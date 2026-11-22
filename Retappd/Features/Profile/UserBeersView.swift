import SwiftUI

/// Drives `UserBeersView`: paginated unique beers for any user, with search and sort.
@Observable @MainActor
final class UserBeersModel {
    typealias Fetcher = @Sendable (_ username: String, _ query: String, _ sort: String, _ offset: Int) async throws -> UserBeersPage

    static let defaultSortOptions: [CollectionSortOption] = [
        CollectionSortOption(key: "date", name: "Most Recent"),
        CollectionSortOption(key: "highest_rated_you", name: "Highest Rated"),
        CollectionSortOption(key: "highest_checkin", name: "Most Check-ins"),
        CollectionSortOption(key: "beer_name_asc", name: "Name (A–Z)"),
    ]

    let username: String
    private let fetcher: Fetcher

    private(set) var items: [UserBeerItem] = []
    private(set) var totalCount: Int?
    private(set) var sortingOptions: [CollectionSortOption] = defaultSortOptions
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    private(set) var hasMore = false
    private(set) var error: String?

    var query = ""
    var sortKey = "date"

    private var nextOffset = 0
    private var generation = 0

    init(username: String, fetcher: @escaping Fetcher = { username, query, sort, offset in
        try await UntappdAPI.shared.fetch(
            .userBeers(username, query: query, sort: sort, offset: offset),
            as: UserBeersPage.self
        )
    }) {
        self.username = username
        self.fetcher = fetcher
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Short list of chips for quick sorting; falls back to defaults until the API returns options.
    var quickSortChips: [(key: String, label: String)] {
        let preferred: [(key: String, label: String)] = [
            ("date", "Recent"),
            ("highest_rated_you", "Highest Rated"),
            ("highest_checkin", "Most Check-ins"),
            ("beer_name_asc", "A–Z"),
        ]
        let available = Set(sortingOptions.map(\.key))
        let matched = preferred.filter { available.contains($0.key) }
        return matched.isEmpty ? preferred : matched
    }

    func load(force: Bool = false) async {
        if hasLoaded && !force && !isLoading { return }
        await reload()
    }

    func reload() async {
        generation += 1
        let gen = generation
        let q = trimmedQuery
        let sort = sortKey
        isLoading = true
        isLoadingMore = false
        error = nil
        do {
            let page = try await fetcher(username, q, sort, 0)
            guard gen == generation else { return }
            items = Self.deduplicated(page.items)
            totalCount = page.totalCount
            if !page.sortingOptions.isEmpty { sortingOptions = page.sortingOptions }
            nextOffset = page.pagination.nextOffset ?? page.items.count
            hasMore = page.pagination.hasMore && !page.items.isEmpty
            hasLoaded = true
            isLoading = false
        } catch {
            guard gen == generation else { return }
            isLoading = false
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }

    func selectSort(_ key: String) async {
        guard key != sortKey else { return }
        sortKey = key
        await reload()
    }

    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let gen = generation
        let q = trimmedQuery
        let sort = sortKey
        let offset = nextOffset
        isLoadingMore = true
        error = nil
        do {
            let page = try await fetcher(username, q, sort, offset)
            guard gen == generation else { return }
            items = Self.deduplicated(items + page.items)
            totalCount = page.totalCount
            let returned = page.items.count
            nextOffset = page.pagination.nextOffset ?? (offset + returned)
            hasMore = page.pagination.hasMore && returned > 0
            isLoadingMore = false
        } catch {
            guard gen == generation else { return }
            isLoadingMore = false
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }

    private static func deduplicated(_ items: [UserBeerItem]) -> [UserBeerItem] {
        var seen = Set<Int>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

/// Paginated list of a user's unique beers, pushed from Profile's Unique stat.
struct UserBeersView: View {
    let username: String
    let displayName: String
    let isOwnProfile: Bool
    @State private var model: UserBeersModel
    @State private var searchText = ""

    init(username: String, displayName: String, isOwnProfile: Bool) {
        self.username = username
        self.displayName = displayName
        self.isOwnProfile = isOwnProfile
        _model = State(initialValue: UserBeersModel(username: username))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                header
                TaproomSearchField(text: $searchText, prompt: "Search unique beers")
                    .accessibilityIdentifier("userBeers.searchField")
                sortBar
                content
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.bottom, 24)
            .frame(maxWidth: .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .taproomScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task { await model.load() }
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != model.trimmedQuery else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            model.query = searchText
            await model.reload()
        }
        .refreshable { await model.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Unique Beers")
                .font(.system(size: 34, weight: .heavy)).tracking(-0.6)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.subheadline).foregroundStyle(Taproom.muted)
        }
    }

    private var subtitle: String {
        var parts = [isOwnProfile ? "@\(username)" : displayName]
        if let count = model.totalCount {
            parts.append("\(count.formatted()) \(count == 1 ? "beer" : "beers")")
        }
        return parts.joined(separator: " · ")
    }

    private var sortBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.quickSortChips, id: \.key) { chip in
                    let on = model.sortKey == chip.key
                    Button(chip.label) {
                        Task { await model.selectSort(chip.key) }
                    }
                    .buttonStyle(TaproomChip(on: on))
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("userBeers.sort.\(chip.key)")
                }

                if model.sortingOptions.count > model.quickSortChips.count {
                    let isCustomSort = !model.quickSortChips.contains { $0.key == model.sortKey }
                    Menu {
                        ForEach(model.sortingOptions) { option in
                            Button {
                                Task { await model.selectSort(option.key) }
                            } label: {
                                if option.key == model.sortKey {
                                    Label(option.name, systemImage: "checkmark")
                                } else {
                                    Text(option.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down").imageScale(.small)
                            Text(isCustomSort
                                 ? (model.sortingOptions.first { $0.key == model.sortKey }?.name ?? "More")
                                 : "More")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isCustomSort ? Taproom.onAmber : Taproom.ink)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .background(isCustomSort ? Taproom.amber : Taproom.card, in: Capsule())
                        .overlay { Capsule().strokeBorder(isCustomSort ? Taproom.amber : Taproom.border, lineWidth: 1) }
                    }
                    .accessibilityLabel("More sort options")
                    .accessibilityIdentifier("userBeers.sortMenu")
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.isLoading && model.items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else if let e = model.error, model.items.isEmpty {
            ErrorRow(message: e) { Task { await model.reload() } }
        } else if model.hasLoaded && model.items.isEmpty {
            if !model.trimmedQuery.isEmpty {
                ContentUnavailableView.search(text: model.trimmedQuery)
                    .padding(.top, 24)
            } else {
                ContentUnavailableView {
                    Label("No beers yet", systemImage: "mug")
                } description: {
                    Text(isOwnProfile
                         ? "Check in your first beer to start your unique list."
                         : "\(displayName) hasn't checked in any beers yet.")
                }
                .padding(.top, 24)
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(model.items) { item in
                    NavigationLink(value: BeerBreweryRoute.beer(item.beerLite)) {
                        UserBeerRow(item: item, isOwnProfile: isOwnProfile)
                    }
                    .buttonStyle(TaproomRowStyle())
                    .taproomRowDivider()
                    .accessibilityIdentifier("userBeers.row.\(item.id)")
                    .onAppear {
                        if item.id == model.items.last?.id {
                            Task { await model.loadMore() }
                        }
                    }
                }

                if model.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else if let e = model.error {
                    ErrorRow(message: e) { Task { await model.loadMore() } }
                        .padding(.top, 12)
                } else if model.hasMore {
                    Button("Load more") { Task { await model.loadMore() } }
                        .buttonStyle(TaproomOutlineButton())
                        .padding(.top, 12)
                        .accessibilityIdentifier("userBeers.loadMore")
                }
            }
            .overlay(alignment: .top) {
                if model.isLoading {
                    ProgressView()
                        .padding(10)
                        .background(Taproom.card, in: Circle())
                        .overlay(Circle().stroke(Taproom.border))
                        .padding(.top, 8)
                }
            }
        }
    }
}

private struct UserBeerRow: View {
    let item: UserBeerItem
    let isOwnProfile: Bool

    var body: some View {
        HStack(spacing: 12) {
            BeerLabel(beer: item.beer.label, brewery: item.brewery?.label, size: 48, cornerRadius: 10)
                .overlay(alignment: .topTrailing) {
                    if !isOwnProfile && HadBeers.shared.has(item.beerLite) {
                        HadCorner(size: 18)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.beer.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                let meta = [
                    item.brewery?.name,
                    item.beer.style,
                    item.beer.abv.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" },
                ].compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty {
                    Text(meta)
                        .font(.footnote)
                        .foregroundStyle(Taproom.muted)
                        .lineLimit(1)
                }
                Text(checkinMeta)
                    .font(.caption)
                    .foregroundStyle(Taproom.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                if let rating = item.userRating {
                    Text(rating.formatted(.number.precision(.fractionLength(2))))
                        .font(.headline.weight(.heavy).monospacedDigit())
                        .foregroundStyle(Taproom.ink)
                } else {
                    Text("–")
                        .font(.headline.weight(.heavy).monospacedDigit())
                        .foregroundStyle(Taproom.muted)
                }
                if let global = item.globalRating {
                    Text("Avg \(global.formatted(.number.precision(.fractionLength(2))))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Taproom.muted)
                }
            }
            .fixedSize()
        }
        .foregroundStyle(Taproom.ink)
        .padding(.vertical, 10)
        .frame(minHeight: 68)
        .accessibilityElement(children: .combine)
    }

    private var checkinMeta: String {
        let countText = "\(item.checkinCount.formatted()) \(item.checkinCount == 1 ? "check-in" : "check-ins")"
        if let recent = item.recentCreatedAt {
            return "\(countText) · \(recent.formatted(date: .abbreviated, time: .omitted))"
        }
        return countText
    }
}
