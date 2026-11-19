import SwiftUI

/// Where the Notifications screen is pushed on the Activity tab's stack.
struct NotificationsRoute: Hashable {}

/// Toasts, comments and tags on checkins (`GET /v4/notifications`), newest first, with friend
/// requests on top when there are any. Opening it marks everything seen (see `NotificationUnread`).
struct NotificationsView: View {
    let unread: NotificationUnread
    /// Opens a checkin on this stack; false when it couldn't be fetched (deleted, or offline).
    let openCheckin: (Int) async -> Bool
    /// Opens Me > Friends, where the requests are.
    let openFriends: () -> Void

    @State private var model = NotificationsModel()
    /// What had been seen when the screen opened, so what's new stays marked while it's open.
    @State private var seenOnOpen: Date?
    @State private var opening: Int?
    @State private var openFailed = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Notifications")
                    .font(.system(size: 34, weight: .heavy)).tracking(-0.6)
                    .padding(.bottom, 12)
                    .accessibilityAddTraits(.isHeader)

                if !unread.requests.isEmpty {
                    FriendRequestsRow(count: unread.requests.count, action: openFriends)
                        .taproomRowDivider()
                }
                ForEach(model.items) { item in
                    NotificationRow(item: item, isNew: item.isNew(since: seenOnOpen), compactLayout: typeSize.isAccessibilitySize) {
                        open(item)
                    }
                    .taproomRowDivider()
                    .onAppear { model.onAppear(item) }
                }
                footer
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.bottom, 24)
        }
        .readableContentWidth()
        .taproomScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .refreshable { await load() }
        .task {
            seenOnOpen = unread.lastSeen
            await load()
        }
        .alert("Couldn't open the check-in", isPresented: $openFailed) {
            Button("OK") {}
        } message: {
            Text("It may have been deleted, or you may be offline.")
        }
    }

    private func load() async {
        async let list: () = model.refresh()
        async let requests: () = unread.refresh()
        _ = await (list, requests)
        guard model.hasLoaded else { return }
        unread.markSeen(newest: model.newest)
    }

    private func open(_ item: NotificationItem) {
        guard opening == nil else { return }
        opening = item.checkinID
        Task {
            openFailed = !(await openCheckin(item.checkinID))
            opening = nil
        }
    }

    @ViewBuilder private var footer: some View {
        if model.items.isEmpty {
            if model.isLoading || !model.hasLoaded && model.error == nil {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            } else if let e = model.error {
                ErrorRow(message: e) { Task { await load() } }
            } else if unread.requests.isEmpty {
                ContentUnavailableView {
                    Label("Nothing yet", systemImage: "bell")
                } description: {
                    Text("Toasts, comments and tags on your check-ins will show up here.")
                }
                .padding(.top, 24)
            }
        } else if model.isLoadingMore {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
        } else if let e = model.moreError {
            ErrorRow(message: e) { Task { await model.loadMore() } }
        } else if let e = model.error {
            ErrorRow(message: e) { Task { await load() } }
        }
    }
}

private struct NotificationRow: View {
    let item: NotificationItem
    let isNew: Bool
    let compactLayout: Bool
    let action: () -> Void

    private var timeText: String { item.createdAt.map { RelativeTime.short($0) } ?? "" }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Avatar(url: item.users[0].avatar, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    (Text(item.actors).fontWeight(.semibold) + Text(" " + item.action))
                        .font(.subheadline)
                        .foregroundStyle(Taproom.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !timeText.isEmpty {
                        Text(timeText).font(.footnote).foregroundStyle(Taproom.muted)
                    }
                }
                Spacer(minLength: 0)
                if !compactLayout {
                    BeerLabel(beer: item.beerLabel, brewery: nil, size: 44, cornerRadius: 8)
                }
            }
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .background(isNew ? Taproom.amber.opacity(0.14) : Color.clear)
        }
        .buttonStyle(TaproomRowStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([isNew ? "New" : nil, item.sentence, item.createdAt.map { RelativeTime.string($0) }]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens the check-in")
        .accessibilityAddTraits(.isButton)
    }
}

private struct FriendRequestsRow: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.plus")
                    .font(.title3)
                    .foregroundStyle(Taproom.onAmber)
                    .frame(width: 44, height: 44)
                    .background(Taproom.amber, in: Circle())
                    .accessibilityHidden(true)
                Text("Friend requests").font(.body.weight(.semibold)).foregroundStyle(Taproom.ink)
                TaproomCountBadge(count: count)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Taproom.muted)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 10)
            .frame(minHeight: 64)
        }
        .buttonStyle(TaproomRowStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Friend requests, \(count) waiting")
        .accessibilityHint("Opens your friends and their requests")
        .accessibilityAddTraits(.isButton)
    }
}
