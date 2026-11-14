import Foundation
import CoreLocation

// MARK: - Envelope

struct Meta: Decodable {
    var code: Int
    var errorDetail: String?
    var errorType: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        code = c.int("code") ?? 0
        errorDetail = c.text("error_detail")
        errorType = c.text("error_type")
    }
}

struct Envelope<T: Decodable>: Decodable {
    var meta: Meta?
    var response: T?
}

// MARK: - Users

struct User: Decodable, Hashable, Identifiable {
    var id: Int
    var userName: String
    var firstName: String?
    var lastName: String?
    var avatar: URL?
    var relationship: String?

    var displayName: String {
        let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return full.isEmpty ? userName : full
    }
    /// First name plus last initial ("Jamie Curtis" → "Jamie C"), for space-constrained places.
    var shortName: String {
        let first = firstName?.trimmingCharacters(in: .whitespaces) ?? ""
        let last = lastName?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !first.isEmpty else { return displayName }
        guard let initial = last.first else { return first }
        return "\(first) \(initial)"
    }
    var isFriend: Bool { relationship == "friends" }

    init(id: Int, userName: String, firstName: String?, lastName: String?, avatar: URL?) {
        self.id = id
        self.userName = userName
        self.firstName = firstName
        self.lastName = lastName
        self.avatar = avatar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.int("uid") ?? c.int("id") ?? 0
        userName = c.string("user_name") ?? ""
        firstName = c.text("first_name")
        lastName = c.text("last_name")
        avatar = c.text("user_avatar").flatMap(URL.init(string:))
        relationship = c.text("relationship")
    }
}

// MARK: - Beers & breweries

struct BeerRef: Decodable, Hashable {
    var bid: Int
    var name: String
    var label: URL?
    var labelHD: URL?
    var style: String?
    var abv: Double?
    var hasHad: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        bid = c.int("bid") ?? 0
        name = c.string("beer_name") ?? ""
        label = c.text("beer_label").flatMap(URL.init(string:))
        labelHD = c.text("beer_label_hd").flatMap(URL.init(string:))
        style = c.text("beer_style")
        abv = c.double("beer_abv")
        hasHad = c.bool("has_had")
    }
}

struct BreweryRef: Decodable, Hashable {
    var id: Int
    var name: String
    var label: URL?
    var country: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.int("brewery_id") ?? 0
        name = c.string("brewery_name") ?? ""
        label = c.text("brewery_label").flatMap(URL.init(string:))
        country = c.text("country_name")
    }
}

/// A compact beer record shared by search, menus, the local index and the check-in sheet.
struct BeerLite: Codable, Hashable, Identifiable {
    var bid: Int
    var name: String
    var brewery: String
    var style: String?
    var abv: Double?
    var label: URL?
    var rating: Double?
    var ratingCount: Int?
    var popularity: Int?
    var hasHad: Bool?
    /// The brewery's logo, shown when the beer has no label of its own.
    var breweryLabel: URL? = nil

    var id: Int { bid }
}

extension BeerLite {
    init(beer: BeerRef, brewery: BreweryRef?) {
        self.init(bid: beer.bid, name: beer.name, brewery: brewery?.name ?? "", style: beer.style,
                  abv: beer.abv, label: beer.label, hasHad: beer.hasHad, breweryLabel: brewery?.label)
    }
}

// MARK: - Barcodes

/// `/v4/beer/checkbarcodemultiple`: the beers Untappd's users have given a barcode. The app
/// gets `items` (a plain list) and `unverified` (`{enabled, count, items}`); metabeer-v2 has also
/// seen a `verified` block. Each may be a list or a `{count, items}` wrapper. Verified beers and
/// `items` come before unverified ones, without duplicates.
struct BarcodeMatches: Decodable {
    var beers: [BeerLite]

