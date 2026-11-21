import Foundation

/// One entry of `GET /v4/notifications`: a kind of activity on one checkin. The API aggregates by
/// `(notification_type, checkin_id)`, so there is no id of its own, `users` is newest first and
/// `createdAt` is the newest activity's time. Friend requests aren't in this list (they come from
/// `GET /v4/user/pending`). `commentTag` and `checkinTag` are named in the docs' `includes` but
/// were never produced by the test accounts, so their wording here is a guess.
struct NotificationItem: Decodable, Identifiable, Hashable {
    enum Kind: Hashable {
        case toast, comment
        /// A friend tagged you in their checkin (`checkinFriendTag`, and `checkinTag`).
        case tagged
        /// Someone mentioned you in a comment (`commentTag`).
        case mentioned
        case other(String)

        init(raw: String) {
            switch raw {
            case "toast": self = .toast
            case "comment": self = .comment
            case "checkinFriendTag", "checkinTag": self = .tagged
            case "commentTag": self = .mentioned
            default: self = .other(raw)
            }
        }
    }

    var kind: Kind
    var checkinID: Int
    /// Whether the signed-in user owns the checkin (true for toasts and comments, false for tags).
    var isOwnCheckin: Bool
    var createdAt: Date?
    /// Distinct people behind this item, which can be more than `users` lists.
    var count: Int
    /// Newest first.
    var users: [User]
    var beerName: String?
    var beerLabel: URL?
    var breweryName: String?

    /// `(type, checkin)` is the API's identity for an item.
    var id: String { "\(rawKind)-\(checkinID)" }
    private var rawKind: String {
        switch kind {
        case .toast: "toast"
        case .comment: "comment"
        case .tagged: "tag"
        case .mentioned: "commentTag"
        case .other(let s): s
        }
    }

    init(kind: Kind, checkinID: Int, isOwnCheckin: Bool = true, createdAt: Date? = nil, count: Int? = nil,
         users: [User], beerName: String? = nil, beerLabel: URL? = nil, breweryName: String? = nil) {
        self.kind = kind
        self.checkinID = checkinID
        self.isOwnCheckin = isOwnCheckin
        self.createdAt = createdAt
        self.count = max(count ?? users.count, users.count)
        self.users = users
        self.beerName = beerName
        self.beerLabel = beerLabel
        self.breweryName = breweryName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let raw = c.text("notification_type"), let checkin = c.int("checkin_id") else { throw APIError.decoding }
        let users: [User] = c.list("users", UserEntry.self).map(\.user)
        guard !users.isEmpty else { throw APIError.decoding }
        self.init(
            kind: Kind(raw: raw), checkinID: checkin,
            isOwnCheckin: c.bool("checkin_owner") ?? true,
            createdAt: UntappdDate.parse(c.string("created_at")),
            count: c.int("count"), users: users,
            beerName: c.nested("meta")?.nested("beer")?.text("beer_name"),
            beerLabel: c.nested("meta")?.nested("beer")?.text("beer_label").flatMap(URL.init(string:)),
            breweryName: c.nested("meta")?.nested("brewery")?.text("brewery_name"))
    }

    private struct UserEntry: Decodable {
        let user: User
        init(from decoder: Decoder) throws {
            guard let u: User = try decoder.container(keyedBy: AnyKey.self).obj("user") else { throw APIError.decoding }
            user = u
        }
    }

    // MARK: Wording

    /// "Jamie S", "Jamie S and 1 other", "Jamie S and 2 others".
    var actors: String {
        let first = users.first?.shortName ?? "Someone"
        let others = count - 1
        guard others > 0 else { return first }
        return others == 1 ? "\(first) and 1 other" : "\(first) and \(others.formatted()) others"
    }

    /// What they did, ending with the beer: "toasted your Late Nights III".
    var action: String {
        let beer = beerName
        switch kind {
        case .toast:
            return beer.map { "toasted your \($0)" } ?? "toasted your check-in"
        case .comment:
            if isOwnCheckin { return beer.map { "commented on your \($0)" } ?? "commented on your check-in" }
            return beer.map { "commented on \($0)" } ?? "commented on a check-in"
        case .tagged:
            return beer.map { "tagged you in \($0)" } ?? "tagged you in a check-in"
        case .mentioned:
            return beer.map { "mentioned you in a comment on \($0)" } ?? "mentioned you in a comment"
        case .other:
            return beer.map { "sent you a notification about \($0)" } ?? "sent you a notification"
        }
    }

    /// The whole sentence: "Jamie S and 2 others toasted your Late Nights III".
    var sentence: String { "\(actors) \(action)" }

    /// True when this item has activity newer than `lastSeen`. With nothing seen yet, nothing is
    /// new (there's no way to tell what the user already knew).
    func isNew(since lastSeen: Date?) -> Bool {
        guard let lastSeen, let createdAt else { return false }
        return createdAt > lastSeen
    }
}

/// `GET /v4/notifications`: `response.notifications.items` and `response.pagination.next_url`.
struct NotificationPage: Decodable {
    var items: [NotificationItem]
    /// How many entries the server sent, including any this app couldn't read: the next page's
    /// `offset` advances by this.
    var rawCount: Int
    var hasMore: Bool

    init(items: [NotificationItem], rawCount: Int? = nil, hasMore: Bool) {
        self.items = items
        self.rawCount = rawCount ?? items.count
        self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let n = c.nested("notifications")
        items = n?.list("items", NotificationItem.self) ?? []
        rawCount = n?.obj("items", [Skipped].self)?.count ?? items.count
        // `next_url` is filled whenever a page came back full, and empty on the last.
        hasMore = !(c.nested("pagination")?.text("next_url") ?? "").isEmpty
    }

    private struct Skipped: Decodable { init(from decoder: Decoder) throws {} }
}
