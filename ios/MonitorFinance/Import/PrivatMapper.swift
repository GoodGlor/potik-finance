import Foundation

/// One statement row → one `Transaction`, mirroring `MonobankMapper`. Pure.
///
/// Privat has no per-row id, so identity is derived: the running balance
/// after the row is the field that separates two identical purchases in the
/// same second, and it is stable across exports — which is what makes
/// re-importing an overlapping period a merge instead of a duplication.
enum PrivatMapper {

    static func key(_ row: PrivatRow) -> String {
        "\(dateComponent(row.date))|\(row.amountMinor)|\(row.cardSuffix)|\(row.balanceMinor)|\(row.descriptionText)"
    }

    /// `Int(Date.timeIntervalSince1970)` traps at runtime for a non-finite
    /// value (`.infinity`/`.nan`) and for any finite value outside `Int`'s
    /// range — both are perfectly constructible `Date` values, just not ones
    /// `PrivatStatementParser` ever produces. `key` is a pure function over
    /// any `PrivatRow`, so a garbage-but-constructible date must degrade to
    /// *some* stable component instead of crashing the app. The bound below
    /// (years 0001–9999) comfortably contains every real and test date.
    private static func dateComponent(_ date: Date) -> Int {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= -62_135_596_800, seconds <= 253_402_300_799 else { return 0 }
        return Int(seconds)
    }

    /// Only the wording that names the owner's own card is a transfer — the
    /// generic outgoing-transfer wording used when money goes to another
    /// person must stay an expense, so the match requires «свою»/«своєї»,
    /// never bare «картку».
    ///
    /// **A cash withdrawal used to match here too** and it no longer does
    /// (board #6). Typing it `.transfer` kept it out of the queue AND out of
    /// every spending figure, so a person who takes 2 000 ₴ from an ATM and
    /// spends it on groceries saw neither the groceries nor the 2 000 ₴ — the
    /// app simply reported that much less spending, in that month, forever.
    /// The ATM is the last place the app can see that money, so that is where
    /// it counts. The row is now an ordinary pending expense which the queue
    /// offers `BudgetMath.cashCategory` for, in one tap.
    static func isOwnTransferText(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("свою картку") || lowered.contains("своєї картки")
    }

    static func isOwnTransfer(_ row: PrivatRow) -> Bool {
        isOwnTransferText(row.category + " " + row.descriptionText)
    }

