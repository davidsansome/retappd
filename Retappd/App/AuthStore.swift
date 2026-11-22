import Foundation
import Security
import Observation

@Observable @MainActor
final class AuthStore {
    private(set) var token: String?
    private(set) var username: String?

    var isSignedIn: Bool { token != nil && username != nil }

    init() {
        let savedToken = Keychain.read("access_token")
        let savedUsername = UserDefaults.standard.string(forKey: "username")
        if let savedToken, let savedUsername {
            token = savedToken
            username = savedUsername
        } else {
            token = nil
            username = nil
            Keychain.delete("access_token")
            UserDefaults.standard.removeObject(forKey: "username")
        }
        UntappdAPI.shared.token = token
        UntappdAPI.shared.onUnauthorized = { [weak self] in
            Task { @MainActor in self?.signOut() }
        }
    }

    func signIn(username: String, password: String) async throws {
        let r = try await UntappdAPI.shared.fetch(.xauth(username: username, password: password), as: XAuthResponse.self)
        if r.twoFactor && r.accessToken == nil {
            throw APIError.server(code: 0, detail: "This account uses two-factor authentication, which isn't supported yet.")
        }
        guard let t = r.accessToken else { throw APIError.server(code: 0, detail: "Sign in failed.") }
        let name = r.username ?? username
        Keychain.write("access_token", t)
        UserDefaults.standard.set(name, forKey: "username")
        UntappdAPI.shared.token = t
        token = t
        self.username = name
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
        Keychain.delete("access_token")
        UserDefaults.standard.removeObject(forKey: "username")
        UntappdAPI.shared.token = nil
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
