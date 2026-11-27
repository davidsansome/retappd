#if DEBUG
import CoreLocation
import SwiftUI
import UIKit

/// Debug-only deterministic demo mode for App Store screenshots.
/// Launch with `-screenshotDemo -screenshotScreen <checkin|feed|venue|beer|stats|discover>`
/// and optional `-screenshotAppearance <light|dark>` and `-screenshotAssetsDir <path>`.
enum ScreenshotDemo {
    enum Screen: String {
        case checkin, feed, venue, beer, stats, discover
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-screenshotDemo")
    }

    static var screen: Screen {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-screenshotScreen"), i + 1 < args.count,
           let s = Screen(rawValue: args[i + 1]) {
            return s
        }
        return .feed
    }

    static var colorScheme: ColorScheme {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-screenshotAppearance"), i + 1 < args.count,
           args[i + 1].lowercased() == "dark" {
            return .dark
        }
        return .light
    }

    static var assetsDir: URL {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-screenshotAssetsDir"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("screenshot-assets", isDirectory: true)
    }

    static let demoUsername = "alex_t"
    static let demoLocation = CLLocation(latitude: -33.8688, longitude: 151.2093)

    static let hadBeerIDs: Set<Int> = [1001, 1002, 1004, 1007]

    static let cloudburstBeer = BeerLite(
        bid: 1001,
        name: "Cloudburst Hazy IPA",
        brewery: "Kestrel Brewing Co.",
        style: "IPA - New England / Hazy",
        abv: 6.6,
        label: URL(string: "https://demo.retappd.local/label/1001.png"),
        rating: 4.18,
        ratingCount: 2840,
        hasHad: true,
        breweryLabel: URL(string: "https://demo.retappd.local/label/1001.png"),
        breweryId: 2001
    )

    static let brassTaproom = Venue(
        venueId: 5001,
        foursquareId: "demo-brass-taproom",
        name: "The Brass Taproom",
        category: "Beer Bar",
        address: "48 George St",
        city: "Sydney",
        state: "NSW",
        lat: -33.8688,
        lng: 151.2093,
        isVerified: true,
        reportedDistance: 12
    )

    static let offlineBeer = BeerLite(
        bid: 1006,
        name: "Midnight Yuzu Sour",
        brewery: "Kestrel Brewing Co.",
        style: "Sour - Fruited",
        abv: 4.9,
        label: URL(string: "https://demo.retappd.local/label/1006.png"),
        rating: 4.12,
        ratingCount: 1150,
        hasHad: false,
        breweryLabel: URL(string: "https://demo.retappd.local/label/1001.png"),
        breweryId: 2001
    )

    @MainActor
    static func prepare() {
        UntappdAPI.shared.token = "demo-token"
        UserDefaults.standard.setVolatileDomain(
            ["username": demoUsername, "statsShowBarValues": true],
            forName: UserDefaults.argumentDomain
        )
        HadBeers.shared.clear()
        for id in hadBeerIDs { HadBeers.shared.add(id) }

        // Seed one offline-saved check-in for Discover's "To check in" card (and clear it on other screens).
        for item in PendingCheckins.shared.items {
            PendingCheckins.shared.remove(item.id)
        }
        if screen == .discover {
            var pending = PendingCheckin(
                username: demoUsername,
                savedAt: Date().addingTimeInterval(-35 * 60),
                beer: offlineBeer,
                venue: brassTaproom,
                rating: 4.0,
                shout: "Bright citrus tang, super refreshing."
            )
            pending.setLocation(demoLocation)
            PendingCheckins.shared.add(pending, photo: nil)
        }
    }

