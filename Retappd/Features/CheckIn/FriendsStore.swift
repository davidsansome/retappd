import Foundation
import Observation

/// What the check-in screen offers: the user's friends (recently tagged ones first), serving
/// types, recent venues and rating precision, all cache-first.
@Observable @MainActor
final class CheckInOptions {
    static let shared = CheckInOptions()

    private static let ratingStepKey = "ratingStep"

    /// 0.1 when the account has Untappd's "rating bump" turned on, else 0.25. Remembered between
    /// launches so the slider is right before the settings have loaded.
    private(set) var ratingStep: Double = {
        let s = UserDefaults.standard.double(forKey: ratingStepKey)
        return s > 0 ? s : 0.25
    }()

    /// The last few places the user checked in, newest first, excluding Untappd at Home.
    private(set) var recentVenues: [Venue] = []
    /// The last few shops the user said they bought a beer at, newest first.
    private(set) var recentShops: [Venue] = []

    private(set) var recentlyTagged: [User] = []
    private(set) var friends: [User] = []
    /// The same friends with when each friendship was made, in the order the server sent them.
    private(set) var friendships: [Friend] = []
    /// Why the friends list couldn't load, when nothing is showing.
    private(set) var friendsError: String?
    private var loadTask: Task<Void, Never>?
    private(set) var servingTypes: [ServingType] = []
    /// Every flavour tag, alphabetically.
    private(set) var flavorTags: [FlavorTag] = []
    private(set) var loadingFriends = false
    private var loadedFriends = false
    private var loadedRecent = false
    private var loadedServing = false
    private var loadedFlavors = false
    /// How many friends have been removed, so other screens (the Me tab's count) can react.
    private(set) var friendRemovals = 0
    /// Friends whose removal is in flight: a friends load that finishes meanwhile mustn't bring
    /// them back.
    private var removingIDs = Set<Int>()
    /// Friends whose removal succeeded, each with how many friends loads had started by then. A
    /// load that started before the removal can still deliver a page listing them, so they stay
    /// hidden until a load that started afterwards completes.
    private var removedIDs: [Int: Int] = [:]
    private var loadGeneration = 0
    private var hiddenIDs: Set<Int> { removingIDs.union(removedIDs.keys) }
    @ObservationIgnored private let cachedPage: FriendPager.Fetch
    @ObservationIgnored private let networkPage: FriendPager.Fetch
    @ObservationIgnored private let sendRemoval: (Int) async throws -> Void
    @ObservationIgnored private let clearFriendCaches: () async -> Void

    init(
        recentlyTagged: [User] = [],
        cachedPage: @escaping FriendPager.Fetch = FriendPager.cachedPage,
        networkPage: @escaping FriendPager.Fetch = FriendPager.networkPage,
        sendRemoval: @escaping (Int) async throws -> Void = { uid in
            _ = try await UntappdAPI.shared.fetch(.removeFriend(uid), as: FriendActionResult.self)
        },
        clearFriendCaches: @escaping () async -> Void = FriendPager.clearCaches
    ) {
        self.recentlyTagged = recentlyTagged
        self.cachedPage = cachedPage
        self.networkPage = networkPage
        self.sendRemoval = sendRemoval
        self.clearFriendCaches = clearFriendCaches
    }

    /// Unfriends someone. They leave the list (and tagging suggestions) at once; if the server
    /// refuses they come back in the same place and the error is thrown. On success the cached
    /// friends pages are dropped, so a stale copy can't bring them back at the next launch.
    func removeFriend(_ friend: Friend) async throws {
        let id = friend.id
        let oldFriendships = friendships
        let oldRecent = recentlyTagged
        removingIDs.insert(id)
        setFriendships(friendships)
        recentlyTagged = recentlyTagged.filter { $0.id != id }
        do {
            try await sendRemoval(id)
        } catch {
            removingIDs.remove(id)
            // Put back only this friend, next to where they were, keeping whatever else changed
            // meanwhile (other removals, friends a load added).
            setFriendships(Self.reinserting(friend, into: friendships, was: oldFriendships))
            if let user = oldRecent.first(where: { $0.id == id }), !hiddenIDs.contains(id) {
                recentlyTagged = Self.reinserting(user, into: recentlyTagged, was: oldRecent)
            }
            throw error
        }
        removingIDs.remove(id)
        removedIDs[id] = loadGeneration
        friendRemovals += 1
        await clearFriendCaches()
    }

    /// `list` with `item` put back just before the first of the items that followed it in `old`
    /// that `list` still has, or at the end if none are.
    private static func reinserting<T: Identifiable>(_ item: T, into list: [T], was old: [T]) -> [T]
    where T.ID == Int {
        guard !list.contains(where: { $0.id == item.id }) else { return list }
        var out = list
        let followers = old.drop { $0.id != item.id }.dropFirst().map(\.id)
        let at = out.firstIndex { followers.contains($0.id) } ?? out.count
        out.insert(item, at: at)
        return out
    }

    /// Friends to offer as one-tap chips: recently tagged ones, else the first of the rest.
    func suggestedFriends(limit: Int = 5) -> [User] {
        Array(orderedFriends.prefix(limit))
    }

