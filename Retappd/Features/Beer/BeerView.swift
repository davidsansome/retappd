import SwiftUI

@Observable @MainActor
final class BeerModel {
    /// What we knew when the page opened, kept up to date from the full record as it loads.
    private(set) var beer: BeerLite
    private(set) var info: BeerInfo?
    private(set) var flavors: [FlavorTag] = []
    /// The user's own rating, from `beer/info`, or `beer/userrating` if that didn't have it.
    private(set) var yourRating: Double?
    private(set) var loadError: String?
    let checkins: CheckinListModel
    private var firstLoad: Task<Void, Never>?

    init(beer: BeerLite) {
        self.beer = beer
        checkins = CheckinListModel(source: .beer(beer.bid))
    }

    var hadIt: Bool { HadBeers.shared.has(beer.bid, fallback: info?.hasHad ?? beer.hasHad) }
    var breweryId: Int? { info?.brewery.flatMap { $0.id > 0 ? $0.id : nil } ?? beer.breweryId }
    var breweryName: String { info?.brewery?.name ?? beer.brewery }

    /// Loads the page. The first load runs in a task of its own, so leaving the page part way
    /// through doesn't leave it half loaded when it's shown again.
    func load(force: Bool = false) async {
        if force {
            await fetch()
            return
        }
        if firstLoad == nil { firstLoad = Task { await fetch() } }
        await firstLoad?.value
    }

    private func fetch() async {
        async let i: Void = loadInfo()
        async let f: Void = loadFlavors()
        _ = await (i, f)
        if info?.hasHad == true, yourRating == nil { await loadUserRating() }
    }

    private func loadInfo() async {
        let apply = { (i: BeerInfo) in
            self.info = i
            self.yourRating = i.yourRating
            self.beer = i.lite
        }
        do {
            apply(try await cacheThenNetwork(.beerInfo(beer.bid), as: BeerInfo.self, onCached: apply))
            loadError = nil
            Task.detached(priority: .utility) { [lite = beer] in await LocalIndex.shared.add(beers: [lite]) }
        } catch {
            if !error.isCancellation { loadError = error.localizedDescription }
        }
    }

    private func loadFlavors() async {
        let apply = { (l: FlavorTagList) in self.flavors = l.items }
        if let l = try? await cacheThenNetwork(.beerFlavorProfile(beer.bid), as: FlavorTagList.self, onCached: apply) {
            apply(l)
        }
    }

    private func loadUserRating() async {
        if let r = try? await UntappdAPI.shared.fetch(.userRating(beer.bid), as: UserBeerRating.self) {
            yourRating = r.rating
        }
    }
}

/// A beer's page: what it is, how it rates, whether you've had it, and who's been drinking it.
/// Reached from check-ins, brewery lists and the check-in screen with a `BeerBreweryRoute`.
struct BeerView: View {
    @State private var model: BeerModel
    @State private var checkInBeer: BeerLite?
    /// The beer's prices at shops, from Metabeer, when shop prices are on and a shop has it.
    @State private var shopPrices: MetabeerOffers?
    /// Tags this page's links, so its rows only show as selected for checkins it opened itself.
    @State private var listID = UUID()
    @Environment(\.beerPageCanCheckIn) private var canCheckIn
    @Environment(DiscoverModel.self) private var discover