    private struct Item: Decodable {
        var beer: BeerLite?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let beer = c.obj("beer", BeerRef.self), beer.bid != 0 else { beer = nil; return }
            // The brewery is usually beside the beer, but some endpoints nest it inside.
            let b = c.nested("beer")
            let brewery = c.obj("brewery", BreweryRef.self) ?? b?.obj("brewery", BreweryRef.self)
            var lite = BeerLite(beer: beer, brewery: brewery)
            lite.rating = b?.double("rating_score")
            lite.ratingCount = b?.int("rating_count")
            self.beer = lite
        }
    }

    init(beers: [BeerLite]) { self.beers = beers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func block(_ key: String) -> [Item] {
            let list: [Item] = c.list(key)
            return list.isEmpty ? c.items(key) : list
        }
        var seen = Set<Int>()
        beers = (block("verified") + block("items") + block("unverified"))
            .compactMap(\.beer)
            .filter { seen.insert($0.bid).inserted }
    }
}

// MARK: - Venues

struct Venue: Codable, Hashable, Identifiable {
    /// Untappd venue id. Missing for Foursquare-only search results.
    var venueId: Int?
    var foursquareId: String?
    var name: String
    var category: String?
    var address: String?
    var city: String?
    var state: String?
    var lat: Double?
    var lng: Double?
    var isVerified: Bool
    var icon: URL?
    /// Distance in metres from wherever the containing query was made, if the API told us.
    var reportedDistance: Double?
    var isCustom: Bool = false
    /// Untappd's popularity score, from /venue/map. Not persisted.
    var popularity: Int?

    static let atHome = Venue(
        venueId: 9_917_985,
        foursquareId: "5e7b4d99c91df60008e8b168",
        name: "Untappd at Home",
        isVerified: false,
        isCustom: true
    )

    init(venueId: Int? = nil, foursquareId: String? = nil, name: String, category: String? = nil,
         address: String? = nil, city: String? = nil, state: String? = nil, lat: Double? = nil, lng: Double? = nil,
         isVerified: Bool = false, icon: URL? = nil, reportedDistance: Double? = nil, isCustom: Bool = false,
         popularity: Int? = nil) {
        self.venueId = venueId
        self.foursquareId = foursquareId
        self.name = name
        self.category = category
        self.address = address
        self.city = city
        self.state = state
        self.lat = lat
        self.lng = lng
        self.isVerified = isVerified
        self.icon = icon
        self.reportedDistance = reportedDistance
        self.isCustom = isCustom
        self.popularity = popularity
    }

    /// Whether a Foursquare-only result looks like somewhere you'd drink a beer.
    var looksLikeDrinkingPlace: Bool {
        guard let c = category?.lowercased() else { return false }
        return ["bar", "pub", "brew", "beer", "liquor", "bottle", "wine", "tavern", "hotel", "restaurant", "bistro",
                "café", "cafe", "club", "taproom", "lounge", "dining", "drinking", "food", "eatery", "inn"]
            .contains { c.contains($0) }
    }

    var id: String { venueId.map { "u\($0)" } ?? "f\(foursquareId ?? name)" }

    var coordinate: CLLocation? {
        guard let lat, let lng, lat != 0 || lng != 0 else { return nil }
        return CLLocation(latitude: lat, longitude: lng)
    }

    var subtitle: String {
        [category, address ?? city].compactMap { $0 }.joined(separator: " · ")
    }

    func distance(from loc: CLLocation?) -> Double? {
        guard let loc, let c = coordinate else { return nil }
        return c.distance(from: loc)
    }

