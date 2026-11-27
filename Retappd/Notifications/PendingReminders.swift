import BackgroundTasks
import Foundation
import UserNotifications

/// Reminds you about check-ins saved for later (`PendingCheckins`), two ways:
///
/// - **Back online:** while the list isn't empty, the app asks iOS for background refreshes
///   (`BGAppRefreshTask`). iOS picks when, and gives each one about 30 seconds, so it runs the
///   shorter proof (`ConnectionProof.Rule.background`: 3 fast responses over 20 s) and, if the
///   connection passes, posts "You have beers to check in". Not more than once every few hours.
/// - **Next morning:** a local notification at 10 AM after the first item was saved, which needs no
///   network, for when iOS never runs the refresh. Both are withdrawn once the list is empty.
@MainActor
final class PendingReminders {
    static let shared = PendingReminders()

    static let refreshTaskID = "com.davidsansome.retappd.pending-checkins"
    static let onlineNoticeID = "pending-checkins-online"
    static let morningNoticeID = "pending-checkins-morning"
    /// Don't ask for a refresh sooner than this.
    static let refreshInterval: TimeInterval = 15 * 60
    /// Don't post "back online" more often than this.
    static let onlineNoticeInterval: TimeInterval = 4 * 60 * 60
    static let morningHour = 10
    private static let lastOnlineNoticeKey = "pendingCheckins.lastOnlineNotice"

    private let center = UNUserNotificationCenter.current()

    /// Registers the background refresh handler. Must run before launch finishes.
    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return task.setTaskCompleted(success: false) }
            Task { @MainActor in PendingReminders.shared.handle(task) }
        }
    }

    /// Brings the reminders in line with the saved list. Call when it changes and when the app
    /// goes to the background.
    func update(_ items: [PendingCheckin]) {
        guard !items.isEmpty else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
            center.removePendingNotificationRequests(withIdentifiers: [Self.morningNoticeID])
            center.removeDeliveredNotifications(withIdentifiers: [Self.onlineNoticeID, Self.morningNoticeID])
            return
        }
        scheduleRefresh()
        let oldest = items.map(\.savedAt).min() ?? .now
        Task { await scheduleMorning(count: items.count, after: oldest) }
    }

    private func scheduleRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)
        try? BGTaskScheduler.shared.submit(r)
    }

    private func handle(_ task: BGAppRefreshTask) {
        let items = PendingCheckins.shared.items
        guard !items.isEmpty else { return task.setTaskCompleted(success: true) }
        scheduleRefresh()  // the next one, in case this one doesn't prove anything
        let work = Task {
            let ok = await Connectivity.shared.prove(.background)
            if ok { await postOnlineNotice(count: PendingCheckins.shared.items.count) }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    private func postOnlineNotice(count: Int) async {
        guard count > 0 else { return }
        let d = UserDefaults.standard
        if let last = d.object(forKey: Self.lastOnlineNoticeKey) as? Date,
           Date.now.timeIntervalSince(last) < Self.onlineNoticeInterval { return }
        guard await authorized(ask: false) else { return }
        let c = Self.content(count: count, online: true)
        try? await center.add(UNNotificationRequest(identifier: Self.onlineNoticeID, content: c, trigger: nil))
        d.set(Date.now, forKey: Self.lastOnlineNoticeKey)
    }

    private func scheduleMorning(count: Int, after saved: Date) async {
        guard await authorized(ask: true) else { return }
        let fire = Self.nextMorning(after: saved)
        guard fire > .now else {
            // The morning has come and gone; the back-online notice covers it from here.
            center.removePendingNotificationRequests(withIdentifiers: [Self.morningNoticeID])
            return
        }
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        let c = Self.content(count: count, online: false)
        try? await center.add(UNNotificationRequest(identifier: Self.morningNoticeID, content: c, trigger: trigger))
    }

    /// Whether local notifications may be shown, asking first (once) if `ask` and iOS hasn't been
    /// told yet.
    private func authorized(ask: Bool) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined:
            guard ask else { return false }
            return (try? await center.requestAuthorization(options: [.alert])) ?? false
        default: return false
        }
    }

    // MARK: Pure parts

    /// The first `morningHour` o'clock after `date`, at least 3 hours on, so something saved at
    /// 9 AM waits for the next day rather than nagging an hour later.
    nonisolated static func nextMorning(after date: Date, hour: Int = morningHour,
                                        calendar: Calendar = .current) -> Date {
        var day = calendar.startOfDay(for: date)
        while true {
            if let t = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
               t.timeIntervalSince(date) >= 3 * 60 * 60 {
                return t
            }
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
    }

    nonisolated static func content(count: Int, online: Bool) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        let beers = count == 1 ? "1 beer" : "\(count) beers"
        c.title = online ? "You're back online" : "Saved check-ins"
        c.body = online
            ? "You have \(beers) to check in. Tap to finish them."
            : "You have \(beers) saved to check in. Tap to finish them."
        c.userInfo = ["retappd": ["type": "pending_checkins"]]
        return c
    }
}
