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
        .refreshable {
            async let a: () = model.refresh()
            async let b: () = loadInfo()
            async let c: () = isAccountTab ? HadBeers.shared.refresh(force: true) : ()
            _ = await (a, b, c)
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
                    NavigationLink(value: ProfileRoute.friends) { stat(info?.totalFriends, "Friends", chevron: true) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows your friends")
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

    private func stat(_ n: Int?, _ label: String, chevron: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(n.map { $0.formatted() } ?? "–")
                .font(.system(size: 22, weight: .heavy).monospacedDigit())
                .tracking(-0.5)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
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
        if let i = try? await cacheThenNetwork(.userInfo(username), as: UserInfo.self, onCached: { info = $0.user }) {
            info = i.user
        }
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
