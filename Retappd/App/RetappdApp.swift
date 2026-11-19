import SwiftUI

@main
struct RetappdApp: App {
    @UIApplicationDelegateAdaptor(NotificationAppDelegate.self) private var appDelegate
    @State private var auth = AuthStore()
    @State private var location = LocationProvider()
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system
    @Environment(\.scenePhase) private var scenePhase

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
                        #if DEBUG
                        .task { await auth.signInFromLaunchArguments() }
                        #endif
                }
            }
            .environment(auth)
            .environment(location)
            .tint(Taproom.amber)
            .preferredColorScheme(appearance.colorScheme)
            // A notification registration deleted at sign-out that couldn't reach the server is
            // retried here, signed in or not.
            .task { await NotificationService.shared.retryPendingDeletion() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await NotificationService.shared.retryPendingDeletion() } }
            }
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
    /// Bumped to focus Discover's search field, or open its barcode scanner, from the tab bar.
    @State private var searchRequests = 0
    @State private var scanRequests = 0
    @State private var router = NotificationRouter.shared
    @State private var unread: NotificationUnread

    init(username: String) {
        self.username = username
        _profile = State(initialValue: CheckinListModel(source: .user(username)))
        _discover = State(initialValue: DiscoverModel(username: username))
        _unread = State(initialValue: NotificationUnread(username: username))
    }

    var body: some View {
        // The system tab bar is hidden; each tab's root screen carries the Taproom bar instead.
        TabView(selection: $page) {
            Tab("Activity", systemImage: "list.bullet.rectangle", value: .feed) {
                NavigationStack(path: $feedPath) {
                    FeedView(model: feed).safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
                        .beerAndBreweryDestinations()
                        .navigationDestination(for: NotificationsRoute.self) { _ in
                            NotificationsView(unread: unread, openCheckin: { await showCheckin($0) }, openFriends: openFriends)
                        }
                }
                .toolbarVisibility(.hidden, for: .tabBar)
            }
            Tab("Discover", systemImage: "mappin.and.ellipse", value: .discover) {
                NavigationStack {
                    DiscoverView(model: discover, searchRequests: searchRequests, scanRequests: scanRequests)
                        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
                        .beerAndBreweryDestinations()
                }
                .toolbarVisibility(.hidden, for: .tabBar)
            }
            Tab("Me", systemImage: "person.crop.circle", value: .profile) {
                NavigationStack(path: $profilePath) {
                    ProfileView(username: username, model: profile) { profilePath.append(ProfileRoute.settings) }
                        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
                        .beerAndBreweryDestinations()
                }
                .toolbarVisibility(.hidden, for: .tabBar)
            }
        }
        .environment(discover)
        .environment(unread)
        // Track location app-wide, so Discover is ready and check-ins can preselect the venue
        // you're at, even before the Discover tab is opened.
        .task { location.start() }
        .task { await loadMe() }
        .task {
            // Every response's envelope says how much is unread; the bell listens.
            let unread = unread
            UntappdAPI.shared.onUnreadCounts = { counts, seq in Task { @MainActor in unread.ingest(counts, startedAt: seq) } }
        }
        .task { await NotificationService.shared.appBecameActive() }
        .onChange(of: router.pending, initial: true) { _, route in
            guard let route else { return }
            router.pending = nil
            open(route)
        }
        .task { await HadBeers.shared.refresh() }
        .task { await CheckInOptions.shared.loadAccountSettings() }
        .task { await CheckInOptions.shared.loadRecentVenues(username: username) }
        .task { await CheckInOptions.shared.loadFriends() }
        .task(id: location.location.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" }) {
            await discover.update(location: location.location)
        }
        .onReceive(NotificationCenter.default.publisher(for: .didCheckIn)) { _ in
            Task {
                await feed.refresh()
                await profile.refresh()
                await CheckInOptions.shared.loadRecentVenues(username: username)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .checkinDeleted)) { n in
            guard let id = n.object as? Int else { return }
            feed.remove(id: id)
            profile.remove(id: id)
            // The beer may no longer be one you've had.
            Task { await HadBeers.shared.refresh(force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .checkinEdited)) { n in
            guard let c = n.object as? Checkin else { return }
            feed.replace(c)
            profile.replace(c)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = .now
            case .active:
                Task { await NotificationService.shared.appBecameActive() }
                Task { await unread.refresh() }
                Task { await HadBeers.shared.refresh() }
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
    private static let tabs = [
        TaproomTab(value: Page.feed, title: "Activity", systemImage: "list.bullet.rectangle"),
        TaproomTab(value: Page.discover, title: "Discover", systemImage: "mappin.and.ellipse"),
        TaproomTab(value: Page.profile, title: "Me", systemImage: "person.crop.circle"),
    ]

    private var tabBar: some View {
        TaproomTabBar(tabs: Self.tabs, selection: page, select: select) {
            if page == .discover {
                TaproomBarAction(title: "Scan", systemImage: "barcode.viewfinder") { scanRequests += 1 }
                    .accessibilityHint("Finds a beer by its barcode")
            } else {
                TaproomBarAction(title: "Search", systemImage: "magnifyingglass") {
                    page = .discover
                    searchRequests += 1
                }
                    .accessibilityHint("Searches for beers and venues")
            }
        }
    }

    /// Opens what a tapped push notification is about: a check-in on the Activity tab, or the
    /// Friends screen (with its requests) on Me.
    private func open(_ route: NotificationRoute) {
        switch route {
        case .friendRequest:
            openFriends()
        case .checkin(let id):
            page = .feed
            feedPath = NavigationPath()
            // Not fetched yet, so the feed is shown meanwhile; a failure just leaves it there.
            Task { _ = await showCheckin(id) }
        }
    }

    private func openFriends() {
        page = .profile
        profilePath = NavigationPath([ProfileRoute.friends])
    }

    /// Fetches a checkin by id and pushes it on the Activity stack. False if that failed.
    private func showCheckin(_ id: Int) async -> Bool {
        guard let r = try? await UntappdAPI.shared.fetch(.checkinView(id), as: CheckinView.self),
              let c = r.checkin else { return false }
        feedPath.append(CheckinRoute(checkin: c, listID: UUID()))
        return true
    }

    /// Switches tab; choosing the tab you're on takes its list back to the top.
    private func select(_ p: Page) {
        guard p == page else { page = p; return }
        switch p {
        case .feed: feed.scrollToTop()
        case .profile: profile.scrollToTop()
        case .discover: break
        }
    }

    /// Loads the signed-in user's profile (cache-first) for showing their own avatar in toasts.
    private func loadMe() async {
        let apply = { (info: UserInfo) in
            guard let me = info.user?.asUser, me.id != 0 else { return }
            feed.me = me
            profile.me = me
            discover.me = me
        }
        if let info = try? await cacheThenNetwork(.userInfo(username), as: UserInfo.self, onCached: apply) {
            apply(info)
        }
    }
}

extension Notification.Name {
    static let didCheckIn = Notification.Name("didCheckIn")
}
