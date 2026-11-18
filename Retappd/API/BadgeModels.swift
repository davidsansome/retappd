import Foundation

/// `GET /v5/badges/status`: the signed-in user's progress on each badge asked about.
struct BadgeStatusList: Decodable {
    /// What the user has on one badge.
    ///
    /// What `level` and `total` count isn't documented (API.md says "isn't confirmed"), so this is
    /// partly a guess. What's known: for a one-off badge both are 1 (the test account's Newbie,
    /// checked live), and the docs' captures of one badge show 152 / 155, then 166 / 170 months
    /// later, so `total` is at least `level` and both grow. Our guess is that `level` is the level
    /// reached, as in the "(Level N)" of a level badge's name, but no capture pairs the two and the
    /// test accounts have no level badges. `total` might be how many times the badge was awarded
    /// (each level is its own award), or something else entirely, so the app doesn't show it.
    struct Status: Decodable, Hashable {
        var level: Int
        var total: Int
        var userBadgeId: Int?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            level = c.int("level") ?? 0
            total = c.int("total") ?? level
            userBadgeId = c.int("user_badge_id")
        }
    }

    /// By badge id. A badge the user doesn't have is `null` in the response and absent here.
    var statuses: [Int: Status]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var result: [Int: Status] = [:]
        if let map = c.nested("badge_statuses") {
            for key in map.allKeys {
                if let id = Int(key.stringValue), let s = map.obj(key.stringValue, Status.self) { result[id] = s }
            }
        }
        statuses = result
    }
}

/// `GET /v4/badges/friends_badges/{badge_id}`: one page of the signed-in user's friends who have a
/// badge. For a level badge (`is_parent`) it lists friends with any level of it, `current_level`
/// saying which; for a one-off badge `current_level` is 0.
struct FriendBadgeList: Decodable {
    struct Entry: Decodable, Hashable, Identifiable {
        var user: User
        /// The friend's level; nil for a one-off badge (the API sends 0).
        var level: Int?
        var earnedAt: Date?
        var userBadgeId: Int?
        var id: String { user.userName }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let u = c.obj("user", User.self), !u.userName.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "no user"))
            }
            user = u
            level = c.int("current_level").flatMap { $0 > 0 ? $0 : nil }
            earnedAt = UntappdDate.parse(c.string("created_at"))
            userBadgeId = c.int("user_badge_id").flatMap { $0 > 0 ? $0 : nil }
        }
    }

    var items: [Entry]
    /// The number of entries in this page (not the total), so a full page means there may be more.
    var count: Int
    var isParent: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        items = c.list("items")
        count = c.int("count") ?? items.count
        isParent = c.bool("is_parent") ?? false
    }
}

/// Level badges carry their level in their name: "The Backpacker (Level 28)".
enum BadgeName {
    private static let suffix = #/\s*\(Level (\d+)\)\s*$/#

    /// The level in the name, if there is one.
    static func level(of name: String) -> Int? {
        name.firstMatch(of: suffix).flatMap { Int($0.1) }
    }

    /// The name without its level: "The Backpacker".
    static func base(of name: String) -> String {
        guard let m = name.firstMatch(of: suffix) else { return name }
        let base = String(name[..<m.range.lowerBound])
        return base.isEmpty ? name : base
    }
}
