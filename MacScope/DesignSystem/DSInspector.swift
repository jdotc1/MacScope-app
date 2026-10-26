import LumenUI
import SwiftUI
import LumenTokens

/// Persisted identity is independent of a translated title or the current selection.
enum DSInspectorSectionID: String, CaseIterable, Sendable {
    case selection
    case function
    case type
    case switchHint
    case data
    case addressDetail
    case segment
    case crossReferences
    case analysis
    case breakpoints
    case diagnostics
    case typeAtlas
    case typeMembers
    case typeMethods
    case typeUsers
    case typeWitnesses
    case typeProperties

    var sceneStorageKey: String { "MacScope.inspector.section.\(rawValue).expanded" }
    var accessibilityIdentifier: String { "inspector.section.\(rawValue)" }

    var hue: LumenToken {
        switch self {
        case .selection: .accent
        case .function: .kindFunction
        case .type: .kindType
        case .switchHint: .statusWarning
        case .data: .kindSymbol
        case .addressDetail: .kindImage
        case .segment: .kindSegment
        case .crossReferences, .breakpoints: .kindDebug
        case .analysis: .statusInfo
        case .diagnostics: .statusWarning
        case .typeAtlas, .typeMembers: .kindType
        case .typeMethods, .typeWitnesses: .kindFunction
        case .typeUsers: .kindDebug
        case .typeProperties: .kindType
        }
    }
}

enum DSInspectorExpansionPolicy {
    static let defaultExpanded = true

    /// An explicit snapshot/test binding wins without writing the scene's saved choice.
    static func binding(restored: Binding<Bool>, override: Binding<Bool>?) -> Binding<Bool> {
        override ?? restored
    }
}

/// The adapter always supplies expansion authority; Lumen's view-local fallback is unused.
struct DSInspectorSection<Content: View>: View {
    let id: DSInspectorSectionID
    let title: String
    let systemImage: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        LumenInspectorSection(title, systemImage: systemImage, hue: id.hue, isExpanded: $isExpanded) {
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id.accessibilityIdentifier)
    }
}

struct DSInspectorHeader: View {
    let title: String
    let subtitle: String
    @Environment(\.lumenMetrics) private var metrics

    var body: some View {
        LumenInspectorHeader(title, subtitle: subtitle, systemImage: "info.circle")
            .lumenMetrics(addressMetrics)
            .truncationMode(.middle)
            .textSelection(.enabled)
            // macOS can lose the combined title when the header's text is selectable.
            // Keep the visible title and selection detail independently available to VoiceOver.
            .accessibilityLabel(title)
            .accessibilityValue(subtitle)
    }

    private var addressMetrics: LumenMetrics {
        var result = metrics
        result.typography.caption = metrics.typography.monoCaption
        return result
    }
}

// MARK: Empty inspector and address field (Lumen 0.13–0.14)

extension View {
    /// While `isEmpty`, the inspector shows one "Nothing selected" message in place of its sections
    /// (no paragraph repeated in every section); the sections return with a selection.
    func dsInspectorEmptyState(_ isEmpty: Bool, message: String) -> some View {
        lumenInspectorEmptyState(isEmpty, message: message)
    }
}

// MARK: Inspector summary and references (Lumen 0.26.0, "B · Summary card, then sections")


// MARK: Type Atlas members (U7b, LumenTable)

/// One stored member of a type as the inspector lists it. A missing offset or type reads "—".
struct DSTypeMemberRow: Identifiable, Equatable {
    let id: Int
    var offset: String
    var name: String
    var type: String
    var evidence: String
    /// The evidence as a glyph, so the table fits the inspector's width; its label is the help tag.
    var evidenceSymbol: String = "questionmark.circle"
    var allowsWrapping = false
    var detail: String? = nil

    var typeDetail: String {
        guard let detail, !detail.isEmpty else { return type }
        return "\(type)\n\(detail)"
    }

    /// What a missing offset or type reads.
    static let unknownMark = "—"
}

