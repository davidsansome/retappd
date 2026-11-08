import Foundation
import CryptoKit

/// Raw response bodies, keyed by request, in memory and on disk. Nothing is ever treated as
/// too old to show: callers display whatever's here immediately and replace it when the
/// network answers.
actor ResponseCache {
    static let shared = ResponseCache()

    private let dir: URL
    private let memory = NSCache<NSString, NSData>()

    init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("responses", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.totalCostLimit = 32 << 20
    }

    private func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(hash)
    }

    func data(for key: String) -> Data? {
        if let d = memory.object(forKey: key as NSString) { return d as Data }
        guard let d = try? Data(contentsOf: file(key)) else { return nil }
        memory.setObject(d as NSData, forKey: key as NSString, cost: d.count)
        return d
    }

    func store(_ data: Data, for key: String) {
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        try? data.write(to: file(key), options: .atomic)
    }

    func remove(_ key: String) {
        memory.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: file(key))
    }

    func removeAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Stale-while-revalidate: starts the network request, concurrently reads the cache and
/// hands any cached value to `onCached` (normally long before the network returns), then
/// returns the fresh value and stores it.
@MainActor
func cacheThenNetwork<T: Decodable>(
    key: String,
    decode: @escaping @Sendable (Data) throws -> T,
    fetch: @escaping @Sendable () async throws -> Data,
    onCached: (T) -> Void
) async throws -> T {
    let network = Task.detached(priority: .userInitiated) { try await fetch() }
    let cached: T? = await Task.detached(priority: .userInitiated) {
        guard let d = await ResponseCache.shared.data(for: key) else { return nil as T? }
        return try? decode(d)
    }.value
    if let cached, !Task.isCancelled { onCached(cached) }

    let data = try await withTaskCancellationHandler {
        try await network.value
    } onCancel: { network.cancel() }
    let value = try await Task.detached { try decode(data) }.value
    await ResponseCache.shared.store(data, for: key)
    return value
}

/// Convenience for Untappd API requests.
@MainActor
func cacheThenNetwork<T: Decodable>(
    _ request: APIRequest,
    as type: T.Type = T.self,
    key: String? = nil,
    onCached: (T) -> Void
) async throws -> T {
    try await cacheThenNetwork(
        key: key ?? request.cacheKey,
        decode: { try UntappdAPI.decode(T.self, from: $0) },
        fetch: { try await UntappdAPI.shared.data(request) },
        onCached: onCached)
}

/// Reads a cached Untappd response without touching the network.
func cachedValue<T: Decodable>(_ request: APIRequest, as type: T.Type = T.self) async -> T? {
    guard let d = await ResponseCache.shared.data(for: request.cacheKey) else { return nil }
    return try? UntappdAPI.decode(T.self, from: d)
}
