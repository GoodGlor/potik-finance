import Foundation

/// The icons a category can wear. Board #61.
///
/// **SF Symbols, not an asset catalogue.** They come in every weight and
/// scale, they are already what the rest of this app draws, and they cost no
/// bytes. The price is that a misspelt name renders as *nothing* — silently, a
/// blank swatch — so `CategoryIconTests` asks UIKit whether every single name
/// below actually resolves. That test is the only thing standing between a
/// typo here and an invisible icon on someone's phone.
///
/// **A curated set rather than the whole library.** The card asked for "a set
/// the app offers", and a person choosing an icon for «Продукти» wants a short
/// list of things a category can be, not five thousand glyphs with a search
/// field. Grouped, because thirty-six in one undifferentiated grid is the same
/// problem in a smaller form.
enum CategoryIcon {

    /// A category the app has no opinion about — every user-created one until
    /// somebody chooses. A generic label, which is honestly what it is; it is
    /// not in `offered` as a separate choice because "no icon" is a state, not
    /// a selection.
    static let fallback = "tag"

    struct Group: Identifiable, Hashable {
        let title: String
        let icons: [String]
        var id: String { title }
    }

    /// Ordered by how often a category needs one, not alphabetically: this
    /// list is browsed, and the first screenful should hold the answers.
    static let groups: [Group] = [
        Group(title: "Щодня", icons: [
            "cart", "fork.knife", "cup.and.saucer", "bag", "creditcard", "banknote",
        ]),
        Group(title: "Дорога", icons: [
            "car", "bus", "tram", "airplane", "fuelpump", "bicycle",
        ]),
        Group(title: "Дім", icons: [
            "house", "hammer", "bolt", "drop", "wifi", "key",
        ]),
        Group(title: "Життя", icons: [
            "heart", "cross.case", "pills", "pawprint", "gift", "figure.walk",
        ]),
        Group(title: "Дозвілля", icons: [
            "gamecontroller", "film", "music.note", "book", "ticket", "wineglass",
        ]),
        Group(title: "Робота й гроші", icons: [
            "briefcase", "graduationcap", "wrench.and.screwdriver", "lock",
            "arrow.down.left", "tag",
        ]),
    ]

    /// Every offered icon, flat. The chooser draws `groups`; everything that
    /// only needs membership reads this.
    static let offered: [String] = groups.flatMap(\.icons)
}
