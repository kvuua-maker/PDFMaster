import SwiftUI

/// The result of one saved review. The record is read from the store so that
/// dismissing a finding updates the screen immediately.
struct ReviewResultView: View {
    let recordID: UUID
    var onDone: (() -> Void)? = nil

    @State private var store = ReviewStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let record {
                    content(for: record)
                } else {
                    Text("Запис не знайдено").foregroundStyle(MidnightGold.secondaryText)
                }
            }
            .midnightScreen()
            .navigationTitle(record?.name ?? "Перевірка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрити") { dismiss() }
                }
            }
        }
    }

    private var record: StoredRecord? { store.record(id: recordID) }

    @ViewBuilder
    private func content(for record: StoredRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if record.response.isUsable {
                    riskHeader(record)
                    findings(record)
                    dismissedFooter(record)
                    missing(record)
                    footer(record)
                } else {
                    messageCard(record)
                }
                Button("Обрати інший договір") {
                    onDone?()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(MidnightGold.gold)
                .foregroundStyle(MidnightGold.canvas)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
            .padding(20)
        }
    }

    private func riskHeader(_ record: StoredRecord) -> some View {
        let visible = record.visibleFindings
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(riskColor(record)).frame(width: 12, height: 12)
                Text(riskTitle(record))
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
            }
            Text("\(visible.count) зауважень · \(record.response.missing.count) відсутніх умов")
                .font(.footnote)
                .foregroundStyle(MidnightGold.secondaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MidnightGold.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func findings(_ record: StoredRecord) -> some View {
        let visible = record.visibleFindings
        if visible.isEmpty {
            Text("Явних ризикованих умов не знайдено.")
                .font(.callout)
                .foregroundStyle(MidnightGold.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Що варто узгодити")
                ForEach(visible) { finding in
                    FindingCard(finding: finding,
                                sourceURL: store.sourceURL(for: record),
                                recordID: record.id)
                }
            }
        }
    }

    @ViewBuilder
    private func dismissedFooter(_ record: StoredRecord) -> some View {
        if !record.dismissed.isEmpty {
            HStack(spacing: 8) {
                Text("Прибрано як «не ризик»: \(record.dismissed.count)")
                    .font(.caption2)
                    .foregroundStyle(MidnightGold.secondaryText)
                Spacer()
                Button("Повернути") {
                    for id in record.dismissed { store.restore(id, in: record.id) }
                }
                .font(.caption2)
                .foregroundStyle(MidnightGold.gold)
            }
        }
    }

    @ViewBuilder
    private func missing(_ record: StoredRecord) -> some View {
        if !record.response.missing.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Чого немає в договорі")
                ForEach(record.response.missing) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        if let explanation = item.explanation, !explanation.isEmpty {
                            Text(explanation)
                                .font(.caption)
                                .foregroundStyle(MidnightGold.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(MidnightGold.surface, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private func messageCard(_ record: StoredRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: record.response.status == "blank" ? "doc" : "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(record.response.message ?? "Не вдалося проаналізувати документ")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            if let score = record.response.stats?.ocrScore, record.response.status == "unreadable" {
                Text(String(format: "Якість розпізнавання: %.0f з 100", score))
                    .font(.caption)
                    .foregroundStyle(MidnightGold.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(MidnightGold.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func footer(_ record: StoredRecord) -> some View {
        HStack(spacing: 8) {
            if let pages = record.response.stats?.pages { Text("сторінок: \(pages)") }
            if let anchored = record.response.stats?.anchored, let total = record.response.stats?.findings {
                Text("· прив’язано \(anchored)/\(total)")
            }
            Text("· \(record.date, format: .dateTime.day().month().hour().minute())")
        }
        .font(.caption2)
        .foregroundStyle(MidnightGold.secondaryText)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(MidnightGold.secondaryText)
            .textCase(.uppercase)
    }

    private func riskColor(_ record: StoredRecord) -> Color {
        switch record.response.riskLevel {
        case "high": return .red
        case "medium": return .orange
        case "low": return .green
        default: return .gray
        }
    }

    private func riskTitle(_ record: StoredRecord) -> String {
        switch record.response.riskLevel {
        case "high": return "Високий ризик"
        case "medium": return "Середній ризик"
        case "low": return "Низький ризик"
        default: return "Без оцінки"
        }
    }
}

private struct FindingCard: View {
    let finding: ReviewFinding
    let sourceURL: URL?
    let recordID: UUID

    @State private var store = ReviewStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sourceURL, let anchor = finding.anchors?.first {
                NavigationLink {
                    ContractDocumentView(sourceURL: sourceURL,
                                         pageIndex: anchor.page,
                                         anchors: finding.anchors ?? [],
                                         title: finding.title,
                                         quote: finding.quote)
                } label: {
                    cardBody(showsAction: true)
                }
                .buttonStyle(.plain)
            } else {
                cardBody(showsAction: false)
            }

            Divider().overlay(Color.white.opacity(0.06))

            HStack {
                Button {
                    store.dismiss(finding.id, in: recordID)
                } label: {
                    Label("Це не ризик", systemImage: "hand.raised")
                }
                .font(.caption)
                .foregroundStyle(MidnightGold.secondaryText)
                Spacer()
                if let page = finding.pageNumber {
                    Text("стор. \(page)")
                        .font(.caption2)
                        .foregroundStyle(MidnightGold.secondaryText)
                }
            }
        }
        .padding(14)
        .background(MidnightGold.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func cardBody(showsAction: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(severityLabel)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(severityColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(severityColor)
                Spacer()
                if showsAction {
                    Text("показати в документі")
                        .font(.caption2)
                        .foregroundStyle(MidnightGold.gold)
                }
            }
            Text(finding.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text(finding.explanation)
                .font(.caption)
                .foregroundStyle(MidnightGold.secondaryText)
                .lineLimit(3)
        }
    }

    private var severityColor: Color {
        switch finding.severity {
        case "high": return .red
        case "medium": return .orange
        default: return .gray
        }
    }

    private var severityLabel: String {
        switch finding.severity {
        case "high": return "ВИСОКИЙ"
        case "medium": return "СЕРЕДНІЙ"
        default: return "НИЗЬКИЙ"
        }
    }
}