    /// Fills in identifiers learned from another sighting of the same venue.
    mutating func merge(_ other: Venue) {
        venueId = venueId ?? other.venueId
        foursquareId = foursquareId ?? other.foursquareId
        category = category ?? other.category
        address = address ?? other.address
        city = city ?? other.city
        lat = lat ?? other.lat
        lng = lng ?? other.lng
        icon = icon ?? other.icon
        isVerified = isVerified || other.isVerified
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        venueId = c.int("venue_id")
        name = c.string("venue_name") ?? ""
        guard venueId != nil || !name.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "empty venue"))
        }
        foursquareId = c.nested("foursquare")?.text("foursquare_id")
        let cats: [Category] = c.items("categories")
        category = c.text("primary_category") ?? c.text("primary_category_en")
            ?? (cats.first(where: \.isPrimary) ?? cats.first)?.name
        if let l = c.nested("location") {
            address = l.text("venue_address")
            city = l.text("venue_city")
            state = l.text("venue_state")
            lat = l.double("lat")
            lng = l.double("lng")
        }
        isVerified = c.bool("is_verified") ?? false
        icon = (c.nested("venue_icon")?.text("md")).flatMap(URL.init(string:))
        // Distances from /venue/around are in km when dist_pref=m.
        reportedDistance = c.double("distance").map { $0 * 1000 }
        isCustom = c.bool("is_custom_venue") ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encodeIfPresent(venueId, forKey: AnyKey("venue_id"))
        try c.encode(name, forKey: AnyKey("venue_name"))
        try c.encodeIfPresent(category, forKey: AnyKey("primary_category"))
        try c.encode(isVerified, forKey: AnyKey("is_verified"))
        try c.encode(isCustom, forKey: AnyKey("is_custom_venue"))
        var l = c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("location"))
        try l.encodeIfPresent(address, forKey: AnyKey("venue_address"))
        try l.encodeIfPresent(city, forKey: AnyKey("venue_city"))
        try l.encodeIfPresent(state, forKey: AnyKey("venue_state"))
        try l.encodeIfPresent(lat, forKey: AnyKey("lat"))
        try l.encodeIfPresent(lng, forKey: AnyKey("lng"))
        if let foursquareId {
            var f = c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("foursquare"))
            try f.encode(foursquareId, forKey: AnyKey("foursquare_id"))
        }
        if let icon {
            var i = c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("venue_icon"))
            try i.encode(icon.absoluteString, forKey: AnyKey("md"))
        }
    }

    private struct Category: Decodable {
        var name: String?
        var isPrimary: Bool
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            name = c.text("category_name") ?? c.text("category_name_en")
            isPrimary = c.bool("is_primary") ?? false
        }
    }
}

// MARK: - Checkins

struct Checkin: Decodable, Hashable, Identifiable {
    var id: Int
    var createdAt: Date?
    var rating: Double?
    var comment: String?
    var user: User?
    var beer: BeerRef?
    var brewery: BreweryRef?
    var venue: Venue?
    var toastCount: Int
    var toasters: [User]
    var youToasted: Bool
    var commentCount: Int
    var photo: Photo?
    var taggedFriends: [User]
    var comments: [Comment]
    var flavors: [String]
    var badges: [Badge]
    var servingType: String?

    struct Photo: Hashable {
        var small: URL?
        var medium: URL?
        var large: URL?
    }

