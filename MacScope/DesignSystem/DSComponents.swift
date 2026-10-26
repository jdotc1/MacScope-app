import AppKit
import LumenTokens
import LumenUI
import SwiftUI

// MARK: Evidence

/// How well an analysis fact is supported. MacScope never lets color carry this alone: every
/// state has its own symbol shape and words.
enum DSEvidence: String, CaseIterable, Sendable {
    case proven
    case inferred
    case unknown
    case missing

    var label: String {
        switch self {
        case .proven: "Proven"
        case .inferred: "Inferred"
        case .unknown: "Unknown"
        case .missing: "Missing"
        }
    }

    /// Filled circle, diamond, hollow circle, crossed circle: distinguishable in grayscale.
    var symbol: String {
        switch self {
        case .proven: "checkmark.circle.fill"
        case .inferred: "diamond.fill"
        case .unknown: "circle.dashed"
        case .missing: "xmark.circle"
        }
    }

    var token: LumenToken {
        switch self {
        case .proven: .evidenceProven
        case .inferred: .evidenceInferred
        case .unknown: .evidenceUnknown
        case .missing: .evidenceMissing
        }
    }

    /// The contrast-verified background the badge text sits on.
    var backgroundToken: LumenToken {
        switch self {
        case .proven: .statusSuccessBackground
        case .inferred: .statusWarningBackground
        case .unknown: .statusNeutralBackground
        case .missing: .statusDangerBackground
        }
    }
}

/// Where an analysis fact came from. A closed set, so badges, filters and the assistant all name
/// sources the same way.
enum DSEvidenceSource: String, CaseIterable, Sendable {
    case machORelocation, symbolTable, debugInfo, objcMetadata, swiftMetadata
    case decompiler, dataflow, heuristic, runtime, user

    var label: String {
        switch self {
        case .machORelocation: "Mach-O relocation"
        case .symbolTable: "Symbol table"
        case .debugInfo: "Debug info"
        case .objcMetadata: "Objective-C metadata"
        case .swiftMetadata: "Swift metadata"
        case .decompiler: "Decompiler"
        case .dataflow: "Data flow"
        case .heuristic: "Heuristic"
        case .runtime: "Runtime observation"
        case .user: "You"
        }
    }
}

/// A compact evidence marker: symbol, state word, and an optional source. The text sits on the
/// matching contrast-verified status background, never on a composited wash.
struct DSEvidenceBadge: View {
    let evidence: DSEvidence
    var source: DSEvidenceSource?

    var body: some View {
        HStack(spacing: Lumen.Space.s2) {
            Image(systemName: evidence.symbol)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(evidence.label)
                .font(Lumen.Font.captionEmphasized)
            if let source {
                Text(source.label)
                    .font(Lumen.Font.caption)
                    .foregroundStyle(.lumen(.fgPrimary))
            }
        }
        .foregroundStyle(.lumen(evidence.token))
        .padding(.horizontal, Lumen.Space.s3)
        .padding(.vertical, Lumen.Space.s1)
        .background(.lumen(evidence.backgroundToken), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.map { "\(evidence.label) evidence, \($0.label)" } ?? "\(evidence.label) evidence")
    }
}

// MARK: Lumen component compatibility

// MARK: Banner, loading and error states (Lumen 0.8.0)

// MARK: Sidebar chrome (Lumen 0.12–0.15)

// MARK: Previews

#Preview("Components") {
    VStack(alignment: .leading, spacing: Lumen.Space.s6) {
        HStack(spacing: Lumen.Space.s3) {
            ForEach(DSEvidence.allCases, id: \.self) { DSEvidenceBadge(evidence: $0) }
        }
        DSEvidenceBadge(evidence: .proven, source: .machORelocation)
        HStack(spacing: Lumen.Space.s3) {
            LumenBadge("12 xrefs", systemImage: "arrow.triangle.branch", tone: .accent)
            LumenBadge("arm64e", monospaced: true)
            LumenBadge("Signed", systemImage: "checkmark.seal.fill", tone: .success)
            LumenBadge("3 warnings", tone: .warning)
        }
        VStack(alignment: .leading, spacing: Lumen.Space.s1) {
            LumenSectionHeader("Instruction")
            LumenPropertyRow(label: "Address", value: "0x1000a3e1c")
            LumenPropertyRow(label: "Target", value: "selRef_init")
        }
        .frame(width: 260)
        LumenEmptyState(
            systemImage: "arrow.triangle.branch",
            title: "No cross-references",
            message: "Nothing in this image calls or reads -[MessageViewer init] yet.",
            actionTitle: "Search All Images",
            action: {}
        )
        .frame(height: 220)
    }
    .padding(Lumen.Space.s8)
    .background(.lumen(.bgCanvas))
}

// MARK: Code pane chrome (Lumen 0.22.0, "A · Quiet strip + gutter")

/// The status a `DSStatusStrip` shows as a dot and a word, with its own spoken label and value.
struct DSStripStatus {
    let title: String
    let tone: LumenToken
    var help: String?
    var accessibilityLabel: String?
    var accessibilityValue: String?
    var accessibilityIdentifier: String?
}

