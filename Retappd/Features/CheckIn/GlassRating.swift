import SwiftUI

/// A tapered pint glass.
struct PintShape: Shape {
    var taper: CGFloat = 0.13

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let inset = rect.width * taper
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Carbonation: a small particle simulation. While you pour, new bubbles form throughout the
/// beer (a little more towards the top while you're filling it up);
/// each rises at its own steady pace (unaffected by the pour), and pops when it reaches the
/// surface. A tap on the glass releases a burst of them. When you stop, no new ones form and the
/// rest fade out as they keep rising.
private struct Bubbles: View {
    var emitting: Bool
    /// Whether the glass is being filled up rather than emptied.
    var filling: Bool
    /// Bumped on each tap, to release a burst.
    var bursts: Int
    @State private var field = BubbleField()
    @State private var running = false
    @State private var stopTask: Task<Void, Never>?
    /// A burst stays at full strength until this time before it starts to fade.
    @State private var holdUntil = 0.0

    private static let burstHold = 0.6

    var body: some View {
        TimelineView(.animation(paused: !running)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                field.step(to: now, size: size, emitting: emitting, filling: filling)
                field.draw(in: &gc, size: size, now: now)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: emitting, initial: true) { _, on in
            if on {
                stopTask?.cancel()
                field.fadeStart = nil
                running = true
            } else if running {
                fadeOut()
            }
        }
        .onChange(of: bursts) {
            field.pendingBurst += BubbleField.burstSize
            holdUntil = Date.now.timeIntervalSinceReferenceDate + Self.burstHold
            running = true
            if !emitting { fadeOut() }
        }
        .onDisappear {
            stopTask?.cancel()
            running = false
        }
    }

    /// Starts the fade (after any burst has had its moment), then stops the animation once
    /// everything has faded.
    private func fadeOut() {
        stopTask?.cancel()
        let now = Date.now.timeIntervalSinceReferenceDate
        let hold = max(holdUntil - now, 0)
        field.fadeStart = now + hold
        stopTask = Task {
            try? await Task.sleep(for: .seconds(hold + BubbleField.fadeDuration + 0.1))
            guard !Task.isCancelled else { return }
            running = false
            field.removeAll()
        }
    }
}

/// The bubbles' state, advanced each frame. Positions are in points up from the bottom of the
/// beer, so a bubble's motion doesn't depend on how full the glass is.
private final class BubbleField {
    static let fadeDuration = 2.4
    static let burstSize = 18

    private struct Bubble {
        var x: Double        // 0...1 across the glass
        var y: Double        // points above the bottom
        var radius: Double
        var speed: Double    // points per second, constant
        var wobble: Double   // radians per second
        var phase: Double
        var born: Double
        var poppedAt: Double?
    }

    /// When the bubbles start fading out, if they are.
    var fadeStart: Double?
    /// Bubbles to release all at once on the next frame.
    var pendingBurst = 0
    private var bubbles: [Bubble] = []
    private var last: Double?
    private var spawnDebt = 0.0
    private let spawnRate = 15.0     // per second while pouring
    private let popDuration = 0.28

    func removeAll() {
        bubbles.removeAll()
        last = nil
        spawnDebt = 0
        pendingBurst = 0
        fadeStart = nil
    }

    func step(to now: Double, size: CGSize, emitting: Bool, filling: Bool) {
        let dt = min(max(now - (last ?? now), 0), 0.1)
        last = now
        let surface = Double(size.height)
        for i in bubbles.indices where bubbles[i].poppedAt == nil {
            bubbles[i].y += bubbles[i].speed * dt
            // Pop at the surface, including when the glass is emptied down past a bubble.
            if bubbles[i].y + bubbles[i].radius >= surface {
                bubbles[i].y = max(surface - bubbles[i].radius, 0)
                bubbles[i].poppedAt = now
            }
        }
        bubbles.removeAll { b in b.poppedAt.map { now - $0 > popDuration } ?? false }

        // Wait for a tap's burst until there's enough beer (the glass may still be filling).
        guard surface > 16 else { return }
        // A tap's burst is spread evenly through the beer.
        for _ in 0..<pendingBurst { spawn(at: now, surface: surface, towardsTop: false) }
        pendingBurst = 0

        guard emitting else { return }
        spawnDebt += dt * spawnRate
        while spawnDebt >= 1 {
            spawnDebt -= 1
            spawn(at: now, surface: surface, towardsTop: filling)
        }
    }

    private func spawn(at now: Double, surface: Double, towardsTop: Bool) {
        let radius = Double.random(in: 1.2...3.2)
        // Anywhere in the beer; a power below 1 skews towards the top.
        let u = towardsTop ? pow(Double.random(in: 0...1), 0.65) : Double.random(in: 0...1)
        bubbles.append(Bubble(
            x: .random(in: 0.15...0.85),
            y: u * max(surface - radius - 6, 0),
            radius: radius,
            speed: .random(in: 28...58.8),
            wobble: .random(in: 1.5...3.5),
            phase: .random(in: 0...(2 * .pi)),
            born: now))
    }

    func draw(in gc: inout GraphicsContext, size: CGSize, now: Double) {
        let fade = fadeStart.map { min(max(0, 1 - (now - $0) / Self.fadeDuration), 1) } ?? 1
        guard fade > 0 else { return }
        let h = Double(size.height)
        for b in bubbles {
            let x = Double(size.width) * b.x + sin((now - b.born) * b.wobble + b.phase) * 2
            let cy = h - b.y
            if let popped = b.poppedAt {
                // A ring that spreads and vanishes.
                let p = min((now - popped) / popDuration, 1)
                let r = b.radius * (1 + 1.6 * p)
                let rect = CGRect(x: x - r, y: cy - r, width: r * 2, height: r * 2)
                gc.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.7 * (1 - p) * fade)), lineWidth: 1)
            } else {
                let fadeIn = min((now - b.born) / 0.25, 1)
                let rect = CGRect(x: x - b.radius, y: cy - b.radius, width: b.radius * 2, height: b.radius * 2)
                gc.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.6 * fadeIn * fade)))
            }
        }
    }
}

