import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins
import Vision
import VisionKit

/// Untappd's Friend Nametag QR codes: `https://untappd.com/qr/namecard/<uid>`.
///
/// The official app encodes a static URL containing only the user's numeric `uid`. Untappd's
/// `GET /v4/user/info/{username}` endpoint does not accept a numeric `uid`, so scanning resolves
/// the `uid` to a username via the public namecard landing page, then fetches `user/info` and
/// verifies `profile.id == uid` (the web page falls back to `/user/You` for unknown ids).
enum FriendQRCode {
    enum Target: Equatable, Sendable {
        case userID(Int)
        case username(String)
    }

    /// The canonical Friend Nametag URL that the official Untappd app generates and scans.
    static func url(forUserID uid: Int) -> URL {
        URL(string: "https://untappd.com/qr/namecard/\(uid)")!
    }

    /// Parses a scanned QR payload into an Untappd user target, or `nil` if it isn't one.
    /// Accepts `https://untappd.com/qr/namecard/<uid>`, `https://untappd.com/user/<username>`,
    /// and `untappd://user/<username>`.
    static func parse(_ payload: String) -> Target? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return nil
        }

        if scheme == "untappd" {
            guard url.host?.lowercased() == "user" else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            guard let raw = parts.first, let name = Friends.normalized(raw) else { return nil }
            return .username(name)
        }

        guard scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              host == "untappd.com" || host == "www.untappd.com"
        else { return nil }

        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 3, parts[0].lowercased() == "qr", parts[1].lowercased() == "namecard" {
            guard let uid = Int(parts[2]), uid > 0 else { return nil }
            return .userID(uid)
        }
        if parts.count >= 2, parts[0].lowercased() == "user" {
            guard let name = Friends.normalized(parts[1]) else { return nil }
            return .username(name)
        }
        return nil
    }

    /// Extracts the username from Untappd's `/qr/namecard/<uid>` HTML landing page.
    static func extractUsername(fromNamecardHTML html: String) -> String? {
        let patterns = [
            #"href="/user/([A-Za-z0-9_.\-]+)""#,
            #"var\s+id\s*=\s*"([A-Za-z0-9_.\-]+)""#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, range: range),
               let capture = Range(match.range(at: 1), in: html),
               let name = Friends.normalized(String(html[capture])) {
                return name
            }
        }
        return nil
    }

    typealias NamecardHTMLFetch = @Sendable (URL) async throws -> String
    typealias UserInfoFetch = @Sendable (String) async throws -> UserInfo.Profile?

    /// Resolves a parsed QR target to a full `UserInfo.Profile` (including friendship relationship),
    /// returning `nil` if no matching user exists.
    static func resolve(
        _ target: Target,
        fetchNamecardHTML: NamecardHTMLFetch = defaultFetchNamecardHTML,
        fetchUserInfo: UserInfoFetch = defaultFetchUserInfo
    ) async throws -> UserInfo.Profile? {
        switch target {
        case .username(let name):
            let profile = try await fetchUserInfo(name)
            return profile.flatMap { $0.id != 0 ? $0 : nil }

        case .userID(let uid):
            let html = try await fetchNamecardHTML(url(forUserID: uid))
            guard let name = extractUsername(fromNamecardHTML: html) else { return nil }
            guard let profile = try await fetchUserInfo(name), profile.id == uid else { return nil }
            return profile
        }
    }

    static func defaultFetchNamecardHTML(_ url: URL) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, resp) = try await UntappdAPI.shared.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.http(status) }
        return String(decoding: data, as: UTF8.self)
    }

    static func defaultFetchUserInfo(_ username: String) async throws -> UserInfo.Profile? {
        do {
            let info = try await UntappdAPI.shared.fetch(.userInfo(username), as: UserInfo.self)
            return info.user
        } catch let e as APIError where Friends.isNotFound(e) {
            return nil
        }
    }

    /// Renders a crisp QR code image for `url` using error-correction level `Q` (25% recovery,
    /// safely tolerating a small centered avatar badge). Always dark modules on a white background
    /// so cameras scan it reliably in both light and dark mode.
    static func renderQRCode(for url: URL, size: CGFloat = 600) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage else { return nil }

        // Color dark modules in warm ink-black on pure white.
        let colorFilter = CIFilter.falseColor()
        colorFilter.inputImage = output
        colorFilter.color0 = CIColor(red: 0x2B / 255.0, green: 0x21 / 255.0, blue: 0x18 / 255.0)
        colorFilter.color1 = CIColor(red: 1, green: 1, blue: 1)
        let colored = colorFilter.outputImage ?? output

        let extent = colored.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }
        let quietModules: CGFloat = 2
        let paddedExtent = extent.insetBy(dx: -quietModules, dy: -quietModules)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: paddedExtent)
        let composited = colored.composited(over: white)
        let scale = max(1, floor(size / max(paddedExtent.width, paddedExtent.height)))
        let scaled = composited.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - My Friend QR Code sheet

