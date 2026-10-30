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
/// The whole point of this type is that hit testing during a drag is pure
/// arithmetic: `PDFPage.characterBounds(at:)` is called here, never on the
/// gesture path, so dragging cannot block the main thread inside PDFKit.
///
/// All rectangles are in page points with a top-left origin, i.e. the same
/// orientation as the rendered page image. Everything the engine consumes is
/// normalised at the very end by `normalised(_:)`.
struct PageTextMap {
    struct Line {
        /// Union of every glyph box on the line.
        let rect: CGRect
        /// Approximate baseline: the glyph bottom minus a descender allowance.
        let baselineY: CGFloat
        /// Glyph boxes, sorted left to right.
        let chars: [CGRect]
    }

    let pageSize: CGSize
    let lines: [Line]

    var isEmpty: Bool { lines.isEmpty }

    // MARK: - Building

    static func make(from url: URL, pageIndex: Int = 0) -> PageTextMap? {
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
            let raw = page.characterBounds(at: index)
            guard raw.width > 0.5, raw.height > 0.5 else { continue }
            boxes.append(CGRect(x: raw.minX - media.minX,
                                y: media.maxY - raw.maxY,
                                width: raw.width,
                                height: raw.height))
        }
        guard !boxes.isEmpty else { return nil }

        // Group glyphs into lines: sort by vertical centre and start a new line
        // as soon as the centre drifts by more than half a glyph height.
        boxes.sort { $0.midY < $1.midY }
        var clusters: [[CGRect]] = []
        var clusterRect = CGRect.null
        for box in boxes {
            if clusterRect.isNull {
                clusters.append([box])
                clusterRect = box
                continue
            }
            let threshold = max(clusterRect.height, box.height) * 0.55
            if abs(box.midY - clusterRect.midY) <= threshold {
                clusters[clusters.count - 1].append(box)
                clusterRect = clusterRect.union(box)
            } else {
                clusters.append([box])
                clusterRect = box
            }
        }

        var lines: [Line] = []
        lines.reserveCapacity(clusters.count)
        for cluster in clusters {
            let sorted = cluster.sorted { $0.minX < $1.minX }
            let rect = sorted.reduce(CGRect.null) { $0.union($1) }
            guard rect.width > 1, rect.height > 1 else { continue }
            let baseline = rect.maxY - rect.height * 0.18
            lines.append(Line(rect: rect, baselineY: baseline, chars: sorted))
        }
        guard !lines.isEmpty else { return nil }
        lines.sort { $0.rect.minY < $1.rect.minY }
        return PageTextMap(pageSize: CGSize(width: media.width, height: media.height),
                           lines: lines)
    }

    // MARK: - Hit testing

    /// Tolerance in page points. It shrinks as the page is zoomed in, so a
    /// finger covers fewer page points at 3× than at 1×, and it never exceeds
    /// the line's own height — which is what stops a tap from reaching the
    /// neighbouring line.
    static func tolerance(base: CGFloat, relativeZoom: CGFloat, lineHeight: CGFloat) -> CGFloat {
        let scaled = base / max(relativeZoom, 1)
        return min(scaled, max(lineHeight * 0.9, 2))
    }

    /// Line under a vertical position, or nil when nothing is close enough.
    func lineIndex(atY y: CGFloat, tolerance: CGFloat) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, line) in lines.enumerated() {
            let distance: CGFloat
            if y < line.rect.minY {
                distance = line.rect.minY - y
            } else if y > line.rect.maxY {
                distance = y - line.rect.maxY
            } else {
                distance = 0
            }
            let limit = min(tolerance, max(line.rect.height * 0.9, 2))
            guard distance <= limit else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// Closest line regardless of distance — used while dragging a handle, so
    /// the selection always snaps somewhere and never gets stuck between rows.
    func nearestLineIndex(atY y: CGFloat) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, line) in lines.enumerated() {
            let distance: CGFloat
            if y < line.rect.minY {
                distance = line.rect.minY - y
            } else if y > line.rect.maxY {
                distance = y - line.rect.maxY
            } else {
                distance = 0
            }
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

    /// Clamps a selection to a (possibly different) line, so a handle dragged
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