    struct Comment: Decodable, Hashable, Identifiable {
        var id: Int
        var user: User?
        var text: String
        var createdAt: Date?
        /// Whether the signed-in user may delete this comment (`comment_owner`).
        var canDelete: Bool?
        /// Whether the signed-in user may edit this comment (`comment_editor`).
        var canEdit: Bool?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.int("comment_id") ?? 0
            user = c.obj("user")
            text = c.string("comment") ?? ""
            createdAt = UntappdDate.parse(c.string("created_at"))
            canDelete = c.bool("comment_owner")
            canEdit = c.bool("comment_editor")
        }
    }

    struct Badge: Decodable, Hashable, Identifiable {
        var id: Int
        var name: String
        var image: URL?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.int("user_badge_id") ?? c.int("badge_id") ?? 0
            name = c.string("badge_name") ?? ""
            image = (c.nested("badge_image")?.text("md") ?? c.nested("badge_image")?.text("sm")).flatMap(URL.init(string:))
        }
    }

    var beerLite: BeerLite? { beer.map { BeerLite(beer: $0, brewery: brewery) } }

    static func == (a: Checkin, b: Checkin) -> Bool {
        a.id == b.id && a.toastCount == b.toastCount && a.youToasted == b.youToasted
            && a.rating == b.rating && a.comment == b.comment && a.servingType == b.servingType
    }
    func hash(into h: inout Hasher) { h.combine(id) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.int("checkin_id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no checkin_id"))
        }
        self.id = id
        createdAt = UntappdDate.parse(c.string("created_at"))
        rating = c.double("rating_score").flatMap { $0 > 0 ? $0 : nil }
        comment = c.text("checkin_comment")
        user = c.obj("user")
        beer = c.obj("beer")
        brewery = c.obj("brewery")
        venue = c.obj("venue")  // `[]` when there's no venue; obj() returns nil.

        let toasts = c.nested("toasts")
        toastCount = toasts?.int("total_count") ?? toasts?.int("count") ?? 0
        youToasted = toasts?.bool("auth_toast") ?? false
        toasters = (toasts?.list("items", ToastItem.self) ?? []).compactMap(\.user)

        commentCount = c.nested("comments")?.int("total_count") ?? 0

        photo = c.items("media", MediaItem.self).first?.photo
        taggedFriends = c.items("friend_tags", TagItem.self).compactMap(\.user)
        comments = c.items("comments")
        flavors = c.items("flavor_profile", Flavor.self).compactMap(\.name)
        badges = c.items("badges")
        // Only seen empty in captures; accept serving-type objects, arrays or plain strings.
        servingType = c.obj("serving_types", Flavor.self)?.name
            ?? c.items("serving_types", Flavor.self).first?.name
            ?? c.list("serving_types", Flavor.self).first?.name
            ?? c.obj("serving_type", Flavor.self)?.name
            ?? c.items("serving_type", Flavor.self).first?.name
            ?? c.list("serving_type", Flavor.self).first?.name
    }

    private struct Flavor: Decodable {
        var name: String?
        init(from decoder: Decoder) throws {
            if let s = (try? decoder.singleValueContainer().decode(String.self))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                name = s
                return
            }
            let c = try decoder.container(keyedBy: AnyKey.self)
            name = c.text("tag_name") ?? c.text("container_name") ?? c.text("serving_type")
                ?? c.text("serving_name") ?? c.text("serving_type_name") ?? c.text("type_name") ?? c.text("name")
        }
    }

    private struct ToastItem: Decodable { var user: User? }
    private struct TagItem: Decodable { var user: User? }
    private struct MediaItem: Decodable {
        var photo: Photo?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let p = c.nested("photo") else { photo = nil; return }
            func u(_ k: String) -> URL? { p.text(k).flatMap(URL.init(string:)) }
            photo = Photo(small: u("photo_img_sm"), medium: u("photo_img_md"), large: u("photo_img_lg") ?? u("photo_img_og"))
        }
    }
}

struct CheckinView: Decodable {
    var checkin: Checkin?
}

/// The response to adding or deleting a comment: the checkin's comments afterwards.
struct CommentList: Decodable {
    var comments: [Checkin.Comment]
    var totalCount: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        comments = c.items("comments")
        totalCount = c.nested("comments")?.int("total_count") ?? comments.count
    }
}

/// The response to editing a comment.
struct EditedComment: Decodable {
    var comment: Checkin.Comment?
}

struct ServingType: Decodable, Hashable, Identifiable {
    var id: Int
    var name: String
    var position: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.int("container_id") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no container_id"))
        }
        self.id = id
        name = c.string("container_name") ?? ""
        position = c.int("container_position") ?? id
    }
}

struct ServingTypes: Decodable {
    var items: [ServingType]
    init(from decoder: Decoder) throws {
        items = try decoder.container(keyedBy: AnyKey.self).list("items")
    }
}

/// `/v4/user/friends` and `/v4/user/recently_tagged` both wrap users as `items[].user`.
struct UserList: Decodable {
    var users: [User]
    var found: Int?

    private struct Item: Decodable { var user: User? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        users = c.list("items", Item.self).compactMap(\.user)
        found = c.int("found")
    }
}

struct CheckinPage: Decodable {
    var checkins: [Checkin]
    var nextMaxId: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        checkins = c.items("checkins")
        nextMaxId = c.nested("pagination")?.int("max_id")
    }
}

// MARK: - Venue endpoints

