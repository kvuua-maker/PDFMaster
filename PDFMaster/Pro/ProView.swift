import SwiftUI

/// The paywall. One product, one button, no clutter.
struct ProView: View {
    @Environment(\.dismiss) private var dismiss
    private var store: ProStore { ProStore.shared }

    private let features = [
        ("infinity", "Безлімітна конвертація Word та Excel"),
        ("drop.triangle", "Жодних водяних знаків на ваших файлах"),
        ("text.viewfinder", "Текстовий шар OCR для пошуку"),
        ("lock.open", "Зняття пароля з документів"),
        ("dot.radiowaves.left.and.right", "Усі майбутні оновлення включено")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    VStack(spacing: 10) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(MidnightGold.gold)
                        Text("PDF Master Pro")
                            .font(.system(size: 30, weight: .bold, design: .serif))
                        Text("Один платіж. Назавжди.")
                            .font(.system(size: 15, design: .serif))
                            .foregroundStyle(MidnightGold.secondaryText)
                    }
                    .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(features, id: \.1) { symbol, title in
                            HStack(spacing: 14) {
                                Image(systemName: symbol)
                                    .font(.system(size: 18, weight: .light))
                                    .foregroundStyle(MidnightGold.gold)
                                    .frame(width: 28)
                                Text(title)
                                    .font(.system(size: 15, design: .serif))
                                    .foregroundStyle(.white)
                                Spacer()
                            }
                        }
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(MidnightGold.rim, lineWidth: 1)
                    )

                    Button {
                        Task { await store.purchase() }
                    } label: {
                        HStack {
                            if store.isLoading { ProgressView().tint(.black) }
                            Text(store.isPro
                                 ? "Повний доступ активний"
                                 : "Отримати повний доступ за \(store.priceLabel)")
                                .font(.system(size: 16, weight: .semibold, design: .serif))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(MidnightGold.gold, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .foregroundStyle(.black)
                    }
                    .disabled(store.isPro || store.isLoading)

                    Button("Відновити покупку") { Task { await store.restore() } }
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(MidnightGold.secondaryText)

                    Text("Оплата через ваш Apple ID. Без підписок і без реєстрації.")
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(MidnightGold.secondaryText)
                        .multilineTextAlignment(.center)

                    if let message = store.message {
                        Text(message)
                            .font(.system(size: 13, design: .serif))
                            .foregroundStyle(MidnightGold.gold)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(22)
            }
            .midnightScreen()
            .navigationTitle("Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрити") { dismiss() }
                        .foregroundStyle(MidnightGold.gold)
                }
            }
        }
    }
}
