import Foundation
import UserNotifications

/// Downloads and attaches the image specified in a push notification's `retappd.image_url` field.
enum NotificationImageAttachment {
    static let maxBytes = 5 * 1024 * 1024

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 15
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func defaultFetch(_ url: URL) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(from: url)
        if response.expectedContentLength > Int64(maxBytes) {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            if data.count >= maxBytes {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return (data, response)
    }

    /// Extracts a valid HTTPS image URL from `userInfo["retappd"]["image_url"]`.
    static func imageURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let retappd = userInfo["retappd"] as? [String: Any],
              let raw = retappd["image_url"] as? String,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// Picks an iOS-supported image file extension from magic bytes, MIME type, or URL path.
    /// Returns nil for non-image MIME types (e.g. HTML error pages) or unrecognised formats.
    static func fileExtension(mimeType: String?, url: URL, data: Data) -> String? {
        let mime = mimeType?.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if let mime, !mime.isEmpty, mime != "application/octet-stream", !mime.hasPrefix("image/") {
            return nil
        }

        if let magic = magicExtension(data) {
            return magic
        }

        switch mime {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case nil, "", "application/octet-stream": break
        default: return nil
        }

        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "jpg"
        case "png": return "png"
        case "gif": return "gif"
        case "heic": return "heic"
        default: return nil
        }
    }

    private static func magicExtension(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "jpg"
        }
        if bytes.count >= 8, bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return "png"
        }
        if bytes.count >= 4, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
            return "gif"
        }
        return nil
    }

    /// Downloads `url` and creates a `UNNotificationAttachment`, returning nil on any failure.
    static func attachment(
        for url: URL,
        directory: URL = FileManager.default.temporaryDirectory,
        fetch: @escaping @Sendable (URL) async throws -> (Data, URLResponse) = defaultFetch
    ) async -> UNNotificationAttachment? {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        guard let (data, response) = try? await fetch(url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        guard !Task.isCancelled else { return nil }
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        guard let ext = fileExtension(mimeType: response.mimeType, url: url, data: data) else { return nil }

        let id = UUID().uuidString
        let fileURL = directory.appendingPathComponent("\(id).\(ext)")
        do {
            try data.write(to: fileURL, options: .atomic)
            return try UNNotificationAttachment(identifier: id, url: fileURL, options: nil)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }
}
