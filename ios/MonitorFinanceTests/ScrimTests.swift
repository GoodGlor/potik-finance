import XCTest
import SwiftUI
@testable import MonitorFinance

/// Board #102 — text over a camera feed.
///
/// Every other colour in `Theme` answers "what appearance is the phone in".
/// This one does not, and must not: it sits over live video, and a bright
/// kitchen and a dark pocket both happen in light mode. The scanner's error
/// line was drawn on `Theme.ink.opacity(0.85)`, and `ink` is near-WHITE in
/// dark appearance — so that line was white text on a white background for
/// anybody using the app in dark mode, with nothing on screen to say so.
final class ScrimTests: XCTestCase {

    private func rgba(_ colour: Color,
                      _ style: UIUserInterfaceStyle) -> (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(colour)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }

    /// The property the whole fix rests on.
    func testTheScrimIsTheSameInBothAppearances() {
        let light = rgba(Theme.scrim, .light)
        let dark = rgba(Theme.scrim, .dark)
        XCTAssertEqual(light.r, dark.r, accuracy: 0.001)
        XCTAssertEqual(light.g, dark.g, accuracy: 0.001)
        XCTAssertEqual(light.b, dark.b, accuracy: 0.001)
        XCTAssertEqual(light.a, dark.a, accuracy: 0.001)
    }

    /// **The control.** The assertion above is only meaningful if a colour
    /// that DOES follow the appearance would fail it — otherwise it would pass
    /// for a palette in which nothing was dynamic at all.
    func testAnOrdinaryThemeColourDoesFollowTheAppearance() {
        let light = rgba(Theme.ink, .light)
        let dark = rgba(Theme.ink, .dark)
        XCTAssertGreaterThan(abs(light.r - dark.r), 0.3,
                             "Theme.ink is dynamic — if this stops being true, the scrim test proves nothing")
    }

    /// Dark enough to carry white text, and against the worst case: a white
    /// wall behind the viewfinder.
    func testTheScrimIsDarkEnoughToCarryWhiteText() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let scrim = rgba(Theme.scrim, style)
            XCTAssertLessThan(scrim.r, 0.2)
            XCTAssertLessThan(scrim.g, 0.2)
            XCTAssertLessThan(scrim.b, 0.2)
            // Composited over pure white, which is what a camera pointed at a
            // white wall gives it. Anything lighter than mid-grey would leave
            // white text on it unreadable.
            let overWhite = scrim.a * scrim.r + (1 - scrim.a) * 1.0
            XCTAssertLessThan(overWhite, 0.5,
                              "over a white wall this must still read as dark")
        }
    }

    /// And it is not opaque — a viewfinder a person cannot see through is not
    /// a viewfinder.
    func testTheScrimStillLetsTheViewfinderThrough() {
        let alpha = rgba(Theme.scrim, .light).a
        XCTAssertGreaterThan(alpha, 0.4, "too faint to carry text")
        XCTAssertLessThan(alpha, 0.85, "too solid to see the camera through")
    }

    /// `onScrim` is fixed for the same reason `scrim` is — a dynamic ink over
    /// a fixed dark scrim is the same defect facing the other way.
    func testTheInkThatGoesOnTheScrimIsAlsoFixed() {
        let light = rgba(Theme.onScrim, .light)
        let dark = rgba(Theme.onScrim, .dark)
        XCTAssertEqual(light.r, dark.r, accuracy: 0.001)
        XCTAssertGreaterThan(light.r, 0.9, "it has to read as white over the scrim")
    }

    /// The defect, pinned where it happened: the old expression is still
    /// available to write, and this says what it would do.
    func testTheOldExpressionWouldHaveBeenWhiteOnWhiteInDarkMode() {
        let ink = rgba(Theme.ink, .dark)
        XCTAssertGreaterThan(ink.r, 0.8,
                             "Theme.ink is near-white on dark — a scrim built from it hides white text")
    }
}
