import SwiftUI

struct ProfileView: View {
    let username: String
    let model: CheckinListModel
    @Environment(AuthStore.self) private var auth
    @State private var info: UserInfo.Profile?
    @State private var confirmSignOut = false

    var body: some View {
        CheckinList(model: model, showUser: false, emptyText: "You haven't checked in anything yet.") {
            header.listRowSeparator(.hidden)
        }
        .toolbar(.hidden, for: .navigationBar)
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
            Avatar(url: info?.avatar, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(info?.displayName ?? username).font(.title3.bold())
                    Spacer()
                    Menu {
                        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            confirmSignOut = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Account")
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
