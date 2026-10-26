import SwiftUI
import LumenTokens
import LumenUI

/// Hosts the Imports / Exports / Sections browsers in one segmented panel — three
/// distinct browsers collapsed into a single sheet. The segmented
/// control switches panes; each pane is a dumb `ForEach` driven entirely by its pure
/// view-model (`ImportsBrowserModel` / `ExportsBrowserModel` / `SectionsBrowserModel`),
/// so no sort/filter logic lives in the view.
struct BrowsersSheet: View {
    @ObservedObject var store: WorkspaceStore

    /// U10-5 (L2, Lumen Tier 2e): a browse-only Lumen sheet (one "Done", Return or Esc), the
    /// pane switcher as Lumen pills at the top of its content.
    var body: some View {
        LumenSheet(
            "Imports, Exports & Sections",
            subtitle: store.focusedBinary?.name,
            systemImage: "tablecells",
            done: LumenBarAction("Done") { store.showBrowsers = false }
        ) {
            LumenModeSwitcher(selection: $store.browserSelection, options: BrowserPane.allCases, style: .pill,
                              title: { $0.displayName })
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Browser pane")

            Group {
                switch store.browserSelection {
                case .imports:
                    ImportsBrowserView(store: store)
                case .exports:
                    ExportsBrowserView(store: store)
                case .sections:
                    SectionsBrowserView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(store.browserSelection.displayName) browser")
    }
}

// MARK: - Shared chrome

/// The sort picker + filter field strip shared by all three browser views. The
/// caller binds a pane-specific sort and the common filter text.
private struct BrowserToolbar<Sort: CaseIterable & Identifiable & Hashable>: View {
    let title: String
    @Binding var sort: Sort
    @Binding var filter: String
    let sortLabel: (Sort) -> String

    var body: some View {
        HStack(spacing: Lumen.Space.s5) {
            // U10-5 (L2): the sort order on a Lumen pop-up, not a system Picker.
            LumenPopUp(selection: $sort, options: Array(Sort.allCases), title: sortLabel)
                .accessibilityLabel("Sort \(title.lowercased())")

            HStack(spacing: Lumen.Space.s4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("Filter \(title.lowercased())", text: $filter)
                    .textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, Lumen.Space.s4)
            .frame(height: 22)
            .compactControlBackground()
        }
        .padding(.horizontal, Lumen.Space.s6)
        .padding(.vertical, Lumen.Space.s5)
    }
}

/// An empty-state line shown when a browser has no rows (empty snapshot or a filter
/// that matched nothing).
private struct BrowserEmptyState: View {
    let message: String

    var body: some View {
        VStack {
            Spacer()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Lumen.Space.s7)
    }
}

/// A small capitalized capsule badge (e.g. "forwarder", "exec", "bss").
private struct BrowserBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        LumenTag(text, color: tint)
            .accessibilityHidden(true)
    }
}

// MARK: - Imports

struct ImportsBrowserView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var sort: ImportsBrowserSort = .name
    @State private var filter = ""
    @State private var selection: ImportBrowserRow.ID?

    private var model: ImportsBrowserModel {
        ImportsBrowserModel(imports: store.focusedAnalysis?.imports ?? [], sort: sort, filter: filter)
    }

    var body: some View {
        let model = model
        VStack(spacing: 0) {
            BrowserToolbar(title: "Imports", sort: $sort, filter: $filter) { $0.displayName }

            Divider()

            if model.isEmpty {
                BrowserEmptyState(message: filter.isEmpty
                    ? "No imported symbols in this target."
                    : "No imports match \"\(filter)\".")
            } else {
                // U8-5b: a Lumen table (name, library, ordinal); rows are lazy, so large import lists
                // stay cheap, and a row can be selected to read it.
                LumenTable(model.rows, selection: $selection, minHeight: 0, columns: [
                    .text("Name", monospaced: true) { $0.name },
                    LumenTableColumn("Library") { row in
                        Text(row.library)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.library)
                    },
                    LumenTableColumn("Ordinal", width: 64, alignment: .trailing) { row in
                        Text(row.ordinalText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    },
                ])
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Lumen.Space.s5)
                .accessibilityIdentifier("browsers.imports.table")
            }
        }
    }
}

