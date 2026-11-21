import SwiftUI

/// Loads Metabeer's shop prices for a beer into `offers`, when shop prices are turned on in
/// Settings. Leaves it nil while off, on failure, and when no shop has the beer, so callers show
/// nothing rather than an error: prices are extra, never in the way.
private struct LoadShopPrices: ViewModifier {
    let beerID: Int?
    @Binding var offers: MetabeerOffers?
    @AppStorage(MetabeerSettings.enabledKey) private var enabled = MetabeerSettings.defaultEnabled
    @AppStorage(MetabeerSettings.marketKey) private var market = MetabeerMarket.local

    func body(content: Content) -> some View {
        content.task(id: "\(enabled) \(beerID ?? 0) \(market.rawValue)") {
            guard enabled, let beerID else { offers = nil; return }
            let found = try? await Metabeer.shared.offers(beerID: beerID, market: market)
            guard !Task.isCancelled else { return }
            offers = found?.offers.isEmpty == false ? found : nil
        }
    }
}

extension View {
    func loadingShopPrices(beerID: Int?, into offers: Binding<MetabeerOffers?>) -> some View {
        modifier(LoadShopPrices(beerID: beerID, offers: offers))
    }
}

/// Outcome of a manual pull-to-refresh of Metabeer shop prices.
enum ShopPricesRefresh {
    /// Server answered cleanly (nil means disabled or now out of stock).
    case updated(MetabeerOffers?)
    /// Request failed or was cancelled; keep whatever was already shown.
    case unchanged
}

/// Refreshes Metabeer shop prices directly (bypassing the cache) when enabled in Settings.
/// Use from `.refreshable` so pull-to-refresh gets fresh prices too.
@MainActor
func refreshShopPrices(beerID: Int?) async -> ShopPricesRefresh {
    guard MetabeerSettings.isEnabled, let beerID else { return .updated(nil) }
    do {
        let found = try await Metabeer.shared.offers(beerID: beerID, market: MetabeerSettings.market, force: true)
        return .updated(found.offers.isEmpty ? nil : found)
    } catch {
        return .unchanged
    }
}

/// "From $6.40 each · 4 shops": the cheapest can or bottle of a beer in the shops Metabeer
/// tracks. Opens the shops and their prices.
struct ShopPriceChip: View {
    let offers: MetabeerOffers
    let beerName: String
    @State private var showing = false

    private var chipText: Text {
        let shops = Text("· \(offers.shopCount) \(offers.shopCount == 1 ? "shop" : "shops")")
            .foregroundStyle(Taproom.muted)
        if let each = offers.cheapestEach {
            return Text("From ") + Text(offers.money(each)).fontWeight(.semibold) + Text(" each ") + shops
        }
        return shops
    }

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag").foregroundStyle(Taproom.amber)
                    .accessibilityHidden(true)
                chipText
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(Taproom.muted)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(TaproomChip(on: false))
        .accessibilityHint("Shows the shops selling this beer and their prices")
        .accessibilityIdentifier("ShopPrices.chip")
        .sheet(isPresented: $showing) { ShopPricesSheet(offers: offers, beerName: beerName) }
    }
}

/// Every shop with the beer in stock, cheapest per can or bottle first. A row opens the shop's
/// page for the product.
struct ShopPricesSheet: View {
    let offers: MetabeerOffers
    let beerName: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(beerName)
                            .font(.system(size: 26, weight: .heavy))
                            .tracking(-0.4)
                            .lineLimit(3)
                            .minimumScaleFactor(0.7)
                        Text("In stock at \(offers.shopCount) \(offers.shopCount == 1 ? "shop" : "shops")")
                            .font(.subheadline).foregroundStyle(Taproom.muted)
                    }
                    TaproomSection("Cheapest each first") {
                        VStack(spacing: 0) {
                            ForEach(offers.sortedOffers) { o in
                                Button {
                                    if o.productUrl.isHTTP { openURL(o.productUrl) }
                                } label: {
                                    OfferRow(offer: o, offers: offers)
                                }
                                .buttonStyle(TaproomRowStyle())
                                .taproomRowDivider()
                                .accessibilityHint("Opens the shop's page")
                                .accessibilityIdentifier("ShopPrices.row.\(o.listingId)")
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prices and stock come from Metabeer, which checks shops every night. Prices are before shipping.")
                            .font(.caption).foregroundStyle(Taproom.muted)
                        if let url = offers.metabeerUrl, url.isHTTP {
                            Link(destination: url) {
                                Label("Price history on Metabeer", systemImage: "arrow.up.right")
                                    .labelStyle(TaproomTrailingIconLabel())
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Taproom.ink)
                            .accessibilityIdentifier("ShopPrices.historyLink")
                        }
                    }
                }
                .padding(.horizontal, Taproom.margin)
                .padding(.vertical, 8)
                .frame(maxWidth: .readableContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .taproomScreen()
            .navigationTitle("Shop prices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Taproom.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .tint(Taproom.ink)
                        .accessibilityIdentifier("ShopPrices.close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Taproom.background)
    }
}

private struct OfferRow: View {
    let offer: MetabeerOffer
    let offers: MetabeerOffers
    @Environment(\.dynamicTypeSize) private var typeSize

    private var packLine: String {
        [offer.packDescription, offer.packSize > 1 ? "\(offers.money(offer.price)) the pack" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var unitDetail: String? {
        let parts = [
            offer.packSize > 1 ? "each" : nil,
            offer.pricePerLitre.map { "\(offers.money($0))/L" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        shopInfo
                        Spacer(minLength: 4)
                        externalIcon
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(offers.money(offer.unitPrice)).font(.headline.weight(.heavy).monospacedDigit())
                        if let unitDetail {
                            Text(unitDetail).font(.caption).foregroundStyle(Taproom.muted).monospacedDigit()
                        }
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    shopInfo
                    Spacer(minLength: 4)
                    // What shops compare on: one can or bottle, so a 4-pack sits fairly beside a single.
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(offers.money(offer.unitPrice)).font(.headline.weight(.heavy).monospacedDigit())
                        if let unitDetail {
                            Text(unitDetail).font(.caption2).foregroundStyle(Taproom.muted).monospacedDigit()
                        }
                    }
                    externalIcon
                }
            }
        }
        .foregroundStyle(Taproom.ink)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
    }

    private var shopInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(offer.shop).font(.body.weight(.semibold)).lineLimit(2)
            if !packLine.isEmpty {
                Text(packLine).font(.footnote).foregroundStyle(Taproom.muted).lineLimit(2)
            }
        }
    }

    private var externalIcon: some View {
        Image(systemName: "arrow.up.right").imageScale(.small).foregroundStyle(Taproom.muted)
            .accessibilityHidden(true)
    }
}
