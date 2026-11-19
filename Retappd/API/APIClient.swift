import Foundation
import UIKit

enum APIError: LocalizedError {
    case http(Int)
    case server(code: Int, detail: String?)
    case unauthorized
    case decoding

    var errorDescription: String? {
        switch self {
        case .http(let c): "The server returned HTTP \(c)."
        case .server(_, let d): d ?? "Untappd returned an error."
        case .unauthorized: "Your session has expired. Please sign in again."
        case .decoding: "Couldn't read the server's response."
        }
    }
}

/// A request to any backend we talk to. `cacheKey` identifies its response in `ResponseCache`.
struct APIRequest: Sendable {
    enum Method: String, Sendable { case get = "GET", post = "POST" }

    var method: Method = .get
    var path: String
    var query: [String: String] = [:]
    var form: [String: String]? = nil

    var cacheKey: String {
        let q = query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let f = (form ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "\(method.rawValue) \(path)?\(q)#\(f)"
    }
}

/// Talks to api.untappd.com, presenting itself the way the docs describe the official app.
final class UntappdAPI: @unchecked Sendable {
    static let shared = UntappdAPI()

    static let clientID = "20B24F8EF10B1A76BBF23B39528B7AB770FFB264"
    static let clientSecret = "10E493969C8A985966F106DC1542E85230B53A26"
    static let appVersion = "4.7.13"
    private let base = URL(string: "https://api.untappd.com")!

    private let lock = NSLock()
    private var _token: String?
    var token: String? {
        get { lock.withLock { _token } }
        set { lock.withLock { _token = newValue } }
    }

    /// Called (on any thread) when the server rejects our token.
    var onUnauthorized: (@Sendable () -> Void)?

    /// Called (on any thread) with the unread counts in each successful response's envelope,
    /// except `GET /v4/notifications`, whose own envelope still shows the counts from before it
    /// cleared them.
    var onUnreadCounts: (@Sendable (UnreadCounts) -> Void)?

    let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData  // we cache ourselves
        c.urlCache = nil
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    func urlRequest(_ r: APIRequest) -> URLRequest {
        var comps = URLComponents(url: base.appendingPathComponent(r.path), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "client_secret", value: Self.clientSecret),
            URLQueryItem(name: "utv", value: "4.0.0"),
        ]
        items += r.query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.httpMethod = r.method.rawValue
        req.setValue("Untappd/\(Self.appVersion) (android; Android 35)", forHTTPHeaderField: "User-Agent")
        req.setValue(Self.appVersion, forHTTPHeaderField: "X-Untappd-App-Version")
        req.setValue("android", forHTTPHeaderField: "X-Untappd-App")
        req.setValue("1", forHTTPHeaderField: "X-React-Native")
        req.setValue("en", forHTTPHeaderField: "Accept-Language")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let form = r.form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.formEncode(form).data(using: .utf8)
        }
        return req
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(v.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
    }

    /// Fetches raw bytes and validates the envelope. Only valid responses are returned (and so cached).
    func data(_ r: APIRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: urlRequest(r))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let envelope = try? JSONDecoder().decode(Envelope<Ignored>.self, from: data)
        let meta = envelope?.meta
        if status == 401 || meta?.code == 401 || meta?.errorType == "invalid_auth" {
            if token != nil { onUnauthorized?() }
            throw APIError.unauthorized
        }
        if let meta, meta.code != 200 {
            throw APIError.server(code: meta.code, detail: meta.errorDetail)
        }
        guard (200..<300).contains(status) else { throw APIError.http(status) }
        if let counts = envelope?.notifications, r.path != "/v4/notifications" { onUnreadCounts?(counts) }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard let r = try JSONDecoder().decode(Envelope<T>.self, from: data).response else { throw APIError.decoding }
        return r
    }

    func fetch<T: Decodable>(_ r: APIRequest, as type: T.Type = T.self) async throws -> T {
        try Self.decode(T.self, from: try await data(r))
    }

    private struct Ignored: Decodable {}

    /// PUTs a checkin's JPEG to the presigned S3 URL that `checkin/add` or `checkin/edit` returned.
    /// This goes to S3, not Untappd, so it carries none of the API's headers. The photo isn't
    /// attached to the checkin until `photoUploadComplete` is then posted.
    func uploadPhoto(_ jpeg: Data, to url: URL) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let (_, resp) = try await session.upload(for: req, from: jpeg)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.http(status) }
    }
}

