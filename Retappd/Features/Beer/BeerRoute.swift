import SwiftUI

/// What a brewery link carries, so the page can show its name and logo before the full record
/// loads.
struct BreweryPreview: Hashable {
    var id: Int
    var name: String
    var label: URL?
}

/// Where a beer or brewery link goes. Push one with `NavigationLink(value:)` from any
/// `NavigationStack` that has `.beerAndBreweryDestinations()` on its content.
enum BeerBreweryRoute: Hashable {
    case beer(BeerLite, venue: Venue? = nil)
    /// Which friends have had a beer, with their ratings and each of their check-ins.
    case friendRatings(BeerLite)
    case brewery(BreweryPreview)
    case badge(Checkin.Badge)
    case userLists(username: String, displayName: String?)
    case customList(CustomList, ownerUsername: String)

    /// The route to a badge's page; nil when its `badge_id` isn't known (the status request needs it).
    static func badge(of badge: Checkin.Badge) -> BeerBreweryRoute? {
        badge.badgeId == nil ? nil : .badge(badge)
    }

    static func brewery(id: Int, name: String, label: URL? = nil) -> BeerBreweryRoute {
        .brewery(BreweryPreview(id: id, name: name, label: label))
    }

    /// The route to the brewery of a beer, when we know its id.
    static func brewery(of beer: BeerLite) -> BeerBreweryRoute? {
        beer.breweryId.map { .brewery(id: $0, name: beer.brewery, label: beer.breweryLabel) }
    }
}

/// Where a profile collection link goes (unique beers, badges, venues). Works from both the
/// signed-in user's Profile tab and any other user's profile pushed onto any tab's stack.
enum ProfileCollectionRoute: Hashable {
    case uniqueBeers(username: String, displayName: String, isOwnProfile: Bool)
    case badges(username: String, displayName: String, isOwnProfile: Bool)
    case venues(username: String, displayName: String, isOwnProfile: Bool)
}

extension View {
    /// Makes `BeerBreweryRoute` and `ProfileCollectionRoute` links push their pages. Put it once on
    /// the root of each `NavigationStack`; SwiftUI ignores (and warns about) repeats further up a stack.
    func beerAndBreweryDestinations() -> some View {
        navigationDestination(for: BeerBreweryRoute.self) { route in
            switch route {
            case .beer(let beer, let venue): BeerView(beer: beer, venue: venue)
            case .friendRatings(let beer): FriendRatingsView(beer: beer)
            case .brewery(let brewery): BreweryView(brewery: brewery)
            case .badge(let badge): BadgeView(badge: badge)
            case .userLists(let username, let displayName): UserListsView(username: username, displayName: displayName)
            case .customList(let list, let ownerUsername): CustomListDetailView(list: list, ownerUsername: ownerUsername)
            }
        }
        .navigationDestination(for: ProfileCollectionRoute.self) { route in
            switch route {
            case .uniqueBeers(let username, let displayName, let isOwnProfile):
                UserBeersView(username: username, displayName: displayName, isOwnProfile: isOwnProfile)
            case .badges(let username, let displayName, let isOwnProfile):
                UserBadgesView(username: username, displayName: displayName, isOwnProfile: isOwnProfile)
            case .venues(let username, let displayName, let isOwnProfile):
                UserVenuesView(username: username, displayName: displayName, isOwnProfile: isOwnProfile)
            }
        }
    }
}

private struct BeerPageCanCheckInKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the Beer page offers "Check in". Off inside the check-in sheet, where it would
    /// open a check-in on top of the one being made.
    var beerPageCanCheckIn: Bool {
        get { self[BeerPageCanCheckInKey.self] }
        set { self[BeerPageCanCheckInKey.self] = newValue }
    }
}

/// A paragraph that shows a few lines and expands on tap; short ones just show in full.
struct ExpandableText: View {
    let text: String
    var lines = 4
    @State private var expanded = false

    private var isLong: Bool { text.count > 40 * lines || text.filter(\.isNewline).count >= lines }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.callout)
                .lineLimit(expanded ? nil : lines)
                .textSelection(.enabled)
            if isLong {
                Button(expanded ? "Less" : "More") { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Taproom.ink)
                    .frame(minHeight: 32, alignment: .leading)
                    .accessibilityHint(expanded ? "Shows less of the description" : "Shows the whole description")
            }
        }
    }
}
