import Foundation
import Observation
import UIKit
import UserNotifications

/// Whether there is anything new for the Activity tab's bell to point at, and what the user has
/// already seen on the Notifications screen.
///
/// Untappd's own unread counts (every response's envelope) are usually reset by the push relay,
/// which reads the feed to build its pushes, so they can't be the only signal. The bell is lit by
/// any of: unread comments, toasts or tags in the envelope; the app icon's badge; or a pending
/// friend request that arrived after the user last opened the screen. Opening the screen
/// (`markSeen`) stores the newest `created_at` it showed per username, clears the icon badge, and
/// zeroes the counts, which reading the feed has just reset on the server. Delivered notifications
/// in Notification Centre are left alone.
@Observable @MainActor
final class NotificationUnread {
    let username: String
    /// Newest activity (a notification or friend request) the user has seen.
    private(set) var lastSeen: Date?
    /// Unread comments, toasts and tags according to the latest envelope.
    private(set) var activity = 0
    /// Incoming friend requests, as last loaded.
    private(set) var requests: [Friend] = []
    private(set) var iconBadge = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loadRequests: @MainActor () async -> [Friend]
    @ObservationIgnored private let readIconBadge: @MainActor () -> Int
    @ObservationIgnored private let clearIconBadge: @MainActor () async -> Void

    init(username: String,
         defaults: UserDefaults = .standard,
         loadRequests: @escaping @MainActor () async -> [Friend] = {
             await CheckInOptions.shared.loadRequests()
             return CheckInOptions.shared.requests
         },
         // There's no non-deprecated way to read the badge (`setBadgeCount` only writes it).
         readIconBadge: @escaping @MainActor () -> Int = { UIApplication.shared.applicationIconBadgeNumber },
         clearIconBadge: @escaping @MainActor () async -> Void = {
             try? await UNUserNotificationCenter.current().setBadgeCount(0)
         }) {
        self.username = username
        self.defaults = defaults
        self.loadRequests = loadRequests
        self.readIconBadge = readIconBadge
        self.clearIconBadge = clearIconBadge
        let stored = defaults.double(forKey: Self.key(username))
        lastSeen = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    static func key(_ username: String) -> String { "notifications.lastSeen.\(username.lowercased())" }

    /// Friend requests newer than what the user last saw.
    var unseenRequests: Int {
        requests.filter { r in
            guard let seen = lastSeen, let at = r.createdAt else { return true }
            return at > seen
        }.count
    }

    /// The number on the bell. Zero with `hasUnread` set means a dot only (the icon badge).
    var count: Int { activity + unseenRequests }
    var hasUnread: Bool { count > 0 || iconBadge > 0 }

    /// Takes the counts from an API response's envelope.
    func ingest(_ counts: UnreadCounts) {
        activity = counts.activity
    }

    func setRequests(_ list: [Friend]) { requests = list }

    /// Re-reads what's cheap to read: the icon badge and the pending friend requests (a small
    /// call whose envelope also carries the unread counts). Called when the app comes to the
    /// foreground and when the feed refreshes.
    func refresh() async {
        iconBadge = readIconBadge()
        requests = await loadRequests()
        iconBadge = readIconBadge()
    }

    /// The Notifications screen showed everything up to `newest`. Only moves forward.
    func markSeen(newest: Date?) {
        let candidates = [lastSeen, newest].compactMap { $0 } + requests.compactMap(\.createdAt)
        if let latest = candidates.max(), latest != lastSeen {
            lastSeen = latest
            defaults.set(latest.timeIntervalSince1970, forKey: Self.key(username))
        }
        activity = 0
        iconBadge = 0
        Task { await clearIconBadge() }
    }
}
