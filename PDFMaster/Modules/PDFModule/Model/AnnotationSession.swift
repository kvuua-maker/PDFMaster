import Foundation

/// Undo/redo stack of one annotation editing session.
///
/// Items are stored in groups so that a single gesture which produced several
/// annotations (three underlined rows, for instance) is undone in one step.
/// Kept separate from the views so the behaviour can be tested without a
/// simulator.
struct AnnotationSession<Item: Equatable> {
    private var groups: [[Item]] = []
    private var undoneGroups: [[Item]] = []

    /// All items currently drawn, top to bottom.
    var drawn: [Item] { groups.flatMap { $0 } }
    var count: Int { groups.reduce(0) { $0 + $1.count } }
    var canUndo: Bool { !groups.isEmpty }
    var canRedo: Bool { !undoneGroups.isEmpty }

    mutating func add(_ item: Item) {
        add(contentsOf: [item])
    }

    mutating func add(contentsOf items: [Item]) {
        guard !items.isEmpty else { return }
        groups.append(items)
        // A new annotation invalidates the redo branch, like a text editor.
        undoneGroups.removeAll()
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let last = groups.popLast() else { return false }
        undoneGroups.append(last)
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let last = undoneGroups.popLast() else { return false }
        groups.append(last)
        return true
    }

    mutating func clear() {
        groups.removeAll()
        undoneGroups.removeAll()
    }
}
