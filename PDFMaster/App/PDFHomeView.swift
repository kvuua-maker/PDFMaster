import SwiftUI

/// Midnight & Gold home screen: deep graphite canvas, frosted cards with a
/// brushed-gold rim, serif headings and a restrained press animation.
struct PDFHomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var showWorkspace = false
    @State private var showDiagnostics = false

    struct ToolProxy: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let symbol: String
    }

    private let tools: [ToolProxy] = [
        .init(title: "Створити", subtitle: "Фото, сканер, порожній документ", symbol: "doc.badge.plus"),
        .init(title: "Обробити", subtitle: "Розпізнавання тексту, експорт", symbol: "wand.and.stars"),
        .init(title: "Організувати", subtitle: "Об’єднання, сторінки, порядок", symbol: "square.stack.3d.up"),
        .init(title: "Захистити", subtitle: "Пароль, водяний знак", symbol: "lock.shield"),
        .init(title: "Підписати", subtitle: "Підпис і штампи", symbol: "signature")
    ]

    private let gold = MidnightGold.gold
    private let goldLight = MidnightGold.goldLight

    private var canvas: Color {
        colorScheme == .dark
            ? MidnightGold.canvas
            : Color(red: 0.93, green: 0.92, blue: 0.90)
    }

    private var primaryText: Color {
        colorScheme == .dark ? .white : Color(red: 0.10, green: 0.10, blue: 0.11)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                        ForEach(tools) { tool in
                            ToolCard(tool: tool,
                                     gold: gold,
                                     goldLight: goldLight,
                                     textColor: .white) { showWorkspace = true }
                        }
                    }
                    footer
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .background(canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showDiagnostics = true } label: {
                        Image(systemName: "stethoscope")
                            .foregroundStyle(gold)
                    }
                    .accessibilityLabel("Діагностика")
                }
            }
            .fullScreenCover(isPresented: $showWorkspace) { PDFToolsView() }
            .sheet(isPresented: $showDiagnostics) { PDFDiagnosticsView() }
        }
        .tint(gold)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PDF MASTER")
                .font(.system(size: 11, weight: .semibold, design: .serif))
                .tracking(4)
                .foregroundStyle(gold)
            Text("Документи,\nякі варті свого вигляду")
                .font(.system(size: 30, weight: .bold, design: .serif))
                .foregroundStyle(primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(LinearGradient(colors: [gold, gold.opacity(0)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 120, height: 1)
                .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    private var footer: some View {
        Text("Створено для тих, хто цінує порядок")
            .font(.system(size: 12, design: .serif))
            .foregroundStyle(primaryText.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }
}

private struct ToolCard: View {
    let tool: PDFHomeView.ToolProxy
    let gold: Color
    let goldLight: Color
    let textColor: Color
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button {
            action()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 26, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(gold)
                Spacer(minLength: 6)
                Text(tool.title)
                    .font(.system(size: 21, weight: .bold, design: .serif))
                    .foregroundStyle(textColor)
                Text(tool.subtitle)
                    .font(.system(size: 12, weight: .regular, design: .serif))
                    .foregroundStyle(textColor.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [gold, goldLight, gold.opacity(0.5)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 15, x: 0, y: 10)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}
