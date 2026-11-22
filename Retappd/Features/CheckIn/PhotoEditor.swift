import SwiftUI
import UIKit

/// Full-screen editor for a checkin photo: pinch to zoom and drag to crop, rotate in quarter turns.
/// The crop is whatever is visible inside the frame when the user taps Done.
struct PhotoEditor: View {
    let onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage
    @State private var didMutate = false
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var drag: CGSize = .zero
    @State private var available: CGSize = .zero

    init(image: UIImage, onDone: @escaping (UIImage) -> Void) {
        _image = State(initialValue: image)
        self.onDone = onDone
    }

    private let maxZoom: CGFloat = 8

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let frame = PhotoEdit.cropFrame(for: image.size, in: geo.size)
                cropView(frame: frame, in: geo.size)
                    .onChange(of: geo.size, initial: true) { _, new in available = new }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                        .accessibilityIdentifier("photoEditor.cancel")
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button { rotate() } label: { Image(systemName: "rotate.right") }
                        .accessibilityLabel("Rotate")
                        .accessibilityIdentifier("photoEditor.rotate")
                    Button("Done") { finish() }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("photoEditor.done")
                }
            }
        }
        .tint(Taproom.amber)
        .preferredColorScheme(.dark)
        .task {
            guard image.imageOrientation != .up || image.scale != 1 else { return }
            let source = image
            let normalized = await Task.detached(priority: .userInitiated) {
                PhotoEdit.upright(source)
            }.value
            if !Task.isCancelled && !didMutate {
                image = normalized
            }
        }
    }

    private func cropView(frame: CGSize, in container: CGSize) -> some View {
        let z = min(max(zoom * pinch, 1), maxZoom)
        let clamped = PhotoEdit.clampedOffset(
            CGSize(width: offset.width + drag.width, height: offset.height + drag.height),
            zoom: z,
            frame: frame
        )
        let isInteracting = pinch != 1 || drag != .zero
        return ZStack {
            Image(uiImage: image)
                .resizable()
                .frame(width: frame.width * z, height: frame.height * z)
                .offset(clamped)

            CropScrim(cutoutSize: frame)
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .frame(width: container.width, height: container.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            cropFrameOverlay(frame: frame, showGrid: isInteracting)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: container.width, height: container.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            MagnifyGesture()
                .onChanged { pinch = $0.magnification }
                .onEnded { value in
                    zoom = min(max(zoom * value.magnification, 1), maxZoom)
                    pinch = 1
                    offset = PhotoEdit.clampedOffset(offset, zoom: zoom, frame: frame)
                }
                .simultaneously(with: DragGesture()
                    .onChanged { drag = $0.translation }
                    .onEnded { value in
                        offset = PhotoEdit.clampedOffset(
                            CGSize(width: offset.width + value.translation.width,
                                   height: offset.height + value.translation.height),
                            zoom: min(max(zoom * pinch, 1), maxZoom),
                            frame: frame
                        )
                        drag = .zero
                    })
        )
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("photoEditor.cropArea")
        .accessibilityLabel("Photo crop")
        .accessibilityHint("Pinch to zoom, drag to move")
    }

    private func cropFrameOverlay(frame: CGSize, showGrid: Bool) -> some View {
        ZStack {
            if showGrid {
                RuleOfThirdsGrid()
                    .stroke(.white.opacity(0.35), lineWidth: 0.5)
            }
            Rectangle()
                .stroke(.white.opacity(0.85), lineWidth: 1.5)
        }
        .frame(width: frame.width, height: frame.height)
    }

    private func rotate() {
        didMutate = true
        image = PhotoEdit.rotated(PhotoEdit.upright(image))
        zoom = 1
        pinch = 1
        offset = .zero
        drag = .zero
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func finish() {
        let upright = PhotoEdit.upright(image)
        // The frame has the image's aspect ratio at 80% of the container, so the visible region
        // is the image divided by the zoom, centred and shifted by the offset.
        let frame = PhotoEdit.cropFrame(for: upright.size, in: available)
        guard frame.width > 0, frame.height > 0 else {
            onDone(upright)
            dismiss()
            return
        }
        let rect = PhotoEdit.cropRect(imageSize: upright.size, frame: frame, zoom: zoom, offset: offset)
        onDone(PhotoEdit.cropped(upright, to: rect))
        dismiss()
    }
}

private struct CropScrim: Shape {
    let cutoutSize: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        let cutout = CGRect(
            x: rect.midX - cutoutSize.width / 2,
            y: rect.midY - cutoutSize.height / 2,
            width: cutoutSize.width,
            height: cutoutSize.height
        )
        path.addRect(cutout)
        return path
    }
}

