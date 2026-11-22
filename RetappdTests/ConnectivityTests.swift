import XCTest
@testable import Retappd

final class ConnectionProofTests: XCTestCase {
    private let rule = ConnectionProof.Rule.foreground  // 3 responses under 3 s, over 60 s
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func proof(_ responses: [(TimeInterval, RequestOutcome)]) -> ConnectionProof {
        var p = ConnectionProof()
        for (s, o) in responses { p.record(o, at: at(s), maxLatency: rule.maxLatency) }
        return p
    }

    private let fast = RequestOutcome.response(latency: 0.4)

    func testSpacedFastResponsesProve() {
        let p = proof([(0, fast), (30, fast), (60, fast)])
        XCTAssertTrue(p.isProven(rule, now: at(61)))
    }

    func testABurstDoesNotProve() {
        let p = proof((0..<10).map { (Double($0), fast) })
        XCTAssertFalse(p.isProven(rule, now: at(10)))
        XCTAssertEqual(p.counted(rule).count, 1)
    }

    func testTooShortASpanDoesNotProve() {
        let p = proof([(0, fast), (30, fast), (59, fast)])
        XCTAssertFalse(p.isProven(rule, now: at(59)))
        // …and the next one counts from 60 s after the first counted, i.e. 30 s after the second.
        XCTAssertEqual(p.nextUsefulRequest(rule, now: at(59)), at(60))
    }

    func testAFailureStartsAgain() {
        let p = proof([(0, fast), (30, fast), (45, .noResponse), (60, fast)])
        XCTAssertFalse(p.isProven(rule, now: at(60)))
        XCTAssertEqual(p.streak, [at(60)])
    }

    func testASlowResponseStartsAgain() {
        let p = proof([(0, fast), (30, .response(latency: 5)), (60, fast)])
        XCTAssertFalse(p.isProven(rule, now: at(60)))
    }

    func testAProofGoesStale() {
        let p = proof([(0, fast), (30, fast), (60, fast)])
        XCTAssertTrue(p.isProven(rule, now: at(60 + rule.freshness)))
        XCTAssertFalse(p.isProven(rule, now: at(61 + rule.freshness)))
    }

    func testBackgroundRuleIsShorter() {
        let p = proof([(0, fast), (10, fast), (20, fast)])
        XCTAssertTrue(p.isProven(.background, now: at(20)))
        XCTAssertFalse(p.isProven(.foreground, now: at(20)))
    }
}

@MainActor
final class ConnectivityTests: XCTestCase {
    /// A clock that only moves when the code under test waits.
    final class FakeClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var waits: [TimeInterval] = []
    }

    private func defaults() -> UserDefaults {
        let name = "ConnectivityTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func make(_ clock: FakeClock, defaults d: UserDefaults? = nil,
                      probe: @escaping () async -> RequestOutcome) -> Connectivity {
        Connectivity(defaults: d ?? defaults(), now: { clock.now },
                     wait: { s in clock.waits.append(s); clock.now = clock.now.addingTimeInterval(s) },
                     probe: probe)
    }

    func testOfflineModePersistsAndNeverTurnsItselfOff() {
        let d = defaults()
        let clock = FakeClock()
        let c = make(clock, defaults: d) { .response(latency: 0.1) }
        c.offlineMode = true
        // Good responses and a good path don't change the user's choice.
        c.pathChanged(satisfied: true)
        for _ in 0..<5 { c.record(.response(latency: 0.1)) }
        XCTAssertTrue(c.offlineMode)
        XCTAssertFalse(c.shouldUseNetwork)
        XCTAssertTrue(make(clock, defaults: d) { .noResponse }.offlineMode)
    }

    func testProveSendsSpacedProbes() async {
        let clock = FakeClock()
        var probes = 0
        let c = make(clock) { probes += 1; return .response(latency: 0.2) }
        let ok = await c.prove(.foreground)
        XCTAssertTrue(ok)
        XCTAssertEqual(probes, 3)
        XCTAssertEqual(clock.waits, [30, 30])
    }

    func testProveStopsAtAFailure() async {
        let clock = FakeClock()
        var outcomes: [RequestOutcome] = [.response(latency: 0.2), .noResponse, .response(latency: 0.2)]
        let c = make(clock) { outcomes.removeFirst() }
        let ok = await c.prove(.foreground)
        XCTAssertFalse(ok)
        XCTAssertEqual(outcomes.count, 1)
    }

    func testProveUsesTheAppsOwnRequests() async {
        let clock = FakeClock()
        var probes = 0
        let c = make(clock) { probes += 1; return .response(latency: 0.2) }
        c.record(.response(latency: 0.3))
        clock.now = clock.now.addingTimeInterval(30)
        c.record(.response(latency: 0.3))
        let ok = await c.prove(.foreground)
        XCTAssertTrue(ok)
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(clock.waits, [30])
    }

    func testProveDoesNothingOfflineOrWithNoRoute() async {
        let clock = FakeClock()
        var probes = 0
        let c = make(clock) { probes += 1; return .response(latency: 0.2) }
        c.offlineMode = true
        var ok = await c.prove()
        XCTAssertFalse(ok)
        c.offlineMode = false
        c.pathChanged(satisfied: false)
        ok = await c.prove()
        XCTAssertFalse(ok)
        XCTAssertEqual(probes, 0)
    }

    func testAPathChangeStartsAgain() {
        let clock = FakeClock()
        let c = make(clock) { .noResponse }
        c.pathChanged(satisfied: true)
        c.record(.response(latency: 0.1))
        c.pathChanged(satisfied: false)
        XCTAssertTrue(c.proof.streak.isEmpty)
    }
}
