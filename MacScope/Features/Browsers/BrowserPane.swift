import Foundation

/// The three browser panes — Imports/Exports/Sections — surfaced together in one
/// segmented panel. Pure, GUI-free, so the
/// notification command layer and the SwiftUI segmented picker share one source of
/// truth and the default/labels stay testable.
enum BrowserPane: String, CaseIterable, Identifiable, Equatable {
    case imports
    case exports
    case sections

    var id: String { rawValue }

    /// The segmented-control / window title for the pane.
    var displayName: String {
        switch self {
        case .imports: return "Imports"
        case .exports: return "Exports"
        case .sections: return "Sections"
        }
    }

    /// SF Symbol shown beside the pane in the segmented control.
    var systemImage: String {
        switch self {
        case .imports: return "arrow.down.circle"
        case .exports: return "arrow.up.circle"
        case .sections: return "square.split.2x2"
        }
    }
}

/// Pure mapping from a browser row's optional address to a navigable target.
///
/// Imports never navigate (they name an external symbol resolved at load time, with
/// no in-image address). Exports and sections navigate when — and only when — they
/// carry a concrete virtual address: a forwarder export or an ordinal-only entry has
/// `address == nil` and is therefore inert, never selecting `0x0` by accident. Kept
/// GUI-free so the row→navigation decision is unit-tested without a live store.
enum BrowserNavigationTarget {
    /// The address an export row navigates to, or nil when it has none (forwarders,
    /// ordinal-only exports).
    static func address(forExport row: ExportBrowserRow) -> UInt64? {
        row.address
    }

    /// The address a section row navigates to. Sections always have a start address,
    /// so this is always navigable.
    static func address(forSection row: SectionBrowserRow) -> UInt64 {
        row.address
    }

    /// True when the export row resolves to a selectable address.
    static func isNavigable(_ row: ExportBrowserRow) -> Bool {
        row.address != nil
    }
}