    static func loadPhotoAsset(_ name: String) -> UIImage? {
        let url = assetsDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Root demo host

struct ScreenshotDemoRoot: View {
    let auth: AuthStore
    let location: LocationProvider
    @State private var feed = CheckinListModel(source: .friends)
    @State private var discover = DiscoverModel(username: ScreenshotDemo.demoUsername)
    @State private var unread = NotificationUnread(username: ScreenshotDemo.demoUsername)
    @State private var prepared = false

    private static let tabs: [TaproomTab<RootTabs.Page>] = [
        .init(value: .feed, title: "Activity", systemImage: "list.bullet.rectangle"),
        .init(value: .discover, title: "Discover", systemImage: "mappin.and.ellipse"),
        .init(value: .profile, title: "Me", systemImage: "person.crop.circle"),
    ]

    private static func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    var body: some View {
        Group {
            if prepared {
                switch ScreenshotDemo.screen {
                case .checkin:
                    CheckInSheet(
                        demoBeer: ScreenshotDemo.cloudburstBeer,
                        venue: ScreenshotDemo.brassTaproom,
                        rating: 4.25,
                        shout: "Juicy mango, tangerine pith and a pillowy soft finish. Tasting great fresh off the tap.",
                        serving: Self.decodeJSON(ServingType.self, #"{"container_id":1,"container_name":"Draft"}"#),
                        flavors: [
                            Self.decodeJSON(FlavorTag.self, #"{"tag_id":1,"tag_name":"Citrus"}"#),
                            Self.decodeJSON(FlavorTag.self, #"{"tag_id":2,"tag_name":"Tropical"}"#),
                            Self.decodeJSON(FlavorTag.self, #"{"tag_id":3,"tag_name":"Smooth"}"#),
                        ].compactMap { $0 },
                        photo: ScreenshotDemo.loadPhotoAsset("photo-hazy-ipa.jpg")
                    )

                case .feed:
                    NavigationStack {
                        FeedView(model: feed)
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                TaproomTabBar(tabs: Self.tabs, selection: .feed, select: { _ in }) {
                                    TaproomBarAction(title: "Search", systemImage: "magnifyingglass") {}
                                }
                            }
                            .beerAndBreweryDestinations()
                    }

                case .venue:
                    NavigationStack {
                        VenueDetailView(venue: ScreenshotDemo.brassTaproom)
                            .beerAndBreweryDestinations()
                    }

                case .beer:
                    NavigationStack {
                        BeerView(beer: ScreenshotDemo.cloudburstBeer)
                            .beerAndBreweryDestinations()
                    }

                case .stats:
                    NavigationStack {
                        StatsView(username: ScreenshotDemo.demoUsername, initialRange: .year)
                            .beerAndBreweryDestinations()
                    }

                case .discover:
                    NavigationStack {
                        DiscoverView(model: discover)
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                TaproomTabBar(tabs: Self.tabs, selection: .discover, select: { _ in }) {
                                    EmptyView()
                                }
                            }
                            .beerAndBreweryDestinations()
                    }
                    .task {
                        await discover.update(location: ScreenshotDemo.demoLocation, force: true)
                    }
                }
            } else {
                Taproom.background.ignoresSafeArea()
            }
        }
        .environment(auth)
        .environment(location)
        .environment(discover)
        .environment(unread)
        .tint(Taproom.amber)
        .preferredColorScheme(ScreenshotDemo.colorScheme)
        .task {
            ScreenshotDemo.prepare()
            discover.me = User(
                id: 100,
                userName: ScreenshotDemo.demoUsername,
                firstName: "Alex",
                lastName: "Turner",
                avatar: URL(string: "https://demo.retappd.local/avatar/100.png")
            )
            prepared = true
        }
    }
}

// MARK: - URLProtocol serving deterministic JSON and artwork

final class ScreenshotDemoURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard ScreenshotDemo.isEnabled, let host = request.url?.host else { return false }
        return host == "api.untappd.com" || host == "demo.retappd.local"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (data, contentType): (Data, String)
        if url.host == "demo.retappd.local" {
            (data, contentType) = Self.serveImage(for: url)
        } else {
            (data, contentType) = (Self.serveAPI(for: url), "application/json; charset=utf-8")
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    // MARK: - API Fixtures

    private static func envelope(_ responseObj: [String: Any]) -> Data {
        let root: [String: Any] = [
            "meta": ["code": 200],
            "notifications": ["unread_count": ["comments": 0, "toasts": 0, "friends": 0, "messages": 0, "venues": 0]],
            "response": responseObj,
        ]
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }

    private static func untappdDate(_ secondsAgo: TimeInterval) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: Date().addingTimeInterval(-secondsAgo))
    }

    private static func userJSON(id: Int, userName: String, first: String, last: String) -> [String: Any] {
        [
            "uid": id,
            "user_name": userName,
            "first_name": first,
            "last_name": last,
            "user_avatar": "https://demo.retappd.local/avatar/\(id).png",
            "relationship": "friends",
        ]
    }

    private static func beerJSON(
        bid: Int, name: String, style: String, abv: Double, ibu: Int = 35,
        rating: Double = 4.1, ratingCount: Int = 1200, hasHad: Bool = false
    ) -> [String: Any] {
        [
            "bid": bid,
            "beer_name": name,
            "beer_label": "https://demo.retappd.local/label/\(bid).png",
            "beer_label_hd": "https://demo.retappd.local/label/\(bid).png",
            "beer_style": style,
            "beer_abv": abv,
            "beer_ibu": ibu,
            "rating_score": rating,
            "rating_count": ratingCount,
            "has_had": hasHad,
        ]
    }

    private static func breweryJSON(id: Int, name: String, city: String = "Sydney", state: String = "NSW") -> [String: Any] {
        [
            "brewery_id": id,
            "brewery_name": name,
            "brewery_label": "https://demo.retappd.local/label/\(1000 + (id % 10)).png",
            "country_name": "Australia",
            "brewery_type": "Micro Brewery",
            "location": ["brewery_city": city, "brewery_state": state],
        ]
    }

    private static func venueJSON(
        id: Int, fsId: String, name: String, category: String, address: String,
        city: String = "Sydney", state: String = "NSW", lat: Double, lng: Double,
        verified: Bool = true, distanceKm: Double
    ) -> [String: Any] {
        [
            "venue_id": id,
            "venue_name": name,
            "primary_category": category,
            "is_verified": verified,
            "distance": distanceKm,
            "foursquare": ["foursquare_id": fsId],
            "location": [
                "venue_address": address,
                "venue_city": city,
                "venue_state": state,
                "venue_country": "Australia",
                "lat": lat,
                "lng": lng,
            ],
            "contact": ["venue_url": "https://brasstaproom.com.au"],
        ]
    }

    private static func serveAPI(for url: URL) -> Data {
        let path = url.path
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        let maya = userJSON(id: 201, userName: "maya_c", first: "Maya", last: "Chen")
        let sam = userJSON(id: 202, userName: "sam_b", first: "Sam", last: "Brooks")
        let oliver = userJSON(id: 203, userName: "oliver_r", first: "Oliver", last: "Reid")
        let priya = userJSON(id: 204, userName: "priya_n", first: "Priya", last: "Nair")

        let brass = venueJSON(
            id: 5001, fsId: "demo-brass-taproom", name: "The Brass Taproom",
            category: "Beer Bar", address: "48 George St",
            lat: -33.8688, lng: 151.2093, distanceKm: 0.012
        )
        let kestrelTap = venueJSON(
            id: 5002, fsId: "demo-kestrel-bar", name: "Kestrel Brewery & Bar",
            category: "Brewery", address: "12 Crown Ln",
            lat: -33.8705, lng: 151.2110, distanceKm: 0.24
        )
        let maltBarrel = venueJSON(
            id: 5003, fsId: "demo-malt-barrel", name: "The Malt & Barrel",
            category: "Craft Beer Bar", address: "95 King St",
            lat: -33.8725, lng: 151.2065, distanceKm: 0.48
        )
        let harbourShop = venueJSON(
            id: 5004, fsId: "demo-harbour-shop", name: "Harbourside Bottle Shop",
            category: "Beer Store", address: "210 Kent St",
            lat: -33.8655, lng: 151.2045, distanceKm: 0.61
        )

        let feedCheckins: [[String: Any]] = [
            [
                "checkin_id": 9001,
                "created_at": untappdDate(14 * 60),
                "rating_score": 4.25,
                "checkin_comment": "Soft citrus and ripe mango on the nose, super clean finish. Easily one of their best hazy releases this year.",
                "user": maya,
                "beer": beerJSON(bid: 1001, name: "Cloudburst Hazy IPA", style: "IPA - New England / Hazy", abv: 6.6, rating: 4.18, ratingCount: 2840, hasHad: true),
                "brewery": breweryJSON(id: 2001, name: "Kestrel Brewing Co."),
                "venue": brass,
                "serving_type": "Draft",
                "toasts": ["total_count": 4, "auth_toast": true, "items": [["user": sam], ["user": oliver]]],
                "comments": ["total_count": 1, "items": []],
                "media": ["items": [["photo": [
                    "photo_img_sm": "https://demo.retappd.local/photo/photo-hazy-ipa.jpg",
                    "photo_img_md": "https://demo.retappd.local/photo/photo-hazy-ipa.jpg",
                    "photo_img_lg": "https://demo.retappd.local/photo/photo-hazy-ipa.jpg",
                ]]]],
                "badges": ["items": [[
                    "badge_id": 701,
                    "user_badge_id": 7001,
                    "badge_name": "Hopped Up (Level 14)",
                    "badge_image": ["md": "https://demo.retappd.local/badge/701.png"],
                ]]],
                "flavor_profile": ["items": ["Citrus", "Tropical", "Smooth"]],
            ],
            [
                "checkin_id": 9002,
                "created_at": untappdDate(52 * 60),
                "rating_score": 4.5,
                "checkin_comment": "Rich dark chocolate, espresso crema and a hint of toasted oak. Velvety mouthfeel.",
                "user": sam,
                "beer": beerJSON(bid: 1002, name: "Velvet Ember Imperial Stout", style: "Stout - Imperial / Double", abv: 10.4, rating: 4.36, ratingCount: 1920, hasHad: true),
                "brewery": breweryJSON(id: 2002, name: "Hearthstone Ales"),
                "venue": kestrelTap,
                "serving_type": "Draft",
                "toasts": ["total_count": 6, "auth_toast": false, "items": [["user": maya], ["user": priya]]],
                "comments": ["total_count": 0, "items": []],
                "media": ["items": [["photo": [
                    "photo_img_sm": "https://demo.retappd.local/photo/photo-stout.jpg",
                    "photo_img_md": "https://demo.retappd.local/photo/photo-stout.jpg",
                    "photo_img_lg": "https://demo.retappd.local/photo/photo-stout.jpg",
                ]]]],
                "badges": ["items": []],
                "flavor_profile": ["items": ["Roasty", "Chocolate", "Coffee"]],
            ],
            [
                "checkin_id": 9003,
                "created_at": untappdDate(2 * 3600 + 18 * 60),
                "rating_score": 4.0,
                "checkin_comment": "Crisp Saaz hop snap and golden malt sweetness in the afternoon sun.",
                "user": priya,
                "beer": beerJSON(bid: 1003, name: "Sunlit Bohemian Pilsner", style: "Pilsner - Czech / Bohemian", abv: 5.1, rating: 3.94, ratingCount: 1410, hasHad: false),
                "brewery": breweryJSON(id: 2003, name: "Linden & Lark"),
                "venue": maltBarrel,
                "serving_type": "Draft",
                "toasts": ["total_count": 3, "auth_toast": false, "items": [["user": oliver]]],
                "comments": ["total_count": 0, "items": []],
                "media": ["items": [["photo": [
                    "photo_img_sm": "https://demo.retappd.local/photo/photo-pilsner.jpg",
                    "photo_img_md": "https://demo.retappd.local/photo/photo-pilsner.jpg",
                    "photo_img_lg": "https://demo.retappd.local/photo/photo-pilsner.jpg",
                ]]]],
                "badges": ["items": []],
                "flavor_profile": ["items": ["Crisp", "Floral", "Clean"]],
            ],
        ]

        // 1. Feed & Beer check-ins
        if path == "/v4/checkin/recent" || path.hasPrefix("/v4/beer/checkins/") || path.hasPrefix("/v4/venue/checkins/") {
            return envelope(["checkins": ["items": feedCheckins]])
        }

        // 2. Serving types & flavors & friends (Check-In sheet)
        if path == "/v4/checkin/serving_types" {
            let types: [[String: Any]] = [
                ["container_id": 1, "container_name": "Draft"],
                ["container_id": 2, "container_name": "Can"],
                ["container_id": 3, "container_name": "Bottle"],
                ["container_id": 4, "container_name": "Taster"],
                ["container_id": 5, "container_name": "Cask"],
            ]
            return envelope(["items": types])
        }

        if path.hasPrefix("/v4/beer/flavor_profile/") || path == "/v4/checkin/flavor_profiles" {
            let tags: [[String: Any]] = [
                ["tag_id": 1, "tag_name": "Citrus"],
                ["tag_id": 2, "tag_name": "Tropical"],
                ["tag_id": 3, "tag_name": "Smooth"],
                ["tag_id": 4, "tag_name": "Juicy"],
                ["tag_id": 5, "tag_name": "Hazy"],
                ["tag_id": 6, "tag_name": "Piney"],
            ]
            return envelope(["items": tags])
        }

        if path == "/v4/user/recently_tagged" || path == "/v4/user/friends" {
            let items: [[String: Any]] = [
                ["user": maya], ["user": sam], ["user": oliver], ["user": priya],
            ]
            return envelope(["items": items, "friends": ["items": items]])
        }

        // 3. Venue info, menu sections & filters
        if path.hasPrefix("/v4/venue/info/") {
            var v = brass
            v["stats"] = [
                "total_count": 14820,
                "total_user_count": 4310,
                "monthly_count": 286,
                "weekly_count": 74,
                "user_count": 18,
            ]
            return envelope(["venue": v])
        }

        if path == "/v4/menus/sections" {
            let onTap: [[String: Any]] = [
                ["id": 1, "untappd_id": 1001, "tap_number": "1", "name": "Cloudburst Hazy IPA", "brewery": "Kestrel Brewing Co.", "style": "IPA - New England / Hazy", "abv": 6.6, "rating": 4.18, "rating_count": 2840, "has_had": true, "label_image": "https://demo.retappd.local/label/1001.png"],
                ["id": 2, "untappd_id": 1003, "tap_number": "2", "name": "Sunlit Bohemian Pilsner", "brewery": "Linden & Lark", "style": "Pilsner - Czech / Bohemian", "abv": 5.1, "rating": 3.94, "rating_count": 1410, "has_had": false, "label_image": "https://demo.retappd.local/label/1003.png"],
                ["id": 3, "untappd_id": 1004, "tap_number": "3", "name": "Coastline West Coast IPA", "brewery": "Saltwind Brewing", "style": "IPA - American", "abv": 6.8, "rating": 4.08, "rating_count": 3120, "has_had": true, "label_image": "https://demo.retappd.local/label/1004.png"],
                ["id": 4, "untappd_id": 1006, "tap_number": "4", "name": "Midnight Yuzu Sour", "brewery": "Kestrel Brewing Co.", "style": "Sour - Fruited", "abv": 4.9, "rating": 4.12, "rating_count": 1150, "has_had": false, "label_image": "https://demo.retappd.local/label/1006.png"],
                ["id": 5, "untappd_id": 1002, "tap_number": "5", "name": "Velvet Ember Imperial Stout", "brewery": "Hearthstone Ales", "style": "Stout - Imperial / Double", "abv": 10.4, "rating": 4.36, "rating_count": 1920, "has_had": true, "label_image": "https://demo.retappd.local/label/1002.png"],
                ["id": 6, "untappd_id": 1005, "tap_number": "6", "name": "Orchard Bloom Saison", "brewery": "Meadowbrook Farmhouse", "style": "Farmhouse Ale - Saison", "abv": 5.8, "rating": 4.02, "rating_count": 890, "has_had": false, "label_image": "https://demo.retappd.local/label/1005.png"],
                ["id": 7, "untappd_id": 1007, "tap_number": "7", "name": "Copper Kettle ESB", "brewery": "Hearthstone Ales", "style": "Bitter - ESB", "abv": 5.5, "rating": 3.96, "rating_count": 760, "has_had": true, "label_image": "https://demo.retappd.local/label/1007.png"],
            ]
            let cans: [[String: Any]] = [
                ["id": 8, "untappd_id": 1008, "position": 0, "name": "Pinecrest Pale Ale", "brewery": "Saltwind Brewing", "style": "Pale Ale - American", "abv": 5.4, "rating": 3.89, "rating_count": 2210, "has_had": false, "label_image": "https://demo.retappd.local/label/1008.png"],
            ]
            return envelope(["sections": [
                ["section_id": 10, "menu_name": "Tap List", "section_name": "On Tap", "total_count": onTap.count, "last_page": true, "items": onTap],
                ["section_id": 11, "menu_name": "Fridge", "section_name": "Cans & Bottles", "total_count": cans.count, "last_page": true, "items": cans],
            ]])
        }

        if path == "/v4/menus/filters" {
            return envelope([
                "total_beer": 8,
                "filters": [
                    "styles": [
                        "IPA - New England / Hazy": 2,
                        "IPA - American": 1,
                        "Pilsner - Czech": 1,
                        "Stout - Imperial": 1,
                        "Sour - Fruited": 1,
                        "Farmhouse Ale - Saison": 1,
                    ],
                    "breweries": [:],
                    "countries": [:],
                ],
            ])
        }

        // 4. Beer info & rating
        if path.hasPrefix("/v4/beer/info/") {
            var b = beerJSON(bid: 1001, name: "Cloudburst Hazy IPA", style: "IPA - New England / Hazy", abv: 6.6, ibu: 35, rating: 4.18, ratingCount: 2840, hasHad: true)
            b["beer_description"] = "Double dry-hopped with Citra, Mosaic and Nelson Sauvin over a soft oat and wheat malt bill. Bursting with ripe mango, sweet tangerine and a pillowy, low-bitterness finish."
            b["brewery"] = breweryJSON(id: 2001, name: "Kestrel Brewing Co.")
            b["auth_rating"] = 4.25
            b["friends_ratings"] = ["rating_score": 4.32, "rating_count": 7]
            b["wish_list"] = false
            b["is_in_production"] = true
            b["stats"] = [
                "total_count": 6420,
                "monthly_count": 318,
                "total_user_count": 4190,
                "user_count": 3,
            ]
            return envelope(["beer": b])
        }

        if path.hasPrefix("/v4/beer/userrating/") {
            return envelope(["rating": ["rating_score": 4.25]])
        }

        // 5. Statistics
        if path == "/v4/user/stats" {
            let startStr = query["start_date"] ?? ""
            let endStr = query["end_date"] ?? ""
            let isSingleMonth = startStr.count == 10 && endStr.count == 10 && startStr.prefix(7) == endStr.prefix(7)
            let monthlyCounts: [Int] = [9, 12, 8, 15, 11, 18, 14, 10, 16, 13, 19, 11]
            let topBeers: [[String: Any]] = [
                ["total_count": 7, "beer": beerJSON(bid: 1001, name: "Cloudburst Hazy IPA", style: "IPA - New England / Hazy", abv: 6.6), "brewery": breweryJSON(id: 2001, name: "Kestrel Brewing Co.")],
                ["total_count": 5, "beer": beerJSON(bid: 1003, name: "Sunlit Bohemian Pilsner", style: "Pilsner - Czech", abv: 5.1), "brewery": breweryJSON(id: 2003, name: "Linden & Lark")],
                ["total_count": 4, "beer": beerJSON(bid: 1002, name: "Velvet Ember Imperial Stout", style: "Stout - Imperial", abv: 10.4), "brewery": breweryJSON(id: 2002, name: "Hearthstone Ales")],
                ["total_count": 4, "beer": beerJSON(bid: 1004, name: "Coastline West Coast IPA", style: "IPA - American", abv: 6.8), "brewery": breweryJSON(id: 2004, name: "Saltwind Brewing")],
            ]
            if isSingleMonth {
                let monthNum = Int(startStr.dropFirst(5).prefix(2)) ?? 1
                let count = monthlyCounts[(monthNum - 1) % monthlyCounts.count]
                return envelope(["stats": [
                    "distinct_beers": count,
                    "total_checkins": Int(Double(count) * 1.4),
                    "average_checkins_per_day": 0.6,
                    "total_venues": 6,
                    "new_venues": 2,
                    "new_venues_perc": 33,
                    "new_beers": count - 2,
                    "new_beers_perc": 82,
                    "first_checkin_date": "2019-04-12 18:00:00",
                    "top_beers": ["beers": ["items": []]],
                ]])
            } else {
                return envelope(["stats": [
                    "distinct_beers": 156,
                    "total_checkins": 224,
                    "average_checkins_per_day": 0.61,
                    "total_venues": 42,
                    "new_venues": 19,
                    "new_venues_perc": 45,
                    "new_beers": 131,
                    "new_beers_perc": 84,
                    "first_checkin_date": "2019-04-12 18:00:00",
                    "top_beers": ["beers": ["items": topBeers]],
                ]])
            }
        }

        // 6. Discover (venues around, map, local pub)
        if path == "/v4/venue/around" {
            return envelope([
                "location": ["lat": -33.8688, "lng": 151.2093],
                "recent": ["items": [brass, kestrelTap]],
                "foursquare": ["items": [brass, kestrelTap, maltBarrel, harbourShop]],
            ])
        }

        if path == "/v4/venue/map" {
            return envelope([
                "center_lat": -33.8688,
                "center_lng": 151.2093,
                "venues": ["items": [
                    ["venue": brass, "popularity": 95],
                    ["venue": kestrelTap, "popularity": 84],
                    ["venue": maltBarrel, "popularity": 78],
                    ["venue": harbourShop, "popularity": 62],
                ]],
            ])
        }

        if path == "/v4/thepub/local" {
            return envelope(["checkins": ["items": feedCheckins]])
        }

        if path == "/v4/user/user_beer_list" {
            return envelope(["items": Array(ScreenshotDemo.hadBeerIDs)])
        }

        return envelope([:])
    }

    // MARK: - Demo Image Rendering

    private static func serveImage(for url: URL) -> (Data, String) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return (Data(), "image/png") }

        switch parts[0] {
        case "photo":
            let fileURL = ScreenshotDemo.assetsDir.appendingPathComponent(parts[1])
            if let data = try? Data(contentsOf: fileURL) {
                return (data, "image/jpeg")
            }
            return (renderPlaceholderPhoto(), "image/png")

        case "label":
            let bid = Int(parts[1].replacingOccurrences(of: ".png", with: "")) ?? 1001
            return (renderBeerLabel(bid: bid), "image/png")

        case "avatar":
            let uid = Int(parts[1].replacingOccurrences(of: ".png", with: "")) ?? 100
            return (renderAvatar(uid: uid), "image/png")

        case "badge":
            return (renderBadge(), "image/png")

        default:
            return (Data(), "image/png")
        }
    }

