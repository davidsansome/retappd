import Foundation

/// A user's Wish List or custom list from `GET /v4/custom_lists/userlists/{username}`
/// (and `list` / `list_meta` in `view`, `viewitemenhanced`, and `upsertitem`).
struct CustomList: Decodable, Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    var description: String?
    var totalItemCount: Int
    var isWishList: Bool
    var isPublic: Bool
    /// Present when `GET /v4/custom_lists/userlists/{username}` is called with `bid`.
    var isInList: Bool?
    var isOwner: Bool?
    var ownerUsername: String?
    var previewLabels: [URL]
    var updatedAt: Date?

    init(
        id: Int,
        name: String,
        description: String? = nil,
        totalItemCount: Int = 0,
        isWishList: Bool = false,
        isPublic: Bool = true,
        isInList: Bool? = nil,
        isOwner: Bool? = nil,
        ownerUsername: String? = nil,
        previewLabels: [URL] = [],
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.totalItemCount = totalItemCount
        self.isWishList = isWishList
        self.isPublic = isPublic
        self.isInList = isInList
        self.isOwner = isOwner
        self.ownerUsername = ownerUsername
        self.previewLabels = previewLabels
        self.updatedAt = updatedAt
    }

    private struct PreviewImage: Decodable {
        var url: URL?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            url = c.url("beer_label")
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.int("list_id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no list_id"))
        }
        self.id = id
        name = c.text("list_name") ?? (c.bool("is_wish_list") == true ? "Wish List" : "Untitled List")
        description = c.text("list_description")
        totalItemCount = c.int("total_item_count") ?? 0
        isWishList = c.bool("is_wish_list") ?? false
        isPublic = c.bool("is_public") ?? true
        isInList = c.bool("is_in_list")
        isOwner = c.bool("is_owner")
        ownerUsername = c.nested("owner")?.text("user_name")
        previewLabels = c.items("list_image", PreviewImage.self).compactMap(\.url)
        updatedAt = UntappdDate.parse(c.string("updated_at"))
    }
}

/// `GET /v4/custom_lists/userlists/{username}`.
struct UserListsResponse: Decodable, Sendable {
    var items: [CustomList]
    var totalCount: Int
    var offset: Int
    var nextURL: String?

    init(items: [CustomList], totalCount: Int? = nil, offset: Int = 0, nextURL: String? = nil) {
        self.items = items
        self.totalCount = totalCount ?? items.count
        self.offset = offset
        self.nextURL = nextURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        items = c.list("items")
        totalCount = c.int("total_list_count") ?? c.int("count") ?? items.count
        offset = c.int("offset") ?? 0
        nextURL = c.nested("pagination")?.text("next_url")
    }
}

/// An item inside a custom list or wishlist, from `GET /v4/custom_lists/view/{id}`,
/// `GET /v4/custom_lists/viewitemenhanced/{id}`, or `POST /v4/custom_lists/upsertitem/{id}`.
struct CustomListItem: Decodable, Identifiable, Hashable, Sendable {
    var id: Int
    var listItemId: Int
    var itemId: Int
    var itemType: String
    var createdAt: Date?
    var beer: BeerLite?
    var notes: String?
    var quantity: Int?
    var containerName: String?
    var purchaseDateISO: String?
    var bottledDateISO: String?
    var bestByDateISO: String?
    var purchasePrice: String?

    init(
        listItemId: Int,
        itemId: Int,
        itemType: String = "beer",
        createdAt: Date? = nil,
        beer: BeerLite? = nil,
        notes: String? = nil,
        quantity: Int? = nil,
        containerName: String? = nil,
        purchaseDateISO: String? = nil,
        bottledDateISO: String? = nil,
        bestByDateISO: String? = nil,
        purchasePrice: String? = nil
    ) {
        self.id = listItemId != 0 ? listItemId : itemId
        self.listItemId = listItemId
        self.itemId = itemId
        self.itemType = itemType
        self.createdAt = createdAt
        self.beer = beer
        self.notes = notes
        self.quantity = quantity
        self.containerName = containerName
        self.purchaseDateISO = purchaseDateISO
        self.bottledDateISO = bottledDateISO
        self.bestByDateISO = bestByDateISO
        self.purchasePrice = purchasePrice
    }

