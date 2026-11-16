import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// First screen of the app: one action — pick a contract — and the list of
/// previous reviews. Everything else lives behind "Ще".
struct ContractReviewHomeView: View {
    @State private var model = ContractReviewModel()
    @State private var showImporter = false
    @State private var showTools = false
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    intro
                    primaryAction
                    stateCard
                    recent
                    disclaimer
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .midnightScreen()
            .navigationTitle("Перевірка договору")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ще") { showTools = true }
                        .accessibilityIdentifier("contract.moreTools")
                }
            }
            .sheet(item: $model.presented) { item in
                ReviewResultView(recordID: item.id) { model.reset() }
            }
            .sheet(isPresented: $showTools) { PDFToolsView() }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.pdf, .image],
                          allowsMultipleSelection: false) { outcome in
                if case let .success(urls) = outcome, let url = urls.first {
                    model.analyse(url: url)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        model.analyse(imageData: data, name: "Фото договору")
                    }
                    photoItem = nil
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Що підписуєте?")
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
            Text("Завантажте договір — побачите умови, які варто узгодити до підпису. Кожне зауваження прив’язане до свого абзацу.")
                .font(.callout)
                .foregroundStyle(MidnightGold.secondaryText)
        }
    }

    private var primaryAction: some View {
        VStack(spacing: 10) {
            Button {
                showImporter = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Обрати договір").font(.headline)
                        Text("PDF, скан або фото").font(.caption).opacity(0.8)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote).opacity(0.7)
                }
                .foregroundStyle(MidnightGold.canvas)
                .padding(18)
                .background(MidnightGold.rim, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .accessibilityIdentifier("contract.pick")

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Сфотографувати або взяти з галереї", systemImage: "camera")
                    .font(.subheadline)
                    .foregroundStyle(MidnightGold.gold)
            }
        }
    }

    @ViewBuilder private var stateCard: some View {
        switch model.phase {
        case .working(let text):
            HStack(spacing: 12) {
                ProgressView().tint(MidnightGold.gold)
                Text(text).font(.subheadline).foregroundStyle(.white)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MidnightGold.surface, in: RoundedRectangle(cornerRadius: 14))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Не вдалося перевірити", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(message).font(.footnote).foregroundStyle(MidnightGold.secondaryText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MidnightGold.surface, in: RoundedRectangle(cornerRadius: 14))
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var recent: some View {
        if !model.records.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Останні перевірки")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MidnightGold.secondaryText)
                ForEach(model.records) { record in
                    Button { model.open(record) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: record))
                                .foregroundStyle(color(for: record))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.name).font(.subheadline).lineLimit(1)
                                    .foregroundStyle(.white)
                                Text(record.subtitle).font(.caption)
                                    .foregroundStyle(MidnightGold.secondaryText)
                            }
                            Spacer()
                            Text(record.date, format: .dateTime.day().month())
                                .font(.caption2)
                                .foregroundStyle(MidnightGold.secondaryText)
                        }
                        .padding(14)
                        .background(MidnightGold.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var disclaimer: some View {
        Text("Застосунок не є юридичною консультацією. Для важливих угод звертайтеся до юриста.")
            .font(.caption2)
            .foregroundStyle(MidnightGold.secondaryText)
            .padding(.top, 8)
    }

    private func icon(for record: StoredRecord) -> String {
        switch record.response.status {
        case "blank": return "doc"
        case "unreadable": return "exclamationmark.triangle"
        default: return "checkmark.shield"
        }
    }

    private func color(for record: StoredRecord) -> Color {
        switch record.response.status {
        case "blank", "unreadable": return .orange
        default:
            switch record.response.riskLevel {
            case "high": return .red
            case "medium": return .orange
            default: return .green
            }
        }
    }
}
