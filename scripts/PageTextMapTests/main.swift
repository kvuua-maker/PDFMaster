import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

// Exercises the shipped annotation geometry and session stack against a real
// PDF whose text rows are known. The device cases (zoom 1×/2×/3×/5×, undo/redo,
// ↑/↓ movement, "no PDFKit on the drag path") are geometry and state
// decisions, so they can be measured exactly here.

var failures = 0

func check(_ ok: Bool, _ name: String, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : " — " + detail))
    if !ok { failures += 1 }
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdfmaster-pagetext", isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

func makePDF(from text: [String], name: String) -> URL? {
    let url = dir.appendingPathComponent(name)
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &media, nil) else { return nil }
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    var y: CGFloat = 700
    for line in text {
        let attributed = NSAttributedString(string: line, attributes: [
            .font: font,
            .foregroundColor: NSColor.black
        ])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 72, y: y)
        CTLineDraw(ctLine, context)
        y -= 26
    }
    context.endPDFPage()
    context.closePDF()
    return url
}

func makeBlankPDF(name: String) -> URL? {
    let url = dir.appendingPathComponent(name)
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &media, nil) else { return nil }
    context.beginPDFPage(nil)
    context.setFillColor(NSColor.white.cgColor)
    context.fill(media)
    context.endPDFPage()
    context.closePDF()
    return url
}

let rows = [
    "The quick brown fox jumps over the lazy dog every single morning",
    "Second line with enough words to drag a selection across it",
    "Third line stays short"
]

guard let url = makePDF(from: rows, name: "lines.pdf") else {
    print("FAIL could not create the fixture PDF")
    exit(1)
}
guard let map = PageTextMap.make(from: url) else {
    print("FAIL could not build a text map from the fixture PDF")
    exit(1)
}

check(map.lines.count == 3, "fixture page has 3 text rows", "got \(map.lines.count)")
guard map.lines.count == 3 else { exit(1) }

let row0 = map.lines[0]
let row1 = map.lines[1]
let row2 = map.lines[2]

// MARK: - Rows are single rows (the Build 40 "two lines" defect)

check(!row0.rect.intersects(row1.rect) && !row1.rect.intersects(row2.rect),
      "adjacent rows never share a selection rectangle")
check(row0.rect.height < row0.lineHeight && row1.rect.height < row1.lineHeight,
      "a row rectangle is shorter than its line height",
      String(format: "%.1f/%.1f pt", row1.rect.height, row1.lineHeight))
check(row1.baselineY > row0.baselineY && row2.baselineY > row1.baselineY,
      "baselines are ordered top to bottom")

// MARK: - Case 1: zoom 1×/2×/3×/5× picks exactly one row, always the same one

let spacing = row1.baselineY - row0.baselineY
let gap01 = (row0.baselineY + row1.baselineY) / 2
let gap12 = (row1.baselineY + row2.baselineY) / 2
let probes: [(String, CGFloat, Int)] = [
    ("row 1 centre", row0.rect.midY, 0),
    ("gap 1–2 midpoint", gap01, 0),   // nearest baseline is row 1
    ("row 2 centre", row1.rect.midY, 1),
    ("gap 2–3 midpoint", gap12, 1),   // nearest baseline is row 2
    ("row 3 centre", row2.rect.midY, 2)
]

for zoom in [CGFloat(1), 2, 3, 5] {
    let tolerance = PageTextMap.tolerance(base: 10, relativeZoom: zoom, lineHeight: spacing)
    var resolved: [Int] = []
    for (name, y, expected) in probes {
        let hit = map.lineIndex(atY: y, tolerance: tolerance)
        resolved.append(hit ?? -1)
        if zoom == 3 {
            check(hit == expected, "1×–5×: \(name) resolves to row \(expected + 1)",
                  "got \(hit.map { String($0 + 1) } ?? "none")")
        }
    }
    check(resolved == probes.map { $0.2 }, "zoom \(Int(zoom))× resolves every probe to one row",
          "\(resolved.map { $0 + 1 })")
}

// A sweep across the whole text block must never return a merged selection.
var sweepOK = true
for zoom in [CGFloat(1), 3, 5] {
    let tolerance = PageTextMap.tolerance(base: 10, relativeZoom: zoom, lineHeight: spacing)
    var y = row0.rect.minY - 20
    while y <= row2.rect.maxY + 20 {
        if let index = map.lineIndex(atY: y, tolerance: tolerance) {
            let chosen = map.lines[index]
            let others = map.lines.enumerated().filter { $0.offset != index }.map { $0.element }
            if others.contains(where: { $0.rect.intersects(chosen.rect) }) { sweepOK = false }
            if abs(y - chosen.baselineY) > spacing * 0.75 { sweepOK = false }
        }
        y += 1
    }
}
check(sweepOK, "a 1 pt sweep at 1×/3×/5× never returns a two-row selection")

// MARK: - Tolerance is clamped to 40% of the row height

check(abs(PageTextMap.tolerance(base: 100, relativeZoom: 1, lineHeight: 20) - 8) < 0.001,
      "tolerance is clamped to 0.4 × line height", "\(PageTextMap.tolerance(base: 100, relativeZoom: 1, lineHeight: 20)) pt")
check(PageTextMap.tolerance(base: 10, relativeZoom: 3, lineHeight: 26) <
      PageTextMap.tolerance(base: 10, relativeZoom: 1, lineHeight: 26),
      "tolerance shrinks with zoom")

