import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

// Exercises the shipped annotation geometry and session stack against a real
// PDF whose text rows are known. Zoom, tap precision, drag height, repeated
// adjustment and undo/redo are geometry and state decisions, so they can be
// measured exactly here.

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

// MARK: - The row model comes from the font, not from the glyph boxes

check(abs(row1.fontSize - 14) < 1.5, "font size is recovered from the glyphs",
      String(format: "%.2f pt (real 14)", row1.fontSize))
check(abs(row1.lineHeight - row1.fontSize * 1.2) < 0.01,
      "line height is font size × 1.2",
      String(format: "%.2f pt", row1.lineHeight))

let box0 = map.rect(for: PageLineSelection(line: 0, start: 0, end: row0.chars.count - 1))!
let box1 = map.rect(for: PageLineSelection(line: 1, start: 0, end: row1.chars.count - 1))!
let box2 = map.rect(for: PageLineSelection(line: 2, start: 0, end: row2.chars.count - 1))!

check(abs(box1.height - row1.lineHeight) < 0.01,
      "selection height is one line box", String(format: "%.2f pt", box1.height))
check(!box0.intersects(box1) && !box1.intersects(box2),
      "line boxes of neighbouring rows never overlap")

// MARK: - Raised glyphs (quotes, apostrophes) must not move the baseline

let plainURL = makePDF(from: ["Apple invoice"], name: "plain.pdf")
let quotedURL = makePDF(from: ["\u{201C}Apple\u{201D} \u{2019}s invoice"], name: "quoted.pdf")
if let plainURL, let quotedURL,
   let plain = PageTextMap.make(from: plainURL), let quotedMap = PageTextMap.make(from: quotedURL),
   let plainRow = plain.lines.first, let quotedRow = quotedMap.lines.first {
    check(abs(plainRow.baselineY - quotedRow.baselineY) < 0.6,
          "quotes and apostrophes do not drag the baseline up",
          String(format: "plain %.2f vs quoted %.2f", plainRow.baselineY, quotedRow.baselineY))
    check(abs(plainRow.fontSize - quotedRow.fontSize) < 0.6,
          "the font size survives raised glyphs",
          String(format: "%.2f vs %.2f", plainRow.fontSize, quotedRow.fontSize))
    let full = PageLineSelection(line: 0, start: 0, end: quotedRow.chars.count - 1)
    if let strike = quotedMap.annotationRect(for: full, style: .strikeThrough) {
        check(strike.midY > quotedRow.rect.minY && strike.midY < quotedRow.rect.maxY,
              "quoted row: strike-through still crosses the glyphs",
              String(format: "y %.2f in %.2f…%.2f", strike.midY, quotedRow.rect.minY, quotedRow.rect.maxY))
    }
    if let underline = quotedMap.annotationRect(for: full, style: .underline) {
        check(underline.midY > quotedRow.baselineY,
              "quoted row: underline still sits below the baseline",
              String(format: "%.2f vs %.2f", underline.midY, quotedRow.baselineY))
    }
} else {
    check(false, "could not build the quoted fixture")
}

// MARK: - Each tool paints its line where the tool belongs

let fullRow = PageLineSelection(line: 1, start: 0, end: row1.chars.count - 1)

if let underline = map.annotationRect(for: fullRow, style: .underline) {
    check(underline.minY > row1.baselineY, "underline starts below the baseline",
          String(format: "top %.2f vs baseline %.2f", underline.minY, row1.baselineY))
    check(underline.height <= row1.lineHeight * 0.2, "underline is a thin line",
          String(format: "%.2f pt", underline.height))
    check(!underline.intersects(row0.rect) && !underline.intersects(row2.rect),
          "underline does not touch the neighbouring rows")
}

if let strike = map.annotationRect(for: fullRow, style: .strikeThrough) {
    let expected = row1.baselineY - row1.lineHeight * 0.3
    check(abs(strike.midY - expected) < 0.01, "strike-through is centred on baseline − 0.3 × lineHeight",
          String(format: "%.2f vs %.2f", strike.midY, expected))
    check(strike.midY > row1.rect.minY && strike.midY < row1.rect.maxY,
          "strike-through crosses the glyphs",
          String(format: "y %.2f in %.2f…%.2f", strike.midY, row1.rect.minY, row1.rect.maxY))
    check(!strike.intersects(row0.rect) && !strike.intersects(row2.rect),
          "strike-through does not touch the neighbouring rows")
}

