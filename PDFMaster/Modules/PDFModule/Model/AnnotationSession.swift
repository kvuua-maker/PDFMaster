import Foundation

/// Undo/redo stack of one annotation editing session.
///
/// Kept separate from the views so the behaviour of the panel can be tested
/// without a simulator: `drawn` is what is on the page, `undone` is what Redo
/// can put back. Done drops the whole session.
struct AnnotationSession<Item: Equatable> {
    private(set) var drawn: [Item] = []
    private(set) var undone: [Item] = []

    var count: Int { drawn.count }
    var canUndo: Bool { !drawn.isEmpty }
    var canRedo: Bool { !undone.isEmpty }

    mutating func add(_ item: Item) {
        drawn.append(item)
        // A new annotation invalidates the redo branch, like a text editor.
        undone.removeAll()
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let last = drawn.popLast() else { return false }
        undone.append(last)
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let last = undone.popLast() else { return false }
        drawn.append(last)
        return true
    }

    mutating func clear() {
        drawn.removeAll()
        undone.removeAll()
    }
}
