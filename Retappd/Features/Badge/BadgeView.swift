import SwiftUI

@Observable @MainActor
final class BadgeModel {
    let badge: Checkin.Badge
    /// The user's level on the badge; nil when they don't have it (or until it loads).
    private(set) var status: BadgeStatusList.Status?
    private(set) var loaded = false
    private(set) var loadError: String?
    private var firstLoad: Task<Void, Never>?

    init(badge: Checkin.Badge) { self.badge = badge }

    func load(force: Bool = false) async {
        if force {
            await fetch()
            return
        }
        // The first load runs in a task of its own, so leaving the page part way through doesn't
        // leave it half loaded when it's shown again.
        if firstLoad == nil { firstLoad = Task { await fetch() } }
        await firstLoad?.value
    }

    private func fetch() async {
        guard let id = badge.badgeId else {
            loaded = true
            return
        }
        let apply = { (l: BadgeStatusList) in
            self.status = l.statuses[id]
            self.loaded = true
        }
        do {
            apply(try await cacheThenNetwork(.badgeStatus([id]), as: BadgeStatusList.self, onCached: apply))
            loadError = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code != .cancelled { loadError = error.localizedDescription }
        }
    }
}

/// A badge's page: its picture, name and description, and the signed-in user's level on it.
/// Reached from every badge in the app with a `BeerBreweryRoute.badge`.
///
/// Not built yet: a "Friends" section with the level each friend has reached. The API docs don't
/// cover whatever the official app calls for that (`/v5/badges/status` only answers for the
/// signed-in user), so it waits on captured traffic. It belongs after `youCard` in `body`.
struct BadgeView: View {
    @State private var model: BadgeModel
    @ScaledMetric private var imageSize: CGFloat = 160

    init(badge: Checkin.Badge) { _model = State(initialValue: BadgeModel(badge: badge)) }

    private var badge: Checkin.Badge { model.badge }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                hero
                youCard
                if let e = model.loadError, !model.loaded {
                    ErrorRow(message: e) { Task { await model.load(force: true) } }
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Taproom.ink)
        .background(Taproom.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task { await model.load() }
        .refreshable { await model.load(force: true) }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            CachedImage(url: badge.largeImage ?? badge.image, maxPixel: 480)
                .frame(width: imageSize, height: imageSize)
                .clipShape(Circle())
                .overlay(Circle().stroke(Taproom.border, lineWidth: 1))
                .accessibilityHidden(true)
            Text(badge.name)
                .font(.system(size: 28, weight: .heavy))
                .tracking(-0.5)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if let d = badge.description {
                Text(d).font(.callout).foregroundStyle(Taproom.muted)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: You

    private var youCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You").font(.caption.weight(.semibold)).foregroundStyle(Taproom.muted)
            if let s = model.status {
                Text("Level \(s.level.formatted())")
                    .font(.system(size: 44, weight: .heavy).monospacedDigit())
                    .tracking(-1)
                // `total` is at least `level` in every sample (152 of 155, 495 of 495). We read it
                // as the count that earns levels (for example check-ins counted) and `level` as the
                // tier reached, so when they differ the gap is progress towards the next level.
                if s.total != s.level {
                    Text("\(s.level.formatted()) of \(s.total.formatted())")
                        .font(.footnote).foregroundStyle(Taproom.muted)
                }
            } else if model.loaded {
                Text("Not earned yet")
                    .font(.system(size: 26, weight: .heavy)).tracking(-0.4)
                    .foregroundStyle(Taproom.glassRim)
            } else if model.loadError == nil {
                ProgressView().frame(minHeight: 44, alignment: .leading)
            } else {
                Text("Couldn't load").font(.system(size: 26, weight: .heavy)).tracking(-0.4)
                    .foregroundStyle(Taproom.glassRim)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taproomCard()
        .accessibilityElement(children: .combine)
    }
}