    func loadFlavorTags() async {
        guard !loadedFlavors else { return }
        loadedFlavors = true
        let apply = { (l: FlavorTagList) in
            self.flavorTags = l.items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        if let l = try? await cacheThenNetwork(.flavorTags, as: FlavorTagList.self, onCached: apply) {
            apply(l)
        } else if flavorTags.isEmpty {
            loadedFlavors = false  // try again next time
        }
    }

    /// Recently tagged friends first, then everyone else alphabetically.
    var orderedFriends: [User] {
        let recentIds = Set(recentlyTagged.map(\.id))
        return recentlyTagged + friends.filter { !recentIds.contains($0.id) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Every known friend (from the friends list and recently tagged), alphabetically.
    var allFriends: [User] {
        dedupe(friends + recentlyTagged)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Reads the account's settings in the background (called at startup) to learn the rating step.
    func loadAccountSettings() async {
        let apply = { (a: AccountSettings) in self.setRatingBump(a.ratingBump) }
        if let a = try? await cacheThenNetwork(.userSettings, as: AccountSettings.self, onCached: apply) { apply(a) }
    }

    /// Called when the rating bump setting is known or changed (e.g. from Settings).
    func setRatingBump(_ on: Bool) {
        ratingStep = on ? 0.1 : 0.25
        UserDefaults.standard.set(ratingStep, forKey: Self.ratingStepKey)
    }

    /// Finds the user's most recent distinct venues and shops from their own checkins.
    func loadRecentVenues(username: String, count: Int = 3) async {
        func recent(_ venues: [Venue]) -> [Venue] {
            var out: [Venue] = []
            for v in venues
            where v.foursquareId != nil && !v.isCustom && v.venueId != Venue.atHome.venueId
                && !out.contains(where: { $0.id == v.id }) {
                out.append(v)
                if out.count == count { break }
            }
            return out
        }
        let apply = { (page: CheckinPage) in
            self.recentVenues = recent(page.checkins.compactMap(\.venue))
            self.recentShops = recent(page.checkins.compactMap(\.retailVenue))
        }
        if let p = try? await cacheThenNetwork(.userCheckins(username), as: CheckinPage.self, onCached: apply) { apply(p) }
    }

    func loadServingTypes() async {
        guard !loadedServing else { return }
        loadedServing = true
        let apply = { (s: ServingTypes) in self.servingTypes = s.items.sorted { $0.position < $1.position } }
        if let s = try? await cacheThenNetwork(.servingTypes, as: ServingTypes.self, onCached: apply) { apply(s) }
    }

    func loadFriends() async {
        guard !loadedFriends || !loadedRecent || loadTask != nil else { return }
        loadingFriends = true
        defer { loadingFriends = loadTask != nil }

        async let recent: Void = loadRecentIfNeeded()
        async let all: Void = loadAllIfNeeded()
        _ = await (recent, all)
    }

    private func loadRecentIfNeeded() async {
        guard !loadedRecent else { return }
        loadedRecent = true
        if let r = try? await cacheThenNetwork(.recentlyTagged, as: UserList.self,
                                               onCached: { recentlyTagged = dedupe($0.users) }) {
            recentlyTagged = dedupe(r.users)
        } else if recentlyTagged.isEmpty {
            loadedRecent = false
        }
    }

    private func loadAllIfNeeded() async {
        guard !loadedFriends || loadTask != nil else { return }
        await loadAll()
    }

    /// Pages through the whole friends list; each page is cached so the list is instant next time.
    /// Fills `friendships` (with join dates, for the Friends screen) and `friends` (for tagging).
    /// A caller that arrives while a load is running waits for that load instead of starting
    /// another, so it returns only once the list is actually up to date.
    private func loadAll() async {
        if let running = loadTask { await running.value; return }
        let task = Task { await fetchAllPages() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func fetchAllPages() async {
        loadGeneration += 1
        let generation = loadGeneration
        let removalsAtStart = friendRemovals
        friendsError = nil
        if friendships.isEmpty {
            let cached = await FriendPager.fetchAll(fetch: cachedPage)
            if !cached.friends.isEmpty {
                setFriendships(cached.friends)
            }
        }
        let baseline = friendships
        let result = await FriendPager.fetchAll(fetch: networkPage) { partial in
            self.setFriendships(partial + baseline)
        }
        let complete = result.isComplete
            && (result.found.map { result.friends.count >= $0 } ?? (!result.friends.isEmpty || baseline.isEmpty))
        if complete {
            setFriendships(result.friends)
            loadedFriends = true
            // This load began after these removals, so the server has caught up with them.
            removedIDs = removedIDs.filter { $0.value >= generation }
        } else {
            loadedFriends = false
            if friendships.isEmpty {
                friendsError = result.error?.localizedDescription
            }
        }
        // Pages this load cached may predate a removal made while it ran.
        if friendRemovals != removalsAtStart { await clearFriendCaches() }
    }

    private func setFriendships(_ list: [Friend]) {
        var seen = hiddenIDs
        friendships = list.filter { seen.insert($0.id).inserted }
        friends = friendships.map(\.user)
    }

    /// Reloads the friends list from the network (the Friends screen's pull to refresh and each
    /// time it opens), showing the cached list meanwhile.
    func reloadFriends() async {
        loadingFriends = true
        defer { loadingFriends = loadTask != nil }
        await loadAll()
    }

    /// Drops repeats and anyone who has been (or is being) unfriended.
    private func dedupe(_ users: [User]) -> [User] {
        var seen = hiddenIDs
        return users.filter { seen.insert($0.id).inserted }
    }
}
