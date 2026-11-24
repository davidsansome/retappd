import SwiftUI

/// Which of the signed-in user's friends have checked in a beer, grouped by friend, from every
/// page of `GET /v4/beer/checkins/{bid}?type=friends`.
///
/// Not verified against a live response: that the friends feed pages with `max_id` to the end
/// like the public one, and whether it leaves out the signed-in user's own check-ins (they are
/// dropped here in case it doesn't).
@Observable @MainActor
final class FriendRatingsModel {
    /// One friend's check-ins of the beer, newest first.
    struct Friend: Identifiable, Equatable {
        let user: User
        let checkins: [Checkin]

        var id: Int { user.id }
        /// The check-ins that have a rating.
        var ratedCount: Int { checkins.lazy.filter { $0.rating != nil }.count }
        /// Their average over the check-ins they rated; nil if they rated none.
        var rating: Double? {
            let ratings = checkins.compactMap(\.rating)
            return ratings.isEmpty ? nil : ratings.reduce(0, +) / Double(ratings.count)
        }
        var latest: Date? { checkins.compactMap(\.createdAt).max() }
    }

    /// Fetches one page: the first (`maxId` nil) cache-first, the rest from the network.
    typealias PageFetch = @MainActor (_ maxId: Int?, _ onCached: (CheckinPage) -> Void) async throws -> CheckinPage

    /// Stops paging after this many pages (25 check-ins each), in case the feed never ends.
    static let maxPages = 20

    let beer: BeerLite
    /// The signed-in user's id, so their own check-ins are left out if the feed includes them.
    var meID: Int? { didSet { regroup() } }
    private(set) var friends: [Friend] = []
    /// Friends' average rating and how many ratings it's from, as the feed reports them.
    private(set) var ratingScore: Double?
    private(set) var ratingCount: Int?
    private(set) var loaded = false
    private(set) var isLoading = false
    private(set) var error: String?
    /// True when paging stopped at `maxPages` with more to come.
    private(set) var truncated = false
    private var checkins: [Checkin] = [] { didSet { regroup() } }
    private var generation = 0
    @ObservationIgnored private let fetchPage: PageFetch

    init(beer: BeerLite, meID: Int? = nil, fetchPage: PageFetch? = nil) {
        self.beer = beer
        self.meID = meID
        self.fetchPage = fetchPage ?? { maxId, onCached in
            let req = APIRequest.beerCheckins(beer.bid, friendsOnly: true, maxId: maxId)
            if maxId == nil {
                return try await cacheThenNetwork(req, as: CheckinPage.self, onCached: onCached)
            }
            return try await UntappdAPI.shared.fetch(req, as: CheckinPage.self)
        }
    }

    /// Loads every page of friends' check-ins. Calling it again starts over.
    func load() async {
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        do {
            let first = try await fetchPage(nil) { cached in
                if self.checkins.isEmpty { self.apply(cached, to: []) }
            }
            guard mine == generation else { return }
            var all = apply(first, to: [])
            var maxId = first.nextMaxId
            var pages = 1
            truncated = false
            while let m = maxId, !first.checkins.isEmpty {
                guard pages < Self.maxPages else { truncated = true; break }
                let page = try await fetchPage(m) { _ in }
                guard mine == generation else { return }
                let known = Set(all.map(\.id))
                let new = page.checkins.filter { !known.contains($0.id) }
                if new.isEmpty { break }
                all += new
                checkins = all
                pages += 1
                maxId = page.nextMaxId == m ? nil : page.nextMaxId
            }
            error = nil
            loaded = true
        } catch {
            guard mine == generation else { return }
            if !error.isCancellation {
                self.error = error.localizedDescription
                loaded = true
            }
        }
    }

    @discardableResult
    private func apply(_ page: CheckinPage, to existing: [Checkin]) -> [Checkin] {
        ratingScore = page.ratingScore
        ratingCount = page.ratingCount
        checkins = existing + page.checkins
        return checkins
    }

    private func regroup() { friends = Self.group(checkins, excluding: meID) }

    /// Groups check-ins by who made them, newest check-in first within each friend, and friends
    /// by their newest check-in. Check-ins with no user, or by `meID`, are left out.
    static func group(_ checkins: [Checkin], excluding meID: Int? = nil) -> [Friend] {
        var order: [Int] = []
        var users: [Int: User] = [:]
        var byUser: [Int: [Checkin]] = [:]
        for c in checkins {
            guard let u = c.user, u.id != meID else { continue }
            if byUser[u.id] == nil { order.append(u.id); users[u.id] = u }
            byUser[u.id, default: []].append(c)
        }
        let friends = order.compactMap { id -> Friend? in
            guard let user = users[id], let list = byUser[id] else { return nil }
            return Friend(user: user, checkins: list.sorted { ($0.createdAt ?? .distantPast, $0.id) > ($1.createdAt ?? .distantPast, $1.id) })
        }
        // Stable: friends whose newest check-ins tie keep the feed's order.
        return friends.enumerated().sorted { a, b in
            let (da, db) = (a.element.latest ?? .distantPast, b.element.latest ?? .distantPast)
            return da != db ? da > db : a.offset < b.offset
        }.map(\.element)
    }
}

