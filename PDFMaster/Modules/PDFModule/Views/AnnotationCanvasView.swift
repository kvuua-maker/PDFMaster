import QuartzCore
import UIKit

/// Zoomable, pannable page canvas for annotating the first page.
///
/// The page image lives inside a scroll view, which gives three things:
/// * pinch-to-zoom and a two-finger drag pan the page while a tool is active;
/// * every touch is converted through the content view, whose bounds are the
///   page itself, so a rectangle is exact at any zoom level or scroll offset;
/// * one finger draws — for underline and strike-through the drag distance
///   sets the line length.
///
/// Line tools snap to one text row: the row is chosen by its baseline, its line
/// height comes from the spacing between neighbouring baselines, and the
/// selection is the union of that row's glyph boxes. Two rows can therefore
/// never end up in one selection.
///
/// A session is drawn in the canvas and applied only when the user taps Done:
/// the active selection can be adjusted with handles or with the ↑/↓/Apply/Clear
/// panel, and committed annotations are redrawn instantly for undo/redo. No
/// PDFKit call happens on the gesture path — `PageTextMap` was built once when
/// the tool was picked.
@MainActor
final class AnnotationCanvasView: UIView {
    let scrollView = UIScrollView()
    let content = UIView()

    private let imageView = UIImageView()
    private let committedLayer = CAShapeLayer()
    private let targetLineLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let zoomDelegate = CanvasZoomDelegate()
    private let drawGesture = UIPanGestureRecognizer()
    private let wordTap = UITapGestureRecognizer()
    private let startHandle = SelectionHandleView(isStart: true)
    private let endHandle = SelectionHandleView(isStart: false)
    private let actionBar = SelectionActionBar()

    /// Session annotations, mirrored from SwiftUI so undo/redo redraws instantly.
    private var annotations: [PlacedAnnotation] = []

    private let pageImage: UIImage
    private let textMap: PageTextMap?
    private var kind: PDFAnnotationKind

    /// Free rectangle tools (and pages without a text layer).
    private var rectSelection: CGRect?
    private var rectAnchor: CGPoint?

    /// Line tools. The selection survives taps and drags until Apply/Clear.
    private var lineSelection: PageLineSelection?
    /// Page-space point where the current drag started (touch-down, not the
    /// point where the pan happened to be recognised).
    private var dragAnchor: CGPoint?
    private var anchorRow: Int?
    private var dragHandle: RowSelectionEditing.Handle?

    private var fitted = false
    private var lastRender: CFTimeInterval = 0
    private var lastDrawnRect: CGRect = .null
    private var highlightedLine: Int?

    /// Called when the user confirms the active selection.
    var onCommit: ((PlacedAnnotation) -> Void)?

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

        committedLayer.frame = content.bounds
        committedLayer.fillColor = kind.color.withAlphaComponent(0.18).cgColor
        committedLayer.strokeColor = kind.color.withAlphaComponent(0.6).cgColor
        committedLayer.lineWidth = 1.5
        content.layer.addSublayer(committedLayer)

        targetLineLayer.frame = content.bounds
        targetLineLayer.fillColor = kind.color.withAlphaComponent(0.14).cgColor
        targetLineLayer.strokeColor = UIColor.clear.cgColor
        targetLineLayer.isHidden = true
        content.layer.addSublayer(targetLineLayer)

        selectionLayer.frame = content.bounds
        selectionLayer.fillColor = kind.color.withAlphaComponent(0.22).cgColor
        selectionLayer.strokeColor = kind.color.cgColor
        selectionLayer.lineWidth = 2
        content.layer.addSublayer(selectionLayer)

