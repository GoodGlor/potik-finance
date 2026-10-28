import SwiftUI
import UIKit

/// The palette from the approved mockups. Warm off-white ground, clay for money
/// owed, green for anything the user can act on — never both on one control.
///
/// **Both schemes, board #58.** Every colour below is a DYNAMIC `Color`: it
/// resolves against whichever appearance is in force when it is drawn, so the
/// several hundred `Theme.ink` / `Theme.card` call sites across the app did
/// not change and cannot fall out of step. The alternative — reading
/// `@Environment(\.colorScheme)` at each site — would have been the same
/// decision written down several hundred times, with the compiler unable to
/// notice the one screen that forgot.
///
/// The dark ground is warm too. A neutral grey beside this app's clay and
/// green reads cold and slightly wrong, and the mockups' whole register is
/// warmth; the dark scheme keeps it rather than starting a second visual
/// language.
enum Theme {

    /// One colour, two values, resolved at draw time.
    ///
    /// `UIColor`'s trait-based initialiser rather than an asset catalogue: the
    /// palette is source, reviewed in diffs and measured by
    /// `StatsColourTests`, and a colour set in an `.xcassets` is none of those
    /// things.
    static func dynamic(light: (Double, Double, Double),
                        dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    static let bg = dynamic(light: (0.968, 0.961, 0.945), dark: (0.086, 0.082, 0.078))
    static let card = dynamic(light: (1, 1, 1), dark: (0.145, 0.141, 0.133))
    static let ink = dynamic(light: (0.204, 0.192, 0.169), dark: (0.949, 0.941, 0.925))
    static let inkSoft = dynamic(light: (0.435, 0.412, 0.376), dark: (0.741, 0.725, 0.702))
    static let inkMuted = dynamic(light: (0.573, 0.549, 0.510), dark: (0.612, 0.596, 0.569))
    static let clay = dynamic(light: (0.729, 0.208, 0.196), dark: (0.925, 0.400, 0.376))
    static let clayLight = dynamic(light: (0.855, 0.451, 0.400), dark: (0.965, 0.600, 0.549))
    static let green = dynamic(light: (0.204, 0.545, 0.443), dark: (0.325, 0.769, 0.635))
    static let greenWash = dynamic(light: (0.898, 0.945, 0.925), dark: (0.114, 0.259, 0.216))
    static let hair = dynamic(light: (0.914, 0.902, 0.878), dark: (0.255, 0.247, 0.235))

    /// **Behind text that sits over a CAMERA FEED. Board #102.**
    ///
    /// Fixed, not dynamic, and that is the whole point. Every other colour here
    /// answers "what appearance is the phone in"; this one sits over live video,
    /// which has no appearance — a bright kitchen and a dark pocket both happen
    /// in light mode. `Theme.ink` was being used for this, and `ink` is
    /// near-WHITE in dark appearance, so the scanner's error line was white
    /// text on a white scrim for anybody using the app in dark mode. Nothing on
    /// screen says that happened; the words are simply gone.
    ///
    /// Dark enough to carry white text against a white wall, at an opacity that
    /// still lets the viewfinder through.
    static let scrim = Color(uiColor: UIColor(white: 0, alpha: 0.62))

    /// The text colour that goes ON `scrim`, and the reason it is here rather
    /// than a bare `.white` at the call site: the pair has to stay a pair.
    /// A dynamic ink over a fixed dark scrim is the same defect in the other
    /// direction — dark text on dark video in light appearance — so naming
    /// both halves keeps the guard from having to exempt a whole file.
    static let onScrim = Color(uiColor: UIColor(white: 1, alpha: 1))

    /// **`ink` is never a SURFACE.** Board #182: the undo toast was drawn on
    /// it, which put a text colour under text — near-white under a fixed
    /// `.white` in dark appearance, a measured 1.14:1, and a toast nobody
    /// could read on a dark phone. The toast now takes `card` and `ink` like
    /// every other surface in the app; `onInk`, the token that briefly existed
    /// to make the inverted pill legible, went with it.
    ///
    /// A card is told apart from the ground by being LIGHTER in both schemes,
    /// so the shadow is a refinement rather than the thing doing the work.
    /// It still has to be much heavier on dark: a 5% black shadow over a 0.086
    /// ground is invisible, which is not a failure anybody would see — the
    /// card would simply look flat.
    /// Carries its own alpha, so it stays a dynamic colour rather than a
    /// number read out of `UITraitCollection.current` — that is not observed
    /// by SwiftUI and would keep whatever value it had when the view was first
    /// built, right through a change of appearance.
    static let cardShadow = Color(uiColor: UIColor { traits in
        UIColor(white: 0, alpha: traits.userInterfaceStyle == .dark ? 0.45 : 0.05)
    })

    /// Rounded system font throughout — the friendly register the mockups settled on.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// **Twenty washes, one per category, and no two alike. Board #57.**
    ///
    /// The count is the seeded nineteen plus one, and the whole palette was
    /// re-measured to reach it. The previous twelve could not simply be
    /// extended: their closest pair sat **0.051 apart in RGB** (the two blues,
    /// old slots 4 and 10; the two ambers, 3 and 9, at 0.054), so appending
    /// eight more pastels would have satisfied "two categories cannot share a
    /// colour" on paper while leaving them a smudge — exactly the complaint
    /// board #12 raised about the set before that one. **The floor is now
    /// 0.194**, measured over all 190 pairs by `CategoryWashTests`.
    ///
    /// **They are also chosen for colourblind readers, and that cost real
    /// separation.** Optimised for ordinary vision alone, twenty colours in
    /// this band reach 0.235 — and collapse to **0.019 under deuteranopia**,
    /// which is to say two of them become the same colour. Optimising for the
    /// worst of ordinary, deuteranopic and protanopic vision at once gives up
    /// 0.235 → 0.194 for ordinary sight and buys 0.019 → 0.096 for a red-green
    /// colourblind one. That is the trade this array encodes, and every one of
    /// those numbers is asserted rather than claimed.
    ///
    /// **0.096 is still not "distinguishable", and that is the honest limit.**
    /// Twenty colours a colourblind reader can tell apart do not exist in any
    /// palette; their vision is roughly two-dimensional and twenty points will
    /// not fit. Colour narrows the field here — it does not name the category.
    /// **What names it is board #61's icon**, drawn on this very swatch. The
    /// two cards are one design, and this comment is why.
    ///
    /// Constraints held by every member, all measured in `CategoryWashTests`:
    /// at least 4.5:1 against the icon ink drawn on top, at least 1.2:1
    /// against the white card so the swatch is visible at all, at least 3:1
    /// against the dark card, and saturation and lightness inside the band the
    /// mockups' warm register uses — the unconstrained optimum was neon.
    ///
    /// **One set for both appearances (board #58), and the reason is what
    /// they are used for.** Every call site is a `.fill()` on a 24–40pt shape:
    /// `FeedView`, `TransactionDetailView`, `CategoryPicker`,
    /// `CategoriesSettingsView`, and no others. A dark counterpart would be
    /// twenty more colours to keep apart, in three kinds of vision, for no
    /// gain — the light set already clears 4.69:1 against the dark card.
    /// **The ORDER is as measured as the colours, and it was bought with a
    /// screenshot.** Washes are handed out in alphabetical order of category
    /// name (see `AppStore.assigningMissingTintIndexes`), and Налаштування →
    /// Категорії lists them alphabetically too — so consecutive entries in
    /// this array are the swatches that sit one above the other on that
    /// screen. Sorted by hue, which is how it was first written, the list read
    /// as a smooth gradient: terracotta, apricot, sand, ochre, straw, lime.
    /// Every pair was 0.194 apart as promised, and every pair a person could
    /// actually compare was the closest pair in the palette.
    ///
    /// Reordered so that touching swatches are far apart, adjacent separation
    /// is **0.483** — two and a half times the all-pairs floor — and 0.252
    /// under deuteranopia. This is the same lesson `rankColours` records for
    /// the donut, learned again one screen over.
    static let washes: [Color] = [
        Color(red: 0.86, green: 0.33, blue: 0.88),   // orchid
        Color(red: 0.91, green: 0.66, blue: 0.51),   // apricot
        Color(red: 0.37, green: 0.83, blue: 0.70),   // jade
        Color(red: 0.91, green: 0.87, blue: 0.49),   // straw
        Color(red: 0.70, green: 0.53, blue: 0.81),   // violet
        Color(red: 0.87, green: 0.69, blue: 0.30),   // ochre
        Color(red: 0.59, green: 0.77, blue: 0.87),   // pale sky
        Color(red: 0.65, green: 0.84, blue: 0.35),   // lime
        Color(red: 0.77, green: 0.67, blue: 0.93),   // lilac
        Color(red: 0.41, green: 0.84, blue: 0.51),   // grass
        Color(red: 0.83, green: 0.65, blue: 0.70),   // dusty rose
        Color(red: 0.34, green: 0.69, blue: 0.84),   // sky
        Color(red: 0.78, green: 0.94, blue: 0.67),   // pale leaf
        Color(red: 0.85, green: 0.47, blue: 0.34),   // terracotta
        Color(red: 0.71, green: 0.94, blue: 0.94),   // ice
        Color(red: 0.71, green: 0.50, blue: 0.51),   // clay rose
        Color(red: 0.96, green: 0.87, blue: 0.76),   // sand
        Color(red: 0.50, green: 0.55, blue: 0.71),   // slate blue
        Color(red: 0.94, green: 0.80, blue: 0.95),   // pale orchid
        Color(red: 0.62, green: 0.76, blue: 0.59),   // sage
    ]

    /// The ink drawn ON a wash — a category's icon, board #61.
    ///
    /// **Fixed, and not `Theme.ink`.** The washes are one set for both
    /// appearances, so what sits on top must be too: `Theme.ink` inverts to
    /// near-white in the dark scheme, and near-white on a pale wash is not a
    /// dark-mode icon, it is a missing one. Every wash carries this at 4.5:1
    /// or better and `CategoryWashTests` measures it — that constraint is
    /// half of why the palette is the palette.
    static let swatchInk = Color(red: 0.16, green: 0.15, blue: 0.14)

    /// `index` folded into the palette, wrapping rather than trapping.
    ///
    /// Wrapping matters: `Category.tintIndex` is a number in a file a person
    /// can edit, restore from another device, or carry forward from a build
    /// with more washes than this one. A crash is not the right answer to a
    /// stale number in a settings file, and neither is a blank swatch.
    ///
    /// The double modulo is for negatives: Swift's `%` keeps the sign, so a
    /// hand-edited `-1` would index out of bounds on the very line meant to
    /// prevent that.
    static func washIndex(_ index: Int) -> Int {
        ((index % washes.count) + washes.count) % washes.count
    }

    /// The colour of the wash at `index`. See `washIndex`.
    static func wash(_ index: Int) -> Color { washes[washIndex(index)] }

    /// The colour for a category the store has never heard of — a row naming a
    /// category that no longer exists, which import and restore can both
    /// produce.
    ///
    /// djb2 over unicode scalars, deliberately NOT `hashValue`, which Swift
    /// seeds per process: the same unknown name would otherwise be a different
    /// colour on the feed and in the picker within one session.
    ///
    /// **This is the fallback and not the mechanism.** Every category the store
    /// knows carries its own `tintIndex`, so nothing that has a colour of its
    /// own is coloured by a hash — which is what board #57 was about. Before
    /// it, this function coloured everything, and nineteen names into twelve
    /// slots collided by arithmetic.
    static func fallbackIndex(for category: String) -> Int {
        var hash: UInt64 = 5381
        for scalar in category.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        return Int(hash % UInt64(washes.count))
    }

    /// Eight colours for the donut's eight slices, keyed by RANK rather than
    /// by name. Board #24.
    ///
    /// `washes` hashed a name into twelve pastels when this card was written,
    /// and nineteen categories into twelve slots meant collisions — «Кредит»
    /// and «Квартплата» landed on the same one — so two adjacent arcs could be
    /// the same colour and the legend, keyed by the same hash, repeated the
    /// ambiguity instead of resolving it. Rank has no collisions by
    /// construction: the donut draws eight slices and there are eight colours.
    ///
    /// **Board #57 removed those collisions, and this array still stands.**
    /// The washes are now one per category and distinct, so the original
    /// argument no longer applies — but the second one always did and is the
    /// real one: here the question is "which slice is which", and its answer
    /// is positional. A donut coloured by category identity puts whichever two
    /// categories happen to be adjacent side by side with no guarantee about
    /// the pair, and the eight rank colours are chosen so that touching arcs
    /// are the ones furthest apart. `StatsColourTests` pins that the two
    /// functions stay different things.
    ///
    /// Deeper than `washes` on purpose. A wash carries a 4.5:1 icon on top and
    /// has to stay light; these carry a 34pt stroke and a 22pt legend swatch
    /// and nothing else, so they can hold real saturation.
    ///
    /// Ordered so that the pairs that touch are the ones furthest apart. The
    /// numbers are measured, not asserted by eye — `StatsColourTests` holds
    /// them: no two of the eight are closer than 0.25 in RGB distance, and no
    /// two ADJACENT ones closer than 0.34. Where hue alone would be thin for a
    /// red-green colourblind reader, lightness or the blue channel carries the
    /// difference instead.
    ///
    /// **`tint(for:)` is untouched.** The feed, the budget and the category
    /// screens key colour to a category so that «Продукти» is the same colour
    /// everywhere; here the question is "which slice is which", and the
    /// answer is positional.
    ///
    /// **A second set for dark (board #58), and it had to be measured.** The
    /// light eight were chosen against white card stock, where separation was
    /// the only criterion — the amber sits at 1.88:1 against white and always
    /// has, because a 34pt arc is not text. Against the dark card three of
    /// them go the other way and genuinely disappear: **the indigo lands at
    /// 2.04:1**, and a slice a person cannot see is not a slice.
    ///
    /// The dark eight keep the hues and raise the lightness, and the same two
    /// separation floors are held for BOTH arrays — 0.25 for any pair, 0.34
    /// for touching ones. The dark set is in fact further apart than the light
    /// one (0.30 / 0.38 against 0.25 / 0.35) and no member falls below 4.6:1
    /// on its ground. `StatsColourTests` measures every one of those numbers
    /// in both appearances; none of it is asserted by eye.
    static let rankLight: [(Double, Double, Double)] = [
        (0.13, 0.51, 0.42),   // deep teal — the brand green, darkened
        (0.25, 0.29, 0.66),   // indigo
        (0.85, 0.36, 0.32),   // coral
        (0.94, 0.70, 0.24),   // amber
        (0.29, 0.63, 0.85),   // sky
        (0.58, 0.33, 0.63),   // plum
        (0.52, 0.61, 0.24),   // olive
        (0.55, 0.58, 0.62),   // slate, for the smallest
    ]

    static let rankDark: [(Double, Double, Double)] = [
        (0.20, 0.75, 0.57),   // teal, lifted off the dark ground
        (0.53, 0.52, 0.99),   // indigo — 2.04:1 on dark before this, now 5.01
        (0.87, 0.40, 0.43),   // coral
        (1.00, 0.70, 0.22),   // amber
        (0.28, 0.62, 0.83),   // sky
        (0.77, 0.50, 0.80),   // plum
        (0.49, 0.66, 0.24),   // olive
        (0.55, 0.59, 0.61),   // slate, for the smallest
    ]

    static let rankColours: [Color] = zip(rankLight, rankDark).map {
        dynamic(light: $0, dark: $1)
    }

    /// The colour of the n-th largest slice. Wraps rather than trapping: the
    /// donut and the legend both stop at eight today, and a caller that one
    /// day draws nine should get a repeat, not a crash.
    static func rank(_ index: Int) -> Color { rankColours[index % rankColours.count] }
}

extension Appearance {
    /// nil hands the decision back to the system — which is exactly what
    /// `preferredColorScheme` means by nil, so `.system` needs no special case
    /// at the call site.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: "Як у системі"
        case .light: "Світла"
        case .dark: "Темна"
        }
    }

    /// The same choice for a UIKit window. `LockWindow` is a second
    /// `UIWindow`, and `preferredColorScheme` reaches only the one SwiftUI
    /// owns — `.unspecified` is UIKit's word for the nil this maps from.
    var uiStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// One card. Every screen is a stack of these, nothing else.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Theme.cardShadow, radius: 12, y: 4)
    }
}

