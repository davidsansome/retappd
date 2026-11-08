import Foundation
import CoreLocation
import Observation

struct FriendActivity: Identifiable, Hashable {
    var venue: Venue
    var checkins: [Checkin]
    var distance: Double?
    var id: String { venue.id }
    var latest: Date { checkins.compactMap(\.createdAt).max() ?? .distantPast }
}

@Observable @MainActor
final class DiscoverModel {
    /// Radius within which a verified venue is assumed to be where the user is.
    static let hereRadius: CLLocationDistance = 50
    /// How far and how recent a friend's checkin must be to count as "nearby now".
    static let friendRadius: CLLocationDistance = 2_000
    static let friendWindow: TimeInterval = 4 * 3600

    private(set) var origin: CLLocation?
    private(set) var here: [Venue] = []
    private(set) var friendsNearby: [FriendActivity] = []
    private(set) var nearby: [Venue] = []
    private(set) var recent: [Venue] = []
    private(set) var isLoading = false
    private(set) var error: String?

    private var around: VenueAround?
    private var map: VenueMap?
    private var pub: [Checkin] = []
    private var feed: [Checkin] = []
    private var lastQueried: CLLocation?
    private var prefetchedMenus = Set<Int>()
    private var isStale = false
    private let username: String

    init(username: String) { self.username = username }

    /// Marks what's nearby as out of date, so it's fetched again when Discover next appears.
    func invalidate() { isStale = true }

    /// Call when Discover appears: refetches if it was invalidated.
    func refreshIfStale(location: CLLocation?) async {
        guard isStale, location != nil else { return }
        isStale = false
        await update(location: location, force: true)
    }

    // MARK: Nearby

    func update(location: CLLocation?, force: Bool = false) async {
        guard let loc = location else { return }
        if !force, let last = lastQueried, last.distance(from: loc) < 20,
           loc.horizontalAccuracy >= last.horizontalAccuracy - 10 {
            return
        }
        lastQueried = loc
        origin = loc
        recompute()  // re-sort what we already have for the new position straight away
        isLoading = true
        defer { isLoading = false }
        let (lat, lng) = (loc.coordinate.latitude, loc.coordinate.longitude)

        // The friends feed is usually already cached by the Feed tab.
        if let f = await cachedValue(.friendFeed(), as: CheckinPage.self) { feed = f.checkins; recompute() }

        async let a: Void = loadAround(lat: lat, lng: lng, loc: loc)
        async let m: Void = loadMap(lat: lat, lng: lng, loc: loc)
        async let p: Void = loadPub(lat: lat, lng: lng)
        _ = await (a, m, p)
    }

    private func loadAround(lat: Double, lng: Double, loc: CLLocation) async {
        do {
            let r = try await cacheThenNetwork(.venuesAround(lat: lat, lng: lng), as: VenueAround.self,
                                               key: "discover.around") { cached in
                // The cache holds the last place we looked; only use it if that's close by.
                if around == nil, let clat = cached.lat, let clng = cached.lng,
                   CLLocation(latitude: clat, longitude: clng).distance(from: loc) < 300 {
                    around = cached
                    recompute()
                }
            }
            around = r
            error = nil
            let all = r.recent + r.nearby
            await LocalIndex.shared.add(venues: all)
            // Learn Untappd ids for Foursquare-only venues from earlier sightings.
            var resolved = r
            resolved.recent = await resolveAll(r.recent)
            resolved.nearby = await resolveAll(r.nearby)
            around = resolved
            recompute()
        } catch {
            if around == nil && map == nil { self.error = error.localizedDescription }
        }
    }

    private func loadMap(lat: Double, lng: Double, loc: CLLocation) async {
        do {
            let r = try await cacheThenNetwork(.venueMap(lat: lat, lng: lng), as: VenueMap.self,
                                               key: "discover.map") { cached in
                if map == nil, let clat = cached.centerLat, let clng = cached.centerLng,
                   CLLocation(latitude: clat, longitude: clng).distance(from: loc) < 300 {
                    map = cached
                    recompute()
                }
            }
            map = r
            error = nil
            recompute()
            await LocalIndex.shared.add(venues: r.venues)
        } catch {
            if map == nil && around == nil { self.error = error.localizedDescription }
        }
    }

