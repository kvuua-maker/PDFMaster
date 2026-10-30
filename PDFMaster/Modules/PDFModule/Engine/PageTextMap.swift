import CoreGraphics
import Foundation
import PDFKit

/// A rectangle on one text line, in character indices of that line.
struct PageLineSelection: Equatable {
    var line: Int
    var start: Int
    var end: Int

    var lower: Int { min(start, end) }
    var upper: Int { max(start, end) }
}

/// Text geometry of a single PDF page, precomputed once.
///
/// A row is modelled the way a typesetter sees it: a baseline plus a line box
/// whose height comes from the PDF font (`font size × 1.2`), not from the glyph
/// boxes of whatever characters happen to be on the row. The line box is what
/// the selection uses vertically, so its height never depends on the zoom level
/// or on how tall the particular glyphs are.
///
/// Hit testing during a drag is pure arithmetic: `PDFPage.characterBounds(at:)`
/// is called here, never on the gesture path.
///
/// All rectangles are in page points with a top-left origin, i.e. the same
/// orientation as the rendered page image. Everything the engine consumes is
/// normalised at the very end by `normalised(_:)`.
struct PageTextMap {
    struct Line {
        /// Union of every glyph box on the line (used for the horizontal extent
        /// and for the target-row highlight).
        let rect: CGRect
        /// Baseline: the bottom of the glyphs that have no descender.
        let baselineY: CGFloat
        /// Font size estimated from the row's glyph boxes.
        let fontSize: CGFloat
        /// Line box height: `fontSize × 1.2`, capped by the row spacing.
        let lineHeight: CGFloat
        /// Glyph boxes, sorted left to right.
        let chars: [CGRect]

        /// Vertical band owned by the row: ascender above the baseline,
        /// descender below it.
        var band: CGRect {
            CGRect(x: rect.minX,
                   y: baselineY - lineHeight * 0.8,
                   width: max(rect.width, 1),
                   height: lineHeight)
        }
    }

    let pageSize: CGSize
    let lines: [Line]

    /// Counts PDFKit calls, so a test can prove that hit testing stays clear of
    /// PDFKit once the map exists.
    nonisolated(unsafe) static var pdfCallCount = 0

    var isEmpty: Bool { lines.isEmpty }

    // MARK: - Building

    static func make(from url: URL, pageIndex: Int = 0) -> PageTextMap? {
        pdfCallCount += 1
        guard let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex) else { return nil }
        let media = page.bounds(for: .mediaBox)
        guard media.width > 1, media.height > 1 else { return nil }

        let total = page.numberOfCharacters
        guard total > 0 else { return nil }
        // A page with tens of thousands of characters is not a document anyone
        // annotates by line; stop before the walk becomes expensive.
        let count = min(total, 6000)

        var boxes: [CGRect] = []
        boxes.reserveCapacity(count)
        for index in 0..<count {
            pdfCallCount += 1
            let raw = page.characterBounds(at: index)
            guard raw.width > 0.5, raw.height > 0.5 else { continue }
            boxes.append(CGRect(x: raw.minX - media.minX,
                                y: media.maxY - raw.maxY,
                                width: raw.width,
                                height: raw.height))
        }
        guard !boxes.isEmpty else { return nil }

        // Group glyphs by baseline, so rows can never merge because their glyph
        // boxes overlap vertically.
        boxes.sort { $0.maxY < $1.maxY }
        var clusters: [[CGRect]] = []
        var baseline: CGFloat = 0
        var clusterHeight: CGFloat = 0
        for box in boxes {
            let joins = !clusters.isEmpty
                && abs(box.maxY - baseline) <= max(clusterHeight * 0.45, 2)
            if joins {
                clusters[clusters.count - 1].append(box)
                baseline = min(baseline, box.maxY)
                clusterHeight = max(clusterHeight, box.height)
            } else {
                clusters.append([box])
                baseline = box.maxY
                clusterHeight = box.height
            }
        }

        var raw: [(rect: CGRect, baseline: CGFloat, chars: [CGRect])] = []
        raw.reserveCapacity(clusters.count)
        for cluster in clusters {
            let sorted = cluster.sorted { $0.minX < $1.minX }
            let rect = sorted.reduce(CGRect.null) { $0.union($1) }
            guard rect.width > 1, rect.height > 1 else { continue }
            let rowBaseline = sorted.map(\.maxY).min() ?? rect.maxY
            raw.append((rect, rowBaseline, sorted))
        }
        guard !raw.isEmpty else { return nil }
        raw.sort { $0.baseline < $1.baseline }

