import SwiftUI
import UIKit

/// Memory + disk image cache with request de-duplication and off-main decoding.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
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

    private func cacheKey(_ url: URL, maxPixel: CGFloat) -> String {
        "\(url.absoluteString)#\(Int(maxPixel.rounded()))"
    }

    /// Synchronous memory lookup so cached images render on the first frame.
    func cached(_ url: URL, maxPixel: CGFloat = 800) -> UIImage? {
        memory.object(forKey: cacheKey(url, maxPixel: maxPixel) as NSString)
    }

    private func file(_ url: URL) -> URL {
        dir.appendingPathComponent(url.absoluteString.sha256Hex)
    }

    func image(_ url: URL, maxPixel: CGFloat = 800) async -> UIImage? {
        if let m = cached(url, maxPixel: maxPixel) { return m }
        let key = cacheKey(url, maxPixel: maxPixel)
        let task: Task<UIImage?, Never> = lock.withLock {
            if let t = inFlight[key] { return t }
            let t = Task.detached(priority: .userInitiated) { [self] () -> UIImage? in
                defer { _ = lock.withLock { inFlight.removeValue(forKey: key) } }
                let path = file(url)
                var img: UIImage?
                if let diskData = try? Data(contentsOf: path) {
                    if let decoded = Self.decode(diskData, maxPixel: maxPixel) {
                        img = decoded
                    } else {
                        try? FileManager.default.removeItem(at: path)
                    }
                }
                if img == nil, let (d, r) = try? await session.data(from: url),
                   (r as? HTTPURLResponse)?.statusCode == 200,
                   let decoded = Self.decode(d, maxPixel: maxPixel) {
                    try? d.write(to: path, options: .atomic)
                    img = decoded
                }
                guard let img else { return nil }
                memory.setObject(img, forKey: key as NSString, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4))
                return img
            }
            inFlight[key] = t
            return t
        }
        return await task.value
    }

    func prefetch(_ urls: [URL], maxPixel: CGFloat = 800) {
        for u in urls where cached(u, maxPixel: maxPixel) == nil {
            Task.detached(priority: .utility) { _ = await self.image(u, maxPixel: maxPixel) }
        }
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
        let img = (loaded?.url == url ? loaded?.image : nil) ?? url.flatMap { ImagePipeline.shared.cached($0, maxPixel: maxPixel) }
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
        self.init(url: url, maxPixel: maxPixel) { Taproom.glassInside }
    }
}
