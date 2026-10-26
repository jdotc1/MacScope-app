import Foundation

/// The sort orderings offered by the Imports browser. Each maps to a deterministic,
/// total comparator in `ImportsBrowserModel` so the list never depends on the
/// snapshot's incoming order.
enum ImportsBrowserSort: String, CaseIterable, Identifiable, Equatable {
    /// Alphabetical by symbol name (case-insensitive), the default ordering.
    case name
    /// Grouped by the owning library, then by name within each library.
    case library
    /// By the dynamic-linker library ordinal (imports with no ordinal sort last).
    case ordinal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name: return "Name"
        case .library: return "Library"
        case .ordinal: return "Ordinal"
        }
    }
}

/// One presentation row in the Imports browser: the imported symbol plus its
/// resolved library and ordinal, each pre-rendered for direct display so the
/// SwiftUI view stays a dumb list.
struct ImportBrowserRow: Identifiable, Equatable {
    let id: UUID
    /// The imported symbol name (e.g. `_printf`).
    let name: String
    /// The owning dynamic library, or "—" when the import is library-agnostic.
    let library: String
    /// The library ordinal rendered for display, or "—" when none is recorded.
    let ordinalText: String
    /// The raw ordinal kept for ordinal-sort; nil when the import carries none.
    let ordinal: Int?
}

/// Pure, GUI-free projection of a snapshot's `imports` into a sortable,
/// text-filterable list. All ordering and matching lives here so the view is a
/// thin `ForEach`; mirrors the `…Reading` structs in the Inspector.
///
/// Filtering is a case-insensitive substring test over the symbol name AND the
/// library name, so typing either narrows the list. Sorting is always total: the
/// symbol name (then the stable `id`) is the final tie-breaker under every key, so
/// rows never reorder unpredictably between renders.
struct ImportsBrowserModel: Equatable {
    /// The library display string for an import that records no library.
    static let noLibraryPlaceholder = "—"

    let rows: [ImportBrowserRow]

    init(imports: [ImportSummary], sort: ImportsBrowserSort = .name, filter: String = "") {
        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let projected = imports.map { summary -> ImportBrowserRow in
            let library = summary.libraryName?.isEmpty == false
                ? summary.libraryName!
                : Self.noLibraryPlaceholder
            let ordinalText = summary.libraryOrdinal.map(String.init) ?? Self.noLibraryPlaceholder
            return ImportBrowserRow(
                id: summary.id,
                name: summary.name,
                library: library,
                ordinalText: ordinalText,
                ordinal: summary.libraryOrdinal
            )
        }

        let filtered = trimmedFilter.isEmpty
            ? projected
            : projected.filter { row in
                row.name.lowercased().contains(trimmedFilter)
                    || row.library.lowercased().contains(trimmedFilter)
            }

        self.rows = Self.sorted(filtered, by: sort)
    }

    /// True when there are no rows to show (empty snapshot or filtered to nothing).
    var isEmpty: Bool { rows.isEmpty }

    private static func sorted(_ rows: [ImportBrowserRow], by sort: ImportsBrowserSort) -> [ImportBrowserRow] {
        rows.sorted { lhs, rhs in
            switch sort {
            case .name:
                return byNameThenID(lhs, rhs)
            case .library:
                if lhs.library.lowercased() != rhs.library.lowercased() {
                    return lhs.library.lowercased() < rhs.library.lowercased()
                }
                return byNameThenID(lhs, rhs)
            case .ordinal:
                // Imports without an ordinal sort after those with one.
                switch (lhs.ordinal, rhs.ordinal) {
                case let (l?, r?) where l != r:
                    return l < r
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    return byNameThenID(lhs, rhs)
                }
            }
        }
    }

    private static func byNameThenID(_ lhs: ImportBrowserRow, _ rhs: ImportBrowserRow) -> Bool {
        if lhs.name.lowercased() != rhs.name.lowercased() {
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
