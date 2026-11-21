import SwiftUI

/// The signed-in user's friends, newest friendship first, with local search and an "Add friend"
/// lookup. Pushed from the Friends stat on the Me tab; a row opens that person's profile through
/// the `User` destination the profile tab's checkin list registers.
struct FriendsListView: View {
    /// The signed-in user's username, so adding yourself can be refused.
    let username: String
    private let options = CheckInOptions.shared
    @State private var query = ""
    @State private var showingAdd = false
    @State private var showingQR = false
    @State private var confirmingRemoval: Friend?
    @State private var removeError: String?
    @State private var requestError: String?

    var body: some View {
        let sorted = Friend.sortedByRecent(options.friendships)
        let shown = Friend.filter(sorted, matching: query)
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                Text("Friends")
                    .font(.system(size: 34, weight: .heavy)).tracking(-0.6)
                    .accessibilityAddTraits(.isHeader)

                if !options.requests.isEmpty {
                    TaproomSection("Requests") {
                        VStack(spacing: 0) {
                            ForEach(Friend.sortedByRecent(options.requests)) { request in
                                RequestRow(
                                    request: request,
                                    accept: { answer(request, accepting: true) },
                                    reject: { answer(request, accepting: false) })
                                .taproomRowDivider()
                            }
                        }
                    }
                }

                if !sorted.isEmpty {
                    TaproomSearchField(text: $query, prompt: "Search friends")
                }

                if options.friendships.isEmpty {
                    placeholder
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query).padding(.top, 24)
                } else {
                    VStack(spacing: 0) {
                        ForEach(shown) { friend in
                            HStack(spacing: 0) {
                                NavigationLink(value: friend.user) { FriendRow(friend: friend) }
                                    .buttonStyle(TaproomRowStyle())
                                Menu {
                                    Button("Remove friend", role: .destructive) { confirmingRemoval = friend }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Taproom.muted)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("More options for \(friend.user.displayName)")
                                .padding(.trailing, -12)  // line the dots up with the content's trailing edge
                            }
                            .taproomRowDivider()
                        }
                    }
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.bottom, 24)
            .frame(maxWidth: .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .taproomScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Friend QR code", systemImage: "qrcode") { showingQR = true }
                    .labelStyle(.iconOnly)
                    .tint(Taproom.ink)
                    .accessibilityIdentifier("friends.qrButton")
                Button("Add friend", systemImage: "person.badge.plus") { showingAdd = true }
                    .labelStyle(.iconOnly)
                    .tint(Taproom.ink)
                    .accessibilityIdentifier("friends.addButton")
            }
        }
        .sheet(isPresented: $showingAdd) { AddFriendView(username: username) }
        .sheet(isPresented: $showingQR) { FriendQRCodeSheet(username: username) }
        .confirmationDialog(
            confirmingRemoval.map { "Remove @\($0.user.userName) as a friend?" } ?? "",
            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
            titleVisibility: .visible, presenting: confirmingRemoval
        ) { friend in
            Button("Remove friend", role: .destructive) { remove(friend) }
        } message: { _ in
            Text("They'll be taken off your friends list. You can send a new request later.")
        }
        .alert("Couldn't remove friend",
               isPresented: Binding(get: { removeError != nil }, set: { if !$0 { removeError = nil } }),
               presenting: removeError) { _ in
            Button("OK") {}
        } message: { Text($0) }
        .alert("Couldn't answer request",
               isPresented: Binding(get: { requestError != nil }, set: { if !$0 { requestError = nil } }),
               presenting: requestError) { _ in
            Button("OK") {}
        } message: { Text($0) }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        async let friends: () = options.reloadFriends()
        async let requests: () = options.loadRequests()
        _ = await (friends, requests)
    }

    /// Accepting or rejecting takes the request off the list at once; it comes back with an alert
    /// if the server refuses. Reject has no confirmation: it's a silent decline that can be undone
    /// by accepting later (the person's profile and the add-friend sheet both offer Accept).
    private func answer(_ request: Friend, accepting: Bool) {
        Task {
            do {
                if accepting { try await options.acceptRequest(request) } else { try await options.rejectRequest(request) }
                await ResponseCache.shared.remove(APIRequest.userInfo(request.user.userName).cacheKey)
            } catch {
                let what = accepting ? "accept" : "reject"
                requestError = "Couldn't \(what) \(request.user.displayName)'s request. \(error.localizedDescription)"
            }
        }
    }

    private func remove(_ friend: Friend) {
        Task {
            do {
                try await options.removeFriend(friend)
                await ResponseCache.shared.remove(APIRequest.userInfo(friend.user.userName).cacheKey)
            } catch {
                removeError = "\(friend.user.displayName) is still your friend. \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if options.loadingFriends {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
        } else if let e = options.friendsError {
            ErrorRow(message: e) { Task { await options.reloadFriends() } }
        } else if !options.requests.isEmpty {
            Text("Accept a request to add your first friend")
                .font(.subheadline).foregroundStyle(Taproom.muted)
        } else {
            ContentUnavailableView {
                Label("No friends yet", systemImage: "person.2")
            } description: {
                Text("Add someone by their username to see their checkins in your activity.")
            } actions: {
                Button { showingAdd = true } label: { Text("Add friend").padding(.horizontal, 16) }
                    .buttonStyle(TaproomOutlineButton()).frame(maxWidth: 220)
            }
            .padding(.top, 24)
        }
    }
}

