import SwiftUI

struct LoginView: View {
    @Environment(AuthStore.self) private var auth
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case user, pass }

    var body: some View {
        ScrollViewReader { proxy in
            form
                // Keep the field you're typing in clear of the keyboard and the Sign in bar.
                .onChange(of: focus) { _, f in
                    guard let f else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))  // let the keyboard arrive
                        withAnimation { proxy.scrollTo(f, anchor: .bottom) }
                    }
                }
        }
        .onAppear { focus = .user }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Taproom.sectionSpacing) {
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Welcome to").font(.subheadline).foregroundStyle(Taproom.muted)
                        Text("Retappd")
                            .font(.system(size: 48, weight: .heavy))
                            .tracking(-1.5)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text("Sign in with your Untappd account to see what your friends are drinking.")
                            .font(.subheadline).foregroundStyle(Taproom.muted)
                            .padding(.top, 4)
                    }
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    FilledGlass(rating: 4, lineWidth: 2.5, foam: true)
                        .frame(height: 190)
                }
                .padding(.top, 16)

                TaproomSection("Username or email") {
                    TextField("", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .user)
                        .submitLabel(.next)
                        .onSubmit { focus = .pass }
                        .modifier(LoginField())
                        .accessibilityLabel("Username or email")
                }
                .id(Field.user)
                TaproomSection("Password") {
                    SecureField("", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .pass)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .modifier(LoginField())
                        .accessibilityLabel("Password")
                }
                .id(Field.pass)

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, Taproom.margin)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(action: submit) {
                    if busy { ProgressView().tint(Taproom.background) } else { Text("Sign in") }
                }
                .buttonStyle(TaproomPrimaryButton())
                .disabled(busy || username.isEmpty || password.isEmpty)
                Text("Your password goes straight to Untappd.")
                    .font(.caption).foregroundStyle(Taproom.muted)
            }
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
            .taproomBottomBar()
        }
        .taproomScreen()
    }

    private func submit() {
        guard !username.isEmpty, !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await auth.signIn(username: username.trimmingCharacters(in: .whitespaces), password: password)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A login text field: a card, a little taller than usual.
private struct LoginField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.body)
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .taproomCard()
    }
}
