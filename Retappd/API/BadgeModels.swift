import Foundation

/// `GET /v5/badges/status`: the signed-in user's progress on each badge asked about.
struct BadgeStatusList: Decodable {
    /// What the user has on one badge.
    struct Status: Decodable, Hashable {
        var level: Int
        /// How `total` differs from `level` isn't documented; see `BadgeView`.
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
