import SwiftUI
import UIKit

/// Pure geometry and gesture math for `PhotoViewer`, separated for unit testing.
enum PhotoViewerZoom {
    static let minimumZoomScale: CGFloat = 1.0
    static let maximumZoomScale: CGFloat = 5.0
    static let doubleTapZoomScale: CGFloat = 2.5
    static let dismissDistanceThreshold: CGFloat = 110
    static let dismissVelocityThreshold: CGFloat = 700
    static let dismissMaxDistance: CGFloat = 300

    /// Aspect-fit size of an image inside the given bounds.
    static func aspectFitSize(imageSize: CGSize, in boundsSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              boundsSize.width > 0, boundsSize.height > 0 else { return .zero }
        let scale = min(boundsSize.width / imageSize.width, boundsSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// Rect in the zoomed content view's coordinate space that zooms to `scale` centered on `center`.
    static func zoomRect(scale: CGFloat, center: CGPoint, in boundsSize: CGSize) -> CGRect {
        guard scale > 0, boundsSize.width > 0, boundsSize.height > 0 else { return .zero }
        let width = boundsSize.width / scale
        let height = boundsSize.height / scale
        return CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
    }

    /// Normalized 0...1 progress for vertical swipe-to-dismiss, used to dim the backdrop.
    static func dismissProgress(translationY: CGFloat, maxDistance: CGFloat = dismissMaxDistance) -> CGFloat {
        guard maxDistance > 0, translationY > 0 else { return 0 }
        return min(translationY / maxDistance, 1)
    }

    /// Whether releasing a vertical swipe-to-dismiss gesture should dismiss the viewer.
    static func shouldDismiss(translationY: CGFloat, velocityY: CGFloat) -> Bool {
        translationY > dismissDistanceThreshold
            || (translationY > 0 && velocityY > dismissVelocityThreshold)
    }
}

/// Full-screen zoomable photo viewer with pinch-to-zoom, double-tap zoom, and swipe-down to dismiss.
struct PhotoViewer: View {
    let url: URL
    var placeholder: URL? = nil
    var title: String = "Photo"

    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage?
    @State private var placeholderImage: UIImage?
    @State private var dragProgress: CGFloat = 0

    private var displayedImage: UIImage? {
        fullImage
            ?? ImagePipeline.shared.cached(url, maxPixel: 2400)
            ?? placeholderImage
            ?? placeholder.flatMap { ImagePipeline.shared.cached($0, maxPixel: 1000) }
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(max(0, 1 - Double(dragProgress) * 0.85))
                .ignoresSafeArea()

            if let image = displayedImage {
                ZoomableImageScrollView(
                    image: image,
                    accessibilityLabel: title,
                    onDragProgress: { dragProgress = $0 },
                    onDismiss: { dismiss() }
                )
                .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel("Loading \(title)")
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark.circle.fill") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.55))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .opacity(max(0, 1 - Double(dragProgress) * 2))
                .padding(.top, 8)
                .padding(.trailing, 12)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("photoViewer.close")
        }
        .accessibilityAction(.escape) { dismiss() }
        .presentationBackground(.clear)
        .task(id: url) {
            async let full = ImagePipeline.shared.image(url, maxPixel: 2400)
            if let placeholder, placeholder != url,
               ImagePipeline.shared.cached(url, maxPixel: 2400) == nil {
                Task {
                    if let ph = await ImagePipeline.shared.image(placeholder, maxPixel: 1000) {
                        placeholderImage = ph
                    }
                }
            }
            if let loaded = await full {
                fullImage = loaded
            }
        }
    }
}

private struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage
    let accessibilityLabel: String
    let onDragProgress: (CGFloat) -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDragProgress: onDragProgress, onDismiss: onDismiss)
    }

    func makeUIView(context: Context) -> PhotoZoomScrollView {
        let scrollView = PhotoZoomScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = PhotoViewerZoom.minimumZoomScale
        scrollView.maximumZoomScale = PhotoViewerZoom.maximumZoomScale
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        scrollView.imageView.isAccessibilityElement = true
        scrollView.imageView.accessibilityTraits = .image
        scrollView.imageView.accessibilityLabel = accessibilityLabel
        scrollView.updateImage(image)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let dismissPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDismissPan(_:))
        )
        dismissPan.maximumNumberOfTouches = 1
        dismissPan.delegate = context.coordinator
        scrollView.addGestureRecognizer(dismissPan)

        context.coordinator.scrollView = scrollView
        context.coordinator.dismissPan = dismissPan
        return scrollView
    }

    func updateUIView(_ scrollView: PhotoZoomScrollView, context: Context) {
        context.coordinator.onDragProgress = onDragProgress
        context.coordinator.onDismiss = onDismiss
        scrollView.imageView.accessibilityLabel = accessibilityLabel
        scrollView.updateImage(image)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var scrollView: PhotoZoomScrollView?
        weak var dismissPan: UIPanGestureRecognizer?
        var onDragProgress: (CGFloat) -> Void
        var onDismiss: () -> Void

        init(onDragProgress: @escaping (CGFloat) -> Void, onDismiss: @escaping () -> Void) {
            self.onDragProgress = onDragProgress
            self.onDismiss = onDismiss
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? PhotoZoomScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? PhotoZoomScrollView)?.centerImageView()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let animated = !UIAccessibility.isReduceMotionEnabled
            if scrollView.zoomScale > 1.05 {
                scrollView.setZoomScale(PhotoViewerZoom.minimumZoomScale, animated: animated)
            } else {
                let rawPoint = gesture.location(in: scrollView.imageView)
                let clamped = CGPoint(
                    x: min(max(rawPoint.x, 0), scrollView.imageView.bounds.width),
                    y: min(max(rawPoint.y, 0), scrollView.imageView.bounds.height)
                )
                let rect = PhotoViewerZoom.zoomRect(
                    scale: PhotoViewerZoom.doubleTapZoomScale,
                    center: clamped,
                    in: scrollView.bounds.size
                )
                scrollView.zoom(to: rect, animated: animated)
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === dismissPan, let scrollView, let pan = dismissPan else {
                return true
            }
            guard pan.numberOfTouches == 1, !scrollView.isZooming, scrollView.zoomScale <= 1.01 else {
                return false
            }
            let velocity = pan.velocity(in: scrollView)
            return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
        }

        @objc func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView else { return }
            let translation = gesture.translation(in: scrollView)
            let velocity = gesture.velocity(in: scrollView)

            switch gesture.state {
            case .changed:
                let dy = translation.y >= 0 ? translation.y : translation.y * 0.25
                scrollView.transform = CGAffineTransform(translationX: 0, y: dy)
                onDragProgress(PhotoViewerZoom.dismissProgress(translationY: dy))
            case .ended:
                if PhotoViewerZoom.shouldDismiss(translationY: translation.y, velocityY: velocity.y) {
                    onDismiss()
                } else {
                    resetPosition(scrollView)
                }
            case .cancelled, .failed:
                resetPosition(scrollView)
            default:
                break
            }
        }

        private func resetPosition(_ scrollView: PhotoZoomScrollView) {
            onDragProgress(0)
            if UIAccessibility.isReduceMotionEnabled {
                scrollView.transform = .identity
            } else {
                UIView.animate(
                    withDuration: 0.25,
                    delay: 0,
                    usingSpringWithDamping: 0.85,
                    initialSpringVelocity: 0
                ) {
                    scrollView.transform = .identity
                }
            }
        }
    }
}