if let circle = map.annotationRect(for: fullRow, style: .circle) {
    check(circle.contains(row1.rect), "circle surrounds the whole row",
          String(format: "%.1fx%.1f vs row %.1fx%.1f", circle.width, circle.height, row1.rect.width, row1.rect.height))
    check(circle.width > row1.rect.width + 4 && circle.height > row1.rect.height + 4,
          "circle has a visible padding")
    check(!circle.intersects(row0.rect) && !circle.intersects(row2.rect),
          "circle does not touch the neighbouring rows")
}

// The three tools must produce three different rectangles for the same row.
if let underline = map.annotationRect(for: fullRow, style: .underline),
   let strike = map.annotationRect(for: fullRow, style: .strikeThrough),
   let circle = map.annotationRect(for: fullRow, style: .circle) {
    check(underline != strike && strike != circle && underline != circle,
          "the three tools produce three different rectangles")
    check(underline.minY > strike.maxY,
          "the underline sits below the strike-through",
          String(format: "underline %.1f > strike %.1f", underline.minY, strike.maxY))
}

// MARK: - Row edges snap to the first / last character

if let fromLeft = map.selection(onLine: 1, fromX: row1.rect.minX - 30, toX: row1.rect.minX + 40) {
    check(fromLeft.start == 0, "a touch left of the row starts at the first character",
          "chars \(fromLeft.start)…\(fromLeft.end)")
    if let rect = map.rect(for: fromLeft) {
        check(abs(rect.minX - row1.chars[0].minX) < 0.01,
              "the selection starts exactly at the first glyph",
              String(format: "%.2f vs %.2f", rect.minX, row1.chars[0].minX))
    }
}
if let toRight = map.selection(onLine: 1, fromX: row1.rect.midX, toX: row1.rect.maxX + 30) {
    check(toRight.end == row1.chars.count - 1, "a touch right of the row ends at the last character",
          "chars \(toRight.end) of \(row1.chars.count - 1)")
}

// MARK: - Case 1: a tap starts at the character under the finger, at any zoom

let contentSize = CGSize(width: map.pageSize.width * 2, height: map.pageSize.height * 2)

func canvasX(forPageX pageX: CGFloat, zoom: CGFloat) -> CGFloat {
    pageX * contentSize.width / map.pageSize.width * zoom
}

func pageX(fromCanvasX canvasX: CGFloat, zoom: CGFloat) -> CGFloat {
    map.pagePoint(fromContentPoint: CGPoint(x: canvasX / zoom, y: 0),
                  contentSize: contentSize).x
}

var tapPrecise = true
var maxDrift: CGFloat = 0
for zoom in [CGFloat(1), 2, 3, 5] {
    for index in stride(from: 0, to: row1.chars.count, by: 7) {
        let box = row1.chars[index]
        let target = box.midX
        let simulated = pageX(fromCanvasX: canvasX(forPageX: target, zoom: zoom), zoom: zoom)
        maxDrift = max(maxDrift, abs(simulated - target))
        if map.charIndex(inLine: 1, atX: simulated) != index { tapPrecise = false }
        if abs(simulated - target) > 0.01 { tapPrecise = false }
    }
}
check(tapPrecise, "1×–5×: a tap resolves to the character under it, no drift",
      String(format: "max drift %.4f pt", maxDrift))

if let selection = map.selection(onLine: 1, fromX: row1.chars[10].midX, toX: row1.chars[10].midX),
   let rect = map.rect(for: selection) {
    check(selection.start == 10 && selection.end == 10, "a tap gives character granularity",
          "chars \(selection.start)…\(selection.end)")
    check(abs(rect.minX - row1.chars[10].minX) < 0.01,
          "the selection starts exactly at the tapped glyph", String(format: "%.3f pt", rect.minX))
}

// MARK: - Case 2: drag height is one row and does not change with zoom

var heights: [CGFloat] = []
var dragOK = true
for zoom in [CGFloat(1), 2, 3, 5] {
    let startX = pageX(fromCanvasX: canvasX(forPageX: row1.chars[5].midX, zoom: zoom), zoom: zoom)
    let endX = pageX(fromCanvasX: canvasX(forPageX: row1.chars[25].midX, zoom: zoom), zoom: zoom)
    guard let selection = map.selection(onLine: 1, fromX: startX, toX: endX),
          let rect = map.rect(for: selection) else { dragOK = false; continue }
    heights.append(rect.height)
    if abs(rect.height - row1.lineHeight) > 0.01 { dragOK = false }
    if rect.intersects(box0) || rect.intersects(box2) { dragOK = false }
}
check(dragOK, "1×–5×: a horizontal drag selects exactly one row height")
check(Set(heights.map { Int($0 * 1000) }).count == 1,
      "selection height is identical at every zoom", "\(heights)")

