import SwiftUI

@Observable @MainActor
final class BeerModel {
    enum CheckinScope: Hashable { case all, friends }

    /// What we knew when the page opened, kept up to date from the full record as it loads.
    private(set) var beer: BeerLite
    private(set) var info: BeerInfo?
    private(set) var flavors: [FlavorTag] = []
    /// The user's own rating, from `beer/info`, or `beer/userrating` if that didn't have it.
    private(set) var yourRating: Double?
    private(set) var isInWishlist = false
    private(set) var loadError: String?
    /// True once the initial parallel `info` + `flavors` fetch has settled (or failed).
    private(set) var detailsLoaded = false
    var checkinScope: CheckinScope = .all
    let checkins: CheckinListModel
    let friendsCheckins: CheckinListModel
    private var firstLoad: Task<Void, Never>?

    init(
        beer: BeerLite,
        checkins: CheckinListModel? = nil,
        friendsCheckins: CheckinListModel? = nil
    ) {
        self.beer = beer
        self.checkins = checkins ?? CheckinListModel(source: .beer(beer.bid, friendsOnly: false))
        self.friendsCheckins = friendsCheckins ?? CheckinListModel(source: .beer(beer.bid, friendsOnly: true))
    }

    var isLoadingDetails: Bool { info == nil && !detailsLoaded }
    var hadIt: Bool { HadBeers.shared.has(beer.bid, fallback: info?.hasHad ?? beer.hasHad) }
    var breweryId: Int? { info?.brewery.flatMap { $0.id > 0 ? $0.id : nil } ?? beer.breweryId }
    var breweryName: String { info?.brewery?.name ?? beer.brewery }

    /// The active check-in list for the currently selected scope.
    var activeCheckins: CheckinListModel {
        checkinScope == .all ? checkins : friendsCheckins
    }

    /// Friends' average rating from `beer/info` (`friends_ratings`), falling back to the
    /// aggregate rating returned by `beer/checkins?type=friends` if loaded.
    var friendsRating: Double? {
        if let r = info?.friendsRating, r > 0 { return r }
        if let r = friendsCheckins.ratingScore, r > 0 { return r }
        return nil
    }

    /// Number of friend ratings from `beer/info` (`friends_ratings`), falling back to
    /// `beer/checkins?type=friends`.
    var friendsRatingCount: Int? {
        if let n = info?.friendsRatingCount, n > 0 { return n }
        if let n = friendsCheckins.ratingCount, n > 0 { return n }
        return nil
    }

    /// Formatted caption for the friends rating row ("1 rating" / "11 ratings").
    var friendsRatingCaption: String? {
        guard let n = friendsRatingCount, n > 0 else { return nil }
        return n == 1 ? "1 rating" : "\(n.formatted()) ratings"
    }

