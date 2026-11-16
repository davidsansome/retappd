import SwiftUI

/// Loads Metabeer's shop prices for a beer into `offers`, when shop prices are turned on in
/// Settings. Leaves it nil while off, on failure, and when no shop has the beer, so callers show
/// nothing rather than an error: prices are extra, never in the way.
private struct LoadShopPrices: ViewModifier {
    let beerID: Int?
    @Binding var offers: MetabeerOffers?
    @AppStorage(MetabeerSettings.enabledKey) private var enabled = false
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

/// "From $6.40 each · 4 shops": the cheapest can or bottle of a beer in the shops Metabeer
/// tracks. Opens the shops and their prices.
struct ShopPriceChip: View {
    let offers: MetabeerOffers
    let beerName: String
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "tag").foregroundStyle(Taproom.amber)
                if let each = offers.cheapestEach {
                    (Text("From ") + Text(offers.money(each)).fontWeight(.semibold) + Text(" each")).lineLimit(1)
                }
                Text("· \(offers.shopCount) \(offers.shopCount == 1 ? "shop" : "shops")")
                    .foregroundStyle(Taproom.muted).lineLimit(1)
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(Taproom.muted)
            }
        }
        .buttonStyle(TaproomChip(on: false))
        .accessibilityHint("Shows the shops selling this beer and their prices")
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
                            ForEach(offers.offers) { o in
                                Button { openURL(o.productUrl) } label: { OfferRow(offer: o, offers: offers) }
                                    .buttonStyle(TaproomRowStyle())
                                    .taproomRowDivider()
                                    .accessibilityHint("Opens the shop's page")
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prices and stock come from Metabeer, which checks shops every night. Prices are before shipping.")
                            .font(.caption).foregroundStyle(Taproom.muted)
                        if let url = offers.metabeerUrl {
                            Link(destination: url) {
                                Label("Price history on Metabeer", systemImage: "arrow.up.right")
                                    .labelStyle(TaproomTrailingIconLabel())
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Taproom.ink)
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
                    Button("Close", systemImage: "xmark") { dismiss() }.tint(Taproom.ink)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.shop).font(.body.weight(.semibold)).lineLimit(1)
                let pack = [offer.packDescription, offer.packSize > 1 ? "\(offers.money(offer.price)) the pack" : nil]
                    .compactMap { $0 }.joined(separator: " · ")
                if !pack.isEmpty { Text(pack).font(.footnote).foregroundStyle(Taproom.muted).lineLimit(1) }
            }
            Spacer(minLength: 4)
            // What shops compare on: one can or bottle, so a 4-pack sits fairly beside a single.
            VStack(alignment: .trailing, spacing: 0) {
                Text(offers.money(offer.unitPrice)).font(.headline.weight(.heavy).monospacedDigit())
                if offer.packSize > 1 { Text("each").font(.caption2).foregroundStyle(Taproom.muted) }
            }
            Image(systemName: "arrow.up.right").imageScale(.small).foregroundStyle(Taproom.muted)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Taproom.ink)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
    }
}
