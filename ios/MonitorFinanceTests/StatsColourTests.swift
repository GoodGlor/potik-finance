import XCTest
import SwiftUI
import UIKit
@testable import MonitorFinance

/// Board #24. The donut coloured its arcs with `Theme.tint(for:)`, which
/// hashed a name into twelve washes — and nineteen seeded categories into
/// twelve slots means collisions, so two touching arcs could be the same
/// colour. The legend under it, keyed by the same hash, repeated the
/// ambiguity instead of resolving it.
///
/// Rank has no collisions by construction. What still has to be held is that
/// the eight are actually far enough apart to read as eight, which is a
/// measurement — done here rather than by eye.
///
/// **Board #57 removed the hash and its collisions, and this file stands.**
/// The reason moved rather than expired: see
/// `testColourFollowsRankAndNotTheName`. The category palette is measured
/// separately, in `CategoryWashTests` — twenty pale washes under an icon and
/// eight saturated arcs are different problems with different floors.
final class StatsColourTests: XCTestCase {

    /// Board #58: every `Theme` colour is dynamic now, so a measurement has to
    /// say WHICH appearance it is measuring. Resolved through the same
    /// `UIColor` trait path the app draws through, rather than off the raw
    /// component arrays — a palette that were correct in the arrays and wired
    /// up the wrong way round would pass a test written against those.
    private static let schemes: [(name: String, style: UIUserInterfaceStyle)] =
        [("light", .light), ("dark", .dark)]

