import SwiftUI

@Observable @MainActor
final class BadgeModel {
    let badge: Checkin.Badge
    /// The user's level on the badge; nil when they don't have it (or until it loads).
    private(set) var status: BadgeStatusList.Status?
    private(set) var loaded = false
    private(set) var loadError: String?

    /// Friends who have the badge, highest level first, a page (`pageSize`) at a time.
    private(set) var friends: [FriendBadgeList.Entry] = []
    private(set) var friendsLoaded = false
    private(set) var friendsError: String?
    private(set) var hasMoreFriends = false
    private(set) var loadingMoreFriends = false
    /// Where the next page starts: the raw count received, which can be more than `friends.count`
    /// once repeats are dropped.
    private var nextOffset = 0
    /// `is_parent` from the friends list. Nil until it loads.
    private var isParent: Bool?

    /// Whether the badge has levels: `is_parent` once the friends list has loaded, else a guess
    /// from the name ("The Backpacker (Level 28)").
    var isLevelBadge: Bool { isParent ?? (BadgeName.level(of: badge.name) != nil) }

    static let pageSize = 15
    private var firstLoad: Task<Void, Never>?

    init(badge: Checkin.Badge) { self.badge = badge }

    func load(force: Bool = false) async {
        if force {
            await fetch()
            return
        }
        // The first load runs in a task of its own, so leaving the page part way through doesn't
        // leave it half loaded when it's shown again.
        if firstLoad == nil { firstLoad = Task { await fetch() } }
        await firstLoad?.value
    }

    private func fetch() async {
        guard let id = badge.badgeId else {
            loaded = true
            friendsLoaded = true
            return
        }
        async let mine: Void = fetchStatus(id)
        async let theirs: Void = fetchFriends(id)
        _ = await (mine, theirs)
    }

    private func fetchStatus(_ id: Int) async {
        let apply = { (l: BadgeStatusList) in
            self.status = l.statuses[id]
            self.loaded = true
        }
        do {
            apply(try await cacheThenNetwork(.badgeStatus([id]), as: BadgeStatusList.self, onCached: apply))
            loadError = nil
        } catch {
            if !Self.isCancellation(error) { loadError = error.localizedDescription }
        }
    }

    /// The first page of friends; refreshing goes back to it.
    private func fetchFriends(_ id: Int) async {
        let apply = { (l: FriendBadgeList) in
            self.friends = Self.unique(l.items)
            self.nextOffset = l.items.count
            self.hasMoreFriends = l.count >= Self.pageSize
            self.isParent = l.isParent
            self.friendsLoaded = true
        }
        do {
            apply(try await cacheThenNetwork(.friendsBadges(id, limit: Self.pageSize), as: FriendBadgeList.self,
                                             onCached: apply))
            friendsError = nil
        } catch {
            if !Self.isCancellation(error) { friendsError = error.localizedDescription }
        }
    }

    func loadMoreFriends() async {
        guard let id = badge.badgeId, hasMoreFriends, !loadingMoreFriends else { return }
        loadingMoreFriends = true
        defer { loadingMoreFriends = false }
        do {
            let page = try await UntappdAPI.shared.fetch(.friendsBadges(id, offset: nextOffset, limit: Self.pageSize),
                                                         as: FriendBadgeList.self)
            friends = Self.unique(friends + page.items)
            nextOffset += page.items.count
            hasMoreFriends = page.count >= Self.pageSize && !page.items.isEmpty
            friendsError = nil
        } catch {
            if !Self.isCancellation(error) { friendsError = error.localizedDescription }
        }
    }

    /// Drops repeats (a friend can shift between pages if they level up while you page).
    private static func unique(_ entries: [FriendBadgeList.Entry]) -> [FriendBadgeList.Entry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id).inserted }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// A badge's page: its picture, name and description, the signed-in user's level on it in a
/// prominent card, then each friend who has it with their level. Reached from every badge in the
/// app with a `BeerBreweryRoute.badge`.
///
/// Friends come from `GET /v4/badges/friends_badges/{badge_id}` (one request per page of 15, not
/// one per friend). The user's own level comes from `GET /v5/badges/status`, since the friends list
/// leaves the user out.
struct BadgeView: View {
    @State private var model: BadgeModel
    @Environment(DiscoverModel.self) private var discover
    @ScaledMetric private var imageSize: CGFloat = 160

