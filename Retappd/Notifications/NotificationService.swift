import Foundation
import CryptoKit
import Observation
import UIKit
import UserNotifications

/// Where the device id and secret (and a pending deletion) are kept; the Keychain in the app.
protocol NotifyStorage {
    func read(_ key: String) -> String?
    func write(_ key: String, _ value: String)
    func delete(_ key: String)
}

struct KeychainNotifyStorage: NotifyStorage {
    func read(_ key: String) -> String? { Keychain.read(key) }
    func write(_ key: String, _ value: String) {
        // These identify a device to the relay, so they stay on this device (no backups or migration).
        Keychain.write(key, value, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }
    func delete(_ key: String) { Keychain.delete(key) }
}

/// Keeps this device registered with the notification relay while the user has notifications on.
/// Every failure is silent: until the relay is deployed, or when offline, nothing here may show
/// an error or block anything; the next change or foreground tries again.
@Observable @MainActor
final class NotificationService {
    static let shared = NotificationService()

    /// What was last sent successfully, to work out what a PATCH needs to carry. The Untappd
    /// token is kept only as a hash.
    struct Snapshot: Codable, Equatable {
        var tokenHash: String
        var apnsToken: String
        var apnsEnv: String
        var prefs: NotifyPrefs
        var appVersion: String
    }

    static let heartbeatInterval: TimeInterval = 12 * 3600
    static let registrationKey = "notify_registration"
    static let pendingDeletionKey = "notify_pending_deletions"

    // Settings UI state
    private(set) var enabled: Bool
    private(set) var prefs: NotifyPrefs
    /// iOS notification permission was refused, so the switch can't work until it's changed in iOS Settings.
    private(set) var permissionDenied = false

    @ObservationIgnored var client: NotifyClient?
    @ObservationIgnored var storage: NotifyStorage
    @ObservationIgnored var defaults: UserDefaults
    @ObservationIgnored var untappdToken: () -> String?
    @ObservationIgnored var now: () -> Date
    @ObservationIgnored var appVersion: String
    @ObservationIgnored var apnsEnv: String
    @ObservationIgnored var requestAuthorization: () async -> Bool
    @ObservationIgnored var authorizationStatus: () async -> UNAuthorizationStatus
    @ObservationIgnored var registerForRemote: @MainActor () -> Void
    @ObservationIgnored private(set) var apnsToken: String?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var resync = false
    @ObservationIgnored private var deleting = false
    /// Bumped whenever the registration is given up (sign-out, switched off), so a request that was
    /// in flight at the time can tell its result is stale.
    @ObservationIgnored private var generation = 0

    init(client: NotifyClient? = NotificationService.defaultClient(),
         storage: NotifyStorage = KeychainNotifyStorage(),
         defaults: UserDefaults = .standard,
         untappdToken: @escaping () -> String? = { UntappdAPI.shared.token },
         now: @escaping () -> Date = Date.init,
         appVersion: String = NotificationService.bundleVersion(),
         apnsEnv: String = NotificationService.defaultEnv,
         requestAuthorization: @escaping () async -> Bool = {
             (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
         },
         authorizationStatus: @escaping () async -> UNAuthorizationStatus = {
             await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
         },
         registerForRemote: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() }) {
        self.client = client
        self.storage = storage
        self.defaults = defaults
        self.untappdToken = untappdToken
        self.now = now
        self.appVersion = appVersion
        self.apnsEnv = apnsEnv
        self.requestAuthorization = requestAuthorization
        self.authorizationStatus = authorizationStatus
        self.registerForRemote = registerForRemote
        enabled = defaults.bool(forKey: "notify.enabled")
        prefs = defaults.data(forKey: "notify.prefs").flatMap { try? JSONDecoder().decode(NotifyPrefs.self, from: $0) } ?? NotifyPrefs()
    }

    #if DEBUG
    nonisolated static let defaultEnv = "sandbox"
    #else
    nonisolated static let defaultEnv = "production"
    #endif

    /// From Info.plist (`RetappdNotifyBaseURL`); Debug builds can override with `-notifyBaseURL <url>`.
    nonisolated static func defaultClient() -> NotifyClient? {
        var s = Bundle.main.object(forInfoDictionaryKey: "RetappdNotifyBaseURL") as? String
        #if DEBUG
        if let o = UserDefaults.standard.string(forKey: "notifyBaseURL"), !o.isEmpty { s = o }
        #endif
        guard let s, let url = URL(string: s) else { return nil }
        return NotifyClient(baseURL: url)
    }

