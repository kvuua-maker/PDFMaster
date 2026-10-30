import QuartzCore
import UIKit

/// Zoomable, pannable page canvas for placing an annotation precisely.
///
/// The page image lives inside a scroll view, which gives three things the
/// first implementation did not have:
/// * pinch-to-zoom and a two-finger drag pan the page while a tool is active;
/// * every touch is converted through the content view, whose bounds are the
///   page itself, so the rectangle is exact at any zoom level or scroll offset;
/// * one finger draws — for underline and strike-through the drag distance
///   sets the line length.
///
/// Line tools (underline, strike-through, circle) no longer select the finger's
/// rectangle. They snap to the glyph boxes of one text row, which is why the
/// selection can no longer swallow two lines. The row geometry is precomputed
/// by `PageTextMap`, so a drag does arithmetic only: no PDFKit call runs on the
/// gesture path and nothing blocks the main thread.
@MainActor
final class AnnotationCanvasView: UIView {
    let scrollView = UIScrollView()
    let content = UIView()

    private let imageView = UIImageView()
    private let selectionLayer = CAShapeLayer()
    private let targetLineLayer = CAShapeLayer()
    private let zoomDelegate = CanvasZoomDelegate()
    private let drawGesture = UIPanGestureRecognizer()
    private let wordTap = UITapGestureRecognizer()
    private let startHandle = SelectionHandleView(isStart: true)
    private let endHandle = SelectionHandleView(isStart: false)

    private let pageImage: UIImage
    private let textMap: PageTextMap?
    private var kind: PDFAnnotationKind

    /// Free rectangle tools, normalised (0…1, top-left origin).
    private var rectSelection: CGRect?
    private var committedRect: CGRect?
    private var rectAnchor: CGPoint?

    /// Line tools.
    private var lineSelection: PageLineSelection?
    private var committedLine: PageLineSelection?
    private var anchorLine: Int?
    private var dragStartX: CGFloat?

    private enum HandleRole { case start, end }

    private var fitted = false
    private var lastRender: CFTimeInterval = 0

    /// Called on the main actor after a selection is committed.
    var onSelection: ((CGRect?) -> Void)?

