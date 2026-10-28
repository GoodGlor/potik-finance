import XCTest

extension XCUIApplication {
    /// The first element whose identifier starts with `prefix`.
    ///
    /// Board #187. Identifiers that used to be flat — one name shared by every
    /// button in a `ForEach` — are now keyed by the row's own id, because a
    /// shared name means two waiting statements are ONE reachable element and
    /// the bug that card is about could never have been caught. Tests match on
    /// the prefix rather than naming an id, so a fixture's id can change
    /// without rewriting them.
    func first(withPrefix prefix: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
    }

    /// Find an element by `accessibilityIdentifier` regardless of the element
    /// TYPE SwiftUI gave it.
    ///
    /// This is not convenience — it is correctness. SwiftUI surfaces a
    /// `ScrollView` as `app.scrollViews`, a `List` as `app.collectionViews`,
    /// and a plain `VStack` as `app.otherElements`. So `app.otherElements["x"]`
    /// silently fails for two of those three even when the identifier is
    /// applied perfectly — and the failure reads as "the screen did not open",
    /// which sends you debugging navigation instead of the query. Ask for the
    /// identifier and let the type be whatever it is.
    func marker(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Past the welcome screen and onto the PIN pad — the first two taps of
    /// every first run since board #16.
    ///
    /// One helper rather than three lines in each of the eight walks: the
    /// screens BEFORE the thing a test is about are scaffolding, and eight
    /// copies of them is eight places to edit when onboarding gains its next
    /// step. It asserts as it goes, so a welcome screen that fails to appear
    /// is reported here rather than as "the PIN pad never showed up" three
    /// lines later.
    ///
    /// **Not for the mismatch path.** Re-entering the PIN pad after «Коди не
    /// збігаються» does not pass the welcome screen again — that is a
    /// `path = [.setPin]`, not a fresh launch — and a test that called this
    /// there would be asserting a screen the app is right not to show.
    func startOnboarding(file: StaticString = #filePath, line: UInt = #line) {
        let start = buttons["welcome.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5),
                      "the first screen of a first run is the welcome screen",
                      file: file, line: line)
        start.tap()
        XCTAssertTrue(staticTexts["Придумайте код"].waitForExistence(timeout: 5),
                      "«Почати» must lead to the PIN pad", file: file, line: line)
    }

    /// `ReceiptItemsView`'s «Підтвердити», found by the prefix of its
    /// receipt-keyed identifier (`receipt.confirm.<receiptId>`).
    ///
    /// For a receipt the seed ships, name the id and query it exactly —
    /// that is the stronger assertion and `SplitTests` does. This is for the
    /// receipts a test ATTACHES at runtime, whose id is minted fresh on
    /// every scan (`ReceiptBuilder.shell`) and no test can know in advance.
    ///
    /// Note the trailing dot in the predicate: it is what makes this query
    /// fail rather than silently succeed if the keying is ever removed —
    /// a bare `receipt.confirm` does not begin with `receipt.confirm.`.
    func confirmButton() -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'receipt.confirm.'"))
            .firstMatch
    }

    /// The refusal line, same reasoning as `confirmButton()`.
    func splitRefusal() -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'receipt.splitRefused.'"))
            .firstMatch
    }

    /// The first group card in the queue, whatever the demo data's biggest
    /// merchant happens to be — no test should assume a particular name.
    /// One card per SHOP since Task 10, not one per purchase.
    func topQueueGroup() -> XCUIElement {
        buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'queue.group.'")).firstMatch
    }

    /// The first queue card that answers for more than one purchase.
    ///
    /// Since generic merchants render one card per transaction, "the top
    /// card" is no longer reliably a multi-row one — in the demo seed the
    /// biggest card is now a single «PORTMONE INSURANCE W» row. Found by
    /// reading the count off the label rather than by naming a merchant, so
    /// this survives the seed changing shape again.
    func multiRowQueueGroup() -> XCUIElement? {
        let cards = buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'queue.group.'"))
        for index in 0..<cards.count {
            let card = cards.element(boundBy: index)
            guard let match = card.label.firstMatch(of: /(\d+) покуп/),
                  let count = Int(match.1), count > 1 else { continue }
            return card
        }
        return nil
    }

    /// Scroll a queue card into reach. The queue can now be dozens of cards
    /// deep — one per transfer — so the card a test wants is often below the
    /// fold, and `assertLive` means hittable. Safe here in a way it is not in
    /// a sheet: this is a `ScrollView`, and a swipe on a sheet's list
    /// dismisses it.
    @discardableResult
    func revealQueueGroup(_ card: XCUIElement, swipes: Int = 12) -> Bool {
        for _ in 0..<swipes {
            if card.isHittable { return true }
            swipeUp()
        }
        return card.isHittable
    }

    /// Resolve the top group card through the picker's «Це не витрата» row —
    /// present on every group regardless of which categories the seed
    /// happens to carry, so no test needs to know a category name, and
    /// resolves every purchase the group holds in the one tap.
    ///
    /// Returns false when there is no group card to tap — i.e. the queue is
    /// empty — so a drain loop can use it as its condition.
    ///
    /// `isEnabled` alongside `isHittable` throughout: `isHittable` proves only
    /// that an element is on screen and unobstructed, and stays true for a
    /// `.disabled(true)` control and even for `.opacity(0)`.
    @discardableResult
    func confirmTopQueueItem(timeout: TimeInterval = 2) -> Bool {
        let group = topQueueGroup()
        guard group.waitForExistence(timeout: timeout), group.isHittable, group.isEnabled else { return false }
        group.tap()
        let notAnExpense = buttons["picker.notAnExpense"]
        if notAnExpense.waitForExistence(timeout: timeout) {
            notAnExpense.tap()
            return true
        }
        // An INCOME group's picker has no «Це не витрата» row — a salary is
        // not a transfer — so a drain loop that only knew that one row would
        // stop dead on the first income card and report the queue as empty.
        // Any category resolves the card; which one does not matter to a
        // caller that is draining.
        let anyCategory = buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'picker.row.'")).firstMatch
        guard anyCategory.waitForExistence(timeout: timeout) else { return false }
        anyCategory.tap()
        return true
    }
}

extension XCTestCase {
    /// "This control is live": on screen, unobstructed AND accepting taps.
    ///
    /// `isHittable` on its own is this repo's longest-standing weak assertion.
    /// It stays true for a `.disabled(true)` control and for `.opacity(0)`;
    /// only moving an element off screen fails it. So a screenful of "the
    /// button is there" passed for buttons nobody could press, and the older
    /// house rule — "assert `isHittable`, not `exists`" — was weaker than it
    /// read. Both halves, or neither.
    func assertLive(_ element: XCUIElement, _ message: String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
        let suffix = message.isEmpty ? "" : " — \(message)"
        XCTAssertTrue(element.isHittable, "not on screen or obstructed\(suffix)",
                      file: file, line: line)
        XCTAssertTrue(element.isEnabled, "on screen but not accepting taps\(suffix)",
                      file: file, line: line)
    }
}
