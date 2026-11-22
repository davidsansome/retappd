import Foundation
import Observation

/// Where tapping a push notification goes (payload: `retappd` dictionary in the contract).
enum NotificationRoute: Equatable {
    case checkin(Int)
    case friendRequest
    /// The local reminder about check-ins saved for later (`PendingReminders`).
    case pendingCheckins

    init?(userInfo: [AnyHashable: Any]) {
        guard let r = userInfo["retappd"] as? [String: Any], let type = r["type"] as? String else { return nil }
        switch type {
        case "friend_request":
            self = .friendRequest
        case "pending_checkins":
            self = .pendingCheckins
        case "toast", "comment", "tag", "comment_tag":
            let raw = r["checkin_id"]
            guard let id = (raw as? Int) ?? (raw as? NSNumber)?.intValue ?? (raw as? String).flatMap(Int.init) else { return nil }
            self = .checkin(id)
        default:
            return nil
        }
    }
}

/// Holds a tapped notification's route until the signed-in UI is there to act on it, which covers
/// cold launches (the tap arrives before any view exists) and being signed out.
@Observable @MainActor
final class NotificationRouter {
    static let shared = NotificationRouter()
    var pending: NotificationRoute?
}
