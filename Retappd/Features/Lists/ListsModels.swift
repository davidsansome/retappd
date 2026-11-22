import Foundation

extension Notification.Name {
    /// Posted whenever a beer is added to or removed from a Wish List or custom list.
    static let listsChanged = Notification.Name("Retappd.listsChanged")
}

enum ListsPageLimit {
    static let overview = 25
    static let detail = 25
    static let beerSheet = 50
}

/// Abstraction over Untappd's wishlist and custom-list endpoints so view models can be unit tested
/// without hitting the network.
protocol ListService: Sendable {
    func fetchUserLists(username: String, bid: Int?, offset: Int, limit: Int,
                        onCached: (@MainActor @Sendable (UserListsResponse) -> Void)?) async throws -> UserListsResponse
    func fetchListDetail(listId: Int, offset: Int, limit: Int,
                         onCached: (@MainActor @Sendable (CustomListDetailResponse) -> Void)?) async throws -> CustomListDetailResponse
    func addToWishlist(bid: Int) async throws -> WishlistMutationResponse
    func removeFromWishlist(bid: Int) async throws -> WishlistMutationResponse
    func addBeer(bid: Int, toList listId: Int) async throws -> AddListItemResponse
    func removeBeer(bid: Int, fromList listId: Int) async throws -> RemoveListItemResponse
    func invalidateCaches(username: String?, bid: Int?, listId: Int?) async
}

struct LiveListService: ListService {
    static let shared = LiveListService()

    func fetchUserLists(username: String, bid: Int?, offset: Int, limit: Int,
                        onCached: (@MainActor @Sendable (UserListsResponse) -> Void)?) async throws -> UserListsResponse {
        let req = APIRequest.userLists(username, bid: bid, offset: offset, limit: limit)
        if let onCached, offset == 0 {
            return try await cacheThenNetwork(req, as: UserListsResponse.self, onCached: onCached)
        }
        return try await UntappdAPI.shared.fetch(req, as: UserListsResponse.self)
    }

    func fetchListDetail(listId: Int, offset: Int, limit: Int,
                         onCached: (@MainActor @Sendable (CustomListDetailResponse) -> Void)?) async throws -> CustomListDetailResponse {
        let req = APIRequest.customListDetail(listId, offset: offset, limit: limit)
        if let onCached, offset == 0 {
            return try await cacheThenNetwork(req, as: CustomListDetailResponse.self, onCached: onCached)
        }
        return try await UntappdAPI.shared.fetch(req, as: CustomListDetailResponse.self)
    }

    func addToWishlist(bid: Int) async throws -> WishlistMutationResponse {
        try await UntappdAPI.shared.fetch(.addToWishlist(bid), as: WishlistMutationResponse.self)
    }

    func removeFromWishlist(bid: Int) async throws -> WishlistMutationResponse {
        try await UntappdAPI.shared.fetch(.removeFromWishlist(bid), as: WishlistMutationResponse.self)
    }

    func addBeer(bid: Int, toList listId: Int) async throws -> AddListItemResponse {
        try await UntappdAPI.shared.fetch(.addBeerToList(listId, bid: bid), as: AddListItemResponse.self)
    }

    func removeBeer(bid: Int, fromList listId: Int) async throws -> RemoveListItemResponse {
        try await UntappdAPI.shared.fetch(.removeBeerFromList(listId, bid: bid), as: RemoveListItemResponse.self)
    }

    func invalidateCaches(username: String?, bid: Int?, listId: Int?) async {
        if let bid {
            await ResponseCache.shared.remove(APIRequest.beerInfo(bid).cacheKey)
        }
        if let username {
            await ResponseCache.shared.remove(APIRequest.userLists(username, limit: ListsPageLimit.overview).cacheKey)
            if let bid {
                await ResponseCache.shared.remove(
                    APIRequest.userLists(username, bid: bid, limit: ListsPageLimit.beerSheet).cacheKey
                )
            }
        }
        if let listId {
            await ResponseCache.shared.remove(APIRequest.customListDetail(listId, limit: ListsPageLimit.detail).cacheKey)
        }
    }
}

enum ListsOrder {
    /// Pins the built-in Wish List first while keeping the server's order for custom lists.
    static func sorted(_ lists: [CustomList]) -> [CustomList] {
        lists.sorted { a, b in
            if a.isWishList != b.isWishList { return a.isWishList }
            return false
        }
    }
}

/// View model for the Lists overview screen (Wishlist + Custom Lists for a user).
@Observable @MainActor
final class UserListsModel {
    let username: String
    private let service: any ListService

    private(set) var lists: [CustomList] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var error: String?
    private var loadedOnce = false

    init(username: String, service: any ListService = LiveListService.shared) {
        self.username = username
        self.service = service
    }

    func loadIfNeeded() async {
        guard !loadedOnce else { return }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.fetchUserLists(
                username: username, bid: nil, offset: 0, limit: ListsPageLimit.overview
            ) { cached in
                self.lists = ListsOrder.sorted(cached.items)
            }
            lists = ListsOrder.sorted(page.items)
            hasMore = page.nextURL != nil && !page.items.isEmpty
            error = nil
            loadedOnce = true
        } catch {
            if !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.fetchUserLists(
                username: username, bid: nil, offset: lists.count, limit: ListsPageLimit.overview, onCached: nil
            )
            let existingIDs = Set(lists.map(\.id))
            let added = page.items.filter { !existingIDs.contains($0.id) }
            lists = ListsOrder.sorted(lists + added)
            hasMore = page.nextURL != nil && !added.isEmpty
        } catch {
            if !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
    }
}

/// View model for a single list's beers (`GET /v4/custom_lists/view/{listId}`).
@Observable @MainActor
final class CustomListDetailModel {
    private(set) var list: CustomList
    let ownerUsername: String
    private let service: any ListService