/// Shows the signed-in user's Friend QR code (compatible with the official Untappd app) and
/// offers a button to scan someone else's code.
struct FriendQRCodeSheet: View {
    let username: String
    var initialProfile: UserInfo.Profile? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var profile: UserInfo.Profile?
    @State private var loading = false
    @State private var loadError: String?
    @State private var qrImage: UIImage?
    @State private var showingScanner = false

    private var activeProfile: UserInfo.Profile? { profile ?? initialProfile }
    private var qrURL: URL? {
        guard let id = activeProfile?.id, id > 0 else { return nil }
        return FriendQRCode.url(forUserID: id)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Taproom.sectionSpacing) {
                    qrHero
                    Text("Friends can scan this in Retappd, the official Untappd app, or their phone camera.")
                        .font(.footnote)
                        .foregroundStyle(Taproom.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                .padding(.horizontal, Taproom.margin)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .readableContentWidth)
                .frame(maxWidth: .infinity)
            }
            .taproomScreen()
            .navigationTitle("Friend QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Taproom.background, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .tint(Taproom.ink)
                        .accessibilityIdentifier("friendQR.close")
                }
                if let qrURL {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: qrURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .tint(Taproom.ink)
                        .accessibilityLabel("Share QR code link")
                        .accessibilityIdentifier("friendQR.share")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan a QR code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(TaproomPrimaryButton())
                .accessibilityIdentifier("friendQR.scanButton")
                .taproomBottomBar()
            }
            .navigationDestination(isPresented: $showingScanner) {
                FriendQRScannerView(username: username)
            }
            .task { await loadProfile() }
        }
        .tint(Taproom.amber)
    }

    @ViewBuilder private var qrHero: some View {
        if let activeProfile, let qrImage {
            VStack(spacing: 16) {
                // Always white behind the QR code with a generous quiet zone so cameras can read
                // it reliably in both light and dark mode.
                ZStack {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("QR code for \(activeProfile.displayName)")
                    Avatar(url: activeProfile.avatar, size: 52)
                        .padding(4)
                        .background(Color.white, in: Circle())
                        .accessibilityHidden(true)
                }
                .padding(20)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Taproom.border))
                .frame(maxWidth: 280)

                VStack(spacing: 2) {
                    Text(activeProfile.displayName)
                        .font(.system(size: 22, weight: .heavy))
                        .tracking(-0.3)
                    Text("@" + activeProfile.userName)
                        .font(.subheadline)
                        .foregroundStyle(Taproom.muted)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .padding(.horizontal, 16)
            .taproomCard(cornerRadius: 20)
        } else if let loadError {
            ErrorRow(message: loadError) { Task { await loadProfile() } }
                .padding(.top, 24)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading your QR code…")
                    .font(.subheadline)
                    .foregroundStyle(Taproom.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 64)
            .taproomCard(cornerRadius: 20)
        }
    }

    private func loadProfile() async {
        if let p = activeProfile, p.id > 0 {
            if qrImage == nil {
                qrImage = FriendQRCode.renderQRCode(for: FriendQRCode.url(forUserID: p.id))
            }
            return
        }
        guard !loading else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let info = try await cacheThenNetwork(.userInfo(username), as: UserInfo.self) { cached in
                if let u = cached.user, u.id > 0 {
                    profile = u
                    qrImage = FriendQRCode.renderQRCode(for: FriendQRCode.url(forUserID: u.id))
                }
            }
            if let u = info.user, u.id > 0 {
                profile = u
                qrImage = FriendQRCode.renderQRCode(for: FriendQRCode.url(forUserID: u.id))
            } else {
                loadError = "Couldn't load your Untappd user ID."
            }
        } catch {
            if profile == nil {
                loadError = error.localizedDescription
            }
        }
    }
}

