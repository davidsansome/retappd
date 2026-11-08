import SwiftUI

@main
struct RetappdApp: App {
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
    enum Page: Hashable { case feed, discover, profile }

    /// How long the app must have been in the background before reopening it refreshes everything.
    static var staleAfter: TimeInterval {
        #if DEBUG
        // e.g. launch with `-staleAfter 10` to try it without waiting.
        let override = UserDefaults.standard.double(forKey: "staleAfter")
        if override > 0 { return override }
        #endif
        return 5 * 60
    }

    let username: String
    @Environment(LocationProvider.self) private var location
    @Environment(\.scenePhase) private var scenePhase
    @State private var feed = CheckinListModel(source: .friends)
    @State private var profile: CheckinListModel
    @State private var discover: DiscoverModel
    @State private var page = Page.feed
    @State private var feedPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var backgroundedAt: Date?

    init(username: String) {
        self.username = username
        _profile = State(initialValue: CheckinListModel(source: .user(username)))
        _discover = State(initialValue: DiscoverModel(username: username))
    }

    var body: some View {
        TabView(selection: $page) {
            Tab("Feed", systemImage: "list.bullet.rectangle", value: .feed) {
                NavigationStack(path: $feedPath) { FeedView(model: feed) }
            }
            Tab("Discover", systemImage: "mappin.and.ellipse", value: .discover) {
                NavigationStack { DiscoverView(model: discover) }
            }
            Tab("Profile", systemImage: "person.crop.circle", value: .profile) {
                NavigationStack(path: $profilePath) { ProfileView(username: username, model: profile) }
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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = .now
            case .active:
                if let at = backgroundedAt, Date.now.timeIntervalSince(at) >= Self.staleAfter {
                    reopenedAfterAWhile()
                }
                backgroundedAt = nil
            default:
                break
            }
        }
    }

    /// Brings the feed or profile up to date if it's on screen, and leaves everything else to
    /// refresh the next time it's shown.
    private func reopenedAfterAWhile() {
        discover.invalidate()
        feed.invalidate()
        profile.invalidate()
        // A pushed checkin or venue covers the list, so that counts as not being on the page.
        if page == .feed && feedPath.isEmpty {
            Task { await feed.reload() }
        } else if page == .profile && profilePath.isEmpty {
            Task { await profile.reload() }
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
