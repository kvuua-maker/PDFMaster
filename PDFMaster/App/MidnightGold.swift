import SwiftUI

/// The single source of truth for the Midnight & Gold look.
enum MidnightGold {
    static let gold = Color(red: 0.90, green: 0.75, blue: 0.30)
    static let goldLight = Color(red: 0.96, green: 0.86, blue: 0.55)
    static let canvas = Color(red: 0.04, green: 0.04, blue: 0.05)
    static let surface = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let secondaryText = Color.white.opacity(0.62)

    static var rim: LinearGradient {
        LinearGradient(colors: [gold, goldLight, gold.opacity(0.45)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Applied to every screen so lists, buttons and links stay on-palette.
struct MidnightGoldScreen: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(MidnightGold.gold)
            .background(MidnightGold.canvas.ignoresSafeArea())
            .scrollContentBackground(.hidden)
    }
}

extension View {
    func midnightScreen() -> some View { modifier(MidnightGoldScreen()) }
}