    /// Refreshes the public check-ins, plus friends' check-ins if they are showing or already loaded.
    func refreshCheckins() async {
        async let all: Void = checkins.refresh()
        if checkinScope == .friends || !friendsCheckins.items.isEmpty {
            async let friends: Void = friendsCheckins.refresh()
            _ = await (all, friends)
        } else {
            await all
        }
    }

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
        // Fetch info and flavors in parallel and commit them together once both settle on a cold
        // load, so About and Flavours don't shift the page in two separate steps. Warm cache hits
        // still apply immediately via onCached.
        async let fetchedInfo = fetchInfo()
        async let fetchedFlavors = fetchFlavors()
        let (i, f) = await (fetchedInfo, fetchedFlavors)
        if let i {
            applyInfo(i)
            loadError = nil
            Task.detached(priority: .utility) { [lite = beer] in await LocalIndex.shared.add(beers: [lite]) }
        }
        if let f { flavors = f.items }
        detailsLoaded = true
        if info?.hasHad == true, yourRating == nil { await loadUserRating() }
    }

    func applyInfo(_ i: BeerInfo) {
        info = i
        yourRating = i.yourRating
        if let wish = i.isInWishlist { isInWishlist = wish }
        beer = i.lite
    }

    func setWishlistStatus(_ inWishlist: Bool) {
        isInWishlist = inWishlist
        info?.isInWishlist = inWishlist
    }

    private func fetchInfo() async -> BeerInfo? {
        do {
            return try await cacheThenNetwork(.beerInfo(beer.bid), as: BeerInfo.self, onCached: applyInfo)
        } catch {
            if !error.isCancellation { loadError = error.localizedDescription }
            return nil
        }
    }

    private func fetchFlavors() async -> FlavorTagList? {
        try? await cacheThenNetwork(.beerFlavorProfile(beer.bid), as: FlavorTagList.self) { l in
            self.flavors = l.items
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
    let venue: Venue?
    @State private var model: BeerModel
    @State private var checkInBeer: BeerLite?
    @State private var showingListsSheet = false
    @State private var showLabelPhoto = false
    /// The beer's prices at shops, from Metabeer, when shop prices are on and a shop has it.
    @State private var shopPrices: MetabeerOffers?
    /// Tags this page's links, so its rows only show as selected for checkins it opened itself.
    @State private var listID = UUID()
    @State private var containerWidth: CGFloat = 0
    @Environment(\.beerPageCanCheckIn) private var canCheckIn
    @Environment(DiscoverModel.self) private var discover
    @Environment(AuthStore.self) private var auth

    init(beer: BeerLite, venue: Venue? = nil) {
        _model = State(initialValue: BeerModel(beer: beer))
        self.venue = venue
    }

    private var isTwoColumn: Bool { containerWidth >= .twoColumnThreshold }

    var body: some View {
        ScrollView {
            Group {
                if isTwoColumn {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                            summaryContent
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        LazyVStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                            recentCheckins
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    LazyVStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                        summaryContent
                        if model.isLoadingDetails {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
                        } else {
                            recentCheckins
                        }
                    }
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: isTwoColumn ? .wideContentWidth : .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        .taproomScreen()
        .taproomScrollTitle(model.beer.name)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .toolbar {
            if auth.username != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingListsSheet = true } label: {
                        Image(systemName: model.isInWishlist ? "bookmark.fill" : "bookmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(model.isInWishlist ? Taproom.amber : Taproom.ink)
                    }
                    .accessibilityLabel(model.isInWishlist ? "On Wish List" : "Add to Wish List or list")
                    .accessibilityHint("Manage wishlist and custom lists for this beer")
                    .accessibilityIdentifier("beer.listsButton")
                }
            }
        }
        .sheet(isPresented: $showingListsSheet) {
            if let username = auth.username {
                BeerListsSheet(beer: model.beer, username: username) { inWishlist in
                    model.setWishlistStatus(inWishlist)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if canCheckIn {
                Button { checkInBeer = model.beer } label: { Label("Check in", systemImage: "plus") }
                    .buttonStyle(TaproomPrimaryButton())
                    .accessibilityHint("Starts a check-in for this beer")
                    .taproomBottomBar()
            }
        }
        .task { await model.load() }
        .task(id: model.checkinScope) {
            let list = model.activeCheckins
            // Not tied to this view: switching All/Friends mid-request would otherwise cancel it.
            await Task { await list.loadIfNeeded() }.value
        }
        .loadingShopPrices(beerID: model.beer.bid, into: $shopPrices)
        .refreshable {
            async let details: Void = model.load(force: true)
            async let checkins: Void = model.refreshCheckins()
            async let prices = refreshShopPrices(beerID: model.beer.bid)
            _ = await (details, checkins)
            if case .updated(let refreshed) = await prices { shopPrices = refreshed }
        }
        .checkInPresentation(item: $checkInBeer) { CheckInSheet(beer: $0, venue: venue ?? discover.here.first) }
    }

    @ViewBuilder private var summaryContent: some View {
        hero
        if let shopPrices { ShopPriceChip(offers: shopPrices, beerName: model.beer.name) }
        ratings
        TaproomStatsCard(stats: [("Check-ins", model.info?.stats?.total), ("People", model.info?.stats?.people),
                                 ("This month", model.info?.stats?.thisMonth)],
                         isLoading: model.isLoadingDetails)
        if let d = model.info?.description {
            TaproomSection("About") { ExpandableText(text: d) }
        }
        if !model.isLoadingDetails, !model.flavors.isEmpty { flavours }
        if let e = model.loadError, model.info == nil {
            ErrorRow(message: e) { Task { await model.load(force: true) } }
        }
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
            let resolved = BeerLabel.resolve(beer: model.beer.label, beerHD: model.info?.labelHD, brewery: model.beer.breweryLabel)
            let label = BeerLabel(beer: model.beer.label, beerHD: model.info?.labelHD, brewery: model.beer.breweryLabel, size: 96, cornerRadius: 16)
                .overlay(alignment: .topTrailing) {
                    if model.hadIt { HadCorner(size: 30) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if let resolved {
                Button { showLabelPhoto = true } label: { label }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Beer label")
                    .accessibilityHint("Opens it full screen")
                    .accessibilityIdentifier("beer.labelButton")
                    .fullScreenCover(isPresented: $showLabelPhoto) {
                        PhotoViewer(url: resolved.url, placeholder: resolved.fallback ?? resolved.url, title: model.beer.name)
                    }
            } else {
                label
            }
        }
    }

    /// Vertical hit-target extension above and below the brewery link so a `.subheadline` line
    /// reaches at least 44pt tall without pushing the beer name down.
    static let breweryTapExtend: CGFloat = 14

    @ViewBuilder private var brewery: some View {
        let name = model.breweryName
        if !name.isEmpty {
            if let id = model.breweryId {
                NavigationLink(value: BeerBreweryRoute.brewery(id: id, name: name, label: model.beer.breweryLabel)) {
                    TaproomLinkLabel(name, font: .subheadline, chevronSize: 10)
                        .foregroundStyle(Taproom.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(TaproomLinkStyle(extend: Self.breweryTapExtend))
                // Sit above the selectable beer-name Text below so its downward tap target isn't swallowed.
                .zIndex(1)
                .accessibilityIdentifier("beer.breweryLink")
                .accessibilityHint("Opens the brewery's page")
                .accessibilityAddTraits(.isLink)
            } else {
                Text(name).font(.subheadline).foregroundStyle(Taproom.muted).lineLimit(1)
            }
        }
    }

    // MARK: Ratings

    /// The global rating beside yours, with friends' average rating underneath when available.
    private var ratings: some View {
        TaproomRatingCard(
            leading: .init(
                title: "Everyone",
                rating: model.beer.rating,
                caption: model.beer.ratingCount.map { "\($0.formatted()) ratings" }
                    ?? (model.isLoadingDetails ? "1,234 ratings" : nil),
                isLoading: model.beer.rating == nil && model.isLoadingDetails,
                isCaptionLoading: model.beer.ratingCount == nil && model.isLoadingDetails,
                accessibilityID: "beer.ratings.everyone"
            ),
            trailing: model.hadIt
                ? .init(
                    title: "You",
                    rating: model.yourRating,
                    empty: "Not rated",
                    caption: yourCheckinsText,
                    isLoading: model.yourRating == nil && model.isLoadingDetails,
                    accessibilityID: "beer.ratings.you"
                )
                : .init(
                    title: "You",
                    rating: nil,
                    empty: "Not had",
                    caption: "Check it in to rate it",
                    isCaptionLoading: model.isLoadingDetails,
                    accessibilityID: "beer.ratings.you"
                ),
            footer: model.friendsRating.map { rating in
                .init(
                    title: "Friends",
                    rating: rating,
                    caption: model.friendsRatingCaption,
                    accessibilityID: "beer.ratings.friends"
                )
            },
            footerLink: BeerBreweryRoute.friendRatings(model.beer)
        )
    }

    private var yourCheckinsText: String? {
        guard let n = model.info?.stats?.yours, n > 0 else { return "You've had it" }
        return n == 1 ? "1 check-in" : "\(n.formatted()) check-ins"
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
        let list = model.activeCheckins
        TaproomSection("Recent check-ins") {
            VStack(alignment: .leading, spacing: 12) {
                TaproomSegmented(
                    options: [(.all, "All"), (.friends, "Friends")],
                    selection: $model.checkinScope,
                    accessibilityID: { $0 == .all ? "beer.checkins.all" : "beer.checkins.friends" }
                )

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
                        Text(model.checkinScope == .all
                             ? "No one has checked in this beer yet."
                             : "None of your friends have checked in this beer yet.")
                            .font(.callout)
                            .foregroundStyle(Taproom.muted)
                            .accessibilityIdentifier("beer.checkins.empty")
                    } else if list.isLoadingMore {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                }
                .id(model.checkinScope)
            }
        }
    }
}
