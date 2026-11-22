import CoreLocation
import Foundation

/// Every venue the signed-in user has ever checked in at, from `GET /v4/user/venues/{username}`,
/// kept on disk so the check-in screen can suggest nearby places with no network at all.
///
/// The first sync walks every page (a heavy user has about a thousand venues, so about 40
/// requests, spaced out). After that a sync reads from the newest visit and stops at the first
/// venue it already has with the same latest check-in, which is usually one request. Check-ins
/// made in the app are recorded straight away with `record(_:)`.
///
/// Venues from this endpoint carry no Foursquare id, which `checkin/add` needs, so each one is
/// merged with any other sighting of it in `LocalIndex`. Callers posting a check-in must still
/// look the Foursquare id up (`venue/info`) for a venue that has none.
@MainActor
final class VenueHistory {
    static let shared = VenueHistory()

    struct Entry: Codable, Hashable {
        var venue: Venue
        var visits: Int
        var lastVisit: Date?
        var recentCheckinId: Int?
    }

    private struct Snapshot: Codable {
        var username: String
        var entries: [Entry]
        var isComplete: Bool
        var fetchedAt: Date
    }

    /// Don't sync more often than this unless asked to.
    static let minimumInterval: TimeInterval = 6 * 60 * 60
    /// Gap between pages, so a first sync of ~40 pages doesn't hammer the API.
    nonisolated static let pageDelay: Duration = .milliseconds(400)
    /// A runaway guard: 200 pages is 5,000 venues.
    static let maxPages = 200
    /// "Nearby" for suggestions: about a 15-minute walk.
    static let nearbyRadius: CLLocationDistance = 1_500

    /// Keyed by Untappd venue id.
    private(set) var entries: [Int: Entry] = [:]
    /// True once every page has been read at least once.
    private(set) var isComplete = false
    private var fetchedAt: Date?
    private var inFlight: Task<Void, Never>?
    /// Bumped by `clear()`; a sync from an earlier generation must not touch the store.
    private var generation = 0
    private let url: URL
    private let currentUser: () -> String?
    private let fetchPage: @Sendable (_ username: String, _ offset: Int) async throws -> UserVenuesPage
    private let pause: @Sendable () async -> Void
    private let index: LocalIndex

