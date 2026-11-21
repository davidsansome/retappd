import Foundation
import Observation

// Data approach for the Statistics screen
//
// `/v4/user/stats` returns period totals only, never a per-day series, so the chart's series is
// assembled per range:
//
// - 1W and 1M (day buckets), current period: page `/v4/user/checkins/{me}` (50 a page, newest
//   first) back to the period's start and count distinct `bid`s per local day. A busy week or
//   month is 1-4 requests. Capped at `maxCheckinPages`; if the cap is hit before the start, fall
//   back to the stats approach below.
// - 1W and 1M, stepped back: the checkins endpoint can only page by `max_id` (no date seek), so
//   reaching an old week would mean paging through everything since. Instead call `/user/stats`
//   once per day (7 or up to 31 requests, six at a time); its `distinct_beers` is the day's value.
// - 1Y: `/user/stats` once per calendar month (12 requests); the chart's value is that month's
//   `distinct_beers`. A month's distinct beers aren't the sum of its days, but it is the true
//   count for the bucket.
// - All: one `/user/stats` call from 2010 to learn `first_checkin_date`, then one per calendar
//   year since (about 14 for a 2013 account).
//
// Plus one `/user/stats` call for the whole period, which feeds the totals and breakdown table.
// - Custom (a start and end the user picked): the same loaders, by the length of the range:
//   up to 62 days is day buckets, up to about 3 years month buckets, longer year buckets. Day
//   buckets of a range ending today page the checkins (like the current week); older days, and
//   every month or year, are one `/user/stats` call per bucket. The first and last bucket are
//   clipped to the range (a range starting on 10 Mar at month granularity gets a "10-31 Mar"
//   bucket, not the whole month), so buckets never overlap or count days outside the range.
//   Requests: 1 (totals) + the bucket count (at most 62 days, 37 months or about 15 years), or
//   1 + at most 8 checkin pages for days ending today.
//
// Everything is cached in memory by range and offset (a custom range by its start and end
// dates) for the life of the screen (the current period is refetched when the screen is reopened). `/v4/user/beers` was not used: it lists
// distinct beers over a range with first/recent dates, but a beer had on two days appears
// once, so it can't give per-day distinct counts.

enum StatsRange: String, CaseIterable, Identifiable {
    case week = "1W", month = "1M", year = "1Y", all = "All"
    /// A start and end the user picked. Not one of the range buttons, so it isn't in `allCases`.
    case custom = "Custom"
    var id: String { rawValue }
    static let allCases: [StatsRange] = [.week, .month, .year, .all]
}

/// One bar of the chart: a day, month or year. `start`...`end` are inclusive days (clamped to
/// the period); `anchor` is the start of the calendar unit, where the chart plots it.
struct StatsBucket: Hashable {
    var start: Date
    var end: Date
    var anchor: Date
}

struct StatsPoint: Identifiable, Equatable {
    var bucket: StatsBucket
    var beers: Int
    var checkins: Int
    var id: Date { bucket.anchor }
}

/// The date range a range button and a step-back count select, and how it splits into buckets.
struct StatsPeriod: Equatable {
    enum Granularity { case day, month, year }

    var range: StatsRange
    var offset: Int
    var start: Date
    var end: Date
    var granularity: Granularity

