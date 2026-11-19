import XCTest
@testable import Retappd

private final class FakeTransport: NotifyTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    /// Responses by "METHOD path" in order; the last repeats. Missing means unreachable.
    var responses: [String: [(Int, String)]] = [:]
    var unreachable = false
    /// Suspends matching requests (after recording them) until released, to test races.
    var holdKey: String?
    private var heldContinuation: CheckedContinuation<Void, Never>?

    func release() { heldContinuation?.resume(); heldContinuation = nil }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if holdKey == "\(request.httpMethod ?? "") \(request.url!.path)" {
            holdKey = nil
            await withCheckedContinuation { heldContinuation = $0 }
        }
        if unreachable { throw URLError(.notConnectedToInternet) }
        let key = "\(request.httpMethod ?? "") \(request.url!.path)"
        let prefix = responses.keys.first { key == $0 || (key.hasPrefix($0) && $0.hasSuffix("/")) }
        guard let k = prefix, var list = responses[k], !list.isEmpty else { throw URLError(.cannotConnectToHost) }
        let r = list.count > 1 ? list.removeFirst() : list[0]
        responses[k] = list
        return (Data(r.1.utf8), r.0)
    }

    func body(_ i: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: requests[i].httpBody ?? Data())) as? [String: Any] ?? [:]
    }
}

private final class MemoryStorage: NotifyStorage {
    var items: [String: String] = [:]
    func read(_ key: String) -> String? { items[key] }
    func write(_ key: String, _ value: String) { items[key] = value }
    func delete(_ key: String) { items[key] = nil }
}

@MainActor
final class NotificationServiceTests: XCTestCase {
    private let regJSON = #"{"device_id":"dev-1","device_secret":"sec-1"}"#
    private var transport = FakeTransport()
    private var storage = MemoryStorage()
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var token: String? = "tok-1"

    override func setUp() {
        transport = FakeTransport()
        storage = MemoryStorage()
        let suite = "notify-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        clock = Date(timeIntervalSince1970: 1_000_000)
        token = "tok-1"
    }

    private func makeService(granted: Bool = true) -> NotificationService {
        NotificationService(
            client: NotifyClient(baseURL: URL(string: "https://relay.test")!, transport: transport),
            storage: storage, defaults: defaults,
            untappdToken: { [unowned self] in token },
            now: { [unowned self] in clock },
            appVersion: "1.0 (1)", apnsEnv: "sandbox",
            requestAuthorization: { granted }, registerForRemote: {})
    }

