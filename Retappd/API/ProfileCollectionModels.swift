import Foundation

// MARK: - Shared collection helpers

/// One entry in `sorting_options` returned by `/v4/user/beers`, `/v4/user/badges` and `/v4/user/venues`.
struct CollectionSortOption: Decodable, Hashable, Identifiable {
    var key: String
    var name: String
    var id: String { key }

    init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let key = c.text("sort_key"), let name = c.text("sort_name") else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "invalid sort option"))
        }
        self.key = key
        self.name = name
    }
}

/// Offset pagination from `response.pagination` (`next_url` + `offset`).
struct CollectionPagination: Decodable, Equatable {
    var nextURL: String?
    var nextOffset: Int?

    var hasMore: Bool {
        if let url = nextURL, !url.isEmpty { return true }
        return false
    }

    init(nextURL: String? = nil, nextOffset: Int? = nil) {
        self.nextURL = nextURL
        self.nextOffset = nextOffset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        nextURL = c.text("next_url")
        nextOffset = c.int("offset")
    }
}

// MARK: - Unique beers (`GET /v4/user/beers/{username}`)

struct UserBeersPage: Decodable {
    var totalCount: Int
    var items: [UserBeerItem]
    var sortKey: String?
    var sortName: String?
    var sortingOptions: [CollectionSortOption]
    var pagination: CollectionPagination

    init(totalCount: Int, items: [UserBeerItem], sortKey: String? = nil, sortName: String? = nil,
         sortingOptions: [CollectionSortOption] = [], pagination: CollectionPagination = .init()) {
        self.totalCount = totalCount
        self.items = items
        self.sortKey = sortKey
        self.sortName = sortName
        self.sortingOptions = sortingOptions
        self.pagination = pagination
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        items = c.items("beers")
        totalCount = c.int("total_count") ?? items.count
        sortKey = c.text("sort_key") ?? c.text("sort")
        sortName = c.text("sort_name")
        sortingOptions = c.list("sorting_options")
        pagination = c.obj("pagination") ?? CollectionPagination()
    }
}

struct UserBeerItem: Decodable, Hashable, Identifiable {
    var beer: BeerRef
    var brewery: BreweryRef?
    /// This profile user's rating of the beer; nil if unrated (API sends 0).
    var userRating: Double?
    /// The signed-in user's own rating when viewing someone else's beers; nil if unrated.
    var authUserRating: Double?
    /// Global community rating from the nested `beer` object; nil if unrated.
    var globalRating: Double?
    var globalRatingCount: Int?
    /// How many times this profile user has checked in this beer.
    var checkinCount: Int
    var firstCreatedAt: Date?
    var recentCreatedAt: Date?
    var recentCheckinId: Int?

    var id: Int { beer.bid }

    init(beer: BeerRef, brewery: BreweryRef? = nil, userRating: Double? = nil, authUserRating: Double? = nil,
         globalRating: Double? = nil, globalRatingCount: Int? = nil, checkinCount: Int = 1,
         firstCreatedAt: Date? = nil, recentCreatedAt: Date? = nil, recentCheckinId: Int? = nil) {
        self.beer = beer
        self.brewery = brewery
        self.userRating = userRating
        self.authUserRating = authUserRating
        self.globalRating = globalRating
        self.globalRatingCount = globalRatingCount
        self.checkinCount = checkinCount
        self.firstCreatedAt = firstCreatedAt
        self.recentCreatedAt = recentCreatedAt
        self.recentCheckinId = recentCheckinId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let beer = c.obj("beer", BeerRef.self), beer.bid != 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "no beer"))
        }
        self.beer = beer
        brewery = c.obj("brewery", BreweryRef.self)
        userRating = c.double("rating_score").flatMap { $0 > 0 ? $0 : nil }
        authUserRating = c.double("user_auth_rating_score").flatMap { $0 > 0 ? $0 : nil }
        let beerContainer = c.nested("beer")
        globalRating = beerContainer?.double("rating_score").flatMap { $0 > 0 ? $0 : nil }
        globalRatingCount = beerContainer?.int("rating_count")
        checkinCount = c.int("count") ?? 1
        firstCreatedAt = UntappdDate.parse(c.string("first_created_at") ?? c.string("first_had"))
        recentCreatedAt = UntappdDate.parse(c.string("recent_created_at"))
        recentCheckinId = c.int("recent_checkin_id")
    }

    var beerLite: BeerLite {
        var lite = BeerLite(beer: beer, brewery: brewery)
        lite.rating = globalRating
        lite.ratingCount = globalRatingCount
        return lite
    }
}

