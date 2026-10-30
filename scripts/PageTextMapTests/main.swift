import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

// Exercises the shipped PageTextMap against a real PDF whose text rows are
// known, because the device test cases (D1–D4) are geometry decisions that can
// be measured exactly on any machine with PDFKit.

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

let row0 = map.lines[0].rect
let row1 = map.lines[1].rect
let row2 = map.lines[2].rect
check(row0.maxY < row1.minY || row1.maxY < row0.minY, "rows do not overlap vertically")
check(row0.height > 4 && row0.height < 30, "row height is a text row, not the page", "\(row0.height) pt")

let tolerance1x = PageTextMap.tolerance(base: 10, relativeZoom: 1, lineHeight: row1.height)
let tolerance3x = PageTextMap.tolerance(base: 10, relativeZoom: 3, lineHeight: row1.height)

// D1 — one row at 3×, no neighbour captured.
check(tolerance3x < tolerance1x, "D1 tolerance shrinks with zoom",
      String(format: "1× %.2f pt, 3× %.2f pt", tolerance1x, tolerance3x))
check(map.lineIndex(atY: row1.midY, tolerance: tolerance3x) == 1, "D1 tap on row 2 selects row 2")
if let selection = map.selection(onLine: 1, fromX: row1.minX + 3, toX: row1.maxX - 3),
   let rect = map.rect(for: selection) {
    check(rect.minY >= row1.minY - 0.5 && rect.maxY <= row1.maxY + 0.5,
          "D1 selection stays inside row 2", "\(rect) vs \(row1)")
    check(!rect.intersects(row0) && !rect.intersects(row2),
          "D1 selection does not overlap the neighbouring rows")
    check(selection.end > selection.start, "D1 drag spans several characters",
          "chars \(selection.start)…\(selection.end)")
} else {
    check(false, "D1 could not build a selection on row 2")
}

// D4 — same accuracy at 1× and 3×.
let probe = CGPoint(x: row1.midX, y: row1.midY + row1.height * 0.3)
let hit1x = map.lineIndex(atY: probe.y, tolerance: tolerance1x)
let hit3x = map.lineIndex(atY: probe.y, tolerance: tolerance3x)
check(hit1x == hit3x && hit1x == 1, "D4 the same point resolves to the same row at 1× and 3×",
      "1×: \(String(describing: hit1x)), 3×: \(String(describing: hit3x))")

// D3 — end of the page must not swallow empty space.
check(map.lineIndex(atY: row2.maxY + 120, tolerance: tolerance1x) == nil,
      "D3 empty area below the last row selects nothing")
check(map.lineIndex(atY: row2.maxY + 2, tolerance: tolerance1x) == 2,
      "D3 a touch just under the last row still selects that row")
if let last = map.selection(onLine: 2, fromX: row2.minX, toX: row2.maxX),
   let rect = map.rect(for: last) {
    check(rect.maxY <= row2.maxY + 0.5, "D3 selection never extends into empty space", "\(rect)")
}

// D2 — handle snapping between rows.
let gap = (row0.maxY + row1.minY) / 2
let gapLine = map.nearestLineIndex(atY: gap)
check(gapLine == 0 || gapLine == 1, "D2 a handle in the row gap snaps to one neighbouring row",
      "got \(String(describing: gapLine))")
check(map.nearestLineIndex(atY: row2.midY) == 2, "D2 a handle dragged onto row 3 lands on row 3")
if let selection = map.selection(onLine: 0, fromX: row0.minX + 4, toX: row0.minX + 120) {
    let moved = map.clamped(selection, to: 2)
    check(moved.line == 2, "D2 the selection follows the handle to another row")
    if let rect = map.rect(for: moved) {
        check(rect.minY >= row2.minY - 0.5 && rect.maxY <= row2.maxY + 0.5,
              "D2 the moved selection stays on row 3", "\(rect) vs \(row2)")
    }
}

// A tap should take a word, not the whole row.
if let word = map.wordSelection(at: CGPoint(x: row0.minX + 10, y: row0.midY), tolerance: tolerance1x),
   let rect = map.rect(for: word) {
    check(rect.width < row0.width * 0.5, "tap selects a word, not the whole row",
          String(format: "%.1f of %.1f pt", rect.width, row0.width))
} else {
    check(false, "tap did not resolve to a word")
}

// The gesture path must be arithmetic only: 20k hit tests should be trivial.
let started = CFAbsoluteTimeGetCurrent()
var hits = 0
for index in 0..<20_000 {
    let y = CGFloat(620 + (index % 90))
    if map.lineIndex(atY: y, tolerance: tolerance3x) != nil { hits += 1 }
}
let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
check(elapsed < 100, "D2 20k hit tests stay under 100 ms (no PDFKit on the gesture path)",
      String(format: "%.1f ms, %d hits", elapsed, hits))

// A page without a text layer must report no rows, so the canvas can fall back
// to the free rectangle instead of blocking the tool.
if let blank = makeBlankPDF(name: "blank.pdf"), let emptyMap = PageTextMap.make(from: blank) {
    check(emptyMap.isEmpty, "scanned page reports no text rows")
} else {
    check(true, "scanned page reports no text rows (no map built)")
}

print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
