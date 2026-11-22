import Foundation
import Network
import Observation

/// What happened to one request, as `UntappdAPI` reports it.
enum RequestOutcome: Sendable, Equatable {
    /// A response arrived (whatever its status), after `latency` seconds.
    case response(latency: TimeInterval)
    /// No response: the request failed in transport or timed out.
    case noResponse
}

/// Whether recent requests prove the connection is good: enough fast responses, spread over
/// enough time, with no failure or slow response since. One lucky request on a flaky pub signal
/// (or a captive portal) doesn't count, and nor does a burst of requests all at once.
struct ConnectionProof: Equatable {
    struct Rule: Equatable {
        /// How many spaced-out fast responses it takes.
        var responses: Int
        /// A response slower than this breaks the streak.
        var maxLatency: TimeInterval
        /// The first and last counted responses must be at least this far apart; counted
        /// responses are at least `span / (responses - 1)` apart.
        var span: TimeInterval
        /// A proof older than this (since its last response) has gone stale.
        var freshness: TimeInterval

        var gap: TimeInterval { responses > 1 ? span / Double(responses - 1) : 0 }

        /// With the app open: 3 responses under 3 s, over at least a minute.
        static let foreground = Rule(responses: 3, maxLatency: 3, span: 60, freshness: 120)
        /// A background refresh only gets about 30 s, so the same check, squeezed: 3 responses
        /// over at least 20 s.
        static let background = Rule(responses: 3, maxLatency: 3, span: 20, freshness: 60)
    }

    /// Times of the fast responses since the streak last broke, oldest first.
    private(set) var streak: [Date] = []

    mutating func record(_ outcome: RequestOutcome, at date: Date, maxLatency: TimeInterval) {
        switch outcome {
        case .response(let latency) where latency <= maxLatency:
            streak.append(date)
            if streak.count > 50 { streak.removeFirst(streak.count - 50) }
        case .response, .noResponse:
            streak = []
        }
    }

    mutating func reset() { streak = [] }

    /// The responses that count towards `rule`: the first of the streak, then each one at least
    /// `rule.gap` after the last counted.
    func counted(_ rule: Rule) -> [Date] {
        var out: [Date] = []
        for t in streak where out.last.map({ t.timeIntervalSince($0) >= rule.gap }) ?? true {
            out.append(t)
        }
        return out
    }

    func isProven(_ rule: Rule, now: Date) -> Bool {
        let c = counted(rule)
        guard c.count >= rule.responses, let first = c.first, let last = c.last else { return false }
        return last.timeIntervalSince(first) >= rule.span && now.timeIntervalSince(last) <= rule.freshness
    }

    /// When the next request would count, if it's fast: now if nothing has counted yet.
    func nextUsefulRequest(_ rule: Rule, now: Date) -> Date {
        guard let last = counted(rule).last else { return now }
        return max(now, last.addingTimeInterval(rule.gap))
    }
}

/// The app's idea of whether it's online, and the user's offline-mode switch.
///
/// - **Offline mode** is the user's choice and only the user changes it: nothing here turns it
///   off when the network comes back. While it's on, nothing should be sent.
/// - **The network path** (`NWPathMonitor`) is only a hint. "No route" means don't bother
///   trying; "satisfied" proves nothing, because flaky signal and captive portals report it too.
/// - **Proof** comes from real Untappd responses, see `ConnectionProof`. Every request the app
///   makes feeds it, and `prove(_:)` sends cheap probes to fill the gaps.
@MainActor @Observable
final class Connectivity {
    static let shared = Connectivity()

    static let offlineModeKey = "offlineMode"

    /// The user's switch. Persisted.
    var offlineMode: Bool {
        get { storedOfflineMode }
        set {
            guard newValue != storedOfflineMode else { return }
            storedOfflineMode = newValue
            defaults.set(newValue, forKey: Self.offlineModeKey)
            applyOfflineMode(newValue)
            if newValue { proof.reset() }
            userWentOnline = !newValue
        }
    }
    private var storedOfflineMode: Bool

    /// True after the user turns offline mode off, until the network path changes or offline
    /// mode goes back on. Switching back online yourself says you think the connection is good,
    /// so the "To check in" list shows at once instead of waiting for `prove(_:)`.
    private(set) var userWentOnline = false

