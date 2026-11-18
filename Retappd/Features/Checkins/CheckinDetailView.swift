import SwiftUI
import UIKit

struct CheckinDetailView: View {
    @State private var checkin: Checkin
    /// The signed-in user, shown on comments while they post.
    let me: User?
    @State private var showPhoto = false
    @State private var checkInBeer: BeerLite?
    /// The checkin being edited in the check-in sheet.
    @State private var editing: Checkin?
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var draft = ""
    @State private var pending: [PendingComment] = []
    @State private var confirmDeleteComment: Checkin.Comment?
    /// The comment whose text is in the composer for editing, if any.
    @State private var editingComment: Checkin.Comment?
    /// What was in the composer before editing a comment started, restored afterwards.
    @State private var draftBeforeEditing = ""
    @State private var error: String?
    @FocusState private var composerFocused: Bool
    @Environment(DiscoverModel.self) private var discover
    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    init(checkin: Checkin, me: User? = nil) {
        _checkin = State(initialValue: checkin)
        self.me = me
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    photo
                    VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                        beerHero
                        author
                        details
                        if !checkin.badges.isEmpty { badges }
                        if checkin.toastCount > 0 { toasts }
                        if !checkin.comments.isEmpty || !pending.isEmpty { comments }
                        Color.clear.frame(height: 0).id(Self.bottomID)
                    }
                    .padding(.horizontal, Taproom.margin)
                    .padding(.top, hasPhoto ? 20 : 8)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .readableContentWidth)
                    .frame(maxWidth: .infinity)
                    // The sheet of content overlaps the bottom of the photo.
                    .background(Taproom.background, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                    .padding(.top, hasPhoto ? -28 : 0)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // The photo runs up under the status and navigation bars.
            .ignoresSafeArea(.container, edges: hasPhoto ? .top : [])
            .foregroundStyle(Taproom.ink)
            .background(Taproom.background)
            // Keep your newest comment in view as it's added and as it turns into "Not sent".
            .onChange(of: pending.map { "\($0.id)\($0.failed)" }) { old, new in
                guard new.count >= old.count, !new.isEmpty else { return }
                // Wait a beat so the row is laid out (and the keyboard settled) before scrolling to it.
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
        }
        .navigationTitle(hasPhoto ? "" : "Checkin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .toolbarBackgroundVisibility(hasPhoto ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if let beer = checkin.beerLite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Check in") { checkInBeer = beer }
                        .fontWeight(.semibold)
                        .tint(Taproom.ink)  // amber text is too faint on the light bar
                        .accessibilityHint("Checks in this beer yourself")
                }
            }
            if checkin.isBy(username: auth.username) {
                ToolbarItem(placement: .topBarTrailing) {
                    if deleting {
                        ProgressView()
                    } else {
                        Menu("More", systemImage: "ellipsis") {
                            Button("Edit checkin", systemImage: "pencil") { editing = checkin }
                            Button("Delete checkin", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        }
                        .deleteCheckinConfirmation(isPresented: $confirmDelete) { Task { await delete() } }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .fullScreenCover(item: $checkInBeer) { CheckInSheet(beer: $0, venue: discover.here.first) }
        .fullScreenCover(item: $editing) { CheckInSheet(editing: $0) }
        .onReceive(NotificationCenter.default.publisher(for: .checkinEdited)) { n in
            if let c = n.object as? Checkin, c.id == checkin.id { checkin = c }
        }
        .confirmationDialog("Delete this comment?",
                            isPresented: Binding(get: { confirmDeleteComment != nil }, set: { if !$0 { confirmDeleteComment = nil } }),
                            titleVisibility: .visible, presenting: confirmDeleteComment) { c in
            Button("Delete", role: .destructive) { Task { await delete(c) } }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
               presenting: error) { _ in
            Button("OK") {}
        } message: { Text($0) }
        .task { await load() }
        .refreshable { await load() }
    }

    private static let bottomID = "CheckinDetail.bottom"

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
            self.error = "Couldn't delete the checkin: \(error.localizedDescription)"
        }
    }

    // MARK: Composer

    /// Untappd's public API documents 140 characters; the private API's limit hasn't been checked.
    private static let maxCommentLength = 140

    private var remaining: Int { Self.maxCommentLength - draft.count }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !trimmedDraft.isEmpty && trimmedDraft != editingComment?.text }

    /// Toasting and commenting, pinned at the bottom: the comment field, with the Toast button
    /// on the right within thumb reach.
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editingComment != nil {
                HStack {
                    Label("Editing comment", systemImage: "pencil")
                        .font(.caption.weight(.semibold)).foregroundStyle(Taproom.muted)
                    Spacer()
                    Button("Cancel", action: cancelEditing).font(.caption.weight(.semibold))
                        .foregroundStyle(Taproom.ink)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .bottom, spacing: 6) {
                    TextField(editingComment == nil ? "Add a comment" : "Comment", text: $draft,
                              prompt: Text(editingComment == nil ? "Add a comment" : "Comment").foregroundStyle(Taproom.muted),
                              axis: .vertical)
                        .lineLimit(1...4)
                        .focused($composerFocused)
                        .padding(.vertical, 12)
                        .onChange(of: draft) { _, new in
                            if new.count > Self.maxCommentLength { draft = String(new.prefix(Self.maxCommentLength)) }
                        }
                    if remaining <= 40 {
                        Text("\(remaining)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(remaining <= 10 ? .red : Taproom.muted)
                            .padding(.bottom, 14)
                    }
                    if composerFocused || !trimmedDraft.isEmpty {
                        Button(action: send) {
                            Image(systemName: editingComment == nil ? "arrow.up" : "checkmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(canSend ? Taproom.background : Taproom.muted)
                                .frame(width: 32, height: 32)
                                .background(canSend ? Taproom.ink : Taproom.border, in: Circle())
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .disabled(!canSend)
                        .accessibilityLabel(editingComment == nil ? "Post comment" : "Save comment")
                        .padding(.trailing, -8)
                    }
                }
                .padding(.leading, 14).padding(.trailing, 8)
                .frame(minHeight: 48)
                .taproomCard()
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .onTapGesture { composerFocused = true }  // the padding isn't part of the text field

                if !composerFocused {
                    Button { Task { await toggleToast() } } label: {
                        HStack(spacing: 6) {
                            Image("toast").resizable().scaledToFit().frame(width: 20, height: 20)
                            Text(checkin.youToasted ? "Toasted" : "Toast")
                        }
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 48)
                        .foregroundStyle(checkin.youToasted ? Taproom.onAmber : Taproom.background)
                        .background(checkin.youToasted ? Taproom.amber : Taproom.ink, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(checkin.youToasted ? "Remove toast" : "Toast")
                    .accessibilityAddTraits(checkin.youToasted ? .isSelected : [])
                    .sensoryFeedback(.impact(weight: .light), trigger: checkin.youToasted)
                }
            }
        }
        .frame(maxWidth: .readableContentWidth)
        .frame(maxWidth: .infinity)
        .taproomBottomBar()
        .animation(.snappy(duration: 0.2), value: composerFocused)
    }

    /// Toasts or un-toasts straight away, putting it back if the server refuses, and tells the
    /// lists so their copies match.
    private func toggleToast() async {
        let before = checkin
        checkin.youToasted.toggle()
        checkin.toastCount = max(0, checkin.toastCount + (checkin.youToasted ? 1 : -1))
        if let me {
            checkin.toasters.removeAll { $0.id == me.id }
            if checkin.youToasted { checkin.toasters.append(me) }
        }
        do {
            _ = try await UntappdAPI.shared.data(.toggleToast(checkin.id))
            NotificationCenter.default.post(name: .checkinEdited, object: checkin)
        } catch {
            checkin = before
            self.error = "Couldn't toast: \(error.localizedDescription)"
        }
    }

    private func send() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        if let c = editingComment {
            editingComment = nil
            draft = draftBeforeEditing
            draftBeforeEditing = ""
            composerFocused = false
            Task { await save(c, text: text) }
            return
        }
        draft = ""
        let p = PendingComment(text: text)
        pending.append(p)
        Task { await post(p.id) }
    }

    /// Posts a pending comment. It stays in the list, marked "Not sent", if that fails.
    private func post(_ id: UUID) async {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].failed = false
        let text = pending[i].text
        do {
            let r = try await UntappdAPI.shared.fetch(.addComment(text, to: checkin.id), as: CommentList.self)
            pending.removeAll { $0.id == id }
            checkin.comments = r.comments
            checkin.commentCount = r.totalCount
        } catch {
            if let j = pending.firstIndex(where: { $0.id == id }) { pending[j].failed = true }
        }
    }

    private func edit(_ p: PendingComment) {
        pending.removeAll { $0.id == p.id }
        draft = p.text
        composerFocused = true
    }

    private func reply(to user: User) {
        let mention = "@\(user.userName) "
        if !draft.hasPrefix(mention) { draft = mention + draft }
        composerFocused = true
    }

    private func startEditing(_ c: Checkin.Comment) {
        if editingComment == nil { draftBeforeEditing = draft }
        editingComment = c
        draft = c.text
        composerFocused = true
    }

    private func cancelEditing() {
        editingComment = nil
        draft = draftBeforeEditing
        draftBeforeEditing = ""
    }

    // The server says which comments you may edit or delete; fall back to the usual rules if it doesn't.
    private func canEdit(_ c: Checkin.Comment) -> Bool {
        c.canEdit ?? (me != nil && c.user?.id == me?.id)
    }

    private func canDelete(_ c: Checkin.Comment) -> Bool {
        if let d = c.canDelete { return d }
        guard let me else { return false }
        return c.user?.id == me.id || checkin.user?.id == me.id
    }

    /// Shows the new text straight away, and puts the old text back if the server refuses.
    private func save(_ c: Checkin.Comment, text: String) async {
        guard let i = checkin.comments.firstIndex(where: { $0.id == c.id }) else { return }
        checkin.comments[i].text = text
        do {
            let r = try await UntappdAPI.shared.fetch(.editComment(c.id, text: text), as: EditedComment.self)
            if let new = r.comment, let j = checkin.comments.firstIndex(where: { $0.id == c.id }) {
                checkin.comments[j] = new
            }
        } catch {
            if let j = checkin.comments.firstIndex(where: { $0.id == c.id }) { checkin.comments[j] = c }
            self.error = "Couldn't save the comment: \(error.localizedDescription)"
        }
    }

    private func delete(_ c: Checkin.Comment) async {
        guard let i = checkin.comments.firstIndex(where: { $0.id == c.id }) else { return }
        checkin.comments.remove(at: i)
        checkin.commentCount = max(0, checkin.commentCount - 1)
        if editingComment?.id == c.id { cancelEditing() }
        do {
            let r = try await UntappdAPI.shared.fetch(.deleteComment(c.id), as: CommentList.self)
            checkin.comments = r.comments
            checkin.commentCount = r.totalCount
        } catch {
            checkin.comments.insert(c, at: min(i, checkin.comments.count))
            checkin.commentCount += 1
            self.error = "Couldn't delete the comment: \(error.localizedDescription)"
        }
    }

    // MARK: Sections

    private var hasPhoto: Bool { checkin.photo.map { ($0.large ?? $0.medium ?? $0.small) != nil } ?? false }

    /// The photo, square and edge to edge under the navigation bar; tap to see it full screen.
    @ViewBuilder private var photo: some View {
        if let p = checkin.photo, let url = p.large ?? p.medium ?? p.small {
            Button { showPhoto = true } label: {
                Taproom.glassInside
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        CachedImage(url: url, maxPixel: 1400) {
                            CachedImage(url: p.medium ?? p.small, maxPixel: 1000)
                        }
                        .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
                    .frame(maxWidth: .readableContentWidth)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Photo")
            .accessibilityHint("Opens it full screen")
            .fullScreenCover(isPresented: $showPhoto) {
                PhotoViewer(url: p.large ?? url, placeholder: p.medium ?? url)
            }
        }
    }

    /// The beer, with the rating (and the serving under it) beside it as the hero. The whole beer
    /// area opens the Beer page; the brewery's name is a link of its own inside it and wins the tap.
    @ViewBuilder private var beerHero: some View {
        HStack(alignment: .top, spacing: 12) {
            if let beer = checkin.beerLite, beer.bid > 0 {
                NavigationLink(value: BeerBreweryRoute.beer(beer)) { beerArea(linked: true) }
                    .buttonStyle(TaproomLinkStyle(extend: 0))
                    .accessibilityElement(children: .contain)
            } else {
                beerArea(linked: false)
            }
            if checkin.rating != nil || checkin.servingType != nil {
                VStack(alignment: .trailing, spacing: 4) {
                    if let r = checkin.rating { TaproomRating(rating: r, size: 44) }
                    if let s = checkin.servingType {
                        HStack(spacing: 4) {
                            ServingIcon(name: s, size: 17)
                            Text(s).font(.footnote).foregroundStyle(Taproom.muted).lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .fixedSize()
                .padding(.top, 6)
            }
        }
    }

    private func beerArea(linked: Bool) -> some View {
        let abv = checkin.beer?.abv.map { "\($0.formatted(.number.precision(.fractionLength(0...1))))%" }
        let meta = [checkin.beer?.style, abv].compactMap { $0 }.joined(separator: " · ")
        let name = checkin.beer?.name ?? ""
        return HStack(alignment: .top, spacing: 12) {
            BeerLabel(beer: checkin.beer?.labelHD ?? checkin.beer?.label, brewery: checkin.brewery?.label, size: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let brewery = checkin.brewery, !brewery.name.isEmpty {
                    if brewery.id > 0 {
                        NavigationLink(value: BeerBreweryRoute.brewery(id: brewery.id, name: brewery.name, label: brewery.label)) {
                            TaproomLinkLabel(brewery.name, font: .subheadline, chevronSize: 10)
                                .foregroundStyle(Taproom.muted)
                        }
                        .buttonStyle(TaproomLinkStyle())
                        .accessibilityHint("Opens the brewery's page")
                        .accessibilityAddTraits(.isLink)
                    } else {
                        Text(brewery.name).font(.subheadline).foregroundStyle(Taproom.muted).lineLimit(1)
                    }
                }
                Group {
                    Text(name)
                        .font(.system(size: 26, weight: .heavy))
                        .tracking(-0.4)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading)
                    if !meta.isEmpty {
                        Text(meta).font(.footnote).foregroundStyle(Taproom.muted).padding(.top, 2)
                    }
                }
                .modifier(BeerLinkAccessibility(linked: linked, label: [name, meta].filter { !$0.isEmpty }.joined(separator: ", ")))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Who checked in, what they said, and when and where; opens their profile when tapped.
    @ViewBuilder private var author: some View {
        if let u = checkin.user, !u.userName.isEmpty {
            NavigationLink(value: u) { authorContent }.buttonStyle(.plain)
        } else {
            authorContent
        }
    }

    private var authorContent: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: checkin.user?.avatar, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                (Text(checkin.user?.displayName ?? "").fontWeight(.semibold)
                 + Text(checkin.comment.map { " " + $0 } ?? ""))
                    .font(.body)
                    .textSelection(.enabled)
                if let d = checkin.createdAt {
                    Text(d.formatted(date: .abbreviated, time: .shortened)
                         + (Date.now.timeIntervalSince(d) < 86_400 ? " · " + RelativeTime.string(d) : ""))
                        .font(.caption).foregroundStyle(Taproom.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    /// Where, where it was bought, who with, and flavours, as chips.
    @ViewBuilder private var details: some View {
        if checkin.venue != nil || checkin.retailVenue != nil || !checkin.taggedFriends.isEmpty
            || !checkin.flavors.isEmpty {
            FlowLayout(spacing: 6) {
                if let v = checkin.venue {
                    NavigationLink(value: v) {
                        HStack(spacing: 5) {
                            Image(systemName: "mappin").foregroundStyle(Taproom.amber)
                            Text(v.name).lineLimit(1)
                        }
                    }
                    .buttonStyle(TaproomChip(on: false))
                }
                if let v = checkin.retailVenue {
                    NavigationLink(value: v) {
                        HStack(spacing: 5) {
                            Image(systemName: "bag").foregroundStyle(Taproom.amber)
                            (Text("Purchased at ").foregroundStyle(Taproom.muted) + Text(v.name)).lineLimit(1)
                        }
                    }
                    .buttonStyle(TaproomChip(on: false))
                }
                ForEach(checkin.taggedFriends) { UserChipLink(user: $0) }
                ForEach(checkin.flavors, id: \.self) { f in
                    Text(f).font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12).frame(minHeight: 34)
                        .overlay(Capsule().strokeBorder(Taproom.border))
                }
            }
        }
    }

    private var badges: some View {
        TaproomSection("Badges earned") {
            ForEach(checkin.badges) { b in
                let row = HStack(spacing: 10) {
                    CachedImage(url: b.image, maxPixel: 120).frame(width: 40, height: 40).clipShape(Circle())
                    Text(b.name).font(.subheadline.weight(.medium))
                }
                if let route = BeerBreweryRoute.badge(of: b) {
                    NavigationLink(value: route) {
                        HStack(spacing: 6) {
                            row
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                                .foregroundStyle(Taproom.muted)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the badge")
                } else {
                    row
                }
            }
        }
    }

    private var toasts: some View {
        TaproomSection("\(checkin.toastCount) \(checkin.toastCount == 1 ? "toast" : "toasts")") {
            FlowLayout(spacing: 6) {
                ForEach(checkin.toasters) { UserChipLink(user: $0) }
            }
        }
    }

    private var comments: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comments").font(Taproom.sectionLabel)
            ForEach(checkin.comments) { c in
                CommentRow(user: c.user, text: c.text, date: c.createdAt)
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = c.text }
                        if let u = c.user, u.id != me?.id {
                            Button("Reply", systemImage: "arrowshape.turn.up.left") { reply(to: u) }
                        }
                        if canEdit(c) {
                            Button("Edit", systemImage: "pencil") { startEditing(c) }
                        }
                        if canDelete(c) {
                            Button("Delete", systemImage: "trash", role: .destructive) { confirmDeleteComment = c }
                        }
                    }
            }
            ForEach(pending) { p in
                CommentRow(user: me, text: p.text, status: p.failed ? .failed : .sending,
                           retry: { Task { await post(p.id) } }, edit: { edit(p) })
            }
        }
    }
}

/// A comment the user has written that the server hasn't accepted yet.
private struct PendingComment: Identifiable {
    let id = UUID()
    var text: String
    var failed = false
}

struct CommentRow: View {
    enum Status { case posted, sending, failed }

    let user: User?
    let text: String
    var date: Date? = nil
    var status: Status = .posted
    var retry: () -> Void = {}
    var edit: () -> Void = {}
    var avatarSize: CGFloat = 32
    var lineLimit: Int? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: user?.avatar, size: avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user?.displayName ?? "You").font(.subheadline.weight(.semibold))
                    switch status {
                    case .posted:
                        if let date { Text(RelativeTime.string(date)).font(.caption).foregroundStyle(Taproom.muted) }
                    case .sending:
                        ProgressView().controlSize(.mini)
                        Text("Posting…").font(.caption).foregroundStyle(Taproom.muted)
                    case .failed:
                        EmptyView()
                    }
                }
                Text(text).font(.subheadline)
                    .lineLimit(lineLimit)
                    .foregroundStyle(status == .failed ? Taproom.muted : Taproom.ink)
                if status == .failed {
                    HStack(spacing: 6) {
                        Label("Not sent", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red).labelStyle(TightLabel())
                        Text("·").foregroundStyle(Taproom.muted)
                        Button("Retry", action: retry).fontWeight(.semibold).foregroundStyle(Taproom.ink)
                        Text("·").foregroundStyle(Taproom.muted)
                        Button("Edit", action: edit).foregroundStyle(Taproom.muted)
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                }
            }
        }
        .opacity(status == .sending ? 0.55 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct UserChip: View {
    let user: User

    var body: some View {
        HStack(spacing: 6) {
            Avatar(url: user.avatar, size: 26)
            Text(user.shortName).font(.subheadline.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(Taproom.ink)
        .padding(.leading, 4).padding(.trailing, 12)
        .frame(minHeight: 34)
        .background(Taproom.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Taproom.border))
    }
}

/// A person chip that opens their profile.
struct UserChipLink: View {
    let user: User

    var body: some View {
        NavigationLink(value: user) { UserChip(user: user) }
            .buttonStyle(.plain)
            .disabled(user.userName.isEmpty)
    }
}

/// Reads the beer's name and style line as one element, a link to the Beer page when it has one.
private struct BeerLinkAccessibility: ViewModifier {
    let linked: Bool
    let label: String

    func body(content: Content) -> some View {
        if linked {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label)
                .accessibilityHint("Opens the beer's page")
                .accessibilityAddTraits(.isLink)
        } else {
            content.textSelection(.enabled)
        }
    }
}

