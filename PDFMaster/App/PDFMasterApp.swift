import SwiftUI

@main
struct PDFMasterApp: App {
    var body: some Scene {
        WindowGroup {
            ContractReviewHomeView()
                .preferredColorScheme(.dark)
                .tint(MidnightGold.gold)
        }
    }
}