    /// Short optional metadata summary for display on a `BeerRow` (e.g. quantity or notes).
    var detailSummary: String? {
        var parts: [String] = []
        if let quantity, quantity > 1 { parts.append("Qty \(quantity)") }
        if let containerName, !containerName.isEmpty { parts.append(containerName) }
        if let notes, !notes.isEmpty { parts.append(notes) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let listItemId = c.int("list_item_id") ?? 0
        let itemId = c.int("item_id") ?? c.nested("beer")?.int("bid") ?? 0
        guard listItemId != 0 || itemId != 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no list item id"))
        }
        self.listItemId = listItemId
        self.itemId = itemId
        self.id = listItemId != 0 ? listItemId : itemId
        itemType = c.text("item_type") ?? "beer"
        createdAt = UntappdDate.parse(c.string("created_at"))

        if let b: BeerRef = c.obj("beer"), b.bid != 0 {
            var lite = BeerLite(beer: b, brewery: c.obj("brewery"))
            let n = c.nested("beer")
            lite.rating = n?.double("rating_score").flatMap { $0 > 0 ? $0 : nil }
            lite.ratingCount = n?.int("rating_count")
            lite.hasHad = c.bool("has_had") ?? b.hasHad
            beer = lite
        } else {
            beer = nil
        }

        notes = c.text("notes")
        quantity = c.int("quantity")
        containerName = c.nested("container")?.text("container_name")
        purchaseDateISO = c.text("purchase_date_iso")
        bottledDateISO = c.text("bottled_date_iso")
        bestByDateISO = c.text("best_by_date_iso")
        let rawPrice = c.text("purchase_price")
        purchasePrice = (rawPrice == "0.00" || rawPrice == "0") ? nil : rawPrice
    }
}

/// `GET /v4/custom_lists/view/{id}`.
struct CustomListDetailResponse: Decodable, Sendable {
    var list: CustomList?
    var totalCount: Int
    var items: [CustomListItem]
    var nextURL: String?

    init(list: CustomList? = nil, totalCount: Int? = nil, items: [CustomListItem], nextURL: String? = nil) {
        self.list = list
        self.totalCount = totalCount ?? items.count
        self.items = items
        self.nextURL = nextURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        list = c.obj("list")
        items = c.list("items")
        totalCount = c.int("total_count") ?? c.int("count") ?? items.count
        nextURL = c.nested("pagination")?.text("next_url")
    }
}

/// `POST /v4/custom_lists/additemenhanced/{id}`.
struct AddListItemResponse: Decodable, Sendable {
    var result: String?
    var itemId: Int?
    var listItemId: Int?

    var isSuccess: Bool { result == "success" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        result = c.text("result")
        itemId = c.int("item_id")
        listItemId = c.int("list_item_id")
    }
}

/// `POST /v4/custom_lists/removeitem/{id}`.
struct RemoveListItemResponse: Decodable, Sendable {
    var result: String?
    var itemId: Int?

    var isSuccess: Bool { result == "success" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        result = c.text("result")
        itemId = c.int("item_id")
    }
}

/// `POST /v4/user/wishlist/add` and `POST /v4/user/wishlist/delete`.
struct WishlistMutationResponse: Decodable, Sendable {
    var result: String?
    var action: String?

    var isSuccess: Bool { result == "success" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        result = c.text("result")
        action = c.text("action")
    }
}

/// `POST /v4/beer/subscribewish`.
struct SubscribeWishResponse: Decodable, Sendable {
    var result: String?
    var mode: String?
    var count: Int
    var items: [Int]

    var isSubscribed: Bool { mode == "on" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        result = c.text("result")
        mode = c.text("mode")
        count = c.int("count") ?? 0
        items = c.list("items")
    }
}

/// `GET /v4/beer/subscribes`.
struct BeerSubscribesResponse: Decodable, Sendable {
    var wishListSubscribeStatus: Bool
    var count: Int
    var items: [BeerLite]

    private struct Item: Decodable {
        var beer: BeerLite?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let b: BeerRef = c.obj("beer"), b.bid != 0 else { beer = nil; return }
            var lite = BeerLite(beer: b, brewery: c.obj("brewery"))
            let n = c.nested("beer")
            lite.rating = n?.double("rating_score").flatMap { $0 > 0 ? $0 : nil }
            lite.ratingCount = n?.int("rating_count")
            lite.hasHad = c.bool("has_had") ?? b.hasHad
            beer = lite
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        wishListSubscribeStatus = c.bool("wish_list_subscribe_status") ?? false
        items = c.list("items", Item.self).compactMap(\.beer)
        count = c.int("count") ?? items.count
    }
}