struct VenueAround: Decodable {
    var lat: Double?
    var lng: Double?
    var recent: [Venue]
    var nearby: [Venue]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        lat = c.nested("location")?.double("lat")
        lng = c.nested("location")?.double("lng")
        recent = c.items("recent")
        nearby = c.items("foursquare")
    }
}

struct VenueMap: Decodable {
    var centerLat: Double?
    var centerLng: Double?
    var venues: [Venue]

    private struct Item: Decodable {
        var venue: Venue?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            venue = c.obj("venue")
            venue?.popularity = c.int("popularity_score")
            if venue?.reportedDistance == nil { venue?.reportedDistance = c.double("distance").map { $0 * 1000 } }
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        venues = c.items("venues", Item.self).compactMap(\.venue)
        if let b = c.nested("bounds"), let ne = b.obj("ne", [Double].self), let sw = b.obj("sw", [Double].self),
           ne.count == 2, sw.count == 2 {
            centerLat = (ne[0] + sw[0]) / 2
            centerLng = (ne[1] + sw[1]) / 2
        }
    }
}

struct VenueInfo: Decodable {
    var venue: Venue?
    /// Beers currently listed at the venue, with tap numbers where the venue sets them.
    var onTap: [TapItem]

    struct TapItem: Decodable {
        var beer: BeerLite?
        var tapNumber: String?
        var addedAt: Date?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            tapNumber = c.text("tap_number").flatMap { $0 == "0" ? nil : $0 }  // "0" means unset
            addedAt = UntappdDate.parse(c.string("created_at"))
            if let b: BeerRef = c.obj("beer"), b.bid > 0 {
                beer = BeerLite(beer: b, brewery: c.obj("brewery"))
                beer?.rating = c.nested("beer")?.double("rating_score")
            }
        }
    }

    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: AnyKey.self).nested("venue")
        venue = try? decoder.container(keyedBy: AnyKey.self).obj("venue")
        onTap = v?.items("recently_added") ?? []
    }
}

struct MenuSections: Decodable {
    var sections: [Section]

    struct Section: Decodable, Identifiable {
        var id: Int
        var menuName: String?
        var name: String?
        var items: [Item]

        /// Section heading, leaving out a menu name that's just the venue's name again.
        func title(venueName: String? = nil) -> String {
            let m = menuName == venueName ? nil : menuName
            switch (m, name) {
            case let (m?, n?) where m != n: return "\(m) · \(n)"
            case let (m, n): return n ?? m ?? "Menu"
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.int("section_id") ?? 0
            menuName = c.text("menu_name")
            name = c.text("section_name")
            items = c.list("items")
        }
    }

    struct Item: Decodable, Identifiable {
        var id: Int
        var beer: BeerLite?
        var tapNumber: String?
        var position: Int?

        /// The number shown on the venue's menu: its tap number, else its 1-based menu position.
        var menuNumber: String? { tapNumber ?? position.map { "\($0 + 1)" } }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.int("id") ?? 0
            tapNumber = c.text("tap_number").flatMap { $0 == "0" ? nil : $0 }
            position = c.int("position")
            if let bid = c.int("untappd_id"), bid > 0 {
                beer = BeerLite(
                    bid: bid,
                    name: c.text("name") ?? c.text("original_name") ?? "",
                    brewery: c.text("brewery") ?? c.text("original_brewery") ?? "",
                    style: c.text("style") ?? c.text("short_style"),
                    abv: c.double("abv"),
                    // Menu items' brewery logo field hasn't been captured, so they fall back
                    // straight to the placeholder.
                    label: (c.text("label_image") ?? c.text("label_image_thumb")).flatMap(URL.init(string:)),
                    rating: c.double("rating"),
                    ratingCount: c.int("rating_count"),
                    hasHad: c.bool("has_had"))
            }
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        sections = c.list("sections")
    }
}

// MARK: - Login & profile

struct XAuthResponse: Decodable {
    var accessToken: String?
    var username: String?
    var twoFactor: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        accessToken = c.text("access_token")
        username = c.text("username")
        twoFactor = c.bool("two_factor_enabled") ?? false
    }
}

