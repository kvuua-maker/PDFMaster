import SwiftUI

/// Shown instead of a camera picker when the hardware or permission is missing.
struct UnsupportedCameraView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "camera.badge.ellipsis")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Камера недоступна")
                    .font(.title3.weight(.semibold))
                Text("Дозвольте доступ до камери в Налаштуваннях або скористайтеся галереєю.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link("Відкрити Налаштування", destination: settings)
                        .buttonStyle(.borderedProminent)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрити") { dismiss() } } }
        }
    }
}
