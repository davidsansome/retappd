import SwiftUI

enum ProfileRoute: Hashable { case settings, friends, statistics }

struct SettingsView: View {
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system
    @Environment(AuthStore.self) private var auth
    @State private var settings: AccountSettings?
    @State private var styles: [ParentStyleOptOut] = []
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var confirmSignOut = false
    @State private var settingTasks: [PartialKeyPath<AccountSettings>: Task<Void, Never>] = [:]
    @State private var settingGenerations: [PartialKeyPath<AccountSettings>: Int] = [:]
    @State private var styleTasks: [Int: Task<Void, Never>] = [:]
    @State private var styleGenerations: [Int: Int] = [:]
    private let notifications = NotificationService.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                TaproomSection("Theme") { themeTiles }

                TaproomSection("Notifications") { notificationControls }

                if let settings {
                    TaproomSection("Privacy") {
                        switchCard {
                            toggle("Private account", \.isPrivate) { .updateSetting("account_private", $0) }
                            toggle("Appear in search", \.isSearchable) { .updateSetting("is_search", $0) }
                            toggle("Public toasts", \.publicToasts) { .updateSetting("public_toasts", $0) }
                            // Sent inverted: oc_privacy=1 stops producers commenting.
                            toggle("Allow producer comments", \.allowsProducerComments) { .updateSetting("oc_privacy", !$0) }
                        }
                        caption("A private account's checkins are only visible to friends. Public toasts lets anyone toast your checkins, not only friends. Producer comments lets breweries comment on your checkins of their drinks.")
                    }

                    TaproomSection("Checkins & badges") {
                        switchCard {
                            // Insiders only, but kept for anyone who has it on so they can turn it off.
                            if settings.isInsider || settings.ratingBump {
                                toggle("0.1 ratings", \.ratingBump) { .setRatingBump($0) }
                            }
                            toggle("Earn core badges retroactively", \.retroactiveBadges) { .setRetroactiveBadges($0) }
                        }
                        caption("\(settings.isInsider || settings.ratingBump ? "0.1 ratings lets you rate in steps of 0.1 instead of 0.25. " : "")Earning core badges retroactively counts all your past checkins towards core badges. They're awarded after your next checkin of a qualifying drink.")
                    }

                    if !styles.isEmpty {
                        TaproomSection("Drink types I see") {
                            FlowLayout(spacing: 6) {
                                ForEach($styles) { $style in styleChip($style) }
                            }
                            caption("Turned-off types are hidden from menus, recommendations and trending lists.")
                        }
                    }
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't load settings", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try again") { Task { await load() } }.buttonStyle(TaproomOutlineButton())
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                }

