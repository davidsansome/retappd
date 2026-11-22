import Foundation
import Security
import Observation

@Observable @MainActor
final class AuthStore {
    private(set) var token: String?
    private(set) var username: String?

    var isSignedIn: Bool { token != nil && username != nil }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readToken: () -> String?
    @ObservationIgnored private let writeToken: (String) -> Void
    @ObservationIgnored private let deleteToken: () -> Void
    @ObservationIgnored private let readAPIToken: () -> String?
    @ObservationIgnored private let setAPIToken: (String?) -> Void
    @ObservationIgnored private let fetchXAuth: @Sendable (String, String) async throws -> XAuthResponse
    @ObservationIgnored private let fetchUserSettings: @Sendable () async throws -> AccountSettings

    /// Untappd usernames cannot contain `@`; an email address stored as `username` breaks every
    /// `/v4/user/.../{username}` endpoint and checkin ownership check.
    static func isValidUsername(_ value: String?) -> Bool {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.contains("@") else { return false }
        return true
    }

    init(
        defaults: UserDefaults = .standard,
        readToken: @escaping () -> String? = { Keychain.read("access_token") },
        writeToken: @escaping (String) -> Void = { Keychain.write("access_token", $0) },
        deleteToken: @escaping () -> Void = { Keychain.delete("access_token") },
        readAPIToken: @escaping () -> String? = { UntappdAPI.shared.token },
        setAPIToken: @escaping (String?) -> Void = { UntappdAPI.shared.token = $0 },
        installUnauthorizedHandler: Bool = true,
        fetchXAuth: @escaping @Sendable (String, String) async throws -> XAuthResponse = { username, password in
            try await UntappdAPI.shared.fetch(.xauth(username: username, password: password), as: XAuthResponse.self)
        },
        fetchUserSettings: @escaping @Sendable () async throws -> AccountSettings = {
            try await UntappdAPI.shared.fetch(.userSettings, as: AccountSettings.self)
        }
    ) {
        self.defaults = defaults
        self.readToken = readToken
        self.writeToken = writeToken
        self.deleteToken = deleteToken
        self.readAPIToken = readAPIToken
        self.setAPIToken = setAPIToken
        self.fetchXAuth = fetchXAuth
        self.fetchUserSettings = fetchUserSettings

        let savedToken = readToken()
        let savedUsername = defaults.string(forKey: "username")
        if let savedToken, let savedUsername {
            token = savedToken
            username = savedUsername
        } else {
            token = nil
            username = nil
            deleteToken()
            defaults.removeObject(forKey: "username")
        }
        setAPIToken(token)
        if installUnauthorizedHandler {
            UntappdAPI.shared.onUnauthorized = { [weak self] in
                Task { @MainActor in self?.signOut() }
            }
        }
    }

    func signIn(username: String, password: String) async throws {
        let r = try await fetchXAuth(username, password)
        if r.twoFactor && r.accessToken == nil {
            throw APIError.server(code: 0, detail: "This account uses two-factor authentication, which isn't supported yet.")
        }
        guard let t = r.accessToken else { throw APIError.server(code: 0, detail: "Sign in failed.") }

        // Resolve the canonical `user_name` via `/v4/account/usersettings` so signing in with an
        // email address (or an account where `xauth` omits/echoes an email in `username`) never
        // stores an email address as `username`.
        let previousToken = readAPIToken()
        setAPIToken(t)
        let settingsResult: Result<AccountSettings, Error>
        do {
            settingsResult = .success(try await fetchUserSettings())
        } catch {
            settingsResult = .failure(error)
        }

        let resolved: String
        if case .success(let settings) = settingsResult,
           let canonical = settings.userName?.trimmingCharacters(in: .whitespacesAndNewlines),
           Self.isValidUsername(canonical) {
            resolved = canonical
        } else if let xauthName = r.username?.trimmingCharacters(in: .whitespacesAndNewlines),
                  Self.isValidUsername(xauthName) {
            resolved = xauthName
        } else if Self.isValidUsername(username) {
            resolved = username.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            setAPIToken(previousToken)
            if case .failure(let error) = settingsResult { throw error }
            throw APIError.server(code: 0, detail: "Couldn't determine your Untappd username.")
        }

        writeToken(t)
        defaults.set(resolved, forKey: "username")
        token = t
        self.username = resolved
    }

    /// Updates the stored username if the server reports a different canonical `user_name`
    /// (for example, repairing an install that previously saved an email address as `username`).
    func reconcileUsername(_ canonical: String?) {
        guard token != nil,
              let canonical = canonical?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isValidUsername(canonical),
              canonical != username else { return }
        defaults.set(canonical, forKey: "username")
        username = canonical
    }

    /// Fetches `/v4/account/usersettings` to replace a saved email address (or invalid username)
    /// with the account's canonical Untappd `user_name`.
    func refreshUsernameIfNeeded() async throws {
        guard token != nil, !Self.isValidUsername(username) else { return }
        let settings = try await fetchUserSettings()
        guard let canonical = settings.userName?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isValidUsername(canonical) else {
            throw APIError.server(code: 0, detail: "Couldn't determine your Untappd username.")
        }
        reconcileUsername(canonical)
    }

    #if DEBUG
    @ObservationIgnored private var triedLaunchSignIn = false

    /// Signs in to a test account given at launch, so a fresh simulator can be signed in without
    /// typing: `xcrun simctl launch <udid> com.davidsansome.retappd -autoLoginUsername <name>
    /// -autoLoginPassword <password>` (or `scripts/launch-test-account.sh`). Does nothing if
    /// already signed in, and only tries once per launch, so signing out sticks. Debug builds
    /// only, so TestFlight builds ignore it.
    func signInFromLaunchArguments() async {
        guard !triedLaunchSignIn, !isSignedIn,
              let user = UserDefaults.standard.string(forKey: "autoLoginUsername"), !user.isEmpty,
              let pass = UserDefaults.standard.string(forKey: "autoLoginPassword"), !pass.isEmpty
        else { return }
        triedLaunchSignIn = true
        do {
            try await signIn(username: user, password: pass)
        } catch {
            print("Auto sign-in as \(user) failed: \(error.localizedDescription)")
        }
    }
    #endif

    func signOut() {
        guard token != nil || username != nil else { return }
        // Stash the notification registration for deletion and start the DELETE before the token
        // goes. It doesn't wait: an unreachable server mustn't hold up signing out (a failed
        // DELETE is retried on the next launch).
        NotificationService.shared.signedOut()
        // First and synchronously: the ticks go at once, an in-flight sync is abandoned, and a
        // sign-in straight afterwards can't pick up this account's list.
        HadBeers.shared.clear()
        VenueHistory.shared.clear()
        deleteToken()
        defaults.removeObject(forKey: "username")
        setAPIToken(nil)
        UntappdAPI.shared.onUnreadCounts = nil
        CheckInOptions.shared.resetForSignOut()
        token = nil
        username = nil
        Task {
            await ResponseCache.shared.removeAll()
            await LocalIndex.shared.removeAll()
        }
    }
}

enum Keychain {
    private static let service = "com.davidsansome.retappd"

    static func read(_ account: String) -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func write(_ account: String, _ value: String, accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) -> Bool {
        delete(account)
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                  kSecValueData: Data(value.utf8), kSecAttrAccessible: accessible]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(q as CFDictionary)
    }
}