/// The friends who have had a beer: each one's rating, and where and when they checked it in.
/// Pushed from the Friends row of the beer page's ratings card with `BeerBreweryRoute.friendRatings`.
struct FriendRatingsView: View {
    @State private var model: FriendRatingsModel
    /// Tags this page's links, so its rows only show as selected for checkins it opened itself.
    @State private var listID = UUID()
    @Environment(DiscoverModel.self) private var discover

    /// `model` is for tests and previews, to show the page without the network.
    init(beer: BeerLite, model: FriendRatingsModel? = nil) {
        _model = State(initialValue: model ?? FriendRatingsModel(beer: beer))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                header
                content
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .taproomScreen()
        .taproomScrollTitle("Friends' ratings")
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task {
            model.meID = discover.me?.id
            if !model.loaded, !model.isLoading { await Task { await model.load() }.value }
        }
        .refreshable { await model.load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.beer.brewery).font(.subheadline).foregroundStyle(Taproom.muted).lineLimit(1)
                Text(model.beer.name)
                    .font(.system(size: 26, weight: .heavy))
                    .tracking(-0.4)
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
                Text("Friends' ratings").font(.footnote).foregroundStyle(Taproom.muted).padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let r = model.ratingScore {
                VStack(alignment: .trailing, spacing: 2) {
                    TaproomRating(rating: r, size: 34)
                    if let n = model.ratingCount, n > 0 {
                        Text(n == 1 ? "1 rating" : "\(n.formatted()) ratings")
                            .font(.caption).foregroundStyle(Taproom.muted)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("friendRatings.average")
            }
        }
    }

    // MARK: Friends

    @ViewBuilder private var content: some View {
        ForEach(model.friends) { friend in
            FriendRatingCard(friend: friend, listID: listID)
        }
        if model.friends.isEmpty && model.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
        } else if let e = model.error {
            ErrorRow(message: e) { Task { await model.load() } }
        } else if model.loaded && model.friends.isEmpty {
            Text("None of your friends have checked in this beer yet.")
                .font(.callout).foregroundStyle(Taproom.muted)
                .accessibilityIdentifier("friendRatings.empty")
        } else if model.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
        } else if model.truncated {
            Text("Showing your friends' latest check-ins only.")
                .font(.footnote).foregroundStyle(Taproom.muted)
        }
    }
}

/// One friend: who (opening their profile) and their rating, then a row per check-in with where
/// and when, each opening that check-in.
private struct FriendRatingCard: View {
    let friend: FriendRatingsModel.Friend
    let listID: UUID

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(value: friend.user) { person }
                .buttonStyle(TaproomRowStyle())
                .accessibilityHint("Opens their profile")
            ForEach(friend.checkins) { c in
                Rectangle().fill(Taproom.border).frame(height: 1)
                NavigationLink(value: CheckinRoute(checkin: c, listID: listID)) { CheckinLine(checkin: c) }
                    .buttonStyle(TaproomRowStyle())
                    .accessibilityHint("Opens the check-in")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .taproomCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("friendRatings.friend.\(friend.id)")
    }

    private var person: some View {
        HStack(spacing: 12) {
            Avatar(url: friend.user.avatar, size: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(friend.user.displayName).font(.body.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.footnote).foregroundStyle(Taproom.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let r = friend.rating {
                VStack(alignment: .trailing, spacing: 0) {
                    TaproomRating(rating: r, size: 26)
                    if friend.ratedCount > 1 {
                        Text("Average of \(friend.ratedCount.formatted())").font(.caption2).foregroundStyle(Taproom.muted)
                    }
                }
            } else {
                Text("Not rated").font(.system(size: 17, weight: .heavy)).tracking(-0.3).foregroundStyle(Taproom.muted)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(Taproom.glassRim)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Taproom.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts = ["@" + friend.user.userName]
        let n = friend.checkins.count
        parts.append(n == 1 ? "1 check-in" : "\(n.formatted()) check-ins")
        return parts.joined(separator: " · ")
    }
}

/// A check-in within a friend's card: where (venue and city), when, and its rating.
private struct CheckinLine: View {
    let checkin: Checkin

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.place(of: checkin) ?? "No location")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(checkin.venue == nil ? Taproom.muted : Taproom.ink)
                    .lineLimit(2)
                if let when = Self.when(of: checkin) {
                    Text(when).font(.footnote).foregroundStyle(Taproom.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let r = checkin.rating {
                TaproomRating(rating: r, size: 20)
            } else {
                Text("Not rated").font(.footnote).foregroundStyle(Taproom.muted)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(Taproom.glassRim)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Taproom.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    /// "The Local, Melbourne"; the city is left off when the name already ends with it.
    static func place(of c: Checkin) -> String? {
        guard let v = c.venue, !v.name.isEmpty else { return nil }
        guard let city = v.city, !city.isEmpty, !v.name.localizedCaseInsensitiveContains(city) else { return v.name }
        return "\(v.name), \(city)"
    }

    /// "12 Nov 2026 · Draft".
    static func when(of c: Checkin) -> String? {
        let parts = [c.createdAt?.formatted(date: .abbreviated, time: .shortened), c.servingType].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
