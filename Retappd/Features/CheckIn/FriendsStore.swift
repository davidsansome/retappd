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
    /// Every change to who is on the friends list (removal or accepted request), so a load that
    /// spans one knows the pages it cached may be out of date.
    private var friendListChanges = 0
    /// Net change to the friend count this session: one less per removal, one more per accepted
    /// request. The Me tab adds the difference to the count it fetched.
    private(set) var friendCountChange = 0

    /// Friends made by accepting a request: the mirror of `removingIDs`/`removedIDs`. The
    /// friends list shows them at once, and a load that started before the accept (so can't list
    /// them yet) mustn't drop them. `settledAt` is how many friends loads had started when the
    /// accept succeeded; nil while it is in flight.
    private struct AddedFriend {
        var friend: Friend
        var settledAt: Int?
    }
    private var addedFriends: [Int: AddedFriend] = [:]

    /// Incoming friend requests, as the server last listed them less the ones answered since.
    private(set) var requests: [Friend] = []
    /// Requests being accepted or rejected right now, and ones answered successfully with how
    /// many requests loads had started by then: a load that started before the answer can still
    /// list the request, so it stays hidden until a load that started afterwards completes.
    private var answeringIDs = Set<Int>()
    private var answeredIDs: [Int: Int] = [:]
    private var requestsGeneration = 0
    private var hiddenRequestIDs: Set<Int> { answeringIDs.union(answeredIDs.keys) }

    enum RequestAnswer { case accept, reject }
    /// Loads the pending requests, calling `onCached` first with a cached copy if there is one.
    typealias RequestsFetch = @MainActor (_ onCached: ([Friend]) -> Void) async throws -> [Friend]
    @ObservationIgnored private let cachedPage: FriendPager.Fetch
    @ObservationIgnored private let networkPage: FriendPager.Fetch
    @ObservationIgnored private let sendRemoval: (Int) async throws -> Void
    @ObservationIgnored private let clearFriendCaches: () async -> Void
    @ObservationIgnored private let fetchRequests: RequestsFetch
    @ObservationIgnored private let sendAnswer: (Int, RequestAnswer) async throws -> Void
    @ObservationIgnored private let clearRequestsCache: () async -> Void

    init(
        recentlyTagged: [User] = [],
        cachedPage: @escaping FriendPager.Fetch = FriendPager.cachedPage,
        networkPage: @escaping FriendPager.Fetch = FriendPager.networkPage,
        sendRemoval: @escaping (Int) async throws -> Void = { uid in
            _ = try await UntappdAPI.shared.fetch(.removeFriend(uid), as: FriendActionResult.self)
        },
        clearFriendCaches: @escaping () async -> Void = FriendPager.clearCaches,
        fetchRequests: @escaping RequestsFetch = { onCached in
            try await cacheThenNetwork(.pendingFriendRequests, as: PendingRequestList.self,
                                       onCached: { onCached($0.requests) }).requests
        },
        sendAnswer: @escaping (Int, RequestAnswer) async throws -> Void = { uid, answer in
            let req = answer == .accept ? APIRequest.acceptFriendRequest(uid) : APIRequest.rejectFriendRequest(uid)
            _ = try await UntappdAPI.shared.fetch(req, as: FriendRequestResult.self)
        },
        clearRequestsCache: @escaping () async -> Void = {
            await ResponseCache.shared.remove(APIRequest.pendingFriendRequests.cacheKey)
        }
    ) {
        self.recentlyTagged = recentlyTagged
        self.cachedPage = cachedPage
        self.networkPage = networkPage
        self.sendRemoval = sendRemoval
        self.clearFriendCaches = clearFriendCaches
        self.fetchRequests = fetchRequests
        self.sendAnswer = sendAnswer
        self.clearRequestsCache = clearRequestsCache
    }

    // MARK: - Friend requests

    /// Loads the incoming requests (cached copy first), for the Friends screen and the Me tab's
    /// indicator. Only the latest load applies its result, and requests answered since it
    /// started stay gone.
    func loadRequests() async {
        requestsGeneration += 1
        let generation = requestsGeneration
        let apply = { (list: [Friend]) in
            guard generation == self.requestsGeneration else { return }
            self.requests = self.visibleRequests(list)
        }
        guard let list = try? await fetchRequests(apply), generation == requestsGeneration else { return }
        // This load began after these answers, so the server has caught up with them.
        answeredIDs = answeredIDs.filter { $0.value >= generation }
        requests = visibleRequests(list)
    }

    /// Forgets the incoming requests (at sign-out, so the next account never sees the last one's)
    /// and abandons any load still in flight.
    func clearRequests() {
        requestsGeneration += 1
        requests = []
        answeringIDs = []
        answeredIDs = [:]
    }

    /// Resets all per-account state at sign-out and abandons any in-flight loads so a subsequent
    /// sign-in can't see the previous account's friends, venues, shops, or requests.
    func resetForSignOut() {
        loadTask?.cancel()
        loadTask = nil
        loadingFriends = false
        loadGeneration += 1
        loadedFriends = false
        loadedRecent = false
        friends = []
        friendships = []
        recentlyTagged = []
        recentVenues = []
        recentShops = []
        friendsError = nil
        removingIDs = []
        removedIDs = [:]
        addedFriends = [:]
        friendRemovals = 0
        friendCountChange = 0
        friendListChanges = 0
        clearRequests()
    }

    private func visibleRequests(_ list: [Friend]) -> [Friend] {
        var seen = hiddenRequestIDs
        return list.filter { seen.insert($0.id).inserted }
    }

    /// Accepts a request. The person is a friend at once (in the list and in tagging); if the
    /// server refuses, the request comes back and the error is thrown. Also used for someone
    /// whose request was rejected earlier, or who isn't in `requests` for another reason.
    func acceptRequest(_ person: Friend) async throws {
        try await answer(person, with: .accept)
    }

    /// Rejects a request. It leaves the list at once and comes back if the server refuses. A
    /// reject is a silent decline that can be undone (the person can still be accepted later),
    /// which is why the UI doesn't confirm it.
    func rejectRequest(_ person: Friend) async throws {
        try await answer(person, with: .reject)
    }

    private func answer(_ person: Friend, with answer: RequestAnswer) async throws {
        let id = person.id
        let oldRequests = requests
        let oldRemoved = removedIDs[id]
        answeringIDs.insert(id)
        requests = requests.filter { $0.id != id }
        if answer == .accept {
            // They are a friend as of now, so they head the newest-first list.
            let made = Friend(user: person.user, location: person.location, createdAt: .now)
            addedFriends[id] = AddedFriend(friend: made, settledAt: nil)
            removedIDs[id] = nil
            setFriendships(friendships)
        }
        do {
            try await sendAnswer(id, answer)
        } catch {
            answeringIDs.remove(id)
            // Bring back only this request, keeping whatever else changed meanwhile.
            if !answeredIDs.keys.contains(id) {
                requests = Self.reinserting(person, into: requests, was: oldRequests)
            }
            if answer == .accept {
                addedFriends[id] = nil
                // Put back the removal tombstone the accept cleared, so a load that began before
                // that removal still can't bring them back.
                removedIDs[id] = oldRemoved
                setFriendships(friendships.filter { $0.id != id })
            }
            throw error
        }
        answeringIDs.remove(id)
        answeredIDs[id] = requestsGeneration
        if answer == .accept {
            addedFriends[id]?.settledAt = loadGeneration
            friendListChanges += 1
            friendCountChange += 1
        }
        await clearRequestsCache()
        if answer == .accept { await clearFriendCaches() }
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
        addedFriends[id] = nil
        friendRemovals += 1
        friendListChanges += 1
        friendCountChange -= 1
        await clearFriendCaches()
    }

    /// Updates local friend state after blocking a user (the server unfriends them as part of blocking).
    func noteBlockedFriend(_ id: Int) async {
        let wasFriend = friendships.contains { $0.id == id }
        removedIDs[id] = loadGeneration
        addedFriends[id] = nil
        setFriendships(friendships.filter { $0.id != id })
        recentlyTagged = recentlyTagged.filter { $0.id != id }
        if wasFriend {
            friendRemovals += 1
            friendListChanges += 1
            friendCountChange -= 1
            await clearFriendCaches()
        }
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

    /// Friends to offer as one-tap chips: up to `limit` recently tagged ones, then up to `limit`
    /// of `nearby` (friends checking in near you, closest first) not already offered, topped up
    /// to `limit` from the rest alphabetically.
    func suggestedFriends(limit: Int = 5, nearby: [User] = []) -> [User] {
        var out = Array(recentlyTagged.prefix(limit))
        var ids = Set(out.map(\.id))
        let near = nearbyFriends(nearby).filter { !ids.contains($0.id) }.prefix(limit)
        out += near
        ids.formUnion(near.map(\.id))
        for u in orderedFriends where out.count < limit && ids.insert(u.id).inserted {
            out.append(u)
        }
        return out
    }

    /// `nearby` without duplicates or anyone just removed or blocked (whom the feed may still
    /// show), in the order given.
    func nearbyFriends(_ nearby: [User]) -> [User] {
        dedupe(nearby)
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
        if let s = try? await cacheThenNetwork(.servingTypes, as: ServingTypes.self, onCached: apply) {
            apply(s)
        } else if servingTypes.isEmpty {
            loadedServing = false  // try again next time
        }
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
        let generation = loadGeneration
        loadedRecent = true
        if let r = try? await cacheThenNetwork(.recentlyTagged, as: UserList.self,
                                               onCached: {
                                                   guard generation == self.loadGeneration else { return }
                                                   recentlyTagged = dedupe($0.users)
                                               }) {
            guard generation == loadGeneration else { return }
            recentlyTagged = dedupe(r.users)
        } else if generation == loadGeneration && recentlyTagged.isEmpty {
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
        if loadTask == task { loadTask = nil }
    }

    private func fetchAllPages() async {
        loadGeneration += 1
        let generation = loadGeneration
        let changesAtStart = friendListChanges
        friendsError = nil
        if friendships.isEmpty {
            let cached = await FriendPager.fetchAll(fetch: cachedPage)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if !cached.friends.isEmpty {
                setFriendships(cached.friends)
            }
        }
        // Not the optimistic friends of in-flight accepts: setFriendships adds those from
        // `addedFriends` itself, and if an accept fails they must not return via this copy.
        let baseline = friendships.filter { addedFriends[$0.id] == nil }
        let result = await FriendPager.fetchAll(fetch: networkPage) { partial in
            guard generation == self.loadGeneration, !Task.isCancelled else { return }
            self.setFriendships(partial + baseline)
        }
        guard generation == loadGeneration, !Task.isCancelled else { return }
        let complete = result.isComplete
            && (result.found.map { result.friends.count >= $0 } ?? (!result.friends.isEmpty || baseline.isEmpty))
        if complete {
            // This load began after these removals and accepts, so the server has caught up.
            removedIDs = removedIDs.filter { $0.value >= generation }
            addedFriends = addedFriends.filter { $0.value.settledAt.map { $0 >= generation } ?? true }
            setFriendships(result.friends)
            loadedFriends = true
        } else {
            loadedFriends = false
            if friendships.isEmpty {
                friendsError = result.error?.localizedDescription
            }
        }
        // Pages this load cached may predate a removal or accept made while it ran.
        if friendListChanges != changesAtStart { await clearFriendCaches() }
    }

    private func setFriendships(_ list: [Friend]) {
        var seen = hiddenIDs
        var out = list.filter { seen.insert($0.id).inserted }
        // Friends just made by accepting a request, which the list this came from may predate.
        let added = addedFriends.values.map(\.friend).filter { seen.insert($0.id).inserted }
        out = Friend.sortedByRecent(added) + out
        friendships = out
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
