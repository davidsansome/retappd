import SwiftUI

/// Drives `UserBadgesView`: category summary (`method=index`) + paginated badges per category (`method=full`).
@Observable @MainActor
final class UserBadgesModel {
    typealias IndexFetcher = @Sendable (_ username: String) async throws -> UserBadgesIndex
    typealias PageFetcher = @Sendable (_ username: String, _ segment: UserBadgeSegment, _ sort: String, _ offset: Int, _ limit: Int) async throws -> UserBadgesPage

    static let pageSize = 25
    static let defaultSortOptions: [CollectionSortOption] = [
        CollectionSortOption(key: "unlocked", name: "Most Recent"),
        CollectionSortOption(key: "badge_name", name: "Name (A–Z)"),
        CollectionSortOption(key: "badge_name_desc", name: "Name (Z–A)"),
        CollectionSortOption(key: "badge_date_desc", name: "Newest Badges"),
    ]

    let username: String
    private let indexFetcher: IndexFetcher
    private let pageFetcher: PageFetcher

    private(set) var stats: [UserBadgeSegment: UserBadgesIndex.CategoryStat] = [:]
    private(set) var items: [UserBadgeItem] = []
    private(set) var sortingOptions: [CollectionSortOption] = defaultSortOptions
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    private(set) var hasMore = false
    private(set) var error: String?

    var segment: UserBadgeSegment = .beer
    var sortKey = "unlocked"

    private var nextOffset = 0
    private var generation = 0

    init(
        username: String,
        indexFetcher: @escaping IndexFetcher = { username in
            try await UntappdAPI.shared.fetch(.userBadgesIndex(username), as: UserBadgesIndex.self)
        },
        pageFetcher: @escaping PageFetcher = { username, segment, sort, offset, limit in
            try await UntappdAPI.shared.fetch(
                .userBadges(username, segment: segment, sort: sort, offset: offset, limit: limit),
                as: UserBadgesPage.self
            )
        }
    ) {
        self.username = username
        self.indexFetcher = indexFetcher
        self.pageFetcher = pageFetcher
    }

    var totalEarned: Int? {
        guard !stats.isEmpty else { return nil }
        return stats.values.reduce(0) { $0 + $1.userCount }
    }

    func count(for segment: UserBadgeSegment) -> Int? {
        stats[segment]?.userCount
    }

    func load(force: Bool = false) async {
        if hasLoaded && !force && !isLoading { return }
        await reloadAll()
    }

    func reloadAll() async {
        async let summary: () = loadIndex()
        async let page: () = reloadPage()
        _ = await (summary, page)
    }

    private func loadIndex() async {
        if let index = try? await indexFetcher(username) {
            stats = index.stats
        }
    }

    func selectSegment(_ newSegment: UserBadgeSegment) async {
        guard newSegment != segment else { return }
        segment = newSegment
        await reloadPage()
    }

    func selectSort(_ newSort: String) async {
        guard newSort != sortKey else { return }
        sortKey = newSort
        await reloadPage()
    }

    func reloadPage() async {
        generation += 1
        let gen = generation
        let seg = segment
        let sort = sortKey
        isLoading = true
        isLoadingMore = false
        error = nil
        do {
            let page = try await pageFetcher(username, seg, sort, 0, Self.pageSize)
            guard gen == generation else { return }
            items = Self.deduplicated(page.items)
            if !page.sortingOptions.isEmpty { sortingOptions = page.sortingOptions }
            nextOffset = page.items.count
            hasMore = page.items.count >= Self.pageSize
            hasLoaded = true
            isLoading = false
        } catch {
            guard gen == generation else { return }
            isLoading = false
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let gen = generation
        let seg = segment
        let sort = sortKey
        let offset = nextOffset
        isLoadingMore = true
        error = nil
        do {
            let page = try await pageFetcher(username, seg, sort, offset, Self.pageSize)
            guard gen == generation else { return }
            items = Self.deduplicated(items + page.items)
            nextOffset = offset + page.items.count
            hasMore = page.items.count >= Self.pageSize
            isLoadingMore = false
        } catch {
            guard gen == generation else { return }
            isLoadingMore = false
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }

    private static func deduplicated(_ items: [UserBadgeItem]) -> [UserBadgeItem] {
        var seen = Set<Int>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

/// Paginated badge grid for a user, pushed from Profile's Badges stat.
struct UserBadgesView: View {
    let username: String
    let displayName: String
    let isOwnProfile: Bool
    @State private var model: UserBadgesModel

    private let columns = [GridItem(.adaptive(minimum: 155), spacing: 12)]

    init(username: String, displayName: String, isOwnProfile: Bool) {
        self.username = username
        self.displayName = displayName
        self.isOwnProfile = isOwnProfile
        _model = State(initialValue: UserBadgesModel(username: username))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                header
                segmentBar
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(Taproom.ink)
                }
                .tint(Taproom.ink)
                .accessibilityLabel("Sort badges")
                .accessibilityIdentifier("userBadges.sortMenu")
            }
        }
        .task { await model.load() }
        .refreshable { await model.reloadAll() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Badges")
                .font(.system(size: 34, weight: .heavy)).tracking(-0.6)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.subheadline).foregroundStyle(Taproom.muted)
        }
    }