    private static func renderBeerLabel(bid: Int) -> Data {
        struct LabelSpec {
            var bg: UIColor
            var accent: UIColor
            var monogram: String
            var subtitle: String
        }
        let specs: [Int: LabelSpec] = [
            1001: .init(bg: UIColor(red: 0.12, green: 0.35, blue: 0.40, alpha: 1), accent: UIColor(red: 0.96, green: 0.72, blue: 0.25, alpha: 1), monogram: "CB", subtitle: "HAZY IPA"),
            1002: .init(bg: UIColor(red: 0.16, green: 0.12, blue: 0.11, alpha: 1), accent: UIColor(red: 0.86, green: 0.48, blue: 0.20, alpha: 1), monogram: "VE", subtitle: "STOUT"),
            1003: .init(bg: UIColor(red: 0.88, green: 0.66, blue: 0.22, alpha: 1), accent: UIColor(red: 0.18, green: 0.14, blue: 0.10, alpha: 1), monogram: "SB", subtitle: "PILSNER"),
            1004: .init(bg: UIColor(red: 0.13, green: 0.26, blue: 0.46, alpha: 1), accent: UIColor(red: 0.95, green: 0.85, blue: 0.62, alpha: 1), monogram: "CW", subtitle: "WC IPA"),
            1005: .init(bg: UIColor(red: 0.27, green: 0.44, blue: 0.30, alpha: 1), accent: UIColor(red: 0.96, green: 0.92, blue: 0.80, alpha: 1), monogram: "OB", subtitle: "SAISON"),
            1006: .init(bg: UIColor(red: 0.42, green: 0.17, blue: 0.34, alpha: 1), accent: UIColor(red: 0.98, green: 0.82, blue: 0.30, alpha: 1), monogram: "MY", subtitle: "YUZU"),
            1007: .init(bg: UIColor(red: 0.60, green: 0.25, blue: 0.14, alpha: 1), accent: UIColor(red: 0.97, green: 0.91, blue: 0.78, alpha: 1), monogram: "CK", subtitle: "ESB"),
            1008: .init(bg: UIColor(red: 0.18, green: 0.34, blue: 0.26, alpha: 1), accent: UIColor(red: 0.93, green: 0.69, blue: 0.29, alpha: 1), monogram: "PP", subtitle: "PALE ALE"),
        ]
        let spec = specs[bid] ?? specs[1001]!
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            spec.bg.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // Subtle craft frame
            spec.accent.withAlphaComponent(0.35).setStroke()
            let framePath = UIBezierPath(roundedRect: CGRect(x: 16, y: 16, width: 224, height: 224), cornerRadius: 24)
            framePath.lineWidth = 4
            framePath.stroke()

            // Sunburst / hop arc at top
            spec.accent.withAlphaComponent(0.22).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 68, y: -40, width: 120, height: 120))

            let monoAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Georgia-Bold", size: 88) ?? UIFont.systemFont(ofSize: 88, weight: .heavy),
                .foregroundColor: spec.accent,
            ]
            let monoStr = NSAttributedString(string: spec.monogram, attributes: monoAttrs)
            let monoSize = monoStr.size()
            monoStr.draw(at: CGPoint(x: (size.width - monoSize.width) / 2, y: 58))

            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24, weight: .heavy),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                .kern: 2.0,
            ]
            let subStr = NSAttributedString(string: spec.subtitle, attributes: subAttrs)
            let subSize = subStr.size()
            subStr.draw(at: CGPoint(x: (size.width - subSize.width) / 2, y: 180))
        }
        return img.pngData() ?? Data()
    }

    private static func renderAvatar(uid: Int) -> Data {
        let table: [Int: (String, UIColor)] = [
            100: ("AT", UIColor(red: 0.78, green: 0.44, blue: 0.16, alpha: 1)),
            201: ("MC", UIColor(red: 0.24, green: 0.45, blue: 0.47, alpha: 1)),
            202: ("SB", UIColor(red: 0.56, green: 0.30, blue: 0.24, alpha: 1)),
            203: ("OR", UIColor(red: 0.33, green: 0.44, blue: 0.27, alpha: 1)),
            204: ("PN", UIColor(red: 0.46, green: 0.28, blue: 0.48, alpha: 1)),
        ]
        let (initials, color) = table[uid] ?? ("RT", UIColor(red: 0.78, green: 0.44, blue: 0.16, alpha: 1))
        let size = CGSize(width: 160, height: 160)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 64, weight: .bold),
                .foregroundColor: UIColor(red: 0.99, green: 0.96, blue: 0.91, alpha: 1),
            ]
            let s = NSAttributedString(string: initials, attributes: attrs)
            let sz = s.size()
            s.draw(at: CGPoint(x: (size.width - sz.width) / 2, y: (size.height - sz.height) / 2))
        }
        return img.pngData() ?? Data()
    }

    private static func renderBadge() -> Data {
        let size = CGSize(width: 128, height: 128)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.91, green: 0.64, blue: 0.23, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 6, y: 6, width: 116, height: 116))
            UIColor(red: 0.17, green: 0.13, blue: 0.09, alpha: 1).setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: 16, y: 16, width: 96, height: 96))
            ring.lineWidth = 4
            ring.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .black),
                .foregroundColor: UIColor(red: 0.17, green: 0.13, blue: 0.09, alpha: 1),
            ]
            let s = NSAttributedString(string: "14", attributes: attrs)
            let sz = s.size()
            s.draw(at: CGPoint(x: (size.width - sz.width) / 2, y: (size.height - sz.height) / 2))
        }
        return img.pngData() ?? Data()
    }

    private static func renderPlaceholderPhoto() -> Data {
        let size = CGSize(width: 600, height: 600)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.85, green: 0.60, blue: 0.22, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return img.pngData() ?? Data()
    }
}
#endif
