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
                    if !checkin.comments.isEmpty || !pending.isEmpty { comments }
                    Color.clear.frame(height: 0).id(Self.bottomID)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
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
        .readableContentWidth()
        .navigationTitle(checkin.beer?.name ?? "Checkin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let beer = checkin.beerLite {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { checkInBeer = beer } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("Check in this beer")
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
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .sheet(item: $checkInBeer) { CheckInSheet(beer: $0, venue: discover.here.first) }
        .sheet(item: $editing) { CheckInSheet(editing: $0) }
        .confirmationDialog("Delete this checkin?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("This can't be undone.")
        }
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

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editingComment != nil {
                HStack {
                    Label("Editing comment", systemImage: "pencil")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: cancelEditing).font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 6)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(editingComment == nil ? "Add a comment…" : "Comment", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color(.separator), lineWidth: 0.5))
                    .contentShape(RoundedRectangle(cornerRadius: 20))
                    .onTapGesture { composerFocused = true }  // the padding isn't part of the text field
                    .onChange(of: draft) { _, new in
                        if new.count > Self.maxCommentLength { draft = String(new.prefix(Self.maxCommentLength)) }
                    }
                VStack(spacing: 4) {
                    if remaining <= 40 {
                        Text("\(remaining)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(remaining <= 10 ? .red : .secondary)
                    }
                    Button(action: send) {
                        Image(systemName: editingComment == nil ? "arrow.up" : "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(canSend ? Color.accentColor : Color(.systemGray4), in: Circle())
                    }
                    .disabled(!canSend)
                    .accessibilityLabel(editingComment == nil ? "Post comment" : "Save comment")
                    .padding(.bottom, 3)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .readableContentWidth)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
            Label { Text("\(checkin.toastCount) \(checkin.toastCount == 1 ? "toast" : "toasts")") } icon: { Image("toast").foregroundStyle(.orange) }
                .font(.headline)
            FlowLayout(spacing: 6) {
                ForEach(checkin.toasters) { UserChip(user: $0) }
            }
        }
    }

    private var comments: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comments").font(.headline)
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: user?.avatar, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(user?.displayName ?? "You").font(.subheadline.weight(.semibold))
                    switch status {
                    case .posted:
                        if let date { Text(RelativeTime.string(date)).font(.caption).foregroundStyle(.secondary) }
                    case .sending:
                        ProgressView().controlSize(.mini)
                        Text("Posting…").font(.caption).foregroundStyle(.secondary)
                    case .failed:
                        EmptyView()
                    }
                }
                Text(text).font(.subheadline)
                    .foregroundStyle(status == .failed ? .secondary : .primary)
                if status == .failed {
                    HStack(spacing: 6) {
                        Label("Not sent", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red).labelStyle(TightLabel())
                        Text("·").foregroundStyle(.secondary)
                        Button("Retry", action: retry).fontWeight(.semibold)
                        Text("·").foregroundStyle(.secondary)
                        Button("Edit", action: edit).foregroundStyle(.secondary)
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
