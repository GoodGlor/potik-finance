import XCTest
import SwiftUI
import UIKit
@testable import MonitorFinance

/// Board #57. The twenty category washes, measured rather than admired.
///
/// The card asked that two categories not share a colour. Index uniqueness
/// gives that on paper; this file is what makes it true on a screen. The old
/// twelve had pairs 0.051 apart in RGB — distinct integers, one colour to the
/// eye — so a palette this app ships has to be held to a number.
///
/// Every floor here was chosen by running the optimiser that produced the
/// array and taking what it could actually reach in the mockups' colour band,
/// then rounding down. They are not aspirations; they are the measured result
/// with a little slack, which is the only kind of floor that stays green.
final class CategoryWashTests: XCTestCase {

    private func rgb(_ colour: Color) -> (r: Double, g: Double, b: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(colour)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private typealias RGB = (r: Double, g: Double, b: Double)

    private func distance(_ a: RGB, _ b: RGB) -> Double {
        ((a.r - b.r) * (a.r - b.r)
       + (a.g - b.g) * (a.g - b.g)
       + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    private func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    // MARK: colourblind simulation

    /// Viénot–Brettel–Mollon dichromat simulation, applied in LINEAR light.
    ///
    /// Applying it to sRGB values directly — which is the mistake that makes
    /// these matrices look wrong — overstates separation, because gamma
    /// stretches the dark end where the collapsed channels land. The whole
    /// point of measuring here is to catch a pair that a colourblind reader
    /// cannot tell apart, so the simulation has to be the pessimistic one.
    private func simulate(_ c: RGB, _ m: (Double, Double, Double, Double, Double, Double,
                                          Double, Double, Double)) -> RGB {
        func linear(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        func encode(_ v: Double) -> Double {
            let x = min(1, max(0, v))
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        let (r, g, b) = (linear(c.r), linear(c.g), linear(c.b))
        return (encode(m.0 * r + m.1 * g + m.2 * b),
                encode(m.3 * r + m.4 * g + m.5 * b),
                encode(m.6 * r + m.7 * g + m.8 * b))
    }

    /// Red-green blindness of the commoner kind — roughly 6% of men.
    private func deuteranope(_ c: RGB) -> RGB {
        simulate(c, (0.625, 0.375, 0, 0.700, 0.300, 0, 0, 0.300, 0.700))
    }

    private func protanope(_ c: RGB) -> RGB {
        simulate(c, (0.1121, 0.8853, -0.0005, 0.1127, 0.8897, -0.0001, 0.0045, 0, 0.9994))
    }

    // MARK: the palette

    /// One wash per seeded category, plus one. Nineteen ship; the twentieth is
    /// the first one a person creates.
    ///
    /// The count is not decoration — `AppStore.nextTintIndex` allocates within
    /// it, and shrinking the array below nineteen would make two SEEDED
    /// categories share a colour on a fresh install, which is the exact
    /// defect this card closed.
    func testThereIsAWashForEverySeededCategoryAndOneToSpare() throws {
        let seed = try SeedLoader.load()
        XCTAssertEqual(seed.categories.count, 19, "the seed changed; the palette may need to")
        XCTAssertGreaterThan(Theme.washes.count, seed.categories.count)
        XCTAssertEqual(Theme.washes.count, 20)
    }

    /// The complaint, measured. The old twelve had a pair at 0.051; this is
    /// the floor across all 190 pairs of the twenty.
    func testNoTwoWashesAreNearlyTheSame() {
        let all = Theme.washes.map(rgb)
        for i in 0..<all.count {
            for j in (i + 1)..<all.count {
                XCTAssertGreaterThan(distance(all[i], all[j]), 0.19,
                                     "washes \(i) and \(j) read as one colour")
            }
        }
    }

    /// **The number that shaped the palette.** Optimised for ordinary vision
    /// alone, twenty colours in this band reach 0.235 apart — and two of them
    /// land 0.019 apart under deuteranopia, which is to say identical. Trading
    /// 0.235 down to 0.194 buys 0.019 up to 0.096, and that is the array that
    /// shipped.
    ///
    /// 0.096 is not "distinguishable" and this test does not claim it is. It
    /// is the best twenty colours can do for a dichromat, whose colour vision
    /// is roughly two-dimensional. Board #61's icon is what actually names the
    /// category; the floor here only stops the palette from regressing to the
    /// point where colour adds nothing at all.
    func testTheWashesDoNotCollapseForAColourblindReader() {
        for (name, transform) in [("deuteranopia", deuteranope), ("protanopia", protanope)] {
            let all = Theme.washes.map { transform(rgb($0)) }
            for i in 0..<all.count {
                for j in (i + 1)..<all.count {
                    XCTAssertGreaterThan(distance(all[i], all[j]), 0.09,
                                         "\(name): washes \(i) and \(j) are one colour")
                }
            }
        }
    }

    /// **And a much higher floor for the pairs that actually touch.**
    ///
    /// Washes are handed out in alphabetical order of category name and
    /// Налаштування → Категорії lists categories alphabetically, so
    /// consecutive entries in the array are the two swatches a person sees one
    /// above the other. Ordered by hue — which is how the array was first
    /// written — that made every comparable pair the closest pair in the
    /// palette, and the screen read as a gradient. A screenshot found it; this
    /// is what stops it coming back.
    func testTouchingWashesAreFurtherApartStill() {
        let all = Theme.washes.map(rgb)
        for i in 0..<(all.count - 1) {
            XCTAssertGreaterThan(distance(all[i], all[i + 1]), 0.40,
                                 "washes \(i) and \(i + 1) sit one above the other")
            XCTAssertGreaterThan(distance(deuteranope(all[i]), deuteranope(all[i + 1])), 0.20,
                                 "washes \(i) and \(i + 1) touch and blur together")
        }
    }

    /// Board #61 draws an icon on this swatch in a fixed dark ink, so every
    /// wash has to carry one. 4.5:1 is the WCAG floor for a graphical object
    /// against its background, and unlike the donut's arcs this genuinely is
    /// an object on a background.
    ///
    /// **Fixed ink and not `Theme.ink`.** The washes are one set for both
    /// appearances; `Theme.ink` inverts. A near-white icon on a pale wash in
    /// dark mode would be invisible, so the icon does not follow the scheme
    /// either — see `CategorySwatch`.
    func testAnIconCanBeReadOnEveryWash() {
        let ink = rgb(Theme.swatchInk)
        for (i, wash) in Theme.washes.enumerated() {
            XCTAssertGreaterThan(contrast(rgb(wash), ink), 4.5,
                                 "wash \(i) cannot carry an icon")
        }
    }

    /// A swatch must be visible AS a swatch in both appearances — which is two
    /// opposite constraints, because the washes do not change and the card
    /// under them does. Too pale and it vanishes on white; too deep and it
    /// merges into the dark card.
    func testEveryWashIsVisibleOnBothCards() {
        // Resolved through `Theme.card` rather than against literal white:
        // the light card IS white today, and a test written against the
        // literal would go on passing if it stopped being.
        let lightCard = rgb(Theme.card)
        for (i, wash) in Theme.washes.enumerated() {
            XCTAssertGreaterThan(contrast(rgb(wash), lightCard), 1.2,
                                 "wash \(i) disappears on the light card")
        }
        // The dark card, resolved the way the app draws it.
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Theme.card)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        let darkCard: RGB = (Double(r), Double(g), Double(b))
        for (i, wash) in Theme.washes.enumerated() {
            XCTAssertGreaterThan(contrast(rgb(wash), darkCard), 3.0,
                                 "wash \(i) merges into the dark card")
        }
    }

    /// The unconstrained optimum was neon — full-saturation magenta and lime,
    /// 0.345 apart and wrong for every other pixel in this app. The band is
    /// what keeps twenty colours inside the mockups' warm register, and it is
    /// the reason the separation floor is 0.199 rather than 0.345.
    func testEveryWashStaysInsideTheAppsRegister() {
        for (i, wash) in Theme.washes.enumerated() {
            var h: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
            UIColor(wash).getHue(&h, saturation: &s, brightness: &br, alpha: &a)
            XCTAssertLessThanOrEqual(s, 0.75, "wash \(i) is louder than the palette")
            XCTAssertGreaterThanOrEqual(br, 0.55, "wash \(i) is too dark to be a wash")
        }
    }

    // MARK: the index

    func testAnIndexPastTheEndWrapsRatherThanTrapping() {
        XCTAssertEqual(Theme.wash(20), Theme.wash(0))
        XCTAssertEqual(Theme.wash(43), Theme.wash(3))
    }

    /// A hand-edited or restored file can carry a negative. Swift's `%` keeps
    /// the sign, so the obvious one-modulo version indexes out of bounds on
    /// the very line written to prevent it.
    func testANegativeIndexWrapsRatherThanCrashing() {
        XCTAssertEqual(Theme.wash(-1), Theme.wash(19))
        XCTAssertEqual(Theme.wash(-20), Theme.wash(0))
    }

    /// Pins the ALGORITHM behind the unknown-category fallback, not just its
    /// self-consistency. Swift's `hashValue` is seeded per process, so a
    /// fallback built on it reshuffles every launch — and within one process
    /// still looks stable, which is why `assertEqual(f(x), f(x))` would pass
    /// over the broken version. These are the exact djb2-mod-20 values,
    /// computed independently.
    func testTheFallbackIsDjb2AndNotSwiftHashValue() {
        XCTAssertEqual(Theme.fallbackIndex(for: "Продукти"), 17)
        XCTAssertEqual(Theme.fallbackIndex(for: "Кафе та ресторани"), 13)
        XCTAssertEqual(Theme.fallbackIndex(for: "Автомобіль"), 15)
        XCTAssertEqual(Theme.fallbackIndex(for: "Зарплата"), 0)
    }
}
