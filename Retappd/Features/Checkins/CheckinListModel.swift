import Foundation
import Observation

/// An infinitely scrolling, cache-first list of checkins (friends feed, or one user's).
@Observable @MainActor
final class CheckinListModel {
    enum Source: Equatable {
        case friends
        case user(String)
        case venue(Int, friendsOnly: Bool)
        case beer(Int)
        case brewery(Int)

        func request(maxId: Int? = nil) -> APIRequest {
            switch self {
            case .friends: .friendFeed(maxId: maxId)
            case .user(let u): .userCheckins(u, maxId: maxId)
            case .venue(let id, let friendsOnly): .venueCheckins(id, friendsOnly: friendsOnly, maxId: maxId)
            case .beer(let id): .beerCheckins(id, maxId: maxId)
            case .brewery(let id): .breweryCheckins(id, maxId: maxId)
            }
        }
    }

    /// One line of a grouped list: a time-bucket header, or a checkin under it.
    enum TimelineEntry: Identifiable {
        case header(RelativeTime.Bucket, isFirst: Bool)
        case row(Checkin)

        var id: Int {
            switch self {
            case .header(let b, _): -1 - b.rawValue
            case .row(let c): c.id
            }
        }
    }

    let source: Source
    /// The signed-in user, so their avatar can appear among toasters as soon as they toast.
    var me: User?
    private(set) var items: [Checkin] = [] { didSet { timeline = Self.timeline(of: items) } }
    /// `items` as time-bucket headers ("Today", "This week", …) followed by their rows, built when
    /// the items change rather than on every render of a long list.
    private(set) var timeline: [TimelineEntry] = []
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    private(set) var reachedEnd = false
    private(set) var error: String?
    private(set) var moreError: String?
    /// Bumped at the start of each `reload()`, so views can reload anything they show alongside.
    private(set) var reloads = 0
    /// Bumped by `reload()`. The list scrolls back to the top whenever it changes.
    private(set) var scrollToTopRequests = 0
    private var nextMaxId: Int?
    private var hasLoaded = false
    private var isStale = false
    private var generation = 0
    private var toastingIDs: Set<Int> = []

    typealias FirstPageFetch = @MainActor (_ onCached: (CheckinPage) -> Void) async throws -> CheckinPage
    typealias MorePageFetch = @MainActor (APIRequest) async throws -> Data
    typealias ToastToggle = @MainActor (Int) async throws -> Void

    @ObservationIgnored private let fetchFirstPage: FirstPageFetch
    @ObservationIgnored private let fetchMoreData: MorePageFetch
    @ObservationIgnored private let sendToastToggle: ToastToggle

    init(
        source: Source,
        fetchFirstPage: FirstPageFetch? = nil,
        fetchMoreData: MorePageFetch? = nil,
        sendToastToggle: ToastToggle? = nil
    ) {
        self.source = source
        self.fetchFirstPage = fetchFirstPage ?? { onCached in
            try await cacheThenNetwork(source.request(), as: CheckinPage.self, onCached: onCached)
        }
        self.fetchMoreData = fetchMoreData ?? { req in
            try await UntappdAPI.shared.data(req)
        }
        self.sendToastToggle = sendToastToggle ?? { id in
            _ = try await UntappdAPI.shared.data(.toggleToast(id))
        }
    }

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
        generation += 1
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let page = try await fetchFirstPage { cached in
                if items.isEmpty { apply(cached, replacing: true) }
            }
            merge(fresh: page)
            error = nil
            moreError = nil
        } catch {
            if error.isCancellation {
                retryIfEmpty()
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    /// A first load that was cancelled (the view went away mid-request) shouldn't count, or the
    /// list stays empty for good: let the next `loadIfNeeded()` try again.
    private func retryIfEmpty() {
        if items.isEmpty { hasLoaded = false }
    }

    static func timeline(of items: [Checkin], now: Date = .now) -> [TimelineEntry] {
        var groups: [RelativeTime.Bucket: [Checkin]] = [:]
        for c in items { groups[c.createdAt.map { RelativeTime.Bucket($0, now: now) } ?? .earlier, default: []].append(c) }
        var out: [TimelineEntry] = []
        out.reserveCapacity(items.count + groups.count)
        for bucket in RelativeTime.Bucket.allCases {
            guard let rows = groups[bucket] else { continue }
            out.append(.header(bucket, isFirst: out.isEmpty))
            out += rows.map { .row($0) }
        }
        return out
    }

    /// Call when a row appears; fetches the next page as the user nears the bottom.
    func onAppear(_ c: Checkin) {
        guard moreError == nil else { return }
        guard let idx = items.firstIndex(where: { $0.id == c.id }), idx >= items.count - 6 else { return }
        Task { await loadMore() }
    }

    func loadMore() async {
        guard !isLoadingMore, !reachedEnd, let maxId = nextMaxId else { return }
        let mine = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        let req = source.request(maxId: maxId)
        do {
            let data = try await fetchMoreData(req)
            let page = try UntappdAPI.decode(CheckinPage.self, from: data)
            Task.detached { await ResponseCache.shared.store(data, for: req.cacheKey) }
            guard mine == generation else { return }
            let known = Set(items.map(\.id))
            let new = page.checkins.filter { !known.contains($0.id) }
            items += new
            ingest(new)
            if new.isEmpty || page.nextMaxId == nil || page.nextMaxId == maxId { reachedEnd = true }
            nextMaxId = page.nextMaxId
            moreError = nil
        } catch {
            guard mine == generation else { return }
            if !error.isCancellation {
                self.moreError = error.localizedDescription
            }
        }
    }

    /// Optimistically toggles the user's toast, reverting only toast fields if the server refuses.
    func toggleToast(_ c: Checkin) async {
        guard !toastingIDs.contains(c.id), let i = items.firstIndex(where: { $0.id == c.id }) else { return }
        toastingIDs.insert(c.id)
        defer { toastingIDs.remove(c.id) }
        let wasToasted = items[i].youToasted
        let oldCount = items[i].toastCount
        let oldToasters = items[i].toasters
        items[i].applyToastToggle(me: me)
        do {
            try await sendToastToggle(c.id)
            await ResponseCache.shared.remove(APIRequest.checkinView(c.id).cacheKey)
            if let j = items.firstIndex(where: { $0.id == c.id }) {
                NotificationCenter.default.post(name: .checkinEdited, object: items[j])
            }
        } catch {
            if let j = items.firstIndex(where: { $0.id == c.id }) {
                items[j].revertToast(toasted: wasToasted, count: oldCount, toasters: oldToasters)
            }
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