        var lines: [Line] = []
        lines.reserveCapacity(raw.count)
        for (index, row) in raw.enumerated() {
            // Actual spacing to the neighbour: the line box may not grow past
            // it, otherwise two rows could claim the same point.
            let next = index + 1 < raw.count ? raw[index + 1].baseline - row.baseline : nil
            let previous = index > 0 ? row.baseline - raw[index - 1].baseline : nil
            let spacing = next ?? previous ?? 0
            // Font size from the row's ascenders: the tallest glyph above the
            // baseline is a cap or an ascender, about 0.72 em.
            let ascent = max(row.baseline - row.rect.minY, 1)
            let fontSize = max(ascent / 0.72, 4)
            var lineHeight = fontSize * 1.2
            if spacing > 2 {
                lineHeight = min(lineHeight, spacing * 0.95)
            }
            lineHeight = max(lineHeight, 6)
            lines.append(Line(rect: row.rect,
                              baselineY: row.baseline,
                              fontSize: fontSize,
                              lineHeight: lineHeight,
                              chars: row.chars))
        }
        return PageTextMap(pageSize: CGSize(width: media.width, height: media.height),
                           lines: lines)
    }

    // MARK: - Coordinates

    /// Content-view point (page image space) → page point. Kept here so the
    /// conversion is testable; the canvas must apply it to the touch-down
    /// point, not to the point where the pan happens to be recognised.
    func pagePoint(fromContentPoint point: CGPoint, contentSize: CGSize) -> CGPoint {
        guard contentSize.width > 0, contentSize.height > 0 else { return point }
        return CGPoint(x: point.x * pageSize.width / contentSize.width,
                       y: point.y * pageSize.height / contentSize.height)
    }

    // MARK: - Hit testing

    /// The miss margin outside the line box. It is a fraction of the row height
    /// and nothing else — it does not grow with the zoom level, so a row is as
    /// easy to hit at 5× as at 1×.
    static func tolerance(lineHeight: CGFloat) -> CGFloat {
        max(lineHeight * 0.4, 1)
    }

    /// Row under a vertical position: the nearest baseline, provided the point
    /// is inside that row's line box or within 40% of the line height of it.
    /// Points further away belong to no row at all.
    func lineIndex(atY y: CGFloat) -> Int? {
        guard !lines.isEmpty else { return nil }
        var best: (index: Int, outside: CGFloat, baseline: CGFloat)?
        for (index, line) in lines.enumerated() {
            let band = line.band
            let outside: CGFloat
            if y < band.minY {
                outside = band.minY - y
            } else if y > band.maxY {
                outside = y - band.maxY
            } else {
                outside = 0
            }
            guard outside <= Self.tolerance(lineHeight: line.lineHeight) else { continue }
            // Among the rows that are reachable, the nearest baseline decides —
            // the same rule the handle snapping uses, so both agree.
            let baselineDistance = abs(y - line.baselineY)
            if best == nil
                || baselineDistance < best!.baseline
                || (baselineDistance == best!.baseline && outside < best!.outside) {
                best = (index, outside, baselineDistance)
            }
        }
        return best?.index
    }

    /// Closest baseline regardless of distance — used while dragging a handle,
    /// so the selection always snaps somewhere and never gets stuck between
    /// rows.
    func nearestLineIndex(atY y: CGFloat) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, line) in lines.enumerated() {
            let distance = abs(y - line.baselineY)
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// Character nearest to a horizontal position on a line.
    func charIndex(inLine line: Int, atX x: CGFloat) -> Int {
        guard lines.indices.contains(line) else { return 0 }
        let chars = lines[line].chars
        guard !chars.isEmpty else { return 0 }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, rect) in chars.enumerated() {
            let distance: CGFloat
            if x < rect.minX {
                distance = rect.minX - x
            } else if x > rect.maxX {
                distance = x - rect.maxX
            } else {
                return index
            }
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Word under a tap: the tapped glyph expanded while neighbouring glyphs
    /// stay within a word gap. Geometric, so it works even when PDFKit returns
    /// no glyph box for spaces.
    func wordSelection(at point: CGPoint) -> PageLineSelection? {
        guard let lineIndex = lineIndex(atY: point.y) else { return nil }
        let line = lines[lineIndex]
        guard !line.chars.isEmpty else { return nil }
        let index = charIndex(inLine: lineIndex, atX: point.x)
        let gap = max(line.chars[index].height * 0.35, 1)
        var lower = index
        while lower > 0, line.chars[lower].minX - line.chars[lower - 1].maxX <= gap {
            lower -= 1
        }
        var upper = index
        while upper < line.chars.count - 1, line.chars[upper + 1].minX - line.chars[upper].maxX <= gap {
            upper += 1
        }
        return PageLineSelection(line: lineIndex, start: lower, end: upper)
    }

    /// Selection from a drag: the anchor line stays fixed, the horizontal
    /// extent follows the finger.
    func selection(onLine line: Int, fromX: CGFloat, toX: CGFloat) -> PageLineSelection? {
        guard lines.indices.contains(line) else { return nil }
        let chars = lines[line].chars
        guard let first = chars.first, let last = chars.last else { return nil }
        // A touch at or beyond the row's edges selects the row's edge
        // character. Without this the left edge of the first glyph was
        // reachable only by luck, which read as "the selection starts to the
        // right of where I put my finger".
        let start = fromX <= first.minX ? 0 : charIndex(inLine: line, atX: fromX)
        let end = toX >= last.maxX ? chars.count - 1 : charIndex(inLine: line, atX: toX)
        return PageLineSelection(line: line, start: start, end: end)
    }

    /// Moves a selection by whole rows (the ↑/↓ buttons). Returns nil at the
    /// first or last row, which is also what disables those buttons.
    func moved(_ selection: PageLineSelection, by delta: Int) -> PageLineSelection? {
        let target = selection.line + delta
        guard lines.indices.contains(target) else { return nil }
        return clamped(selection, to: target)
    }

    /// Clamps a selection to a (possibly different) line, so a selection moved
    /// onto the next row keeps a sensible character range.
    func clamped(_ selection: PageLineSelection, to line: Int) -> PageLineSelection {
        guard lines.indices.contains(line) else { return selection }
        let last = max(lines[line].chars.count - 1, 0)
        return PageLineSelection(line: line,
                                 start: min(max(selection.start, 0), last),
                                 end: min(max(selection.end, 0), last))
    }

    /// The selection rectangle: X from the selected glyphs (character accurate),
    /// Y from the row's font line box (so the height is one row, at any zoom).
    func rect(for selection: PageLineSelection) -> CGRect? {
        guard lines.indices.contains(selection.line) else { return nil }
        let line = lines[selection.line]
        let chars = line.chars
        guard !chars.isEmpty else { return nil }
        let lower = min(max(selection.lower, 0), chars.count - 1)
        let upper = min(max(selection.upper, lower), chars.count - 1)
        let minX = chars[lower].minX
        let maxX = chars[upper].maxX
        let top = line.baselineY - line.lineHeight * 0.8
        return CGRect(x: minX, y: top, width: max(maxX - minX, 1), height: line.lineHeight)
    }

    /// How the app paints a row annotation. The position of the drawn line is
    /// decided here, per tool, instead of relying on how PDFKit happens to
    /// place an underline or a strike-through inside a tall rectangle.
    enum LineStyle {
        case underline
        case strikeThrough
        case circle
    }

    /// Rectangle handed to the PDF engine for a row selection.
    ///
    /// * underline — a thin band starting just below the baseline, so the line
    ///   PDFKit draws under it sits under the text;
    /// * strike-through — a thin band centred on `baseline − 0.3 × lineHeight`,
    ///   so the line crosses the glyphs;
    /// * circle — the row box grown by a small padding, so the ring surrounds
    ///   the whole row without touching the neighbours.
    func annotationRect(for selection: PageLineSelection, style: LineStyle) -> CGRect? {
        guard lines.indices.contains(selection.line),
              let box = rect(for: selection) else { return nil }
        let line = lines[selection.line]
        let baseline = line.baselineY
        let height = line.lineHeight
        let thickness = max(height * 0.08, 1.5)
        let width = max(box.width, 1)
        switch style {
        case .underline:
            // The band starts 1.5 pt under the baseline; PDFKit paints the
            // underline along the bottom of the band.
            let top = baseline + max(1.5, height * 0.09)
            return CGRect(x: box.minX, y: top, width: width, height: thickness)
        case .strikeThrough:
            let centre = baseline - height * 0.3
            return CGRect(x: box.minX, y: centre - thickness / 2,
                          width: width, height: thickness)
        case .circle:
            let padding: CGFloat = max(height * 0.15, 2.5)
            let top = baseline - height * 0.8 - padding
            return CGRect(x: box.minX - padding, y: top,
                          width: width + padding * 2,
                          height: height + padding * 2)
        }
    }

    /// Page points → 0…1 with a top-left origin (what the PDF engine takes).
    func normalised(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX / pageSize.width,
               y: rect.minY / pageSize.height,
               width: rect.width / pageSize.width,
               height: rect.height / pageSize.height)
    }
}