    nonisolated static func bundleVersion() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }

    // MARK: Entry points

    /// On launch and whenever the app comes to the foreground: retries a pending deletion, then
    /// registers or sends a heartbeat if one is due.
    func appBecameActive() async {
        await retryPendingDeletion()
        if enabled { registerForRemote() }
        await refreshPermission()
        await sync()
    }

    func setAPNsToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        guard hex != apnsToken else { return }
        apnsToken = hex
        Task { await sync() }
    }

    /// The master switch. Turning on asks for permission first.
    func setEnabled(_ on: Bool) async {
        if on {
            let gen = generation
            guard await requestAuthorization() else {
                if gen == generation { permissionDenied = true }
                return
            }
            guard gen == generation, untappdToken() != nil else { return }
            permissionDenied = false
            enabled = true
            defaults.set(true, forKey: "notify.enabled")
            registerForRemote()
            await sync()
        } else {
            enabled = false
            defaults.set(false, forKey: "notify.enabled")
            await removeRegistration()
        }
    }

    func setPrefs(_ p: NotifyPrefs) async {
        guard p != prefs else { return }
        prefs = p
        defaults.set(try? JSONEncoder().encode(p), forKey: "notify.prefs")
        await sync()
    }

    /// Sign-out. Synchronously moves the registration to the pending-deletion item (so a quit or
    /// failure can't leave the account's token on the server), switches notifications off, and
    /// returns the task that tries the DELETE; the caller doesn't need to wait for it.
    @discardableResult
    func signedOut() -> Task<Void, Never> {
        // A tap on a notification for the account just left mustn't route the next one.
        NotificationRouter.shared.pending = nil
        enabled = false
        defaults.set(false, forKey: "notify.enabled")
        stashRegistrationForDeletion()
        return Task { await retryPendingDeletion() }
    }

    // MARK: Registration

    private var registration: DeviceRegistration? {
        storage.read(Self.registrationKey).flatMap { try? JSONDecoder().decode(DeviceRegistration.self, from: Data($0.utf8)) }
    }

    private func store(_ r: DeviceRegistration) {
        if let d = try? JSONEncoder().encode(r), let s = String(data: d, encoding: .utf8) { storage.write(Self.registrationKey, s) }
    }

    private var synced: Snapshot? {
        defaults.data(forKey: "notify.synced").flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
    }

    private func markSynced(_ s: Snapshot?) {
        if let s {
            defaults.set(try? JSONEncoder().encode(s), forKey: "notify.synced")
            defaults.set(now().timeIntervalSince1970, forKey: "notify.lastSeen")
        } else {
            defaults.removeObject(forKey: "notify.synced")
        }
    }

    private var heartbeatDue: Bool {
        let last = defaults.double(forKey: "notify.lastSeen")
        return now().timeIntervalSince1970 - last >= Self.heartbeatInterval
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Brings the server in line: registers if needed, PATCHes what changed, or heartbeats if 12 h
    /// have passed. Does nothing without notifications on, an APNs token and an Untappd sign-in.
    func sync() async {
        if syncing { resync = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            resync = false
            await syncOnce()
        } while resync
    }

    private func syncOnce() async {
        guard enabled, let client, let apns = apnsToken, let token = untappdToken() else { return }
        let gen = generation
        let snap = Snapshot(tokenHash: Self.hash(token), apnsToken: apns, apnsEnv: apnsEnv, prefs: prefs, appVersion: appVersion)
        guard let reg = registration else {
            await register(client, token: token, snap: snap, generation: gen)
            return
        }
        var body = DeviceUpdate()
        if let old = synced, old != snap {
            if old.tokenHash != snap.tokenHash { body.untappdToken = token }
            if old.apnsToken != snap.apnsToken { body.apnsToken = apns }
            if old.apnsEnv != snap.apnsEnv { body.apnsEnv = apnsEnv }
            if old.prefs != snap.prefs { body.prefs = prefs }
            if old.appVersion != snap.appVersion { body.appVersion = appVersion }
        } else if synced == nil {
            body = DeviceUpdate(untappdToken: token, apnsToken: apns, apnsEnv: apnsEnv, prefs: prefs, appVersion: appVersion)
        } else if !heartbeatDue {
            return
        }
        do {
            try await client.update(reg, body)
            if gen == generation { markSynced(snap) }
        } catch NotifyError.status(404) {
            guard gen == generation else { return }
            storage.delete(Self.registrationKey)
            markSynced(nil)
            await register(client, token: token, snap: snap, generation: gen)
        } catch NotifyError.status(401) {
            // The secret is wrong or the token belongs to another account: start afresh.
            try? await client.delete(reg)
            guard gen == generation else { return }
            storage.delete(Self.registrationKey)
            markSynced(nil)
            await register(client, token: token, snap: snap, generation: gen)
        } catch {
            // Unreachable or server trouble: try again on the next change or foreground.
        }
    }

    private func register(_ client: NotifyClient, token: String, snap: Snapshot, generation gen: Int) async {
        let body = DeviceRegistrationRequest(untappdToken: token, apnsToken: snap.apnsToken, apnsEnv: snap.apnsEnv,
                                             prefs: snap.prefs, appVersion: snap.appVersion)
        guard let r = try? await client.register(body) else { return }
        guard gen == generation else {
            // Signed out or switched off while this was in flight: the server now holds the old
            // account's token, so the new device goes straight to deletion.
            addPending(r)
            await retryPendingDeletion()
            return
        }
        store(r)
        markSynced(snap)
    }

    // MARK: Deletion

    private var pendingDeletions: [DeviceRegistration] {
        get {
            storage.read(Self.pendingDeletionKey)
                .flatMap { try? JSONDecoder().decode([DeviceRegistration].self, from: Data($0.utf8)) } ?? []
        }
        set {
            if newValue.isEmpty { storage.delete(Self.pendingDeletionKey) }
            else if let d = try? JSONEncoder().encode(newValue), let s = String(data: d, encoding: .utf8) {
                storage.write(Self.pendingDeletionKey, s)
            }
        }
    }

    private func addPending(_ r: DeviceRegistration) {
        var list = pendingDeletions
        if !list.contains(r) { list.append(r) }
        pendingDeletions = list
    }

    private func stashRegistrationForDeletion() {
        generation += 1
        if let raw = storage.read(Self.registrationKey),
           let r = try? JSONDecoder().decode(DeviceRegistration.self, from: Data(raw.utf8)) {
            addPending(r)
        }
        storage.delete(Self.registrationKey)
        markSynced(nil)
        defaults.removeObject(forKey: "notify.lastSeen")
    }

    /// Switching off: the registration is stashed first, then the DELETE tried.
    private func removeRegistration() async {
        stashRegistrationForDeletion()
        await retryPendingDeletion()
    }

    /// DELETEs every stashed registration; each is forgotten on success and kept for the next
    /// launch or foreground if the server can't be reached.
    func retryPendingDeletion() async {
        guard !deleting, let client else { return }
        deleting = true
        defer { deleting = false }
        var attempted: Set<String> = []
        while let reg = pendingDeletions.first(where: { !attempted.contains($0.deviceID) }) {
            attempted.insert(reg.deviceID)
            do {
                try await client.delete(reg)
                pendingDeletions = pendingDeletions.filter { $0 != reg }
            } catch {}
        }
    }

    var hasPendingDeletion: Bool { !pendingDeletions.isEmpty }

    private func refreshPermission() async {
        guard enabled || permissionDenied else { return }
        let s = await authorizationStatus()
        permissionDenied = (s == .denied)
    }
}

extension Notification.Name {
    /// Posted when a push notification arrives while the app is in the foreground.
    static let foregroundPushReceived = Notification.Name("retappd.foregroundPushReceived")
}

// MARK: - App delegate

/// Receives the APNs token and notification taps; the SwiftUI `App` has no hooks for either.
final class NotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Clear any leftover app icon badge from older versions.
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
        PendingReminders.register()
        #if DEBUG
        if !ScreenshotDemo.isEnabled {
            CheckinQueue.shared.start()
        }
        #else
        CheckinQueue.shared.start()
        #endif
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        CheckinQueue.shared.handleBackgroundSessionEvents(identifier: identifier, completionHandler: completionHandler)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in NotificationService.shared.setAPNsToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Silent: the simulator or a missing entitlement just means no pushes.
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        if NotificationRoute.isActivity(userInfo: notification.request.content.userInfo) {
            await MainActor.run { NotificationCenter.default.post(name: .foregroundPushReceived, object: nil) }
        }
        return [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let route = NotificationRoute(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { NotificationRouter.shared.pending = route }
    }
}
