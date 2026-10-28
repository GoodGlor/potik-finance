import Foundation

/// Every way an import can be refused, each with the one sentence the
/// screen shows. The file never touches persistence unless parsing
/// succeeded in full, so every case is a clean stop.
enum PrivatImportError: Error, Equatable {
    case cantReadFile
    case notAnXLSX
    case notAPrivatStatement
    case badRow(Int)
    case emptyStatement

    var userMessage: String {
        switch self {
        case .cantReadFile:
            return "Не вдалося прочитати файл. Спробуйте вибрати його ще раз."
        case .notAnXLSX:
            return "Це не файл Excel (.xlsx). Збережіть виписку з Приват24 і виберіть її."
        case .notAPrivatStatement:
            return "Файл не схожий на виписку ПриватБанку — таблиці «Історія операцій» не знайдено."
        case .badRow(let line):
            // The only case carrying a number, so the only one that cannot be
            // a plain catalogue key looked up at the `Text`. Translated here,
            // the way `Derived` and `BudgetMath` translate what they assemble.
            return String(format: L10n.t("Рядок %lld виписки не вдалося розібрати. Спробуйте зберегти файл ще раз.",
                                         L10n.formatting), line)
        case .emptyStatement:
            return "У виписці немає жодної операції."
        }
    }
}