// MARK: - Endpoints

extension APIRequest {
    static func xauth(username: String, password: String) -> APIRequest {
        let device = UIDevice.current
        return APIRequest(method: .post, path: "/v4/xauth", form: [
            "app_version": UntappdAPI.appVersion,
            "device_name": device.model,
            "device_platform": "Android",
            "device_udid": DeviceID.value,
            "device_version": device.systemVersion,
            "multi_account": "true",
            "user_name": username,
            "user_password": password,
        ])
    }

    static func friendFeed(maxId: Int? = nil, limit: Int = 25) -> APIRequest {
        var q = ["limit": "\(limit)"]
        if let maxId { q["max_id"] = "\(maxId)" }
        return APIRequest(path: "/v4/checkin/recent", query: q)
    }

    /// The notification feed, newest first, as the official app asks for it. **Reading it marks
    /// the account's notifications as read** (see `GET /v4/notifications` in the API docs). It
    /// pages with `limit`/`offset`, and `response.pagination.next_url` is empty on the last page.
    static func notifications(offset: Int = 0, limit: Int = 25) -> APIRequest {
        APIRequest(path: "/v4/notifications", query: [
            "includes": "commentTag,checkinTag,checkinFriendTag,toast,comment,promo",
            "is_news": "false", "version": "2",
            "limit": "\(limit)", "offset": "\(offset)",
        ])
    }

    static func userCheckins(_ username: String, maxId: Int? = nil, limit: Int = 25) -> APIRequest {
        var q = ["limit": "\(limit)"]
        if let maxId { q["max_id"] = "\(maxId)" }
        return APIRequest(path: "/v4/user/checkins/\(username)", query: q)
    }

    /// Totals for `start`...`end` (YYYY-MM-DD, both inclusive, in the time zone `gmtOffset` hours
    /// from GMT). Always for the signed-in user. The official app sends `v2=true`.
    static func userStats(start: String, end: String, gmtOffset: Double) -> APIRequest {
        APIRequest(path: "/v4/user/stats", query: [
            "start_date": start, "end_date": end, "v2": "true",
            "gmt_offset": gmtOffset == gmtOffset.rounded() ? String(Int(gmtOffset)) : String(gmtOffset),
        ])
    }

    static func userInfo(_ username: String) -> APIRequest {
        APIRequest(path: "/v4/user/info/\(username)", query: ["compact": "true"])
    }

    /// Every beer id the signed-in user has had, in one response (no per-beer details). Behind `HadBeers`.
    static let userBeerList = APIRequest(path: "/v4/user/user_beer_list", query: ["mode": "v3"])

    static func venuesAround(lat: Double, lng: Double, query: String = "", limit: Int = 25) -> APIRequest {
        APIRequest(path: "/v4/venue/around", query: [
            "lat": String(format: "%.6f", lat), "lng": String(format: "%.6f", lng),
            "limit": "\(limit)", "dist_pref": "m", "q": query, "location": "",
        ])
    }

