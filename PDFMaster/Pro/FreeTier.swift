import Foundation

/// Free-tier limits: three Word/Excel conversions per day and a watermark on
/// exported files. Pro removes both.
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
        guard UserDefaults.standard.string(forKey: dayKey) == today else { return 0 }
        return UserDefaults.standard.integer(forKey: countKey)
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
        UserDefaults.standard.set(today, forKey: dayKey)
        UserDefaults.standard.set(used + 1, forKey: countKey)
    }

    static var limitMessage: String {
        "Безкоштовно доступно \(dailyConversions) конвертації на день. Ліміт вичерпано — відкрийте повний доступ."
    }

    static var usageMessage: String {
        isPro ? "Pro: конвертації без обмежень" : "Безкоштовно: залишилось \(remaining) з \(dailyConversions) сьогодні"
    }
}
