import XCTest
import UserNotifications

final class NotificationImageAttachmentTests: XCTestCase {
    private let validURL = URL(string: "https://assets.untappd.com/site/beer_logos/beer-6755412_99dd9_sm.jpeg")!
    private let validJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
    private let validPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

    func testImageURLExtractionAcceptsHTTPSAndRejectsInvalid() {
        XCTAssertEqual(
            NotificationImageAttachment.imageURL(from: ["retappd": ["image_url": validURL.absoluteString]]),
            validURL
        )
        XCTAssertNil(NotificationImageAttachment.imageURL(from: ["retappd": ["image_url": "http://assets.untappd.com/a.jpg"]]))
        XCTAssertNil(NotificationImageAttachment.imageURL(from: ["retappd": ["image_url": "not a url"]]))
        XCTAssertNil(NotificationImageAttachment.imageURL(from: ["retappd": ["type": "toast"]]))
        XCTAssertNil(NotificationImageAttachment.imageURL(from: [:]))
    }

    func testFileExtensionDetectionFromMagicBytesMIMEAndPath() {
        let noExt = URL(string: "https://assets.untappd.com/image")!
        XCTAssertEqual(NotificationImageAttachment.fileExtension(mimeType: nil, url: noExt, data: validJPEG), "jpg")
        XCTAssertEqual(NotificationImageAttachment.fileExtension(mimeType: "image/png; charset=binary", url: noExt, data: validPNG), "png")
        XCTAssertEqual(NotificationImageAttachment.fileExtension(mimeType: "image/jpeg", url: noExt, data: Data([0x00, 0x01])), "jpg")
        XCTAssertEqual(NotificationImageAttachment.fileExtension(mimeType: "application/octet-stream", url: validURL, data: Data([0x00, 0x01])), "jpg")
        // Non-image MIME types and unsupported image types (e.g. WebP) are rejected even if the URL ends in .jpeg.
        XCTAssertNil(NotificationImageAttachment.fileExtension(mimeType: "text/html", url: validURL, data: Data("<html>".utf8)))
        XCTAssertNil(NotificationImageAttachment.fileExtension(mimeType: "image/webp", url: validURL, data: Data("RIFF\0\0\0\0WEBP".utf8)))
        XCTAssertNil(NotificationImageAttachment.fileExtension(mimeType: nil, url: noExt, data: Data([0x00, 0x01])))
    }

    func testAttachmentCreatedFromValidImageResponse() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let jpeg = validJPEG
        let attachment = await NotificationImageAttachment.attachment(for: validURL, directory: dir) { url in
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"])!
            return (jpeg, resp)
        }
        XCTAssertNotNil(attachment)
        XCTAssertEqual(attachment?.url.pathExtension, "jpg")
    }

    func testAttachmentReturnsNilOnHTTPErrorEmptyOversizedOrNonImage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let jpeg = validJPEG
        let http404 = await NotificationImageAttachment.attachment(for: validURL, directory: dir) { url in
            (jpeg, HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertNil(http404)

        let empty = await NotificationImageAttachment.attachment(for: validURL, directory: dir) { url in
            (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"])!)
        }
        XCTAssertNil(empty)

        let html = await NotificationImageAttachment.attachment(for: validURL, directory: dir) { url in
            (Data("<html>oops</html>".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!)
        }
        XCTAssertNil(html)

        let huge = await NotificationImageAttachment.attachment(for: validURL, directory: dir) { url in
            (Data(count: NotificationImageAttachment.maxBytes + 1), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"])!)
        }
        XCTAssertNil(huge)

        let networkErr = await NotificationImageAttachment.attachment(for: validURL, directory: dir) { _ in
            throw URLError(.timedOut)
        }
        XCTAssertNil(networkErr)
    }
}