/// A type's members in a Lumen table: offset, name, type, and where the offset came from (a glyph
/// with its label as the help tag, so name and type keep the width at the inspector's 248–340 pt),
/// then an optional note when the layout is unknown. When no member has an offset the Offset column
/// leaves the row (the note says why), and when every member has the same evidence its glyph does
/// (the inspector's header badge already says it); Name takes their width. Up to eight rows show at
/// once; longer types scroll inside the table.
struct DSTypeMembersTable: View {
    let rows: [DSTypeMemberRow]
    let note: String?
    @State private var selection: Int?
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenDensity) private var density

    static let visibleRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            // U10-4 (Lumen's inspector width rule): Offset 44 mono, evidence 16 (a glyph header);
            // Name and Type keep at least ~9 mono characters and Name keeps its width longest. Cells
            // end at the tail with their full text as help (`LumenTableText`). Below 300 pt the
            // Evidence column leaves the row (Lumen's ruling for the 8-character floor at 248/260);
            // the name's help and accessibility value carry it.
            // §4.93 (Lumen F1, N1): an Offset column of "—" and the same glyph in every row only take
            // width from the names, so they leave the row. Name and Type end in the middle, where
            // members and same-module types differ ("trigg…Appear", "Calc…Mode").
            ViewThatFits(in: .horizontal) {
                if evidenceVaries {
                    table(showsEvidence: true).frame(minWidth: evidenceMinimumWidth)
                }
                table(showsEvidence: false)
            }
            .accessibilityIdentifier("typeAtlas.members")
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("typeAtlas.members.layoutNote")
            }
        }
        .padding(.vertical, Lumen.Space.s2)
    }

    /// The table width below which the Evidence column leaves the row: Lumen's ~300 pt inspector
    /// less its side padding.
    static let evidenceMinimumWidth: CGFloat = 268
    static let offsetWidth: CGFloat = 44

    /// False when no member has a recorded offset: the column would read "—" in every row.
    var showsOffset: Bool { rows.contains { $0.offset != DSTypeMemberRow.unknownMark } }

    /// False when every member has the same evidence: the column would repeat one glyph.
    var evidenceVaries: Bool { Set(rows.map(\.evidence)).count > 1 }

    /// Without the Offset column (and the spacing before it) Evidence fits that much narrower.
    private var evidenceMinimumWidth: CGFloat {
        showsOffset ? Self.evidenceMinimumWidth : Self.evidenceMinimumWidth - Self.offsetWidth - metrics.spacing.s5
    }

    private func table(showsEvidence: Bool) -> some View {
        var columns: [LumenTableColumn<DSTypeMemberRow>] = []
        if showsOffset {
            columns.append(.text("Offset", width: Self.offsetWidth, monospaced: true) { $0.offset })
        }
        columns += [
            LumenTableColumn("Name") { row in
                if showsEvidence {
                    DSTableMiddleText(row.name, allowsWrapping: row.allowsWrapping)
                } else {
                    DSTableMiddleText(row.name, allowsWrapping: row.allowsWrapping)
                        .help("\(row.name) — \(row.evidence)")
                        .accessibilityValue(row.evidence)
                }
            }
            .minWidth(72).priority(1),
            LumenTableColumn("Type") {
                DSTableMiddleText($0.typeDetail, monospaced: true, allowsWrapping: $0.allowsWrapping)
            }.minWidth(72),
        ]
        if showsEvidence {
            columns.append(
                LumenTableColumn("Evidence", width: 16, alignment: .center) { row in
                    Image(systemName: row.evidenceSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(row.evidence)
                        .accessibilityLabel(row.evidence)
                }
                .header { Image(systemName: "checkmark.seal").font(.caption2).foregroundStyle(.secondary) }
            )
        }
        return LumenTable(rows, selection: $selection, minHeight: rowsHeight, columns: columns)
    }

    private var rowsHeight: CGFloat {
        CGFloat(min(rows.count, Self.visibleRows)) * (density.rowHeight(in: metrics.layout) + metrics.stroke.hairline)
    }
}

/// A table cell like `LumenTableText` that ends in the middle instead of at the tail, for values
/// that differ at the end (member names sharing a stem, type names sharing a module prefix). The full text is the help tag, and
/// it reports itself to Lumen's truncation checks when fewer than 8 characters show around the
/// ellipsis. MacScope-side until Lumen's table text takes a truncation mode (§4.93; D22 holds the pin).
struct DSTableMiddleText: View {
    let text: String
    var monospaced = false
    var allowsWrapping = false

    var effectiveLineLimit: Int? { allowsWrapping ? nil : 1 }
    var truncationMode: Text.TruncationMode { .middle }

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont

    init(_ text: String, monospaced: Bool = false, allowsWrapping: Bool = false) {
        self.text = text
        self.monospaced = monospaced
        self.allowsWrapping = allowsWrapping
    }

