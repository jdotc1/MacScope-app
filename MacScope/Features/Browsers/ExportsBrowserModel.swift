import Foundation

/// The sort orderings offered by the Exports browser.
enum ExportsBrowserSort: String, CaseIterable, Identifiable, Equatable {
    /// Alphabetical by symbol name (case-insensitive), the default ordering.
    case name
    /// By export virtual address (address-less exports — forwarders / ordinal-only
    /// entries — sort last).
    case address

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name: return "Name"
        case .address: return "Address"
        }
    }
}

/// One presentation row in the Exports browser: the exported symbol with its
/// address (or a forwarder/ordinal-only marker) pre-rendered for display.
struct ExportBrowserRow: Identifiable, Equatable {
    let id: UUID
    /// The exported symbol name. A nameless export (PE keeps these as a `#<ordinal>`
    /// label upstream, so this fallback is only a defensive guard) shows a stable
    /// placeholder rather than a blank cell.
    let name: String
    /// The export's virtual address rendered as hex, or "—" when it has none
    /// (a forwarder, or an ordinal-only export).
    let addressText: String
    /// The export's provenance string verbatim (e.g. "exports trie", "forwarder").
    let source: String
    /// True when this export forwards to another module rather than resolving to a
    /// local address. Drives the view's badge and is matched by the filter word.
    let isForwarder: Bool
    /// The raw address kept for address-sort; nil when the export carries none.
    let address: UInt64?
}

/// Pure, GUI-free projection of a snapshot's `exports` into a sortable,
/// text-filterable list. Forwarder exports (`source == "forwarder"`) are flagged so
/// the view can badge them, and ordinal-only exports (no usable name) get a
/// synthesised label.
///
/// Filtering is a case-insensitive substring test over the name, the source, AND
/// the rendered address, so typing "forwarder" isolates forwarders and typing a hex
/// fragment isolates an address.
struct ExportsBrowserModel: Equatable {
    /// The address display string for an export with no resolvable address.
    static let noAddressPlaceholder = "—"
    /// The `ExportSummary.source` value marking a re-export/forwarder.
    static let forwarderSource = "forwarder"
    /// The display label for a nameless export (defensive — PE labels these `#N`).
    static let unnamedPlaceholder = "(unnamed)"

    let rows: [ExportBrowserRow]

    init(exports: [ExportSummary], sort: ExportsBrowserSort = .name, filter: String = "") {
        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let projected = exports.map { summary -> ExportBrowserRow in
            let isForwarder = summary.source.lowercased() == Self.forwarderSource
            let name = summary.name.isEmpty ? Self.unnamedPlaceholder : summary.name
            return ExportBrowserRow(
                id: summary.id,
                name: name,
                addressText: summary.address?.hexAddress ?? Self.noAddressPlaceholder,
                source: summary.source,
                isForwarder: isForwarder,
                address: summary.address
            )
        }

        let filtered = trimmedFilter.isEmpty
            ? projected
            : projected.filter { row in
                row.name.lowercased().contains(trimmedFilter)
                    || row.source.lowercased().contains(trimmedFilter)
                    || row.addressText.lowercased().contains(trimmedFilter)
            }

        self.rows = Self.sorted(filtered, by: sort)
    }

    var isEmpty: Bool { rows.isEmpty }

    private static func sorted(_ rows: [ExportBrowserRow], by sort: ExportsBrowserSort) -> [ExportBrowserRow] {
        rows.sorted { lhs, rhs in
            switch sort {
            case .name:
                return byNameThenID(lhs, rhs)
            case .address:
                switch (lhs.address, rhs.address) {
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

    private static func byNameThenID(_ lhs: ExportBrowserRow, _ rhs: ExportBrowserRow) -> Bool {
        if lhs.name.lowercased() != rhs.name.lowercased() {
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