// MARK: - Case 1 (selection rect): a row selection stays on its row

if let selection = map.selection(onLine: 1, fromX: row1.rect.minX + 3, toX: row1.rect.maxX - 3),
   let rect = map.rect(for: selection) {
    check(rect.minY >= row1.rect.minY - 0.5 && rect.maxY <= row1.rect.maxY + 0.5,
          "selection stays inside its row", "\(rect) vs \(row1.rect)")
    check(!rect.intersects(row0.rect) && !rect.intersects(row2.rect),
          "selection does not touch the neighbouring rows")
    check(selection.end > selection.start, "drag spans several characters",
          "chars \(selection.start)…\(selection.end)")
} else {
    check(false, "could not build a row selection")
}

// MARK: - Empty space below the text

check(map.lineIndex(atY: row2.rect.maxY + 120, tolerance: 10) == nil,
      "empty area below the last row selects nothing")
check(map.lineIndex(atY: row2.rect.maxY + 2, tolerance: 10) == 2,
      "a touch just under the last row still selects it")

// MARK: - Case 6: ↑ / ↓ movement, Apply/Clear state

if let onRow1 = map.selection(onLine: 1, fromX: row1.rect.minX + 4, toX: row1.rect.minX + 90) {
    check(map.moved(onRow1, by: -1)?.line == 0, "↑ moves the selection one row up")
    check(map.moved(onRow1, by: 1)?.line == 2, "↓ moves the selection one row down")
    if let up = map.moved(onRow1, by: -1), let rect = map.rect(for: up) {
        check(rect.minY >= row0.rect.minY - 0.5 && rect.maxY <= row0.rect.maxY + 0.5,
              "the moved selection lands on the target row", "\(rect) vs \(row0.rect)")
    }
}
if let first = map.selection(onLine: 0, fromX: row0.rect.minX, toX: row0.rect.minX + 60) {
    check(map.moved(first, by: -1) == nil, "↑ is unavailable on the first row")
}
if let last = map.selection(onLine: 2, fromX: row2.rect.minX, toX: row2.rect.minX + 60) {
    check(map.moved(last, by: 1) == nil, "↓ is unavailable on the last row")
}

// Handle snapping follows the nearest baseline.
check(map.nearestLineIndex(atY: gap01 - 1) == 0, "a handle above the row gap snaps to row 1")
check(map.nearestLineIndex(atY: gap01 + 1) == 1, "a handle below the row gap snaps to row 2")

// MARK: - Case 7: the drag path never calls PDFKit

let callsBefore = PageTextMap.pdfCallCount
let indexSpan = max(Int(row2.rect.maxY - row0.rect.minY), 1)
let started = CFAbsoluteTimeGetCurrent()
var hits = 0
var simulatedDrags = 0
for index in 0..<20_000 {
    let y = row0.rect.minY + CGFloat(index % indexSpan)
    if map.lineIndex(atY: y, tolerance: 3.33) != nil { hits += 1 }
}
// 200 handle events: snap to a row, pick a character, build the rectangle.
for index in 0..<200 {
    let y = row0.rect.minY + CGFloat(index % indexSpan)
    guard let line = map.nearestLineIndex(atY: y) else { continue }
    let x = row0.rect.minX + CGFloat(index * 2)
    let char = map.charIndex(inLine: line, atX: x)
    _ = map.rect(for: PageLineSelection(line: line, start: 0, end: char))
    simulatedDrags += 1
}
let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
check(PageTextMap.pdfCallCount == callsBefore,
      "no PDFKit call during hit testing or a simulated drag",
      "counter \(callsBefore) → \(PageTextMap.pdfCallCount)")
check(elapsed < 100, "20k hit tests + \(simulatedDrags) handle events stay under 100 ms",
      String(format: "%.1f ms, %d hits", elapsed, hits))

// MARK: - Word tap

if let word = map.wordSelection(at: CGPoint(x: row0.rect.minX + 10, y: row0.rect.midY), tolerance: 10),
   let rect = map.rect(for: word) {
    check(rect.width < row0.rect.width * 0.5, "a tap selects a word, not the whole row",
          String(format: "%.1f of %.1f pt", rect.width, row0.rect.width))
}

// MARK: - Cases 2–5: undo / redo stack

var session = AnnotationSession<Int>()
session.add(1)
session.add(2)
session.add(3)
check(session.count == 3, "3 annotations drawn", "count \(session.count)")
session.undo()
check(session.count == 2 && session.canUndo, "undo once leaves 2 and stays in the session")
session.undo()
session.undo()
check(session.count == 0 && !session.canUndo, "undo three times leaves 0 and disables undo")
check(session.canRedo, "redo is available after undo")
session.redo()
check(session.count == 1, "redo brings one annotation back", "count \(session.count)")
session.add(4)
check(!session.canRedo, "a new annotation clears the redo branch")
session.clear()
check(session.count == 0 && !session.canRedo, "Done clears the session stack")

// MARK: - A page without a text layer keeps the rectangle fallback

if let blank = makeBlankPDF(name: "blank.pdf"), let emptyMap = PageTextMap.make(from: blank) {
    check(emptyMap.isEmpty, "scanned page reports no text rows")
} else {
    check(true, "scanned page reports no text rows (no map built)")
}

print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