        drawGesture.addTarget(self, action: #selector(handleDraw(_:)))
        drawGesture.maximumNumberOfTouches = 1
        content.addGestureRecognizer(drawGesture)

        wordTap.addTarget(self, action: #selector(handleWordTap(_:)))
        wordTap.require(toFail: drawGesture)
        content.addGestureRecognizer(wordTap)

        // Handles and the panel sit above the scroll view, so a touch that
        // starts on them never reaches the draw gesture or the scroll pan.
        startHandle.setColor(kind.color)
        endHandle.setColor(kind.color)
        startHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleStartPanned(_:))))
        endHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleEndPanned(_:))))
        addSubview(startHandle)
        addSubview(endHandle)

        actionBar.onMoveUp = { [weak self] in self?.moveSelection(by: -1) }
        actionBar.onMoveDown = { [weak self] in self?.moveSelection(by: 1) }
        actionBar.onApply = { [weak self] in self?.commitActiveSelection() }
        actionBar.onClear = { [weak self] in self?.clearActiveSelection() }
        addSubview(actionBar)
    }

    // MARK: - Session

    /// Mirrors the SwiftUI session stack so undo/redo is visible immediately.
    func setAnnotations(_ items: [PlacedAnnotation]) {
        guard items != annotations else { return }
        annotations = items
        drawCommitted()
    }

    /// The tool can change while the canvas is on screen.
    func update(kind newKind: PDFAnnotationKind) {
        if newKind == kind { return }
        let wasLineTool = usesLineSnapping
        kind = newKind
        committedLayer.fillColor = newKind.color.withAlphaComponent(0.18).cgColor
        committedLayer.strokeColor = newKind.color.withAlphaComponent(0.6).cgColor
        selectionLayer.fillColor = newKind.color.withAlphaComponent(0.22).cgColor
        selectionLayer.strokeColor = newKind.color.cgColor
        targetLineLayer.fillColor = newKind.color.withAlphaComponent(0.14).cgColor
        startHandle.setColor(newKind.color)
        endHandle.setColor(newKind.color)
        if wasLineTool != usesLineSnapping {
            clearActiveSelection()
        }
        drawCommitted()
        renderThrottled(force: true)
    }

    private func drawCommitted() {
        guard !annotations.isEmpty else {
            committedLayer.path = nil
            return
        }
        let path = UIBezierPath()
        for item in annotations {
            path.append(UIBezierPath(rect: contentRect(fromNormalised: item.rect)))
        }
        committedLayer.path = path.cgPath
        committedLayer.lineWidth = max(1.5 / max(scrollView.zoomScale, 0.05), 0.4)
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
        updateActionBarPosition()
        drawCommitted()
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

    private func contentRect(fromNormalised rect: CGRect) -> CGRect {
        let size = content.bounds.size
        return CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                      width: rect.width * size.width, height: rect.height * size.height)
    }

    private func clampToContent(_ point: CGPoint) -> CGPoint {
        let size = content.bounds.size
        return CGPoint(x: min(max(point.x, 0), size.width),
                       y: min(max(point.y, 0), size.height))
    }

    private func clampedPagePoint(_ contentPoint: CGPoint) -> CGPoint {
        pagePoint(from: clampToContent(contentPoint))
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
            hideActionBar()
            hideHandles()
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
            rectSelection = makeRectSelection(from: rectAnchor, to: point)
            renderThrottled(force: true)
            showActionBar()
        case .cancelled, .failed:
            rectAnchor = nil
            rectSelection = nil
            renderThrottled(force: true)
            hideActionBar()
        default:
            break
        }
    }

    private func handleLineDraw(_ gesture: UIPanGestureRecognizer, at point: CGPoint) {
        guard let textMap else { return }
        switch gesture.state {
        case .began:
            hideActionBar()
            hideTargetLine()
            let touch = touchDownPoint(gesture)
            logTouch(gesture, touchDown: touch)
            beginLineDrag(at: touch, in: textMap)
        case .changed:
            updateLineDrag(to: point, in: textMap)
        case .ended:
            dragAnchor = nil
            dragHandle = nil
            anchorRow = nil
            renderThrottled(force: true)
            showHandles()
            showActionBar()
        case .cancelled, .failed:
            // Keep the selection: an interrupted drag must not throw away work.
            dragAnchor = nil
            dragHandle = nil
            anchorRow = nil
            renderThrottled(force: true)
            showHandles()
            showActionBar()
        default:
            break
        }
    }

    /// The point where the finger first touched the glass.
    ///
    /// A `UIPanGestureRecognizer` only begins after the finger has travelled
    /// its recognition distance, so `location(in:)` at `.began` is already
    /// ~10 pt away from the touch-down point. Subtracting the translation
    /// recovers the real start — this was the offset at the start of a
    /// selection.
    private func touchDownPoint(_ gesture: UIPanGestureRecognizer) -> CGPoint {
        let location = gesture.location(in: content)
        let translation = gesture.translation(in: content)
        return CGPoint(x: location.x - translation.x, y: location.y - translation.y)
    }

    private func logTouch(_ gesture: UIPanGestureRecognizer, touchDown: CGPoint) {
        let translation = gesture.translation(in: content)
        let page = pagePoint(from: clampToContent(touchDown))
        RuntimeDiagnostics.shared.log(
            "annotation",
            String(format: "touch-down content=(%.1f,%.1f) translation=(%.1f,%.1f) page=(%.1f,%.1f) zoom=%.3f",
                   touchDown.x, touchDown.y, translation.x, translation.y,
                   page.x, page.y, scrollView.zoomScale)
        )
    }

    private func beginLineDrag(at touch: CGPoint, in textMap: PageTextMap) {
        dragAnchor = touch
        anchorRow = lineSelection?.line
        // An existing selection is adjusted, never thrown away.
        if let existing = lineSelection {
            dragHandle = RowSelectionEditing.nearestHandle(in: textMap,
                                                           selection: existing,
                                                           atX: touch.x)
            renderThrottled(force: true)
            return
        }
        dragHandle = nil
        guard let line = textMap.lineIndex(atY: touch.y) else {
            anchorRow = nil
            renderThrottled(force: true)
            return
        }
        anchorRow = line
        let index = textMap.charIndex(inLine: line, atX: touch.x)
        lineSelection = PageLineSelection(line: line, start: index, end: index)
        renderThrottled(force: true)
    }

    private func updateLineDrag(to point: CGPoint, in textMap: PageTextMap) {
        guard let anchor = dragAnchor, let current = lineSelection else { return }
        var selection = current

        // Slide to the neighbouring row only when the finger really left the
        // row it started on; the selection itself stays a single row.
        if let row = textMap.nearestLineIndex(atY: point.y), let row0 = anchorRow, row != row0 {
            let origin = textMap.lines[row0]
            if abs(point.y - origin.baselineY) > origin.lineHeight * 0.5 {
                anchorRow = row
                selection = textMap.clamped(selection, to: row)
            }
        }

        if let handle = dragHandle {
            lineSelection = RowSelectionEditing.moving(handle,
                                                       toX: point.x,
                                                       onRow: selection.line,
                                                       in: textMap,
                                                       selection: selection)
        } else {
            // Creating: the start is the touch-down character, the end follows
            // the finger. Both are character-granular.
            lineSelection = textMap.selection(onLine: selection.line,
                                              fromX: anchor.x,
                                              toX: point.x)
        }
        renderThrottled()
    }

    /// A tap adjusts an existing selection; with no selection it selects the
    /// word under the finger.
    @objc private func handleWordTap(_ gesture: UITapGestureRecognizer) {
        guard usesLineSnapping, let textMap else { return }
        let point = clampedPagePoint(gesture.location(in: content))
        if let selection = lineSelection {
            lineSelection = RowSelectionEditing.tap(at: point, in: textMap, selection: selection)
            renderThrottled(force: true)
            showHandles()
            showActionBar()
            return
        }
        guard let word = textMap.wordSelection(at: point) else { return }
        lineSelection = word
        renderThrottled(force: true)
        showHandles()
        showActionBar()
    }

    // MARK: - Handles

    @objc private func handleStartPanned(_ gesture: UIPanGestureRecognizer) {
        handleHandleDrag(gesture, role: .start)
    }

    @objc private func handleEndPanned(_ gesture: UIPanGestureRecognizer) {
        handleHandleDrag(gesture, role: .end)
    }

    private enum HandleRole { case start, end }

    private func handleHandleDrag(_ gesture: UIPanGestureRecognizer, role: HandleRole) {
        guard usesLineSnapping, let textMap, let base = lineSelection else { return }
        let point = clampedPagePoint(gesture.location(in: content))
        switch gesture.state {
        case .began:
            hideActionBar()
        case .changed:
            // Snap to the nearest baseline, so moving one finger across rows is
            // a single, predictable step instead of a fight with a threshold.
            let line = textMap.nearestLineIndex(atY: point.y) ?? base.line
            let handle: RowSelectionEditing.Handle = role == .start ? .start : .end
            lineSelection = RowSelectionEditing.moving(handle,
                                                       toX: point.x,
                                                       onRow: line,
                                                       in: textMap,
                                                       selection: base)
            showTargetLine(line)
            // Only the selection path and the two 44 pt handles are touched;
            // the path itself is capped at 30 fps, the handles follow every
            // event so the dot never feels laggy.
            renderThrottled()
            updateHandlePositions()
        case .ended, .cancelled, .failed:
            hideTargetLine()
            renderThrottled(force: true)
            showHandles()
            showActionBar()
        default:
            break
        }
    }

    private func lineBoxRect(_ index: Int, in textMap: PageTextMap) -> CGRect {
        let count = textMap.lines[index].chars.count
        let selection = PageLineSelection(line: index, start: 0, end: max(count - 1, 0))
        return textMap.rect(for: selection) ?? textMap.lines[index].rect
    }

    /// Highlights the row the handle is currently snapping to.
    private func showTargetLine(_ index: Int) {
        guard let textMap, textMap.lines.indices.contains(index) else {
            hideTargetLine()
            return
        }
        guard highlightedLine != index else { return }
        highlightedLine = index
        let zoom = max(scrollView.zoomScale, 0.1)
        let rowRect = contentRect(from: lineBoxRect(index, in: textMap))
        let padded = rowRect.insetBy(dx: -4 / zoom, dy: -1.5 / zoom)
        targetLineLayer.path = UIBezierPath(roundedRect: padded,
                                            cornerRadius: 3 / zoom).cgPath
        targetLineLayer.isHidden = false
    }

    private func hideTargetLine() {
        highlightedLine = nil
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
        let overlapping = canvasRect.width < SelectionHandleView.touchSize
        startHandle.clipsInnerHalf = overlapping
        endHandle.clipsInnerHalf = overlapping
    }

    // MARK: - Action bar

    private func showActionBar() {
        guard contentSelectionRect() != nil else {
            hideActionBar()
            return
        }
        actionBar.isHidden = false
        updateActionBarState()
        updateActionBarPosition()
    }

    private func hideActionBar() {
        actionBar.isHidden = true
    }

    private func updateActionBarState() {
        guard usesLineSnapping, let textMap, let lineSelection else {
            actionBar.update(canMoveUp: false, canMoveDown: false)
            return
        }
        actionBar.update(canMoveUp: textMap.moved(lineSelection, by: -1) != nil,
                         canMoveDown: textMap.moved(lineSelection, by: 1) != nil)
    }

    fileprivate func updateActionBarPosition() {
        guard !actionBar.isHidden, let rect = contentSelectionRect() else { return }
        let canvasRect = content.convert(rect, to: self)
        let size = actionBar.frame.size
        var x = canvasRect.midX - size.width / 2
        x = min(max(x, 8), max(bounds.width - size.width - 8, 8))
        var y = canvasRect.minY - size.height - 8
        if y < safeAreaInsets.top + 8 {
            y = canvasRect.maxY + 8
        }
        actionBar.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Moves the active selection to the neighbouring row — instant, because it
    /// only re-indexes the cached map.
    private func moveSelection(by delta: Int) {
        guard let textMap, let selection = lineSelection,
              let moved = textMap.moved(selection, by: delta) else { return }
        lineSelection = moved
        renderThrottled(force: true)
        updateActionBarState()
        showHandles()
        updateActionBarPosition()
    }

    private func commitActiveSelection() {
        guard let rect = normalisedSelection else { return }
        let item = PlacedAnnotation(kind: kind, rect: rect)
        annotations.append(item)
        drawCommitted()
        onCommit?(item)
        clearActiveSelection()
    }

    private func clearActiveSelection() {
        lineSelection = nil
        rectSelection = nil
        dragAnchor = nil
        dragHandle = nil
        anchorRow = nil
        hideHandles()
        hideActionBar()
        hideTargetLine()
        renderThrottled(force: true)
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
        return contentRect(fromNormalised: rectSelection)
    }

    private func renderSelection() {
        guard let rect = contentSelectionRect() else {
            if lastDrawnRect != .null {
                selectionLayer.path = nil
                lastDrawnRect = .null
            }
            return
        }
        guard rect != lastDrawnRect else { return }
        lastDrawnRect = rect
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
        updateActionBarPosition()
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
        MainActor.assumeIsolated {
            canvas.updateHandlePositions()
            canvas.updateActionBarPosition()
        }
    }
}