/// A pending request: the person (opens their profile), when they asked, and Accept / Reject.
private struct RequestRow: View {
    let request: Friend
    let accept: () -> Void
    let reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            NavigationLink(value: request.user) {
                HStack(spacing: 12) {
                    Avatar(url: request.user.avatar, size: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(request.user.displayName).font(.body.weight(.semibold)).lineLimit(1)
                        Text(["@" + request.user.userName, request.createdAt.map { "asked " + RelativeTime.string($0) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(Taproom.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
                .frame(minHeight: 60)
            }
            .buttonStyle(TaproomRowStyle())
            HStack(spacing: 8) {
                Button("Accept", action: accept).buttonStyle(TaproomPrimaryButton(compact: true))
                    .accessibilityLabel("Accept \(request.user.displayName)'s request")
                Button("Reject", action: reject).buttonStyle(TaproomOutlineButton())
                    .accessibilityLabel("Reject \(request.user.displayName)'s request")
            }
            .padding(.bottom, 12)
        }
    }
}

private struct FriendRow: View {
    let friend: Friend

    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: friend.user.avatar, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(friend.user.displayName).font(.body.weight(.semibold)).lineLimit(1)
                Text(["@" + friend.user.userName, friend.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(Taproom.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 60)
    }
}

// MARK: - Add friend

/// Looks a user up by exact username and sends them a friend request.
///
/// The API repo documents no user-search endpoint, so there is no way to search by name: this
/// asks for an exact username and fetches `GET /v4/user/info/{username}` (the 404 for an unknown
/// one is how "no such user" is detected), then `POST /v4/friend/request/{uid}`.
struct AddFriendView: View {
    let username: String
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var phase = Phase.idle
    @State private var lookupTask: Task<Void, Never>?
    @State private var showingScanner = false

    enum Phase: Equatable {
        case idle
        case looking
        case found(UserInfo.Profile)
        case missing(String)
        case failed(String)

        static func == (a: Phase, b: Phase) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.looking, .looking): true
            case let (.found(x), .found(y)): x.id == y.id
            case let (.missing(x), .missing(y)): x == y
            case let (.failed(x), .failed(y)): x == y
            default: false
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                    TaproomSection("Username") {
                        VStack(spacing: 10) {
                            TaproomSearchField(text: $typed, prompt: "Exact username")
                                .onSubmit(lookUp)
                            Button("Look up", action: lookUp)
                                .buttonStyle(TaproomOutlineButton())
                                .disabled(Friends.normalized(typed) == nil || phase == .looking)
                        }
                    }
                    result
                    if case .idle = phase {
                        TaproomSection("Or scan a QR code") {
                            Button {
                                showingScanner = true
                            } label: {
                                Label("Scan a friend's QR code", systemImage: "qrcode.viewfinder")
                            }
                            .buttonStyle(TaproomOutlineButton())
                            .accessibilityIdentifier("addFriend.scanQR")
                        }
                    }
                }
                .padding(.horizontal, Taproom.margin)
                .padding(.bottom, 24)
                .frame(maxWidth: .readableContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .taproomScreen()
            .navigationTitle("Add a friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Taproom.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).tint(Taproom.ink)
                }
            }
            .sheet(isPresented: $showingScanner) {
                FriendQRScannerSheet(username: username)
            }
            .onChange(of: typed) {
                lookupTask?.cancel()
                lookupTask = nil
                phase = .idle
            }
            .onDisappear {
                lookupTask?.cancel()
                lookupTask = nil
            }
        }
    }

    @ViewBuilder private var result: some View {
        switch phase {
        case .idle:
            Text("Untappd's API has no way to search for people, so type their exact username or scan their QR code.")
                .font(.footnote).foregroundStyle(Taproom.muted)
        case .looking:
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
        case .missing(let name):
            ContentUnavailableView("No user called \(name)", systemImage: "person.fill.questionmark",
                                   description: Text("Check the spelling. Usernames have to match exactly."))
        case .failed(let message):
            ErrorRow(message: message, retry: lookUp)
        case .found(let profile):
            AddFriendResultCard(profile: profile, me: username)
                .id(profile.id)
        }
    }

    private func lookUp() {
        guard let name = Friends.normalized(typed), phase != .looking else { return }
        lookupTask?.cancel()
        phase = .looking
        lookupTask = Task {
            do {
                let info = try await UntappdAPI.shared.fetch(.userInfo(name), as: UserInfo.self)
                guard !Task.isCancelled, Friends.normalized(typed) == name else { return }
                if let p = info.user, p.id != 0 { phase = .found(p) } else { phase = .missing(name) }
            } catch let e as APIError {
                guard !Task.isCancelled, !e.isCancellation, Friends.normalized(typed) == name else { return }
                phase = Friends.isNotFound(e) ? .missing(name) : .failed(e.localizedDescription)
            } catch {
                guard !Task.isCancelled, !error.isCancellation, Friends.normalized(typed) == name else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

/// Shows a looked-up user's card with the appropriate friendship action ("Add friend", "Accept",
/// or their current relationship status). Shared by `AddFriendView` and `FriendQRScannerView`.
struct AddFriendResultCard: View {
    let profile: UserInfo.Profile
    let me: String
    private let options = CheckInOptions.shared
    @State private var sending = false
    @State private var sent: String?
    @State private var sendError: String?
    @State private var accepting = false

    var body: some View {
        let status = Friends.status(of: profile, me: me, friendIDs: Set(options.friendships.map(\.id)))
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Avatar(url: profile.avatar, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName).font(.system(size: 20, weight: .heavy)).tracking(-0.3)
                    Text(["@" + profile.userName, profile.location].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(Taproom.muted)
                }
                Spacer(minLength: 0)
            }
            if let sent {
                Label(sent, systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(Taproom.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else if status.canAccept {
                Text(status.message).font(.subheadline).foregroundStyle(Taproom.muted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                Button { accept() } label: {
                    if accepting { ProgressView().accessibilityLabel("Accepting") } else { Text("Accept") }
                }
                .buttonStyle(TaproomPrimaryButton())
                .disabled(accepting)
            } else if status != .canAdd {
                Text(status.message).font(.subheadline).foregroundStyle(Taproom.muted)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Button { send() } label: {
                    if sending { ProgressView() } else { Text("Add friend") }
                }
                .buttonStyle(TaproomPrimaryButton())
                .disabled(sending)
            }
            if let sendError {
                Text(sendError).font(.footnote).foregroundStyle(Taproom.muted).multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .taproomCard()
    }

    private func send() {
        sending = true
        sendError = nil
        Task {
            defer { sending = false }
            do {
                let r = try await UntappdAPI.shared.fetch(.sendFriendRequest(profile.id), as: FriendRequestResult.self)
                sent = r.confirmation
                await ResponseCache.shared.remove(APIRequest.userInfo(profile.userName).cacheKey)
            } catch {
                sendError = Friends.sendErrorMessage(error)
            }
        }
    }

    /// Accepts their request through the shared store, so they join the friends list at once
    /// (and the card then reads "You're already friends.").
    private func accept() {
        accepting = true
        sendError = nil
        Task {
            defer { accepting = false }
            do {
                try await options.acceptRequest(Friend(user: profile.asUser, location: profile.location))
                await ResponseCache.shared.remove(APIRequest.userInfo(profile.userName).cacheKey)
            } catch {
                sendError = error.localizedDescription
            }
        }
    }
}

/// Pure helpers for the add-friend lookup.
enum Friends {
    /// Whether someone can be sent a request, and if not, why.
    enum Status: Equatable {
        case canAdd, you, friends, following
        /// You've asked and they haven't answered, or they've asked you.
        case requestSent, requestReceived
        /// They asked and you rejected it (`relationship: "ignore"`). Rejecting is silent and
        /// you can still accept.
        case requestRejected

        /// Whether the sheet offers an Accept button: they asked, whether or not you rejected it.
        var canAccept: Bool { self == .requestReceived || self == .requestRejected }

        var message: String {
            switch self {
            case .canAdd: ""
            case .you: "That's you."
            case .friends: "You're already friends."
            case .following: "You already follow this account."
            case .requestSent: "Friend request sent. Waiting for them to accept."
            case .requestReceived: "They've already sent you a friend request."
            case .requestRejected: "You rejected their friend request."
            }
        }
    }

    static func status(of p: UserInfo.Profile, me: String, friendIDs: Set<Int>) -> Status {
        if p.userName.caseInsensitiveCompare(me) == .orderedSame { return .you }
        if p.relationship == "friends" || friendIDs.contains(p.id) { return .friends }
        if p.relationship == "follow" { return .following }
        if p.relationship == "pending_them" { return .requestSent }
        if p.relationship == "pending_you" { return .requestReceived }
        if p.relationship == "ignore" { return .requestRejected }
        return .canAdd
    }

    /// The username to look up: trimmed, without a leading "@", or nil if it's empty or has
    /// characters a username can't (which would also change the request's path).
    static func normalized(_ typed: String) -> String? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("@") { s.removeFirst() }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        guard !s.isEmpty, s.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return s
    }

    /// What to tell someone whose `friend/request` failed. If they'd already asked, the server
    /// answers HTTP 500 `invalid_param` "This request is pending the user's approval." (seen live
    /// on 2026-11-19, after the other side rejected): say so in friendlier words. That also
    /// covers a request you sent that was rejected, which stays pending from your side.
    static func sendErrorMessage(_ error: Error) -> String {
        if case let .server(_, detail?) = error as? APIError, detail.localizedCaseInsensitiveContains("pending") {
            return "Your request is still waiting for them."
        }
        return error.localizedDescription
    }

    /// Whether an error from `user/info` means the user doesn't exist.
    static func isNotFound(_ e: APIError) -> Bool {
        switch e {
        case .http(404): true
        case .server(code: 404, _): true
        default: false
        }
    }
}
