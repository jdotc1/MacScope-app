import Foundation

/// The sort orderings offered by the Sections browser.
enum SectionsBrowserSort: String, CaseIterable, Identifiable, Equatable {
    /// By virtual address — the natural memory-layout order and the default.
    case address
    /// Alphabetical by section name (case-insensitive).
    case name
    /// By byte size, largest first, so the heaviest sections surface at the top.
    case size

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .address: return "Address"
        case .name: return "Name"
        case .size: return "Size"
        }
    }
}

/// One presentation row in the Sections browser: a loaded segment/section with its
/// address, size, file offset, and executable/zero-fill flags pre-rendered.
struct SectionBrowserRow: Identifiable, Equatable {
    let id: UUID
    /// The section name (e.g. `__TEXT,__text`).
    let name: String
    /// The section's start virtual address rendered as hex.
    let addressText: String
    /// The section's byte size rendered as hex (e.g. `0x1f40`).
    let sizeText: String
    /// The section's file offset rendered as hex, or a marker for zero-fill sections
    /// (which occupy VA space but have no backing file bytes).
    let fileOffsetText: String
    /// True when the section holds executable code (drives the view's icon/tone).
    let isExecutable: Bool
    /// True when the section is BSS-type (zero-fill, no file bytes).
    let isZeroFill: Bool
    /// The raw address kept for address-sort.
    let address: UInt64
    /// The raw size kept for size-sort.
    let size: UInt64
}

/// Pure, GUI-free projection of a snapshot's `sections` into a sortable,
/// text-filterable list. Zero-fill (BSS) sections are kept and flagged so the view
/// can mark that their `fileOffset` is a placeholder rather than a real file slot.
///
/// Filtering is a case-insensitive substring test over the section name AND its
/// rendered address, so typing "text" isolates the text sections and typing a hex
/// fragment isolates an address.
struct SectionsBrowserModel: Equatable {
    /// The file-offset display string for a zero-fill section (no backing bytes).
    static let zeroFillOffsetPlaceholder = "— (zero-fill)"

    let rows: [SectionBrowserRow]

    init(sections: [SectionSummary], sort: SectionsBrowserSort = .address, filter: String = "") {
        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let projected = sections.map { summary -> SectionBrowserRow in
            SectionBrowserRow(
                id: summary.id,
                name: summary.name,
                addressText: summary.address.hexAddress,
                sizeText: Self.hexSize(summary.size),
                fileOffsetText: summary.isZeroFill
                    ? Self.zeroFillOffsetPlaceholder
                    : Self.hexSize(summary.fileOffset),
                isExecutable: summary.isExecutable,
                isZeroFill: summary.isZeroFill,
                address: summary.address,
                size: summary.size
            )
        }

        let filtered = trimmedFilter.isEmpty
            ? projected
            : projected.filter { row in
                row.name.lowercased().contains(trimmedFilter)
                    || row.addressText.lowercased().contains(trimmedFilter)
            }

        self.rows = Self.sorted(filtered, by: sort)
    }

    var isEmpty: Bool { rows.isEmpty }

    /// Renders a byte count as a compact `0x…` hex string (no fixed-width padding,
    /// unlike a virtual address) so sizes read naturally in the list.
    private static func hexSize(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16, uppercase: false)
    }

    private static func sorted(_ rows: [SectionBrowserRow], by sort: SectionsBrowserSort) -> [SectionBrowserRow] {
        rows.sorted { lhs, rhs in
            switch sort {
            case .address:
                if lhs.address != rhs.address { return lhs.address < rhs.address }
                return byNameThenID(lhs, rhs)
            case .name:
                return byNameThenID(lhs, rhs)
            case .size:
                if lhs.size != rhs.size { return lhs.size > rhs.size }
                return byNameThenID(lhs, rhs)
            }
        }
    }

    private static func byNameThenID(_ lhs: SectionBrowserRow, _ rhs: SectionBrowserRow) -> Bool {
        if lhs.name.lowercased() != rhs.name.lowercased() {
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
