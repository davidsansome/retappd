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
        let meta = (try? JSONDecoder().decode(Envelope<Ignored>.self, from: data))?.meta
        if status == 401 || meta?.code == 401 || meta?.errorType == "invalid_auth" {
            if token != nil { onUnauthorized?() }
            throw APIError.unauthorized
        }
        if let meta, meta.code != 200 {
            throw APIError.server(code: meta.code, detail: meta.errorDetail)
        }
        guard (200..<300).contains(status) else { throw APIError.http(status) }
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

    static func userCheckins(_ username: String, maxId: Int? = nil, limit: Int = 25) -> APIRequest {
        var q = ["limit": "\(limit)"]
        if let maxId { q["max_id"] = "\(maxId)" }
        return APIRequest(path: "/v4/user/checkins/\(username)", query: q)
    }

    static func userInfo(_ username: String) -> APIRequest {
        APIRequest(path: "/v4/user/info/\(username)", query: ["compact": "true"])
    }

    static func venuesAround(lat: Double, lng: Double, query: String = "", limit: Int = 25) -> APIRequest {
        APIRequest(path: "/v4/venue/around", query: [
            "lat": String(format: "%.6f", lat), "lng": String(format: "%.6f", lng),
            "limit": "\(limit)", "dist_pref": "m", "q": query, "location": "",
        ])
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

    static func venueCheckins(_ venueId: Int, friendsOnly: Bool = false, limit: Int = 25) -> APIRequest {
        var q = ["limit": "\(limit)"]
        if friendsOnly { q["type"] = "friends" }
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

    static func deleteCheckin(_ id: Int) -> APIRequest {
        APIRequest(method: .post, path: "/v4/checkin/delete/\(id)", form: [:])
    }

    /// Changes a checkin's rating, comment and serving type, sending its beer and venue back
    /// unchanged as the official app does. Untappd treats an empty `shout`, `checkin_tags` or
    /// `flavor_profiles` as "leave as is", so a comment can be changed but not cleared.
    static func editCheckin(_ checkin: Checkin, rating: Double, shout: String, containerId: Int?) -> APIRequest {
        let tz = TimeZone.current
        var form = [
            "rating": rating > 0 ? String(format: "%.2f", rating) : "0",
            "shout": shout,
            "checkin_tags": "",
            "flavor_profiles": "",
            "is_photo": "false",
            "gmt_offset": "\(tz.secondsFromGMT() / 3600)",
            "timezone": tz.identifier,
            "request_id": requestID(),
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

    /// The 24-hex-digit id the official app sends with checkins and edits.
    private static func requestID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24).description
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

    static let servingTypes = APIRequest(path: "/v4/checkin/serving_types")

    static func friends(offset: Int = 0, limit: Int = 50) -> APIRequest {
        APIRequest(path: "/v4/user/friends", query: ["limit": "\(limit)", "offset": "\(offset)"])
    }

    static let recentlyTagged = APIRequest(path: "/v4/user/recently_tagged", query: ["friendTaggingLimit": "20"])

    static func checkin(beer: Int, foursquareId: String?, lat: Double?, lng: Double?,
                        rating: Double, shout: String, containerId: Int? = nil, taggedUserIds: [Int] = []) -> APIRequest {
        let tz = TimeZone.current
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var form = [
            "bid": "\(beer)",
            "rating": rating > 0 ? String(format: "%.2f", rating) : "0",
            "shout": shout,
            "gmt_offset": "\(tz.secondsFromGMT() / 3600)",
            "timezone": tz.identifier,
            "created_at": df.string(from: .now),
            "platform": "android",
            "app_theme": "light",
            "is_photo": "false",
            // Format not captured (the one sample was empty); comma-separated user ids is a guess.
            "checkin_tags": taggedUserIds.map(String.init).joined(separator: ","),
            "request_id": requestID(),
        ]
        if let foursquareId { form["foursquare_id"] = foursquareId }
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

