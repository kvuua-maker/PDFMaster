import UIKit

/// Zoomable, pannable page canvas for placing an annotation precisely.
///
/// The page image lives inside a scroll view, which gives three things the
/// previous implementation did not have:
/// * pinch-to-zoom and a two-finger drag pan the page while a tool is active;
/// * every touch is converted through the content view, whose bounds are the
///   page itself, so the rectangle is exact at any zoom level or scroll offset
///   (before, raw screen points were divided by the container size, which
///   shifted the annotation whenever the page was letterboxed, zoomed or
///   scrolled);
/// * one finger draws — for underline and strike-through the drag distance
///   sets the line length, so the line ends where the finger is lifted.
@MainActor
final class AnnotationCanvasView: UIView {
    let scrollView = UIScrollView()
    let content = UIView()

    private let imageView = UIImageView()
    private let selectionLayer = CAShapeLayer()
    private let zoomDelegate = CanvasZoomDelegate()
    private let drawGesture = UIPanGestureRecognizer()

    private let pageImage: UIImage
    private var kind: PDFAnnotationKind
    /// Normalised selection (0…1, top-left origin), the coordinate space the
    /// PDF engine expects.
    private var selection: CGRect?
    private var startPoint: CGPoint?
    private var fitted = false

    /// Called on the main actor after a drag finishes.
    var onSelection: ((CGRect?) -> Void)?

    init(image: UIImage, kind: PDFAnnotationKind) {
        self.pageImage = image
        self.kind = kind
        super.init(frame: .zero)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUp() {
        backgroundColor = .clear
        clipsToBounds = true

        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = zoomDelegate
        zoomDelegate.canvas = self
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        // One finger belongs to the tool; two fingers zoom and pan.
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        addSubview(scrollView)

        content.frame = CGRect(origin: .zero, size: pageImage.size)
        content.isUserInteractionEnabled = true
        scrollView.addSubview(content)

        imageView.frame = content.bounds
        imageView.image = pageImage
        imageView.isUserInteractionEnabled = false
        content.addSubview(imageView)

        selectionLayer.frame = content.bounds
        selectionLayer.fillColor = kind.color.withAlphaComponent(0.22).cgColor
        selectionLayer.strokeColor = kind.color.cgColor
        selectionLayer.lineWidth = 2
        content.layer.addSublayer(selectionLayer)

        drawGesture.addTarget(self, action: #selector(handleDraw(_:)))
        drawGesture.maximumNumberOfTouches = 1
        content.addGestureRecognizer(drawGesture)
    }

    /// The tool can change while the canvas is on screen.
    func update(kind newKind: PDFAnnotationKind) {
        if newKind == kind { return }
        kind = newKind
        selectionLayer.fillColor = newKind.color.withAlphaComponent(0.22).cgColor
        selectionLayer.strokeColor = newKind.color.cgColor
        renderSelection()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard bounds.width > 1, bounds.height > 1,
              pageImage.size.width > 1, pageImage.size.height > 1 else { return }
        let fit = min(bounds.width / pageImage.size.width,
                      bounds.height / pageImage.size.height)
        guard fit > 0 else { return }
        scrollView.minimumZoomScale = fit
        scrollView.maximumZoomScale = max(fit * 6, fit + 0.5)
        if !fitted {
            fitted = true
            scrollView.zoomScale = fit
        } else if scrollView.zoomScale < fit {
            scrollView.zoomScale = fit
        }
        updateZoomInsets()
    }

    /// Keeps the page centred when it is smaller than the viewport, exactly
    /// like a photo viewer, and never moves content that is zoomed in.
    func updateZoomInsets() {
        let viewport = scrollView.bounds.size
        guard viewport.width > 1, viewport.height > 1 else { return }
        let scaled = CGSize(width: pageImage.size.width * scrollView.zoomScale,
                            height: pageImage.size.height * scrollView.zoomScale)
        let horizontal = max((viewport.width - scaled.width) / 2, 0)
        let vertical = max((viewport.height - scaled.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal,
                                               bottom: vertical, right: horizontal)
        renderSelection()
    }

    @objc private func handleDraw(_ gesture: UIPanGestureRecognizer) {
        let location = clampToPage(gesture.location(in: content))
        switch gesture.state {
        case .began:
            startPoint = location
            selection = makeSelection(from: location, to: location)
            renderSelection()
        case .changed:
            guard let startPoint else { return }
            selection = makeSelection(from: startPoint, to: location)
            renderSelection()
        case .ended, .cancelled, .failed:
            guard let startPoint else { return }
            self.startPoint = nil
            let finished = makeSelection(from: startPoint, to: location)
            selection = finished
            renderSelection()
            onSelection?(finished)
        default:
            break
        }
    }

    private func clampToPage(_ point: CGPoint) -> CGPoint {
        let size = content.bounds.size
        return CGPoint(x: min(max(point.x, 0), size.width),
                       y: min(max(point.y, 0), size.height))
    }

    private func makeSelection(from start: CGPoint, to end: CGPoint) -> CGRect {
        let size = content.bounds.size
        guard size.width > 1, size.height > 1 else { return .zero }
        if kind == .underline || kind == .strikeOut {
            let length = max(abs(end.x - start.x), size.width * 0.02)
            let band = max(size.height * 0.022, 4)
            // PDFKit paints an underline along the bottom of the bounds and a
            // strike-through through the middle, so the band is shifted to keep
            // the visible line exactly where the finger is.
            let lineY = kind == .underline ? start.y - band : start.y - band / 2
            let originX = min(max(min(start.x, end.x), 0), max(size.width - length, 0))
            let originY = min(max(lineY, 0), max(size.height - band, 0))
            let rect = CGRect(x: originX, y: originY,
                              width: min(length, size.width), height: band)
            return normalise(rect, in: size)
        }
        let originX = min(start.x, end.x)
        let originY = min(start.y, end.y)
        let width = max(abs(end.x - start.x), size.width * 0.03)
        let height = max(abs(end.y - start.y), size.height * 0.02)
        return normalise(CGRect(x: originX, y: originY, width: width, height: height),
                         in: size)
    }

    private func normalise(_ rect: CGRect, in size: CGSize) -> CGRect {
        let x = min(max(rect.minX / size.width, 0), 1)
        let y = min(max(rect.minY / size.height, 0), 1)
        let width = min(max(rect.width / size.width, 0.001), 1 - x)
        let height = min(max(rect.height / size.height, 0.001), 1 - y)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func renderSelection() {
        guard let selection else {
            selectionLayer.path = nil
            return
        }
        let size = content.bounds.size
        let rect = CGRect(x: selection.minX * size.width,
                          y: selection.minY * size.height,
                          width: selection.width * size.width,
                          height: selection.height * size.height)
        selectionLayer.path = UIBezierPath(rect: rect).cgPath
        // Keep the outline one physical pixel-ish wide at every zoom level.
        selectionLayer.lineWidth = max(1.5 / max(scrollView.zoomScale, 0.05), 0.4)
    }
}

/// Scroll-view delegate kept as a plain `NSObject` so the conformance stays
/// outside the main-actor-isolated view, the same pattern the camera and
/// scanner bridges use.
private final class CanvasZoomDelegate: NSObject, UIScrollViewDelegate {
    weak var canvas: AnnotationCanvasView?

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        guard let canvas else { return nil }
        var zoomingView: UIView?
        MainActor.assumeIsolated { zoomingView = canvas.content }
        return zoomingView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard let canvas else { return }
        MainActor.assumeIsolated { canvas.updateZoomInsets() }
    }
}