    /// Privat's statement vocabulary, in the app's words (board #14).
    ///
    /// The suggestion chip CREATES whatever category it carries, so a
    /// statement word passed through verbatim becomes a real category on one
    /// tap: «Ресторани, кафе, бари» lands beside the seeded «Кафе та
    /// ресторани», and the two then split one shop's history between them.
    /// Board #15 spent a card folding forty names down to nineteen; without
    /// this table the chip grows them back, one tap at a time, and the person
    /// doing it is being *helpful* — they tapped the button the app offered.
    ///
    /// **Keys are lowercased**; the lookup folds case, so a statement that
    /// capitalises differently between exports still matches.
    ///
    /// Two provenances, both deliberate:
    ///
    /// * The names seen in a real statement — «Супермаркети та продукти»,
    ///   «Ресторани, кафе, бари», «Кредити», «Зняття готівки» (the last from
    ///   board #6, the only translation that used to exist).
    /// * Every decided rename from the seed generator's own `CATEGORY_RENAMES`.
    ///   Those keys are the owner's sheet vocabulary rather than Privat's, so
    ///   some may be inert here forever — but each one is a word whose meaning
    ///   this project has ALREADY ruled on, and re-deciding it in a second
    ///   place is how two spellings of one rule start to drift.
    ///   `test_the_privat_map_agrees_with_the_seed_generator` fails if they do.
    ///
    /// A name that is not here falls through unchanged and is created as
    /// before — the card asked for that, and inventing a target for a word
    /// nobody has seen would be worse than letting the owner name it.
    static let categoryMap: [String: String] = [
        // seen in a real statement
        "зняття готівки": BudgetMath.cashCategory,
        "супермаркети та продукти": "Продукти",
        "ресторани, кафе, бари": "Кафе та ресторани",
        // the same idea, the word order the board card recorded — one of the
        // two spellings is what this bank actually writes and neither costs
        // anything to carry
        "кафе, бари, ресторани": "Кафе та ресторани",
        "кредити": "Кредит",
        // one name per idea — mirrored from `CATEGORY_RENAMES`
        "аптеки": "Медицина",
        "комуналка": "Квартплата",
        "інтернет": "Квартплата",
        "ремонт техніки": "Дім та ремонт",
        "оплата частинами": "Кредит",
        "таксі": "Транспорт",
        "суші": "Кафе та ресторани",
        "освіта": "Послуги",
        "страхування": "Послуги",
        "платежі до бюджету": "Послуги",
        "спорт": "Розваги",
        "цифрові товари": "Розваги",
        // the things a person buys, under one heading
        "покупки / побут": "Покупки",
        "одяг та взуття": "Покупки",
        "книги та канцтовари": "Покупки",
        "квіти": "Покупки",
        "краса": "Покупки",
        // Board #149, and every one of these was MEASURED in the owner's own
        // categorization log rather than guessed at. Each is a word
        // PrivatBank really writes that had no entry here, so the suggestion
        // chip offered it verbatim and one tap made it a real category — the
        // exact failure this table's own comment predicted.
        //
        // «Авто» is the one the owner reported: «There is an Automobile, so
        // why is Авто there?» The bank wrote it 28 times, the chip was tapped
        // twice, and the rule then cascaded to 8 more rows — so two merchants'
        // car spending ended up split across two names.
        "авто": "Автомобіль",
        // A second medicine word, beside «аптеки» which is already folded.
        "медичні послуги": "Медицина",
        // Beside «спорт» and «цифрові товари», which already land here.
        "кіно": "Розваги",
        // The compound spelling. Both halves were already folded separately —
        // «комуналка» and «інтернет» — and the bank writes them joined.
        "комуналка та інтернет": "Квартплата",
        // Beside «одяг та взуття», «квіти» and «краса»: things a person buys.
        "годинники та ювелірні вироби": "Покупки",
        // Beside «освіта», «страхування» and «платежі до бюджету».
        "поповнення мобільного": "Послуги",
    ]

    /// Words PrivatBank writes that name a MECHANISM rather than a purpose.
    ///
    /// The «переказ…» rule below already refuses these, and for the reason
    /// stated there: a movement of money is not a reason for it. «Платежі за
    /// реквізитами» is the same shape — a payment made by bank details can be
    /// rent, a fine, or a present — and it was seen 4 times in the owner's
    /// real data, once accepted from the chip, creating a category named after
    /// a payment method (board #149).
    ///
    /// Better no chip than a one-tap answer that is only ever right by
    /// accident.
    static let mechanismWords: Set<String> = ["платежі за реквізитами"]

    /// Seen in real data, deliberately NOT mapped, and each with its reason.
    ///
    /// Board #149 asked that every difference be "either mapped or
    /// deliberately recorded". These are the recorded ones: mapping them would
    /// be inventing an answer, and `test_privat_category_words_are_all_ruled_on`
    /// treats this set as an explicit decision rather than a gap.
    ///
    /// * **«АЗС»** — the owner picks «АЗС» by hand alongside «Автомобіль» in
    ///   the same log. Folding fuel into the car category would erase
    ///   a distinction they are actively making. Their call, not ours.
    /// * **«Туризм»** — rare, and the owner has never chosen it as a
    ///   category. There is no evidence of what they want it to mean.
    static let unmappedByDecision: Set<String> = ["азс", "туризм"]

