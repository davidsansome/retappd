import SwiftUI

/// Discover's "To check in" list: check-ins saved for later while offline. The rows to finish them
/// appear only once offline mode is off and real Untappd responses have proven the connection
/// good (`Connectivity.prove`), so a flaky signal doesn't put you in front of a check-in that
/// fails. Turning offline mode off yourself counts as that proof (`Connectivity.userWentOnline`).
/// Until then it shows how many are waiting, and why.
struct ToCheckInSection: View {
    /// Finish this saved check-in (it has a beer).
    var onCheckIn: (PendingCheckin) -> Void
    /// Search for this saved search's beer.
    var onFind: (PendingCheckin) -> Void
    @State private var pending = PendingCheckins.shared
    @State private var connectivity = Connectivity.shared
    @State private var proven = false

    private var items: [PendingCheckin] { pending.items }

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("To check in").font(Taproom.sectionLabel)
                        TaproomCountBadge(count: items.count)
                    }
                    if connectivity.offlineMode || !(proven || connectivity.userWentOnline) {
                        waiting
                    } else {
                        list
                    }
                }
            }
        }
        .task(id: ProofKey(waiting: !items.isEmpty, offline: connectivity.offlineMode)) { await waitForProof() }
    }

    /// Before the connection is proven: say why the list isn't offered yet, so switching back
    /// online doesn't look like it did nothing.
    private var waiting: some View {
        HStack(spacing: 10) {
            if connectivity.offlineMode {
                Image(systemName: "wifi.slash").foregroundStyle(Taproom.muted).accessibilityHidden(true)
                Text("Saved for when you're back online. Turn offline mode off to finish them.")
            } else {
                ProgressView().controlSize(.small)
                Text("Checking your connection is steady before you finish these. This takes about a minute.")
            }
            Spacer(minLength: 0)
        }
        .font(.footnote).foregroundStyle(Taproom.muted)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taproomCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var list: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                row(item)
                if item.id != items.last?.id {
                    Rectangle().fill(Taproom.border).frame(height: 1)
                }
            }
        }
        .taproomCard()
        Text("Check-ins post at the time you finish them. Ones more than an hour late start “LCI”.")
            .font(.caption).foregroundStyle(Taproom.muted)
    }

    private struct ProofKey: Equatable {
        var waiting: Bool
        var offline: Bool
    }

    /// Proves the connection, trying again every so often while it isn't good.
    private func waitForProof() async {
        proven = false
        guard !items.isEmpty, !connectivity.offlineMode else { return }
        while !Task.isCancelled {
            if await connectivity.prove(.foreground) {
                withAnimation { proven = true }
                return
            }
            try? await Task.sleep(for: .seconds(30))
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
