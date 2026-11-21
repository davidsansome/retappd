import SwiftUI

/// Detail screen for a Wish List or custom list showing its beers, linking to `BeerView`.
struct CustomListDetailView: View {
    @State private var model: CustomListDetailModel
    @Environment(AuthStore.self) private var auth
    @State private var removeFeedback = 0

    init(list: CustomList, ownerUsername: String) {
        _model = State(initialValue: CustomListDetailModel(list: list, ownerUsername: ownerUsername))
    }

    private var canEdit: Bool {
        if let isOwner = model.list.isOwner { return isOwner }
        return auth.username?.caseInsensitiveCompare(model.ownerUsername) == .orderedSame
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, Taproom.sectionSpacing)

                if model.isLoading && model.items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else if let error = model.error, model.items.isEmpty {
                    ErrorRow(message: error) {
                        Task { await model.refresh() }
                    }
                } else if model.beerItems.isEmpty {
                    ContentUnavailableView(
                        "No beers yet",
                        systemImage: model.list.isWishList ? "bookmark" : "list.bullet",
                        description: Text(canEdit
                            ? "Save beers from any beer page to add them to \(model.list.name)."
                            : "There are no beers in this list yet.")
                    )
                    .padding(.vertical, 32)
                } else {
                    ForEach(model.beerItems) { item in
                        if let beer = item.beer {
                            beerItemRow(item: item, beer: beer)
                                .onAppear {
                                    if item.id == model.beerItems.last?.id, model.hasMore {
                                        Task { await model.loadMore() }
                                    }
                                }
                        }
                    }

                    if model.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .taproomScreen()
        .taproomScrollTitle(model.list.name)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .alert(
            "Couldn't remove beer",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .sensoryFeedback(.success, trigger: removeFeedback)
        .task { await model.loadIfNeeded() }
        .refreshable { await model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(model.list.name)
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.6)
                    .accessibilityAddTraits(.isHeader)
                if !model.list.isPublic {
                    Image(systemName: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(Taproom.muted)
                        .accessibilityLabel("Private list")
                }
            }
            if let desc = model.list.description {
                Text(desc)
                    .font(.subheadline)
                    .foregroundStyle(Taproom.muted)
            }
            Text(listItemCountLabel(model.totalCount))
                .font(.footnote)
                .foregroundStyle(Taproom.muted)
                .contentTransition(.numericText(value: Double(model.totalCount)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beerItemRow(item: CustomListItem, beer: BeerLite) -> some View {
        HStack(spacing: 4) {
            NavigationLink(value: BeerBreweryRoute.beer(beer)) {
                BeerRow(beer: beer, detail: item.detailSummary)
            }
            .buttonStyle(TaproomRowStyle())
            .accessibilityIdentifier("listDetail.beerRow.\(beer.bid)")

            if canEdit {
                Menu {
                    Button(
                        model.list.isWishList ? "Remove from Wish List" : "Remove from list",
                        systemImage: "trash",
                        role: .destructive
                    ) {
                        Task {
                            if await model.remove(item) {
                                removeFeedback += 1
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(Taproom.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Options for \(beer.name)")
                .accessibilityIdentifier("listDetail.removeMenu.\(beer.bid)")
            }
        }
        .taproomRowDivider()
        .contextMenu {
            if canEdit {
                Button(
                    model.list.isWishList ? "Remove from Wish List" : "Remove from list",
                    systemImage: "trash",
                    role: .destructive
                ) {
                    Task {
                        if await model.remove(item) {
                            removeFeedback += 1
                        }
                    }
                }
            }
        }
    }
}