/// The one green button. There is never more than one per screen.
struct PrimaryButton: View {
    /// `LocalizedStringKey`, not `String` — board #85. Every caller passes
    /// a literal, and a `String` parameter takes SwiftUI's non-localising
    /// `Text` overload, which left «Розібрати за хвилину» in Ukrainian on an
    /// otherwise English screen. The type is what carries the localisation.
    let title: LocalizedStringKey
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(17, .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Theme.green, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

extension Int {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// Board #85. The separators follow the interface language, which is the
    /// owner's decision: "1,240.50 ₴" in English, «1 240,50 ₴» in Ukrainian.
    ///
    /// **Spelt out rather than taken from `Locale`.** The Ukrainian pair is
    /// the one this app has always drawn and several tests measure it to the
    /// code point — a locale's own idea of a grouping separator is a
    /// narrow no-break space on some systems and an ordinary one on others,
    /// and the difference is invisible until a test compares strings.
    /// `.resolved`, not a bare `== .en`. `L10n.formatting` is `.system` until
    /// `AppStore.init` sets it, and `MonthKey.title` resolves the same value
    /// through `.locale` — so comparing the raw case here made a date English
    /// and the amount beside it Ukrainian on an English phone, for the length
    /// of one launch. Both sides resolve, or neither.
    private static func separated() -> NumberFormatter {
        let f = formatter
        let english = L10n.formatting.resolved == .en
        f.groupingSeparator = english ? "," : " "
        f.decimalSeparator = english ? "." : ","
        return f
    }

    /// Minor units as whole hryvnia — headline and summary figures. Rounds
    /// rather than truncates: 12 345,67 belongs to the 12 346 the advice text
    /// quotes, and a screen that shows both must not disagree with itself.
    var uah: String {
        let formatter = Int.separated()
        formatter.maximumFractionDigits = 0
        let value = (Double(abs(self)) / 100).rounded()
        return (formatter.string(from: NSNumber(value: value)) ?? "0") + " ₴"
    }

    /// Minor units to the kopeck — transaction rows, where the exact figure is
    /// the thing being reconciled against the bank.
    var uahExact: String {
        let formatter = Int.separated()
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        defer { formatter.minimumFractionDigits = 0 }
        return (formatter.string(from: NSNumber(value: Double(abs(self)) / 100)) ?? "0") + " ₴"
    }

    /// `uahExact` with the direction in front of it. Every transaction row on
    /// every screen shows the same signed figure, and three screens had each
    /// respelled `(amount > 0 ? "+" : "−") + amount.uahExact` locally — the
    /// fourth screen to be written would have spelled it a fourth time, and
    /// one already shipped with a hyphen-minus and needed a fix commit. The
    /// sign is U+2212 MINUS SIGN, not a hyphen: it is the width of a digit,
    /// so a column of amounts stays aligned.
    var signedUahExact: String { (self > 0 ? "+" : "−") + uahExact }
}
