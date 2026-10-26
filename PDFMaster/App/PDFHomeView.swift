import SwiftUI

/// Minimal premium home: one grid of tools, no settings, no clutter.
struct PDFHomeView: View {
    @State private var showWorkspace = false
    @State private var showDiagnostics = false
    @Namespace private var animation

    private struct Tool: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let symbol: String
        let tint: Color
    }

    private let tools: [Tool] = [
        .init(title: "Створити", subtitle: "З фото, сканера чи порожній", symbol: "doc.badge.plus", tint: .blue),
        .init(title: "Обробити", subtitle: "OCR, текст, PNG, колір", symbol: "wand.and.stars", tint: .purple),
        .init(title: "Організувати", subtitle: "Об'єднати, розділити, сторінки", symbol: "square.stack.3d.up", tint: .teal),
        .init(title: "Захистити", subtitle: "Пароль, водяний знак", symbol: "lock.shield", tint: .green),
        .init(title: "Підписати", subtitle: "Підпис і штампи", symbol: "signature", tint: .orange)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(tools) { tool in
                            card(tool)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDiagnostics = true } label: { Image(systemName: "stethoscope") }
                        .accessibilityLabel("Діагностика")
                }
            }
            .sheet(isPresented: $showWorkspace) { PDFToolsView() }
            .sheet(isPresented: $showDiagnostics) { PDFDiagnosticsView() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PDF Master")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Усе, що потрібно від PDF — в одному місці")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func card(_ tool: Tool) -> some View {
        Button {
            showWorkspace = true
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tool.tint)
                    .frame(width: 48, height: 48)
                    .background(tool.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(tool.title).font(.headline)
                Text(tool.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.quaternary))
        }
        .buttonStyle(.plain)
    }
}
