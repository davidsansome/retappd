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
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "mug.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
            Text("Sign in to Untappd").font(.title2.bold())

            VStack(spacing: 12) {
                TextField("Username or email", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .user)
                    .submitLabel(.next)
                    .onSubmit { focus = .pass }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .pass)
                    .submitLabel(.go)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            Button(action: submit) {
                Group {
                    if busy { ProgressView() } else { Text("Sign in").bold() }
                }
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || username.isEmpty || password.isEmpty)
            Spacer()
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 420)
        .onAppear { focus = .user }
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