struct UserInfo: Decodable {
    var user: Profile?

    struct Profile: Decodable {
        var id: Int
        var firstName: String?
        var lastName: String?
        var userName: String
        var displayName: String
        var avatar: URL?
        var location: String?
        var totalCheckins: Int?
        var totalBeers: Int?
        var totalBadges: Int?
        var totalFriends: Int?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.int("uid") ?? c.int("id") ?? 0
            firstName = c.text("first_name")
            lastName = c.text("last_name")
            userName = c.string("user_name") ?? ""
            let full = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
            displayName = full.isEmpty ? userName : full
            avatar = (c.text("user_avatar_hd") ?? c.text("user_avatar")).flatMap(URL.init(string:))
            location = c.text("location")
            let s = c.nested("stats")
            totalCheckins = s?.int("total_checkins")
            totalBeers = s?.int("total_beers")
            totalBadges = s?.int("total_badges")
            totalFriends = s?.int("total_friends")
        }
    }
}

extension UserInfo.Profile {
    var asUser: User {
        User(id: id, userName: userName, firstName: firstName, lastName: lastName, avatar: avatar)
    }
}

/// The response to `checkin/add` and `checkin/edit`.
struct CheckinAddResponse: Decodable {
    var result: String?
    var checkinId: Int?
    /// With `is_photo=true`: a presigned S3 URL (valid for 120 seconds) to PUT the photo to.
    var photoUploadURL: URL?
    /// Where the uploaded photo will then be served from.
    var photoDestinationURL: URL?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        result = c.text("result")
        checkinId = c.int("checkin_id")
        let upload = c.nested("photo_upload")
        photoUploadURL = upload?.text("url").flatMap(URL.init(string:))
        photoDestinationURL = upload?.text("destination_url").flatMap(URL.init(string:))
    }
}

// MARK: - Algolia

struct AlgoliaBeerHits: Decodable {
    var hits: [BeerLite]

    private struct Hit: Decodable {
        var beer: BeerLite?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let bid = c.int("bid") else { beer = nil; return }
            beer = BeerLite(
                bid: bid, name: c.string("beer_name") ?? "", brewery: c.string("brewery_name") ?? "",
                style: c.text("type_name"), abv: c.double("beer_abv"),
                label: c.text("beer_label").flatMap(URL.init(string:)),
                rating: c.double("rating_score"), ratingCount: c.int("rating_count"),
                popularity: c.int("popularity"),
                breweryLabel: c.text("brewery_label").flatMap(URL.init(string:)))
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        hits = c.list("hits", Hit.self).compactMap(\.beer)
    }
}

// MARK: - Account settings

/// The parts of `/v4/account/usersettings` that the API lets us change.
struct AccountSettings: Decodable {
    var isPrivate: Bool
    var isSearchable: Bool
    var publicToasts: Bool
    var ocOptOut: Bool
    var ratingBump: Bool
    var retroactiveBadges: Bool
    var emailAddress: String?

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: AnyKey.self)
        let u = root.nested("user") ?? root
        let s = u.nested("settings")
        isPrivate = u.bool("is_private") ?? false
        isSearchable = s?.bool("is_search") ?? true
        publicToasts = s?.bool("public_toasts") ?? true
        ocOptOut = s?.bool("is_oc_opt") ?? false
        ratingBump = u.bool("rating_bump") ?? false
        retroactiveBadges = u.bool("retro_status") ?? false
        emailAddress = s?.text("email_address")
    }
}

/// A parent style (Non-Alcoholic, Hard Seltzer, …) that can be hidden from menus and recommendations.
struct ParentStyleOptOut: Decodable, Identifiable {
    var id: Int
    var name: String
    var description: String?
    var isEnabled: Bool
    var isLocked: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.int("parent_id") else { throw APIError.decoding }
        self.id = id
        name = c.text("parent_name") ?? "Style \(id)"
        description = c.text("description")
        isEnabled = c.bool("is_enabled") ?? true
        isLocked = c.bool("is_locked") ?? false
    }
}