    /// Places to have bought a beer, in `foursquare`: everything nearby, not just shops, unless
    /// `query` narrows it. Same shape as `/venue/around`; what the official app's "Purchased at"
    /// picker calls. Not sent with `recent=true`, which empties the `foursquare` list.
    ///
    /// `location` is a place name ("Melbourne", "Tokyo", "Belgium") for the official app's second,
    /// "search near…" field. The API docs list `location` with no description, only ever captured
    /// empty. Tried live on 2026-11-18, it is geocoded on the server (by Google, echoed in
    /// `response.location.geocode`) and the search moves there:
    /// - `lat`/`lng` are still required (HTTP 500, `invalid_param`, "Your missing the 'lat' and/or
    ///   'lng' parameter." without them, and for 0,0) but are ignored when `location` geocodes, so
    ///   any non-zero pair will do when there's no device fix. Omitting `location` equals "".
    /// - Results come from around the geocoded point: `algolia.aroundLatLng` is the point and
    ///   `aroundRadius` 250 (m) with no `q`, 100000 with one; `distance` is from that point (km).
    ///   `Melbourne` gave Melbourne VIC places, `Tokyo` Tokyo ones, `Belgium` places near Belgium's
    ///   centroid, and with `q=bottle` Melbourne bottle shops.
    /// - `response.location.geocode[0]` echoes the place: `metadata.formatted_address` ("Melbourne
    ///   VIC, Australia"), `lat`/`lng`, `provider`, `metadata.geometry`. (`response.location.lat/lng`
    ///   stay the device values.) `/venue/around` instead echoes `location_query` and the point in
    ///   `location`, and adds `is_too_far_away`.
    /// - An unknown place ("qzxqzx") is still HTTP 200, with `geocode: []`, an empty `foursquare`
    ///   and `algolia.aroundLatLngViaIP`: no error code. (`/venue/around` silently searches near
    ///   the device instead.)
    /// - Case, spacing and extra words ("Melbourne, Victoria") don't matter.
    static func retailVenuesAround(lat: Double, lng: Double, query: String = "", location: String? = nil,
                                   limit: Int = 25) -> APIRequest {
        var q = [
            "lat": String(format: "%.6f", lat), "lng": String(format: "%.6f", lng),
            "limit": "\(limit)", "dist_pref": "m", "q": query,
        ]
        if let place = ShopPlace.normalized(location) { q["location"] = place }
        return APIRequest(path: "/v4/venue/aroundretail", query: q)
    }