    private func enabledAndRegistered() async -> NotificationService {
        transport.responses["POST /v1/devices"] = [(200, regJSON)]
        transport.responses["PATCH /v1/devices/dev-1"] = [(200, #"{"ok":true}"#)]
        transport.responses["DELETE /v1/devices/dev-1"] = [(204, "")]
        let s = makeService()
        await s.setEnabled(true)
        s.setAPNsToken(Data([0xab, 0xcd]))
        await s.sync()
        return s
    }

    func testRegistrationRequestAndStorage() async throws {
        let s = await enabledAndRegistered()
        XCTAssertEqual(transport.requests.count, 1)
        let r = transport.requests[0]
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "https://relay.test/v1/devices")
        let b = transport.body(0)
        XCTAssertEqual(b["untappd_token"] as? String, "tok-1")
        XCTAssertEqual(b["apns_token"] as? String, "abcd")
        XCTAssertEqual(b["apns_env"] as? String, "sandbox")
        XCTAssertEqual(b["app_version"] as? String, "1.0 (1)")
        XCTAssertEqual(b["prefs"] as? [String: Bool], ["toast": true, "comment": true, "tag": true, "friend": true])
        XCTAssertNotNil(storage.read(NotificationService.registrationKey))
        _ = s
    }

    func testNotRegisteredWhenDisabledOrWithoutToken() async {
        transport.responses["POST /v1/devices"] = [(200, regJSON)]
        let s = makeService()
        s.setAPNsToken(Data([1]))
        await s.sync()
        XCTAssertTrue(transport.requests.isEmpty)
        token = nil
        await s.setEnabled(true)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testDeniedPermissionLeavesItOff() async {
        let s = makeService(granted: false)
        await s.setEnabled(true)
        XCTAssertFalse(s.enabled)
        XCTAssertTrue(s.permissionDenied)
    }

    func testPrefsChangeSendsPatchWithOnlyPrefs() async {
        let s = await enabledAndRegistered()
        var p = s.prefs
        p.tag = false
        await s.setPrefs(p)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[1].httpMethod, "PATCH")
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer sec-1")
        let b = transport.body(1)
        XCTAssertEqual(Set(b.keys), ["prefs"])
        XCTAssertEqual((b["prefs"] as? [String: Bool])?["tag"], false)
    }

    func testChangedUntappdTokenAndApnsTokenPatch() async {
        let s = await enabledAndRegistered()
        token = "tok-2"
        s.setAPNsToken(Data([0x01]))
        await s.sync()
        let bodies = (1..<transport.requests.count).map { transport.body($0) }
        XCTAssertTrue(bodies.contains { $0["untappd_token"] as? String == "tok-2" || $0["apns_token"] as? String == "01" })
        XCTAssertTrue(bodies.contains { $0["apns_token"] as? String == "01" })
    }

    func testHeartbeatThrottledToTwelveHours() async {
        let s = await enabledAndRegistered()
        let n = transport.requests.count
        clock += 11 * 3600
        await s.sync()
        XCTAssertEqual(transport.requests.count, n, "no heartbeat before 12 h")
        clock += 2 * 3600
        await s.sync()
        XCTAssertEqual(transport.requests.count, n + 1)
        XCTAssertEqual(transport.requests.last?.httpMethod, "PATCH")
        XCTAssertEqual(transport.body(n).count, 0, "heartbeat is {}")
        await s.sync()
        XCTAssertEqual(transport.requests.count, n + 1, "and it resets the clock")
    }

    func test404ReRegisters() async {
        let s = await enabledAndRegistered()
        clock += 13 * 3600
        transport.responses["PATCH /v1/devices/dev-1"] = [(404, "{}")]
        transport.responses["POST /v1/devices"] = [(200, #"{"device_id":"dev-2","device_secret":"sec-2"}"#)]
        await s.sync()
        let methods = transport.requests.map { $0.httpMethod ?? "" }
        XCTAssertEqual(methods, ["POST", "PATCH", "POST"])
        XCTAssertTrue(storage.read(NotificationService.registrationKey)?.contains("dev-2") == true)
    }

    func testUnreachableServerIsSilent() async {
        transport.unreachable = true
        let s = makeService()
        await s.setEnabled(true)
        s.setAPNsToken(Data([1]))
        await s.sync()
        XCTAssertTrue(s.enabled)
        XCTAssertNil(storage.read(NotificationService.registrationKey))
    }

    func testSwitchingOffDeletes() async {
        let s = await enabledAndRegistered()
        await s.setEnabled(false)
        XCTAssertEqual(transport.requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(transport.requests.last?.url?.path, "/v1/devices/dev-1")
        XCTAssertNil(storage.read(NotificationService.registrationKey))
        XCTAssertFalse(s.hasPendingDeletion)
    }

    func testSignOutOfflineKeepsPendingDeletionAndRetries() async {
        let s = await enabledAndRegistered()
        transport.unreachable = true
        await s.signedOut().value
        XCTAssertFalse(s.enabled)
        XCTAssertNil(storage.read(NotificationService.registrationKey))
        XCTAssertTrue(s.hasPendingDeletion)

        // Back online on the next launch.
        transport.unreachable = false
        transport.responses["DELETE /v1/devices/dev-1"] = [(404, "")]
        await s.retryPendingDeletion()
        XCTAssertFalse(s.hasPendingDeletion, "404 counts as deleted")
        XCTAssertEqual(transport.requests.last?.httpMethod, "DELETE")
    }

    func testSignOutOnlineClearsEverything() async {
        let s = await enabledAndRegistered()
        await s.signedOut().value
        XCTAssertFalse(s.hasPendingDeletion)
        XCTAssertNil(storage.read(NotificationService.registrationKey))
    }

    /// The registration in these tests is made by a task `setAPNsToken` starts, which the test
    /// can't await directly: wait until its DELETE has been attempted.
    private func settle() async {
        for _ in 0..<2000 where !transport.requests.contains(where: { $0.httpMethod == "DELETE" }) { await Task.yield() }
        for _ in 0..<200 { await Task.yield() }
    }

    func testSignOutDuringInFlightRegistrationDeletesTheNewDevice() async {
        transport.responses["POST /v1/devices"] = [(200, regJSON)]
        transport.responses["DELETE /v1/devices/dev-1"] = [(204, "")]
        transport.holdKey = "POST /v1/devices"
        let s = makeService()
        await s.setEnabled(true)
        s.setAPNsToken(Data([0xab]))
        let sync = Task { await s.sync() }
        while !transport.requests.contains(where: { $0.httpMethod == "POST" }) { await Task.yield() }
        await s.signedOut().value
        transport.release()
        await sync.value
        await settle()
        XCTAssertEqual(transport.requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(transport.requests.last?.url?.path, "/v1/devices/dev-1")
        XCTAssertNil(storage.read(NotificationService.registrationKey))
        XCTAssertFalse(s.hasPendingDeletion)
    }

    func testSignOutDuringInFlightRegistrationOfflineKeepsItPending() async {
        transport.responses["POST /v1/devices"] = [(200, regJSON)]
        transport.holdKey = "POST /v1/devices"
        let s = makeService()
        await s.setEnabled(true)
        s.setAPNsToken(Data([0xab]))
        let sync = Task { await s.sync() }
        while !transport.requests.contains(where: { $0.httpMethod == "POST" }) { await Task.yield() }
        await s.signedOut().value
        transport.release()
        // The DELETE can't get through (no response configured), so it stays queued.
        await sync.value
        await settle()
        XCTAssertNil(storage.read(NotificationService.registrationKey))
        XCTAssertTrue(s.hasPendingDeletion)
    }

    func testPendingDeletionsAccumulateAndAllRetry() async {
        let s = await enabledAndRegistered()
        transport.unreachable = true
        await s.signedOut().value
        // Back online briefly: a second device registers, then goes offline again before sign-out.
        transport.unreachable = false
        transport.responses["POST /v1/devices"] = [(200, #"{"device_id":"dev-2","device_secret":"sec-2"}"#)]
        transport.responses["DELETE /v1/devices/dev-1"] = []
        await s.setEnabled(true)
        XCTAssertTrue(storage.read(NotificationService.registrationKey)?.contains("dev-2") == true)
        transport.unreachable = true
        await s.signedOut().value
        let raw = storage.read(NotificationService.pendingDeletionKey) ?? ""
        XCTAssertTrue(raw.contains("dev-1") && raw.contains("dev-2"), "the older device isn't overwritten")

        transport.unreachable = false
        transport.responses["DELETE /v1/devices/dev-1"] = [(204, "")]
        transport.responses["DELETE /v1/devices/dev-2"] = [(204, "")]
        let before = transport.requests.count
        await s.retryPendingDeletion()
        let deleted = transport.requests[before...].filter { $0.httpMethod == "DELETE" }.map { $0.url!.path }
        XCTAssertEqual(Set(deleted), ["/v1/devices/dev-1", "/v1/devices/dev-2"])
        XCTAssertFalse(s.hasPendingDeletion)
    }

    func testPatch401DeletesAndReRegisters() async {
        let s = await enabledAndRegistered()
        clock += 13 * 3600
        transport.responses["PATCH /v1/devices/dev-1"] = [(401, "{}")]
        transport.responses["POST /v1/devices"] = [(200, #"{"device_id":"dev-2","device_secret":"sec-2"}"#)]
        await s.sync()
        let methods = transport.requests.map { $0.httpMethod ?? "" }
        XCTAssertEqual(methods, ["POST", "PATCH", "DELETE", "POST"])
        XCTAssertEqual(transport.requests[2].url?.path, "/v1/devices/dev-1")
        XCTAssertTrue(storage.read(NotificationService.registrationKey)?.contains("dev-2") == true)
    }

    func testSignOutClearsPendingNotificationRoute() async {
        NotificationRouter.shared.pending = .checkin(5)
        let s = makeService()
        await s.signedOut().value
        XCTAssertNil(NotificationRouter.shared.pending)
    }

    // MARK: Payload parsing

    func testRoutesFromPayload() {
        func route(_ type: String, id: Any? = nil) -> NotificationRoute? {
            var r: [String: Any] = ["type": type, "actor": "Jamie S"]
            if let id { r["checkin_id"] = id }
            return NotificationRoute(userInfo: ["aps": ["badge": 3], "retappd": r])
        }
        XCTAssertEqual(route("toast", id: 1582931702), .checkin(1582931702))
        XCTAssertEqual(route("comment", id: NSNumber(value: 5)), .checkin(5))
        XCTAssertEqual(route("tag", id: "7"), .checkin(7))
        XCTAssertEqual(route("comment_tag", id: 9), .checkin(9))
        XCTAssertEqual(route("friend_request"), .friendRequest)
        XCTAssertNil(route("toast"), "check-in types need an id")
        XCTAssertNil(route("mystery", id: 1))
        XCTAssertNil(NotificationRoute(userInfo: ["aps": [:]]))
        // A "N more notifications" summary carries no `retappd` key: the tap just opens the app.
        XCTAssertNil(NotificationRoute(userInfo: ["aps": ["alert": ["body": "3 more notifications"], "badge": 5]]))
        XCTAssertNil(NotificationRoute(userInfo: ["retappd": "oops"]))
    }
}
