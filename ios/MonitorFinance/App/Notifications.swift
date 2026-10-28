import UserNotifications

/// Local only — there is no server, so there is no push. Refusing permission
/// disables the notification and nothing else; sync is unaffected.
enum Notifications {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// The amount goes in the BODY, never the title, so iOS's "hide previews
    /// when locked" covers it for anyone who wants that.
    /// «3 покупки», not «3 Покупки». `Plural.purchases` already returns the
    /// finished phrase; `.capitalized` on top of it upper-cased a word
    /// Ukrainian does not capitalise mid-phrase. A `static func` so the copy
    /// is pinned by a test instead of only by a device screenshot.
    static func newPurchasesTitle(_ count: Int, _ language: AppLanguage) -> String {
        count == 1 ? L10n.t("Нова покупка", language) : Plural.purchases(count, language)
    }

    /// **Board #96: the body translates too.**
    ///
    /// The title above went through `L10n.t` from the day the English interface
    /// landed; the two lines that built the body did not, so an English phone
    /// showed "New purchase" over a Ukrainian sentence. There is no view here
    /// and therefore no `EnvironmentValues.locale` for SwiftUI to resolve
    /// against — a notification is assembled copy by construction, which is
    /// exactly the case `L10n` exists for.
    ///
    /// `static func`s for the same reason the title is one: so the copy is
    /// pinned by a test rather than only by whoever happens to look at a
    /// notification on an English device.
    static func newPurchaseBody(merchant: String, amount: String,
                                _ language: AppLanguage) -> String {
        String(format: L10n.t("%@ · %@ — що це?", language), merchant, amount)
    }

    static func manyPurchasesBody(total: String, _ language: AppLanguage) -> String {
        String(format: L10n.t("Разом %@ — розберемо?", language), total)
    }

    static func postNewPurchases(_ rows: [Transaction], _ language: AppLanguage) async {
        let spends = rows.filter { $0.kind == .expense }
        guard !spends.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = newPurchasesTitle(spends.count, language)
        if spends.count == 1, let one = spends.first {
            content.body = newPurchaseBody(merchant: one.merchant,
                                           amount: abs(one.amount).uah, language)
        } else {
            content.body = manyPurchasesBody(
                total: spends.reduce(0) { $0 + abs($1.amount) }.uah, language)
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