private final class PhotoZoomScrollView: UIScrollView {
    let imageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.isUserInteractionEnabled = true
        return view
    }()

    private var lastLayoutSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateImage(_ image: UIImage) {
        let sameReference = imageView.image === image
        imageView.image = image
        guard !sameReference else { return }
        fitImageIfNeeded(forceResetZoom: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            fitImageIfNeeded(forceResetZoom: true)
        }
    }

    private func fitImageIfNeeded(forceResetZoom: Bool) {
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        let fitted = PhotoViewerZoom.aspectFitSize(imageSize: image.size, in: bounds.size)
        guard fitted.width > 0, fitted.height > 0 else { return }

        if !forceResetZoom {
            let currentBaseSize = imageView.bounds.size
            if abs(currentBaseSize.width - fitted.width) < 0.5,
               abs(currentBaseSize.height - fitted.height) < 0.5 {
                // HD replacement with the same aspect ratio: preserve current zoom and offset.
                return
            }
        }

        let preservedScale = forceResetZoom ? PhotoViewerZoom.minimumZoomScale : zoomScale
        zoomScale = PhotoViewerZoom.minimumZoomScale
        imageView.transform = .identity
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        if preservedScale > PhotoViewerZoom.minimumZoomScale {
            zoomScale = min(preservedScale, maximumZoomScale)
        }
        centerImageView()
    }

    func centerImageView() {
        let boundsSize = bounds.size
        var frameToCenter = imageView.frame
        frameToCenter.origin.x = frameToCenter.width < boundsSize.width
            ? (boundsSize.width - frameToCenter.width) / 2
            : 0
        frameToCenter.origin.y = frameToCenter.height < boundsSize.height
            ? (boundsSize.height - frameToCenter.height) / 2
            : 0
        imageView.frame = frameToCenter
    }
}
