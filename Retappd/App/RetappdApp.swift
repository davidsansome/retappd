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
        UntappdAPI.shared.onRequestOutcome = { outcome in
            Task { @MainActor in Connectivity.shared.record(outcome) }
        }
        Connectivity.shared.startMonitoring()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ScreenshotDemo.isEnabled {
                ScreenshotDemoRoot(auth: auth, location: location)
            } else {
                mainScene
            }
            #else
            mainScene
            #endif
        }
    }

    private var mainScene: some View {
        Group {
            if let username = auth.username, auth.isSignedIn {
                if AuthStore.isValidUsername(username) {
                    RootTabs(username: username)
                        .id(username)
                } else {
                    UsernameResolutionView()
                }
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
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if !signedIn { location.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await NotificationService.shared.retryPendingDeletion() } }
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
    @Environment(AuthStore.self) private var auth
    @Environment(LocationProvider.self) private var location
    @Environment(\.scenePhase) private var scenePhase
    @State private var feed = CheckinListModel(source: .friends)
    @State private var profile: CheckinListModel
    @State private var discover: DiscoverModel
    @State private var page = Page.feed
    @State private var feedPath = NavigationPath()
    @State private var profilePath = NavigationPath()
    @State private var discoverPath = NavigationPath()
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
        VStack(spacing: 0) {
            CheckinQueueBanner(queue: CheckinQueue.shared)
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
                    NavigationStack(path: $discoverPath) {
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
        }
        .environment(discover)
        .environment(unread)
        .background { keyboardShortcuts }
        // Resume location updates if already authorized, without prompting until the user
        // opens Discover or starts a check-in.
        .task { location.startIfAuthorized() }
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
        .task { await VenueHistory.shared.refresh() }
        .onChange(of: PendingCheckins.shared.items) { _, items in PendingReminders.shared.update(items) }
        .task {
            if let settings = await CheckInOptions.shared.loadAccountSettings() {
                auth.reconcileUsername(settings.userName)
            }
        }
        .task { await CheckInOptions.shared.loadRecentVenues(username: username) }
        .task { await CheckInOptions.shared.loadFriends() }
        .task(id: location.location.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" }) {
            await discover.update(location: location.location)
        }
        .onReceive(NotificationCenter.default.publisher(for: .didCheckIn)) { _ in
            Task {
                async let f: Void = feed.refresh()
                async let p: Void = profile.refresh()
                async let v: Void = CheckInOptions.shared.loadRecentVenues(username: username)
                _ = await (f, p, v)
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
        .onReceive(NotificationCenter.default.publisher(for: .userModerationChanged)) { n in
            if let hiddenUserID = n.object as? Int { feed.removeCheckins(byUserID: hiddenUserID) }
            Task { await feed.refresh() }
        }
        // Requests may have been accepted or rejected on Me > Friends; the bell lives on Activity,
        // so it recounts (one small call) when you come back to that tab.
        .onChange(of: page) { _, page in
            if page == .feed { Task { await unread.refresh() } }
            if page == .discover { location.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                PendingReminders.shared.update(PendingCheckins.shared.items)
                backgroundedAt = .now
            case .active:
                Task { await NotificationService.shared.appBecameActive() }
                Task { await unread.refresh() }
                Task { await HadBeers.shared.refresh() }
                Task { await VenueHistory.shared.refresh() }
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

    private var keyboardShortcuts: some View {
        Group {
            Button("Activity") { select(.feed) }.keyboardShortcut("1", modifiers: .command)
            Button("Discover") { select(.discover) }.keyboardShortcut("2", modifiers: .command)
            Button("Me") { select(.profile) }.keyboardShortcut("3", modifiers: .command)
            Button("Search") {
                page = .discover
                searchRequests += 1
            }.keyboardShortcut("f", modifiers: .command)
            Button("Refresh") {
                Task {
                    switch page {
                    case .feed: await feed.refresh()
                    case .discover: await discover.update(location: location.location, force: true)
                    case .profile: await profile.refresh()
                    }
                }
            }.keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

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
        case .pendingCheckins:
            // The "To check in" card leads Discover.
            page = .discover
            discoverPath = NavigationPath()  // back to the top, where the card is
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

/// Shown briefly on launch only when an existing install has an invalid username stored (such as an
/// email address from an older sign-in) while resolving the canonical Untappd `user_name`.
private struct UsernameResolutionView: View {
    @Environment(AuthStore.self) private var auth
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 16) {
            if let error {
                Text("Couldn't load your account")
                    .font(.headline)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(Taproom.muted)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Try again") {
                        self.error = nil
                        attempt += 1
                    }
                    .buttonStyle(TaproomOutlineButton())
                    Button("Sign out", role: .destructive) {
                        auth.signOut()
                    }
                    .buttonStyle(TaproomOutlineButton())
                }
            } else {
                ProgressView()
                Text("Finishing sign in…")
                    .font(.subheadline)
                    .foregroundStyle(Taproom.muted)
            }
        }
        .padding(Taproom.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .taproomScreen()
        .task(id: attempt) {
            do {
                try await auth.refreshUsernameIfNeeded()
            } catch {
                if !error.isCancellation {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

extension Notification.Name {
    static let didCheckIn = Notification.Name("didCheckIn")
    /// Posted after blocking, unblocking, muting or unmuting a user. `object` is the user's `Int`
    /// uid when their checkins should be hidden from the feed immediately, or `nil` on unblock/unmute.
    static let userModerationChanged = Notification.Name("userModerationChanged")
}
