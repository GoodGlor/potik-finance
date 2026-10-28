import XCTest
@testable import MonitorFinance

/// Board #105 — what a queue or feed render actually costs.
///
/// The card says «Baseline first. Reproduce and measure before changing
/// anything». This is the measuring half: the per-row work a scroll repeats,
/// timed against the real demo seed rather than a fixture, so the numbers are
/// the ones the owner's phone is doing.
///
/// **These are not thresholds.** A wall-clock assertion on a shared machine is
/// a flake generator. Each test asserts a RATIO against a control doing the
/// same work the cheap way — that survives a fast machine, a slow one, and a
/// Debug build, and it is the only comparison that says anything about the fix.
@MainActor
final class ScrollCostTests: XCTestCase {

    private func seed() throws -> AppStore {
        let bundle = try SeedLoader.load()
        return AppStore(repository: MemoryRepository(), seed: bundle,
                        keychain: Keychain(service: "ua.monitorfinance.tests.\(UUID().uuidString)"))
    }

    private func elapsed(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    /// **The finding.** `DateFormatter` is an ICU object, not a struct, and
    /// building one costs orders of magnitude more than formatting a date with
    /// one that already exists.
    ///
    /// It mattered because `FeedView.dayTitle` built a fresh one on every call
    /// and `QueueView.countText` calls it for **every generic-merchant card** —
    /// the demo queue is 61 cards of which 35 are one merchant's card-to-card
    /// transfers, so a single render built 35 of them on the main thread, and a
    /// scroll rebuilds rows as they come into view.
    func testBuildingAFormatterCostsFarMoreThanUsingOne() {
        let date = Date(timeIntervalSince1970: 1_756_800_000)
        let reused = DateFormatter()
        reused.calendar = .kyiv; reused.timeZone = .kyiv; reused.dateFormat = "d MMMM"

        let building = elapsed {
            for _ in 0..<500 {
                let f = DateFormatter()
                f.calendar = .kyiv; f.timeZone = .kyiv; f.dateFormat = "d MMMM"
                _ = f.string(from: date)
            }
        }
        let reusing = elapsed {
            for _ in 0..<500 { _ = reused.string(from: date) }
        }

        XCTAssertGreaterThan(building, reusing * 3,
                             "if building one were this cheap the cache would not be worth its "
                             + "complexity — building \(building)s, reusing \(reusing)s")
    }

    /// The fix, at the call site the queue actually uses: `dayTitle` must now
    /// cost what reusing a formatter costs, not what building one costs.
    func testTheFeedsDayTitleNoLongerBuildsAFormatterEachTime() {
        let date = Date(timeIntervalSince1970: 1_756_800_000)
        _ = FeedView.dayTitle(date)          // warm the cache, as the first row does

        let cached = elapsed { for _ in 0..<500 { _ = FeedView.dayTitle(date) } }
        let building = elapsed {
            for _ in 0..<500 {
                let f = DateFormatter()
                f.calendar = .kyiv; f.timeZone = .kyiv; f.dateFormat = "d MMMM"
                _ = f.string(from: date)
            }
        }
        // **A THREEFOLD margin, not `<`.** The first version asserted only
        // `cached < building` — and passed against the unfixed code, because
        // both sides were doing the same work and the winner was noise. A test
        // that cannot fail is worse than none; measured, the cache is an order
        // of magnitude, so three is safe and unambiguous.
        XCTAssertLessThan(cached * 3, building,
                          "dayTitle is still building a formatter per call: "
                          + "\(cached)s vs \(building)s")
    }

    /// **The cache must not outlive the language.** `L10n.formatting` is
    /// process-wide and mutable — the person can change the interface language
    /// while a screen is up — and a formatter cached under the old locale would
    /// keep printing «18 березня» to an English reader for the rest of the
    /// session. That is board #96's defect arriving through a cache, which is
    /// the failure mode this whole change could have introduced.
    func testTheCacheFollowsTheLanguage() {
        let date = Date(timeIntervalSince1970: 1_756_800_000)
        let before = L10n.formatting
        defer { L10n.setFormatting(before) }

        L10n.setFormatting(.uk)
        let uk = FeedView.dayTitle(date)
        L10n.setFormatting(.en)
        let en = FeedView.dayTitle(date)

        XCTAssertNotEqual(uk, en, "a cached formatter must not freeze the language")
        L10n.setFormatting(.uk)
        XCTAssertEqual(FeedView.dayTitle(date), uk, "…and switching back gives the first answer")
    }

    /// A queue card's second line, over the shape the demo actually has: mostly
    /// generic merchants, each of which formats a date.
    func testAQueueRenderIsCheaperThanItWas() throws {
        let store = try seed()
        let groups = store.pendingGroups
        XCTAssertGreaterThan(groups.filter { $0.date != nil }.count, 10,
                             "precondition: the demo queue is mostly per-transaction cards, "
                             + "which is what makes this line hot")

        let cached = elapsed {
            for _ in 0..<20 {
                for group in groups { _ = QueueView.countText(for: group, .uk) }
            }
        }
        let building = elapsed {
            for _ in 0..<20 {
                for group in groups where group.date != nil {
                    let f = DateFormatter()
                    f.calendar = .kyiv; f.timeZone = .kyiv; f.dateFormat = "d MMMM"
                    _ = f.string(from: group.date!)
                }
            }
        }
        XCTAssertLessThan(cached * 3, building,
                          "a whole queue's worth of second lines must cost a third of what "
                          + "formatting only its DATED cards the old way costs: "
                          + "\(cached)s vs \(building)s")
    }

    /// The card's third criterion — the feed checked for the same pattern. Its
    /// row subtitle formats a time for **every** row, so it was the same defect
    /// on a longer list.
    func testTheFeedsRowTimeNoLongerBuildsAFormatterEachTime() {
        let date = Date(timeIntervalSince1970: 1_756_800_000)
        _ = TransactionRow.time(date)

        let cached = elapsed { for _ in 0..<500 { _ = TransactionRow.time(date) } }
        let building = elapsed {
            for _ in 0..<500 {
                let f = DateFormatter()
                f.calendar = .kyiv; f.timeZone = .kyiv; f.dateFormat = "HH:mm"
                _ = f.string(from: date)
            }
        }
        XCTAssertLessThan(cached * 3, building, "\(cached)s vs \(building)s")
    }

    /// Same for the month title, which the feed's toolbar draws on every render
    /// and the month sheet draws once per row.
    func testAMonthTitleNoLongerBuildsAFormatterEachTime() {
        let month = MonthKey(year: 2026, month: 8)
        _ = month.title

        let cached = elapsed { for _ in 0..<500 { _ = month.title } }
        let building = elapsed {
            for _ in 0..<500 {
                let f = DateFormatter()
                f.calendar = .kyiv; f.timeZone = .kyiv; f.dateFormat = "LLLL yyyy"
                _ = f.string(from: month.start)
            }
        }
        XCTAssertLessThan(cached * 3, building, "\(cached)s vs \(building)s")
    }

    /// Every cached format still prints what it printed before — a cache that
    /// returned the wrong formatter would be silent and everywhere.
    func testTheCachedFormattersStillPrintWhatTheyDid() {
        let before = L10n.formatting
        defer { L10n.setFormatting(before) }
        L10n.setFormatting(.uk)

        let date = Calendar.kyiv.date(from: DateComponents(year: 2026, month: 3, day: 18,
                                                          hour: 14, minute: 5))!
        XCTAssertEqual(FeedView.dayTitle(date), "18 березня")
        XCTAssertEqual(TransactionRow.time(date), "14:05")
        XCTAssertEqual(MonthKey(date).title, "березень 2026")
    }
}
