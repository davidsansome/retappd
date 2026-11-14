import Foundation
import Observation

/// An infinitely scrolling, cache-first list of checkins (friends feed, or one user's).
@Observable @MainActor
final class CheckinListModel {
    enum Source: Equatable {
        case friends
        case user(String)

        func request(maxId: Int? = nil) -> APIRequest {
            switch self {
            case .friends: .friendFeed(maxId: maxId)
            case .user(let u): .userCheckins(u, maxId: maxId)
            }
        }
    }

    let source: Source
    /// The signed-in user, so their avatar can appear among toasters as soon as they toast.
    var me: User?
    private(set) var items: [Checkin] = []
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    private(set) var reachedEnd = false
    private(set) var error: String?
    /// Bumped at the start of each `reload()`, so views can reload anything they show alongside.
    private(set) var reloads = 0
    /// Bumped by `reload()`. The list scrolls back to the top whenever it changes.
    private(set) var scrollToTopRequests = 0
    private var nextMaxId: Int?
    private var hasLoaded = false
    private var isStale = false

    init(source: Source) { self.source = source }

    /// Call when the list appears: loads it the first time, and reloads it if it was invalidated.
    func loadIfNeeded() async {
        if isStale {
            await reload()
        } else if !hasLoaded {
            hasLoaded = true
            await refresh()
        }
    }

    /// Scrolls the list back to the top without reloading it.
    func scrollToTop() { scrollToTopRequests += 1 }

    /// Marks the list as out of date, so it goes back to the top and refreshes when it next appears.
    func invalidate() { isStale = true }

    /// Goes back to the top and fetches the newest checkins.
    func reload() async {
        isStale = false
        hasLoaded = true
        reloads += 1
        scrollToTopRequests += 1
        await refresh()
        // Scroll again, in case the fresh checkins were put above where the list was.
        scrollToTopRequests += 1
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let page = try await cacheThenNetwork(source.request(), as: CheckinPage.self) { cached in
                if items.isEmpty { apply(cached, replacing: true) }
            }
            merge(fresh: page)
            error = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code != .cancelled { self.error = error.localizedDescription }
        }
    }

    /// Call when a row appears; fetches the next page as the user nears the bottom.
    func onAppear(_ c: Checkin) {
        guard let idx = items.firstIndex(where: { $0.id == c.id }), idx >= items.count - 6 else { return }
        Task { await loadMore() }
    }

    func loadMore() async {
        guard !isLoadingMore, !reachedEnd, let maxId = nextMaxId else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let req = source.request(maxId: maxId)
        do {
            let data = try await UntappdAPI.shared.data(req)
            let page = try UntappdAPI.decode(CheckinPage.self, from: data)
            Task.detached { await ResponseCache.shared.store(data, for: req.cacheKey) }
            let known = Set(items.map(\.id))
            let new = page.checkins.filter { !known.contains($0.id) }
            items += new
            ingest(new)
            if new.isEmpty || page.nextMaxId == nil || page.nextMaxId == maxId { reachedEnd = true }
            nextMaxId = page.nextMaxId
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Optimistically toggles the user's toast, reverting if the server refuses.
    func toggleToast(_ c: Checkin) async {
        guard let i = items.firstIndex(where: { $0.id == c.id }) else { return }
        let before = items[i]
        items[i].youToasted.toggle()
        items[i].toastCount = max(0, items[i].toastCount + (items[i].youToasted ? 1 : -1))
        if let me {
            items[i].toasters.removeAll { $0.id == me.id }
            if items[i].youToasted { items[i].toasters.append(me) }
        }
        do {
            _ = try await UntappdAPI.shared.data(.toggleToast(c.id))
        } catch {
            if let j = items.firstIndex(where: { $0.id == c.id }) { items[j] = before }
            self.error = "Couldn't toast: \(error.localizedDescription)"
        }
    }

    /// Optimistically deletes one of the user's checkins, putting it back if the server refuses.
    func delete(_ c: Checkin) async {
        guard let i = items.firstIndex(where: { $0.id == c.id }) else { return }
        let removed = items.remove(at: i)
        do {
            _ = try await UntappdAPI.shared.data(.deleteCheckin(c.id))
            NotificationCenter.default.post(name: .checkinDeleted, object: c.id)
        } catch {
            if !items.contains(where: { $0.id == c.id }) { items.insert(removed, at: min(i, items.count)) }
            self.error = "Couldn't delete: \(error.localizedDescription)"
        }
    }

    /// Drops a checkin that was deleted elsewhere.
    func remove(id: Int) { items.removeAll { $0.id == id } }

    /// Swaps in a checkin that was edited elsewhere.
    func replace(_ c: Checkin) {
        if let i = items.firstIndex(where: { $0.id == c.id }) { items[i] = c }
    }

    private func apply(_ page: CheckinPage, replacing: Bool) {
        items = page.checkins
        nextMaxId = page.nextMaxId
        reachedEnd = page.checkins.isEmpty
        ingest(page.checkins)
    }

    /// Puts a fresh first page on top, keeping already-loaded older items if the two overlap.
    private func merge(fresh page: CheckinPage) {
        guard let oldestFresh = page.checkins.last?.id, let newestOld = items.first?.id, newestOld >= oldestFresh else {
            apply(page, replacing: true)
            return
        }
        let older = items.filter { $0.id < oldestFresh }
        items = page.checkins + older
        if older.isEmpty { nextMaxId = page.nextMaxId; reachedEnd = page.checkins.isEmpty }
        ingest(page.checkins)
    }

    private func ingest(_ checkins: [Checkin]) {
        ImagePipeline.shared.prefetch(checkins.prefix(10).flatMap { c in
            [c.beer?.label, c.user?.avatar, c.photo?.medium].compactMap { $0 }
        })
        Task.detached(priority: .utility) { await LocalIndex.shared.add(checkins: checkins) }
    }
}

extension Notification.Name {
    /// Posted with the deleted checkin's id (an `Int`) as the object.
    static let checkinDeleted = Notification.Name("checkinDeleted")
    /// Posted with the edited `Checkin` as the object.
    static let checkinEdited = Notification.Name("checkinEdited")
}

extension Checkin {
    /// Whether the signed-in user (`username`) made this checkin, so may edit or delete it.
    func isBy(username: String?) -> Bool {
        guard let username, let name = user?.userName, !name.isEmpty else { return false }
        return name.caseInsensitiveCompare(username) == .orderedSame
    }
}