    init(url: URL? = nil,
         currentUser: @escaping () -> String? = { UserDefaults.standard.string(forKey: "username") },
         fetchPage: @escaping @Sendable (String, Int) async throws -> UserVenuesPage = { user, offset in
             try await UntappdAPI.shared.fetch(.userVenues(user, offset: offset), as: UserVenuesPage.self)
         },
         pause: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: VenueHistory.pageDelay) },
         index: LocalIndex = .shared) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = url ?? dir.appendingPathComponent("venue-history.json")
        self.currentUser = currentUser
        self.fetchPage = fetchPage
        self.pause = pause
        self.index = index
        if let d = try? Data(contentsOf: self.url),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: d),
           snap.username == currentUser() {
            for e in snap.entries { if let id = e.venue.venueId { entries[id] = e } }
            isComplete = snap.isComplete
            fetchedAt = snap.fetchedAt
        }
    }

    // MARK: Reading

    /// Venues you've checked in at within `radius` of `location`, nearest first; among places
    /// about as close as each other (within 50 m), the one you've been to most comes first.
    func nearby(_ location: CLLocation, radius: CLLocationDistance = nearbyRadius, limit: Int = 8) -> [Venue] {
        let close = entries.values.compactMap { e -> (Entry, CLLocationDistance)? in
            guard let d = e.venue.distance(from: location), d <= radius else { return nil }
            return (e, d)
        }
        return close.sorted { a, b in
            if abs(a.1 - b.1) > 50 { return a.1 < b.1 }
            if a.0.visits != b.0.visits { return a.0.visits > b.0.visits }
            return a.1 < b.1
        }
        .prefix(limit)
        .map(\.0.venue)
    }

    // MARK: Writing

    /// Records a check-in made in the app, without waiting for the next sync.
    func record(_ venue: Venue, checkinId: Int?, at date: Date = .now) {
        guard let id = venue.venueId, !venue.isCustom else { return }
        var e = entries[id] ?? Entry(venue: venue, visits: 0)
        var v = venue
        v.merge(e.venue)
        e.venue = v
        e.visits += 1
        e.lastVisit = date
        // Leave `recentCheckinId` alone: the next sync then sees this venue as changed and reads
        // past it, picking up the server's count and id.
        entries[id] = e
        save()
    }

    /// Syncs unless a recent sync is on hand (or `force`). Concurrent calls share one sync.
    func refresh(force: Bool = false) async {
        if let existing = inFlight {
            await existing.value
            return
        }
        guard let user = currentUser() else { return }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.minimumInterval { return }
        let gen = generation
        let task = Task { await self.sync(generation: gen, user: user) }
        inFlight = task
        await task.value
        if generation == gen { inFlight = nil }
    }

    private func sync(generation gen: Int, user: String) async {
        let full = !isComplete
        var seen: [Int: Entry] = [:]
        var offset = 0
        var reachedEnd = false
        var total: Int?
        pages: for page in 0..<Self.maxPages {
            if page > 0 { await pause() }
            guard gen == generation, currentUser() == user, !Task.isCancelled else { return }
            let p: UserVenuesPage
            do {
                p = try await fetchPage(user, offset)
            } catch {
                break  // keep what this sync has read so far; the rest next time
            }
            guard gen == generation, currentUser() == user else { return }
            total = p.totalCount ?? total
            if p.items.isEmpty { reachedEnd = true; break }
            for item in p.items {
                guard let id = item.venue.venueId else { continue }
                if !full, let old = entries[id], old.recentCheckinId != nil, old.recentCheckinId == item.recentCheckinId {
                    // Everything from here on was visited before this one and is unchanged.
                    reachedEnd = true
                    break pages
                }
                seen[id] = Entry(venue: item.venue, visits: item.visits, lastVisit: item.lastVisit,
                                 recentCheckinId: item.recentCheckinId)
            }
            offset += p.items.count
            if let total, offset >= total { reachedEnd = true; break }
        }
        guard await apply(seen, replacing: full && reachedEnd, generation: gen, user: user) else { return }
        if reachedEnd {
            isComplete = true
            fetchedAt = .now
        }
        save()
    }

    /// Takes a sync's venues into the store, filling in Foursquare ids and the like from
    /// `LocalIndex`, and teaches `LocalIndex` the venues so search finds them offline.
    /// Returns false, changing nothing, if the user signed out or switched account meanwhile.
    private func apply(_ seen: [Int: Entry], replacing: Bool, generation gen: Int, user: String) async -> Bool {
        var resolved: [Int: Entry] = [:]
        for (id, var e) in seen {
            e.venue = await index.resolve(e.venue)
            resolved[id] = e
        }
        guard gen == generation, currentUser() == user else { return false }
        for id in resolved.keys {
            if let old = entries[id] { resolved[id]?.venue.merge(old.venue) }
        }
        if replacing {
            entries = resolved
        } else {
            entries.merge(resolved) { _, new in new }
        }
        await index.add(venues: resolved.values.map(\.venue))
        return true
    }

    /// Forgets everything (sign-out). Takes effect at once: an in-flight sync is abandoned.
    func clear() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        entries = [:]
        isComplete = false
        fetchedAt = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func save() {
        guard let user = currentUser() else { return }
        let snap = Snapshot(username: user, entries: Array(entries.values), isComplete: isComplete,
                            fetchedAt: fetchedAt ?? .distantPast)
        if let d = try? JSONEncoder().encode(snap) { try? d.write(to: url, options: .atomic) }
    }
}
