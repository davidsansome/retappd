import Foundation
import Observation

/// The paged list behind the Notifications screen: `GET /v4/notifications`, newest first.
///
/// Paging is guarded so it can't cascade: a page is only requested from a row that is one of the
/// last few loaded, never while one is already loading, never after the last page, and never
/// again on its own after a failure (the footer's Retry does that).
@Observable @MainActor
final class NotificationsModel {
    typealias Fetch = @MainActor (_ offset: Int, _ limit: Int) async throws -> NotificationPage

    static let pageSize = 25
    /// A row this close to the end of what's loaded asks for the next page.
    static let prefetchDistance = 5

    private(set) var items: [NotificationItem] = []
    /// The first page (or a refresh) is loading.
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var reachedEnd = false
    private(set) var hasLoaded = false
    /// Why the first page failed.
    private(set) var error: String?
    /// Why a later page failed. While it's set, scrolling doesn't retry.
    private(set) var moreError: String?

    @ObservationIgnored private let fetch: Fetch
    /// Entries the server has sent so far, including any that couldn't be read: the next `offset`.
    private var loadedRaw = 0
    /// Bumped by each refresh, so a page that was loading before it is dropped.
    private var generation = 0

    init(fetch: @escaping Fetch = { offset, limit in
        try await UntappdAPI.shared.fetch(.notifications(offset: offset, limit: limit), as: NotificationPage.self)
    }) {
        self.fetch = fetch
    }

    /// Loads the newest page, replacing what's shown. Keeps the old list if it fails. Returns
    /// whether the list is now fresh from the server.
    @discardableResult
    func refresh() async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        isLoadingMore = false
        generation += 1
        let mine = generation
        defer { if mine == generation { isLoading = false } }
        do {
            let page = try await fetch(0, Self.pageSize)
            guard mine == generation else { return false }
            items = Self.unique(page.items)
            loadedRaw = page.rawCount
            reachedEnd = !page.hasMore
            hasLoaded = true
            error = nil
            moreError = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard mine == generation else { return false }
            if (error as? URLError)?.code != .cancelled { self.error = error.localizedDescription }
            return false
        }
    }

    /// Call when a row appears.
    func onAppear(_ item: NotificationItem) {
        guard shouldLoadMore(after: item) else { return }
        Task { await loadMore() }
    }

    /// Whether `item` appearing should fetch the next page.
    func shouldLoadMore(after item: NotificationItem) -> Bool {
        guard hasLoaded, !isLoading, !isLoadingMore, !reachedEnd, moreError == nil,
              let i = items.firstIndex(where: { $0.id == item.id }) else { return false }
        return i >= items.count - Self.prefetchDistance
    }

    func loadMore() async {
        guard hasLoaded, !isLoading, !isLoadingMore, !reachedEnd else { return }
        isLoadingMore = true
        moreError = nil
        let mine = generation
        defer { if mine == generation { isLoadingMore = false } }
        do {
            let page = try await fetch(loadedRaw, Self.pageSize)
            guard mine == generation else { return }
            // An item with new activity moves to the top, so paging by offset can repeat one.
            items = Self.unique(items + page.items)
            loadedRaw += page.rawCount
            reachedEnd = !page.hasMore || page.rawCount == 0
        } catch is CancellationError {
        } catch {
            guard mine == generation else { return }
            if (error as? URLError)?.code != .cancelled { moreError = error.localizedDescription }
        }
    }

    /// The newest activity among the loaded items.
    var newest: Date? { items.compactMap(\.createdAt).max() }

    static func unique(_ items: [NotificationItem]) -> [NotificationItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
