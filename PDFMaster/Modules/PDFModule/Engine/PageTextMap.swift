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
/// Rows are modelled the way a typesetter sees them, not the way their glyph
/// boxes happen to overlap: every row has a baseline and a line height taken
/// from the spacing between neighbouring baselines (falling back to the row's
/// own glyph height). Two rows therefore never merge, which is what stopped a
/// selection from swallowing two lines when the page was zoomed in.
///
/// Hit testing during a drag is pure arithmetic: `PDFPage.characterBounds(at:)`
/// is called here, never on the gesture path, so dragging cannot block the main
/// thread inside PDFKit.
///
/// All rectangles are in page points with a top-left origin, i.e. the same
/// orientation as the rendered page image. Everything the engine consumes is
/// normalised at the very end by `normalised(_:)`.
struct PageTextMap {
    struct Line {
        /// Union of every glyph box on the line.
        let rect: CGRect
        /// Baseline: the bottom of the glyphs that have no descender.
        let baselineY: CGFloat
        /// Distance to the neighbouring baseline, clamped to a sane range.
        let lineHeight: CGFloat
        /// Glyph boxes, sorted left to right.
        let chars: [CGRect]

        /// Vertical band the row owns: half a line height either side of the
        /// baseline, i.e. up to the midpoints between neighbouring baselines.
        /// Bands of adjacent rows therefore meet exactly where the "nearest
        /// baseline" decision flips, so inside a text block a point belongs to
        /// exactly one row and never falls into a dead gap.
        var band: CGRect {
            CGRect(x: rect.minX,
                   y: baselineY - lineHeight * 0.5,
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

        // Group glyphs by baseline. Descenders sit a little below the baseline,
        // so a glyph joins the row while it is within a fraction of the row's
        // height; the next row starts a full line height lower, which is well
        // outside that window.
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
            // Prefer the spacing to the next row, so consecutive bands tile;
            // the last row borrows the spacing above it.
            let next = index + 1 < raw.count ? raw[index + 1].baseline - row.baseline : nil
            let previous = index > 0 ? row.baseline - raw[index - 1].baseline : nil
            let measured = next ?? previous ?? 0
            let fallback = max(row.rect.height * 1.35, 8)
            let lineHeight: CGFloat
            if measured > 4 {
                lineHeight = min(max(measured, 8), max(row.rect.height * 2.6, 12))
            } else {
                lineHeight = fallback
            }
            lines.append(Line(rect: row.rect,
                              baselineY: row.baseline,
                              lineHeight: lineHeight,
                              chars: row.chars))
        }
        return PageTextMap(pageSize: CGSize(width: media.width, height: media.height),
                           lines: lines)
    }

    // MARK: - Hit testing

    /// Tolerance in page points. It shrinks as the page is zoomed in, so a
    /// finger covers fewer page points at 3× than at 1×, and it is clamped to
    /// 40% of the row height so it can never reach the neighbouring row.
    static func tolerance(base: CGFloat, relativeZoom: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let scaled = base / max(relativeZoom, 1)
        return min(scaled, max(lineHeight * 0.4, 1))
    }

    /// Row under a vertical position. The nearest baseline wins, but only while
    /// the point is inside the row's band plus the zoom-scaled tolerance;
    /// otherwise there is no row and no selection is created.
    func lineIndex(atY y: CGFloat, tolerance: CGFloat) -> Int? {
        guard !lines.isEmpty else { return nil }
        // The closest baseline decides which row the finger means; the band and
        // the tolerance only decide whether the finger is close enough to any
        // text at all.
        var closest = 0
        var closestDistance = CGFloat.greatestFiniteMagnitude
        for (index, line) in lines.enumerated() {
            let distance = abs(y - line.baselineY)
            if distance < closestDistance {
                closestDistance = distance
                closest = index
            }
        }
        let line = lines[closest]
        let band = line.band
        let outside: CGFloat
        if y < band.minY {
            outside = band.minY - y
        } else if y > band.maxY {
            outside = y - band.maxY
        } else {
            outside = 0
        }
        // Never let the miss margin exceed 40% of the row height, whatever
        // tolerance the caller derived from the zoom level.
        let limit = min(tolerance, max(line.lineHeight * 0.4, 1))
        return outside <= limit ? closest : nil
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
    func wordSelection(at point: CGPoint, tolerance: CGFloat) -> PageLineSelection? {
        guard let lineIndex = lineIndex(atY: point.y, tolerance: tolerance) else { return nil }
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
        return PageLineSelection(line: line,
                                 start: charIndex(inLine: line, atX: fromX),
                                 end: charIndex(inLine: line, atX: toX))
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

    /// Union of the selected glyph boxes.
    func rect(for selection: PageLineSelection) -> CGRect? {
        guard lines.indices.contains(selection.line) else { return nil }
        let chars = lines[selection.line].chars
        guard !chars.isEmpty else { return nil }
        let lower = min(max(selection.lower, 0), chars.count - 1)
        let upper = min(max(selection.upper, lower), chars.count - 1)
        if lower == upper { return chars[lower] }
        var rect = chars[lower]
        for index in (lower + 1)...upper {
            rect = rect.union(chars[index])
        }
        return rect
    }

    /// Page points → 0…1 with a top-left origin (what the PDF engine takes).
    func normalised(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX / pageSize.width,
               y: rect.minY / pageSize.height,
               width: rect.width / pageSize.width,
               height: rect.height / pageSize.height)
    }
}
