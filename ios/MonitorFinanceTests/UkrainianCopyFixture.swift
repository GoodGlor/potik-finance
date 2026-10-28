import XCTest
@testable import MonitorFinance

/// Pins the formatting language for a test that asserts Ukrainian copy.
///
/// **Board #85 made this necessary, and the failure it prevents is a good
/// one.** `L10n.formatting` starts at `.system`, a simulator's system language
/// is English, and `Int.uah` and `MonthKey.title` follow the interface
/// language — so a test written against «1 240,50 ₴» and «липень 2026» began
/// reading "1,240.50 ₴" and "July 2026" the moment amounts learned to be
/// English. Nothing was broken; the tests had simply never had to say which
/// language they were about.
///
/// Called from `setUp`, not applied globally to the target: a test asserting a
/// Ukrainian sentence should SAY that is what it does, and an English one — of
/// which `LocalizationTests` has several — must be able to say the opposite in
/// the same file without fighting a hidden default.
@MainActor
func pinUkrainianFormatting() {
    L10n.setFormatting(.uk)
}