    private func loadPub(lat: Double, lng: Double) async {
        if let r = try? await cacheThenNetwork(.thePubLocal(lat: lat, lng: lng), as: CheckinPage.self,
                                               key: "discover.pub", onCached: { pub = $0.checkins; recompute() }) {
            pub = r.checkins
            Task.detached(priority: .utility) { await LocalIndex.shared.add(checkins: r.checkins) }
            recompute()
        }
    }

    private func resolveAll(_ vs: [Venue]) async -> [Venue] {
        var out: [Venue] = []
        for v in vs { out.append(await LocalIndex.shared.resolve(v)) }
        return out
    }

    private func recompute() {
        let loc = origin
        func dist(_ v: Venue) -> Double { v.distance(from: loc) ?? v.reportedDistance ?? .infinity }

        var seen = Set<String>()
        var venues: [Venue] = []
        // Untappd's own venues first, so they win de-duplication over bare Foursquare results.
        // Foursquare-only results are kept only if they look like somewhere to drink.
        let fsqOnly = (around?.nearby ?? []).filter { $0.venueId != nil || $0.looksLikeDrinkingPlace }
        for v in (map?.venues ?? []) + (around?.recent ?? []) + fsqOnly where !v.isCustom {
            let keys = [v.venueId.map { "u\($0)" }, v.foursquareId.map { "f\($0)" }].compactMap { $0 }
            guard !keys.contains(where: seen.contains) else { continue }
            keys.forEach { seen.insert($0) }
            venues.append(v)
        }
        venues.sort { dist($0) < dist($1) }

        here = venues.filter { $0.isVerified && dist($0) <= Self.hereRadius }
        let hereIds = Set(here.map(\.id))

        // Friends checking in nearby, recently. Feed items are all friends; pub items may not be.
        let cutoff = Date.now.addingTimeInterval(-Self.friendWindow)
        var groups: [String: FriendActivity] = [:]
        var seenCheckins = Set<Int>()
        for c in feed + pub.filter({ $0.user?.isFriend == true }) {
            guard c.user?.userName.caseInsensitiveCompare(username) != .orderedSame,
                  seenCheckins.insert(c.id).inserted, let v = c.venue, !v.isCustom,
                  let d = c.createdAt, d > cutoff else { continue }
            let distance = v.distance(from: loc)
            guard let distance, distance <= Self.friendRadius else { continue }
            groups[v.id, default: FriendActivity(venue: v, checkins: [], distance: distance)].checkins.append(c)
        }
        friendsNearby = groups.values
            .map { var g = $0; g.checkins.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }; return g }
            .sorted { $0.latest > $1.latest }

