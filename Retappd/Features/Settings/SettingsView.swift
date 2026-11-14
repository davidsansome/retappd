import SwiftUI

enum ProfileRoute: Hashable { case settings }

struct SettingsView: View {
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system
    @Environment(AuthStore.self) private var auth
    @State private var settings: AccountSettings?
    @State private var styles: [ParentStyleOptOut] = []
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if let settings {
                Section {
                    toggle("Private account", \.isPrivate) { .updateSetting("account_private", $0) }
                    toggle("Appear in search", \.isSearchable) { .updateSetting("is_search", $0) }
                    toggle("Public toasts", \.publicToasts) { .updateSetting("public_toasts", $0) }
                    toggle("Opt out of data sharing", \.ocOptOut) { .updateSetting("oc_privacy", $0) }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("A private account's checkins are only visible to friends. Public toasts lets anyone toast your checkins, not only friends.")
                }

                Section("Checkins & badges") {
                    toggle("Rating bump", \.ratingBump) { .setRatingBump($0) }
                    toggle("Retroactive badges", \.retroactiveBadges) { .setRetroactiveBadges($0) }
                }

                if !styles.isEmpty {
                    Section {
                        ForEach($styles) { $style in
                            styleToggle($style)
                        }
                    } header: {
                        Text("Drink types")
                    } footer: {
                        Text("Turn off drink types to hide them from menus, recommendations and trending lists.")
                    }
                }

                if let email = settings.emailAddress {
                    Section("Account") {
                        LabeledContent("Email", value: email)
                    }
                }
            } else if let loadError {
                Section {
                    ContentUnavailableView {
                        Label("Couldn't load settings", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                }
            } else {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }

            Section {
                Button("Sign out", role: .destructive) { confirmSignOut = true }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
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

    /// A switch that changes the setting straight away and flips back if the server refuses.
    private func toggle(_ title: String, _ key: WritableKeyPath<AccountSettings, Bool>,
                        request: @escaping (Bool) -> APIRequest) -> some View {
        Toggle(title, isOn: Binding(
            get: { settings?[keyPath: key] ?? false },
            set: { on in
                settings?[keyPath: key] = on
                Task {
                    do {
                        _ = try await UntappdAPI.shared.data(request(on))
                        if key == \.ratingBump { CheckInOptions.shared.setRatingBump(on) }
                        await invalidateCache()
                    } catch {
                        settings?[keyPath: key] = !on
                        saveError = error.localizedDescription
                    }
                }
            }))
    }

    private func styleToggle(_ style: Binding<ParentStyleOptOut>) -> some View {
        Toggle(isOn: Binding(
            get: { style.wrappedValue.isEnabled },
            set: { on in
                style.wrappedValue.isEnabled = on
                let id = style.wrappedValue.id
                Task {
                    do {
                        _ = try await UntappdAPI.shared.data(.setParentStyle(id, enabled: on))
                        await invalidateCache()
                    } catch {
                        if let i = styles.firstIndex(where: { $0.id == id }) { styles[i].isEnabled = !on }
                        saveError = error.localizedDescription
                    }
                }
            })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(style.wrappedValue.name)
                if let d = style.wrappedValue.description {
                    Text(d).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(style.wrappedValue.isLocked)
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
            if settings == nil { loadError = error.localizedDescription }
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