// MARK: - Badges (`GET /v4/user/badges/{username}`)

/// The four badge categories returned by `GET /v4/user/badges/{username}`.
enum UserBadgeSegment: String, CaseIterable, Hashable, Identifiable {
    case beer
    case venue
    case special
    case localBadges = "local_badges"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .beer: "Beer"
        case .venue: "Venue"
        case .special: "Special"
        case .localBadges: "Local"
        }
    }
}

struct UserBadgesIndex: Decodable {
    struct CategoryStat: Decodable, Equatable {
        var userCount: Int
        var totalCount: Int?

        init(userCount: Int, totalCount: Int? = nil) {
            self.userCount = userCount
            self.totalCount = totalCount
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            userCount = c.int("total_user_count") ?? 0
            totalCount = c.int("total_count")
        }
    }

    var stats: [UserBadgeSegment: CategoryStat]
    var previews: [UserBadgeSegment: [UserBadgeItem]]

    var totalEarned: Int {
        stats.values.reduce(0) { $0 + $1.userCount }
    }

    init(stats: [UserBadgeSegment: CategoryStat] = [:], previews: [UserBadgeSegment: [UserBadgeItem]] = [:]) {
        self.stats = stats
        self.previews = previews
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var parsedStats: [UserBadgeSegment: CategoryStat] = [:]
        var parsedPreviews: [UserBadgeSegment: [UserBadgeItem]] = [:]
        let statsContainer = c.nested("stats")
        for segment in UserBadgeSegment.allCases {
            if let s = statsContainer?.obj(segment.rawValue, CategoryStat.self) {
                parsedStats[segment] = s
            }
            let items: [UserBadgeItem] = c.items(segment.rawValue)
            if !items.isEmpty { parsedPreviews[segment] = items }
        }
        stats = parsedStats
        previews = parsedPreviews
    }
}

struct UserBadgesPage: Decodable {
    var segment: UserBadgeSegment?
    var sortKey: String?
    var offset: Int
    var limit: Int
    var count: Int
    var items: [UserBadgeItem]
    var sortingOptions: [CollectionSortOption]

    init(segment: UserBadgeSegment? = nil, sortKey: String? = nil, offset: Int = 0, limit: Int = 25,
         count: Int? = nil, items: [UserBadgeItem], sortingOptions: [CollectionSortOption] = []) {
        self.segment = segment
        self.sortKey = sortKey
        self.offset = offset
        self.limit = limit
        self.count = count ?? items.count
        self.items = items
        self.sortingOptions = sortingOptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        segment = c.text("segment").flatMap(UserBadgeSegment.init(rawValue:))
        sortKey = c.text("sort_key") ?? c.text("sort")
        offset = c.int("offset") ?? 0
        limit = c.int("limit") ?? 25
        let badgesContainer = c.nested("badges")
        items = badgesContainer?.list("items") ?? []
        count = badgesContainer?.int("count") ?? items.count
        sortingOptions = c.list("sorting_options")
    }
}

struct UserBadgeItem: Decodable, Hashable, Identifiable {
    var userBadgeId: Int?
    var badgeId: Int
    var checkinId: Int?
    var name: String
    var description: String?
    var hint: String?
    var image: URL?
    var largeImage: URL?
    var earnedAt: Date?
    var createdAt: Date?
    var isLevel: Bool
    var hasBadge: Bool
    var categoryId: Int?
    var levelStatus: Int?
    var maxLevels: Int?

    /// Unique across both earned badges (`userBadgeId`) and locked badges (`badgeId`).
    var id: Int { userBadgeId ?? badgeId }

    /// The badge's level, from `level_status` or parsed from `"(Level N)"` in its name.
    var level: Int? {
        if let levelStatus, levelStatus > 0 { return levelStatus }
        return BadgeName.level(of: name)
    }

    var baseName: String { BadgeName.base(of: name) }

    /// Converts into `Checkin.Badge` for pushing the existing `BadgeView`.
    var asCheckinBadge: Checkin.Badge {
        Checkin.Badge(
            id: id,
            badgeId: badgeId,
            userBadgeId: userBadgeId,
            name: name,
            description: description,
            image: image,
            largeImage: largeImage
        )
    }

