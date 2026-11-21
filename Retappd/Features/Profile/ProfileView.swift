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
    @Environment(\.openURL) private var openURL
    @State private var info: UserInfo.Profile?
    @State private var showingQR = false
    @State private var friendActionInFlight = false
    @State private var confirmingRemoval: UserInfo.Profile?
    @State private var confirmingBlock: UserInfo.Profile?
    @State private var friendActionError: FriendActionError?
    @State private var friendActionFeedback = 0

    private struct FriendActionError {
        let title: String
        let message: String
    }

    var body: some View {
        CheckinList(model: model, showUser: false, registersDestinations: isAccountTab, emptyText: emptyText) {
            header
        }
        .toolbar(isAccountTab ? .hidden : .automatic, for: .navigationBar)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .navigationTitle(isAccountTab ? "" : (info?.userName ?? username))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isAccountTab, let profile = info,
               let action = ProfileFriendMenu.action(
                   for: profile,
                   me: auth.username ?? "",
                   friendIDs: Set(CheckInOptions.shared.friendships.map(\.id))
               ) {
                ToolbarItem(placement: .topBarTrailing) {
                    if friendActionInFlight {
                        ProgressView()
                            .accessibilityLabel("Updating friendship")
                    } else {
                        Menu("More", systemImage: "ellipsis") {
                            overflowMenuContent(for: action, profile: profile)
                        }
                        .tint(Taproom.ink)
                        .accessibilityIdentifier("profile.overflowMenu")
                    }
                }
            }
        }
        .confirmationDialog(
            confirmingRemoval.map { "Remove @\($0.userName) as a friend?" } ?? "",
            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
            titleVisibility: .visible, presenting: confirmingRemoval
        ) { profile in
            Button("Remove friend", role: .destructive) { removeFriend(profile) }
        } message: { _ in
            Text("They'll be taken off your friends list. You can send a new request later.")
        }
        .confirmationDialog(
            confirmingBlock.map { "Block @\($0.userName)?" } ?? "",
            isPresented: Binding(get: { confirmingBlock != nil }, set: { if !$0 { confirmingBlock = nil } }),
            titleVisibility: .visible, presenting: confirmingBlock
        ) { profile in
            Button("Block user", role: .destructive) { toggleBlockUser(profile) }
        } message: { _ in
            Text("They won't be able to see your checkins or interact with you, and if you're friends they'll be removed from your friends list.")
        }
        .alert(
            friendActionError?.title ?? "",
            isPresented: Binding(get: { friendActionError != nil }, set: { if !$0 { friendActionError = nil } }),
            presenting: friendActionError
        ) { _ in
            Button("OK") {}
        } message: { Text($0.message) }
        .sensoryFeedback(.success, trigger: friendActionFeedback)
        .sheet(isPresented: $showingQR) { FriendQRCodeSheet(username: username, initialProfile: info) }
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
            .overlay(alignment: .topLeading) {
                if isAccountTab {
                    Button { showingQR = true } label: {
                        Image(systemName: "qrcode").font(.title3).frame(width: 44, height: 44)
                    }
                    .foregroundStyle(Taproom.ink)
                    .accessibilityLabel("Friend QR code")
                    .accessibilityIdentifier("profile.qrButton")
                    .padding(.leading, -10)
                }
            }
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

    @ViewBuilder
    private func overflowMenuContent(for action: ProfileFriendMenu, profile: UserInfo.Profile) -> some View {
        if !profile.isBlocked {
            friendMenuContent(for: action, profile: profile)
            if action == .remove {
                if profile.isMuted {
                    Button("Unmute user", systemImage: "speaker.wave.2") { unmuteUser(profile) }
                } else {
                    Menu("Mute user", systemImage: "speaker.slash") {
                        Button("For 1 day") { muteUser(profile, days: 1) }
                        Button("For 7 days") { muteUser(profile, days: 7) }
                        Button("Forever") { muteUser(profile, days: 0) }
                    }
                }
            }
            Divider()
        }
        if profile.isBlocked {
            Button("Unblock user", systemImage: "hand.raised.slash") { toggleBlockUser(profile) }
        } else {
            Button("Block user", systemImage: "hand.raised", role: .destructive) { confirmingBlock = profile }
        }
        if let reportURL = UntappdWebURL.reportUser(profile.userName) {
            Button("Report user", systemImage: "flag", role: .destructive) { openURL(reportURL) }
        }
    }

    @ViewBuilder
    private func friendMenuContent(for action: ProfileFriendMenu, profile: UserInfo.Profile) -> some View {
        switch action {
        case .add:
            Button("Add friend", systemImage: "person.badge.plus") { addFriend(profile) }
        case .remove:
            Button("Remove friend", systemImage: "person.badge.minus", role: .destructive) { confirmingRemoval = profile }
        case .requestSent:
            Button("Friend request sent", systemImage: "clock") {}
                .disabled(true)
        case .following:
            Button("Following", systemImage: "checkmark") {}
                .disabled(true)
        case .accept(let canReject):
            Button("Accept friend request", systemImage: "person.badge.plus") { answerRequest(profile, accepting: true) }
            if canReject {
                Button("Reject friend request", systemImage: "person.badge.minus", role: .destructive) {
                    answerRequest(profile, accepting: false)
                }
            }
        }
    }

    private func addFriend(_ profile: UserInfo.Profile) {
        friendActionInFlight = true
        Task {
            defer { friendActionInFlight = false }
            do {
                let result = try await UntappdAPI.shared.fetch(.sendFriendRequest(profile.id), as: FriendRequestResult.self)
                info?.relationship = result.isFollow ? "follow" : "pending_them"
                await ResponseCache.shared.remove(APIRequest.userInfo(username).cacheKey)
                friendActionFeedback += 1
            } catch {
                friendActionError = FriendActionError(
                    title: "Couldn't add friend",
                    message: Friends.sendErrorMessage(error)
                )
            }
        }
    }

    private func removeFriend(_ profile: UserInfo.Profile) {
        friendActionInFlight = true
        Task {
            defer { friendActionInFlight = false }
            do {
                try await CheckInOptions.shared.removeFriend(Friend(user: profile.asUser, location: profile.location))
                info?.relationship = "none"
                if let total = info?.totalFriends { info?.totalFriends = max(0, total - 1) }
                await ResponseCache.shared.remove(APIRequest.userInfo(username).cacheKey)
                friendActionFeedback += 1
            } catch {
                friendActionError = FriendActionError(
                    title: "Couldn't remove friend",
                    message: "\(profile.displayName) is still your friend. \(error.localizedDescription)"
                )
            }
        }
    }

    private func answerRequest(_ profile: UserInfo.Profile, accepting: Bool) {
        friendActionInFlight = true
        Task {
            defer { friendActionInFlight = false }
            let friend = Friend(user: profile.asUser, location: profile.location)
            do {
                if accepting {
                    try await CheckInOptions.shared.acceptRequest(friend)
                    info?.relationship = "friends"
                    if let total = info?.totalFriends { info?.totalFriends = total + 1 }
                } else {
                    try await CheckInOptions.shared.rejectRequest(friend)
                    info?.relationship = "ignore"
                }
                await ResponseCache.shared.remove(APIRequest.userInfo(username).cacheKey)
                friendActionFeedback += 1
            } catch {
                let what = accepting ? "accept" : "reject"
                friendActionError = FriendActionError(
                    title: "Couldn't answer request",
                    message: "Couldn't \(what) \(profile.displayName)'s request. \(error.localizedDescription)"
                )
            }
        }
    }

    private func toggleBlockUser(_ profile: UserInfo.Profile) {
        friendActionInFlight = true
        let wasFriend = profile.relationship == "friends"
        let blocking = !profile.isBlocked
        Task {
            defer { friendActionInFlight = false }
            do {
                let result = try await UntappdAPI.shared.fetch(.toggleBlockUser(profile.id), as: BlockUserResult.self)
                let nowBlocked = result.isBlocked
                info?.blockStatus = nowBlocked ? "blocked_you" : "none"
                if nowBlocked {
                    if wasFriend {
                        info?.relationship = "none"
                        if let total = info?.totalFriends { info?.totalFriends = max(0, total - 1) }
                    }
                    info?.muteStatus = "unmute"
                    await CheckInOptions.shared.noteBlockedFriend(profile.id)
                }
                await ResponseCache.shared.remove(APIRequest.userInfo(username).cacheKey)
                NotificationCenter.default.post(name: .userModerationChanged, object: nowBlocked ? profile.id : nil)
                friendActionFeedback += 1
            } catch {
                friendActionError = FriendActionError(
                    title: blocking ? "Couldn't block user" : "Couldn't unblock user",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func muteUser(_ profile: UserInfo.Profile, days: Int) {
        friendActionInFlight = true
        Task {
            defer { friendActionInFlight = false }
            do {
                _ = try await UntappdAPI.shared.data(.muteUser(profile.id, days: days))
                info?.muteStatus = "mute"
                await ResponseCache.shared.remove(APIRequest.userInfo(username).cacheKey)
                NotificationCenter.default.post(name: .userModerationChanged, object: profile.id)
                friendActionFeedback += 1
            } catch {
                friendActionError = FriendActionError(
                    title: "Couldn't mute user",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func unmuteUser(_ profile: UserInfo.Profile) {
        friendActionInFlight = true
        Task {
            defer { friendActionInFlight = false }
            do {
                _ = try await UntappdAPI.shared.data(.unmuteUser(profile.id))
                info?.muteStatus = "unmute"
                await ResponseCache.shared.remove(APIRequest.userInfo(username).cacheKey)
                NotificationCenter.default.post(name: .userModerationChanged, object: nil)
                friendActionFeedback += 1
            } catch {
                friendActionError = FriendActionError(
                    title: "Couldn't unmute user",
                    message: error.localizedDescription
                )
            }
        }
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

/// What the overflow menu on another user's profile offers, based on the friendship status.
enum ProfileFriendMenu: Equatable {
    case add
    case remove
    case requestSent
    case following
    /// They sent you a request (`canReject == true` while pending, `false` if already rejected).
    case accept(canReject: Bool)

    static func action(for profile: UserInfo.Profile, me: String, friendIDs: Set<Int>) -> Self? {
        guard profile.id != 0 else { return nil }
        switch Friends.status(of: profile, me: me, friendIDs: friendIDs) {
        case .you: return nil
        case .friends: return .remove
        case .canAdd: return .add
        case .requestSent: return .requestSent
        case .following: return .following
        case .requestReceived: return .accept(canReject: true)
        case .requestRejected: return .accept(canReject: false)
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
