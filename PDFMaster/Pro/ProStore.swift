import StoreKit
import SwiftUI

/// StoreKit 2 wrapper for the single non-consumable "Pro" unlock.
/// No account, no login: the entitlement lives with the Apple ID.
@MainActor
@Observable
final class ProStore {
    static let shared = ProStore()
    static let productID = "com.kvuua.pdfmaster.pro"

    private(set) var product: Product?
    private(set) var isPro = false
    private(set) var isLoading = false
    var message: String?

    private var updates: Task<Void, Never>?

    var priceLabel: String {
        product?.displayPrice ?? "$7.99"
    }

    func start() async {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case let .verified(transaction) = update {
                    await transaction.finish()
                    await self.refreshEntitlements()
                }
            }
        }
        await loadProduct()
        await refreshEntitlements()
    }

    func loadProduct() async {
        isLoading = true
        defer { isLoading = false }
        do {
            product = try await Product.products(for: [Self.productID]).first
            if product == nil {
                message = "Продукт не знайдено. Перевірте, чи створена покупка в App Store Connect."
            }
        } catch {
            message = "Не вдалося завантажити ціну: \(error.localizedDescription)"
        }
    }

    func purchase() async {
        guard let product else {
            await loadProduct()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await product.purchase()
            switch result {
            case let .success(verification):
                if case let .verified(transaction) = verification {
                    await transaction.finish()
                    await refreshEntitlements()
                    message = "Дякуємо! Повний доступ відкрито."
                } else {
                    message = "Покупку не вдалося перевірити."
                }
            case .userCancelled:
                message = nil
            case .pending:
                message = "Покупка очікує підтвердження."
            @unknown default:
                message = "Невідомий результат покупки."
            }
        } catch {
            message = "Помилка покупки: \(error.localizedDescription)"
        }
    }

    func restore() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = isPro ? "Покупку відновлено." : "Активних покупок не знайдено."
        } catch {
            message = "Не вдалося відновити: \(error.localizedDescription)"
        }
    }

    func refreshEntitlements() async {
        var owned = false
        for await entitlement in Transaction.currentEntitlements {
            if case let .verified(transaction) = entitlement,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                owned = true
            }
        }
        isPro = owned
    }
}
