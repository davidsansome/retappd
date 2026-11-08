import SwiftUI
import UIKit
import CryptoKit

/// Memory + disk image cache with request de-duplication and off-main decoding.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSURL, UIImage>()
    private let dir: URL
    private let lock = NSLock()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    init() {
        memory.totalCostLimit = 120 << 20
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = URLSessionConfiguration.default
        c.urlCache = nil
        c.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: c)
    }

    /// Synchronous memory lookup so cached images render on the first frame.
    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    private func file(_ url: URL) -> URL {
        dir.appendingPathComponent(SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined())
    }

    func image(_ url: URL, maxPixel: CGFloat = 800) async -> UIImage? {
        if let m = cached(url) { return m }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let t = inFlight[url] { return t }
            let t = Task.detached(priority: .userInitiated) { [self] () -> UIImage? in
                let path = file(url)
                var data = try? Data(contentsOf: path)
                if data == nil, let (d, r) = try? await session.data(from: url),
                   (r as? HTTPURLResponse)?.statusCode == 200 {
                    data = d
                    try? d.write(to: path, options: .atomic)
                }
                defer { _ = lock.withLock { inFlight.removeValue(forKey: url) } }
                guard let data, let img = Self.decode(data, maxPixel: maxPixel) else { return nil }
                memory.setObject(img, forKey: url as NSURL, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4))
                return img
            }
            inFlight[url] = t
            return t
        }
        return await task.value
    }

    func prefetch(_ urls: [URL]) {
        for u in urls where cached(u) == nil { Task.detached(priority: .utility) { _ = await self.image(u) } }
    }

    private static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct CachedImage<Placeholder: View>: View {
    let url: URL?
    var maxPixel: CGFloat = 400
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var loaded: (url: URL, image: UIImage)?

    var body: some View {
        let img = (loaded?.url == url ? loaded?.image : nil) ?? url.flatMap { ImagePipeline.shared.cached($0) }
        Group {
            if let img {
                Image(uiImage: img).resizable()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { return }
            // Always set state, even on a cache hit: the body may have rendered before the image
            // landed in memory, and nothing else would trigger a re-render.
            if let i = await ImagePipeline.shared.image(url, maxPixel: maxPixel) { loaded = (url, i) }
        }
    }
}

extension CachedImage where Placeholder == Color {
    init(url: URL?, maxPixel: CGFloat = 400) {
        self.init(url: url, maxPixel: maxPixel) { Color(.secondarySystemFill) }
    }
}
