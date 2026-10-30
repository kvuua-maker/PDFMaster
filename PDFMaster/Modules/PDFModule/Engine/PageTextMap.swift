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

/// A selection that may cover several rows, like a paragraph in a text editor.
///
/// `anchor` is where the finger landed, `focus` is where it is now; every row
/// between them is covered, the first and last only partly.
struct PageTextSelection: Equatable {
    var anchorLine: Int
    var anchorChar: Int
    var focusLine: Int
    var focusChar: Int

    var firstLine: Int { min(anchorLine, focusLine) }
    var lastLine: Int { max(anchorLine, focusLine) }
    var isMultiLine: Bool { firstLine != lastLine }

    static func single(line: Int, char: Int) -> PageTextSelection {
        PageTextSelection(anchorLine: line, anchorChar: char,
                          focusLine: line, focusChar: char)
    }
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

        // PDFKit already knows how the text is laid out: its line selections
        // follow the actual text runs, so quotes, superscripts and mixed fonts
        // stay on the row they belong to. Glyph clustering is only the fallback
        // for pages where PDFKit returns no lines.
        var rows = rowsFromLines(page: page, media: media, boxes: boxes)
            ?? rowsFromClustering(boxes)
        guard !rows.isEmpty else { return nil }
        rows.sort { $0.rect.minY < $1.rect.minY }

        var lines: [Line] = []
        lines.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            // Actual spacing to the neighbour: the line box may not grow past
            // it, otherwise two rows could claim the same point.
            let next = index + 1 < rows.count ? rows[index + 1].baseline - row.baseline : nil
            let previous = index > 0 ? row.baseline - rows[index - 1].baseline : nil
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

    private struct RawRow {
        var rect: CGRect
        var baseline: CGFloat
        var chars: [CGRect]
    }

