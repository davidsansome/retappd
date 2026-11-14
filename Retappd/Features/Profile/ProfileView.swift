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
    @Environment(AuthStore.self) private var auth
    @State private var info: UserInfo.Profile?
    @State private var confirmSignOut = false

    var body: some View {
        CheckinList(model: model, showUser: false, registersDestinations: isAccountTab, emptyText: emptyText) {
            header.listRowSeparator(.hidden)
        }
        .toolbar(isAccountTab ? .hidden : .automatic, for: .navigationBar)
        .navigationTitle(isAccountTab ? "" : (info?.userName ?? username))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(SettingsDestination(enabled: isAccountTab))
        .confirmationDialog("Sign out of Untappd?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { auth.signOut() }
        }
        .task(id: model.reloads) { await loadInfo() }
        .refreshable {
            async let a: () = model.refresh()
            async let b: () = loadInfo()
            _ = await (a, b)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Avatar(url: info?.avatar ?? placeholder?.avatar, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(info?.displayName ?? placeholder?.displayName ?? username).font(.title3.bold())
                    Spacer()
                    if isAccountTab { accountMenu }
                }
                if let loc = info?.location { Text(loc).font(.subheadline).foregroundStyle(.secondary) }
                HStack(spacing: 16) {
                    stat(info?.totalCheckins, "Total")
                    stat(info?.totalBeers, "Unique")
                    stat(info?.totalBadges, "Badges")
                    stat(info?.totalFriends, "Friends")
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var accountMenu: some View {
        Menu {
            Button("Settings", systemImage: "gearshape") { openSettings() }
            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                confirmSignOut = true
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
        }
        .accessibilityLabel("Account")
    }

    private var emptyText: String {
        if isAccountTab { return "You haven't checked in anything yet." }
        let name = info?.firstName ?? placeholder?.firstName ?? username
        return "\(name) hasn't checked in anything yet."
    }

    private func stat(_ n: Int?, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(n.map { $0.formatted() } ?? "–").font(.subheadline.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
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

    func body(content: Content) -> some View {
        if enabled {
            content.navigationDestination(for: ProfileRoute.self) { _ in SettingsView() }
        } else {
            content
        }
    }
}
