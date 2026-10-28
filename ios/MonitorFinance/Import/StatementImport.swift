import Foundation

/// Board #148 — one statement file that was imported, kept so it can be listed
/// and undone.
///
/// Until this existed, `ImportSummary` was handed to the summary screen and
/// thrown away: the app had no record that an import ever happened, so there
/// was nothing to list and nothing to delete.
///
/// ## `created` is the whole design
///
/// It holds the ids of the transactions this statement **brought into being**,
/// never the ones it merely touched — and that distinction is load-bearing,
/// not a nicety. `applyStatement` merges a purchase the notification letters
/// had already delivered into the letter's existing row (`PrivatCrossSource`),
/// and the comment there explains why the letter's row is the one that stays:
/// it may already carry a rule's answer.
///
/// A row like that existed **before** this file and would still exist without
/// it. Undoing the import must leave it alone, or "delete the statement I
/// imported by mistake" quietly deletes history that came from somewhere else.
struct StatementImport: Identifiable, Codable, Hashable {
    var id: UUID
    /// What the person will recognise it by. From the file picker's URL or
    /// the emailed statement's own name.
    var filename: String
    var importedAt: Date
    /// The transactions this file created. See the type's note.
    var created: [UUID]
    /// Rows that were already here and were merged into rather than added.
    /// Reported so the list can say "412 added, 37 already known" instead of
    /// a single number that means neither.
    var merged: Int
    /// The span the file covers, for a list that would otherwise be a column
    /// of identical-looking filenames.
    var from: Date?
    var to: Date?

    init(id: UUID = UUID(), filename: String, importedAt: Date,
         created: [UUID], merged: Int, from: Date?, to: Date?) {
        self.id = id
        self.filename = filename
        self.importedAt = importedAt
        self.created = created
        self.merged = merged
        self.from = from
        self.to = to
    }
}
