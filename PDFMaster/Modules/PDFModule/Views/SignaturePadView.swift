import SwiftUI
import UIKit

/// Draws a signature directly over the document page. The canvas is a single
/// UIView that captures every touch, so the list behind it can never scroll
/// while the user is drawing.
struct SignaturePadView: View {
    let background: UIImage?
    let onSave: (UIImage, CGRect) -> Void
    let onCancel: () -> Void

    @State private var pad = SignaturePadController()

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    Color.white
                    if let background {
                        Image(uiImage: background)
                            .resizable()
                            .scaledToFit()
                            .opacity(0.9)
                    }
                    SignatureCanvas(pad: pad)
                        .background(Color.white)
                }
                .contentShape(Rectangle())
                .onAppear { pad.canvasSize = geometry.size }
                .overlay(alignment: .bottom) {
                    Text(PDFL10n.t("Намалюйте підпис поверх документа"))
                        .font(.footnote)
                        .foregroundStyle(.black.opacity(0.6))
                        .padding(10)
                }
            }
            .navigationTitle(PDFL10n.t("Підпис"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(PDFL10n.t("Скасувати")) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(PDFL10n.t("Готово")) {
                        if let result = pad.render() { onSave(result.image, result.rect) }
                    }
                }
            }
        }
        .interactiveDismissDisabled(true)
        .preferredColorScheme(.light)
    }
}

final class SignaturePadController {
    var strokes: [[CGPoint]] = []
    var current: [CGPoint] = []
    var canvasSize: CGSize = .zero

    /// Returns the signature image plus its normalized rectangle inside the page.
    func render() -> (image: UIImage, rect: CGRect)? {
        let all = strokes.flatMap { $0 }
        guard !all.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let minX = all.map(\.x).min() ?? 0
        let maxX = all.map(\.x).max() ?? 0
        let minY = all.map(\.y).min() ?? 0
        let maxY = all.map(\.y).max() ?? 0
        let padding: CGFloat = 6
        let box = CGRect(x: minX - padding, y: minY - padding,
                         width: maxX - minX + padding * 2,
                         height: maxY - minY + padding * 2)
        let renderer = UIGraphicsImageRenderer(size: box.size)
        let image = renderer.image { context in
            UIColor.clear.setFill()
            context.cgContext.clear(CGRect(origin: .zero, size: box.size))
            UIColor.black.setStroke()
            context.cgContext.setLineWidth(3)
            context.cgContext.setLineCap(.round)
            for stroke in strokes where stroke.count > 1 {
                context.cgContext.move(to: CGPoint(x: stroke[0].x - box.minX, y: stroke[0].y - box.minY))
                for point in stroke.dropFirst() {
                    context.cgContext.addLine(to: CGPoint(x: point.x - box.minX, y: point.y - box.minY))
                }
                context.cgContext.strokePath()
            }
        }
        let rect = CGRect(x: box.minX / canvasSize.width,
                          y: box.minY / canvasSize.height,
                          width: box.width / canvasSize.width,
                          height: box.height / canvasSize.height)
        return (image, rect)
    }
}

struct SignatureCanvas: UIViewRepresentable {
    let pad: SignaturePadController

    func makeUIView(context: Context) -> CanvasView {
        let view = CanvasView()
        view.pad = pad
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        view.isOpaque = false
        return view
    }

    func updateUIView(_ view: CanvasView, context: Context) {}

    final class CanvasView: UIView {
        var pad: SignaturePadController?

        // Capture every touch so no ancestor scroll view can scroll underneath.
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let point = touches.first?.location(in: self) else { return }
            pad?.current = [point]
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let point = touches.first?.location(in: self) else { return }
            pad?.current.append(point)
            setNeedsDisplay()
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let pad, !pad.current.isEmpty else { return }
            pad.strokes.append(pad.current)
            pad.current = []
            setNeedsDisplay()
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let pad else { return }
            pad.current = []
            setNeedsDisplay()
        }
        override func draw(_ rect: CGRect) {
            guard let pad, let context = UIGraphicsGetCurrentContext() else { return }
            UIColor.black.setStroke()
            context.setLineWidth(3)
            context.setLineCap(.round)
            for stroke in pad.strokes + [pad.current] where stroke.count > 1 {
                context.move(to: stroke[0])
                for point in stroke.dropFirst() { context.addLine(to: point) }
                context.strokePath()
            }
        }
    }
}
