import SwiftUI
import UIKit

/// Precise annotation placement on the rendered page.
///
/// Two fingers zoom and pan the page even while a tool is active, one finger
/// draws. Underline and strike-through take their length from the drag, so the
/// line ends exactly where the finger is lifted instead of at a fixed default
/// width, and the result is applied wherever the page is zoomed or scrolled to.
struct AnnotationPlacementView: View {
    let image: UIImage?
    let kind: PDFAnnotationKind
    let onApply: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var selection: CGRect?
    @State private var showHint = true

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color(.systemBackground).ignoresSafeArea()
                page
                hint
            }
            .midnightScreen()
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(PDFL10n.t("Скасувати")) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(PDFL10n.t("Додати")) {
                        if let selection { onApply(selection) }
                    }
                    .disabled(selection == nil)
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(6))
                withAnimation(.easeOut(duration: 0.4)) { showHint = false }
            }
        }
        .interactiveDismissDisabled(true)
    }

    @ViewBuilder private var page: some View {
        if let image {
            AnnotationCanvas(image: image, kind: kind, selection: $selection)
                .ignoresSafeArea(edges: .bottom)
        } else {
            Text(PDFL10n.t("Немає сторінки для анотації"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var hint: some View {
        if showHint {
            Text(kind.hint)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

/// Bridges the UIKit canvas into SwiftUI; the binding only carries the final,
/// normalised rectangle the engine needs.
private struct AnnotationCanvas: UIViewRepresentable {
    let image: UIImage
    let kind: PDFAnnotationKind
    @Binding var selection: CGRect?

    func makeUIView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView(image: image, kind: kind)
        let coordinator = context.coordinator
        view.onSelection = { rect in coordinator.parent.selection = rect }
        return view
    }

    func updateUIView(_ view: AnnotationCanvasView, context: Context) {
        context.coordinator.parent = self
        view.update(kind: kind)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: AnnotationCanvas
        init(_ parent: AnnotationCanvas) { self.parent = parent }
    }
}

private extension PDFAnnotationKind {
    var title: String {
        switch self {
        case .highlight: PDFL10n.t("Маркер")
        case .underline: PDFL10n.t("Підкреслення")
        case .strikeOut: PDFL10n.t("Закреслення")
        case .square: PDFL10n.t("Прямокутник")
        case .circle: PDFL10n.t("Коло")
        case .comment: PDFL10n.t("Коментар")
        }
    }

    var hint: String {
        switch self {
        case .underline, .strikeOut:
            PDFL10n.t("Проведіть пальцем уздовж слова — лінія буде такої довжини. Двома пальцями: масштаб і прокрутка.")
        default:
            PDFL10n.t("Обведіть область пальцем. Двома пальцями: масштаб і прокрутка.")
        }
    }
}
