import Foundation
import Observation

/// Every beer the signed-in user has ever had, from `GET /v4/user/user_beer_list?mode=v3`: the
/// source of truth for the green "had it" corner. Unlike the per-beer `has_had` flags (absent from
/// Algolia hits, stale in cached feeds), this covers the user's whole history in one cheap call.
///
/// Until the first full list arrives (never synced, or signed in a moment ago), `has(_:)` falls
/// back to the flag the beer carries, which `LocalIndex` makes sticky. Once a list has loaded, the
/// set is authoritative, so a beer whose only check-in was deleted loses its tick on next refresh.
///
/// Persisted to disk so the ticks are there at once, offline. Observable, so views showing a tick
/// update when a sync lands.
@MainActor @Observable
final class HadBeers {
    static let shared = HadBeers()

    /// Don't re-fetch more often than this unless asked to (pull to refresh, deleted check-in).
    static let minimumInterval: TimeInterval = 3 * 60 * 60

    private(set) var ids: Set<Int> = []
    /// True once a full list has been fetched (this launch or a previous one).
    private(set) var isAuthoritative = false
    @ObservationIgnored private var fetchedAt: Date?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// Beers added by check-ins while a fetch was in flight; the fetched list may predate them.
    @ObservationIgnored private var addedDuringFetch: Set<Int> = []
    @ObservationIgnored private let url: URL

    private struct Snapshot: Codable {
        var ids: [Int]
        var fetchedAt: Date
    }

    init(url: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = url ?? dir.appendingPathComponent("had-beers.json")
        if let d = try? Data(contentsOf: self.url),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: d) {
            ids = Set(snap.ids)
            fetchedAt = snap.fetchedAt
            isAuthoritative = true
        }
    }

    /// Whether to show the tick for `beer`.
    func has(_ beer: BeerLite) -> Bool { has(beer.bid, fallback: beer.hasHad) }

    /// `fallback` is whatever the API or `LocalIndex` said, used only before a full list has loaded.
    func has(_ bid: Int, fallback: Bool? = nil) -> Bool {
        ids.contains(bid) || (!isAuthoritative && fallback == true)
    }

    /// Records a beer the user has just checked in, without waiting for the next sync.
    func add(_ bid: Int) {
        guard bid > 0 else { return }
        ids.insert(bid)
        if inFlight != nil { addedDuringFetch.insert(bid) }
        save()
    }

    /// Fetches the list unless a recent one is on hand (or `force`). Concurrent calls share one fetch.
    func refresh(force: Bool = false) async {
        if let inFlight { return await inFlight.value }
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.minimumInterval { return }
        let task = Task { await self.fetch() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func fetch() async {
        addedDuringFetch = []
        #if DEBUG
        let started = Date.now
        #endif
        do {
            let data = try await UntappdAPI.shared.data(.userBeerList)
            let list = try UntappdAPI.decode(UserBeerList.self, from: data)
            #if DEBUG
            print("HadBeers: \(list.bids.count) beers (bids_count \(list.count ?? -1)), \(data.count) bytes, "
                  + "\(Int(Date.now.timeIntervalSince(started) * 1000)) ms, bids \(list.wasBase64 ? "base64" : "plain")")
            #endif
            guard !Task.isCancelled else { return }
            ids = Set(list.bids).union(addedDuringFetch)
            isAuthoritative = true
            fetchedAt = .now
            save()
        } catch {
            // Keep whatever we had; try again next time.
        }
    }

    /// Forgets everything (sign-out).
    func clear() {
        inFlight?.cancel()
        inFlight = nil
        ids = []
        isAuthoritative = false
        fetchedAt = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func save() {
        // A partial set (check-ins before the first sync) mustn't be reloaded as the full list.
        guard isAuthoritative else { return }
        let snap = Snapshot(ids: Array(ids), fetchedAt: fetchedAt ?? .now)
        let url = url
        Task.detached(priority: .utility) {
            if let d = try? JSONEncoder().encode(snap) { try? d.write(to: url, options: .atomic) }
        }
    }
}
