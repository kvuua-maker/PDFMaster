import Foundation

/// Free-tier limits: three Word/Excel conversions per day and a watermark on
/// every export. The counter lives in the keychain so a reinstall does not reset
/// it; the Pro flag comes from StoreKit.
@MainActor
enum FreeTier {
    static let dailyConversions = 3

    private static let countKey = "free.conversions.count"
    private static let dayKey = "free.conversions.day"

    static var isPro: Bool { ProStore.shared.isPro }

    private static var today: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static var usedToday: Int {
        guard KeychainStore.string(for: dayKey) == today else {
            // migrate a value written by an earlier build, then forget it
            migrateLegacyCountIfNeeded()
            guard KeychainStore.string(for: dayKey) == today else { return 0 }
            return Int(KeychainStore.string(for: countKey) ?? "0") ?? 0
        }
        return Int(KeychainStore.string(for: countKey) ?? "0") ?? 0
    }

    static var remaining: Int {
        max(0, dailyConversions - usedToday)
    }

    static var canConvert: Bool {
        isPro || remaining > 0
    }

    static func registerConversion() {
        guard !isPro else { return }
        let used = usedToday
        KeychainStore.set(today, for: dayKey)
        KeychainStore.set(String(used + 1), for: countKey)
    }

    private static func migrateLegacyCountIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: dayKey) == today else { return }
        let legacy = defaults.integer(forKey: countKey)
        KeychainStore.set(today, for: dayKey)
        KeychainStore.set(String(legacy), for: countKey)
        defaults.removeObject(forKey: countKey)
        defaults.removeObject(forKey: dayKey)
    }

    static var limitMessage: String {
        "Безкоштовно доступно \(dailyConversions) конвертації на день. Ліміт вичерпано — відкрийте повний доступ."
    }

    static var usageMessage: String {
        isPro ? "Pro: конвертації без обмежень" : "Безкоштовно: залишилось \(remaining) з \(dailyConversions) сьогодні"
    }
}
