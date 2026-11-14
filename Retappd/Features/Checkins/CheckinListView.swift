import SwiftUI

/// Shared infinite list used by the Feed and Profile tabs. Rows open `CheckinDetailView`.
struct CheckinList<Header: View>: View {
    let model: CheckinListModel
    var showUser = true
    var showActions = false
    var emptyText = "No checkins yet."
    @ViewBuilder var header: () -> Header
    @State private var checkInBeer: BeerLite?
    @State private var editing: Checkin?
    @State private var deleting: Checkin?
    @Environment(DiscoverModel.self) private var discover
    @Environment(AuthStore.self) private var auth

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: model.scrollToTopRequests) { scrollToTop(proxy) }
        }
    }

    private var list: some View {
        List {
            header().id(Self.topID)
            ForEach(model.items) { c in
                let mine = c.isBy(username: auth.username)
                // A zero-opacity link keeps the whole row tappable without List's disclosure chevron.
                ZStack {
                    NavigationLink(value: c) { EmptyView() }.opacity(0)
                    VStack(alignment: .leading, spacing: 0) {
                        CheckinRow(checkin: c, showUser: showUser,
                                   menu: CheckinMenuItems.hasItems(c, isMine: mine) ? { menuItems(c, isMine: mine) } : nil)
                        if showActions {
                            CheckinActions(checkin: c, toast: { Task { await model.toggleToast(c) } })
                        }
                    }
                }
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }  // full-width divider
                .onAppear { model.onAppear(c) }
                .contextMenu { menuItems(c, isMine: mine) }
            }
            footer
        }
        .listStyle(.plain)
        .readableContentWidth()
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
        .navigationDestination(for: Checkin.self) { CheckinDetailView(checkin: $0) }
        .navigationDestination(for: Venue.self) { VenueDetailView(venue: $0) }
        .sheet(item: $checkInBeer) { CheckInSheet(beer: $0, venue: discover.here.first) }
        .sheet(item: $editing) { CheckInSheet(editing: $0) }
        .confirmationDialog("Delete this checkin?", isPresented: isConfirmingDelete,
                            titleVisibility: .visible, presenting: deleting) { c in
            Button("Delete", role: .destructive) { Task { await model.delete(c) } }
        } message: { _ in
            Text("This can't be undone.")
        }
    }

    private func menuItems(_ c: Checkin, isMine: Bool) -> CheckinMenuItems {
        CheckinMenuItems(checkin: c, isMine: isMine,
                         checkIn: { checkInBeer = $0 },
                         edit: { editing = c },
                         delete: { deleting = c })
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
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
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            } else if let e = model.error {
                ErrorRow(message: e) { Task { await model.refresh() } }
            } else {
                Text(emptyText).foregroundStyle(.secondary).frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
        } else if model.isLoadingMore {
            ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
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

/// The toast button under a feed row.
struct CheckinActions: View {
    let checkin: Checkin
    let toast: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toast) {
                HStack(spacing: 4) {
                    Text("🍻")
                    Text(checkin.youToasted ? "Toasted" : "Toast").font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 34)
                .foregroundStyle(checkin.youToasted ? Color.orange : Color.primary)
                .background(checkin.youToasted ? Color.orange.opacity(0.15) : Color(.tertiarySystemFill),
                            in: Capsule())
            }
            .accessibilityLabel(checkin.youToasted ? "Remove toast" : "Toast")

            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)  // keeps taps on the buttons, not the row's navigation link
        .tint(.primary)
        .padding(.bottom, 6)
    }
}

struct ErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Retry", action: retry).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
    }
}

struct FeedView: View {
    let model: CheckinListModel

    var body: some View {
        CheckinList(model: model, showActions: true, emptyText: "Your friends haven't checked in anything yet.")
            .toolbar(.hidden, for: .navigationBar)
    }
}
