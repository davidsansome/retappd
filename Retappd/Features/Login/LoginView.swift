import SwiftUI

/// Adaptive vertical layout metrics for `LoginView`, computed purely from the `ScrollView`
/// viewport height (which automatically reflects device size, `.safeAreaInset(edge: .bottom)`,
/// and keyboard appearance) and whether an accessibility Dynamic Type size is active.
struct LoginLayoutMetrics: Equatable {
    enum Tier: Equatable {
        case generous
        case medium
        case compact
    }

    /// Fallback viewport height used before the first geometry pass reports a positive height.
    static let defaultViewportHeight: CGFloat = 600
    /// Maximum decorative glass height under accessibility Dynamic Type sizes so large text has room.
    static let accessibilityMaxGlassHeight: CGFloat = 80

    let tier: Tier
    let glassHeight: CGFloat
    let titleSize: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let heroTextSpacing: CGFloat
    let heroTextBottomPadding: CGFloat
    let sectionSpacing: CGFloat
    let labelSpacing: CGFloat
    let fieldMinHeight: CGFloat
    let showSubtitle: Bool

    static func metrics(forViewportHeight height: CGFloat, isAccessibilitySize: Bool) -> LoginLayoutMetrics {
        let effectiveHeight = (height.isFinite && height > 0) ? height : defaultViewportHeight

        let tier: Tier
        var glassHeight: CGFloat
        let titleSize: CGFloat
        let topPadding: CGFloat
        let bottomPadding: CGFloat
        let heroTextSpacing: CGFloat
        let heroTextBottomPadding: CGFloat
        let sectionSpacing: CGFloat
        let labelSpacing: CGFloat
        let fieldMinHeight: CGFloat
        let showSubtitle: Bool

        if effectiveHeight >= 500 {
            tier = .generous
            glassHeight = min(170, max(120, effectiveHeight * 0.28))
            titleSize = 46
            topPadding = 16
            bottomPadding = 12
            heroTextSpacing = 6
            heroTextBottomPadding = 12
            sectionSpacing = Taproom.sectionSpacing
            labelSpacing = 8
            fieldMinHeight = 50
            showSubtitle = true
        } else if effectiveHeight >= 300 {
            tier = .medium
            glassHeight = max(72, min(110, effectiveHeight * 0.24))
            titleSize = max(32, min(40, effectiveHeight * 0.10))
            topPadding = 6
            bottomPadding = 8
            heroTextSpacing = 4
            heroTextBottomPadding = 4
            sectionSpacing = 10
            labelSpacing = 6
            fieldMinHeight = 44
            showSubtitle = effectiveHeight >= 360
        } else {
            tier = .compact
            glassHeight = 58
            titleSize = 28
            topPadding = 4
            bottomPadding = 4
            heroTextSpacing = 2
            heroTextBottomPadding = 2
            sectionSpacing = 8
            labelSpacing = 4
            fieldMinHeight = 44
            showSubtitle = false
        }

        if isAccessibilitySize {
            glassHeight = min(glassHeight, accessibilityMaxGlassHeight)
        }

        return LoginLayoutMetrics(
            tier: tier,
            glassHeight: glassHeight,
            titleSize: titleSize,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
            heroTextSpacing: heroTextSpacing,
            heroTextBottomPadding: heroTextBottomPadding,
            sectionSpacing: sectionSpacing,
            labelSpacing: labelSpacing,
            fieldMinHeight: max(fieldMinHeight, 44),
            showSubtitle: showSubtitle
        )
    }

    /// Estimated total vertical height of the hero + Username + Password form at default text size,
    /// used to verify that both input fields stay above the fold across device sizes.
    var estimatedContentHeight: CGFloat {
        let welcomeLineHeight: CGFloat = 20
        let titleLineHeight = titleSize * 1.19
        let subtitleHeight: CGFloat = showSubtitle ? (4 + 40) : 0
        let heroTextHeight = welcomeLineHeight + heroTextSpacing + titleLineHeight + subtitleHeight + heroTextBottomPadding
        let heroHeight = max(glassHeight, heroTextHeight)

        let sectionLabelHeight: CGFloat = 18
        let fieldSectionHeight = sectionLabelHeight + labelSpacing + fieldMinHeight

        return topPadding
            + heroHeight
            + sectionSpacing
            + fieldSectionHeight
            + sectionSpacing
            + fieldSectionHeight
            + bottomPadding
    }
}