    init(badge: Checkin.Badge) { _model = State(initialValue: BadgeModel(badge: badge)) }

    private var badge: Checkin.Badge { model.badge }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                hero
                youCard
                if let e = model.loadError, !model.loaded {
                    ErrorRow(message: e) { Task { await model.load(force: true) } }
                }
                friendsSection
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .taproomScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task { await model.load() }
        .refreshable { await model.load(force: true) }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            CachedImage(url: badge.largeImage ?? badge.image, maxPixel: 480)
                .frame(width: imageSize, height: imageSize)
                .clipShape(Circle())
                .overlay(Circle().stroke(Taproom.border, lineWidth: 1))
                .accessibilityHidden(true)
            // Without the "(Level N)" the earner reached: the page is about the badge, and the
            // levels follow below.
            Text(BadgeName.base(of: badge.name))
                .font(.system(size: 28, weight: .heavy))
                .tracking(-0.5)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if let d = badge.description {
                Text(d).font(.callout).foregroundStyle(Taproom.muted)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: You

    private var youCard: some View {
        HStack(spacing: 14) {
            Avatar(url: discover.me?.avatar, size: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("You").font(.caption.weight(.semibold)).foregroundStyle(Taproom.muted)
                youValue
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taproomCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var youValue: some View {
        if let s = model.status {
            if !model.isLevelBadge {
                Text("Earned")
                    .font(.system(size: 36, weight: .heavy)).tracking(-0.8)
            } else {
                Text("Level \(s.level.formatted())")
                    .font(.system(size: 36, weight: .heavy).monospacedDigit())
                    .tracking(-0.8)
            }
        } else if model.loaded {
            Text("Not earned yet")
                .font(.system(size: 26, weight: .heavy)).tracking(-0.4)
                .foregroundStyle(Taproom.glassRim)
        } else if model.loadError == nil {
            ProgressView().frame(minHeight: 44, alignment: .leading)
        } else {
            Text("Couldn't load").font(.system(size: 26, weight: .heavy)).tracking(-0.4)
                .foregroundStyle(Taproom.glassRim)
        }
    }

    // MARK: Friends

    private var friendsSection: some View {
        TaproomSection("Friends") {
            if !model.friends.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.friends) { entry in
                        NavigationLink(value: entry.user) { FriendBadgeRow(entry: entry) }
                            .buttonStyle(TaproomRowStyle())
                            .taproomRowDivider()
                    }
                }
                if model.hasMoreFriends {
                    Button {
                        Task { await model.loadMoreFriends() }
                    } label: {
                        if model.loadingMoreFriends { ProgressView() } else { Text("Show more") }
                    }
                    .buttonStyle(TaproomOutlineButton())
                    .disabled(model.loadingMoreFriends)
                    .padding(.top, 4)
                }
            }
            if let e = model.friendsError {
                ErrorRow(message: e) {
                    Task {
                        if model.friends.isEmpty { await model.load(force: true) } else { await model.loadMoreFriends() }
                    }
                }
            } else if !model.friendsLoaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            } else if model.friends.isEmpty {
                Text("None of your friends have this badge yet.")
                    .font(.subheadline).foregroundStyle(Taproom.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
    }
}

/// A friend who has the badge: who, when they earned it, and their level when it has levels.
private struct FriendBadgeRow: View {
    let entry: FriendBadgeList.Entry

    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: entry.user.avatar, size: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.user.displayName).font(.body.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.footnote).foregroundStyle(Taproom.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let level = entry.level {
                Text("Level \(level.formatted())")
                    .font(.system(size: 17, weight: .heavy).monospacedDigit())
                    .tracking(-0.3)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Taproom.glassRim)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = ["@" + entry.user.userName]
        if let d = entry.earnedAt { parts.append("Earned \(d.formatted(date: .abbreviated, time: .omitted))") }
        return parts.joined(separator: " · ")
    }
}
