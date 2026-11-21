import SwiftUI

/// Sheet opened from a beer's page to toggle its Wishlist status or add/remove it from custom lists.
struct BeerListsSheet: View {
    @State private var model: BeerListsSheetModel
    var onWishlistChange: (Bool) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var toggleFeedback = 0

    init(beer: BeerLite, username: String, onWishlistChange: @escaping (Bool) -> Void = { _ in }) {
        _model = State(initialValue: BeerListsSheetModel(beer: beer, username: username))
        self.onWishlistChange = onWishlistChange
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                    beerHeader

                    if model.isLoading && model.lists.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    } else if let error = model.error, model.lists.isEmpty {
                        ErrorRow(message: error) {
                            Task { await model.load() }
                        }
                    } else if model.lists.isEmpty {
                        ContentUnavailableView(
                            "No lists yet",
                            systemImage: "bookmark",
                            description: Text("Your Wish List and custom lists will appear here.")
                        )
                        .padding(.vertical, 24)
                    } else {
                        TaproomSection("Your lists") {
                            VStack(spacing: 10) {
                                ForEach(model.lists) { list in
                                    listRow(list)
                                }
                            }
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
            .navigationTitle("Save to list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Taproom.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundStyle(Taproom.ink)
                    .accessibilityLabel("Done")
                    .accessibilityIdentifier("beerLists.closeButton")
                }
            }
            .alert(
                "Couldn't update list",
                isPresented: Binding(
                    get: { model.mutationError != nil },
                    set: { if !$0 { model.mutationError = nil } }
                )
            ) {
                Button("OK") { model.mutationError = nil }
            } message: {
                Text(model.mutationError ?? "")
            }
            .sensoryFeedback(.selection, trigger: toggleFeedback)
            .task {
                await model.load()
                if let inWishlist = model.isInWishlist {
                    onWishlistChange(inWishlist)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var beerHeader: some View {
        HStack(spacing: 12) {
            BeerLabel(beer: model.beer.label, brewery: model.beer.breweryLabel, size: 44, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.beer.name)
                    .font(.headline.weight(.heavy))
                    .lineLimit(2)
                if !model.beer.brewery.isEmpty {
                    Text(model.beer.brewery)
                        .font(.footnote)
                        .foregroundStyle(Taproom.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .taproomCard()
    }

    private func listRow(_ list: CustomList) -> some View {
        let isOn = list.isInList == true
        let isBusy = model.inFlightIDs.contains(list.id)
        return Button {
            Task {
                if await model.toggle(list) {
                    toggleFeedback += 1
                    if list.isWishList, let inWishlist = model.isInWishlist {
                        onWishlistChange(inWishlist)
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isOn ? Taproom.amber : Taproom.glassInside)
                    Image(systemName: list.isWishList ? (isOn ? "bookmark.fill" : "bookmark") : "list.bullet")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isOn ? Taproom.onAmber : Taproom.amber)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(list.name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        if !list.isPublic {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(Taproom.muted)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(listItemCountLabel(list.totalItemCount))
                        .font(.footnote)
                        .foregroundStyle(Taproom.muted)
                        .contentTransition(.numericText(value: Double(list.totalItemCount)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isBusy {
                    ProgressView()
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "plus.circle")
                        .font(.title3)
                        .foregroundStyle(isOn ? Taproom.amber : Taproom.muted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 64)
            .background(Taproom.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isOn ? Taproom.amber : Taproom.border, lineWidth: isOn ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(CardLinkStyle())
        .disabled(isBusy)
        .accessibilityIdentifier(list.isWishList ? "beerLists.wishlistRow" : "beerLists.row.\(list.id)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityValue(isOn ? "Saved" : "Not saved")
        .accessibilityHint(isOn ? "Removes this beer from \(list.name)" : "Adds this beer to \(list.name)")
    }
}

func listItemCountLabel(_ count: Int) -> String {
    count == 1 ? "1 item" : "\(count.formatted()) items"
}