    /// From `NWPathMonitor`: nil until it has reported.
    private(set) var pathSatisfied: Bool?
    private(set) var proof = ConnectionProof()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let applyOfflineMode: (Bool) -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let wait: (TimeInterval) async -> Void
    @ObservationIgnored private let probe: () async -> RequestOutcome
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var proving: Task<Bool, Never>?

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         wait: @escaping (TimeInterval) async -> Void = { s in try? await Task.sleep(for: .seconds(s)) },
         probe: (() async -> RequestOutcome)? = nil,
         applyOfflineMode: @escaping (Bool) -> Void = { UntappdAPI.shared.isOffline = $0 }) {
        self.defaults = defaults
        self.applyOfflineMode = applyOfflineMode
        self.now = now
        self.wait = wait
        self.probe = probe ?? Connectivity.defaultProbe
        storedOfflineMode = defaults.bool(forKey: Self.offlineModeKey)
        applyOfflineMode(storedOfflineMode)
    }

    /// Whether it's worth sending anything at all.
    var shouldUseNetwork: Bool { !offlineMode && pathSatisfied != false }

    /// Whether recent responses prove a good connection (and offline mode is off).
    func isProven(_ rule: ConnectionProof.Rule = .foreground) -> Bool {
        shouldUseNetwork && proof.isProven(rule, now: now())
    }

    /// Takes in a request's outcome. `UntappdAPI.onRequestOutcome` calls this for every request.
    func record(_ outcome: RequestOutcome) {
        proof.record(outcome, at: now(), maxLatency: ConnectionProof.Rule.foreground.maxLatency)
    }

    /// Starts watching the network path. Call once at launch.
    func startMonitoring() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(satisfied: ok) }
        }
        m.start(queue: DispatchQueue(label: "Connectivity.path"))
        monitor = m
    }

    func pathChanged(satisfied: Bool) {
        // A new path (Wi-Fi to cellular, or losing signal) says nothing for the old streak.
        if pathSatisfied != satisfied {
            proof.reset()
            if pathSatisfied != nil { userWentOnline = false }
        }
        pathSatisfied = satisfied
    }

    /// Sends probes, spaced out, until `rule` is proven (true) or a probe fails or is slow
    /// (false). Requests the app makes meanwhile count too. Concurrent calls share one run.
    func prove(_ rule: ConnectionProof.Rule = .foreground) async -> Bool {
        if let proving { return await proving.value }
        let task = Task { await self.runProof(rule) }
        proving = task
        let result = await task.value
        proving = nil
        return result
    }

    private func runProof(_ rule: ConnectionProof.Rule) async -> Bool {
        // Enough probes for a whole proof from scratch, plus one for luck.
        for _ in 0...rule.responses {
            if isProven(rule) { return true }
            guard shouldUseNetwork, !Task.isCancelled else { return false }
            let at = proof.nextUsefulRequest(rule, now: now())
            let delay = at.timeIntervalSince(now())
            if delay > 0 { await wait(delay) }
            if isProven(rule) { return true }
            guard shouldUseNetwork, !Task.isCancelled else { return false }
            let outcome = await probe()
            proof.record(outcome, at: now(), maxLatency: rule.maxLatency)
            if proof.streak.isEmpty { return false }
        }
        return isProven(rule)
    }

    /// A small authenticated request: the signed-in user's compact profile. `UntappdAPI` reports
    /// its outcome through `onRequestOutcome` as well, so it's recorded twice at the same moment;
    /// `ConnectionProof` only counts responses at least `gap` apart, so that's harmless.
    private static func defaultProbe() async -> RequestOutcome {
        guard let user = UserDefaults.standard.string(forKey: "username") else { return .noResponse }
        let start = ContinuousClock.now
        do {
            _ = try await UntappdAPI.shared.data(.userInfo(user))
        } catch let e as APIError {
            switch e {
            case .unauthorized, .offline: return .noResponse
            default: break  // the server answered, if with an error
            }
        } catch {
            return .noResponse
        }
        return .response(latency: UntappdAPI.seconds(ContinuousClock.now - start))
    }
}