    init(image: UIImage, kind: PDFAnnotationKind, textMap: PageTextMap?) {
        self.pageImage = image
        self.kind = kind
        self.textMap = textMap
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

        targetLineLayer.frame = content.bounds
        targetLineLayer.fillColor = kind.color.withAlphaComponent(0.14).cgColor
        targetLineLayer.strokeColor = UIColor.clear.cgColor
        targetLineLayer.isHidden = true
        content.layer.insertSublayer(targetLineLayer, below: selectionLayer)

        drawGesture.addTarget(self, action: #selector(handleDraw(_:)))
        drawGesture.maximumNumberOfTouches = 1
        content.addGestureRecognizer(drawGesture)

        wordTap.addTarget(self, action: #selector(handleWordTap(_:)))
        wordTap.require(toFail: drawGesture)
        content.addGestureRecognizer(wordTap)

        // Handles sit above the scroll view, so a touch that starts on one of
        // them never reaches the draw gesture or the scroll pan: the drag is
        // already exclusive without a recogniser-priority dance.
        startHandle.setColor(kind.color)
        endHandle.setColor(kind.color)
        startHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleStartPanned(_:))))
        endHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleEndPanned(_:))))
        addSubview(startHandle)
        addSubview(endHandle)
    }

    /// The tool can change while the canvas is on screen.
    func update(kind newKind: PDFAnnotationKind) {
        if newKind == kind { return }
        let wasLineTool = usesLineSnapping
        kind = newKind
        selectionLayer.fillColor = newKind.color.withAlphaComponent(0.22).cgColor
        selectionLayer.strokeColor = newKind.color.cgColor
        targetLineLayer.fillColor = newKind.color.withAlphaComponent(0.14).cgColor
        startHandle.setColor(newKind.color)
        endHandle.setColor(newKind.color)
        if wasLineTool != usesLineSnapping {
            lineSelection = nil
            committedLine = nil
            rectSelection = nil
            committedRect = nil
            hideHandles()
            onSelection?(nil)
        }
        renderThrottled(force: true)
    }

    // MARK: - Layout and zoom

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
        updateHandlePositions()
    }

    // MARK: - Tool mode

    /// Line tools are used only when the page really has a text layer and the
    /// rendered image has the same orientation as the page box (a rotated page
    /// renders with swapped sides, and snapping would be off).
    private var usesLineSnapping: Bool {
        guard let textMap, !textMap.isEmpty else { return false }
        guard pageImage.size.width > 1, pageImage.size.height > 1 else { return false }
        let imageRatio = pageImage.size.width / pageImage.size.height
        let pageRatio = textMap.pageSize.width / textMap.pageSize.height
        guard abs(imageRatio - pageRatio) < 0.02 else { return false }
        return kind.followsTextLines
    }

    // MARK: - Coordinate conversion

    private func pagePoint(from contentPoint: CGPoint) -> CGPoint {
        guard let textMap, content.bounds.width > 0, content.bounds.height > 0 else { return contentPoint }
        return CGPoint(x: contentPoint.x * textMap.pageSize.width / content.bounds.width,
                       y: contentPoint.y * textMap.pageSize.height / content.bounds.height)
    }

    private func contentRect(from pageRect: CGRect) -> CGRect {
        guard let textMap else { return .zero }
        let scaleX = content.bounds.width / max(textMap.pageSize.width, 1)
        let scaleY = content.bounds.height / max(textMap.pageSize.height, 1)
        return CGRect(x: pageRect.minX * scaleX, y: pageRect.minY * scaleY,
                      width: pageRect.width * scaleX, height: pageRect.height * scaleY)
    }

    private func clampToContent(_ point: CGPoint) -> CGPoint {
        let size = content.bounds.size
        return CGPoint(x: min(max(point.x, 0), size.width),
                       y: min(max(point.y, 0), size.height))
    }

    private func clampedPagePoint(_ contentPoint: CGPoint) -> CGPoint {
        pagePoint(from: clampToContent(contentPoint))
    }

    private func toleranceForZoom() -> CGFloat {
        let fit = scrollView.minimumZoomScale > 0 ? scrollView.minimumZoomScale : 1
        let relativeZoom = max(scrollView.zoomScale / fit, 1)
        return PageTextMap.tolerance(base: 10, relativeZoom: relativeZoom, lineHeight: 12)
    }

    // MARK: - Drawing gesture

    @objc private func handleDraw(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: content)
        if usesLineSnapping {
            handleLineDraw(gesture, at: clampedPagePoint(location))
        } else {
            handleRectDraw(gesture, at: clampToContent(location))
        }
    }

    private func handleRectDraw(_ gesture: UIPanGestureRecognizer, at point: CGPoint) {
        switch gesture.state {
        case .began:
            rectAnchor = point
            rectSelection = makeRectSelection(from: point, to: point)
            renderThrottled(force: true)
        case .changed:
            guard let rectAnchor else { return }
            rectSelection = makeRectSelection(from: rectAnchor, to: point)
            renderThrottled()
        case .ended:
            guard let rectAnchor else { return }
            self.rectAnchor = nil
            let finished = makeRectSelection(from: rectAnchor, to: point)
            rectSelection = finished
            committedRect = finished
            renderThrottled(force: true)
            onSelection?(finished)
        case .cancelled, .failed:
            rectAnchor = nil
            rectSelection = committedRect
            renderThrottled(force: true)
        default:
            break
        }
    }

    private func handleLineDraw(_ gesture: UIPanGestureRecognizer, at point: CGPoint) {
        guard let textMap else { return }
        switch gesture.state {
        case .began:
            hideHandles()
            hideTargetLine()
            guard let line = textMap.lineIndex(atY: point.y, tolerance: toleranceForZoom()) else {
                // No row under the finger: show nothing rather than a box the
                // user did not ask for.
                anchorLine = nil
                dragStartX = nil
                lineSelection = nil
                committedLine = nil
                renderThrottled(force: true)
                onSelection?(nil)
                return
            }
            anchorLine = line
            dragStartX = point.x
            let index = textMap.charIndex(inLine: line, atX: point.x)
            lineSelection = PageLineSelection(line: line, start: index, end: index)
            renderThrottled(force: true)
        case .changed:
            guard let line = anchorLine, let startX = dragStartX else { return }
            lineSelection = textMap.selection(onLine: line, fromX: startX, toX: point.x)
            renderThrottled()
        case .ended:
            guard let line = anchorLine, let startX = dragStartX else { return }
            anchorLine = nil
            dragStartX = nil
            guard let finished = textMap.selection(onLine: line, fromX: startX, toX: point.x) else {
                lineSelection = committedLine
                renderThrottled(force: true)
                return
            }
            lineSelection = finished
            committedLine = finished
            renderThrottled(force: true)
            showHandles()
            onSelection?(normalisedSelection)
        case .cancelled, .failed:
            anchorLine = nil
            dragStartX = nil
            lineSelection = committedLine
            renderThrottled(force: true)
            showHandles()
        default:
            break
        }
    }

    /// A tap selects the word under the finger, snapped to its row.
    @objc private func handleWordTap(_ gesture: UITapGestureRecognizer) {
        guard usesLineSnapping, let textMap else { return }
        let point = clampedPagePoint(gesture.location(in: content))
        guard let word = textMap.wordSelection(at: point, tolerance: toleranceForZoom()) else {
            lineSelection = nil
            committedLine = nil
            renderThrottled(force: true)
            hideHandles()
            onSelection?(nil)
            return
        }
        lineSelection = word
        committedLine = word
        renderThrottled(force: true)
        showHandles()
        onSelection?(normalisedSelection)
    }

    // MARK: - Handles

    @objc private func handleStartPanned(_ gesture: UIPanGestureRecognizer) {
        handleHandleDrag(gesture, role: .start)
    }

    @objc private func handleEndPanned(_ gesture: UIPanGestureRecognizer) {
        handleHandleDrag(gesture, role: .end)
    }

    private func handleHandleDrag(_ gesture: UIPanGestureRecognizer, role: HandleRole) {
        guard usesLineSnapping, let textMap, let base = lineSelection else { return }
        let point = clampedPagePoint(gesture.location(in: content))
        switch gesture.state {
        case .began:
            break
        case .changed:
            // Snap to the nearest row, so moving one finger across rows is a
            // single, predictable step instead of a fight with a threshold.
            let line = textMap.nearestLineIndex(atY: point.y) ?? base.line
            var candidate = textMap.clamped(base, to: line)
            let index = textMap.charIndex(inLine: line, atX: point.x)
            if role == .start {
                candidate.start = index
            } else {
                candidate.end = index
            }
            if candidate.start > candidate.end {
                swap(&candidate.start, &candidate.end)
            }
            lineSelection = candidate
            showTargetLine(line)
            // The layer path is throttled; the handle itself follows every
            // event so the dot never feels laggy under the finger.
            renderThrottled()
            updateHandlePositions()
        case .ended, .cancelled, .failed:
            hideTargetLine()
            committedLine = lineSelection
            renderThrottled(force: true)
            showHandles()
            onSelection?(normalisedSelection)
        default:
            break
        }
    }

    /// Highlights the row the handle is currently snapping to.
    private func showTargetLine(_ index: Int) {
        guard let textMap, textMap.lines.indices.contains(index) else {
            hideTargetLine()
            return
        }
        let zoom = max(scrollView.zoomScale, 0.1)
        let rowRect = contentRect(from: textMap.lines[index].rect)
        let padded = rowRect.insetBy(dx: -4 / zoom, dy: -1.5 / zoom)
        targetLineLayer.path = UIBezierPath(roundedRect: padded,
                                            cornerRadius: 3 / zoom).cgPath
        targetLineLayer.isHidden = false
    }

    private func hideTargetLine() {
        targetLineLayer.isHidden = true
        targetLineLayer.path = nil
    }

    private func showHandles() {
        guard usesLineSnapping, contentSelectionRect() != nil else {
            hideHandles()
            return
        }
        startHandle.isHidden = false
        endHandle.isHidden = false
        updateHandlePositions()
    }

    private func hideHandles() {
        startHandle.isHidden = true
        endHandle.isHidden = true
    }

    func updateHandlePositions() {
        guard !startHandle.isHidden, let contentRect = contentSelectionRect() else { return }
        let canvasRect = content.convert(contentRect, to: self)
        startHandle.center = CGPoint(x: canvasRect.minX, y: canvasRect.midY)
        endHandle.center = CGPoint(x: canvasRect.maxX, y: canvasRect.midY)
    }

    // MARK: - Rendering

    private var normalisedSelection: CGRect? {
        if usesLineSnapping, let textMap, let lineSelection,
           let pageRect = textMap.rect(for: lineSelection) {
            return textMap.normalised(pageRect)
        }
        return rectSelection
    }

    private func contentSelectionRect() -> CGRect? {
        if usesLineSnapping, let textMap, let lineSelection,
           let pageRect = textMap.rect(for: lineSelection) {
            return contentRect(from: pageRect)
        }
        guard let rectSelection else { return nil }
        let size = content.bounds.size
        return CGRect(x: rectSelection.minX * size.width,
                      y: rectSelection.minY * size.height,
                      width: rectSelection.width * size.width,
                      height: rectSelection.height * size.height)
    }

    private func renderSelection() {
        guard let rect = contentSelectionRect() else {
            selectionLayer.path = nil
            return
        }
        selectionLayer.path = UIBezierPath(rect: rect).cgPath
        // Keep the outline one physical pixel-ish wide at every zoom level.
        selectionLayer.lineWidth = max(1.5 / max(scrollView.zoomScale, 0.05), 0.4)
    }

    /// Caps visual updates at 30 fps; the final state is always drawn on release.
    private func renderThrottled(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastRender >= 1.0 / 30.0 else { return }
        lastRender = now
        renderSelection()
        updateHandlePositions()
    }

    // MARK: - Geometry for rectangle tools

    private func makeRectSelection(from start: CGPoint, to end: CGPoint) -> CGRect {
        let size = content.bounds.size
        guard size.width > 1, size.height > 1 else { return .zero }
        if kind == .underline || kind == .strikeOut {
            let length = max(abs(end.x - start.x), size.width * 0.02)
            let band = max(size.height * 0.022, 4)
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
}

extension PDFAnnotationKind {
    /// Underline, strike-through and circle are meant to follow a text row, so
    /// they are placed through `PageTextMap` instead of a free rectangle.
    var followsTextLines: Bool {
        switch self {
        case .underline, .strikeOut, .circle: return true
        default: return false
        }
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

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let canvas else { return }
        MainActor.assumeIsolated { canvas.updateHandlePositions() }
    }
}
