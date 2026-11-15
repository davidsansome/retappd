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
    private(set) var servingTypes: [ServingType] = []
    private(set) var loadingFriends = false
    private var loadedFriends = false
    private var loadedServing = false

    /// Recently tagged friends first, then everyone else alphabetically.
    var orderedFriends: [User] {
        let recentIds = Set(recentlyTagged.map(\.id))
        return recentlyTagged + friends.filter { !recentIds.contains($0.id) }
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
        guard !loadedFriends else { return }
        loadedFriends = true
        loadingFriends = true
        defer { loadingFriends = false }

        async let recent: Void = loadRecent()
        async let all: Void = loadAll()
        _ = await (recent, all)
    }

    private func loadRecent() async {
        if let r = try? await cacheThenNetwork(.recentlyTagged, as: UserList.self,
                                               onCached: { recentlyTagged = dedupe($0.users) }) {
            recentlyTagged = dedupe(r.users)
        }
    }

    /// Pages through the whole friends list; each page is cached so the list is instant next time.
    private func loadAll() async {
        let pageSize = 50
        var offset = 0
        var collected: [User] = []
        while offset < 2000 {
            let req = APIRequest.friends(offset: offset, limit: pageSize)
            let isFirst = offset == 0
            guard let page = try? await cacheThenNetwork(req, as: UserList.self, onCached: { cached in
                if isFirst && friends.isEmpty { friends = cached.users }
            }) else { break }
            collected += page.users
            friends = dedupe(collected + friends)
            if page.users.count < pageSize || (page.found.map { collected.count >= $0 } ?? false) { break }
            offset += pageSize
        }
        if !collected.isEmpty { friends = dedupe(collected) }
    }

    private func dedupe(_ users: [User]) -> [User] {
        var seen = Set<Int>()
        return users.filter { seen.insert($0.id).inserted }
    }
}