// MARK: - Friend QR Scanner

/// Standalone sheet wrapper for `FriendQRScannerView` (used when launched from `AddFriendView`).
struct FriendQRScannerSheet: View {
    let username: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FriendQRScannerView(username: username)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                            .tint(Taproom.ink)
                            .accessibilityIdentifier("friendQRScanner.close")
                    }
                }
        }
        .tint(Taproom.amber)
    }
}

/// Scans an Untappd Friend QR code (`untappd.com/qr/namecard/<uid>` or `untappd.com/user/<name>`),
/// resolves the person, and lets you send or accept a friend request.
struct FriendQRScannerView: View {
    let username: String

    private enum Phase: Equatable {
        case scanning
        case looking
        case found(UserInfo.Profile)
        case invalid(String)
        case missing
        case failed(FriendQRCode.Target, String)

        static func == (a: Phase, b: Phase) -> Bool {
            switch (a, b) {
            case (.scanning, .scanning), (.looking, .looking), (.missing, .missing): true
            case let (.found(x), .found(y)): x.id == y.id
            case let (.invalid(x), .invalid(y)): x == y
            case let (.failed(t1, m1), .failed(t2, m2)): t1 == t2 && m1 == m2
            default: false
            }
        }
    }

    @Environment(\.openURL) private var openURL
    @State private var phase = Phase.scanning
    @State private var cameraAllowed: Bool?
    @State private var lookupTask: Task<Void, Never>?
    #if DEBUG
    @State private var manualInput = ""
    @FocusState private var typing: Bool
    #endif

