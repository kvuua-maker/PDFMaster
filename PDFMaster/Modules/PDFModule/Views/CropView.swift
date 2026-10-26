import SwiftUI

/// Interactive crop: drag the rectangle over the rendered page, then apply.
struct CropView: View {
    let image: UIImage?
    @Binding var onlyFirstPage: Bool
    let onApply: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var rect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var dragStart: CGRect = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.9)
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                    cropOverlay(in: geometry.size)
                }
                .contentShape(Rectangle())
            }
            .safeAreaInset(edge: .bottom) {
                Picker("Область", selection: $onlyFirstPage) {
                    Text(PDFL10n.t("Всі сторінки")).tag(false)
                    Text(PDFL10n.t("Лише перша")).tag(true)
                }
                .pickerStyle(.segmented)
                .padding()
                .background(.ultraThinMaterial)
            }
            .navigationTitle(PDFL10n.t("Обрізати"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(PDFL10n.t("Скасувати")) { onCancel() } }
                ToolbarItem(placement: .confirmationAction) { Button(PDFL10n.t("Застосувати")) { onApply(rect) } }
            }
        }
        .interactiveDismissDisabled(true)
    }

    private func cropOverlay(in size: CGSize) -> some View {
        let frame = CGRect(x: rect.minX * size.width,
                           y: rect.minY * size.height,
                           width: rect.width * size.width,
                           height: rect.height * size.height)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .path(in: frame)
                .stroke(Color.white, lineWidth: 2)
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStart == .zero { dragStart = rect }
                            let dx = value.translation.width / size.width
                            let dy = value.translation.height / size.height
                            rect = CGRect(x: min(max(dragStart.minX + dx, 0), 1 - dragStart.width),
                                          y: min(max(dragStart.minY + dy, 0), 1 - dragStart.height),
                                          width: dragStart.width,
                                          height: dragStart.height)
                        }
                        .onEnded { _ in dragStart = .zero }
                )
            cornerHandle(at: CGPoint(x: frame.minX, y: frame.minY), in: size, corner: .topLeft)
            cornerHandle(at: CGPoint(x: frame.maxX, y: frame.minY), in: size, corner: .topRight)
            cornerHandle(at: CGPoint(x: frame.minX, y: frame.maxY), in: size, corner: .bottomLeft)
            cornerHandle(at: CGPoint(x: frame.maxX, y: frame.maxY), in: size, corner: .bottomRight)
        }
    }

    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private func cornerHandle(at point: CGPoint, in size: CGSize, corner: Corner) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 22, height: 22)
            .position(point)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        var updated = rect
                        let dx = value.translation.width / size.width
                        let dy = value.translation.height / size.height
                        switch corner {
                        case .topLeft:
                            updated.origin.x = min(max(rect.minX + dx, 0), rect.maxX - 0.1)
                            updated.origin.y = min(max(rect.minY + dy, 0), rect.maxY - 0.1)
                            updated.size.width = rect.maxX - updated.minX
                            updated.size.height = rect.maxY - updated.minY
                        case .topRight:
                            updated.size.width = max(0.1, min(rect.width + dx, 1 - rect.minX))
                            updated.origin.y = min(max(rect.minY + dy, 0), rect.maxY - 0.1)
                            updated.size.height = rect.maxY - updated.minY
                        case .bottomLeft:
                            updated.origin.x = min(max(rect.minX + dx, 0), rect.maxX - 0.1)
                            updated.size.width = rect.maxX - updated.minX
                            updated.size.height = max(0.1, min(rect.height + dy, 1 - rect.minY))
                        case .bottomRight:
                            updated.size.width = max(0.1, min(rect.width + dx, 1 - rect.minX))
                            updated.size.height = max(0.1, min(rect.height + dy, 1 - rect.minY))
                        }
                        rect = updated
                    }
            )
    }
}