// MARK: - Exports

struct ExportsBrowserView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var sort: ExportsBrowserSort = .name
    @State private var filter = ""

    private var model: ExportsBrowserModel {
        ExportsBrowserModel(exports: store.focusedAnalysis?.exports ?? [], sort: sort, filter: filter)
    }

    var body: some View {
        let model = model
        let imageSlot = store.focusedImageSlot
        VStack(spacing: 0) {
            BrowserToolbar(title: "Exports", sort: $sort, filter: $filter) { $0.displayName }

            Divider()

            if model.isEmpty {
                BrowserEmptyState(message: filter.isEmpty
                    ? "No exported symbols in this target."
                    : "No exports match \"\(filter)\".")
            } else {
                List(model.rows) { row in
                    let navigationTarget = store.browserNavigationTarget(
                        forExportID: row.id,
                        address: BrowserNavigationTarget.address(forExport: row),
                        in: imageSlot
                    )
                    Button {
                        if let navigationTarget {
                            store.navigateFromBrowser(navigationTarget)
                        }
                    } label: {
                        HStack(spacing: Lumen.Space.s5) {
                            Text(row.name)
                                .font(AppTypography.bytes)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if row.isForwarder {
                                BrowserBadge(text: "forwarder", tint: Color.lumen(.kindImport))
                            }
                            Spacer(minLength: Lumen.Space.s5)
                            Text(row.addressText)
                                .font(AppTypography.bytes)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!BrowserNavigationTarget.isNavigable(row))
                    .accessibilityLabel("\(row.name)\(row.isForwarder ? ", forwarder" : ""), \(row.addressText)")
                    .accessibilityHint(BrowserNavigationTarget.isNavigable(row) ? "Selects this address in the listing" : "")
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
}

// MARK: - Sections

struct SectionsBrowserView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var sort: SectionsBrowserSort = .address
    @State private var filter = ""

    private var model: SectionsBrowserModel {
        SectionsBrowserModel(sections: store.focusedAnalysis?.sections ?? [], sort: sort, filter: filter)
    }

    var body: some View {
        let model = model
        let imageSlot = store.focusedImageSlot
        VStack(spacing: 0) {
            BrowserToolbar(title: "Sections", sort: $sort, filter: $filter) { $0.displayName }

            Divider()

            if model.isEmpty {
                BrowserEmptyState(message: filter.isEmpty
                    ? "No sections in this target."
                    : "No sections match \"\(filter)\".")
            } else {
                List(model.rows) { row in
                    let navigationTarget = store.browserNavigationTarget(
                        forSectionID: row.id,
                        address: BrowserNavigationTarget.address(forSection: row),
                        in: imageSlot
                    )
                    Button {
                        if let navigationTarget {
                            store.navigateFromBrowser(navigationTarget)
                        }
                    } label: {
                        HStack(spacing: Lumen.Space.s5) {
                            Text(row.name)
                                .font(AppTypography.bytes)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if row.isExecutable {
                                BrowserBadge(text: "exec", tint: Color.lumen(.kindSegment))
                            }
                            if row.isZeroFill {
                                BrowserBadge(text: "bss", tint: Color.lumen(.kindSection))
                            }
                            Spacer(minLength: Lumen.Space.s5)
                            Text(row.addressText)
                                .font(AppTypography.bytes)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(row.sizeText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.name)\(row.isExecutable ? ", executable" : "")\(row.isZeroFill ? ", zero-fill" : ""), \(row.addressText), size \(row.sizeText)")
                    .accessibilityHint("Selects this address in the listing")
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
}
