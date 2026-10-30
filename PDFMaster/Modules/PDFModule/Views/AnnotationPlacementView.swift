import SwiftUI
import UIKit

/// Annotation editing session for the first page.
///
/// The toolbar is an editing panel, not an exit: Undo removes the last drawn
/// annotation of this session, Redo puts it back, and Done is the only way to
/// leave the mode — it writes the whole session to the PDF at once.
///
/// The active (not yet applied) selection is adjusted on the canvas itself:
/// drag handles, or the ↑/↓/Apply/Clear panel floating above it.
struct AnnotationPlacementView: View {
    let image: UIImage?
    let kind: PDFAnnotationKind
    /// Glyph geometry of the page, used by the row-accurate line tools.
    let textMap: PageTextMap?
    let onApply: ([PlacedAnnotation]) -> Void

    /// Session stack: what is drawn, plus what Undo can put back. Done drops it.
    @State private var session = AnnotationSession<PlacedAnnotation>()
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
            .safeAreaInset(edge: .bottom, spacing: 0) { editingBar }
            .task {
                try? await Task.sleep(for: .seconds(6))
                withAnimation(.easeOut(duration: 0.4)) { showHint = false }
            }
        }
        .interactiveDismissDisabled(true)
    }

    @ViewBuilder private var page: some View {
        if let image {
            AnnotationCanvas(image: image,
                             kind: kind,
                             textMap: textMap,
                             annotations: session.drawn,
                             onCommit: { session.add($0) })
                .ignoresSafeArea(edges: .bottom)
        } else {
            Text(PDFL10n.t("Немає сторінки для анотації"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var editingBar: some View {
        HStack(spacing: 4) {
            Button { session.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 44, height: 40)
            }
            .disabled(!session.canUndo)
            .accessibilityLabel(PDFL10n.t("Скасувати останню анотацію"))
            .accessibilityIdentifier("annotation.undo")

            Button { session.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 44, height: 40)
            }
            .disabled(!session.canRedo)
            .accessibilityLabel(PDFL10n.t("Повторити скасовану анотацію"))
            .accessibilityIdentifier("annotation.redo")

            Spacer(minLength: 8)

            Button {
                onApply(session.drawn)
            } label: {
                Label(PDFL10n.t("Готово"), systemImage: "checkmark")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("annotation.done")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
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

/// Bridges the UIKit canvas into SwiftUI. The canvas draws the session itself;
/// this binding only mirrors the stack so undo/redo redraws in the same frame.
private struct AnnotationCanvas: UIViewRepresentable {
    let image: UIImage
    let kind: PDFAnnotationKind
    let textMap: PageTextMap?
    let annotations: [PlacedAnnotation]
    let onCommit: (PlacedAnnotation) -> Void

    func makeUIView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView(image: image, kind: kind, textMap: textMap)
        let coordinator = context.coordinator
        view.onCommit = { item in coordinator.parent.onCommit(item) }
        return view
    }

    func updateUIView(_ view: AnnotationCanvasView, context: Context) {
        context.coordinator.parent = self
        view.setAnnotations(annotations)
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
        if followsTextLines, textMap?.isEmpty != false {
            return PDFL10n.t("У цьому PDF немає текстового шару — лінія йде за пальцем. Розпізнайте текст (OCR), щоб прив'язувати лінії до рядків.")
        }
        switch self {
        case .underline, .strikeOut:
            PDFL10n.t("Проведіть пальцем уздовж слова — лінія буде такої довжини. Двома пальцями: масштаб і прокрутка.")
        default:
            PDFL10n.t("Обведіть область пальцем. Двома пальцями: масштаб і прокрутка.")
        }
    }
}
