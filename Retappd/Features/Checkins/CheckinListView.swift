import SwiftUI

/// Shared infinite list used by the Feed and Profile tabs. Rows open `CheckinDetailView`.
struct CheckinList<Header: View>: View {
    let model: CheckinListModel
    var showUser = true
    var showActions = false
    /// Whether to declare where checkins, venues and people open. Only the list at the root of a
    /// navigation stack should, as SwiftUI ignores (and warns about) repeats further up the stack.
    var registersDestinations = true
    var emptyText = "No checkins yet."
    @ViewBuilder var header: () -> Header
    @State private var checkInBeer: BeerLite?
    @State private var editing: Checkin?
    @State private var deleting: Checkin?
    /// Tags this list's links, so its rows only show as selected for checkins it opened itself.
    @State private var listID = UUID()
    @Environment(DiscoverModel.self) private var discover
    @Environment(AuthStore.self) private var auth

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: model.scrollToTopRequests) { scrollToTop(proxy) }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                header().id(Self.topID)
                ForEach(model.items) { c in
                    let mine = c.isBy(username: auth.username)
                    NavigationLink(value: CheckinRoute(checkin: c, listID: listID)) {
                        CheckinRow(checkin: c, showUser: showUser, showHad: !mine,
                                   menu: CheckinMenuItems.hasItems(c, isMine: mine) ? { menuItems(c, isMine: mine) } : nil,
                                   toast: showActions ? { toggleToast(c) } : nil,
                                   confirmingDelete: isConfirmingDelete(c),
                                   delete: { Task { await model.delete(c) } })
                    }
                    .buttonStyle(CardLinkStyle())
                    .id(c.id)
                    .onAppear { model.onAppear(c) }
                    .contextMenu { menuItems(c, isMine: mine) }
                }
                footer
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.bottom, 16)
        }
        .foregroundStyle(Taproom.ink)
        .background(Taproom.background)
        .readableContentWidth()
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
        .modifier(CheckinDestinations(enabled: registersDestinations, me: model.me))
        .fullScreenCover(item: $checkInBeer) { CheckInSheet(beer: $0, venue: discover.here.first) }
        .fullScreenCover(item: $editing) { CheckInSheet(editing: $0) }
    }

    private func menuItems(_ c: Checkin, isMine: Bool) -> CheckinMenuItems {
        CheckinMenuItems(checkin: c, isMine: isMine,
                         checkIn: { checkInBeer = $0 },
                         edit: { editing = c },
                         delete: { deleting = c })
    }

    private func toggleToast(_ c: Checkin) {
        Task { await model.toggleToast(c) }
    }

    private func isConfirmingDelete(_ c: Checkin) -> Binding<Bool> {
        Binding(get: { deleting?.id == c.id }, set: { if !$0, deleting?.id == c.id { deleting = nil } })
    }

    private static var topID: String { "CheckinList.top" }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        // An empty header has nothing to scroll to, so go to the first row instead.
        if Header.self != EmptyView.self {
            proxy.scrollTo(Self.topID, anchor: .top)
        } else if let first = model.items.first {
            proxy.scrollTo(first.id, anchor: .top)
        }
    }

    @ViewBuilder private var footer: some View {
        if model.items.isEmpty {
            if model.isRefreshing {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if let e = model.error {
                ErrorRow(message: e) { Task { await model.refresh() } }
            } else {
                Text(emptyText).foregroundStyle(Taproom.muted).frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        } else if model.isLoadingMore {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
        } else if let e = model.error {
            ErrorRow(message: e) { Task { await model.loadMore() } }
        }
    }
}

extension CheckinList where Header == EmptyView {
    init(model: CheckinListModel, showUser: Bool = true, showActions: Bool = false,
         emptyText: String = "No checkins yet.") {
        self.init(model: model, showUser: showUser, showActions: showActions, emptyText: emptyText) { EmptyView() }
    }
}

/// A checkin opened from a particular list, so that the same checkin opened from two lists in one
/// stack (the feed, then someone's profile) are separate pushes.
struct CheckinRoute: Hashable {
    let checkin: Checkin
    let listID: UUID
}

/// Where checkins, venues and people open within a navigation stack.
private struct CheckinDestinations: ViewModifier {
    let enabled: Bool
    let me: User?

    func body(content: Content) -> some View {
        if enabled {
            content
                .navigationDestination(for: CheckinRoute.self) { CheckinDetailView(checkin: $0.checkin, me: me) }
                .navigationDestination(for: Venue.self) { VenueDetailView(venue: $0) }
                .navigationDestination(for: User.self) { UserProfileView(user: $0, me: me) }
        } else {
            content
        }
    }
}

/// The Toast button at the end of a feed row's toasts.
struct ToastButton: View {
    let checkin: Checkin
    let toast: () -> Void

    var body: some View {
        Button(action: toast) {
            HStack(spacing: 4) {
                Image("toast").resizable().scaledToFit().frame(width: 18, height: 18)
                Text(checkin.youToasted ? "Toasted" : "Toast").font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(TaproomChip(on: checkin.youToasted))
        .accessibilityAddTraits(checkin.youToasted ? .isSelected : [])
        .accessibilityLabel(checkin.youToasted ? "Remove toast" : "Toast")
    }
}

struct ErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(message).font(.footnote).foregroundStyle(Taproom.muted).multilineTextAlignment(.center)
            Button("Retry", action: retry).buttonStyle(TaproomOutlineButton()).frame(maxWidth: 160)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

struct FeedView: View {
    let model: CheckinListModel

    var body: some View {
        CheckinList(model: model, showActions: true, emptyText: "Your friends haven't checked in anything yet.") {
            Text("Activity")
                .font(.system(size: 34, weight: .heavy))
                .tracking(-0.8)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// A whole card that opens something; dims a little while pressed.
struct CardLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: configuration.isPressed)
    }
}
