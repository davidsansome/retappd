import Foundation
import Observation

/// The user's friends (recently tagged ones first) and the serving types, cache-first.
@Observable @MainActor
final class CheckInOptions {
    static let shared = CheckInOptions()

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
