import SwiftUI
import PDFKit

/// PDF viewer that can jump to a page, used to navigate OCR search results.
struct PDFPageViewer: View {
    let url: URL
    let pageIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var needsPassword = false
    @State private var unlocked = false

    var body: some View {
        NavigationStack {
            PDFKitView(url: url, pageIndex: pageIndex, password: password)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Сторінка \(pageIndex + 1)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                    }
                }
        }
        .interactiveDismissDisabled(false)
        .alert(PDFL10n.t("Файл захищений паролем"), isPresented: $needsPassword) {
            SecureField("Пароль", text: $password)
            Button(PDFL10n.t("Відкрити")) { unlocked = true }
            Button(PDFL10n.t("Скасувати"), role: .cancel) { dismiss() }
        } message: {
            Text(PDFL10n.t("Введіть пароль, щоб переглянути документ"))
        }
        .onAppear {
            if let document = PDFDocument(url: url), document.isLocked {
                needsPassword = true
            }
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let url: URL
    let pageIndex: Int
    let password: String

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        let document = PDFDocument(url: url)
        if let document, document.isLocked, !password.isEmpty {
            _ = document.unlock(withPassword: password)
        }
        view.document = document
        if let page = view.document?.page(at: pageIndex) {
            view.go(to: page)
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if let document = view.document, document.isLocked, !password.isEmpty {
            _ = document.unlock(withPassword: password)
        }
        guard let page = view.document?.page(at: pageIndex) else { return }
        view.go(to: page)
    }
}