    init(beer: BeerLite) { _model = State(initialValue: BeerModel(beer: beer)) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                hero
                if let shopPrices { ShopPriceChip(offers: shopPrices, beerName: model.beer.name) }
                ratings
                TaproomStatsCard(stats: [("Check-ins", model.info?.stats?.total), ("People", model.info?.stats?.people),
                                         ("This month", model.info?.stats?.thisMonth)])
                if let d = model.info?.description {
                    TaproomSection("About") { ExpandableText(text: d) }
                }
                if !model.flavors.isEmpty { flavours }
                if let e = model.loadError, model.info == nil {
                    ErrorRow(message: e) { Task { await model.load(force: true) } }
                }
                recentCheckins
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .taproomScreen()
        .taproomScrollTitle(model.beer.name)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if canCheckIn {
                Button { checkInBeer = model.beer } label: { Label("Check in", systemImage: "plus") }
                    .buttonStyle(TaproomPrimaryButton())
                    .accessibilityHint("Starts a check-in for this beer")
                    .taproomBottomBar()
            }
        }
        .task { await model.load() }
        .task { await model.checkins.loadIfNeeded() }
        .loadingShopPrices(beerID: model.beer.bid, into: $shopPrices)
        .refreshable {
            async let details: Void = model.load(force: true)
            async let checkins: Void = model.checkins.refresh()
            async let prices = refreshShopPrices(beerID: model.beer.bid)
            _ = await (details, checkins)
            if case .updated(let refreshed) = await prices { shopPrices = refreshed }
        }
        .fullScreenCover(item: $checkInBeer) { CheckInSheet(beer: $0, venue: discover.here.first) }
    }

    // MARK: Header

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                brewery
                Text(model.beer.name)
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.6)
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                let meta = [model.beer.style,
                            model.beer.abv.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))% ABV" },
                            model.info?.ibu.flatMap { $0 > 0 ? "\($0) IBU" : nil }]
                    .compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta).font(.footnote).foregroundStyle(Taproom.muted).padding(.top, 2)
                }
                if model.info?.isInProduction == false {
                    Text("Out of production").font(.footnote.weight(.semibold)).foregroundStyle(Taproom.muted).padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BeerLabel(beer: model.info?.labelHD ?? model.beer.label, brewery: model.beer.breweryLabel, size: 96, cornerRadius: 16)
                .overlay(alignment: .topTrailing) {
                    if model.hadIt { HadCorner(size: 30) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder private var brewery: some View {
        let name = model.breweryName
        if !name.isEmpty {
            if let id = model.breweryId {
                NavigationLink(value: BeerBreweryRoute.brewery(id: id, name: name, label: model.beer.breweryLabel)) {
                    TaproomLinkLabel(name, font: .subheadline, chevronSize: 10)
                        .foregroundStyle(Taproom.muted)
                }
                .buttonStyle(TaproomLinkStyle())
                .accessibilityHint("Opens the brewery's page")
                .accessibilityAddTraits(.isLink)
            } else {
                Text(name).font(.subheadline).foregroundStyle(Taproom.muted).lineLimit(1)
            }
        }
    }

    // MARK: Ratings

    /// The global rating beside yours.
    private var ratings: some View {
        HStack(alignment: .top, spacing: 0) {
            ratingColumn("Everyone", rating: model.beer.rating,
                         caption: model.beer.ratingCount.map { "\($0.formatted()) ratings" })
            Rectangle().fill(Taproom.border).frame(width: 1)
            if model.hadIt {
                ratingColumn("You", rating: model.yourRating, empty: "Not rated",
                             caption: yourCheckinsText)
            } else {
                ratingColumn("You", rating: nil, empty: "Not had",
                             caption: model.info == nil ? nil : "Check it in to rate it")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .taproomCard()
        .accessibilityElement(children: .contain)
    }

    private var yourCheckinsText: String? {
        guard let n = model.info?.stats?.yours, n > 0 else { return "You've had it" }
        return n == 1 ? "1 check-in" : "\(n.formatted()) check-ins"
    }

    private func ratingColumn(_ title: String, rating: Double?, empty: String = "No ratings", caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Taproom.muted)
            if let rating, rating > 0 {
                TaproomRating(rating: rating, size: 34)
            } else {
                Text(empty).font(.system(size: 22, weight: .heavy)).tracking(-0.4).foregroundStyle(Taproom.muted)
                    .frame(minHeight: 34, alignment: .leading)
                    .accessibilityLabel("\(title): \(empty)")
            }
            if let caption { Text(caption).font(.caption).foregroundStyle(Taproom.muted) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Flavours

    private var flavours: some View {
        TaproomSection("Flavours") {
            FlowLayout(spacing: 6) {
                ForEach(model.flavors) { tag in
                    Text(tag.name)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .background(Taproom.card, in: Capsule())
                        .overlay(Capsule().stroke(Taproom.border, lineWidth: 1))
                }
            }
        }
    }

    // MARK: Check-ins

    @ViewBuilder private var recentCheckins: some View {
        let list = model.checkins
        TaproomSection("Recent check-ins") {
            // Lazy, so a row's onAppear fires as it scrolls into view and pages load one at a time.
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(list.items) { c in
                    NavigationLink(value: CheckinRoute(checkin: c, listID: listID)) {
                        CheckinRow(checkin: c)
                    }
                    .buttonStyle(CardLinkStyle())
                    .onAppear { list.onAppear(c) }
                }
                if list.items.isEmpty && (list.isRefreshing || list.isLoadingMore) {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                } else if let error = list.error {
                    ErrorRow(message: error) { Task { await list.refresh() } }
                } else if list.items.isEmpty {
                    Text("No one has checked in this beer yet.").font(.callout).foregroundStyle(Taproom.muted)
                } else if list.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            }
        }
    }
}
