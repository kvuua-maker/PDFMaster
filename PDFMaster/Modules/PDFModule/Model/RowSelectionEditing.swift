import CoreGraphics
import Foundation

/// Rules for adjusting a (possibly multi-row) selection.
///
/// Kept out of the view and free of UIKit so the "drag an end, tap to extend"
/// behaviour can be tested without a simulator. The canvas converts touches
/// into page points and calls these functions.
enum RowSelectionEditing {
    enum Handle: Equatable { case start, end }

    /// Which end of the selection a touch at `x` should grab: the closer glyph
    /// edge wins, so a finger inside a long selection moves the near end
    /// instead of starting over.
    static func nearestHandle(in map: PageTextMap,
                              selection: PageTextSelection,
                              atX x: CGFloat) -> Handle {
        let ends = map.orderedEnds(of: selection)
        let startRect = map.charRect(inLine: ends.startLine, index: ends.startChar)
        let endRect = map.charRect(inLine: ends.endLine, index: ends.endChar)
        let startDistance = startRect.map { distance(from: x, to: $0) } ?? .greatestFiniteMagnitude
        let endDistance = endRect.map { distance(from: x, to: $0) } ?? .greatestFiniteMagnitude
        return startDistance <= endDistance ? .start : .end
    }

    /// Moves one end to the character under `x`, on the given row.
    static func moving(_ handle: Handle,
                       toX x: CGFloat,
                       onRow row: Int,
                       in map: PageTextMap,
                       selection: PageTextSelection) -> PageTextSelection {
        let ends = map.orderedEnds(of: selection)
        let index = map.charIndex(inLine: row, atX: x)
        switch handle {
        case .start:
            return PageTextSelection(anchorLine: row, anchorChar: index,
                                     focusLine: ends.endLine, focusChar: ends.endChar)
        case .end:
            return PageTextSelection(anchorLine: ends.startLine, anchorChar: ends.startChar,
                                     focusLine: row, focusChar: index)
        }
    }

    /// A tap on an existing selection: inside it, the nearer end moves to the
    /// tapped character; outside it, the selection grows towards the tap —
    /// including onto a neighbouring row, like a paragraph selection.
    static func tap(at point: CGPoint,
                    in map: PageTextMap,
                    selection: PageTextSelection) -> PageTextSelection {
        guard let row = map.nearestLineIndex(atY: point.y) else { return selection }
        let ends = map.orderedEnds(of: selection)
        let startRect = map.charRect(inLine: ends.startLine, index: ends.startChar)
        let endRect = map.charRect(inLine: ends.endLine, index: ends.endChar)
        let startX = startRect?.minX ?? 0
        let endX = endRect?.maxX ?? 0

        let insideRows = row >= ends.startLine && row <= ends.endLine
        if insideRows, point.x >= startX - 1, point.x <= endX + 1 {
            let handle = nearestHandle(in: map, selection: selection, atX: point.x)
            return moving(handle, toX: point.x, onRow: row, in: map, selection: selection)
        }

        let index = map.charIndex(inLine: row, atX: point.x)
        let after = row > ends.endLine || (row == ends.endLine && point.x > endX)
        if after {
            return PageTextSelection(anchorLine: ends.startLine, anchorChar: ends.startChar,
                                     focusLine: row, focusChar: index)
        }
        return PageTextSelection(anchorLine: row, anchorChar: index,
                                 focusLine: ends.endLine, focusChar: ends.endChar)
    }

    private static func distance(from x: CGFloat, to rect: CGRect) -> CGFloat {
        if x < rect.minX { return rect.minX - x }
        if x > rect.maxX { return x - rect.maxX }
        return 0
    }
}