    private(set) var items: [CustomListItem] = []
    private(set) var totalCount: Int
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var error: String?
    var actionError: String?
    private var loadedOnce = false

    init(list: CustomList, ownerUsername: String, service: any ListService = LiveListService.shared) {
        self.list = list
        self.ownerUsername = ownerUsername
        self.totalCount = list.totalItemCount
        self.service = service
    }

    /// Only beer items are navigable to `BeerView`.
    var beerItems: [CustomListItem] {
        items.filter { $0.beer != nil }
    }

    func loadIfNeeded() async {
        guard !loadedOnce else { return }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.fetchListDetail(
                listId: list.id, offset: 0, limit: ListsPageLimit.detail
            ) { cached in
                self.apply(cached, replacing: true)
            }
            apply(page, replacing: true)
            error = nil
            loadedOnce = true
        } catch {
            if !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.fetchListDetail(
                listId: list.id, offset: items.count, limit: ListsPageLimit.detail, onCached: nil
            )
            apply(page, replacing: false)
        } catch {
            if !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
    }

    /// Optimistically removes a beer from the signed-in user's list, restoring only that item if
    /// the server refuses (so overlapping removals of other rows aren't clobbered).
    func remove(_ item: CustomListItem) async -> Bool {
        guard let bid = item.beer?.bid ?? (item.itemId != 0 ? item.itemId : nil),
              let index = items.firstIndex(where: { $0.id == item.id }) else {
            return false
        }
        items.remove(at: index)
        totalCount = max(0, totalCount - 1)
        list.totalItemCount = totalCount
        actionError = nil

        do {
            if list.isWishList {
                _ = try await service.removeFromWishlist(bid: bid)
            } else {
                _ = try await service.removeBeer(bid: bid, fromList: list.id)
            }
            await service.invalidateCaches(username: ownerUsername, bid: bid, listId: list.id)
            NotificationCenter.default.post(
                name: .listsChanged,
                object: nil,
                userInfo: ["listId": list.id, "fromDetail": true]
            )
            return true
        } catch {
            if !items.contains(where: { $0.id == item.id }) {
                items.insert(item, at: min(index, items.count))
                totalCount += 1
                list.totalItemCount = totalCount
            }
            if !error.isCancellation {
                actionError = error.localizedDescription
            }
            return false
        }
    }

    private func apply(_ page: CustomListDetailResponse, replacing: Bool) {
        if let updated = page.list {
            list = updated
        }
        if replacing {
            items = page.items
            hasMore = page.nextURL != nil && !page.items.isEmpty
        } else {
            let existingIDs = Set(items.map(\.id))
            let added = page.items.filter { !existingIDs.contains($0.id) }
            items.append(contentsOf: added)
            hasMore = page.nextURL != nil && !added.isEmpty
        }
        totalCount = page.totalCount
    }
}

/// View model for the "Add to List" sheet opened from a beer's page.
@Observable @MainActor
final class BeerListsSheetModel {
    let beer: BeerLite
    let username: String
    private let service: any ListService

    private(set) var lists: [CustomList] = []
    private(set) var inFlightIDs: Set<Int> = []
    private(set) var isLoading = false
    private(set) var error: String?
    var mutationError: String?

    init(beer: BeerLite, username: String, service: any ListService = LiveListService.shared) {
        self.beer = beer
        self.username = username
        self.service = service
    }

    /// Current wishlist membership if the Wish List is loaded.
    var isInWishlist: Bool? {
        lists.first(where: \.isWishList)?.isInList
    }

    /// Whether the beer is in at least one list (wishlist or custom list).
    var isInAnyList: Bool {
        lists.contains { $0.isInList == true }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await service.fetchUserLists(
                username: username, bid: beer.bid, offset: 0, limit: ListsPageLimit.beerSheet
            ) { cached in
                self.lists = ListsOrder.sorted(cached.items)
            }
            lists = ListsOrder.sorted(page.items)
            error = nil
        } catch {
            if !error.isCancellation {
                self.error = error.localizedDescription
            }
        }
    }

    /// Toggles the beer's membership in `list` optimistically, rolling back on error.
    func toggle(_ list: CustomList) async -> Bool {
        guard !inFlightIDs.contains(list.id),
              let index = lists.firstIndex(where: { $0.id == list.id }) else {
            return false
        }
        let wasInList = lists[index].isInList == true
        let previousCount = lists[index].totalItemCount
        let targetState = !wasInList

        inFlightIDs.insert(list.id)
        lists[index].isInList = targetState
        lists[index].totalItemCount = max(0, previousCount + (targetState ? 1 : -1))
        mutationError = nil
        defer { inFlightIDs.remove(list.id) }

        do {
            if list.isWishList {
                if targetState {
                    _ = try await service.addToWishlist(bid: beer.bid)
                } else {
                    _ = try await service.removeFromWishlist(bid: beer.bid)
                }
            } else {
                if targetState {
                    _ = try await service.addBeer(bid: beer.bid, toList: list.id)
                } else {
                    _ = try await service.removeBeer(bid: beer.bid, fromList: list.id)
                }
            }
            await service.invalidateCaches(username: username, bid: beer.bid, listId: list.id)
            NotificationCenter.default.post(
                name: .listsChanged,
                object: nil,
                userInfo: ["listId": list.id]
            )
            return true
        } catch {
            if let rollbackIndex = lists.firstIndex(where: { $0.id == list.id }) {
                lists[rollbackIndex].isInList = wasInList
                lists[rollbackIndex].totalItemCount = previousCount
            }
            if !error.isCancellation {
                mutationError = error.localizedDescription
            }
            return false
        }
    }
}