    /// Privat's word for one of this row's rows, in the app's vocabulary —
    /// or `nil` when the honest answer is to offer nothing.
    ///
    /// **`nil` for anything named «переказ…»**, and that is a deviation from
    /// the card, which asked for "create it as today". A transfer word names
    /// a MOVEMENT, not a purpose: one pays a friend back for groceries, the
    /// next splits a restaurant bill, the one after is rent. Creating a
    /// category called «Перекази» is the same harm as creating a second cafe
    /// category, wearing different clothes — and `GenericMerchant` already
    /// rules on exactly this, which is why these rows get a card per
    /// transaction in the first place. Better no chip than a one-tap answer
    /// that is only ever right by accident.
    ///
    /// Own-card transfers never reach here (they are `.transfer` before a
    /// suggestion is read) and income rows carry no suggestion at all, so the
    /// prefix only ever fires on money going to another person.
    ///
    /// Idempotent: every value in the table is a seeded category and no value
    /// is also a key, so translating an already-translated word returns it
    /// unchanged. That matters because rows imported before board #14 have
    /// «Готівка» stored where they now store «Зняття готівки».
    static func suggestion(for category: String) -> String? {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = trimmed.lowercased()
        guard !key.hasPrefix("переказ"), !mechanismWords.contains(key) else { return nil }
        return categoryMap[key] ?? trimmed
    }

    /// The bank these rows belong to. Named here rather than spelled out at
    /// each use so the queue's suggestion chip and the mapper cannot drift
    /// apart — the chip is only correct for rows this mapper produced.
    static let bankId = "privatbank"

    /// What every statement row's `externalId` starts with — and the only way
    /// `PrivatCrossSource`'s callers can tell a statement row already in the
    /// store from a letter's. Named here so the two cannot drift, the way
    /// `PrivatEmailMapper.externalIdPrefix` is.
    static let externalIdPrefix = bankId + "|"

    static func transaction(_ row: PrivatRow, bankId: String = PrivatMapper.bankId) -> Transaction {
        let transfer = isOwnTransfer(row)
        let income = row.amountMinor > 0
        let key = key(row)
        let name = externalIdPrefix + key
        return Transaction(
            id: UUIDv5.make(namespace: UUIDv5.appNamespace, name: name),
            date: row.date,
            kind: transfer ? .transfer : (income ? .income : .expense),
            // Income must land in a category whose kind is `.earned`
            // counts, or it contributes zero to the income base — the same
            // rule MonobankMapper's own test pins.
            category: (income && !transfer) ? BudgetMath.defaultIncomeCategory : "",
            merchant: row.descriptionText,
            amount: row.amountMinor,
            cardSuffix: row.cardSuffix,
            bankId: bankId,
            receiptId: nil,
            splits: [],
            resolution: transfer ? .transfer : .pending,
            // Privat's own category, surfaced by the queue's suggestion chip
            // — but only for an expense. An income row already carries the
            // correct (countable) category, and «Зарахування» etc. are NOT
            // categories whose kind is `.earned`: if a later queue chip
            // ever applied a suggestion verbatim, accepting it on an income
            // row would move that income out of the budget's income base —
            // the exact harm the income-category default exists to prevent.
            //
            // **Stored as the bank wrote it** (board #14). `suggestion(for:)`
            // translates it where the chip is OFFERED, not here, for two
            // reasons: the Debug categorization log records this field as its
            // `bankSuggestion`, and a column meaning "what the bank guessed"
            // filled with the app's own word is a lie in a training corpus;
            // and translating at read time means every Privat row already on
            // the device is covered, instead of only rows imported after this
            // shipped — the hole board #4's second pass found in `mcc`.
            suggestions: (transfer || income || row.category.isEmpty)
                ? [] : [row.category],
            externalId: name,
            hold: false,
            // The statement export has no MCC column, and inventing one from
            // Privat's own category text would put a guess where the other
            // bank puts a fact.
            mcc: nil,
            // Column J's running balance, kept so `PrivatCrossSource` can
            // recognise this purchase when the notification letter for it
            // arrives (or already has) under a different suffix masking, a
            // different merchant text and a different second.
            balanceAfterMinor: row.balanceMinor)
    }
}
