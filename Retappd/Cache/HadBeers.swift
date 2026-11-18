import Foundation
import Observation

/// Every beer the signed-in user has ever had, from `GET /v4/user/user_beer_list?mode=v3`: the
/// source of truth for the green "had it" corner. Unlike the per-beer `has_had` flags (absent from
/// Algolia hits, stale in cached feeds), this covers the user's whole history in one cheap call.
///
/// Until the first full list arrives (never synced, or signed in a moment ago), `has(_:)` falls
/// back to the flag the beer carries, which `LocalIndex` makes sticky. Once a list that is clearly
/// complete has loaded (its length matches `bids_count`), the set is authoritative, so a beer whose
/// only check-in was deleted loses its tick on next refresh. A failed fetch, or an empty list with a
/// non-zero count, changes nothing; a short list or one without a count only adds ticks.
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
    /// Bumped by `clear()`; a fetch or refresh from an earlier generation must not touch the store.
    @ObservationIgnored private var generation = 0
    /// Beers added by check-ins while a fetch was in flight; the fetched list may predate them.
    @ObservationIgnored private var addedDuringFetch: Set<Int> = []
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let currentUser: () -> String?
    @ObservationIgnored private let fetchList: @Sendable () async throws -> UserBeerList

    private struct Snapshot: Codable {
        var username: String
        var ids: [Int]
        var fetchedAt: Date
    }

    /// `bids_count` may be off by one (the live server counted a leading empty field); a list
    /// shorter than that by more than this is treated as truncated. `bids_limit` in the response is
    /// undocumented, so it's ignored rather than guessed at.
    static let countTolerance = 2

    init(url: URL? = nil,
         currentUser: @escaping () -> String? = { UserDefaults.standard.string(forKey: "username") },
         fetchList: @escaping @Sendable () async throws -> UserBeerList = {
             try await UntappdAPI.shared.fetch(.userBeerList, as: UserBeerList.self)
         }) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = url ?? dir.appendingPathComponent("had-beers.json")
        self.currentUser = currentUser
        self.fetchList = fetchList
        if let d = try? Data(contentsOf: self.url),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: d),
           snap.username == currentUser() {
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
        guard let user = currentUser() else { return }  // signed out: nothing to sync
        if !force, let fetchedAt, Date.now.timeIntervalSince(fetchedAt) < Self.minimumInterval { return }
        let gen = generation
        let task = Task { await self.fetch(generation: gen, user: user) }
        inFlight = task
        await task.value
        // A clear() (and perhaps a newer refresh) may have happened meanwhile; don't nil out its task.
        if generation == gen { inFlight = nil }
    }

    /// `gen` and `user` are the session the fetch started in: if the user signed out (`clear()`
    /// bumps `generation`) or another account is now signed in, the result is dropped.
    private func fetch(generation gen: Int, user: String) async {
        addedDuringFetch = []
        do {
            let list = try await fetchList()
            guard gen == generation, currentUser() == user, !Task.isCancelled else { return }
            apply(list)
        } catch {
            // Keep whatever we had; try again next time.
        }
    }

    /// Takes a fetched list into the store, unless it looks wrong.
    private func apply(_ list: UserBeerList) {
        #if DEBUG
        print("HadBeers: \(list.bids.count) beers (bids_count \(list.count ?? -1)), bids \(list.wasBase64 ? "base64" : "plain")")
        #endif
        let fetched = Set(list.bids).union(addedDuringFetch)
        if list.bids.isEmpty {
            // An empty list is believable only if the server says the count is zero too; otherwise
            // it's a missing or damaged field, and wiping every tick would be worse than a stale set.
            guard list.count == 0 else {
                #if DEBUG
                print("HadBeers: ignoring empty list (bids_count \(list.count ?? -1))")
                #endif
                return
            }
        } else if list.count.map({ list.bids.count + Self.countTolerance < $0 }) ?? true {
            // Truncated, or no count to check it against: it can add ticks but not remove any, and
            // doesn't make the set authoritative (or refresh `fetchedAt`, so it's retried).
            #if DEBUG
            print("HadBeers: possibly partial list, \(list.bids.count) of \(list.count ?? -1); merging")
            #endif
            ids.formUnion(fetched)
            save()  // only writes if already authoritative, where a superset is still right
            return
        }
        ids = fetched
        isAuthoritative = true
        fetchedAt = .now
        save()
    }

    /// Forgets everything (sign-out). Takes effect at once: an in-flight fetch is abandoned.
    func clear() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        addedDuringFetch = []
        ids = []
        isAuthoritative = false
        fetchedAt = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Written synchronously on the main actor (tens of KB), so writes can't reorder or outlive `clear()`.
    private func save() {
        // A partial set (check-ins before the first sync) mustn't be reloaded as the full list.
        guard isAuthoritative, let user = currentUser() else { return }
        let snap = Snapshot(username: user, ids: Array(ids), fetchedAt: fetchedAt ?? .now)
        if let d = try? JSONEncoder().encode(snap) { try? d.write(to: url, options: .atomic) }
    }
}
