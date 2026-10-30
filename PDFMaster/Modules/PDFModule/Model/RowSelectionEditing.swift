import CoreGraphics
import Foundation

/// Rules for adjusting an existing row selection.
///
/// Kept out of the view (and free of UIKit) so the "drag an end, tap to extend"
/// behaviour can be tested without a simulator. The canvas only converts
/// touches into page points and calls these functions.
enum RowSelectionEditing {
    enum Handle: Equatable { case start, end }

    /// Which end of the selection a touch at `x` should grab: the closer glyph
    /// edge wins, so a finger inside a long selection moves the near end
    /// instead of starting over.
    static func nearestHandle(in map: PageTextMap, selection: PageLineSelection, atX x: CGFloat) -> Handle {
        guard map.lines.indices.contains(selection.line) else { return .end }
        let line = map.lines[selection.line]
        guard !line.chars.isEmpty else { return .end }
        let startRect = map.rect(for: PageLineSelection(line: selection.line,
                                                        start: selection.lower,
                                                        end: selection.lower)) ?? line.chars[0]
        let endRect = map.rect(for: PageLineSelection(line: selection.line,
                                                      start: selection.upper,
                                                      end: selection.upper)) ?? line.chars[line.chars.count - 1]
        return distance(from: x, to: startRect) <= distance(from: x, to: endRect) ? .start : .end
    }

    /// Moves one end to the character under `x`, staying on a single row.
    static func moving(_ handle: Handle,
                       toX x: CGFloat,
                       onRow row: Int,
                       in map: PageTextMap,
                       selection: PageLineSelection) -> PageLineSelection {
        var updated = map.clamped(selection, to: row)
        let index = map.charIndex(inLine: row, atX: x)
        switch handle {
        case .start: updated.start = index
        case .end: updated.end = index
        }
        if updated.start > updated.end {
            swap(&updated.start, &updated.end)
        }
        return updated
    }

    /// A tap on an existing selection: inside it, the nearer end moves to the
    /// tapped character; outside it, the selection grows towards the tap.
    static func tap(at point: CGPoint,
                    in map: PageTextMap,
                    selection: PageLineSelection) -> PageLineSelection {
        guard let row = map.nearestLineIndex(atY: point.y) else { return selection }
        guard let rect = map.rect(for: selection) else { return selection }
        let sameRow = row == selection.line
        let inside = sameRow && point.x >= rect.minX && point.x <= rect.maxX

        if inside {
            let handle = nearestHandle(in: map, selection: selection, atX: point.x)
            return moving(handle, toX: point.x, onRow: row, in: map, selection: selection)
        }

        var extended = map.clamped(selection, to: row)
        let index = map.charIndex(inLine: row, atX: point.x)
        if sameRow && point.x < rect.minX {
            extended.start = index
        } else if sameRow && point.x > rect.maxX {
            extended.end = index
        } else if point.x < rect.midX {
            extended.start = index
        } else {
            extended.end = index
        }
        if extended.start > extended.end {
            swap(&extended.start, &extended.end)
        }
        return extended
    }

    private static func distance(from x: CGFloat, to rect: CGRect) -> CGFloat {
        if x < rect.minX { return rect.minX - x }
        if x > rect.maxX { return x - rect.maxX }
        return 0
    }
}
