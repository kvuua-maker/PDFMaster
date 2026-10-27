import SwiftUI

/// Tap (or drag) on the page to place an annotation exactly where the finger is.
struct AnnotationPlacementView: View {
    let image: UIImage?
    let kind: PDFAnnotationKind
    let onApply: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var rect: CGRect?

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    Color(.systemBackground)
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                    if let rect {
                        Rectangle()
                            .stroke(Color.accentColor, lineWidth: 2)
                            .background(Color.accentColor.opacity(0.15))
                            .frame(width: rect.width * geometry.size.width,
                                   height: rect.height * geometry.size.height)
                            .position(x: rect.midX * geometry.size.width,
                                      y: rect.midY * geometry.size.height)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let start = value.startLocation
                            let current = value.location
                            let minX = min(start.x, current.x) / geometry.size.width
                            let maxX = max(start.x, current.x) / geometry.size.width
                            let minY = min(start.y, current.y) / geometry.size.height
                            let maxY = max(start.y, current.y) / geometry.size.height
                            let width = max(maxX - minX, 0.05)
                            let height = max(maxY - minY, 0.02)
                            rect = CGRect(x: minX, y: minY, width: width, height: height)
                        }
                )
            }
            .midnightScreen()
            .navigationTitle(kind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(PDFL10n.t("Скасувати")) { onCancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(PDFL10n.t("Додати")) {
                        if let rect { onApply(rect) }
                    }
                }
            }
        }
        .interactiveDismissDisabled(true)
    }
}