                VStack(spacing: 8) {
                    if let email = settings?.emailAddress {
                        Text("Signed in as \(email)").font(.caption).foregroundStyle(Taproom.muted)
                    }
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .buttonStyle(TaproomOutlineButton())
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .readableContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .taproomScreen()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Taproom.background, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
        .alert("Couldn't save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") {}
        } message: {
            Text(saveError ?? "")
        }
        .confirmationDialog("Sign out of Untappd?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { auth.signOut() }
        }
    }

    // MARK: Pieces

    /// System, Light and Dark as tiles, each with a little preview of the page in that theme.
    private var themeTiles: some View {
        HStack(spacing: 8) {
            ForEach(Appearance.allCases) { a in
                let on = appearance == a
                Button { appearance = a } label: {
                    VStack(spacing: 6) {
                        ThemePreview(appearance: a)
                        Text(a.title).font(.subheadline.weight(.semibold))
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Taproom.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(on ? Taproom.amber : Taproom.border, lineWidth: on ? 2 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: appearance)
    }

    /// The notification master switch, a note on what it shares, and one switch per type.
    private var notificationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            switchCard {
                Toggle("Push notifications", isOn: Binding(
                    get: { notifications.enabled },
                    set: { on in Task { await notifications.setEnabled(on) } }))
                    .tint(Taproom.amber)
                if notifications.enabled {
                    prefToggle("Toasts", \.toast)
                    prefToggle("Comments", \.comment)
                    prefToggle("Tags", \.tag)
                    prefToggle("Friend requests", \.friend)
                }
            }
            if notifications.permissionDenied {
                caption("Notifications are turned off for Retappd in iOS. Turn them on in the Settings app, then come back and switch this on.")
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(TaproomOutlineButton())
            }
            caption("Get a notification when someone toasts, comments on or tags you in a check-in, or sends a friend request. To check for activity while the app is closed, turning this on stores an encrypted copy of your Untappd sign-in on Retappd's notification server. Turning it off, or signing out, deletes it.")
            caption("Retappd's server checks your Untappd activity about once a minute. When it sends you a notification, Untappd marks your notifications as read, so they won't show as unread in other apps, including the official Untappd app.")
        }
    }

    private func prefToggle(_ title: String, _ key: WritableKeyPath<NotifyPrefs, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { notifications.prefs[keyPath: key] },
            set: { on in
                var p = notifications.prefs
                p[keyPath: key] = on
                Task { await notifications.setPrefs(p) }
            }))
            .tint(Taproom.amber)
    }

    /// Switch rows in a card, with a line between each.
    private func switchCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Group(subviews: content()) { rows in
                ForEach(rows.indices, id: \.self) { i in
                    rows[i]
                        .padding(.horizontal, 14)
                        .frame(minHeight: 50)
                        .overlay(alignment: .bottom) {
                            if i < rows.count - 1 { Rectangle().fill(Taproom.border).frame(height: 1) }
                        }
                }
            }
        }
        .taproomCard()
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Taproom.muted)
    }

    /// A switch that changes the setting straight away and flips back if the server refuses.
    private func toggle(_ title: String, _ key: WritableKeyPath<AccountSettings, Bool>,
                        request: @escaping (Bool) -> APIRequest) -> some View {
        Toggle(title, isOn: Binding(
            get: { settings?[keyPath: key] ?? false },
            set: { on in
                settings?[keyPath: key] = on
                settingTasks[key]?.cancel()
                let gen = (settingGenerations[key] ?? 0) + 1
                settingGenerations[key] = gen
                settingTasks[key] = Task {
                    do {
                        _ = try await UntappdAPI.shared.data(request(on))
                        guard settingGenerations[key] == gen else { return }
                        if key == \.ratingBump { CheckInOptions.shared.setRatingBump(on) }
                        await invalidateCache()
                    } catch {
                        guard settingGenerations[key] == gen, !error.isCancellation else { return }
                        settings?[keyPath: key] = !on
                        saveError = error.localizedDescription
                    }
                }
            }))
            .tint(Taproom.amber)
    }

    /// A drink type as a chip: amber when shown, outlined when hidden. Flips straight away and
    /// back again if the server refuses.
    private func styleChip(_ style: Binding<ParentStyleOptOut>) -> some View {
        let on = style.wrappedValue.isEnabled
        return Button {
            let next = !on
            style.wrappedValue.isEnabled = next
            let id = style.wrappedValue.id
            styleTasks[id]?.cancel()
            let gen = (styleGenerations[id] ?? 0) + 1
            styleGenerations[id] = gen
            styleTasks[id] = Task {
                do {
                    _ = try await UntappdAPI.shared.data(.setParentStyle(id, enabled: next))
                    guard styleGenerations[id] == gen else { return }
                    await invalidateCache()
                } catch {
                    guard styleGenerations[id] == gen, !error.isCancellation else { return }
                    if let i = styles.firstIndex(where: { $0.id == id }) { styles[i].isEnabled = on }
                    saveError = error.localizedDescription
                }
            }
        } label: {
            Text(style.wrappedValue.name)
        }
        .buttonStyle(TaproomChip(on: on))
        .disabled(style.wrappedValue.isLocked)
        .opacity(style.wrappedValue.isLocked ? 0.6 : 1)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(style.wrappedValue.description ?? "")
    }

    private func load() async {
        loadError = nil
        async let s: () = loadSettings()
        async let o: () = loadStyles()
        _ = await (s, o)
    }

    private func loadSettings() async {
        do {
            settings = try await cacheThenNetwork(.userSettings, as: AccountSettings.self, onCached: { settings = $0 })
        } catch {
            if !error.isCancellation, settings == nil { loadError = error.localizedDescription }
        }
    }

    private func loadStyles() async {
        if let s = try? await cacheThenNetwork(.parentStyleOptOuts, as: [Failable<ParentStyleOptOut>].self,
                                               onCached: { styles = $0.compactMap(\.value) }) {
            styles = s.compactMap(\.value)
        }
    }

    /// Drops cached copies so the next visit doesn't briefly show the old values.
    private func invalidateCache() async {
        await ResponseCache.shared.remove(APIRequest.userSettings.cacheKey)
        await ResponseCache.shared.remove(APIRequest.parentStyleOptOuts.cacheKey)
    }
}

/// A thumbnail of the page in one theme, for the theme tiles. System shows light and dark side by side.
private struct ThemePreview: View {
    let appearance: Appearance

    var body: some View {
        HStack(spacing: 0) {
            switch appearance {
            case .system:
                page(.light)
                page(.dark)
            case .light:
                page(.light)
            case .dark:
                page(.dark)
            }
        }
        .frame(height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Taproom.border))
        .accessibilityHidden(true)
    }

    /// The page drawn in one scheme: background, an amber line and two lines of text.
    private func page(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(Taproom.amber).frame(width: 26, height: 6)
            Capsule().fill(Taproom.ink).frame(width: 38, height: 6)
            Capsule().fill(Taproom.glassRim).frame(width: 22, height: 6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Taproom.background)
        .environment(\.colorScheme, scheme)
    }
}
