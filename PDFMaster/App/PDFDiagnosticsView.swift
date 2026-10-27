import SwiftUI
import UIKit

struct PDFDiagnosticsView: View {
    private var diagnostics: RuntimeDiagnostics { RuntimeDiagnostics.shared }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ShareLink(item: diagnostics.copyableText) { Text("Поділитися логом") }
                    Button("Скопіювати", role: .none) {
                        UIPasteboard.general.string = diagnostics.copyableText
                    }
                    Button("Очистити", role: .destructive) { diagnostics.clear() }
                }
                Section("Лог") {
                    ForEach(diagnostics.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.kind).font(.caption2).foregroundStyle(.secondary)
                            Text(entry.text).font(.callout)
                        }
                    }
                }
            }
            .midnightScreen()
            .navigationTitle("Діагностика")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}