/// A command in a `DSStatusStrip`: drawn as its glyph, with its hint as help.
struct DSStripAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var help: String?
    var accessibilityLabel: String?
    var accessibilityHint: String?
    var accessibilityIdentifier: String?
    let perform: () -> Void
}

/// A code pane's status strip: Lumen's `LumenStatusStrip` (leading control, the status as a dot and
/// a word with its own spoken label, value and identifier, warning chips, icon-only commands with
/// identifiers and help; when narrow the status drops to its dot, then the chips fold into its
/// help tag; nothing clips). Lumen 0.34.3 (jdotc1/Lumen#4).
struct DSStatusStrip<Leading: View>: View {
    var status: DSStripStatus?
    var chips: [LumenStripChip] = []
    var actions: [DSStripAction] = []
    @ViewBuilder var leading: Leading

    var body: some View {
        LumenStatusStrip(
            status: status.map {
                LumenStripStatus($0.title, tone: $0.tone, spokenLabel: $0.accessibilityLabel,
                                 spokenValue: $0.accessibilityValue, accessibilityIdentifier: $0.accessibilityIdentifier)
            },
            chips: chips,
            actions: actions.map { action in
                LumenBarAction(action.title, systemImage: action.systemImage, help: action.help ?? action.accessibilityHint,
                               accessibilityIdentifier: action.accessibilityIdentifier, perform: action.perform)
            }
        ) { leading }
        .frame(minHeight: DSStatusStripMetrics.height)
    }
}

enum DSStatusStripMetrics {
    /// Lumen's strip minimum: the one status-and-action band of a code pane.
    static let height: CGFloat = 36
}

enum DSCodeGutter {
    /// Puts a line-number ruler on `textView`'s scroll view, in the editor palette. Keep the result
    /// and call `refresh(_:)` on a theme change.
    @MainActor
    static func install(on textView: NSTextView) -> LumenLineNumberRuler {
        LumenLineNumberRuler.install(on: textView, palette: DSThemeStore.active.resolvedEditorPalette())
    }

    @MainActor
    static func refresh(_ ruler: LumenLineNumberRuler) {
        ruler.palette = DSThemeStore.active.resolvedEditorPalette()
    }

    /// Tints the current line; call from the text view's `drawBackground(in:)` after `super`.
    @MainActor
    static func drawCurrentLine(in textView: NSTextView) {
        LumenLineNumberRuler.drawCurrentLine(
            in: textView,
            color: DSThemeStore.active.nsColor(LumenToken.Code.currentLine, editorSurface: true)
        )
    }
}

// MARK: Listing rows (Lumen 0.25.0, "B + branch lanes")

extension View {
    /// Fills a listing row for `state` and draws its leading bar. The selection is a tint with an
    /// accent bar, so mnemonics and operands keep their syntax colors.
    func dsListingRow(_ state: LumenListingRowState, isActiveWindow: Bool) -> some View {
        lumenListingRow(state, isActiveWindow: isActiveWindow)
    }
}

// MARK: Hex colors (Lumen 0.18.0, "A · Quiet")

/// The hex editor's colors from Lumen's quiet hex style, on the editor surface: the offset column,
/// bytes with zeros faded, unprintable ASCII, the selection and the column separators. The editor
/// keeps its own editing model and its patched-byte highlight.
struct DSHexStyle {
    let offset: NSColor
    let byte: NSColor
    let zeroByte: NSColor
    let unprintable: NSColor
    let selectionBackground: NSColor
    let selectionForeground: NSColor
    let separator: NSColor

    @MainActor
    static func current() -> DSHexStyle {
        let style = LumenHexStyle(palette: DSThemeStore.active.resolvedEditorPalette())
        return DSHexStyle(
            offset: NSColor(style.offset),
            byte: NSColor(style.byte),
            zeroByte: NSColor(style.zeroByte),
            unprintable: NSColor(style.unprintable),
            selectionBackground: NSColor(style.selectionBackground),
            selectionForeground: NSColor(style.selectionForeground),
            separator: NSColor(style.separator)
        )
    }
}

// MARK: Panel bar parts (Lumen 0.12.0)

extension View {
    /// Lumen's focus ring for custom-styled buttons.
    func dsFocusRing(cornerRadius: CGFloat? = nil) -> some View { lumenFocusRing(cornerRadius: cornerRadius) }

    /// The focus ring for a `LumenPrimaryButtonStyle` capsule (Lumen draws the primary action as a
    /// 12 pt-radius capsule).
    func dsPrimaryFocusRing() -> some View { lumenFocusRing(cornerRadius: 12) }
}

/// A hairline rule across a row (the Lumen listing's rule above each function label).
struct DSHairlineRule: View {
    var body: some View {
        Rectangle().fill(Color.lumen(.borderSubtle)).frame(height: 0.5).accessibilityHidden(true)
    }
}

// MARK: Debugger stack and registers (Lumen 0.16.0)

// MARK: Debugger breakpoints, watches, variables, console (Lumen 0.17–0.20)

// MARK: Sheets (Lumen 0.21.0)

// MARK: Settings (Lumen 0.24.0, "B · Rich rows")