    private var canScan: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable && cameraAllowed == true
    }

    var body: some View {
        content
            .taproomScreen()
            .navigationTitle("Scan a QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Taproom.background, for: .navigationBar)
            .task { await askForCamera() }
            .onDisappear {
                lookupTask?.cancel()
                lookupTask = nil
            }
            .sensoryFeedback(.success, trigger: phase) { _, new in
                if case .looking = new { return true } else { return false }
            }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .scanning:
            VStack(spacing: 0) {
                scanner
                #if DEBUG
                manualEntry
                #endif
            }

        case .looking:
            VStack(spacing: 12) {
                ProgressView()
                Text("Looking up friend…")
                    .foregroundStyle(Taproom.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .found(let profile):
            ScrollView {
                AddFriendResultCard(profile: profile, me: username)
                    .padding(.horizontal, Taproom.margin)
                    .padding(.top, 16)
                    .frame(maxWidth: .readableContentWidth)
                    .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                scanAnotherBar
            }

        case .invalid(let raw):
            ContentUnavailableView {
                Label("Not a friend QR code", systemImage: "qrcode")
            } description: {
                Text("That code isn't an Untappd friend link (\(raw)).")
            } actions: {
                Button("Scan another") { resetScanner() }
                    .buttonStyle(TaproomOutlineButton())
                    .frame(maxWidth: 240)
            }

        case .missing:
            ContentUnavailableView {
                Label("User not found", systemImage: "person.fill.questionmark")
            } description: {
                Text("Untappd didn't recognize the account in that QR code.")
            } actions: {
                Button("Scan another") { resetScanner() }
                    .buttonStyle(TaproomOutlineButton())
                    .frame(maxWidth: 240)
            }

        case .failed(let target, let message):
            ContentUnavailableView {
                Label("Couldn't look up friend", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                VStack(spacing: 8) {
                    Button("Try again") { resolve(target) }
                        .buttonStyle(TaproomPrimaryButton())
                    Button("Scan another") { resetScanner() }
                        .buttonStyle(TaproomOutlineButton())
                }
                .frame(maxWidth: 280)
            }
        }
    }

    private var scanAnotherBar: some View {
        Button {
            resetScanner()
        } label: {
            Label("Scan another", systemImage: "qrcode.viewfinder")
        }
        .buttonStyle(TaproomOutlineButton())
        .accessibilityIdentifier("friendQRScanner.scanAnother")
        .taproomBottomBar()
    }

    @ViewBuilder private var scanner: some View {
        if canScan {
            BarcodeScanner(symbologies: [.qr]) { code in
                #if DEBUG
                if typing { return }
                #endif
                if case .scanning = phase { handleScannedPayload(code) }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Taproom.amber, lineWidth: 3)
                    .frame(width: 220, height: 220)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                Text("Point the camera at a friend's Untappd QR code")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
            }
            .ignoresSafeArea(edges: .horizontal)
        } else if cameraAllowed == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("Can't scan here", systemImage: "qrcode.viewfinder")
            } description: {
                Text(cameraAllowed == false
                     ? "Camera access is off. Turn it on in Settings to scan QR codes."
                     : "This device can't scan QR codes.")
            } actions: {
                if cameraAllowed == false, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(url) }
                        .buttonStyle(TaproomPrimaryButton())
                        .frame(maxWidth: 280)
                }
            }
        }
    }

    #if DEBUG
    /// Typed/pasted QR payload entry for driving the scanner in the simulator (which has no camera).
    /// Compiled out of Release builds.
    private var manualEntry: some View {
        HStack(spacing: 8) {
            TextField("Or paste QR URL or user ID", text: $manualInput,
                      prompt: Text("Or paste QR URL or user ID").foregroundStyle(Taproom.muted))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($typing)
                .onSubmit(submitManual)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .taproomCard(cornerRadius: 12)
                .accessibilityIdentifier("friendQRScanner.manualInput")
            Button("Scan", action: submitManual)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Taproom.background)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Taproom.ink, in: RoundedRectangle(cornerRadius: 12))
                .opacity(manualInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                .disabled(manualInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("friendQRScanner.manualSubmit")
        }
        .padding(Taproom.margin)
        .background(Taproom.background)
    }

    private func submitManual() {
        let trimmed = manualInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        typing = false
        if let uid = Int(trimmed), uid > 0 {
            handleScannedPayload(FriendQRCode.url(forUserID: uid).absoluteString)
        } else {
            handleScannedPayload(trimmed)
        }
    }
    #endif

    private func resetScanner() {
        lookupTask?.cancel()
        lookupTask = nil
        #if DEBUG
        manualInput = ""
        #endif
        phase = .scanning
    }

    private func handleScannedPayload(_ raw: String) {
        guard let target = FriendQRCode.parse(raw) else {
            phase = .invalid(raw)
            return
        }
        resolve(target)
    }

    private func resolve(_ target: FriendQRCode.Target) {
        lookupTask?.cancel()
        phase = .looking
        lookupTask = Task {
            do {
                if let profile = try await FriendQRCode.resolve(target) {
                    guard !Task.isCancelled else { return }
                    phase = .found(profile)
                } else {
                    guard !Task.isCancelled else { return }
                    phase = .missing
                }
            } catch {
                guard !Task.isCancelled, !error.isCancellation else { return }
                phase = .failed(target, error.localizedDescription)
            }
        }
    }

    private func askForCamera() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraAllowed = true
        case .notDetermined: cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
        default: cameraAllowed = false
        }
    }
}
