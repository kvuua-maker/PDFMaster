import SwiftUI

@main
struct PDFMasterApp: App {
    var body: some Scene {
        WindowGroup {
            PDFHomeView()
                .preferredColorScheme(.dark)
        }
    }
}
