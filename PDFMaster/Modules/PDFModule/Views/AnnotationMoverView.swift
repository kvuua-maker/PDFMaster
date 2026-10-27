import SwiftUI

/// Drag annotations on a rendered page; offsets are applied to the PDF on save.
struct AnnotationMoverView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    @State private var boxes: [(id: Int, rect: CGRect, label: String)] = []
    @State private var offsets: [Int: CGSize] = [:]
    @State private var pageSize: CGSize = .zero
    @State private var pageImage: UIImage?
    @State private var status: String?

    var body: some View {
        NavigationStack {
            VStack {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        if let pageImage {
                            Image(uiImage: pageImage)
                                .resizable()
                                .scaledToFit()
                        }
                        ForEach(boxes, id: \.id) { box in
                            let scale = geometry.size.width / max(pageSize.width, 1)
                            let offset = offsets[box.id] ?? .zero
                            Rectangle()
                                .stroke(Color.accentColor, lineWidth: 2)
                                .background(Color.accentColor.opacity(0.12))
                                .frame(width: box.rect.width * scale, height: box.rect.height * scale)
                                .position(
                                    x: (box.rect.midX + offset.width) * scale,
                                    y: (pageSize.height - box.rect.midY + offset.height) * scale
                                )
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in offsets[box.id] = value.translation }
                                )
                        }
                    }
                }
                .padding()
                if let status { Text(status).font(.footnote) }
                List {
                    ForEach(boxes, id: \.id) { box in
                        HStack {
                            Text(box.label).lineLimit(1)
                            Spacer()
                            Button(PDFL10n.t("Видалити"), role: .destructive) { remove(box.id) }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
            .midnightScreen()
            .navigationTitle(PDFL10n.t("Переміщення анотацій"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(PDFL10n.t("Скасувати")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(PDFL10n.t("Зберегти")) { Task { await save() } }
                }
            }
            .task { load() }
        }
    }

    private func load() {
        pageImage = PDFToolsEngine.shared.pageImageSync(url)
        pageSize = pageImage?.size ?? .zero
        let items = (try? PDFToolsEngine.shared.annotationsSync(url)) ?? []
        boxes = items.map { (id: $0.id, rect: $0.bounds, label: $0.label) }
    }

    private func remove(_ index: Int) {
        Task {
            do {
                let updated = try await PDFToolsEngine.shared.deleteAnnotation(url, annotationIndex: index)
                boxes.removeAll { $0.id == index }
                status = "Анотацію видалено: \(updated.lastPathComponent)"
            } catch {
                status = "Не вдалося видалити"
            }
        }
    }

    private func save() async {
        do {
            var working = url
            for (id, offset) in offsets {
                working = try await PDFToolsEngine.shared.moveAnnotation(working, annotationIndex: id, by: offset)
            }
            status = "Збережено"
            _ = working
            dismiss()
        } catch {
            status = "Не вдалося: \(error)"
        }
    }
}