        nearby = venues.filter { !hereIds.contains($0.id) }.prefix(25).map { $0 }
        prefetchMenus(for: here + friendsNearby.prefix(2).map(\.venue))
        recent = (around?.recent ?? []).filter { !$0.isCustom && !hereIds.contains($0.id) }
    }

    /// Warms the response and image caches for venues the user is likely to open next.
    private func prefetchMenus(for venues: [Venue]) {
        for v in venues {
            guard let id = v.venueId, prefetchedMenus.insert(id).inserted else { continue }
            Task.detached(priority: .utility) {
                if v.isVerified, let data = try? await UntappdAPI.shared.data(.venueMenu(id)) {
                    await ResponseCache.shared.store(data, for: APIRequest.venueMenu(id).cacheKey)
                    if let m = try? UntappdAPI.decode(MenuSections.self, from: data) {
                        let beers = m.sections.flatMap { $0.items.compactMap(\.beer) }
                        ImagePipeline.shared.prefetch(beers.compactMap(\.label))
                        await LocalIndex.shared.add(beers: beers)
                    }
                }
                if let data = try? await UntappdAPI.shared.data(.venueCheckins(id)) {
                    await ResponseCache.shared.store(data, for: APIRequest.venueCheckins(id).cacheKey)
                }
            }
        }
    }

    /// Candidate venues for the check-in sheet, best guess first.
    var checkInVenues: [Venue] {
        var out: [Venue] = [.atHome]
        for v in here + friendsNearby.map(\.venue) + nearby where !out.contains(where: { $0.id == v.id }) {
            out.append(v)
        }
        return out.filter { $0.foursquareId != nil }
    }

    // MARK: Search

    private(set) var beerResults: [BeerLite] = []
    private(set) var venueResults: [Venue] = []
    private(set) var isSearching = false

    /// Local results synchronously-ish, then network results (themselves cache-first).
    func search(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { beerResults = []; venueResults = []; return }
        let loc = origin

        let localBeers = await LocalIndex.shared.searchBeers(q)
        let localVenues = await LocalIndex.shared.searchVenues(q, near: loc)
        guard !Task.isCancelled else { return }
        beerResults = localBeers
        venueResults = localVenues

        // Debounce network work while typing; cancelled by the next keystroke.
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        isSearching = true
        defer { isSearching = false }

        async let b: Void = searchBeersRemote(q, local: localBeers)
        async let v: Void = searchVenuesRemote(q, loc: loc, local: localVenues)
        _ = await (b, v)
    }

    private func searchBeersRemote(_ q: String, local: [BeerLite]) async {
        // Algolia also matches aliases and collaborators, so results that literally contain every
        // query word in their name or brewery go first (stable, so Algolia's order breaks ties).
        let merge = { (remote: [BeerLite]) -> [BeerLite] in
            let ids = Set(remote.map(\.bid))
            let all = remote + local.filter { !ids.contains($0.bid) }
            let direct = all.filter { LocalIndex.matches(query: q, text: "\($0.name) \($0.brewery)") }
            let directIds = Set(direct.map(\.bid))
            return direct + all.filter { !directIds.contains($0.bid) }
        }
        do {
            let r = try await cacheThenNetwork(
                key: Algolia.cacheKey(beerQuery: q),
                decode: { try JSONDecoder().decode(AlgoliaBeerHits.self, from: $0).hits },
                fetch: { try await Algolia.searchBeers(q) },
                onCached: { if !Task.isCancelled { beerResults = merge($0) } })
            guard !Task.isCancelled else { return }
            beerResults = merge(r)
            await LocalIndex.shared.add(beers: r)
        } catch {}
    }

    private func searchVenuesRemote(_ q: String, loc: CLLocation?, local: [Venue]) async {
        guard let loc else { return }
        let merge = { (remote: [Venue]) -> [Venue] in
            let keys = Set(remote.map { $0.foursquareId ?? $0.id })
            return remote + local.filter { !keys.contains($0.foursquareId ?? $0.id) }
        }
        // Round the cache key's location (~1km) so nearby repeat searches hit it.
        let key = String(format: "venue.search %@ %.2f,%.2f", LocalIndex.normalize(q),
                         loc.coordinate.latitude, loc.coordinate.longitude)
        do {
            let r = try await cacheThenNetwork(
                .venuesAround(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, query: q),
                as: VenueAround.self, key: key,
                onCached: { c in if !Task.isCancelled { venueResults = merge((c.recent.filter { LocalIndex.matches(query: q, text: $0.name) } + c.nearby).filter { !$0.isCustom }) } })
            guard !Task.isCancelled else { return }
            let all = await resolveAll((r.recent.filter { LocalIndex.matches(query: q, text: $0.name) } + r.nearby).filter { !$0.isCustom })
            venueResults = merge(all)
            await LocalIndex.shared.add(venues: all)
        } catch {}
    }
}
