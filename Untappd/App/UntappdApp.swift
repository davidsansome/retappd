import SwiftUI

@main
struct UntappdApp: App {
    @State private var auth = AuthStore()
    @State private var location = LocationProvider()

    init() {
        Task { await LocalIndex.shared.warmUp() }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let username = auth.username, auth.isSignedIn {
                    RootTabs(username: username)
                        .id(username)
                } else {
                    LoginView()
                }
            }
            .environment(auth)
            .environment(location)
            .tint(.orange)
        }
    }
}

struct RootTabs: View {
    let username: String
    @Environment(LocationProvider.self) private var location
    @State private var feed = CheckinListModel(source: .friends)
    @State private var profile: CheckinListModel
    @State private var discover: DiscoverModel

    init(username: String) {
        self.username = username
        _profile = State(initialValue: CheckinListModel(source: .user(username)))
        _discover = State(initialValue: DiscoverModel(username: username))
    }

    var body: some View {
        TabView {
            Tab("Feed", systemImage: "list.bullet.rectangle") {
                NavigationStack { FeedView(model: feed) }
            }
            Tab("Discover", systemImage: "mappin.and.ellipse") {
                NavigationStack { DiscoverView(model: discover) }
            }
            Tab("Profile", systemImage: "person.crop.circle") {
                NavigationStack { ProfileView(username: username, model: profile) }
            }
        }
        .environment(discover)
        // Track location app-wide, so Discover is ready and check-ins can preselect the venue
        // you're at, even before the Discover tab is opened.
        .task { location.start() }
        .task { await loadMe() }
        .task(id: location.location.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" }) {
            await discover.update(location: location.location)
        }
        .onReceive(NotificationCenter.default.publisher(for: .didCheckIn)) { _ in
            Task {
                await feed.refresh()
                await profile.refresh()
            }
        }
    }
}

extension RootTabs {
    /// Loads the signed-in user's profile (cache-first) for showing their own avatar in toasts.
    private func loadMe() async {
        let apply = { (info: UserInfo) in
            guard let me = info.user?.asUser, me.id != 0 else { return }
            feed.me = me
            profile.me = me
        }
        if let info = try? await cacheThenNetwork(.userInfo(username), as: UserInfo.self, onCached: apply) {
            apply(info)
        }
    }
}

extension Notification.Name {
    static let didCheckIn = Notification.Name("didCheckIn")
}