    private func rgb(_ colour: Color,
                     _ style: UIUserInterfaceStyle) -> (r: Double, g: Double, b: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(colour)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private func distance(_ x: Color, _ y: Color, _ style: UIUserInterfaceStyle) -> Double {
        let (a, b) = (rgb(x, style), rgb(y, style))
        return ((a.r - b.r) * (a.r - b.r)
              + (a.g - b.g) * (a.g - b.g)
              + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    /// WCAG relative luminance, then the contrast ratio. Not a
    /// text-legibility claim — an arc is not text — but the number that tells
    /// "deep teal on white" from "deep teal on near-black", which is the
    /// difference board #58 had to measure.
    private func contrast(_ x: Color, _ y: Color, _ style: UIUserInterfaceStyle) -> Double {
        func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
            func channel(_ v: Double) -> Double {
                v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
        }
        let (a, b) = (luminance(rgb(x, style)), luminance(rgb(y, style)))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Eight slices, eight colours. The donut and the legend both stop at
    /// `prefix(8)`, so a palette shorter than that would start repeating.
    func testThereIsOneColourPerDrawnSlice() {
        XCTAssertEqual(Theme.rankColours.count, 8)
    }

    /// The complaint, measured. 0.25 is the floor for ANY pair — two slices
    /// on opposite sides of the ring still share a legend, where they sit two
    /// rows apart.
    func testNoTwoSliceColoursAreNearlyTheSame() {
        for (name, style) in Self.schemes {
            for i in 0..<Theme.rankColours.count {
                for j in (i + 1)..<Theme.rankColours.count {
                    XCTAssertGreaterThan(
                        distance(Theme.rankColours[i], Theme.rankColours[j], style), 0.25,
                        "\(name): slices \(i) and \(j) are too close to read as two")
                }
            }
        }
    }

    /// And a higher floor for the pairs that actually touch: an arc's
    /// neighbours are the ones a hairline gap has to separate.
    func testTouchingSlicesAreFurtherApartStill() {
        for (name, style) in Self.schemes {
            for i in 0..<(Theme.rankColours.count - 1) {
                XCTAssertGreaterThan(
                    distance(Theme.rankColours[i], Theme.rankColours[i + 1], style), 0.34,
                    "\(name): slices \(i) and \(i + 1) sit against each other in the ring")
            }
        }
    }

    /// Board #58. The light eight were chosen against white for separation
    /// alone, which is the right criterion there — but three of them are dark,
    /// and on a near-black card the indigo fell to 2.04:1 and simply
    /// disappeared. A slice a person cannot see is not a slice.
    ///
    /// 3.0 is the floor a large graphical object is normally held to. The
    /// LIGHT scheme is deliberately not asserted against it: the amber sits at
    /// 1.88:1 on white and always has, that palette shipped and was looked at,
    /// and inventing a threshold here to make an existing decision fail would
    /// be the test lying about what it checked.
    func testEverySliceIsVisibleAgainstTheDarkCardItIsDrawnOn() {
        for colour in Theme.rankColours {
            XCTAssertGreaterThan(contrast(colour, Theme.card, .dark), 3.0,
                                 "an arc that vanishes into the card is not a slice")
        }
    }

    /// The washes are ONE set for both appearances, which is only defensible
    /// while they carry no text — every call site is a `.fill()` on a small
    /// shape. Against the dark card they have to stay plainly visible, and
    /// this is the number that says they do.
    func testTheCategoryWashesStayVisibleOnBothCards() {
        for (name, style) in Self.schemes {
            for wash in Theme.washes {
                XCTAssertGreaterThan(contrast(wash, Theme.card, style), 1.2,
                                     "\(name): a wash that merges into the card names nothing")
            }
        }
    }

    /// The one that would go wrong silently: a dynamic colour wired up the
    /// wrong way round, or not dynamic at all. Ink and ground must SWAP, not
    /// merely differ.
    func testTheGroundAndTheInkActuallyChangeWithTheAppearance() {
        let inkLight = rgb(Theme.ink, .light), inkDark = rgb(Theme.ink, .dark)
        let bgLight = rgb(Theme.bg, .light), bgDark = rgb(Theme.bg, .dark)
        XCTAssertLessThan(inkLight.r, 0.5, "ink is dark in the light scheme")
        XCTAssertGreaterThan(inkDark.r, 0.5, "…and light in the dark one")
        XCTAssertGreaterThan(bgLight.r, 0.5, "the ground is light in the light scheme")
        XCTAssertLessThan(bgDark.r, 0.5, "…and dark in the dark one")

        // Text has to be readable in both, which is the one place a real WCAG
        // threshold belongs. 7.0 is AAA for body text; the light scheme
        // already clears it and the dark scheme was built to.
        for (name, style) in Self.schemes {
            XCTAssertGreaterThan(contrast(Theme.ink, Theme.card, style), 7.0, name)
            XCTAssertGreaterThan(contrast(Theme.inkSoft, Theme.card, style), 4.5, name)
        }
    }

    /// Board #182. The undo toast used to be the one place `ink` was a
    /// SURFACE rather than a text colour, and the text on it was a fixed
    /// `.white` — so in dark appearance the app drew white on `ink`'s
    /// near-white, **1.14:1** where the same pair measures 12.96:1 in light,
    /// and the two lines of the toast were simply not there. Reported off a
    /// phone, because nothing in the repository was measuring this pair.
    ///
    /// **The toast now follows the appearance instead of inverting against
    /// it** — the owner's decision, taken after seeing the inverted version:
    /// white ground and dark letters in the light theme, dark ground and light
    /// letters in the dark one. That is a different fix from the one that
    /// merely made the old pill readable, and it moves three tokens at once;
    /// each of them is measured below.
    ///
    /// It is measured here rather than judged on a screenshot for the reason
    /// the whole file exists: the light appearance looked perfect throughout,
    /// so every look at this toast that was not taken in dark mode agreed it
    /// was fine.
    func testTheUndoToastIsLegibleOnBothAppearances() {
        // The toast FOLLOWS the appearance rather than inverting against it —
        // the owner's own call: white ground and dark letters in the light
        // theme, dark ground and light letters in the dark one. So the pill is
        // `card` and the words are `ink`, and the two must SWAP together. A
        // surface that failed to invert would pass one scheme and fail the
        // other, and this says which half went wrong.
        let pillLight = rgb(Theme.card, .light), pillDark = rgb(Theme.card, .dark)
        XCTAssertGreaterThan(pillLight.r, 0.5, "the toast's ground is light in the light theme")
        XCTAssertLessThan(pillDark.r, 0.5, "…and dark in the dark one")

        for (name, style) in Self.schemes {
            // The message: 7.0 is AAA for body text, and this is the same pair
            // every other surface in the app draws text on. An undo has five
            // seconds to be read.
            XCTAssertGreaterThan(contrast(Theme.ink, Theme.card, style), 7.0,
                                 "\(name): the toast's words are unreadable on its own pill")

            // «Скасувати» is the reason the button's colour moved with the
            // pill. `greenWash` was picked to sit on the old dark pill and
            // measures 1.16:1 on a card — swapping the surface without
            // swapping this would have traded an unreadable message for an
            // unreadable button, which is the same bug with a new victim.
            XCTAssertLessThan(contrast(Theme.greenWash, Theme.card, .light), 2.0,
                              "if greenWash ever became legible on a card, say so here")
            // 3.0, not 4.5: `green` on `card` measures 4.14 in light and 7.24
            // in dark, and 4.14 is what every other green control on a card in
            // this app already is. A stricter floor here would not be a
            // standard the toast fails — it would be a standard the app fails,
            // asserted in the one place nobody would look for it.
            XCTAssertGreaterThan(contrast(Theme.green, Theme.card, style), 3.0,
                                 "\(name): the undo's own button is unreadable")
        }

        // The pill is the SAME colour as the cards it floats over, which is
        // what the owner asked for and is why `toastBar` carries a border and
        // a shadow: `card` against `bg` is 1.09:1 in light appearance, so
        // nothing but the edge separates the toast from the page. Recorded
        // here so a later "simplify" that drops the border knows what it costs.
        XCTAssertLessThan(contrast(Theme.card, Theme.bg, .light), 1.5,
                          "the toast has no colour separation; its edge is doing the work")
        // …so the edge is held to the floor a UI boundary is held to, in both
        // appearances. `Theme.hair` was tried first and measures 1.25:1 on a
        // card — a border only in principle, which is why this is `inkMuted`.
        for (name, style) in Self.schemes {
            XCTAssertGreaterThan(contrast(Theme.inkMuted, Theme.card, style), 3.0,
                                 "\(name): the toast's edge is not visible on its own ground")
            XCTAssertLessThan(contrast(Theme.hair, Theme.card, style), 2.0,
                              "\(name): if hair ever became a visible border, this can go back")
        }
    }

    /// Positional, not per-category — the whole point, and it outlived the
    /// argument that first made it.
    ///
    /// **The original reason is gone.** This test used to open by asserting
    /// that «Покупки» and «Послуги» really did share a wash, because the donut
    /// keyed by category would then have drawn two arcs in one colour. Board
    /// #57 gave every category its own wash, so that precondition is now false
    /// — `CategoryTintTests` asserts the opposite of it.
    ///
    /// **The surviving reason is the better one.** Even with twenty distinct
    /// washes, colouring the donut by category says nothing about which two
    /// arcs end up adjacent: the pair is whatever this month's spending
    /// happens to put side by side. `rankColours` is ordered so that touching
    /// arcs are the ones furthest apart, which is a promise only a positional
    /// scheme can make. Category identity is the feed's question; "which slice
    /// is which" is this screen's, and they are not the same question.
    func testColourFollowsRankAndNotTheName() {
        XCTAssertNotEqual(Theme.rank(0), Theme.rank(1))

        // The two schemes are separate arrays and must stay so: a refactor
        // that "unified" them would silently hand the donut twenty pale
        // washes chosen to sit under an icon, not eight saturated arcs.
        XCTAssertEqual(Theme.rankColours.count, 8)
        XCTAssertEqual(Theme.washes.count, 20)
        for rank in Theme.rankColours {
            XCTAssertFalse(Theme.washes.contains(rank),
                           "a rank colour has leaked into the category palette")
        }
    }

    /// Past the eighth it wraps. Nothing draws a ninth slice today; a caller
    /// that one day does should get a repeat rather than a crash.
    func testAskingPastTheEighthWrapsRatherThanTrapping() {
        XCTAssertEqual(Theme.rank(8), Theme.rank(0))
        XCTAssertEqual(Theme.rank(19), Theme.rank(3))
    }
}
