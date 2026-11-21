import SwiftUI

/// Overview of a user's Wish List and custom lists, pushed from `ProfileView`.
struct UserListsView: View {
    let username: String
    /// Nil when viewing your own lists.
    var displayName: String? = nil
    @State private var model: UserListsModel

    init(username: String, displayName: String? = nil) {
        self.username = username
        self.displayName = displayName
        _model = State(initialValue: UserListsModel(username: username))
    }

    private var heading: String {
        if let displayName, !displayName.isEmpty {
            return "\(displayName)'s Lists"
        }
        return "Lists"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text(heading)
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.6)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 4)

                if model.isLoading && model.lists.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else if let error = model.error, model.lists.isEmpty {
                    ErrorRow(message: error) {
                        Task { await model.refresh() }
                    }
                } else if model.lists.isEmpty {
                    ContentUnavailableView(
                        "No lists yet",
                        systemImage: "bookmark",
                        description: Text(displayName == nil
                            ? "Beers you save to your Wish List or custom lists will appear here."
                            : "\(displayName ?? username) doesn't have any public lists.")
                    )
                    .padding(.vertical, 32)
                } else {
                    ForEach(model.lists) { list in
                        NavigationLink(value: BeerBreweryRoute.customList(list, ownerUsername: username)) {
                            listCard(list)
                        }
                        .buttonStyle(CardLinkStyle())
                        .accessibilityIdentifier(list.isWishList ? "lists.wishlistRow" : "lists.row.\(list.id)")
                        .onAppear {
                            if list.id == model.lists.last?.id, model.hasMore {
                                Task { await model.loadMore() }
                            }
                        }
                    }

                    if model.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
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
        .taproomScrollTitle(heading)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task { await model.loadIfNeeded() }
        .refreshable { await model.refresh() }
    }

    private func listCard(_ list: CustomList) -> some View {
        HStack(spacing: 12) {
            listThumbnail(list)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(list.name)
                        .font(.body.weight(.heavy))
                        .lineLimit(1)
                    if !list.isPublic {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(Taproom.muted)
                            .accessibilityLabel("Private")
                    }
                }
                if let desc = list.description {
                    Text(desc)
                        .font(.footnote)
                        .foregroundStyle(Taproom.muted)
                        .lineLimit(2)
                }
                Text(listItemCountLabel(list.totalItemCount))
                    .font(.footnote)
                    .foregroundStyle(Taproom.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Taproom.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 72)
        .taproomCard()
    }

    @ViewBuilder
    private func listThumbnail(_ list: CustomList) -> some View {
        if let url = list.previewLabels.first(where: { !BeerLabel.isPlaceholder($0) }) {
            CachedImage(url: url, maxPixel: 144) {
                fallbackThumbnail(isWishList: list.isWishList)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if list.isWishList {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Taproom.onAmber)
                        .padding(4)
                        .background(Taproom.amber, in: Circle())
                        .offset(x: 4, y: 4)
                }
            }
        } else {
            fallbackThumbnail(isWishList: list.isWishList)
                .frame(width: 48, height: 48)
        }
    }

    private func fallbackThumbnail(isWishList: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isWishList ? Taproom.amber.opacity(0.18) : Taproom.glassInside)
            Image(systemName: isWishList ? "bookmark.fill" : "list.bullet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Taproom.amber)
        }
    }
}
