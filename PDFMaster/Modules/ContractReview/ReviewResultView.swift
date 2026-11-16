import SwiftUI

/// The result of one review: a risk badge, the findings with their page, and
/// the clauses the contract is missing.
struct ReviewResultView: View {
    let name: String
    let response: ReviewResponse
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if response.isUsable {
                        riskHeader
                        findingsSection
                        missingSection
                        footer
                    } else {
                        messageCard
                    }
                    Button("Обрати інший договір") {
                        onDone()
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
            .midnightScreen()
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрити") { dismiss() }
                }
            }
        }
    }

    private var riskHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(riskColor).frame(width: 12, height: 12)
                Text(riskTitle)
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
            }
            Text("\(response.findings.count) зауважень · \(response.missing.count) відсутніх умов")
                .font(.footnote)
                .foregroundStyle(MidnightGold.secondaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MidnightGold.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var findingsSection: some View {
        if response.findings.isEmpty {
            Text("Явних ризикованих умов не знайдено.")
                .font(.callout)
                .foregroundStyle(MidnightGold.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Що варто узгодити")
                ForEach(response.findings) { finding in
                    NavigationLink {
                        FindingDetailView(finding: finding)
                    } label: {
                        FindingRow(finding: finding)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var missingSection: some View {
        if !response.missing.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Чого немає в договорі")
                ForEach(response.missing) { item in
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

    private var messageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: response.status == "blank" ? "doc" : "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(response.message ?? "Не вдалося проаналізувати документ")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            if let score = response.stats?.ocrScore, response.status == "unreadable" {
                Text(String(format: "Якість розпізнавання: %.0f з 100", score))
                    .font(.caption)
                    .foregroundStyle(MidnightGold.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(MidnightGold.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let pages = response.stats?.pages { Text("сторінок: \(pages)") }
            if let ms = response.stats?.ms { Text("· \(ms) мс") }
            if let anchored = response.stats?.anchored, let total = response.stats?.findings {
                Text("· прив’язано \(anchored)/\(total)")
            }
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

    private var riskColor: Color {
        switch response.riskLevel {
        case "high": return .red
        case "medium": return .orange
        case "low": return .green
        default: return .gray
        }
    }

    private var riskTitle: String {
        switch response.riskLevel {
        case "high": return "Високий ризик"
        case "medium": return "Середній ризик"
        case "low": return "Низький ризик"
        default: return "Без оцінки"
        }
    }
}

private struct FindingRow: View {
    let finding: ReviewFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(severityLabel)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(severityColor.opacity(0.18), in: Capsule())
                    .foregroundStyle(severityColor)
                Spacer()
                if let page = finding.pageNumber {
                    Text("стор. \(page)")
                        .font(.caption2)
                        .foregroundStyle(MidnightGold.secondaryText)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(MidnightGold.surface, in: RoundedRectangle(cornerRadius: 14))
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

private struct FindingDetailView: View {
    let finding: ReviewFinding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(finding.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(finding.explanation)
                    .font(.callout)
                    .foregroundStyle(MidnightGold.secondaryText)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Цитата з договору")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MidnightGold.secondaryText)
                    Text("«\(finding.quote)»")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .italic()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(MidnightGold.surface, in: RoundedRectangle(cornerRadius: 14))
                if let page = finding.pageNumber {
                    Text("Абзац на сторінці \(page)")
                        .font(.caption)
                        .foregroundStyle(MidnightGold.secondaryText)
                }
            }
            .padding(20)
        }
        .midnightScreen()
        .navigationTitle("Зауваження")
        .navigationBarTitleDisplayMode(.inline)
    }
}
