import SwiftUI

/// Discover's "To check in" list: check-ins saved for later while offline, always shown while
/// there are any, so you decide when the connection is good enough to finish them. (The
/// connection proof only gates the background "back online" notification.)
struct ToCheckInSection: View {
    /// Finish this saved check-in (it has a beer).
    var onCheckIn: (PendingCheckin) -> Void
    /// Search for this saved search's beer.
    var onFind: (PendingCheckin) -> Void
    @State private var pending = PendingCheckins.shared
    @State private var connectivity = Connectivity.shared

    private var items: [PendingCheckin] { pending.items }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("To check in").font(Taproom.sectionLabel)
                    TaproomCountBadge(count: items.count)
                }
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item)
                        if item.id != items.last?.id {
                            Rectangle().fill(Taproom.border).frame(height: 1)
                        }
                    }
                }
                .taproomCard()
                Text(connectivity.offlineMode
                     ? "Offline mode is on. Turn it off to check these in."
                     : "Check-ins post at the time you finish them. Ones more than an hour late start “LCI”.")
                    .font(.caption).foregroundStyle(Taproom.muted)
            }
        }
    }

    private func row(_ item: PendingCheckin) -> some View {
        HStack(spacing: 12) {
            if let beer = item.beer {
                BeerLabel(beer: beer.label, brewery: beer.breweryLabel, size: 44, cornerRadius: 8)
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Taproom.muted)
                    .frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Taproom.glassRim, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(detail(item)).font(.footnote).foregroundStyle(Taproom.muted).lineLimit(1)
                Text(when(item)).font(.caption).foregroundStyle(Taproom.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.beer != nil {
                Button("Check in") { onCheckIn(item) }
                    .buttonStyle(TaproomPrimaryButton(fullWidth: false, compact: true))
                    .disabled(connectivity.offlineMode)
            } else {
                Button("Find") { onFind(item) }
                    .buttonStyle(TaproomOutlineButton())
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Remove from list", systemImage: "trash", role: .destructive) {
                withAnimation { pending.remove(item.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Remove from list") { pending.remove(item.id) }
    }

    private func detail(_ item: PendingCheckin) -> String {
        guard let beer = item.beer else { return "Search only, no beer picked" }
        var parts = [beer.brewery]
        if item.rating > 0 { parts.append(GlassRating.format(item.rating, step: 0.25)) }
        if let s = item.servingName { parts.append(s) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func when(_ item: PendingCheckin) -> String {
        let time = item.savedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        if let v = item.venue { return "\(time) · \(v.name)" }
        return time
    }
}