    var body: some View {
        let font = monospaced ? (codeFont ?? .standard).font(sizeDelta: -1) : metrics.typography.callout
        Text(text)
            .font(font)
            .foregroundStyle(palette[.fgPrimary])
            .lineLimit(effectiveLineLimit)
            .truncationMode(truncationMode)
            .fixedSize(horizontal: false, vertical: allowsWrapping)
            .help(text)
            .background { minimumWidthWatch(font) }
    }

    /// The shortest middle-truncated form keeps 4 characters on each side of the ellipsis.
    static func shortestForm(_ text: String) -> String {
        let n = LumenTableText.minimumVisibleCharacters
        return text.count > n + 2 ? String(text.prefix(n / 2)) + "…" + String(text.suffix(n - n / 2)) : text
    }

    private func minimumWidthWatch(_ font: Font) -> some View {
        GeometryReader { actual in
            Text(Self.shortestForm(text)).font(font).fixedSize().hidden()
                .background {
                    GeometryReader { needed in
                        Color.clear.preference(key: LumenTruncationKey.self,
                                               value: !allowsWrapping && actual.size.width + 0.5 < needed.size.width
                                                   ? ["\(text) (fewer than \(LumenTableText.minimumVisibleCharacters) characters show)"] : [])
                    }
                }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Applied type values (U8-5a, LumenTable)

/// One member of a type applied at an address, with the value decoded from the loaded bytes.
struct DSAppliedTypeRow: Identifiable, Equatable {
    let id: Int
    var offset: String
    var name: String
    var type: String
    var value: String
}

/// The members of a type applied at the selected address in a Lumen table, by Lumen's inspector width
/// rule (U10-6): Offset 44 pt mono; Name and Type keep at least ~9 mono characters, Name longest; the
/// decoded Value is the first to give way and leaves the row below `valueMinimumWidth`, its value then
/// in the name's help tag. Cells end at the tail with their full text as help. Up to eight rows show
/// at once.
struct DSAppliedTypeTable: View {
    let rows: [DSAppliedTypeRow]
    @State private var selection: Int?
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenDensity) private var density

    /// The table width below which the Value column leaves the row: Offset 44 + Name, Type and Value
    /// at their 72 pt minimums + column spacing and row padding, so every cell keeps 8+ characters.
    static let valueMinimumWidth: CGFloat = 328
    /// Below this the Type column leaves too (Lumen's order: Value gives way first, then Type), so
    /// the name keeps 8+ characters at the 248 pt inspector.
    static let typeMinimumWidth: CGFloat = 236

    var body: some View {
        ViewThatFits(in: .horizontal) {
            table(showsValue: true, showsType: true).frame(minWidth: Self.valueMinimumWidth)
            table(showsValue: false, showsType: true).frame(minWidth: Self.typeMinimumWidth)
            table(showsValue: false, showsType: false)
        }
        .padding(.vertical, Lumen.Space.s2)
        .accessibilityIdentifier("inspector.appliedType.members")
    }

    private func table(showsValue: Bool, showsType: Bool) -> some View {
        var columns: [LumenTableColumn<DSAppliedTypeRow>] = [
            .text("Offset", width: 44, monospaced: true) { $0.offset },
            LumenTableColumn("Name") { row in
                if showsValue {
                    LumenTableText(row.name)
                } else {
                    // Columns that left the row: the name's help tag carries them.
                    let help = showsType ? "\(row.name) = \(row.value)" : "\(row.name): \(row.type) = \(row.value)"
                    LumenTableText(row.name)
                        .help(help)
                        .accessibilityValue(showsType ? row.value : "\(row.type) = \(row.value)")
                }
            }
            .minWidth(72).priority(2),
        ]
        if showsType {
            columns.append(.text("Type", monospaced: true) { $0.type }.minWidth(72).priority(1))
        }
        if showsValue {
            // Every shared column has a minimum (Lumen 0.42: one without collapses to nothing).
            columns.append(.text("Value", alignment: .trailing, monospaced: true) { $0.value }.minWidth(72))
        }
        return LumenTable(rows, selection: $selection, minHeight: rowsHeight, columns: columns)
    }

    private var rowsHeight: CGFloat {
        CGFloat(min(rows.count, DSTypeMembersTable.visibleRows)) * (density.rowHeight(in: metrics.layout) + metrics.stroke.hairline)
    }
}
