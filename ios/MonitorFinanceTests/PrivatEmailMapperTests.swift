import XCTest
@testable import MonitorFinance

final class PrivatEmailMapperTests: XCTestCase {
    private func row(id: Int = 1, amount: Int = -12_550, currency: String = "UAH",
                     merchant: String = "Тест-Маркет",
                     balance: Int? = 903_450) -> PrivatEmailTransaction {
        .init(id: id, occurredAt: Date(timeIntervalSince1970: 1_787_900_000),
              amountMinor: amount, currency: currency, cardSuffix: "5*99",
              merchantRaw: merchant, balanceAfterMinor: balance)
    }

    func testAnExpenseArrivesPending() throws {
        let tx = try XCTUnwrap(PrivatEmailMapper.transaction(row(), userId: "u1"))
        XCTAssertEqual(tx.resolution, .pending)
        XCTAssertEqual(tx.kind, .expense)
        XCTAssertEqual(tx.bankId, "privatbank")
        XCTAssertEqual(tx.externalId, "privat-email|u1|1")
        XCTAssertEqual(tx.amount, -12_550)
        XCTAssertEqual(tx.category, "")
        XCTAssertEqual(tx.suggestions, [])
        XCTAssertNil(tx.mcc)
        XCTAssertEqual(tx.hold, false)
        XCTAssertEqual(tx.balanceAfterMinor, 903_450,
                       "the half of the cross-source key this source contributes")
    }

    /// Rare — interest rows arrive without one — and the matcher must be able
    /// to see that, because a balance-less row has no identity to match on.
    func testALetterWithNoBalanceCarriesNone() throws {
        let tx = try XCTUnwrap(PrivatEmailMapper.transaction(row(balance: nil), userId: "u1"))
        XCTAssertNil(tx.balanceAfterMinor)
    }

    func testTheIdentityIsStable() throws {
        let a = try XCTUnwrap(PrivatEmailMapper.transaction(row(), userId: "u1"))
        let b = try XCTUnwrap(PrivatEmailMapper.transaction(row(), userId: "u1"))
        let c = try XCTUnwrap(PrivatEmailMapper.transaction(row(id: 2), userId: "u1"))
        XCTAssertEqual(a.id, b.id, "same row twice → same id, or a re-import duplicates")
        XCTAssertNotEqual(a.id, c.id, "the backend id is the only difference between the pair")
    }

    /// Board's fix-round-3 finding: the backend's row id is only unique
    /// PER ACCOUNT. Without `userId` folded in, a re-registration against a
    /// new account whose ids restart at 1 would map its row 1 onto whatever
    /// the OLD account's row 1 became — not a duplicate, a wrong merge that
    /// overwrites an unrelated purchase.
    func testTheIdentityIncludesTheAccountNotJustTheRow() throws {
        let sameAccount = try XCTUnwrap(PrivatEmailMapper.transaction(row(), userId: "u1"))
        let sameAccountAgain = try XCTUnwrap(PrivatEmailMapper.transaction(row(), userId: "u1"))
        let differentAccount = try XCTUnwrap(PrivatEmailMapper.transaction(row(), userId: "u2"))
        XCTAssertEqual(sameAccount.id, sameAccountAgain.id,
                       "same account, same row → still stable")
        XCTAssertNotEqual(sameAccount.id, differentAccount.id,
                          "two accounts' row 1 must never collide")
    }

    func testIncomeLandsInACountedCategory() throws {
        let tx = try XCTUnwrap(PrivatEmailMapper.transaction(
            row(amount: 250_000, merchant: "Зарахування зарплати"), userId: "u1"))
        XCTAssertEqual(tx.kind, .income)
        XCTAssertEqual(tx.category, BudgetMath.defaultIncomeCategory)
    }

    func testAPlusOwnTransferIsATransferNotIncome() throws {
        let tx = try XCTUnwrap(PrivatEmailMapper.transaction(
            row(amount: 50_000, merchant: "Переказ зі своєї картки"), userId: "u1"))
        XCTAssertEqual(tx.kind, .transfer)
        XCTAssertEqual(tx.resolution, .transfer)
        XCTAssertEqual(tx.category, "")
    }

    func testAnOwnTransferIsATransfer() throws {
        let tx = try XCTUnwrap(PrivatEmailMapper.transaction(
            row(amount: -30_000, merchant: "Переказ на свою картку"), userId: "u1"))
        XCTAssertEqual(tx.kind, .transfer)
        XCTAssertEqual(tx.resolution, .transfer)
        XCTAssertEqual(tx.category, "")
    }

    func testADollarRowIsSkipped() {
        XCTAssertNil(PrivatEmailMapper.transaction(row(currency: "USD"), userId: "u1"))
    }
}
