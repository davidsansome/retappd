import Charts
import SwiftUI

/// Statistics for the signed-in user: a range picker, totals, a chart of unique beers per
/// day / month / year you can scrub, a check-in breakdown and the period's top beers. See
/// `StatsModel` for where each range's numbers come from.
struct StatsView: View {
    @State private var model: StatsModel
    @State private var selected: Date?
    @State private var didLoad = false
    @State private var picking = false
    @State private var chartWidth: CGFloat = 320
    /// Whether the bars carry their unique-beer count. Kept across launches.
    @AppStorage("statsShowBarValues") private var showValues = false
    /// A press-and-drag on the chart is in progress, or just ended: its release isn't a tap.
    @GestureState private var scrubbing = false
    @State private var lastScrubEnd = Date.distantPast
    @State private var containerWidth: CGFloat = 0

    init(username: String) {
        _model = State(initialValue: StatsModel(username: username))
    }

    private var isTwoColumn: Bool { containerWidth >= .twoColumnThreshold }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                TaproomSegmented(options: StatsRange.allCases.map { ($0, $0.rawValue) },
                                 selection: Binding(get: { model.range }, set: { model.select($0); selected = nil }))
                    .frame(maxWidth: .readableContentWidth)
                    .frame(maxWidth: .infinity)
                if isTwoColumn {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                            periodHeader
                            chartCard
                            if let error = model.error {
                                ErrorRow(message: error) { model.load(force: true) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let s = model.stats {
                            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                                TaproomSection("Check-in breakdown") { breakdown(s) }
                                if !s.topBeers.isEmpty { topBeers(s) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    periodHeader
                    chartCard
                    if let error = model.error {
                        ErrorRow(message: error) { model.load(force: true) }
                    }
                    if let s = model.stats {
                        TaproomSection("Check-in breakdown") { breakdown(s) }
                        if !s.topBeers.isEmpty { topBeers(s) }
                    }
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: isTwoColumn ? .wideContentWidth : .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        .taproomScreen()
        .navigationTitle("Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task {
            // Once per screen: `.task` runs again on coming back from a beer's page, and that
            // shouldn't refetch the whole series.
            guard !didLoad else { return }
            didLoad = true
            model.load(force: true)
        }
        .refreshable { await model.refresh() }
        .sheet(isPresented: $picking) {
            StatsRangeSheet(start: model.period.start, end: model.period.end,
                            earliest: model.firstCheckin ?? StatsPeriod.allTimeStart, latest: Date()) { s, e in
                selected = nil
                model.setCustom(start: s, end: e)
            }
        }
    }

    // MARK: Header

    private var selectedPoint: StatsPoint? {
        guard let selected else { return nil }
        // The bar under the finger: the last one starting at or before it.
        return model.points.last { $0.bucket.anchor <= selected } ?? model.points.first
    }

    /// The period stepper, then the totals; while scrubbing, the touched bucket's figures instead.
    private var periodHeader: some View {
        let caption = model.period.caption()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                stepButton("chevron.left", label: "Previous period", enabled: model.canStepBack) { model.step(1); selected = nil }
                Spacer()
                Button { picking = true } label: {
                    HStack(spacing: 6) {
                        Text(caption)
                            .font(.footnote.weight(.bold)).tracking(0.6)
                            .contentTransition(.numericText())
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Image(systemName: "calendar").font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(Taproom.ink)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(caption)
                .accessibilityHint("Choose a date range")
                .accessibilityAddTraits([.isHeader, .isButton])
                Spacer()
                stepButton("chevron.right", label: "Next period", enabled: model.canStepForward) { model.step(-1); selected = nil }
            }
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                if let p = selectedPoint {
                    figure(p.beers, "unique beers")
                    figure(p.checkins, "check-ins")
                    Spacer(minLength: 0)
                    Text(label(for: p.bucket)).font(.subheadline.weight(.semibold)).foregroundStyle(Taproom.muted)
                } else {
                    figure(model.stats?.distinctBeers, "unique beers")
                    figure(model.stats?.totalCheckins, "check-ins")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func stepButton(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.bold)).frame(width: 44, height: 44)
        }
        .foregroundStyle(enabled ? Taproom.ink : Taproom.glassRim)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func figure(_ n: Int?, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(n.map { $0.formatted() } ?? "–")
                .font(.system(size: 44, weight: .heavy).monospacedDigit())
                .tracking(-1)
                .contentTransition(.numericText(value: Double(n ?? 0)))
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(caption).font(.subheadline).foregroundStyle(Taproom.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private func label(for b: StatsBucket) -> String {
        switch model.period.granularity {
        case .day: b.anchor.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .month: b.anchor.formatted(.dateTime.month(.wide).year())
        case .year: b.anchor.formatted(.dateTime.year())
        }
    }

    // MARK: Chart

    private var chartCard: some View {
        let points = model.points
        let top = max(points.map(\.beers).max() ?? 0, 1)
        let step = max(1, Int((Double(top) / 4).rounded(.up)))
        let yTop = ((top + step - 1) / step) * step
        let cal = Calendar.current
        let buckets = model.period.buckets(calendar: cal)
        let unit: Calendar.Component = switch model.period.granularity { case .day: .day; case .month: .month; case .year: .year }
        // Bars fill their whole day, month or year, so the plot runs to the end of the last one.
        let lo = buckets.first?.anchor ?? Date()
        let hi = buckets.last.flatMap { cal.date(byAdding: unit, value: 1, to: $0.anchor) } ?? lo.addingTimeInterval(86_400)
        let chosen = selectedPoint
        // Always leave a little headroom above the top gridline so toggling bar values on and off
        // never shifts the y-scale or moves the bars; the axis still stops at `yTop`.
        let yMax = Double(yTop) * 1.14
        let labelEvery = valueLabelSpacing(count: buckets.count, maxValue: top)
        // Labels go from the newest bar back on every non-empty bar that is at least `labelEvery`
        // bars before the last labelled one, so crowded stretches thin out and lone bars always show.
        var labelled = Set<Date>()
        var lastLabelled = buckets.count + labelEvery
        for (i, b) in buckets.enumerated().reversed() {
            guard let v = points.first(where: { $0.bucket.anchor == b.anchor })?.beers, v > 0,
                  lastLabelled - i >= labelEvery else { continue }
            labelled.insert(b.anchor)
            lastLabelled = i
        }

        return Chart {
            ForEach(points) { p in
                BarMark(x: .value("Date", p.bucket.anchor, unit: unit), y: .value("Unique beers", p.beers))
                    .foregroundStyle(Taproom.amber.opacity(chosen == nil || chosen?.id == p.id ? 1 : 0.35))
                    .cornerRadius(3)
                    .annotation(position: .top, spacing: 2) {
                        // Zero bars get no label: a row of "0"s only adds noise. Dense charts
                        // label bars at least n apart, and always the touched one.
                        if showValues, p.beers > 0,
                           chosen?.id == p.id || labelled.contains(p.bucket.anchor) {
                            Text("\(p.beers)")
                                .font(.caption2.weight(chosen?.id == p.id ? .bold : .medium).monospacedDigit())
                                .foregroundStyle(chosen?.id == p.id ? Taproom.ink : Taproom.muted)
                                .fixedSize()
                        }
                    }
                    .accessibilityLabel(label(for: p.bucket))
                    .accessibilityValue("\(p.beers) unique beers, \(p.checkins) check-ins")
            }
        }
        .chartXScale(domain: lo...hi)
        .chartYScale(domain: 0...yMax)
        .chartOverlay { proxy in chartGestures(proxy) }
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(stride(from: 0, through: yTop, by: step))) { _ in
                AxisGridLine().foregroundStyle(Taproom.border)
                AxisValueLabel().foregroundStyle(Taproom.muted).font(.caption2)
            }
        }
        .chartXAxis {
            switch model.period.granularity {
            case .day where model.range == .week:
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true).foregroundStyle(Taproom.muted).font(.caption2)
                }
            case .day:
                AxisMarks(values: .stride(by: .day, count: max(1, (buckets.count + 4) / 5))) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true).foregroundStyle(Taproom.muted).font(.caption2)
                }
            case .month where buckets.count <= 12:
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: buckets.count <= 6 ? .dateTime.month(.abbreviated) : .dateTime.month(.narrow),
                                   centered: true).foregroundStyle(Taproom.muted).font(.caption2)
                }
            case .month:
                AxisMarks(values: .stride(by: .month, count: max(1, (buckets.count + 5) / 6))) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits), centered: true).foregroundStyle(Taproom.muted).font(.caption2)
                }
            case .year:
                AxisMarks(values: .stride(by: .year, count: max(1, (buckets.count + 5) / 6))) { _ in
                    AxisValueLabel(format: .dateTime.year(), centered: true).foregroundStyle(Taproom.muted).font(.caption2)
                }
            }
        }
        .frame(height: 220)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chartWidth = $0 }
        .accessibilityAction(named: showValues ? "Hide values on bars" : "Show values on bars") {
            withAnimation(.easeOut(duration: 0.2)) { showValues.toggle() }
        }
        .overlay {
            if model.isLoading && points.isEmpty { ProgressView().tint(Taproom.muted) }
        }
        .overlay(alignment: .topTrailing) {
            if model.isLoading && model.expected > 0 && !points.isEmpty {
                Text("Loading \(model.progress)/\(model.expected)").font(.caption2).foregroundStyle(Taproom.muted)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .taproomCard()
        .animation(.easeOut(duration: 0.25), value: points)
        .sensoryFeedback(.selection, trigger: chosen?.id)
    }

    /// Show every nth label so neighbouring ones never touch: a label is about as wide as its
    /// digits plus a small gap, and each bar gets the plot's width divided by the bar count
    /// (the axis labels take about 30pt).
    private func valueLabelSpacing(count: Int, maxValue: Int) -> Int {
        let digits = CGFloat(String(maxValue).count)
        let needed = digits * 7 + 5
        let slot = max(chartWidth - 30, 1) / CGFloat(max(count, 1))
        return max(1, Int((needed / slot).rounded(.up)))
    }

    /// A tap toggles the bar values; pressing and dragging scrubs, selecting the bar under the
    /// finger until release. `chartXSelection` isn't used because it selects on a plain tap too.
    /// The press has to hold for a moment before it scrubs, so a vertical swipe still scrolls.
    private func chartGestures(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let plotX = proxy.plotFrame.map { geo[$0].minX } ?? 0
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { _ in
                        guard !scrubbing, Date().timeIntervalSince(lastScrubEnd) > 0.3 else { return }
                        withAnimation(.easeOut(duration: 0.2)) { showValues.toggle() }
                    }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.2)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        // `updating` resets on cancel too (the page scrolling away, an interruption,
                        // a hold that never moved), which `onEnded` doesn't see.
                        .updating($scrubbing) { value, state, _ in
                            if case .second(true, _) = value { state = true }
                        }
                        .onChanged { value in
                            guard case .second(true, let drag) = value, let x = drag?.location.x else { return }
                            selected = proxy.value(atX: x - plotX, as: Date.self)
                        }
                )
                .onChange(of: scrubbing) { _, now in
                    if !now { selected = nil; lastScrubEnd = Date() }
                }
        }
        .accessibilityHidden(true)
    }

    // MARK: Breakdown and top beers

    private func breakdown(_ s: UserStats) -> some View {
        let rows: [(String, String)] = [
            ("Unique beers", s.distinctBeers.formatted()),
            ("Check-ins", s.totalCheckins.formatted()),
            ("New beers", s.newBeers.formatted()),
            ("New places", s.newVenues.formatted()),
            ("Places visited", s.totalVenues.formatted()),
            // Worked out here: the API rounds its own average to a whole number (0 for most people).
            ("Check-ins per day", (Double(s.totalCheckins) / Double(max(1, model.period.dayCount(calendar: .current))))
                .formatted(.number.precision(.fractionLength(0...1)))),
            ("New beer ratio", "\(s.newBeersPercent)%"),
            ("New place ratio", "\(s.newVenuesPercent)%"),
        ]
        return VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                TaproomStatRow(label: rows[i].0, value: rows[i].1)
                if i < rows.count - 1 { Rectangle().fill(Taproom.border).frame(height: 1).padding(.leading, 14) }
            }
        }
        .taproomCard()
    }

    /// Each row opens the beer's page.
    private func topBeers(_ s: UserStats) -> some View {
        TaproomSection("Top beers") {
            VStack(spacing: 0) {
                ForEach(s.topBeers) { t in
                    NavigationLink(value: BeerBreweryRoute.beer(t.beer)) {
                        BeerRow(beer: t.beer, detail: t.count == 1 ? "1 check-in" : "\(t.count) check-ins")
                    }
                    .buttonStyle(TaproomRowStyle())
                    .taproomRowDivider()
                }
            }
        }
    }
}