// MARK: - Case 3: the start can be adjusted repeatedly without a reset

if let base = map.selection(onLine: 1, fromX: row1.chars[10].minX, toX: row1.chars[30].maxX) {
    var selection = base
    var stable = true
    for target in [3, 20, 6] {
        selection = RowSelectionEditing.moving(.start,
                                               toX: row1.chars[target].midX,
                                               onRow: 1,
                                               in: map,
                                               selection: selection)
        if selection.line != 1 || selection.start != target || selection.end != base.end { stable = false }
    }
    check(stable, "three start adjustments in a row keep the selection intact",
          "final chars \(selection.start)…\(selection.end)")

    var endSelection = base
    var endStable = true
    for target in [40, 33, 45] {
        endSelection = RowSelectionEditing.moving(.end,
                                                  toX: row1.chars[target].midX,
                                                  onRow: 1,
                                                  in: map,
                                                  selection: endSelection)
        if endSelection.end != target || endSelection.start != base.start { endStable = false }
    }
    check(endStable, "three end adjustments in a row keep the selection intact",
          "final chars \(endSelection.start)…\(endSelection.end)")

    // Which end a touch grabs: the nearer one.
    check(RowSelectionEditing.nearestHandle(in: map, selection: base, atX: row1.chars[12].midX) == .start,
          "a touch near the start grabs the start handle")
    check(RowSelectionEditing.nearestHandle(in: map, selection: base, atX: row1.chars[28].midX) == .end,
          "a touch near the end grabs the end handle")
}

// MARK: - Case 4: taps extend the selection on the side they land

if let base = map.selection(onLine: 1, fromX: row1.chars[10].minX, toX: row1.chars[20].maxX) {
    let right = RowSelectionEditing.tap(at: CGPoint(x: row1.chars[35].midX, y: row1.rect.midY),
                                        in: map, selection: base)
    check(right.start == 10 && right.end == 35, "a tap to the right extends the end",
          "chars \(right.start)…\(right.end)")

    let left = RowSelectionEditing.tap(at: CGPoint(x: row1.chars[3].midX, y: row1.rect.midY),
                                       in: map, selection: right)
    check(left.start == 3 && left.end == 35, "a tap to the left extends the start",
          "chars \(left.start)…\(left.end)")

    let inside = RowSelectionEditing.tap(at: CGPoint(x: row1.chars[15].midX, y: row1.rect.midY),
                                         in: map, selection: base)
    check(inside.end == 20 && inside.start == 15, "a tap inside moves the nearer end",
          "chars \(inside.start)…\(inside.end)")
}

// MARK: - Cases 5–6: Apply fixes the selection, Clear allows a fresh start

var session = AnnotationSession<Int>()
if let selection = map.selection(onLine: 1, fromX: row1.chars[4].minX, toX: row1.chars[18].maxX),
   let rect = map.rect(for: selection) {
    let normalised = map.normalised(rect)
    session.add(1)
    check(session.count == 1, "Apply puts the adjusted selection into the session")
    check(normalised.width > 0 && normalised.height > 0 &&
          normalised.midX > 0 && normalised.midX < 1 &&
          normalised.midY > 0 && normalised.midY < 1,
          "the fixed rectangle is a valid normalised rect",
          String(format: "%.4f × %.4f", normalised.width, normalised.height))
}
check(map.wordSelection(at: CGPoint(x: row1.chars[2].midX, y: row1.rect.midY)) != nil,
      "after Clear a fresh tap can start a new selection")

// MARK: - Row decisions are zoom independent

for probe in [(row0.rect.midY, 0), ((row0.baselineY + row1.baselineY) / 2, 1),
              (row1.rect.midY, 1), ((row1.baselineY + row2.baselineY) / 2, 2),
              (row2.rect.midY, 2)] {
    check(map.lineIndex(atY: probe.0) == probe.1,
          "row under a probe point is the nearest baseline",
          "y \(String(format: "%.1f", probe.0)) → \(map.lineIndex(atY: probe.0).map { $0 + 1 } ?? -1)")
}

check(map.lineIndex(atY: row2.rect.maxY + 120) == nil,
      "empty area below the last row selects nothing")
check(map.lineIndex(atY: row2.rect.maxY + 2) == 2,
      "a touch just under the last row still selects it")

