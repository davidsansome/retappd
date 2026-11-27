import Foundation
import Observation
import UserNotifications

/// Whether there is anything new for the Activity tab's bell to point at, and what the user has
/// already seen on the Notifications screen.
///
/// Untappd's own unread counts (every response's envelope) are usually reset by the push relay,
/// which reads the feed to build its pushes, so they can't be the only signal. The bell is lit by
/// any of: unread comments, toasts or tags in the envelope; a push notification delivered since
/// the screen was last seen (or arriving in the foreground); or a pending friend request that
/// arrived after the user last opened the screen. Opening the screen (`markSeen`) stores the
/// newest `created_at` it showed per username, records when it was seen, and zeroes the counts,
/// which reading the feed has just reset on the server. Delivered notifications in Notification
/// Centre are left alone.
@Observable @MainActor
final class NotificationUnread {
    let username: String
    /// Newest activity (a notification or friend request) the user has seen.
    private(set) var lastSeen: Date?
    /// Unread comments, toasts and tags according to the latest envelope.
    private(set) var activity = 0
    /// Incoming friend requests, as last loaded.
    private(set) var requests: [Friend] = []
    private(set) var hasDeliveredPush = false
    private(set) var hasForegroundPush = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loadRequests: @MainActor () async throws -> [Friend]
    @ObservationIgnored private let sequence: @MainActor () -> Int
    /// Counts from requests that started at or before this are older than the last `markSeen`.
    private var clearedAt = 0
    /// The newest request whose counts have been applied.
    private var appliedAt = 0
    /// Wall-clock time `markSeen` last ran (at least the newest delivered push date seen then).
    private var markedSeenAt: Date?
    private var latestDeliveredPush: Date?
    @ObservationIgnored private let deliveredPushDates: @MainActor () async -> [Date]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored nonisolated(unsafe) private var foregroundPushObserver: NSObjectProtocol?

    init(username: String,
         defaults: UserDefaults = .standard,
         loadRequests: @escaping @MainActor () async throws -> [Friend] = {
             try await UntappdAPI.shared.fetch(.pendingFriendRequests, as: PendingRequestList.self).requests
         },
         sequence: @escaping @MainActor () -> Int = { UntappdAPI.shared.currentSequence },
         deliveredPushDates: @escaping @MainActor () async -> [Date] = {
             await UNUserNotificationCenter.current().deliveredNotifications()
                 .filter { NotificationRoute.isActivity(userInfo: $0.request.content.userInfo) }
                 .map(\.date)
         },
         now: @escaping () -> Date = Date.init,
         notificationCenter: NotificationCenter = .default) {
        self.username = username
        self.defaults = defaults
        self.loadRequests = loadRequests
        self.sequence = sequence
        self.deliveredPushDates = deliveredPushDates
        self.now = now
        self.notificationCenter = notificationCenter
        let stored = defaults.double(forKey: Self.key(username))
        lastSeen = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        let storedSeenAt = defaults.double(forKey: Self.markedSeenKey(username))
        if storedSeenAt > 0 {
            markedSeenAt = Date(timeIntervalSince1970: storedSeenAt)
        } else if lastSeen != nil {
            // Upgrading from a version before `markedSeenAt` existed: baseline to now so old
            // already-seen pushes (whose delivery date is after the item's `created_at`) don't
            // falsely light the bell once.
            let baseline = now()
            markedSeenAt = baseline
            defaults.set(baseline.timeIntervalSince1970, forKey: Self.markedSeenKey(username))
        }
        foregroundPushObserver = notificationCenter.addObserver(forName: .foregroundPushReceived, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasForegroundPush = true
                await self.refresh()
            }
        }
    }

    deinit {
        if let foregroundPushObserver { notificationCenter.removeObserver(foregroundPushObserver) }
    }

    static func key(_ username: String) -> String { "notifications.lastSeen.\(username.lowercased())" }
    static func markedSeenKey(_ username: String) -> String { "notifications.markedSeenAt.\(username.lowercased())" }

    /// Friend requests newer than what the user last saw.
    var unseenRequests: Int {
        requests.filter { r in
            guard let seen = lastSeen else { return true }
            guard let at = r.createdAt else { return false }
            return at > seen
        }.count
    }

    /// The number on the bell. Zero with `hasUnread` set means a dot only (a delivered push).
    var count: Int { activity + unseenRequests }
    var hasUnread: Bool { count > 0 || hasDeliveredPush || hasForegroundPush }

    /// Takes the counts from an API response's envelope. `startedAt` is the sequence number its
    /// request started with: counts from a request that started before the last `markSeen` (the
    /// server has cleared them since) or before one already applied are stale and dropped.
    func ingest(_ counts: UnreadCounts, startedAt: Int) {
        guard startedAt > clearedAt, startedAt > appliedAt else { return }
        appliedAt = startedAt
        activity = counts.activity
    }

    func setRequests(_ list: [Friend]) { requests = list }

    /// Re-reads what's cheap to read: delivered push notifications and pending friend requests (a
    /// small call whose envelope also carries the unread counts). Called when the app comes to the
    /// foreground and when the feed refreshes.
    /// A failed load keeps the requests as they were.
    func refresh() async {
        async let delivered = deliveredPushDates()
        async let pending: [Friend]? = try? await loadRequests()
        let (dates, list) = await (delivered, pending)
        if let list { requests = list }
        latestDeliveredPush = dates.max()
        if let latest = latestDeliveredPush {
            hasDeliveredPush = markedSeenAt.map { latest > $0 } ?? true
        } else {
            hasDeliveredPush = false
        }
    }

    /// The Notifications screen showed everything up to `newest`. Only moves forward.
    func markSeen(newest: Date?) {
        let candidates = [lastSeen, newest].compactMap { $0 } + requests.compactMap(\.createdAt)
        if let latest = candidates.max(), latest != lastSeen {
            lastSeen = latest
            defaults.set(latest.timeIntervalSince1970, forKey: Self.key(username))
        }
        let seenAt = max(now(), markedSeenAt ?? .distantPast, latestDeliveredPush ?? .distantPast)
        if seenAt != markedSeenAt {
            markedSeenAt = seenAt
            defaults.set(seenAt.timeIntervalSince1970, forKey: Self.markedSeenKey(username))
        }
        activity = 0
        clearedAt = sequence()
        hasDeliveredPush = false
        hasForegroundPush = false
    }
}
