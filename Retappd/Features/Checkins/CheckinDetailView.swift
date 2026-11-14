import SwiftUI

struct CheckinDetailView: View {
    @State private var checkin: Checkin
    @State private var showPhoto = false
    @State private var checkInBeer: BeerLite?
    @State private var editing: Checkin?
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?
    @Environment(DiscoverModel.self) private var discover
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    init(checkin: Checkin) { _checkin = State(initialValue: checkin) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                userHeader
                beerCard
                if let comment = checkin.comment {
                    Text(comment).font(.body).textSelection(.enabled)
                }
                photo
                details
                if !checkin.badges.isEmpty { badges }
                if checkin.toastCount > 0 { toasts }
                if !checkin.comments.isEmpty { comments }
            }
            .padding()
            .padding(.bottom, 60)
        }
        .readableContentWidth()
        .navigationTitle(checkin.beer?.name ?? "Checkin")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let beer = checkin.beerLite {
                Button { checkInBeer = beer } label: {
                    Label("Check in this beer", systemImage: "plus.circle.fill")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .frame(maxWidth: .readableContentWidth)
                .padding(.bottom, 8)
            }
        }
        .sheet(item: $checkInBeer) { CheckInSheet(beer: $0, venue: discover.here.first) }
        .sheet(item: $editing) { CheckInSheet(editing: $0) }
        .toolbar {
            if checkin.isBy(username: auth.username) {
                ToolbarItem(placement: .topBarTrailing) {
                    if deleting {
                        ProgressView()
                    } else {
                        Menu("More", systemImage: "ellipsis") {
                            Button("Edit checkin", systemImage: "pencil") { editing = checkin }
                            Button("Delete checkin", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Delete this checkin?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("This can't be undone.")
        }
        .alert("Couldn't delete the checkin", isPresented: Binding(get: { deleteError != nil },
                                                                  set: { if !$0 { deleteError = nil } })) {
            Button("OK") {}
        } message: {
            Text(deleteError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .checkinEdited)) { n in
            if let c = n.object as? Checkin, c.id == checkin.id { checkin = c }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if let r = try? await cacheThenNetwork(.checkinView(checkin.id), as: CheckinView.self,
                                               onCached: { if let c = $0.checkin { checkin = c } }),
           let c = r.checkin {
            checkin = c
        }
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        do {
            _ = try await UntappdAPI.shared.data(.deleteCheckin(checkin.id))
            NotificationCenter.default.post(name: .checkinDeleted, object: checkin.id)
            dismiss()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    // MARK: Sections

    private var userHeader: some View {
        HStack(spacing: 12) {
            Avatar(url: checkin.user?.avatar, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(checkin.user?.displayName ?? "").font(.headline)
                if let d = checkin.createdAt {
                    Text(d.formatted(date: .abbreviated, time: .shortened)
                         + (Date.now.timeIntervalSince(d) < 86_400 ? " · " + RelativeTime.string(d) : ""))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var beerCard: some View {
        HStack(alignment: .top, spacing: 14) {
            CachedImage(url: checkin.beer?.labelHD ?? checkin.beer?.label, maxPixel: 300)
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(checkin.beer?.name ?? "").font(.title3.bold())
                if let b = checkin.brewery?.name { Text(b).foregroundStyle(.secondary) }
                let meta = [checkin.beer?.style,
                            checkin.beer?.abv.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))% ABV" }]
                    .compactMap { $0 }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary) }
                if let r = checkin.rating { StarRating(rating: r).padding(.top, 2) }
            }
        }
    }

    @ViewBuilder private var photo: some View {
        if let p = checkin.photo, let url = p.large ?? p.medium ?? p.small {
            Button { showPhoto = true } label: {
                CachedImage(url: url, maxPixel: 1400) {
                    CachedImage(url: p.medium ?? p.small, maxPixel: 1000)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $showPhoto) {
                PhotoViewer(url: p.large ?? url, placeholder: p.medium ?? url)
            }
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let v = checkin.venue {
                NavigationLink(value: v) {
                    HStack(spacing: 10) {
                        VenueIcon(venue: v, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(v.name).font(.subheadline.weight(.semibold))
                                if v.isVerified { VerifiedBadge() }
                            }
                            if !v.subtitle.isEmpty { Text(v.subtitle).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let s = checkin.servingType {
                Label { Text(s) } icon: { ServingIcon(name: s, size: 17) }.font(.subheadline)
            }
            if !checkin.flavors.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(checkin.flavors, id: \.self) { f in
                        Text(f).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(.secondarySystemFill), in: Capsule())
                    }
                }
            }
            if !checkin.taggedFriends.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("With").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(checkin.taggedFriends) { UserChip(user: $0) }
                    }
                }
            }
        }
    }

    private var badges: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Badges earned").font(.headline)
            ForEach(checkin.badges) { b in
                HStack(spacing: 10) {
                    CachedImage(url: b.image, maxPixel: 120).frame(width: 36, height: 36).clipShape(Circle())
                    Text(b.name).font(.subheadline)
                }
            }
        }
    }

    private var toasts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🍻 \(checkin.toastCount) \(checkin.toastCount == 1 ? "toast" : "toasts")").font(.headline)
            FlowLayout(spacing: 6) {
                ForEach(checkin.toasters) { UserChip(user: $0) }
            }
        }
    }

    private var comments: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comments").font(.headline)
            ForEach(checkin.comments) { c in
                HStack(alignment: .top, spacing: 10) {
                    Avatar(url: c.user?.avatar, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(c.user?.displayName ?? "").font(.subheadline.weight(.semibold))
                            if let d = c.createdAt {
                                Text(RelativeTime.string(d)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(c.text).font(.subheadline)
                    }
                }
            }
        }
    }
}

struct UserChip: View {
    let user: User

    var body: some View {
        HStack(spacing: 6) {
            Avatar(url: user.avatar, size: 22)
            Text(user.shortName).font(.caption).lineLimit(1)
        }
        .padding(.leading, 2).padding(.trailing, 8).padding(.vertical, 2)
        .background(Color(.secondarySystemFill), in: Capsule())
    }
}

struct StarRating: View {
    let rating: Double
    var size: CGFloat = 16

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(0..<5) { i in
                    let fill = min(max(rating - Double(i), 0), 1)
                    Image(systemName: "star.fill")
                        .foregroundStyle(Color(.systemGray4))
                        .overlay(alignment: .leading) {
                            Image(systemName: "star.fill").foregroundStyle(.orange)
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: size * fill)
                                }
                        }
                        .font(.system(size: size))
                        .frame(width: size, height: size)
                }
            }
            Text(rating.formatted(.number.precision(.fractionLength(2))))
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(rating) out of 5")
    }
}
