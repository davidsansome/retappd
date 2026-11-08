import SwiftUI

/// Shared infinite list used by the Feed and Profile tabs. Rows open `CheckinDetailView`.
struct CheckinList<Header: View>: View {
    let model: CheckinListModel
    var showUser = true
    var showActions = false
    var emptyText = "No checkins yet."
    @ViewBuilder var header: () -> Header
    @State private var checkInBeer: BeerLite?
    @Environment(DiscoverModel.self) private var discover

    var body: some View {
        List {
            header()
            ForEach(model.items) { c in
                // A zero-opacity link keeps the whole row tappable without List's disclosure chevron.
                ZStack {
                    NavigationLink(value: c) { EmptyView() }.opacity(0)
                    VStack(alignment: .leading, spacing: 0) {
                        CheckinRow(checkin: c, showUser: showUser)
                        if showActions {
                            CheckinActions(checkin: c,
                                           toast: { Task { await model.toggleToast(c) } },
                                           checkIn: { checkInBeer = c.beerLite })
                        }
                    }
                }
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }  // full-width divider
                .onAppear { model.onAppear(c) }
                .contextMenu {
                    if let b = c.beerLite {
                        Button("Check in \(b.name)", systemImage: "plus.circle") { checkInBeer = b }
                    }
                }
            }
            footer
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
        .navigationDestination(for: Checkin.self) { CheckinDetailView(checkin: $0) }
        .navigationDestination(for: Venue.self) { VenueDetailView(venue: $0) }
        .sheet(item: $checkInBeer) { CheckInSheet(beer: $0, venue: discover.here.first) }
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

/// Toast and check-in buttons under a feed row.
struct CheckinActions: View {
    let checkin: Checkin
    let toast: () -> Void
    let checkIn: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toast) {
                HStack(spacing: 4) {
                    Text("🍻")
                    Text(checkin.youToasted ? "Toasted" : "Toast").font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(checkin.youToasted ? Color.orange : Color.primary)
                .background(checkin.youToasted ? Color.orange.opacity(0.15) : Color(.tertiarySystemFill),
                            in: Capsule())
            }
            .accessibilityLabel(checkin.youToasted ? "Remove toast" : "Toast")

            Button(action: checkIn) {
                Label("Check in", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .disabled(checkin.beerLite == nil)
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
