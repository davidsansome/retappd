import SwiftUI

/// A user's stats and checkins. The Profile tab shows the signed-in user's; other people's are
/// pushed from a checkin (see `UserProfileView`).
struct ProfileView: View {
    let username: String
    let model: CheckinListModel
    /// Whether this is the Profile tab, which has the account menu and no navigation bar.
    var isAccountTab = true
    /// Shown in the header until the full profile loads.
    var placeholder: User? = nil
    var openSettings: () -> Void = {}
    @State private var info: UserInfo.Profile?

    var body: some View {
        CheckinList(model: model, showUser: false, registersDestinations: isAccountTab, emptyText: emptyText) {
            header
        }
        .toolbar(isAccountTab ? .hidden : .automatic, for: .navigationBar)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .navigationTitle(isAccountTab ? "" : (info?.userName ?? username))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(SettingsDestination(enabled: isAccountTab, username: username))
        .task(id: model.reloads) { await loadInfo() }
        .task(id: model.reloads) { if isAccountTab { await CheckInOptions.shared.loadRequests() } }
        .onChange(of: CheckInOptions.shared.friendCountChange) { old, new in
            // Someone was unfriended or a request was accepted on the Friends screen: show the new
            // count at once, then refetch from a cache that no longer holds the old one.
            guard isAccountTab else { return }
            info?.totalFriends = ProfileFriendCount.adjusted(info?.totalFriends, changeAtStart: old, changeNow: new)
            Task {
                await ResponseCache.shared.remove(APIRequest.userInfo(username).cacheKey)
                await loadInfo()
            }
        }
        .refreshable {
            async let a: () = model.refresh()
            async let b: () = loadInfo()
            async let c: () = isAccountTab ? HadBeers.shared.refresh(force: true) : ()
            async let d: () = isAccountTab ? CheckInOptions.shared.loadRequests() : ()
            _ = await (a, b, c, d)
        }
    }

    /// The avatar and name centred as the hero, then the stats in a row.
    private var header: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Avatar(url: info?.avatar ?? placeholder?.avatar, size: 96)
                Text(info?.displayName ?? placeholder?.displayName ?? username)
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.4)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                Text(["@" + (info?.userName ?? username), info?.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Taproom.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) {
                if isAccountTab {
                    Button(action: openSettings) {
                        Image(systemName: "gearshape").font(.title3).frame(width: 44, height: 44)
                    }
                    .foregroundStyle(Taproom.ink)
                    .accessibilityLabel("Settings")
                    .padding(.trailing, -10)
                }
            }

            HStack(spacing: 0) {
                stat(info?.totalCheckins, "Total")
                stat(info?.totalBeers, "Unique")
                stat(info?.totalBadges, "Badges")
                if isAccountTab {
                    let waiting = CheckInOptions.shared.requests.count
                    NavigationLink(value: ProfileRoute.friends) {
                        stat(info?.totalFriends, "Friends", chevron: true, badge: waiting)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(waiting > 0
                        ? "Shows your friends and \(waiting) waiting friend request\(waiting == 1 ? "" : "s")"
                        : "Shows your friends")
                } else {
                    stat(info?.totalFriends, "Friends")
                }
            }
            .padding(.vertical, 16)
            .overlay(alignment: .top) { Rectangle().fill(Taproom.border).frame(height: 1) }
            .taproomRowDivider()
            .padding(.top, Taproom.sectionSpacing)

            if isAccountTab { statisticsEntry.padding(.top, Taproom.sectionSpacing) }

            Text("Checkins").font(Taproom.sectionLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Taproom.sectionSpacing)
        }
        .padding(.top, isAccountTab ? 8 : 0)
    }

    /// Opens the Statistics screen; only on your own profile.
    private var statisticsEntry: some View {
        NavigationLink(value: ProfileRoute.statistics) {
            HStack(spacing: 12) {
                Image(systemName: "chart.xyaxis.line").font(.title3).foregroundStyle(Taproom.amber).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Statistics").font(.body.weight(.heavy))
                    Text("Unique beers, check-ins and top beers").font(.footnote).foregroundStyle(Taproom.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Taproom.muted)
            }
            .padding(.horizontal, 14).frame(minHeight: 60)
            .taproomCard()
        }
        .buttonStyle(CardLinkStyle())
    }

    private var emptyText: String {
        if isAccountTab { return "You haven't checked in anything yet." }
        let name = info?.firstName ?? placeholder?.firstName ?? username
        return "\(name) hasn't checked in anything yet."
    }

    /// `badge` is how many friend requests are waiting: shown as an amber count by the number.
    private func stat(_ n: Int?, _ label: String, chevron: Bool = false, badge: Int = 0) -> some View {
        VStack(spacing: 2) {
            Text(n.map { $0.formatted() } ?? "–")
                .font(.system(size: 22, weight: .heavy).monospacedDigit())
                .tracking(-0.5)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .overlay(alignment: .topTrailing) {
                    // Sits just past the number's trailing edge, centred on its top.
                    if badge > 0 {
                        TaproomCountBadge(count: badge)
                            .alignmentGuide(.trailing) { $0[.leading] - 2 }
                            .alignmentGuide(.top) { $0[VerticalAlignment.center] }
                            .fixedSize()
                    }
                }
            HStack(spacing: 3) {
                Text(label)
                if chevron { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
            }
            .font(.caption).foregroundStyle(Taproom.muted)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func loadInfo() async {
        // A fetch that began before a friend was removed or added doesn't know about it.
        let changeAtStart = CheckInOptions.shared.friendCountChange
        let current = { (p: UserInfo.Profile?) -> UserInfo.Profile? in
            guard var p, isAccountTab else { return p }
            p.totalFriends = ProfileFriendCount.adjusted(
                p.totalFriends, changeAtStart: changeAtStart, changeNow: CheckInOptions.shared.friendCountChange)
            return p
        }
        if let i = try? await cacheThenNetwork(.userInfo(username), as: UserInfo.self, onCached: { info = current($0.user) }) {
            info = current(i.user)
        }
    }
}

/// The Me tab's friend count while friends are being removed and requests accepted.
enum ProfileFriendCount {
    /// `fetched` plus the net change (`CheckInOptions.friendCountChange`: up for an accept, down
    /// for a removal) made since the fetch began, which it can't include.
    static func adjusted(_ fetched: Int?, changeAtStart: Int, changeNow: Int) -> Int? {
        fetched.map { max(0, $0 + changeNow - changeAtStart) }
    }
}

/// Someone's profile, pushed from a person chip on a checkin.
struct UserProfileView: View {
    let user: User
    @State private var model: CheckinListModel

    init(user: User, me: User?) {
        self.user = user
        let model = CheckinListModel(source: .user(user.userName))
        model.me = me
        _model = State(initialValue: model)
    }

    var body: some View {
        ProfileView(username: user.userName, model: model, isAccountTab: false, placeholder: user)
    }
}

/// Declares where the Settings route opens, only on the Profile tab's root (repeats further up the
/// stack are ignored and warned about).
private struct SettingsDestination: ViewModifier {
    let enabled: Bool
    let username: String

    func body(content: Content) -> some View {
        if enabled {
            content.navigationDestination(for: ProfileRoute.self) { route in
                switch route {
                case .settings: SettingsView()
                case .friends: FriendsListView(username: username)
                case .statistics: StatsView(username: username)
                }
            }
        } else {
            content
        }
    }
}
