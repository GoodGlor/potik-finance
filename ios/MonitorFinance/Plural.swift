import Foundation

/// Counted nouns, in whichever language the interface is in.
///
/// **Not a `.stringsdict`.** The platform's own plural format would have
/// worked and would have meant a second file format, a second place to look, and — the deciding
/// point — no way to unit-test a form without going through a bundle lookup.
/// The Ukrainian rule below was already written and tested here before English
/// existed; adding a second rule beside it keeps every form in one file that
/// `PluralTests` can exercise directly.
enum Plural {
    /// Ukrainian needs three forms, and 11–14 take the "many" form despite
    /// ending in 1–4. Written once because getting it wrong is invisible
    /// until a real number lands on it.
    static func uk(_ n: Int, one: String, few: String, many: String) -> String {
        let hundred = n % 100, ten = n % 10
        if (11...14).contains(hundred) { return many }
        if ten == 1 { return one }
        if (2...4).contains(ten) { return few }
        return many
    }

    /// English needs two, and only exactly 1 takes the singular — 0 and 21 do
    /// not, which is where a rule written from Ukrainian habits goes wrong.
    static func en(_ n: Int, one: String, other: String) -> String {
        n == 1 ? one : other
    }

    /// The noun alone, for a sentence that places the number itself.
    static func word(_ n: Int, _ language: AppLanguage,
                     uk forms: (one: String, few: String, many: String),
                     en pair: (one: String, other: String)) -> String {
        language.resolved == .en
            ? en(n, one: pair.one, other: pair.other)
            : uk(n, one: forms.one, few: forms.few, many: forms.many)
    }

    /// The number and the noun. Ukrainian and English happen to agree on the
    /// order, which is the only reason one helper can serve both.
    private static func counted(_ n: Int, _ language: AppLanguage,
                                uk forms: (one: String, few: String, many: String),
                                en pair: (one: String, other: String)) -> String {
        "\(n) " + word(n, language, uk: forms, en: pair)
    }

    /// «1 покупка» · «2 покупки» · «5 покупок» · «11 покупок» · «21 покупка»
    static func purchases(_ n: Int, _ language: AppLanguage) -> String {
        counted(n, language, uk: ("покупка", "покупки", "покупок"),
                en: ("purchase", "purchases"))
    }

    /// «1 операція» · «2 операції» · «0 операцій» — Налаштування → Категорії,
    /// board #25, where the column was a bare number with nothing on the
    /// screen saying what it counted.
    ///
    /// «Операція», not «покупка»: those rows count income and savings top-ups
    /// too, and `purchases` above is the narrower word for the queue. English
    /// keeps the same distinction — "transaction" against "purchase".
    static func operations(_ n: Int, _ language: AppLanguage) -> String {
        counted(n, language, uk: ("операція", "операції", "операцій"),
                en: ("transaction", "transactions"))
    }

    /// «1 надходження» · «2 надходження» · «5 надходжень» · «21 надходження»
    ///
    /// The queue called every card «покупка», salary included (board #9).
    /// `one` and `few` are the same string because that is the language —
    /// «надходження» is its own nominative plural for 2–4 — not a copy-paste.
    static func incomes(_ n: Int, _ language: AppLanguage) -> String {
        counted(n, language, uk: ("надходження", "надходження", "надходжень"),
                en: ("payment in", "payments in"))
    }

    /// «1 хвилина» · «2 хвилини» · «5 хвилин» · «11 хвилин» · «21 хвилина»
    static func minutes(_ n: Int, _ language: AppLanguage) -> String {
        counted(n, language, uk: ("хвилина", "хвилини", "хвилин"),
                en: ("minute", "minutes"))
    }

    static func cards(_ n: Int, _ language: AppLanguage) -> String {
        counted(n, language, uk: ("картка", "картки", "карток"), en: ("card", "cards"))
    }

    static func months(_ n: Int, _ language: AppLanguage) -> String {
        counted(n, language, uk: ("місяць", "місяці", "місяців"), en: ("month", "months"))
    }

    static func questions(_ n: Int, _ language: AppLanguage) -> String {
        counted(n, language, uk: ("запитання", "запитання", "запитань"),
                en: ("question", "questions"))
    }

    /// The ACCUSATIVE singular, which Ukrainian needs and English does not
    /// distinguish: «1 операцію … пропущено», not «1 операція … пропущено».
    /// A separate helper rather than a case parameter, because this is the
    /// only sentence in the app that governs its noun.
    static func operationsAccusative(_ n: Int, _ language: AppLanguage) -> String {
        counted(n, language, uk: ("операцію", "операції", "операцій"),
                en: ("transaction", "transactions"))
    }

    /// «1 товар» · «2 товари» · «5 товарів» — the lines on a receipt, board
    /// #185's queue card. Not `purchases`: a покупка is one charge on a card,
    /// and a товар is one line inside it, so a card reading «3 покупки» over a
    /// single receipt would claim three payments that never happened.
    static func products(_ n: Int, _ language: AppLanguage) -> String {
        counted(n, language, uk: ("товар", "товари", "товарів"), en: ("item", "items"))
    }

    /// The ACCUSATIVE of `purchases`, for «Ви розібрали N покупку». Board #182,
    /// reported off the done screen.
    ///
    /// **Only the singular differs** — «покупки» and «покупок» are the same in
    /// both cases, because an inanimate noun's accusative plural copies its
    /// nominative. That is what made this survive: a test written with 2 or 5
    /// passes against the nominative helper, and it is the count of one, the
    /// commonest ending to a queue, that reads as broken.
    static func purchasesAccusative(_ n: Int, _ language: AppLanguage) -> String {
        counted(n, language, uk: ("покупку", "покупки", "покупок"),
                en: ("purchase", "purchases"))
    }
}
