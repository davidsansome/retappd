import Foundation
import CoreLocation

/// Every beer and venue the app has ever seen (feeds, menus, searches), persisted and
/// searchable offline. Gives instant results for any query, before the network replies.
actor LocalIndex {
    static let shared = LocalIndex()

    private struct BeerEntry: Codable {
        var beer: BeerLite
        var seen: Int
        var words: [String]
    }
    private struct VenueEntry: Codable {
        var venue: Venue
        var seen: Int
        var words: [String]
    }
    private struct Snapshot: Codable {
        var beers: [BeerEntry]
        var venues: [VenueEntry]
    }

    private var beers: [Int: BeerEntry] = [:]
    private var venues: [String: VenueEntry] = [:]
    private var venueIdByFoursquare: [String: Int] = [:]
    private var loaded = false
    private var saveTask: Task<Void, Never>?
    private let url: URL

    init(url: URL? = nil) {
        let dir: URL
        #if DEBUG
        if ScreenshotDemo.isEnabled {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("retappd-demo-localindex", isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        }
        #else
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = url ?? dir.appendingPathComponent("local-index.json")
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func words(_ s: String) -> [String] {
        normalize(s).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let d = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: d) else { return }
        for b in snap.beers { beers[b.beer.bid] = b }
        for v in snap.venues {
            venues[v.venue.id] = v
            if let f = v.venue.foursquareId, let id = v.venue.venueId { venueIdByFoursquare[f] = id }
        }
    }

    func warmUp() { loadIfNeeded() }

    // MARK: Ingest

    /// Beers the signed-in user is known to have had. Algolia's public index can't say, so
    /// search results borrow this from what feeds, menus and barcodes have told us.
    func hadBeerIds() -> Set<Int> {
        loadIfNeeded()
        return Set(beers.values.filter { $0.beer.hasHad == true }.map(\.beer.bid))
    }

    func add(beers new: [BeerLite]) {
        loadIfNeeded()
        for b in new where b.bid > 0 && !b.name.isEmpty {
            if var e = beers[b.bid] {
                let oldName = e.beer.name, oldBrewery = e.beer.brewery
                // Keep the richest version of each field.
                e.beer = BeerLite(bid: b.bid, name: b.name, brewery: b.brewery.isEmpty ? e.beer.brewery : b.brewery,
                                  style: b.style ?? e.beer.style, abv: b.abv ?? e.beer.abv, label: b.label ?? e.beer.label,
                                  rating: b.rating ?? e.beer.rating, ratingCount: b.ratingCount ?? e.beer.ratingCount,
                                  popularity: b.popularity ?? e.beer.popularity,
                                  // Once had, always had; Algolia hits say nothing (nil), and an older
                                  // "false" mustn't outlive a later check-in. Only a fallback now: once
                                  // `HadBeers` has synced the full list it decides what shows a tick.
                                  hasHad: (b.hasHad == true || e.beer.hasHad == true) ? true : (b.hasHad ?? e.beer.hasHad),
                                  breweryLabel: b.breweryLabel ?? e.beer.breweryLabel,
                                  breweryId: b.breweryId ?? e.beer.breweryId)
                if e.beer.name != oldName || e.beer.brewery != oldBrewery {
                    e.words = Self.words("\(e.beer.name) \(e.beer.brewery)")
                }
                e.seen += 1
                beers[b.bid] = e
            } else {
                beers[b.bid] = BeerEntry(beer: b, seen: 1, words: Self.words("\(b.name) \(b.brewery)"))
            }
        }
        scheduleSave()
    }

    func add(venues new: [Venue]) {
        loadIfNeeded()
        for var v in new where !v.name.isEmpty && !v.isCustom {
            if let f = v.foursquareId {
                if let id = v.venueId { venueIdByFoursquare[f] = id } else { v.venueId = venueIdByFoursquare[f] }
                // A Foursquare-only entry may already exist under its fsq key; fold it in.
                if v.venueId != nil, let old = venues.removeValue(forKey: "f\(f)") { v.merge(old.venue) }
            }
            if var e = venues[v.id] {
                let oldName = e.venue.name, oldCity = e.venue.city
                v.merge(e.venue)
                e.venue = v
                if e.venue.name != oldName || e.venue.city != oldCity {
                    e.words = Self.words("\(e.venue.name) \(e.venue.city ?? "")")
                }
                e.seen += 1
                venues[v.id] = e
            } else {
                venues[v.id] = VenueEntry(venue: v, seen: 1, words: Self.words("\(v.name) \(v.city ?? "")"))
            }
        }
        scheduleSave()
    }

    func add(checkins: [Checkin]) {
        add(beers: checkins.compactMap(\.beerLite))
        add(venues: checkins.compactMap(\.venue))
    }

    /// Fills in a missing Untappd venue id from any other sighting of the same place.
    func resolve(_ v: Venue) -> Venue {
        loadIfNeeded()
        var v = v
        if v.venueId == nil, let f = v.foursquareId { v.venueId = venueIdByFoursquare[f] }
        if let e = venues[v.id] { v.merge(e.venue) }
        return v
    }

    // MARK: Search

    static func matches(query: String, text: String) -> Bool {
        let q = words(query)
        return !q.isEmpty && matches(q, words(text))
    }

    private static func matches(_ q: [String], _ words: [String]) -> Bool {
        q.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
    }

    func searchBeers(_ query: String, limit: Int = 30) -> [BeerLite] {
        loadIfNeeded()
        let q = Self.words(query)
        guard !q.isEmpty else { return [] }
        return beers.values
            .filter { Self.matches(q, $0.words) }
            .map { e -> (BeerLite, Double) in
                var score = log(Double((e.beer.popularity ?? e.beer.ratingCount ?? 0) + 1)) + Double(e.seen) * 2
                if let first = e.words.first, first.hasPrefix(q[0]) { score += 5 }
                return (e.beer, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit).map(\.0)
    }

    func searchVenues(_ query: String, near loc: CLLocation?, limit: Int = 20) -> [Venue] {
        loadIfNeeded()
        let q = Self.words(query)
        guard !q.isEmpty else { return [] }
        return venues.values
            .filter { Self.matches(q, $0.words) }
            .sorted { a, b in
                let da = a.venue.distance(from: loc) ?? .infinity, db = b.venue.distance(from: loc) ?? .infinity
                return da != db ? da < db : a.seen > b.seen
            }
            .prefix(limit).map(\.venue)
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        let snap = Snapshot(beers: Array(beers.values), venues: Array(venues.values))
        if let d = try? JSONEncoder().encode(snap) { try? d.write(to: url, options: .atomic) }
    }

    func removeAll() {
        saveTask?.cancel()
        saveTask = nil
        loaded = true
        beers = [:]; venues = [:]; venueIdByFoursquare = [:]
        try? FileManager.default.removeItem(at: url)
    }
}
