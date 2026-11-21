import SwiftUI

/// Pure subtitle formatting for blocked and muted user rows.
enum ModerationUserSubtitle {
    static func blocked(_ item: BlockedUser, now: Date = .now) -> String {
        let parts: [String?] = [
            "@" + item.user.userName,
            item.createdAt.map { "blocked " + RelativeTime.string($0, now: now) },
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    static func muted(_ item: MutedUser) -> String {
        var detail: String?
        if item.muteForever {
            detail = "muted forever"
        } else if let expire = item.expireDate {
            detail = "until " + expire.formatted(date: .abbreviated, time: .shortened)
        }
        return ["@" + item.user.userName, detail].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Lists the signed-in account's blocked users and lets them be unblocked.
struct BlockedUsersView: View {
    @State private var items: [BlockedUser]?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var inFlight: Set<Int> = []
    @State private var feedback = 0
    @State private var ignoreNextNotification = false

    var body: some View {
        ModerationUsersScaffold(
            title: "Blocked users",
            items: items,
            loadError: loadError,
            emptyTitle: "No blocked users",
            emptyIcon: "hand.raised.slash",
            emptyDescription: "People you block won't be able to see your checkins or interact with you.",
            actionTitle: "Unblock",
            actionErrorTitle: "Couldn't unblock user",
            actionError: $actionError,
            accessibilityPrefix: "blockedUsers.unblock",
            inFlight: inFlight,
            feedback: feedback,
            user: \.user,
            subtitle: { ModerationUserSubtitle.blocked($0) },
            retry: { Task { await load() } },
            refresh: { await load() },
            performAction: unblock
        )
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .userModerationChanged)) { _ in
            if ignoreNextNotification {
                ignoreNextNotification = false
                return
            }
            Task { await load() }
        }
    }

    private func load() async {
        loadError = nil
        do {
            let response = try await cacheThenNetwork(
                .blockedUsers,
                as: BlockedUsersResponse.self,
                onCached: { items = $0.items }
            )
            items = response.items
        } catch {
            if !error.isCancellation, items == nil {
                loadError = error.localizedDescription
            }
        }
    }

    private func unblock(_ item: BlockedUser) {
        let uid = item.id
        guard !inFlight.contains(uid) else { return }
        inFlight.insert(uid)
        Task {
            defer { inFlight.remove(uid) }
            do {
                let result = try await UntappdAPI.shared.fetch(.toggleBlockUser(uid), as: BlockUserResult.self)
                if !result.isBlocked {
                    withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.85)) {
                        items?.removeAll { $0.id == uid }
                    }
                }
                await ResponseCache.shared.remove(APIRequest.blockedUsers.cacheKey)
                await ResponseCache.shared.remove(APIRequest.userSettings.cacheKey)
                await ResponseCache.shared.remove(APIRequest.userInfo(item.user.userName).cacheKey)
                ignoreNextNotification = true
                NotificationCenter.default.post(name: .userModerationChanged, object: nil)
                feedback += 1
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// Lists the signed-in account's muted friends and lets them be unmuted.
struct MutedUsersView: View {
    @State private var items: [MutedUser]?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var inFlight: Set<Int> = []
    @State private var feedback = 0
    @State private var ignoreNextNotification = false

    var body: some View {
        ModerationUsersScaffold(
            title: "Muted users",
            items: items,
            loadError: loadError,
            emptyTitle: "No muted users",
            emptyIcon: "speaker.wave.2",
            emptyDescription: "Friends you mute won't appear in your activity feed.",
            actionTitle: "Unmute",
            actionErrorTitle: "Couldn't unmute user",
            actionError: $actionError,
            accessibilityPrefix: "mutedUsers.unmute",
            inFlight: inFlight,
            feedback: feedback,
            user: \.user,
            subtitle: { ModerationUserSubtitle.muted($0) },
            retry: { Task { await load() } },
            refresh: { await load() },
            performAction: unmute
        )
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .userModerationChanged)) { _ in
            if ignoreNextNotification {
                ignoreNextNotification = false
                return
            }
            Task { await load() }
        }
    }

    private func load() async {
        loadError = nil
        do {
            let response = try await cacheThenNetwork(
                .mutedUsers,
                as: MutedUsersResponse.self,
                onCached: { items = $0.items }
            )
            items = response.items
        } catch {
            if !error.isCancellation, items == nil {
                loadError = error.localizedDescription
            }
        }
    }

    private func unmute(_ item: MutedUser) {
        let uid = item.id
        guard !inFlight.contains(uid) else { return }
        inFlight.insert(uid)
        Task {
            defer { inFlight.remove(uid) }
            do {
                _ = try await UntappdAPI.shared.data(.unmuteUser(uid))
                withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.85)) {
                    items?.removeAll { $0.id == uid }
                }
                await ResponseCache.shared.remove(APIRequest.mutedUsers.cacheKey)
                await ResponseCache.shared.remove(APIRequest.userSettings.cacheKey)
                await ResponseCache.shared.remove(APIRequest.userInfo(item.user.userName).cacheKey)
                ignoreNextNotification = true
                NotificationCenter.default.post(name: .userModerationChanged, object: nil)
                feedback += 1
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

/// Shared Taproom list layout for Blocked users and Muted users.
private struct ModerationUsersScaffold<Item: Identifiable>: View where Item.ID == Int {
    let title: String
    let items: [Item]?
    let loadError: String?
    let emptyTitle: String
    let emptyIcon: String
    let emptyDescription: String
    let actionTitle: String
    let actionErrorTitle: String
    @Binding var actionError: String?
    let accessibilityPrefix: String
    let inFlight: Set<Int>
    let feedback: Int
    let user: (Item) -> User
    let subtitle: (Item) -> String
    let retry: () -> Void
    let refresh: () async -> Void
    let performAction: (Item) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                Text(title)
                    .font(.system(size: 34, weight: .heavy)).tracking(-0.6)
                    .accessibilityAddTraits(.isHeader)

                if let items {
                    if items.isEmpty {
                        ContentUnavailableView {
                            Label(emptyTitle, systemImage: emptyIcon)
                        } description: {
                            Text(emptyDescription)
                        }
                        .padding(.top, 24)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                let person = user(item)
                                let busy = inFlight.contains(item.id)
                                HStack(spacing: 10) {
                                    NavigationLink(value: person) {
                                        HStack(spacing: 12) {
                                            Avatar(url: person.avatar, size: 44)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(person.displayName)
                                                    .font(.body.weight(.semibold))
                                                    .lineLimit(1)
                                                Text(subtitle(item))
                                                    .font(.footnote)
                                                    .foregroundStyle(Taproom.muted)
                                                    .lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.vertical, 8)
                                        .frame(minHeight: 60)
                                    }
                                    .buttonStyle(TaproomRowStyle())

                                    Button { performAction(item) } label: {
                                        Group {
                                            if busy {
                                                ProgressView()
                                                    .controlSize(.small)
                                                    .frame(minWidth: 56)
                                            } else {
                                                Text(actionTitle)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(Taproom.ink)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .frame(height: 34)
                                        .background(Taproom.card, in: Capsule())
                                        .overlay(Capsule().strokeBorder(Taproom.border, lineWidth: 1))
                                        .frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(busy)
                                    .accessibilityLabel("\(actionTitle) \(person.displayName)")
                                    .accessibilityIdentifier("\(accessibilityPrefix).\(person.userName)")
                                }
                                .taproomRowDivider()
                            }
                        }
                    }
                } else if let loadError {
                    ErrorRow(message: loadError, retry: retry)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.bottom, 24)
            .frame(maxWidth: .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .taproomScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .refreshable { await refresh() }
        .sensoryFeedback(.success, trigger: feedback)
        .alert(
            actionErrorTitle,
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } }),
            presenting: actionError
        ) { _ in
            Button("OK") {}
        } message: { Text($0) }
    }
}