    /// Rows taken from PDFKit's own line selections.
    private static func rowsFromLines(page: PDFPage,
                                      media: CGRect,
                                      boxes: [CGRect]) -> [RawRow]? {
        guard let pageSelection = page.selection(for: media) else { return nil }
        var lineRects: [CGRect] = []
        for selection in pageSelection.selectionsByLine() {
            let bounds = selection.bounds(for: page)
            guard bounds.width > 1, bounds.height > 0.5 else { continue }
            lineRects.append(CGRect(x: bounds.minX - media.minX,
                                    y: media.maxY - bounds.maxY,
                                    width: bounds.width,
                                    height: bounds.height))
        }
        guard !lineRects.isEmpty else { return nil }

        // One visual row can arrive as several fragments (bold + regular runs);
        // merge fragments that overlap vertically.
        lineRects.sort { $0.minY < $1.minY }
        var merged: [CGRect] = []
        for rect in lineRects {
            if let last = merged.last {
                let overlap = min(last.maxY, rect.maxY) - max(last.minY, rect.minY)
                if overlap > 0.6 * min(last.height, rect.height) {
                    merged[merged.count - 1] = last.union(rect)
                    continue
                }
            }
            merged.append(rect)
        }

        var rows = merged.map { RawRow(rect: $0, baseline: $0.maxY, chars: []) }
        for box in boxes {
            var bestIndex = -1
            var bestOverlap: CGFloat = 0
            for (index, row) in rows.enumerated() {
                let overlap = min(box.maxY, row.rect.maxY) - max(box.minY, row.rect.minY)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { continue }
            rows[bestIndex].chars.append(box)
        }
        rows = rows.filter { $0.chars.count > 0 }
        guard !rows.isEmpty else { return nil }
        for index in rows.indices {
            rows[index].chars.sort { $0.minX < $1.minX }
            rows[index].rect = rows[index].chars.reduce(CGRect.null) { $0.union($1) }
            rows[index].baseline = baseline(of: rows[index].chars, fallback: rows[index].rect.maxY)
        }
        return rows
    }

    /// Fallback: chain glyphs by their bottoms. Quotes and superscripts sit a
    /// few points above the baseline, so the window follows the taller glyph.
    private static func rowsFromClustering(_ boxes: [CGRect]) -> [RawRow] {
        let sorted = boxes.sorted { $0.maxY < $1.maxY }
        var clusters: [[CGRect]] = []
        var previousBottom: CGFloat = 0
        var previousHeight: CGFloat = 0
        for box in sorted {
            let window = max(max(previousHeight, box.height) * 0.6, 2.5)
            if !clusters.isEmpty, abs(box.maxY - previousBottom) <= window {
                clusters[clusters.count - 1].append(box)
            } else {
                clusters.append([box])
            }
            previousBottom = box.maxY
            previousHeight = box.height
        }
        return clusters.compactMap { cluster in
            let sorted = cluster.sorted { $0.minX < $1.minX }
            let rect = sorted.reduce(CGRect.null) { $0.union($1) }
            guard rect.width > 1, rect.height > 1 else { return nil }
            return RawRow(rect: rect,
                          baseline: baseline(of: sorted, fallback: rect.maxY),
                          chars: sorted)
        }
    }

    /// Baseline = the most common glyph bottom. Raised glyphs (quotes,
    /// apostrophes, asterisks, superscripts) have their bottom above the
    /// baseline; taking the minimum dragged a whole row up by 3–6 pt, which is
    /// why an underline landed on the text and a strike-through above it.
    private static func baseline(of chars: [CGRect], fallback: CGFloat) -> CGFloat {
        let bottoms = chars.map(\.maxY).sorted()
        guard let median = bottoms.isEmpty ? nil : bottoms[bottoms.count / 2] else { return fallback }
        let inliers = bottoms.filter { abs($0 - median) <= 1.5 }
        guard !inliers.isEmpty else { return median }
        return inliers.reduce(0, +) / CGFloat(inliers.count)
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

    /// Moves a single-row selection by whole rows.
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
        case highlight
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
        let fontSize = line.fontSize
        let lineHeight = line.lineHeight
        let width = max(box.width, 1)
        // A 1–2 pt band centred on the target Y: PDFKit paints an underline at
        // the bottom of its bounds and a strike-through through the middle, and
        // with a band this thin either choice lands within ~1 pt of the target.
        let thickness = max(fontSize * 0.1, 1.5)
        switch style {
        case .underline:
            let y = baseline + fontSize * 0.15
            return CGRect(x: box.minX, y: y - thickness / 2,
                          width: width, height: thickness)
        case .strikeThrough:
            let y = baseline - lineHeight * 0.3
            return CGRect(x: box.minX, y: y - thickness / 2,
                          width: width, height: thickness)
        case .circle:
            let top = baseline - lineHeight * 0.8
            return CGRect(x: box.minX, y: top, width: width, height: lineHeight)
        case .highlight:
            return box
        }
    }

    // MARK: - Multi-row selections

    /// Endpoints in document order (top-left first).
    func orderedEnds(of selection: PageTextSelection) -> (startLine: Int, startChar: Int,
                                                        endLine: Int, endChar: Int) {
        var start = (selection.anchorLine, selection.anchorChar)
        var end = (selection.focusLine, selection.focusChar)
        if start.0 > end.0 || (start.0 == end.0 && start.1 > end.1) {
            swap(&start, &end)
        }
        return (start.0, start.1, end.0, end.1)
    }

    /// One range per covered row: the first row starts at the start character,
    /// the last ends at the end character, and rows in between are full width.
    func rows(in selection: PageTextSelection) -> [PageLineSelection] {
        guard !lines.isEmpty else { return [] }
        let ends = orderedEnds(of: selection)
        let first = min(max(ends.startLine, 0), lines.count - 1)
        let last = min(max(ends.endLine, 0), lines.count - 1)
        var result: [PageLineSelection] = []
        for row in first...last {
            let chars = lines[row].chars
            guard !chars.isEmpty else { continue }
            var start = row == first ? ends.startChar : 0
            var end = row == last ? ends.endChar : chars.count - 1
            start = min(max(start, 0), chars.count - 1)
            end = min(max(end, 0), chars.count - 1)
            if start > end { swap(&start, &end) }
            result.append(PageLineSelection(line: row, start: start, end: end))
        }
        return result
    }

    /// One box per covered row (full line height), used by the marker tool and
    /// by the on-screen preview.
    func rowRects(for selection: PageTextSelection) -> [CGRect] {
        rows(in: selection).compactMap { rect(for: $0) }
    }

    /// Bounding box of every covered row — the circle is drawn around it.
    func boundingRect(for selection: PageTextSelection) -> CGRect? {
        let rects = rowRects(for: selection)
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// What is written into the PDF: one thin line per row for underline and
    /// strike-through, one rectangle per row for the marker, one oval around
    /// the whole block for a circle.
    func annotationRects(for selection: PageTextSelection, style: LineStyle) -> [CGRect] {
        switch style {
        case .underline, .strikeThrough:
            return rows(in: selection).compactMap { annotationRect(for: $0, style: style) }
        case .highlight:
            return rowRects(for: selection)
        case .circle:
            guard let box = boundingRect(for: selection) else { return [] }
            let padding: CGFloat = 2.5
            return [box.insetBy(dx: -padding, dy: -padding)]
        }
    }

    /// Moves a whole (possibly multi-row) selection by rows.
    func moved(_ selection: PageTextSelection, by delta: Int) -> PageTextSelection? {
        let ends = orderedEnds(of: selection)
        let newStart = ends.startLine + delta
        let newEnd = ends.endLine + delta
        guard lines.indices.contains(newStart), lines.indices.contains(newEnd) else { return nil }
        let startChar = min(ends.startChar, max(lines[newStart].chars.count - 1, 0))
        let endChar = min(ends.endChar, max(lines[newEnd].chars.count - 1, 0))
        return PageTextSelection(anchorLine: newStart, anchorChar: startChar,
                                 focusLine: newEnd, focusChar: endChar)
    }

    /// Clamps both endpoints into the page's rows.
    func clamped(_ selection: PageTextSelection) -> PageTextSelection {
        guard !lines.isEmpty else { return selection }
        let anchorLine = min(max(selection.anchorLine, 0), lines.count - 1)
        let focusLine = min(max(selection.focusLine, 0), lines.count - 1)
        let anchorChar = min(max(selection.anchorChar, 0),
                             max(lines[anchorLine].chars.count - 1, 0))
        let focusChar = min(max(selection.focusChar, 0),
                            max(lines[focusLine].chars.count - 1, 0))
        return PageTextSelection(anchorLine: anchorLine, anchorChar: anchorChar,
                                 focusLine: focusLine, focusChar: focusChar)
    }

    /// Box of a single character, used by the selection handles.
    func charRect(inLine line: Int, index: Int) -> CGRect? {
        guard lines.indices.contains(line) else { return nil }
        let chars = lines[line].chars
        guard !chars.isEmpty else { return nil }
        let clamped = min(max(index, 0), chars.count - 1)
        return rect(for: PageLineSelection(line: line, start: clamped, end: clamped))
    }

    /// Page points → 0…1 with a top-left origin (what the PDF engine takes).
    func normalised(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX / pageSize.width,
               y: rect.minY / pageSize.height,
               width: rect.width / pageSize.width,
               height: rect.height / pageSize.height)
    }
}
