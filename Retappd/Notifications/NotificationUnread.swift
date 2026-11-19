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
    @ObservationIgnored private let loadRequests: @MainActor () async throws -> [Friend]
    @ObservationIgnored private let sequence: @MainActor () -> Int
    /// Counts from requests that started at or before this are older than the last `markSeen`.
    private var clearedAt = 0
    /// The newest request whose counts have been applied.
    private var appliedAt = 0
    @ObservationIgnored private let readIconBadge: @MainActor () -> Int
    @ObservationIgnored private let clearIconBadge: @MainActor () async -> Void

    init(username: String,
         defaults: UserDefaults = .standard,
         loadRequests: @escaping @MainActor () async throws -> [Friend] = {
             try await UntappdAPI.shared.fetch(.pendingFriendRequests, as: PendingRequestList.self).requests
         },
         sequence: @escaping @MainActor () -> Int = { UntappdAPI.shared.currentSequence },
         // There's no non-deprecated way to read the badge (`setBadgeCount` only writes it).
         readIconBadge: @escaping @MainActor () -> Int = { UIApplication.shared.applicationIconBadgeNumber },
         clearIconBadge: @escaping @MainActor () async -> Void = {
             try? await UNUserNotificationCenter.current().setBadgeCount(0)
         }) {
        self.username = username
        self.defaults = defaults
        self.loadRequests = loadRequests
        self.sequence = sequence
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

    /// Takes the counts from an API response's envelope. `startedAt` is the sequence number its
    /// request started with: counts from a request that started before the last `markSeen` (the
    /// server has cleared them since) or before one already applied are stale and dropped.
    func ingest(_ counts: UnreadCounts, startedAt: Int) {
        guard startedAt > clearedAt, startedAt > appliedAt else { return }
        appliedAt = startedAt
        activity = counts.activity
    }

    func setRequests(_ list: [Friend]) { requests = list }

    /// Re-reads what's cheap to read: the icon badge and the pending friend requests (a small
    /// call whose envelope also carries the unread counts). Called when the app comes to the
    /// foreground and when the feed refreshes.
    /// A failed load keeps the requests as they were.
    func refresh() async {
        iconBadge = readIconBadge()
        if let list = try? await loadRequests() { requests = list }
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
        clearedAt = sequence()
        iconBadge = 0
        Task { await clearIconBadge() }
    }
}