/// A rating control drawn as a pint glass: drag up or down on it to fill it to your score.
struct GlassRating: View {
    @Binding var rating: Double
    /// 0.1 or 0.25.
    var step: Double
    /// Bumped to trigger a prefill pour animation with bubbles.
    var pourTrigger: Int = 0
    /// Called when the user interacts with the glass (drag, tap, or VoiceOver adjust).
    var onUserInteraction: (() -> Void)? = nil

    /// How full the glass is at 5, leaving room for the head.
    private let maxFill = 0.93

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether you're dragging the glass, which pours in new bubbles.
    @State private var pouring = false
    /// Whether an automatic prefill pour is emitting bubbles.
    @State private var autoPouring = false
    @State private var autoPourTask: Task<Void, Never>?
    @State private var usePourSpring = false
    @State private var handledPour = 0
    /// Whether the latest drag movement was upwards.
    @State private var filling = true
    /// Counts taps on the glass, each of which releases a burst of bubbles.
    @State private var bursts = 0
    @State private var touchStart: Date?
    @State private var lastBurst = Date.distantPast

    /// Releases a burst, unless one tap has already been seen by the other gesture.
    private func burst() {
        guard Date.now.timeIntervalSince(lastBurst) > 0.3 else { return }
        lastBurst = .now
        bursts += 1
    }

    private func beginUserInteraction() {
        autoPourTask?.cancel()
        autoPourTask = nil
        autoPouring = false
        usePourSpring = false
        handledPour = pourTrigger
        onUserInteraction?()
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let level = h * CGFloat(min(max(rating, 0), 5) / 5 * maxFill)
            let pourSpring = !reduceMotion && (pourTrigger != handledPour || usePourSpring)
            ZStack(alignment: .bottom) {
                PintShape().fill(Taproom.glassInside)
                VStack(spacing: 0) {
                    if rating > 0 {
                        Rectangle().fill(Taproom.foam).frame(height: 16)
                            .overlay(alignment: .top) { Rectangle().fill(Taproom.border).frame(height: 1) }
                    }
                    Rectangle().fill(Taproom.amber).frame(height: level)
                        .overlay {
                            if !reduceMotion {
                                Bubbles(emitting: pouring || autoPouring, filling: autoPouring ? true : filling, bursts: bursts)
                            }
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .clipShape(PintShape())
                PintShape().stroke(Taproom.glassRim, lineWidth: 2)
            }
            .animation(pourSpring ? .spring(response: 0.55, dampingFraction: 0.85) : .interactiveSpring(response: 0.25, dampingFraction: 0.85), value: rating)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard h > 0 else { return }
                        if !pouring { beginUserInteraction() }
                        rating = snap(Double((h - v.location.y) / (h * maxFill)) * 5)
                        if !pouring { pouring = true }
                        if touchStart == nil { touchStart = .now }
                        // Only flip direction on a clear movement, so a pause doesn't flicker it.
                        if v.velocity.height < -20 { filling = true } else if v.velocity.height > 20 { filling = false }
                    }
                    .onEnded { v in
                        let quick = touchStart.map { Date.now.timeIntervalSince($0) < 0.35 } ?? false
                        if quick && hypot(v.translation.width, v.translation.height) < 10 { burst() }
                        touchStart = nil
                        pouring = false
                    }
            )
            // A quick tap can finish before the drag gesture starts, so it's caught here too.
            .simultaneousGesture(
                SpatialTapGesture().onEnded { v in
                    guard h > 0 else { return }
                    beginUserInteraction()
                    rating = snap(Double((h - v.location.y) / (h * maxFill)) * 5)
                    burst()
                }
            )
        }
        .onChange(of: pourTrigger) {
            handledPour = pourTrigger
            guard !reduceMotion && rating > 0 else { return }
            autoPourTask?.cancel()
            usePourSpring = true
            filling = true
            autoPouring = true
            bursts += 1
            autoPourTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                autoPouring = false
                usePourSpring = false
            }
        }
        .onDisappear {
            autoPourTask?.cancel()
            autoPourTask = nil
        }
        .sensoryFeedback(.selection, trigger: rating)
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue(rating == 0 ? "None" : "\(Self.format(rating, step: step)) out of 5")
        .accessibilityHint("Swipe up or down to change it")
        .accessibilityAdjustableAction { dir in
            beginUserInteraction()
            switch dir {
            case .increment: rating = snap(rating + step)
            case .decrement: rating = snap(rating - step)
            @unknown default: break
            }
        }
    }

    static func prefillTarget(lastRating: Double?, step: Double) -> Double? {
        guard let lastRating, lastRating > 0 else { return nil }
        return max(snap(lastRating, step: step), step)
    }

    static func snap(_ raw: Double, step: Double) -> Double {
        let snapped = (min(max(raw, 0), 5) / step).rounded() * step
        return (snapped * 100).rounded() / 100
    }

    private func snap(_ raw: Double) -> Double {
        Self.snap(raw, step: step)
    }

    /// One decimal place in 0.1 steps, two in quarter steps.
    static func format(_ rating: Double, step: Double) -> String {
        rating.formatted(.number.precision(.fractionLength(step < 0.25 ? 1 : 2)))
    }
}
