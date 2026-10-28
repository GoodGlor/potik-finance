import SwiftUI

/// The coloured square that stands for a category. Board #57.
///
/// **Four screens drew this by hand and now none do** — `FeedView`,
/// `TransactionDetailView`, `CategoryPicker` and `CategoriesSettingsView` each
/// had their own `RoundedRectangle(...).fill(Theme.tint(for: name))`. That was
/// survivable while the colour was a pure function of the name; it is not once
/// the colour is a property of the category, because then every one of the
/// four has to know how to ask the store, and the day one of them forgets is
/// the day the same category is two colours in one app.
///
/// The size and corner radius stay per-site: the feed's 40pt tile and the
/// settings list's 24pt chip were drawn to different measurements on purpose,
/// and a single formula would have quietly restyled three screens under cover
/// of a colour change.
///
/// **Board #61 added the icon here and nowhere else**, which is what that
/// consolidation was for: four screens gained a per-category icon in one file.
struct CategorySwatch: View {
    let category: String
    let size: CGFloat
    let cornerRadius: CGFloat
    @Environment(AppStore.self) private var store

    init(_ category: String, size: CGFloat, cornerRadius: CGFloat) {
        self.category = category
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.wash(store.tintIndex(for: category)))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: store.iconName(for: category))
                    // Half the tile, which holds from the settings list's 24pt
                    // chip to the feed's 40pt one. `.medium` rather than
                    // `.regular`: at 12pt a hairline glyph on a mid-tone wash
                    // reads as a smudge however good the contrast ratio is.
                    .font(.system(size: size * 0.5, weight: .medium))
                    // **Fixed ink, not `Theme.ink`.** The washes are one set
                    // for both appearances, so what sits on them must be too —
                    // `Theme.ink` inverts to near-white, and near-white on a
                    // pale wash is not a dark-mode icon, it is a missing one.
                    // `CategoryWashTests` measures every wash at ≥4.5:1
                    // against this exact colour.
                    .foregroundStyle(Theme.swatchInk)
            }
            // One element, not two: a swatch is decoration beside a label that
            // already says the category's name, and VoiceOver reading
            // "Продукти, cart" would be the icon's alt text leaking into a
            // list of Ukrainian category names.
            .accessibilityHidden(true)
    }
}
