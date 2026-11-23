import XCTest
@testable import Retappd

@MainActor
final class AuthStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "AuthStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func decodeXAuth(_ json: String) throws -> XAuthResponse {
        try UntappdAPI.decode(XAuthResponse.self, from: Data(json.utf8))
    }

    private func decodeSettings(_ json: String) throws -> AccountSettings {
        try UntappdAPI.decode(AccountSettings.self, from: Data(json.utf8))
    }

    func testAccountSettingsDecodesUserName() throws {
        let json = """
        {"meta":{"code":200},"response":{"user":{"uid":1001,"user_name":"sample_user","is_private":1}}}
        """
        let settings = try decodeSettings(json)
        XCTAssertEqual(settings.userName, "sample_user")
    }

    func testSignInWithEmailResolvesCanonicalUsernameWhenXAuthReturnsEmail() async throws {
        let defaults = makeDefaults()
        var storedToken: String?
        var apiToken: String?

        let xauth = try decodeXAuth("""
        {"meta":{"code":200},"response":{"access_token":"tok-1","username":"tester@example.com","two_factor_enabled":0}}
        """)
        let settings = try decodeSettings("""
        {"meta":{"code":200},"response":{"user":{"uid":1001,"user_name":"sample_user"}}}
        """)

        let auth = AuthStore(
            defaults: defaults,
            readToken: { storedToken },
            writeToken: { storedToken = $0 },
            deleteToken: { storedToken = nil },
            readAPIToken: { apiToken },
            setAPIToken: { apiToken = $0 },
            installUnauthorizedHandler: false,
            fetchXAuth: { _, _ in xauth },
            fetchUserSettings: { settings }
        )

        try await auth.signIn(username: "tester@example.com", password: "secret")

        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(auth.username, "sample_user")
        XCTAssertEqual(defaults.string(forKey: "username"), "sample_user")
        XCTAssertEqual(storedToken, "tok-1")
        XCTAssertEqual(apiToken, "tok-1")
    }

    func testSignInWithEmailResolvesCanonicalUsernameWhenXAuthOmitsUsername() async throws {
        let defaults = makeDefaults()
        var storedToken: String?
        var apiToken: String?

        let xauth = try decodeXAuth("""
        {"meta":{"code":200},"response":{"access_token":"tok-2","two_factor_enabled":0}}
        """)
        let settings = try decodeSettings("""
        {"meta":{"code":200},"response":{"user":{"uid":1001,"user_name":"sample_user"}}}
        """)

        let auth = AuthStore(
            defaults: defaults,
            readToken: { storedToken },
            writeToken: { storedToken = $0 },
            deleteToken: { storedToken = nil },
            readAPIToken: { apiToken },
            setAPIToken: { apiToken = $0 },
            installUnauthorizedHandler: false,
            fetchXAuth: { _, _ in xauth },
            fetchUserSettings: { settings }
        )

        try await auth.signIn(username: "tester@example.com", password: "secret")

        XCTAssertEqual(auth.username, "sample_user")
        XCTAssertEqual(defaults.string(forKey: "username"), "sample_user")
    }

    func testSignInWithEmailFailsRatherThanSavingEmailWhenUserSettingsFails() async throws {
        let defaults = makeDefaults()
        var storedToken: String?
        var apiToken: String?

        let xauth = try decodeXAuth("""
        {"meta":{"code":200},"response":{"access_token":"tok-3","username":"tester@example.com","two_factor_enabled":0}}
        """)

        let auth = AuthStore(
            defaults: defaults,
            readToken: { storedToken },
            writeToken: { storedToken = $0 },
            deleteToken: { storedToken = nil },
            readAPIToken: { apiToken },
            setAPIToken: { apiToken = $0 },
            installUnauthorizedHandler: false,
            fetchXAuth: { _, _ in xauth },
            fetchUserSettings: { throw APIError.http(503) }
        )

        do {
            try await auth.signIn(username: "tester@example.com", password: "secret")
            XCTFail("Expected signIn to throw when only an email is available and usersettings fails")
        } catch {}

        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(auth.username)
        XCTAssertNil(storedToken)
        XCTAssertNil(apiToken)
        XCTAssertNil(defaults.string(forKey: "username"))
    }

    func testSignInFallsBackToValidXAuthUsernameWhenUserSettingsFails() async throws {
        let defaults = makeDefaults()
        var storedToken: String?
        var apiToken: String?

        let xauth = try decodeXAuth("""
        {"meta":{"code":200},"response":{"access_token":"tok-4","username":"sample_user","two_factor_enabled":0}}
        """)

        let auth = AuthStore(
            defaults: defaults,
            readToken: { storedToken },
            writeToken: { storedToken = $0 },
            deleteToken: { storedToken = nil },
            readAPIToken: { apiToken },
            setAPIToken: { apiToken = $0 },
            installUnauthorizedHandler: false,
            fetchXAuth: { _, _ in xauth },
            fetchUserSettings: { throw APIError.http(503) }
        )

        try await auth.signIn(username: "tester@example.com", password: "secret")

        XCTAssertEqual(auth.username, "sample_user")
        XCTAssertEqual(storedToken, "tok-4")
    }

    func testRefreshUsernameIfNeededRepairsSavedEmail() async throws {
        let defaults = makeDefaults()
        defaults.set("tester@example.com", forKey: "username")
        var storedToken: String? = "existing-tok"
        var apiToken: String?

        let settings = try decodeSettings("""
        {"meta":{"code":200},"response":{"user":{"uid":1001,"user_name":"sample_user"}}}
        """)

        let auth = AuthStore(
            defaults: defaults,
            readToken: { storedToken },
            writeToken: { storedToken = $0 },
            deleteToken: { storedToken = nil },
            readAPIToken: { apiToken },
            setAPIToken: { apiToken = $0 },
            installUnauthorizedHandler: false,
            fetchXAuth: { _, _ in XCTFail("Should not call xauth"); throw APIError.http(500) },
            fetchUserSettings: { settings }
        )

        XCTAssertEqual(auth.username, "tester@example.com")
        XCTAssertFalse(AuthStore.isValidUsername(auth.username))

        try await auth.refreshUsernameIfNeeded()

        XCTAssertEqual(auth.username, "sample_user")
        XCTAssertEqual(defaults.string(forKey: "username"), "sample_user")
        XCTAssertTrue(AuthStore.isValidUsername(auth.username))
    }

    func testReconcileUsernameIgnoresEmailsAndUpdatesValidCanonicalName() throws {
        let defaults = makeDefaults()
        defaults.set("Sample_User", forKey: "username")
        let storedToken: String? = "existing-tok"

        let auth = AuthStore(
            defaults: defaults,
            readToken: { storedToken },
            writeToken: { _ in },
            deleteToken: {},
            readAPIToken: { storedToken },
            setAPIToken: { _ in },
            installUnauthorizedHandler: false,
            fetchXAuth: { _, _ in throw APIError.http(500) },
            fetchUserSettings: { throw APIError.http(500) }
        )

        auth.reconcileUsername("tester@example.com")
        XCTAssertEqual(auth.username, "Sample_User")

        auth.reconcileUsername("sample_user")
        XCTAssertEqual(auth.username, "sample_user")
        XCTAssertEqual(defaults.string(forKey: "username"), "sample_user")
    }
}