    private var subtitle: String {
        var parts = [isOwnProfile ? "@\(username)" : displayName]
        if let count = model.totalEarned {
            parts.append("\(count.formatted()) earned")
        }
        return parts.joined(separator: " · ")
    }

    private var segmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(UserBadgeSegment.allCases) { seg in
                    let on = model.segment == seg
                    let title: String = {
                        if let c = model.count(for: seg) { return "\(seg.title) · \(c.formatted())" }
                        return seg.title
                    }()
                    Button(title) {
                        Task { await model.selectSegment(seg) }
                    }
                    .buttonStyle(TaproomChip(on: on))
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("userBadges.segment.\(seg.rawValue)")
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
            ErrorRow(message: e) { Task { await model.reloadPage() } }
        } else if model.hasLoaded && model.items.isEmpty {
            ContentUnavailableView {
                Label("No \(model.segment.title.lowercased()) badges", systemImage: "rosette")
            } description: {
                Text(isOwnProfile
                     ? "Keep checking in beers to unlock \(model.segment.title.lowercased()) badges."
                     : "\(displayName) hasn't unlocked any \(model.segment.title.lowercased()) badges yet.")
            }
            .padding(.top, 24)
        } else {
            VStack(spacing: 12) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.items) { item in
                        NavigationLink(value: BeerBreweryRoute.badge(item.asCheckinBadge)) {
                            UserBadgeCard(item: item)
                        }
                        .buttonStyle(CardLinkStyle())
                        .accessibilityIdentifier("userBadges.card.\(item.id)")
                        .onAppear {
                            if item.id == model.items.last?.id {
                                Task { await model.loadMore() }
                            }
                        }
                    }
                }

                if model.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else if let e = model.error {
                    ErrorRow(message: e) { Task { await model.loadMore() } }
                } else if model.hasMore {
                    Button("Load more") { Task { await model.loadMore() } }
                        .buttonStyle(TaproomOutlineButton())
                        .accessibilityIdentifier("userBadges.loadMore")
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

private struct UserBadgeCard: View {
    let item: UserBadgeItem

    var body: some View {
        VStack(spacing: 8) {
            CachedImage(url: item.image ?? item.largeImage, maxPixel: 240) {
                ZStack {
                    Taproom.glassInside
                    Image(systemName: "rosette")
                        .font(.title2)
                        .foregroundStyle(Taproom.muted)
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(Circle())
            .overlay(Circle().stroke(Taproom.border, lineWidth: 1))
            .opacity(item.hasBadge ? 1 : 0.4)
            .accessibilityHidden(true)

            Text(item.baseName)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(item.hasBadge ? Taproom.ink : Taproom.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(minHeight: 36, alignment: .top)

            if item.hasBadge, let level = item.level {
                Text("Level \(level.formatted())")
                    .font(.caption.weight(.heavy).monospacedDigit())
                    .foregroundStyle(Taproom.onAmber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Taproom.amber, in: Capsule())
            }

            if let earned = item.earnedAt {
                Text(earned.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(Taproom.muted)
                    .lineLimit(1)
            } else if !item.hasBadge {
                Text("Locked")
                    .font(.caption2)
                    .foregroundStyle(Taproom.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .taproomCard()
        .accessibilityElement(children: .combine)
    }
}