struct LoginView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var viewportHeight: CGFloat = 0
    @FocusState private var focus: Field?

    private enum Field { case user, pass }

    private var metrics: LoginLayoutMetrics {
        LoginLayoutMetrics.metrics(
            forViewportHeight: viewportHeight,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            form
                // Keep the field you're typing in clear of the keyboard and the Sign in bar.
                .task(id: focus) {
                    guard let f = focus else { return }
                    do {
                        try await Task.sleep(for: .milliseconds(300))  // let the keyboard arrive
                        if reduceMotion {
                            proxy.scrollTo(f, anchor: .bottom)
                        } else {
                            withAnimation { proxy.scrollTo(f, anchor: .bottom) }
                        }
                    } catch {}
                }
        }
        .onAppear { focus = .user }
    }

    private var form: some View {
        let m = metrics
        return ScrollView {
            VStack(alignment: .leading, spacing: m.sectionSpacing) {
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: m.heroTextSpacing) {
                        Text("Welcome to").font(.subheadline).foregroundStyle(Taproom.muted)
                        Text("Retappd")
                            .font(.system(size: m.titleSize, weight: .heavy))
                            .tracking(-1.5)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        if m.showSubtitle {
                            Text("Sign in with your Untappd account to see what your friends are drinking.")
                                .font(.subheadline).foregroundStyle(Taproom.muted)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.bottom, m.heroTextBottomPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    FilledGlass(rating: 4, lineWidth: m.glassHeight >= 110 ? 2.5 : 2, foam: true)
                        .frame(height: m.glassHeight)
                }
                .padding(.top, m.topPadding)

                LoginFieldSection("Username or email", spacing: m.labelSpacing) {
                    TextField("", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .user)
                        .submitLabel(.next)
                        .onSubmit { focus = .pass }
                        .modifier(LoginField(minHeight: m.fieldMinHeight))
                        .accessibilityLabel("Username or email")
                        .accessibilityIdentifier("login.username")
                }
                .id(Field.user)

                LoginFieldSection("Password", spacing: m.labelSpacing) {
                    SecureField("", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .pass)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .modifier(LoginField(minHeight: m.fieldMinHeight))
                        .accessibilityLabel("Password")
                        .accessibilityIdentifier("login.password")
                }
                .id(Field.pass)

                if let error {
                    Text(error).font(.footnote).foregroundStyle(Taproom.destructive)
                }
            }
            .padding(.horizontal, Taproom.margin)
            .padding(.bottom, m.bottomPadding)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            guard newHeight.isFinite, newHeight > 0, abs(newHeight - viewportHeight) > 0.5 else { return }
            if viewportHeight == 0 || reduceMotion {
                viewportHeight = newHeight
            } else {
                withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.85)) {
                    viewportHeight = newHeight
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(action: submit) {
                    if busy { ProgressView().tint(Taproom.background) } else { Text("Sign in") }
                }
                .buttonStyle(TaproomPrimaryButton())
                .disabled(busy || trimmedUsername.isEmpty || password.isEmpty)
                .accessibilityIdentifier("login.signIn")
                Text("Your password goes straight to Untappd.")
                    .font(.caption).foregroundStyle(Taproom.muted)
            }
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
            .taproomBottomBar()
        }
        .taproomScreen()
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let user = trimmedUsername
        guard !user.isEmpty, !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await auth.signIn(username: user, password: password)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Matches `TaproomSection`'s label styling while allowing tighter label-to-field spacing
/// in medium and compact viewports.
private struct LoginFieldSection<Content: View>: View {
    let title: String
    let spacing: CGFloat
    @ViewBuilder var content: Content

    init(_ title: String, spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.title = title
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title).font(Taproom.sectionLabel)
            content
        }
    }
}

/// A login text field: a card with adaptive height (always >= 44pt).
private struct LoginField: ViewModifier {
    var minHeight: CGFloat = 50

    func body(content: Content) -> some View {
        content
            .font(.body)
            .padding(.horizontal, 14)
            .frame(minHeight: minHeight)
            .taproomCard()
    }
}
