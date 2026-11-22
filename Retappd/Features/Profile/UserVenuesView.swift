import SwiftUI

/// Drives `UserVenuesView`: paginated venues a user has visited, with sort and verified filter.
@Observable @MainActor
final class UserVenuesModel {
    typealias Fetcher = @Sendable (_ username: String, _ sort: String, _ verifiedOnly: Bool, _ offset: Int) async throws -> UserVenuesPage

    static let defaultSortOptions: [CollectionSortOption] = [
        CollectionSortOption(key: "date", name: "Most Recent"),
        CollectionSortOption(key: "highest_checkin", name: "Most Visits"),
        CollectionSortOption(key: "lowest_checkin", name: "Fewest Visits"),
    ]

    let username: String
    private let fetcher: Fetcher

    private(set) var items: [UserVenueItem] = []
    private(set) var totalCount: Int?
    private(set) var sortingOptions: [CollectionSortOption] = defaultSortOptions
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    private(set) var hasMore = false
    private(set) var error: String?

    var sortKey = "date"
    var verifiedOnly = false

    private var nextOffset = 0
    private var generation = 0

    init(username: String, fetcher: @escaping Fetcher = { username, sort, verifiedOnly, offset in
        try await UntappdAPI.shared.fetch(
            .userVenues(username, sort: sort, verifiedOnly: verifiedOnly, offset: offset),
            as: UserVenuesPage.self
        )
    }) {
        self.username = username
        self.fetcher = fetcher
    }

    var quickSortChips: [(key: String, label: String)] {
        let preferred: [(key: String, label: String)] = [
            ("date", "Recent"),
            ("highest_checkin", "Most Visits"),
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
        let sort = sortKey
        let verified = verifiedOnly
        isLoading = true
        isLoadingMore = false
        error = nil
        do {
            let page = try await fetcher(username, sort, verified, 0)
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

    func toggleVerifiedOnly() async {
        verifiedOnly.toggle()
        await reload()
    }

    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let gen = generation
        let sort = sortKey
        let verified = verifiedOnly
        let offset = nextOffset
        isLoadingMore = true
        error = nil
        do {
            let page = try await fetcher(username, sort, verified, offset)
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

    private static func deduplicated(_ items: [UserVenueItem]) -> [UserVenueItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

/// Paginated list of venues a user has checked in at, pushed from Profile's Venues entry.
struct UserVenuesView: View {
    let username: String
    let displayName: String
    let isOwnProfile: Bool
    @State private var model: UserVenuesModel

    init(username: String, displayName: String, isOwnProfile: Bool) {
        self.username = username
        self.displayName = displayName
        self.isOwnProfile = isOwnProfile
        _model = State(initialValue: UserVenuesModel(username: username))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                header
                filterBar
                content
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.bottom, 24)
            .frame(maxWidth: .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .taproomScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task { await model.load() }
        .refreshable { await model.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Venues")
                .font(.system(size: 34, weight: .heavy)).tracking(-0.6)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.subheadline).foregroundStyle(Taproom.muted)
        }
    }

    private var subtitle: String {
        var parts = [isOwnProfile ? "@\(username)" : displayName]
        if let count = model.totalCount {
            parts.append("\(count.formatted()) \(count == 1 ? "venue" : "venues")")
        }
        return parts.joined(separator: " · ")
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.quickSortChips, id: \.key) { chip in
                    let on = model.sortKey == chip.key
                    Button(chip.label) {
                        Task { await model.selectSort(chip.key) }
                    }
                    .buttonStyle(TaproomChip(on: on))
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("userVenues.sort.\(chip.key)")
                }

                Button {
                    Task { await model.toggleVerifiedOnly() }
                } label: {
                    Label("Verified", systemImage: "checkmark.seal")
                }
                .buttonStyle(TaproomChip(on: model.verifiedOnly))
                .accessibilityAddTraits(model.verifiedOnly ? .isSelected : [])
                .accessibilityIdentifier("userVenues.filter.verified")

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
                    .accessibilityIdentifier("userVenues.sortMenu")
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
            ContentUnavailableView {
                Label(model.verifiedOnly ? "No verified venues" : "No venues yet", systemImage: "mappin.and.ellipse")
            } description: {
                Text(model.verifiedOnly
                     ? "Try turning off the Verified filter to see all venues."
                     : (isOwnProfile
                        ? "Tag a venue on a check-in to start your venues list."
                        : "\(displayName) hasn't checked in at any venues yet."))
            } actions: {
                if model.verifiedOnly {
                    Button {
                        Task { await model.toggleVerifiedOnly() }
                    } label: {
                        Text("Show all venues").padding(.horizontal, 16)
                    }
                    .buttonStyle(TaproomOutlineButton())
                    .frame(maxWidth: 220)
                }
            }
            .padding(.top, 24)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(model.items) { item in
                    NavigationLink(value: item.venue) {
                        UserVenueRow(item: item)
                    }
                    .buttonStyle(TaproomRowStyle())
                    .taproomRowDivider()
                    .accessibilityIdentifier("userVenues.row.\(item.id)")
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
                        .accessibilityIdentifier("userVenues.loadMore")
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

private struct UserVenueRow: View {
    let item: UserVenueItem

    var body: some View {
        HStack(spacing: 12) {
            VenueIcon(venue: item.venue, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.venue.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if item.venue.isVerified { VerifiedBadge() }
                }
                if !item.venue.subtitle.isEmpty {
                    Text(item.venue.subtitle)
                        .font(.footnote)
                        .foregroundStyle(Taproom.muted)
                        .lineLimit(1)
                }
                if let recent = item.recentVisit {
                    Text("Last visited \(recent.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(Taproom.muted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(item.visitCount.formatted())
                    .font(.headline.weight(.heavy).monospacedDigit())
                    .foregroundStyle(Taproom.ink)
                Text(item.visitCount == 1 ? "visit" : "visits")
                    .font(.caption2)
                    .foregroundStyle(Taproom.muted)
            }
            .fixedSize()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Taproom.glassRim)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Taproom.ink)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
    }
}