    /// Untappd's own venues (with ids and verified flags) inside a box of ±`span` degrees.
    static func venueMap(lat: Double, lng: Double, span: Double = 0.008, limit: Int = 60) -> APIRequest {
        let bounds = String(format: #"{"ne":[%.6f,%.6f],"sw":[%.6f,%.6f]}"#, lat + span, lng + span, lat - span, lng - span)
        return APIRequest(path: "/v4/venue/map", query: [
            "bounds": bounds, "categories": "true", "dist_pref": "m",
            "lat": String(format: "%.6f", lat), "lng": String(format: "%.6f", lng),
            "limit": "\(limit)", "menu_offering_filters": "", "mode": "v3", "sub_category_id": "",
        ])
    }

    static func thePubLocal(lat: Double, lng: Double, limit: Int = 25) -> APIRequest {
        APIRequest(path: "/v4/thepub/local", query: [
            "lat": String(format: "%.5f", lat), "lng": String(format: "%.5f", lng), "limit": "\(limit)",
        ])
    }

    /// A venue's checkins, newest first; `friendsOnly` keeps just the user's friends'. Pages with
    /// `max_id` like the other feeds.
    static func venueCheckins(_ venueId: Int, friendsOnly: Bool = false, maxId: Int? = nil, limit: Int = 25) -> APIRequest {
        var q = ["limit": "\(limit)"]
        if friendsOnly { q["type"] = "friends" }
        if let maxId { q["max_id"] = "\(maxId)" }
        return APIRequest(path: "/v4/venue/checkins/\(venueId)", query: q)
    }

    static func venueMenu(_ venueId: Int, limit: Int = 100) -> APIRequest {
        APIRequest(method: .post, path: "/v4/menus/sections", form: [
            "brewery": "", "countries": "", "flatten_when_filtering": "true", "has_not_had_before": "false",
            "limit": "\(limit)", "menu_id": "", "q": "", "serving_styles": "", "sort": "", "styles": "",
            "types": "", "untappd_community_awards": "false", "venue_id": "\(venueId)",
        ])
    }

    /// Venue details. With `compact=venue_menu_compact`, `recently_added` lists the beers on
    /// tap with their tap numbers (the menu endpoint leaves `tap_number` null).
    static func venueInfo(_ id: Int) -> APIRequest {
        APIRequest(path: "/v4/venue/info/\(id)", query: [
            "compact": "venue_menu_compact", "multipleHours": "1",
            "timezone": "\(TimeZone.current.secondsFromGMT() / 3600)", "track": "false",
        ])
    }

    /// Toggles the user's toast on a checkin. Not in the captured docs; this is the public v4
    /// API's endpoint (POST /v4/checkin/toast/{id}), which toasts or un-toasts.
    static func toggleToast(_ checkinId: Int) -> APIRequest {
        APIRequest(method: .post, path: "/v4/checkin/toast/\(checkinId)", form: [:])
    }

    /// Attaches a photo PUT to `photo_upload.url` to its checkin. Not in the Android capture; from
    /// Metabeer (see `POST /v4/photo/uploadComplete` in the API docs). Without it the checkin has
    /// no photo.
    static func photoUploadComplete(checkinId: Int, destination: URL) -> APIRequest {
        APIRequest(method: .post, path: "/v4/photo/uploadComplete", form: [
            "checkin_id": "\(checkinId)",
            "destination_url": destination.absoluteString,
        ])
    }

    static func deleteCheckin(_ id: Int) -> APIRequest {
        APIRequest(method: .post, path: "/v4/checkin/delete/\(id)", form: [:])
    }

    /// Changes a checkin's rating, comment, serving type and shop, sending its beer and venue back
    /// unchanged as the official app does. Untappd treats an empty `shout`, `checkin_tags` or
    /// `flavor_profiles` as "leave as is", so a comment can be changed but not cleared.
    ///
    /// `purchase_foursquare_id` is the opposite: leaving it out (or sending it empty) removes the
    /// checkin's shop, so `purchaseFoursquareId` must be the shop to keep, or nil to remove it.
    static func editCheckin(_ checkin: Checkin, rating: Double, shout: String, containerId: Int?,
                            purchaseFoursquareId: String?, isPhoto: Bool = false) -> APIRequest {
        let tz = TimeZone.current
        var form = [
            "rating": rating > 0 ? String(format: "%.2f", rating) : "0",
            "shout": shout,
            "checkin_tags": "",
            "flavor_profiles": "",
            "is_photo": isPhoto ? "true" : "false",
            "photo_file_ext": "jpg",
            "gmt_offset": "\(tz.secondsFromGMT() / 3600)",
            "timezone": tz.identifier,
            "purchase_foursquare_id": purchaseFoursquareId ?? "",
        ]
        if let bid = checkin.beerLite?.bid { form["bid"] = "\(bid)" }
        if let containerId { form["container_id"] = "\(containerId)" }
        if let v = checkin.venue {
            if let f = v.foursquareId { form["foursquare_id"] = f }
            if let lat = v.lat, let lng = v.lng {
                form["geolat"] = String(format: "%.6f", lat)
                form["geolng"] = String(format: "%.6f", lng)
            }
        }
        return APIRequest(method: .post, path: "/v4/checkin/edit/\(checkin.id)", form: form)
    }

    static func addComment(_ text: String, to checkinId: Int) -> APIRequest {
        APIRequest(method: .post, path: "/v4/checkin/addcomment/\(checkinId)", form: ["comment": text])
    }

    /// Takes the comment's id, not the checkin's.
    static func editComment(_ commentId: Int, text: String) -> APIRequest {
        APIRequest(method: .post, path: "/v4/checkin/editcomment/\(commentId)", form: ["comment": text])
    }

    /// Takes the comment's id, not the checkin's.
    static func deleteComment(_ commentId: Int) -> APIRequest {
        APIRequest(method: .post, path: "/v4/checkin/deletecomment/\(commentId)", form: [:])
    }

    static func checkinView(_ id: Int) -> APIRequest {
        APIRequest(path: "/v4/checkin/view/\(id)")
    }

    /// The beers Untappd's users have given barcode `upc` (digits as printed), most trusted first.
    /// What the official app calls on a scan (documented in untappd-private-api).
    static func checkBarcode(_ upc: String) -> APIRequest {
        APIRequest(path: "/v4/beer/checkbarcodemultiple", query: ["upc": upc])
    }

    /// The rating the signed-in user last gave a beer (`rating_score`, 0 if none). The official
    /// app uses this to prefill its check-in screen. It stays 0 for a few minutes after a
    /// beer's first checkin, until Untappd catches up.
    static func userRating(_ bid: Int) -> APIRequest {
        APIRequest(path: "/v4/beer/userrating/\(bid)")
    }

    /// A beer in full. The docs mark `compact`, `dist_pref`, `lat`, `lng` and `radius` as sent by
    /// the app (the location is for "available near you", which this app doesn't show), so the
    /// location is optional here and the rest is sent as captured.
    static func beerInfo(_ bid: Int, lat: Double? = nil, lng: Double? = nil) -> APIRequest {
        var q = ["compact": "enhanced", "dist_pref": "m", "radius": "10"]
        if let lat, let lng { q["lat"] = String(format: "%.5f", lat); q["lng"] = String(format: "%.5f", lng) }
        return APIRequest(path: "/v4/beer/info/\(bid)", query: q)
    }

    /// Recent checkins of a beer by everyone, newest first, paged with `max_id`. The docs only
    /// show `type=friends` (marked required, though it's the filter); leaving it off is assumed to
    /// mean everyone, as for the venue feed.
    static func beerCheckins(_ bid: Int, friendsOnly: Bool = false, maxId: Int? = nil, limit: Int = 25) -> APIRequest {
        var q = ["limit": "\(limit)"]
        if friendsOnly { q["type"] = "friends" }
        if let maxId { q["max_id"] = "\(maxId)" }
        return APIRequest(path: "/v4/beer/checkins/\(bid)", query: q)
    }

    /// A brewery in full; `collaborations` and the location are as the docs show the app sending.
    static func breweryInfo(_ id: Int) -> APIRequest {
        APIRequest(path: "/v4/brewery/info/\(id)", query: ["collaborations": "true", "dist_pref": "m", "radius": "10"])
    }

    /// A brewery's beers, most popular first. The docs capture the filters but no paging; `offset`
    /// is the public API's parameter for it and is assumed to work here.
    static func breweryBeers(_ id: Int, offset: Int = 0) -> APIRequest {
        var q = ["hasNotHadBefore": "false", "q": "", "showAllBeers": "false", "sort": "most_popular",
                 "styles": "true", "type_id": ""]
        if offset > 0 { q["offset"] = "\(offset)" }
        return APIRequest(path: "/v4/brewery/beer_list/\(id)", query: q)
    }

    /// A brewery's recent checkins by everyone, newest first.
    static func breweryCheckins(_ id: Int, maxId: Int? = nil, limit: Int = 25) -> APIRequest {
        var q = ["limit": "\(limit)"]
        if let maxId { q["max_id"] = "\(maxId)" }
        return APIRequest(path: "/v4/brewery/checkins/\(id)", query: q)
    }

    /// The signed-in user's level on each of these badges (`badge_ids[n]`: the `badge_id`, not the
    /// `user_badge_id`).
    static func badgeStatus(_ badgeIds: [Int]) -> APIRequest {
        var q: [String: String] = [:]
        for (i, id) in badgeIds.enumerated() { q["badge_ids[\(i)]"] = "\(id)" }
        return APIRequest(path: "/v5/badges/status", query: q)
    }

    /// A page of the signed-in user's friends who have a badge (`badge_id`), highest level first.
    /// The docs show the app paging 15 at a time and always sending `q` empty.
    static func friendsBadges(_ badgeId: Int, offset: Int = 0, limit: Int = 15) -> APIRequest {
        var q = ["limit": "\(limit)", "q": "", "sort": "level"]
        if offset > 0 { q["offset"] = "\(offset)" }
        return APIRequest(path: "/v4/badges/friends_badges/\(badgeId)", query: q)
    }

    static let servingTypes = APIRequest(path: "/v4/checkin/serving_types")

    /// The flavour tags people have given a beer most, most used first, with their counts.
    static func beerFlavorProfile(_ bid: Int) -> APIRequest {
        APIRequest(path: "/v4/beer/flavor_profile/\(bid)")
    }

    /// Every flavour tag a checkin can have (about 340), alphabetically. A POST with no fields,
    /// as the official app sends it, though it only reads.
    static let flavorTags = APIRequest(method: .post, path: "/v4/checkin/flavor_profiles", form: [:])


    static func friends(offset: Int = 0, limit: Int = FriendPager.pageSize) -> APIRequest {
        APIRequest(path: "/v4/user/friends", query: ["limit": "\(limit)", "offset": "\(offset)"])
    }

    /// Sends a friend request to a user by id. A POST with no fields. Accounts you follow rather
    /// than befriend (breweries) answer with `request_type: "follow"`. Tried live on 2026-11-18
    /// against a private account that wasn't a friend: `request_type: "request"`,
    /// `friendship_type: "friend"`, and from then on the target's `relationship` reads
    /// `pending_them` (`pending_you` from their side) until they accept.
    static func sendFriendRequest(_ uid: Int) -> APIRequest {
        APIRequest(method: .post, path: "/v4/friend/request/\(uid)", form: [:])
    }

    /// Removes a friend by id, from both sides. Not in the API docs: found by probing on
    /// 2026-11-18 with the old public API's name. A POST with no fields (the first guess; GET was
    /// never tried) answers HTTP 200 `{"meta":{"code":200},"response":{"result":"success"}}`.
    /// Afterwards the person's `relationship` is `none` and `/v4/user/friends` no longer lists
    /// them.
    static func removeFriend(_ uid: Int) -> APIRequest {
        APIRequest(method: .post, path: "/v4/friend/remove/\(uid)", form: [:])
    }

    /// Accepts the incoming friend request from a user, by id (the `uid` in an item of
    /// `GET /v4/user/pending`). Not in the API docs: found by probing on 2026-11-18. A POST with
    /// no fields (the first guess; GET was never tried) answers HTTP 200 with `result: "success"`,
    /// `request_type: "accept"`, `friendship_type: "friend"` and the `target_user`. Afterwards
    /// both sides' `relationship` is `friends`. It also works after a reject (see
    /// `rejectFriendRequest`), though the request is no longer in `/v4/user/pending`.
    static func acceptFriendRequest(_ uid: Int) -> APIRequest {
        APIRequest(method: .post, path: "/v4/friend/accept/\(uid)", form: [:])
    }

    /// Rejects the incoming friend request from a user, by id. Tried live on 2026-11-19 (a POST
    /// with no fields): HTTP 200 `{"result":"success","request_type":"reject",
    /// "friendship_type":"friend","target_user":{…}}`. It is a silent decline: the request leaves
    /// the receiver's `/v4/user/pending` and the receiver then sees the sender's `relationship`
    /// as `ignore`; the sender still sees `pending_them` and can't send another request (HTTP
    /// 500, `invalid_param`, "This request is pending the user's approval."). The receiver can
    /// still `acceptFriendRequest` later.
    static func rejectFriendRequest(_ uid: Int) -> APIRequest {
        APIRequest(method: .post, path: "/v4/friend/reject/\(uid)", form: [:])
    }

    /// The signed-in user's incoming friend requests (not the ones they sent): `count` and
    /// `items`, each `created_at` and a `user` (`uid` is what accept and reject take). Checked
    /// live on 2026-11-19. Nothing in the docs about paging; the test accounts never had more
    /// than one.
    static let pendingFriendRequests = APIRequest(path: "/v4/user/pending")

    static let recentlyTagged = APIRequest(path: "/v4/user/recently_tagged", query: ["friendTaggingLimit": "20"])

    static let userSettings = APIRequest(path: "/v4/account/usersettings")

    /// Changes one setting. `name` is the form field: `account_private`, `is_search`,
    /// `oc_privacy` or `public_toasts`.
    static func updateSetting(_ name: String, _ on: Bool) -> APIRequest {
        APIRequest(method: .post, path: "/v4/account/updatesettings", form: [name: on ? "1" : "0"])
    }

    static func setRatingBump(_ on: Bool) -> APIRequest {
        APIRequest(method: .post, path: "/v4/account/toggle_rating_bump", form: ["rating_bump": on ? "1" : "0"])
    }

    static func setRetroactiveBadges(_ on: Bool) -> APIRequest {
        APIRequest(method: .post, path: "/v4/account/retroactive_badges", form: ["is_retro": on ? "1" : "0"])
    }

    static let parentStyleOptOuts = APIRequest(path: "/v4/account/user_parent_style_opt_outs", query: ["mode": "v2"])

    static func setParentStyle(_ id: Int, enabled: Bool) -> APIRequest {
        APIRequest(method: .post, path: "/v4/account/update_parent_style_opt_outs",
                   form: ["parent_id": "\(id)", "is_enabled": enabled ? "true" : "false"])
    }

    /// `purchaseFoursquareId` is where the beer was bought, which can be set without a venue. It
    /// has to be a Foursquare id: Untappd doesn't reject an Untappd venue id there, but saves
    /// some unrelated place instead.
    static func checkin(beer: Int, foursquareId: String?, lat: Double?, lng: Double?,
                        rating: Double, shout: String, containerId: Int? = nil, taggedUserIds: [Int] = [],
                        purchaseFoursquareId: String? = nil, flavorIds: [Int] = [],
                        isPhoto: Bool = false) -> APIRequest {
        let tz = TimeZone.current
        // No `created_at`: Untappd seems to treat a checkin that gives its own time as backdated
        // and keeps it out of every friend feed (`checkin/recent`), even when the time is now.
        // Without it the server uses the current time. No `request_id` either: the official app
        // sends a MongoDB ObjectId, but Untappd doesn't need one (Metabeer never sends it).
        // See `POST /v4/checkin/add` in untappd-private-api.
        var form = [
            "bid": "\(beer)",
            "rating": rating > 0 ? String(format: "%.2f", rating) : "0",
            "shout": shout,
            "gmt_offset": "\(tz.secondsFromGMT() / 3600)",
            "timezone": tz.identifier,
            "platform": "android",
            "app_theme": "light",
            "is_photo": isPhoto ? "true" : "false",
            "photo_file_ext": "jpg",
            // Format not captured (the one sample was empty); comma-separated user ids is a guess.
            "checkin_tags": taggedUserIds.map(String.init).joined(separator: ","),
            // Tag ids; the one captured sample had a single id. Comma-separated, like `checkin_tags`.
            "flavor_profiles": flavorIds.map(String.init).joined(separator: ","),
        ]
        if let foursquareId { form["foursquare_id"] = foursquareId }
        if let purchaseFoursquareId { form["purchase_foursquare_id"] = purchaseFoursquareId }
        if let containerId { form["container_id"] = "\(containerId)" }
        if let lat, let lng {
            form["geolat"] = String(format: "%.6f", lat)
            form["geolng"] = String(format: "%.6f", lng)
        }
        return APIRequest(method: .post, path: "/v4/checkin/add", form: form)
    }
}

enum DeviceID {
    static var value: String {
        let key = "device_udid"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = (UIDevice.current.identifierForVendor ?? UUID()).uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(v, forKey: key)
        return v
    }
}

