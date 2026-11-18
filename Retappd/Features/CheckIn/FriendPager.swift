import Foundation
import os

/// Pages through `GET /v4/user/friends` until every friend is in hand.
///
/// How the endpoint pages (docs/API.md, and checked live): `limit` and `offset` query
/// parameters, `found` is the total across all pages, and `pagination.offset` in the reply is
/// the request's offset plus the number of items returned. The server caps a page below what
/// you ask for: the docs' sample asked for `limit=50` and got 25 back with `found: 108`. So a
/// page shorter than `limit` doesn't mean the list has ended. The pager instead advances by the
/// number of items actually returned and stops when a page is empty, when it has `found`
/// friends, or when a page brings nobody new (in case the server ever ignores `offset`).
enum FriendPager {
    /// What the server returns per page at most (see above); asking for more gains nothing.
    static let pageSize = 25
    /// A backstop against a server that never stops returning new people.
    static let maxPages = 400

    typealias Fetch = (_ offset: Int, _ limit: Int) async throws -> FriendPage

    struct Result {
        /// Everyone fetched, deduplicated, in the server's order (newest friendship first).
        var friends: [Friend]
        /// The total the server reported, if any.
        var found: Int?
        /// Why paging stopped early, if it did. `friends` then holds the pages before the failure.
        var error: Error?
        var isComplete: Bool { error == nil }
    }

    /// Fetches pages until the list ends, calling `onProgress` with everything so far after each
    /// page. A failure stops paging and is returned in `error` alongside what was fetched.
    @MainActor
    static func fetchAll(
        pageSize: Int = pageSize,
        maxPages: Int = maxPages,
        fetch: Fetch,
        onProgress: ([Friend]) -> Void = { _ in }
    ) async -> Result {
        var collected: [Friend] = []
        var seen = Set<Int>()
        var found: Int?
        var offset = 0
        for _ in 0..<maxPages {
            let page: FriendPage
            do {
                page = try await fetch(offset, pageSize)
            } catch {
                return Result(friends: collected, found: found, error: error)
            }
            if let f = page.found { found = f }
            let fresh = page.friends.filter { seen.insert($0.id).inserted }
            collected += fresh
            if !fresh.isEmpty { onProgress(collected) }
            if page.friends.isEmpty || fresh.isEmpty { break }
            if let found, collected.count >= found { break }
            offset += page.friends.count
        }
        return Result(friends: collected, found: found, error: nil)
    }
}

extension FriendPager {
    static let log = Logger(subsystem: "com.davidsansome.retappd", category: "friends")

    /// Fetches one page from the network, caches it and logs the raw sizes the server reported.
    static func networkPage(offset: Int, limit: Int) async throws -> FriendPage {
        let req = APIRequest.friends(offset: offset, limit: limit)
        let data = try await UntappdAPI.shared.data(req)
        let page = try UntappdAPI.decode(FriendPage.self, from: data)
        let meta = try? UntappdAPI.decode(PageMeta.self, from: data)
        log.info("""
            friends page: asked offset=\(offset) limit=\(limit); got items=\(page.friends.count) \
            count=\(meta?.count ?? -1) found=\(page.found ?? -1) next offset=\(meta?.nextOffset ?? -1)
            """)
        await ResponseCache.shared.store(data, for: req.cacheKey)
        return page
    }

    /// Reads one page from the response cache, throwing when it isn't there.
    static func cachedPage(offset: Int, limit: Int) async throws -> FriendPage {
        guard let p = await cachedValue(.friends(offset: offset, limit: limit), as: FriendPage.self) else {
            throw CacheMiss()
        }
        return p
    }

    struct CacheMiss: Error {}

    /// The paging fields `FriendPage` doesn't keep, read only for logging.
    private struct PageMeta: Decodable {
        var count: Int?
        var nextOffset: Int?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            count = c.int("count")
            nextOffset = c.nested("pagination")?.int("offset")
        }
    }
}

extension FriendPage {
    init(friends: [Friend], found: Int?) {
        self.friends = friends
        self.found = found
    }
}
