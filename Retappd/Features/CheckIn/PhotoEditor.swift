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
                let frame = PhotoEdit.frame(for: image.size, in: geo.size)
                cropView(frame: frame)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
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
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button { rotate() } label: { Image(systemName: "rotate.right") }
                        .accessibilityLabel("Rotate")
                    Button("Done") { finish() }.fontWeight(.semibold)
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

    private func cropView(frame: CGSize) -> some View {
        let z = min(max(zoom * pinch, 1), maxZoom)
        let clamped = clamp(CGSize(width: offset.width + drag.width, height: offset.height + drag.height),
                            zoom: z, frame: frame)
        return Image(uiImage: image)
            .resizable()
            .frame(width: frame.width * z, height: frame.height * z)
            .offset(clamped)
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .overlay(Rectangle().stroke(.white.opacity(0.7), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { pinch = $0.magnification }
                    .onEnded { value in
                        zoom = min(max(zoom * value.magnification, 1), maxZoom)
                        pinch = 1
                        offset = clamp(offset, zoom: zoom, frame: frame)
                    }
                    .simultaneously(with: DragGesture()
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            offset = clamp(CGSize(width: offset.width + value.translation.width,
                                                  height: offset.height + value.translation.height),
                                           zoom: min(max(zoom * pinch, 1), maxZoom), frame: frame)
                            drag = .zero
                            })
            )
            .accessibilityLabel("Photo crop")
            .accessibilityHint("Pinch to zoom, drag to move")
    }

    /// Keeps the image covering the frame.
    private func clamp(_ o: CGSize, zoom z: CGFloat, frame: CGSize) -> CGSize {
        let mx = frame.width * (z - 1) / 2, my = frame.height * (z - 1) / 2
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }

    private func rotate() {
        didMutate = true
        image = PhotoEdit.rotated(PhotoEdit.upright(image))
        zoom = 1; offset = .zero
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func finish() {
        let upright = PhotoEdit.upright(image)
        // The frame has the image's aspect ratio, so the visible region is the image divided by the zoom,
        // centred and shifted by the offset (expressed as a fraction of the frame).
        let frame = PhotoEdit.frame(for: upright.size, in: available)
        guard frame.width > 0, frame.height > 0 else {
            onDone(upright)
            dismiss()
            return
        }
        let o = clamp(offset, zoom: zoom, frame: frame)
        let size = upright.size
        let w = size.width / zoom, h = size.height / zoom
        let x = (size.width - w) / 2 - o.width / frame.width * size.width / zoom
        let y = (size.height - h) / 2 - o.height / frame.height * size.height / zoom
        onDone(PhotoEdit.cropped(upright, to: CGRect(x: x, y: y, width: w, height: h)))
        dismiss()
    }
}

enum PhotoEdit {
    /// The largest rectangle with `size`'s aspect ratio that fits in `container`,.
    static func frame(for size: CGSize, in container: CGSize) -> CGSize {
        let s = min(container.width / max(size.width, 1), container.height / max(size.height, 1))
        return CGSize(width: size.width * s, height: size.height * s)
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