private struct RuleOfThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
            let x = rect.minX + rect.width * fraction
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))

            let y = rect.minY + rect.height * fraction
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

enum PhotoEdit {
    /// Fraction of the editor container occupied by the crop frame, leaving room around it so
    /// zoomed-out / cropped-away portions of the photo remain visible.
    static let cropFrameScale: CGFloat = 0.8

    /// The largest rectangle with `size`'s aspect ratio that fits in `container`.
    static func frame(for size: CGSize, in container: CGSize) -> CGSize {
        let s = min(container.width / max(size.width, 1), container.height / max(size.height, 1))
        return CGSize(width: size.width * s, height: size.height * s)
    }

    /// The crop frame sized to `scale` (default 80%) of `container`, preserving `size`'s aspect ratio.
    static func cropFrame(for size: CGSize, in container: CGSize, scale: CGFloat = cropFrameScale) -> CGSize {
        frame(for: size, in: CGSize(width: container.width * scale, height: container.height * scale))
    }

    /// Clamps a drag offset so the zoomed photo always covers the entire crop frame.
    static func clampedOffset(_ offset: CGSize, zoom: CGFloat, frame: CGSize) -> CGSize {
        let z = max(zoom, 1)
        let mx = frame.width * (z - 1) / 2
        let my = frame.height * (z - 1) / 2
        return CGSize(width: min(max(offset.width, -mx), mx), height: min(max(offset.height, -my), my))
    }

    /// Computes the crop rectangle in `imageSize` coordinates corresponding to the visible `frame`
    /// at the given `zoom` and `offset`.
    static func cropRect(imageSize: CGSize, frame: CGSize, zoom: CGFloat, offset: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0 else {
            return CGRect(origin: .zero, size: imageSize)
        }
        let z = max(zoom, 1)
        let o = clampedOffset(offset, zoom: z, frame: frame)
        let w = imageSize.width / z
        let h = imageSize.height / z
        let x = (imageSize.width - w) / 2 - o.width / frame.width * imageSize.width / z
        let y = (imageSize.height - h) / 2 - o.height / frame.height * imageSize.height / z
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Redraws the image with its orientation baked in, at 1 pixel per point.
    static func upright(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up && image.scale == 1 { return image }
        return render(CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)) { size, _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// A quarter turn clockwise.
    static func rotated(_ image: UIImage) -> UIImage {
        let w = image.size.width, h = image.size.height
        return render(CGSize(width: h, height: w)) { _, ctx in
            ctx.translateBy(x: h, y: 0)
            ctx.rotate(by: .pi / 2)
            image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    static func cropped(_ image: UIImage, to rect: CGRect) -> UIImage {
        let r = rect.integral.intersection(CGRect(origin: .zero, size: image.size))
        guard r.width >= 1, r.height >= 1 else { return image }
        return render(r.size) { _, _ in image.draw(at: CGPoint(x: -r.origin.x, y: -r.origin.y)) }
    }

    private static func render(_ size: CGSize, _ draw: @escaping (CGSize, CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            draw(size, ctx.cgContext)
        }
    }
}
