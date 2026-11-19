import Foundation

/// The small HTTP client for Retappd's notification relay (see `.claude/notify-contract.md`).
/// Separate from `UntappdAPI`: different server, different auth, and its failures are never
/// shown to the user.

protocol NotifyTransport {
    /// Sends the request and returns the body and HTTP status. Throws only when there was no response.
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

extension URLSession: NotifyTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await self.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Which notification types are wanted. Keys are the contract's.
struct NotifyPrefs: Codable, Equatable {
    var toast = true
    var comment = true
    var tag = true
    var friend = true
}

struct DeviceRegistration: Codable, Equatable {
    var deviceID: String
    var secret: String

    enum CodingKeys: String, CodingKey { case deviceID = "device_id", secret = "device_secret" }
}

/// The body of a PATCH: any subset of fields (all nil is a heartbeat, which encodes as `{}`).
struct DeviceUpdate: Codable, Equatable {
    var untappdToken: String?
    var apnsToken: String?
    var apnsEnv: String?
    var prefs: NotifyPrefs?
    var appVersion: String?

    enum CodingKeys: String, CodingKey {
        case untappdToken = "untappd_token", apnsToken = "apns_token", apnsEnv = "apns_env"
        case prefs, appVersion = "app_version"
    }
}

struct DeviceRegistrationRequest: Codable, Equatable {
    var untappdToken: String
    var apnsToken: String
    var apnsEnv: String
    var prefs: NotifyPrefs
    var appVersion: String

    enum CodingKeys: String, CodingKey {
        case untappdToken = "untappd_token", apnsToken = "apns_token", apnsEnv = "apns_env"
        case prefs, appVersion = "app_version"
    }
}

enum NotifyError: Error, Equatable {
    /// No HTTP response at all (offline, server not deployed yet, ...).
    case unreachable
    case status(Int)
    case badResponse
}

struct NotifyClient {
    var baseURL: URL
    var transport: NotifyTransport = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.waitsForConnectivity = false
        return c
    }())

    func register(_ body: DeviceRegistrationRequest) async throws -> DeviceRegistration {
        let req = try request("POST", "/v1/devices", body: body)
        let data = try await perform(req)
        guard let r = try? JSONDecoder().decode(DeviceRegistration.self, from: data) else { throw NotifyError.badResponse }
        return r
    }

    func update(_ device: DeviceRegistration, _ body: DeviceUpdate) async throws {
        _ = try await perform(try request("PATCH", "/v1/devices/\(device.deviceID)", secret: device.secret, body: body))
    }

    /// 204, 404 and 401 (wrong secret: nothing more we can do) all mean forget the device.
    func delete(_ device: DeviceRegistration) async throws {
        do {
            _ = try await perform(try request("DELETE", "/v1/devices/\(device.deviceID)", secret: device.secret))
        } catch NotifyError.status(404) {
        } catch NotifyError.status(401) {}
    }

    func request(_ method: String, _ path: String, secret: String? = nil, body: (any Encodable)? = nil) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = method
        req.timeoutInterval = 10
        if let secret { req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        let data: Data, status: Int
        do { (data, status) = try await transport.send(req) } catch { throw NotifyError.unreachable }
        guard (200..<300).contains(status) else { throw NotifyError.status(status) }
        return data
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ v: any Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