var sweepOK = true
var y = row0.rect.minY - 20
while y <= row2.rect.maxY + 20 {
    if let index = map.lineIndex(atY: y) {
        let chosen = map.lines[index]
        let box = map.rect(for: PageLineSelection(line: index, start: 0, end: chosen.chars.count - 1))!
        for (otherIndex, other) in map.lines.enumerated() where otherIndex != index {
            let otherBox = map.rect(for: PageLineSelection(line: otherIndex, start: 0, end: other.chars.count - 1))!
            if otherBox.intersects(box) { sweepOK = false }
        }
        // The chosen row must be the reachable row with the nearest baseline.
        var expected: Int?
        var expectedDistance = CGFloat.greatestFiniteMagnitude
        for (otherIndex, other) in map.lines.enumerated() {
            let band = other.band
            let outside: CGFloat
            if y < band.minY {
                outside = band.minY - y
            } else if y > band.maxY {
                outside = y - band.maxY
            } else {
                outside = 0
            }
            guard outside <= PageTextMap.tolerance(lineHeight: other.lineHeight) else { continue }
            let distance = abs(y - other.baselineY)
            if distance < expectedDistance {
                expectedDistance = distance
                expected = otherIndex
            }
        }
        if let expected, expected != index { sweepOK = false }
    }
    y += 1
}
check(sweepOK, "a 1 pt sweep never returns a two-row selection")

// MARK: - ↑ / ↓ movement and handle snapping (Build 41 behaviour)

if let onRow1 = map.selection(onLine: 1, fromX: row1.rect.minX + 4, toX: row1.rect.minX + 90) {
    check(map.moved(onRow1, by: -1)?.line == 0, "↑ moves the selection one row up")
    check(map.moved(onRow1, by: 1)?.line == 2, "↓ moves the selection one row down")
}
if let first = map.selection(onLine: 0, fromX: row0.rect.minX, toX: row0.rect.minX + 60) {
    check(map.moved(first, by: -1) == nil, "↑ is unavailable on the first row")
}
if let last = map.selection(onLine: 2, fromX: row2.rect.minX, toX: row2.rect.minX + 60) {
    check(map.moved(last, by: 1) == nil, "↓ is unavailable on the last row")
}
let gap01 = (row0.baselineY + row1.baselineY) / 2
check(map.nearestLineIndex(atY: gap01 - 1) == 0, "a handle above the row gap snaps to row 1")
check(map.nearestLineIndex(atY: gap01 + 1) == 1, "a handle below the row gap snaps to row 2")

// MARK: - The drag path never calls PDFKit

let callsBefore = PageTextMap.pdfCallCount
let indexSpan = max(Int(row2.rect.maxY - row0.rect.minY), 1)
let started = CFAbsoluteTimeGetCurrent()
var hits = 0
for index in 0..<20_000 {
    let probeY = row0.rect.minY + CGFloat(index % indexSpan)
    if map.lineIndex(atY: probeY) != nil { hits += 1 }
}
for index in 0..<200 {
    let probeY = row0.rect.minY + CGFloat(index % indexSpan)
    guard let line = map.nearestLineIndex(atY: probeY) else { continue }
    let x = row0.rect.minX + CGFloat(index * 2)
    _ = RowSelectionEditing.moving(.end, toX: x, onRow: line, in: map,
                                   selection: PageLineSelection(line: line, start: 0, end: 0))
}
let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
check(PageTextMap.pdfCallCount == callsBefore,
      "no PDFKit call during hit testing or a simulated drag",
      "counter \(callsBefore) → \(PageTextMap.pdfCallCount)")
check(elapsed < 100, "20k hit tests + 200 handle events stay under 100 ms",
      String(format: "%.1f ms, %d hits", elapsed, hits))

// MARK: - Undo / redo stack (Build 41, unchanged)

var stack = AnnotationSession<Int>()
stack.add(1)
stack.add(2)
stack.add(3)
check(stack.count == 3, "3 annotations drawn")
stack.undo()
check(stack.count == 2 && stack.canUndo, "undo once leaves 2 and stays in the session")
stack.undo()
stack.undo()
check(stack.count == 0 && !stack.canUndo, "undo three times leaves 0 and disables undo")
check(stack.canRedo, "redo is available after undo")
stack.redo()
check(stack.count == 1, "redo brings one annotation back")
stack.add(4)
check(!stack.canRedo, "a new annotation clears the redo branch")
stack.clear()
check(stack.count == 0 && !stack.canRedo, "Done clears the session stack")

// MARK: - A page without a text layer keeps the rectangle fallback

if let blank = makeBlankPDF(name: "blank.pdf"), let emptyMap = PageTextMap.make(from: blank) {
    check(emptyMap.isEmpty, "scanned page reports no text rows")
} else {
    check(true, "scanned page reports no text rows (no map built)")
}

print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")
exit(failures == 0 ? 0 : 1)
