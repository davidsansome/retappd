import Foundation
import Security
import Observation

@Observable @MainActor
final class AuthStore {
    private(set) var token: String?
    private(set) var username: String?

    var isSignedIn: Bool { token != nil && username != nil }

    init() {
        token = Keychain.read("access_token")
        username = UserDefaults.standard.string(forKey: "username")
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

    func signOut() {
        Keychain.delete("access_token")
        UserDefaults.standard.removeObject(forKey: "username")
        UntappdAPI.shared.token = nil
        token = nil
        username = nil
        Task {
            await ResponseCache.shared.removeAll()
            await LocalIndex.shared.removeAll()
        }
    }
}

enum Keychain {
    private static let service = "dev.retappd.app"

    static func read(_ account: String) -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        delete(account)
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                  kSecValueData: Data(value.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(q as CFDictionary)
    }
}