    /// Untappd launched in 2010; where the all-time stats call starts before the first check-in is known.
    static let allTimeStart = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2010, month: 1, day: 1).date!

    /// - 1W: 7 days ending today (or `offset` weeks earlier).
    /// - 1M: a month up to and including today, then `offset` contiguous months earlier.
    /// - 1Y: the 12 calendar months ending with this one (`offset` years earlier, ending at that month's end).
    /// - All: from the first check-in (or 2010) to today; can't be stepped.
    static func make(_ range: StatsRange, offset: Int = 0, today: Date, firstCheckin: Date? = nil,
                     calendar cal: Calendar) -> StatsPeriod {
        let todayStart = cal.startOfDay(for: today)
        func add(_ c: Calendar.Component, _ n: Int, _ d: Date) -> Date { cal.date(byAdding: c, value: n, to: d)! }
        func monthStart(_ d: Date) -> Date { cal.dateInterval(of: .month, for: d)!.start }
        switch range {
        case .week:
            let end = add(.day, -7 * offset, todayStart)
            return StatsPeriod(range: range, offset: offset, start: add(.day, -6, end), end: end, granularity: .day)
        case .month:
            // Each period ends the day before the previous one starts, so stepping back never
            // overlaps or skips days around short months (31 Mar: 1-31 Mar, 29 Jan-28 Feb, ...).
            func window(endingOn end: Date) -> (Date, Date) {
                (add(.day, 1, add(.month, -1, end)), end)
            }
            var (start, end) = window(endingOn: todayStart)
            for _ in 0..<offset { (start, end) = window(endingOn: add(.day, -1, start)) }
            return StatsPeriod(range: range, offset: offset, start: start, end: end, granularity: .day)
        case .year:
            let anchor = add(.year, -offset, todayStart)
            let end = offset == 0 ? todayStart : add(.day, -1, add(.month, 1, monthStart(anchor)))
            let start = monthStart(add(.month, -11, anchor))
            return StatsPeriod(range: range, offset: offset, start: start, end: end, granularity: .month)
        case .custom:
            // Real custom periods come from `custom(start:end:…)`; this is a month ending today.
            return custom(start: add(.day, 1, add(.month, -1, todayStart)), end: todayStart, today: today,
                          firstCheckin: firstCheckin, calendar: cal)
        case .all:
            let start = min(cal.startOfDay(for: firstCheckin ?? allTimeStart), todayStart)
            return StatsPeriod(range: range, offset: 0, start: start, end: todayStart, granularity: .year)
        }
    }

    /// A period the user picked. Both ends are clamped to `firstCheckin`...today (the latter
    /// first, so a start in the future becomes today), and the end is never before the start.
    /// Buckets: up to 62 days is days, up to 3 years (1096 days) months, longer years.
    static func custom(start: Date, end: Date, today: Date, firstCheckin: Date? = nil, calendar cal: Calendar) -> StatsPeriod {
        let todayStart = cal.startOfDay(for: today)
        let floor = min(cal.startOfDay(for: firstCheckin ?? allTimeStart), todayStart)
        let e = min(max(cal.startOfDay(for: end), floor), todayStart)
        let s = min(max(cal.startOfDay(for: start), floor), e)
        let days = (cal.dateComponents([.day], from: s, to: e).day ?? 0) + 1
        let g: Granularity = days <= 62 ? .day : days <= 1096 ? .month : .year
        return StatsPeriod(range: .custom, offset: 0, start: s, end: e, granularity: g)
    }

    /// What the cache files this period under: the range and offset, or a custom period's dates.
    func cacheKey(calendar cal: Calendar) -> String {
        range == .custom
            ? "custom/\(Self.apiDate(start, calendar: cal))/\(Self.apiDate(end, calendar: cal))"
            : "\(range.rawValue)/\(offset)"
    }

    /// Days in the period, both ends included.
    func dayCount(calendar cal: Calendar) -> Int {
        (cal.dateComponents([.day], from: start, to: end).day ?? 0) + 1
    }

    func buckets(calendar cal: Calendar) -> [StatsBucket] {
        var result: [StatsBucket] = []
        switch granularity {
        case .day:
            var d = start
            while d <= end {
                result.append(StatsBucket(start: d, end: d, anchor: d))
                d = cal.date(byAdding: .day, value: 1, to: d)!
            }
        case .month, .year:
            let unit: Calendar.Component = granularity == .month ? .month : .year
            var a = cal.dateInterval(of: unit, for: start)!.start
            while a <= end {
                let next = cal.date(byAdding: unit, value: 1, to: a)!
                let last = cal.date(byAdding: .day, value: -1, to: next)!
                result.append(StatsBucket(start: max(a, start), end: min(last, end), anchor: a))
                a = next
            }
        }
        return result
    }

    /// "NOV 12 – NOV 18" (with years unless both days are this year), "NOV 2025 – NOV 2026", "2013 – 2026", or just "2026" for a single year.
    /// Custom ranges always use day precision so users see the exact dates they picked.
    func caption(today: Date = Date(), calendar cal: Calendar = .current) -> String {
        var style = Date.FormatStyle(calendar: cal, timeZone: cal.timeZone)
        if range == .custom || granularity == .day {
            // Add the year when the days aren't both in this year.
            let year = cal.component(.year, from: today)
            let inYear = cal.component(.year, from: start) == year && cal.component(.year, from: end) == year
            style = inYear ? style.month(.abbreviated).day() : style.month(.abbreviated).day().year()
        } else if granularity == .month {
            style = style.month(.abbreviated).year()
        } else {
            style = style.year()
        }
        let (a, b) = (start.formatted(style), end.formatted(style))
        return (a == b ? a : "\(a) – \(b)").uppercased()
    }

    /// `yyyy-MM-dd` in `cal`'s time zone, as `/user/stats` wants.
    static func apiDate(_ d: Date, calendar cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

enum StatsBucketing {
    struct DayCount: Equatable {
        var beers: Set<Int> = []
        var checkins = 0
    }

    /// Distinct beers and checkins per local day.
    static func dailyCounts(_ checkins: [Checkin], calendar cal: Calendar) -> [Date: DayCount] {
        var out: [Date: DayCount] = [:]
        for c in checkins {
            guard let t = c.createdAt else { continue }
            let day = cal.startOfDay(for: t)
            out[day, default: DayCount()].checkins += 1
            if let bid = c.beer?.bid, bid != 0 { out[day, default: DayCount()].beers.insert(bid) }
        }
        return out
    }

    /// One point per day bucket from `from` on (earlier days aren't loaded yet), zero where
    /// nothing was checked in.
    static func points(buckets: [StatsBucket], counts: [Date: DayCount], from: Date) -> [StatsPoint] {
        buckets.filter { $0.start >= from }.map {
            let n = counts[$0.start]
            return StatsPoint(bucket: $0, beers: n?.beers.count ?? 0, checkins: n?.checkins ?? 0)
        }
    }
}

/// Where the model gets its numbers; tests supply fakes.
struct StatsSource {
    /// Totals for `start`...`end` (inclusive days) in a time zone `gmtHours` from GMT.
    var stats: @MainActor @Sendable (_ start: Date, _ end: Date, _ gmtHours: Double) async throws -> UserStats
    /// A page of the user's checkins, newest first.
    var checkins: @MainActor @Sendable (_ maxId: Int?) async throws -> CheckinPage

    static func live(username: String) -> StatsSource {
        StatsSource(
            stats: { start, end, gmt in
                let cal = Calendar.current
                let r = APIRequest.userStats(start: StatsPeriod.apiDate(start, calendar: cal),
                                             end: StatsPeriod.apiDate(end, calendar: cal), gmtOffset: gmt)
                return try await UntappdAPI.shared.fetch(r, as: UserStatsResponse.self).stats
            },
            checkins: { maxId in
                try await UntappdAPI.shared.fetch(.userCheckins(username, maxId: maxId, limit: 50), as: CheckinPage.self)
            })
    }
}

@Observable @MainActor
final class StatsModel {
    private(set) var range = StatsRange.week
    private(set) var offset = 0
    private(set) var period: StatsPeriod
    /// The picked start and end while `range` is `.custom`.
    private var customPeriod: StatsPeriod?
    /// The length in days the user asked for. Stepping uses it rather than `period`'s, which
    /// is shorter when the first check-in clipped it, so stepping forward again restores it.
    private var customLength: Int?
    private(set) var stats: UserStats?
    private(set) var points: [StatsPoint] = []
    private(set) var isLoading = false
    private(set) var error: String?
    /// How many of the series' requests have finished, and how many there'll be (0 when unknown).
    private(set) var progress = 0
    private(set) var expected = 0
    private(set) var firstCheckin: Date?

    private struct Loaded { var period: StatsPeriod; var stats: UserStats?; var points: [StatsPoint] }
    private var cache: [String: Loaded] = [:]
    /// The day the cache was filled: every period is measured back from today, so a new day
    /// makes all of it stale.
    private var cacheDay = Date.distantPast
    private var task: Task<Void, Never>?
    /// Bumped by every `load()`. A load only touches the model while its number is current, so
    /// a cancelled one that is still winding down can't overwrite what a newer one shows.
    private var generation = 0
    /// The range and offset the numbers on screen belong to.
    private var shownKey: String?
    private let source: StatsSource
    private let now: @Sendable () -> Date
    private var calendar: Calendar { .current }
    private let maxCheckinPages = 8
    private let concurrency = 6

    init(source: StatsSource, now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.now = now
        period = StatsPeriod.make(.week, today: now(), calendar: .current)
    }

    convenience init(username: String) { self.init(source: .live(username: username)) }

    var canStepForward: Bool {
        range == .custom ? period.end < calendar.startOfDay(for: now()) : offset > 0
    }
    var canStepBack: Bool {
        guard range != .all else { return false }
        if let firstCheckin { return period.start > calendar.startOfDay(for: firstCheckin) }
        return true
    }

    /// Picks a range button. `.custom` can only come from `setCustom`.
    func select(_ r: StatsRange) {
        guard r != range, r != .custom else { return }
        range = r
        offset = 0
        customPeriod = nil
        customLength = nil
        load()
    }

    /// Shows `start`...`end` (inclusive days), clamped to the first check-in and today.
    func setCustom(start: Date, end: Date, length: Int? = nil) {
        let p = StatsPeriod.custom(start: start, end: end, today: now(), firstCheckin: firstCheckin, calendar: calendar)
        guard range != .custom || p != customPeriod else { return }
        range = .custom
        offset = 0
        customPeriod = p
        customLength = length ?? p.dayCount(calendar: calendar)
        load()
    }

    /// Steps back (`delta` 1) or forward (-1) a period. A custom range moves by its own length:
    /// back ends the day before it starts (clipped at the first check-in, which shortens it),
    /// forward starts the day after it ends and keeps its length, ending no later than today
    /// (so the last step may overlap days already seen).
    func step(_ delta: Int) {
        guard range != .all else { return }
        if range == .custom {
            let cal = calendar
            let today = cal.startOfDay(for: now())
            let days = customLength ?? period.dayCount(calendar: cal)
            func add(_ n: Int, _ d: Date) -> Date { cal.date(byAdding: .day, value: n, to: d)! }
            if delta > 0 {
                guard canStepBack else { return }
                let end = add(-1, period.start)
                setCustom(start: add(-(days - 1), end), end: end, length: days)
            } else if delta < 0 {
                guard canStepForward else { return }
                let end = min(add(days, period.end), today)
                setCustom(start: add(-(days - 1), end), end: end, length: days)
            }
            return
        }
        let n = offset + delta
        guard n >= 0 else { return }
        offset = n
        load()
    }

    /// The UTC offset in hours at `date`, so a request spanning a DST change still gets the
    /// offset in force on its first day. Half-hour zones send e.g. "5.5"; the docs show only
    /// whole hours, so how the server takes those is unverified.
    private func gmtHours(at date: Date) -> Double {
        Double(calendar.timeZone.secondsFromGMT(for: date)) / 3600
    }


    /// Shows the selection from the cache if it's there, else fetches it. `force` refetches
    /// either way, leaving what's on screen until the new numbers arrive.
    @discardableResult
    func load(force: Bool = false) -> Task<Void, Never>? {
        task?.cancel()
        generation += 1
        let gen = generation
        let today = calendar.startOfDay(for: now())
        if today != cacheDay { cache = [:]; cacheDay = today }
        let start = (range == .custom ? customPeriod : nil)
            ?? StatsPeriod.make(range, offset: offset, today: now(), firstCheckin: firstCheckin, calendar: calendar)
        let key = start.cacheKey(calendar: calendar)
        if !force, let c = cache[key] {
            period = c.period; stats = c.stats; points = c.points
            isLoading = false; error = nil; shownKey = key
            task = nil
            return nil
        }
        if shownKey != key {
            period = start; stats = nil; points = []; shownKey = key
        }
        error = nil; isLoading = true; progress = 0; expected = 0
        let r = range
        let t = Task { await run(range: r, start: start, key: key, gen: gen) }
        task = t
        return t
    }

    /// Reloads and waits for it (pull to refresh).
    func refresh() async { await load(force: true)?.value }

    /// Waits for the current load, if any.
    func waitUntilIdle() async { await task?.value }

    private func isCurrent(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    private func run(range: StatsRange, start: StatsPeriod, key: String, gen: Int) async {
        do {
            guard isCurrent(gen) else { throw CancellationError() }
            // Structured, so it's cancelled and awaited if this load is.
            async let totals = source.stats(start.start, start.end, gmtHours(at: start.start))
            var newStats: UserStats?
            let p: StatsPeriod
            if range == .all {
                let t = try await totals
                try Task.checkCancellation()
                guard isCurrent(gen) else { return }
                firstCheckin = t.firstCheckinDate
                p = StatsPeriod.make(.all, today: now(), firstCheckin: t.firstCheckinDate, calendar: calendar)
                period = p
                stats = t
                newStats = t
            } else {
                p = start
            }
            let buckets = p.buckets(calendar: calendar)
            var done = false
            var complete = true
            if p.granularity == .day && p.end >= calendar.startOfDay(for: now()) { done = try await seriesFromCheckins(p, buckets, gen: gen) }
            if !done { complete = try await seriesFromStats(buckets, gen: gen) }
            if range != .all { newStats = try await totals }
            try Task.checkCancellation()
            guard isCurrent(gen) else { return }
            stats = newStats
            if firstCheckin == nil { firstCheckin = newStats?.firstCheckinDate }
            // A chart with missing buckets isn't cached, so reselecting it retries.
            if complete {
                cache[key] = Loaded(period: p, stats: newStats, points: points)
            } else {
                error = "Some of the chart couldn't be loaded."
            }
            isLoading = false
        } catch is CancellationError {
        } catch {
            guard isCurrent(gen) else { return }
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    /// Pages the user's checkins back to the period's start. Returns false (without having set
    /// any points) if that took more than `maxCheckinPages` pages.
    private func seriesFromCheckins(_ p: StatsPeriod, _ buckets: [StatsBucket], gen: Int) async throws -> Bool {
        let cal = calendar
        var all: [Checkin] = []
        var maxId: Int?
        var pages = 0
        var reachedStart = false
        guard isCurrent(gen) else { throw CancellationError() }
        expected = 0
        while pages < maxCheckinPages, !reachedStart {
            let page = try await source.checkins(maxId)
            try Task.checkCancellation()
            guard isCurrent(gen) else { throw CancellationError() }
            pages += 1
            progress = pages
            all += page.checkins.filter { ($0.createdAt ?? .distantFuture) >= p.start }
            let oldest = page.checkins.compactMap(\.createdAt).min()
            maxId = page.nextMaxId
            reachedStart = page.checkins.isEmpty || maxId == nil || (oldest.map { $0 < p.start } ?? false)
            // The oldest day loaded may be cut off, so only draw days after it until we're done.
            let from = reachedStart ? p.start : (oldest.map { cal.startOfDay(for: $0).addingTimeInterval(86_400 * 1.5) } ?? p.start)
            points = StatsBucketing.points(buckets: buckets, counts: StatsBucketing.dailyCounts(all, calendar: cal),
                                           from: cal.startOfDay(for: from))
        }
        if !reachedStart { points = [] }
        return reachedStart
    }

    /// One `/user/stats` call per bucket, `concurrency` at a time, drawn as they arrive. Returns
    /// false if some buckets failed (what did load is still drawn).
    private func seriesFromStats(_ buckets: [StatsBucket], gen: Int) async throws -> Bool {
        guard isCurrent(gen) else { throw CancellationError() }
        expected = buckets.count
        progress = 0
        var results: [Int: StatsPoint] = [:]
        var failure: Error?
        let source = source
        let gmts = buckets.map { gmtHours(at: $0.start) }
        await withTaskGroup(of: (Int, StatsPoint?, Error?).self) { group in
            var next = 0
            func enqueue() {
                guard next < buckets.count else { return }
                let i = next, b = buckets[i]
                next += 1
                let gmt = gmts[i]
                group.addTask {
                    do {
                        let s = try await source.stats(b.start, b.end, gmt)
                        return (i, StatsPoint(bucket: b, beers: s.distinctBeers, checkins: s.totalCheckins), nil)
                    } catch { return (i, nil, error) }
                }
            }
            for _ in 0..<concurrency { enqueue() }
            for await (i, pt, err) in group {
                guard isCurrent(gen) else { group.cancelAll(); break }
                if let pt { results[i] = pt } else if let err { failure = err }
                progress += 1
                points = results.keys.sorted().map { results[$0]! }
                enqueue()
            }
        }
        try Task.checkCancellation()
        guard isCurrent(gen) else { throw CancellationError() }
        if results.isEmpty, let failure { throw failure }
        return failure == nil
    }
}