    init(userBadgeId: Int? = nil, badgeId: Int, checkinId: Int? = nil, name: String,
         description: String? = nil, hint: String? = nil, image: URL? = nil, largeImage: URL? = nil,
         earnedAt: Date? = nil, createdAt: Date? = nil, isLevel: Bool = false, hasBadge: Bool = true,
         categoryId: Int? = nil, levelStatus: Int? = nil, maxLevels: Int? = nil) {
        self.userBadgeId = userBadgeId
        self.badgeId = badgeId
        self.checkinId = checkinId
        self.name = name
        self.description = description
        self.hint = hint
        self.image = image
        self.largeImage = largeImage
        self.earnedAt = earnedAt
        self.createdAt = createdAt
        self.isLevel = isLevel
        self.hasBadge = hasBadge
        self.categoryId = categoryId
        self.levelStatus = levelStatus
        self.maxLevels = maxLevels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let badgeId = c.int("badge_id"), badgeId > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "no badge_id"))
        }
        self.badgeId = badgeId
        userBadgeId = c.int("user_badge_id").flatMap { $0 > 0 ? $0 : nil }
        checkinId = c.int("checkin_id").flatMap { $0 > 0 ? $0 : nil }
        name = c.string("badge_name") ?? ""
        description = c.text("badge_description")
        hint = c.text("badge_hint")
        let media = c.nested("media")
        let legacyImg = c.nested("badge_image")
        image = media?.url("badge_image_md") ?? media?.url("badge_image_sm")
            ?? legacyImg?.url("md") ?? legacyImg?.url("sm")
        largeImage = media?.url("badge_image_lg") ?? legacyImg?.url("lg")
        earnedAt = UntappdDate.parse(c.string("earned_at"))
        createdAt = UntappdDate.parse(c.string("created_at"))
        isLevel = c.bool("is_level") ?? false
        hasBadge = c.bool("has_badge") ?? (userBadgeId != nil || earnedAt != nil)
        categoryId = c.int("category_id")
        levelStatus = c.int("level_status").flatMap { $0 > 0 ? $0 : nil }
        maxLevels = c.int("max_levels").flatMap { $0 > 0 ? $0 : nil }
    }
}

// MARK: - Venues (`GET /v4/user/venues/{username}`)

struct UserVenuesPage: Decodable {
    var totalCount: Int
    var items: [UserVenueItem]
    var sortKey: String?
    var sortName: String?
    var sortingOptions: [CollectionSortOption]
    var pagination: CollectionPagination

    init(totalCount: Int, items: [UserVenueItem], sortKey: String? = nil, sortName: String? = nil,
         sortingOptions: [CollectionSortOption] = [], pagination: CollectionPagination = .init()) {
        self.totalCount = totalCount
        self.items = items
        self.sortKey = sortKey
        self.sortName = sortName
        self.sortingOptions = sortingOptions
        self.pagination = pagination
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        items = c.items("venues")
        totalCount = c.int("total_count") ?? items.count
        sortKey = c.text("sort_key") ?? c.text("sort")
        sortName = c.text("sort_name")
        sortingOptions = c.list("sorting_options")
        pagination = c.obj("pagination") ?? CollectionPagination()
    }
}

struct UserVenueItem: Decodable, Hashable, Identifiable {
    var venue: Venue
    var visitCount: Int
    var recentVisit: Date?
    var firstVisit: Date?
    var recentCheckinId: Int?

    var id: String { venue.id }

    init(venue: Venue, visitCount: Int = 1, recentVisit: Date? = nil, firstVisit: Date? = nil,
         recentCheckinId: Int? = nil) {
        self.venue = venue
        self.visitCount = visitCount
        self.recentVisit = recentVisit
        self.firstVisit = firstVisit
        self.recentCheckinId = recentCheckinId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let venue = c.obj("venue", Venue.self) else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "no venue"))
        }
        self.venue = venue
        visitCount = c.int("total_count") ?? 1
        recentVisit = UntappdDate.parse(c.string("recent_visit"))
        firstVisit = UntappdDate.parse(c.string("first_visit"))
        recentCheckinId = c.int("recent_checkin_id")
    }
}
