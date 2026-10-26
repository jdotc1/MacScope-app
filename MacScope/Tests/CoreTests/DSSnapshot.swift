import AppKit
import LumenUI
#if !DS_SNAPSHOT_STANDALONE
@testable import MacScope
#endif
import SwiftUI
import LumenTokens

/// Renders design-system views to PNG and compares them with golden images. Used by
/// `DSSnapshotTests`; set `DS_RECORD_SNAPSHOTS=1` to rewrite the goldens.
///
/// AppKit-backed controls (`Button` with system styles, `List`, `TextField`, `ColorPicker`)
/// cannot render offscreen, so snapshot subjects stick to SwiftUI-drawn components.
@MainActor
enum DSSnapshot {
    private static var lastRenderedSnapshotName = "snapshot"
    private static var artifactSequence = 0

    struct Subject {
        let name: String
        let size: CGSize
        let view: AnyView
        /// Variants to render under. A subject that draws its own themes (the miniature sheet)
        /// renders once.
        var variants: [Variant] = Variant.all
    }

    /// One theme variant to snapshot under, rendered with a throwaway, non-persisting store.
    struct Variant {
        let themeID: String
        let colorScheme: ColorScheme
        /// A different editor theme, as Settings ▸ Themes ▸ Editor theme allows; `nil` = same.
        var editorThemeID: String? = nil
        var label: String {
            func short(_ id: String) -> Substring { id.split(separator: ".").last ?? "" }
            let base = "\(short(themeID))-\(colorScheme == .dark ? "dark" : "light")"
            return editorThemeID.map { "\(base)+\(short($0))-editor" } ?? base
        }

        static let all: [Variant] = [
            Variant(themeID: DSBuiltInThemes.scope.id, colorScheme: .light),
            Variant(themeID: DSBuiltInThemes.scope.id, colorScheme: .dark),
            Variant(themeID: DSBuiltInThemes.midnight.id, colorScheme: .dark),
            Variant(themeID: DSBuiltInThemes.contrast.id, colorScheme: .light),
            Variant(themeID: DSBuiltInThemes.contrast.id, colorScheme: .dark),
        ]

        /// Window and editor themes that differ. The editor subtree takes the editor theme's forced
        /// appearance (Midnight is dark), exactly as `dsEditorSurface` arranges in the app.
        static let splitThemes: [Variant] = [
            Variant(themeID: DSBuiltInThemes.scope.id, colorScheme: .dark, editorThemeID: DSBuiltInThemes.midnight.id),
            Variant(themeID: DSBuiltInThemes.midnight.id, colorScheme: .dark, editorThemeID: DSBuiltInThemes.scope.id),
            Variant(themeID: DSBuiltInThemes.scope.id, colorScheme: .light, editorThemeID: DSBuiltInThemes.contrast.id),
        ]
    }

    static func png(of subject: Subject, in variant: Variant, scale: CGFloat = 2) -> Data? {
        lastRenderedSnapshotName = "\(subject.name)@\(variant.label)"
        let store = DSThemeStore(themes: DSBuiltInThemes.all, selectedID: variant.themeID, persistsSelection: false)
        if let editor = variant.editorThemeID { store.selectEditorTheme(editor) }
        return DSThemeStore.withActiveStore(store) {
            let content = subject.view
                .lumenRendersOffscreen()
                .frame(width: subject.size.width, height: subject.size.height)
                .background(.lumen(.bgCanvas))
                .environment(\.colorScheme, variant.colorScheme)
                .environment(\.dsPalette, store.resolvedPalette())
            let renderer = ImageRenderer(content: content)
            renderer.scale = scale
            guard let cg = renderer.cgImage else { return nil }
            return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        }
    }

    struct Difference: CustomStringConvertible {
        let differingPixelFraction: Double
        let maxChannelDelta: Int
        let sizeMismatch: Bool
        var description: String {
            sizeMismatch ? "size differs"
                : "\((differingPixelFraction * 100).formatted(.number.precision(.fractionLength(2))))% of pixels differ (max channel delta \(maxChannelDelta))"
        }
    }

    /// Compares two PNGs. A pixel differs when any channel moves by more than `channelTolerance`
    /// (absorbs antialiasing and rasterizer noise).
    static func compare(_ a: Data, _ b: Data, channelTolerance: Int = 12) -> Difference {
        guard let ra = NSBitmapImageRep(data: a), let rb = NSBitmapImageRep(data: b),
              ra.pixelsWide == rb.pixelsWide, ra.pixelsHigh == rb.pixelsHigh else {
            exportMismatchArtifacts(actual: a, reference: b)
            return Difference(differingPixelFraction: 1, maxChannelDelta: 255, sizeMismatch: true)
        }
        var differing = 0, maxDelta = 0
        for y in 0..<ra.pixelsHigh {
            for x in 0..<ra.pixelsWide {
                guard let ca = ra.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let cb = rb.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let delta = [ca.redComponent - cb.redComponent, ca.greenComponent - cb.greenComponent,
                             ca.blueComponent - cb.blueComponent, ca.alphaComponent - cb.alphaComponent]
                    .map { Int((abs($0) * 255).rounded()) }.max() ?? 0
                maxDelta = max(maxDelta, delta)
                if delta > channelTolerance { differing += 1 }
            }
        }
        if differing > 0 {
            exportMismatchArtifacts(actual: a, reference: b)
        }
        return Difference(differingPixelFraction: Double(differing) / Double(ra.pixelsWide * ra.pixelsHigh),
                          maxChannelDelta: maxDelta, sizeMismatch: false)
    }

    /// Exports comparison mismatches, including differences below a caller's allowed fraction.
    /// Artifact failures are diagnostic only and never change the comparison result.
    private static func exportMismatchArtifacts(actual: Data, reference: Data) {
        // xcodebuild forwards TEST_RUNNER_* variables after removing that prefix.
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MACSCOPE_SNAPSHOT_ARTIFACTS"]
                ?? environment["TEST_RUNNER_MACSCOPE_SNAPSHOT_ARTIFACTS"],
              !path.isEmpty else { return }
        artifactSequence += 1
        let name = lastRenderedSnapshotName.replacingOccurrences(of: "/", with: "_")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("\(artifactSequence)-\(name)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try reference.write(to: directory.appendingPathComponent("reference.png"), options: .atomic)
            try actual.write(to: directory.appendingPathComponent("actual.png"), options: .atomic)
            guard let diff = differencePNG(actual: actual, reference: reference) else {
                print("Snapshot artifact diff could not be encoded: \(directory.path)")
                return
            }
            try diff.write(to: directory.appendingPathComponent("diff.png"), options: .atomic)
            print("Snapshot mismatch artifacts: \(directory.path)")
        } catch {
            print("Snapshot artifact export failed at \(directory.path): \(error)")
        }
    }

    /// Absolute channel differences on black; magenta marks pixels outside either image.
    private static func differencePNG(actual: Data, reference: Data) -> Data? {
        guard let actualImage = NSBitmapImageRep(data: actual),
              let referenceImage = NSBitmapImageRep(data: reference) else { return nil }
        let width = max(actualImage.pixelsWide, referenceImage.pixelsWide)
        let height = max(actualImage.pixelsHigh, referenceImage.pixelsHigh)
        guard let diff = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        for y in 0..<height {
            for x in 0..<width {
                guard x < actualImage.pixelsWide, y < actualImage.pixelsHigh,
                      x < referenceImage.pixelsWide, y < referenceImage.pixelsHigh,
                      let actualColor = actualImage.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let referenceColor = referenceImage.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    diff.setColor(.magenta, atX: x, y: y)
                    continue
                }
                let alphaDelta = abs(actualColor.alphaComponent - referenceColor.alphaComponent)
                diff.setColor(NSColor(srgbRed: max(abs(actualColor.redComponent - referenceColor.redComponent), alphaDelta),
                                      green: max(abs(actualColor.greenComponent - referenceColor.greenComponent), alphaDelta),
                                      blue: max(abs(actualColor.blueComponent - referenceColor.blueComponent), alphaDelta),
                                      alpha: 1), atX: x, y: y)
            }
        }
        return diff.representation(using: .png, properties: [:])
    }

    /// Reads colors from the environment palette at render time. (`subjects` is built once, so
    /// a `DS.color` call in its initializer would capture whichever store was active then.)
    private struct KindTagRow: View {
        @Environment(\.dsPalette) private var palette

        var body: some View {
            HStack(spacing: Lumen.Space.s3) {
                LumenTag("call", color: palette[.kindFunction])
                LumenTag("string", color: palette[.kindString])
                LumenTag("exec", color: palette[.kindSegment])
                LumenTag("bss", color: palette[.kindSection])
            }
        }
    }

    /// The four Lumen edge kinds and a selected edge, stroked as the graph strokes them.
    private struct GraphEdgeRow: View {
        @Environment(\.dsPalette) private var palette

        private func sample(_ token: LumenToken, width: CGFloat, dash: [CGFloat], label: String) -> some View {
            VStack(spacing: Lumen.Space.s2) {
                Path { path in
                    path.move(to: CGPoint(x: 2, y: 6))
                    path.addLine(to: CGPoint(x: 62, y: 6))
                }
                .stroke(palette[token], style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
                .frame(width: 64, height: 12)
                Text(label).font(Lumen.Font.caption).foregroundStyle(palette[.fgSecondary])
            }
        }

        // U2-graph edges (Lumen edge kinds): taken, not taken, unconditional, call/xref, selected.
        var body: some View {
            HStack(spacing: Lumen.Space.s6) {
                ForEach(LumenGraphEdgeKind.allCases, id: \.self) { kind in
                    sample(kind.token, width: kind.lineWidth(isSelected: false), dash: kind.dash, label: kind.title.lowercased())
                }
                sample(.fgPrimary, width: LumenGraphEdgeKind.taken.lineWidth(isSelected: true), dash: [], label: "selected")
            }
        }
    }

    /// A slice of the disassembly listing as the app draws it (UF-3): each row's fill and leading bar
    /// come from the real Lumen listing-row state (`dsListingRow`) on the editor surface, in its order
    /// (selection, program counter, patch, tag, current block). Syntax colors stay on every row,
    /// the selection included; there is no striping.
    private struct ListingRows: View {
        @Environment(\.dsPalette) private var palette

        private struct Row: Identifiable {
            let id: Int
            let address: String, bytes: String, mnemonic: String
            let mnemonicRole: LumenToken
            let operands: [(String, LumenToken)]
            let state: LumenListingRowState
        }

        private let rows: [Row] = [
            Row(id: 0, address: "1000a3e10", bytes: "fd 7b bf a9", mnemonic: "stp", mnemonicRole: .syntaxMnemonicMemory,
                operands: [("x29", .syntaxRegister), (", ", .syntaxPunctuation), ("x30", .syntaxRegister)],
                state: LumenListingRowState()),
            Row(id: 1, address: "1000a3e14", bytes: "fd 03 00 91", mnemonic: "mov", mnemonicRole: .syntaxMnemonicArithmetic,
                operands: [("x29", .syntaxRegister), (", ", .syntaxPunctuation), ("sp", .syntaxRegister)],
                state: LumenListingRowState(isInCurrentBlock: true)),
            Row(id: 2, address: "1000a3e18", bytes: "01 00 00 90", mnemonic: "adrp", mnemonicRole: .syntaxMnemonicMemory,
                operands: [("x1", .syntaxRegister), (", ", .syntaxPunctuation), ("selRef_init", .syntaxAddress)],
                state: LumenListingRowState(tag: .orange, isInCurrentBlock: true)),
            Row(id: 3, address: "1000a3e1c", bytes: "2f 00 00 94", mnemonic: "bl", mnemonicRole: .syntaxMnemonicBranch,
                operands: [("_objc_msgSend", .syntaxAddress)],
                state: LumenListingRowState(isProgramCounter: true, isInCurrentBlock: true)),
            Row(id: 4, address: "1000a3e20", bytes: "1f 20 03 d5", mnemonic: "nop", mnemonicRole: .syntaxMnemonicGeneral,
                operands: [("; patched", .syntaxPunctuation)],
                state: LumenListingRowState(isPatched: true, isInCurrentBlock: true)),
            Row(id: 5, address: "1000a3e24", bytes: "42 60 00 91", mnemonic: "add", mnemonicRole: .syntaxMnemonicArithmetic,
                operands: [("x2", .syntaxRegister), (", ", .syntaxPunctuation), ("#0x18", .syntaxImmediate)],
                state: LumenListingRowState(isSelected: true, isInCurrentBlock: true)),
        ]

        private func operands(_ row: Row) -> AttributedString {
            row.operands.reduce(into: AttributedString()) { result, part in
                var run = AttributedString(part.0)
                run.foregroundColor = palette[part.1]
                result.append(run)
            }
        }

        var body: some View {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: Lumen.Space.s5) {
                        Text(row.address).frame(width: 84, alignment: .leading)
                            .foregroundStyle(palette[.listingSecondaryText])
                        Text(row.bytes).frame(width: 96, alignment: .leading)
                            .foregroundStyle(palette[.listingSecondaryText])
                        Text(row.mnemonic).fontWeight(.semibold).frame(width: 44, alignment: .leading)
                            .foregroundStyle(palette[row.mnemonicRole])
                        Text(operands(row))
                        Spacer(minLength: 0)
                    }
                    .font(Lumen.Font.monoSmall)
                    .padding(.horizontal, Lumen.Space.s4)
                    .frame(height: DS.Layout.rowHeightRegular)
                    .dsListingRow(row.state, isActiveWindow: true)
                }
            }
            .background(palette[.bgCanvas])
            .dsEditorSurface(ownsEveryColor: true)
        }
    }

    /// The design-system subjects under snapshot. All are drawn by SwiftUI.
    static let subjects: [Subject] = [
        Subject(name: "evidence-badges", size: CGSize(width: 420, height: 44), view: AnyView(
            HStack(spacing: Lumen.Space.s3) { ForEach(DSEvidence.allCases, id: \.self) { DSEvidenceBadge(evidence: $0) } }
        )),
        Subject(name: "badges", size: CGSize(width: 420, height: 44), view: AnyView(
            HStack(spacing: Lumen.Space.s3) {
                LumenBadge("12 xrefs", systemImage: "arrow.triangle.branch", tone: .accent)
                LumenBadge("arm64e", monospaced: true)
                LumenBadge("Signed", systemImage: "checkmark.seal.fill", tone: .success)
                LumenBadge("3 warnings", tone: .warning)
            }
        )),
        Subject(name: "inspector-section", size: CGSize(width: 300, height: 96), view: AnyView(
            DSInspectorSection(id: .selection, title: "Selection", systemImage: "scope",
                               isExpanded: .constant(true)) {
                LumenPropertyRow(label: "Address", value: "0x1000a3e1c")
                LumenPropertyRow(label: "Target", value: "selRef_init")
            }
        )),
        // U7b/U7b-fit: a type's members at the inspector's width, one offset unrecorded, evidence as glyphs.
        Subject(name: "type-members", size: CGSize(width: 280, height: 170), view: AnyView(
            DSTypeMembersTable(rows: [
                DSTypeMemberRow(id: 0, offset: "+0x8", name: "_count", type: "int", evidence: "Static evaluation", evidenceSymbol: "function"),
                DSTypeMemberRow(id: 1, offset: "+0x10", name: "_ratio", type: "double", evidence: "Static evaluation", evidenceSymbol: "function"),
                DSTypeMemberRow(id: 2, offset: "—", name: "_delegate", type: "—", evidence: "Unknown", evidenceSymbol: "questionmark.circle"),
            ], note: "Partly unknown layout: rows marked — have no offset recorded in the image.")
            .lumenRendersOffscreen(true)
        )),
        // §4.93 (Lumen F1): no offset recorded, so no Offset column; names keep their distinguishing
        // tails, and same-module types end in the middle.
        Subject(name: "type-members-unknown-layout", size: CGSize(width: 280, height: 170), view: AnyView(
            DSTypeMembersTable(rows: [
                DSTypeMemberRow(id: 0, offset: "—", name: "triggerAnalysisOnAppear", type: "CalculatorViewModel.Mode", evidence: "Unknown", evidenceSymbol: "questionmark.circle"),
                DSTypeMemberRow(id: 1, offset: "—", name: "triggerAnalysisOnChange", type: "CalculatorViewModel.Operation", evidence: "Unknown", evidenceSymbol: "questionmark.circle"),
                DSTypeMemberRow(id: 2, offset: "—", name: "_showShiftedKeys", type: "Bool", evidence: "Unknown", evidenceSymbol: "questionmark.circle"),
            ], note: "Unknown layout: the image records no offsets for these members.")
            .lumenRendersOffscreen(true)
        )),
        Subject(name: "empty-state", size: CGSize(width: 320, height: 220), view: AnyView(
            LumenEmptyState(systemImage: "arrow.triangle.branch", title: "No cross-references",
                         message: "Nothing in this image calls or reads this function yet.")
        )),
        Subject(name: "pills", size: CGSize(width: 520, height: 40), view: AnyView(
            HStack(spacing: Lumen.Space.s3) {
                LumenPill(label: "start", value: "0x1000a3e10")
                LumenPill(label: "MH_EXECUTE", value: "arm64e", systemImage: "cpu")
                LumenPill(label: "functions", value: "1,284", systemImage: "function", style: .metric)
            }
        )),
        Subject(name: "kind-tags", size: CGSize(width: 420, height: 36), view: AnyView(KindTagRow())),
        Subject(name: "kind-badges", size: CGSize(width: 420, height: 36), view: AnyView(
            HStack(spacing: Lumen.Space.s3) { ForEach(DSObjectKind.allCases, id: \.self) { DSKindBadge(kind: $0) } }
        )),
        Subject(name: "listing-rows", size: CGSize(width: 520, height: 172), view: AnyView(ListingRows()),
                variants: Variant.all + Variant.splitThemes),
        Subject(name: "graph-edges", size: CGSize(width: 560, height: 56), view: AnyView(GraphEdgeRow())),
        Subject(name: "badge-tones", size: CGSize(width: 520, height: 44), view: AnyView(
            HStack(spacing: Lumen.Space.s3) {
                ForEach(LumenBadge.Tone.allCases, id: \.self) { tone in
                    LumenBadge("\(tone)", systemImage: tone == .neutral ? nil : "circle.fill", tone: tone)
                }
            }
        )),
        Subject(name: "section-headers", size: CGSize(width: 300, height: 120), view: AnyView(
            VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                LumenSectionHeader(title: "Cross-references") { LumenBadge("12", tone: .accent) }
                LumenPropertyRow(label: "Callers", value: "4 functions", monospaced: false)
                LumenSectionHeader(title: "Signature") { LumenBadge("Signed", systemImage: "checkmark.seal.fill", tone: .success) }
                LumenPropertyRow(label: "Team", value: "Developer ID", monospaced: false)
            }.padding(Lumen.Space.s4)
        )),
        Subject(name: "empty-state-action", size: CGSize(width: 320, height: 240), view: AnyView(
            LumenEmptyState(systemImage: "magnifyingglass", title: "No matches",
                         message: "No symbol in this image matches the filter.",
                         actionTitle: "Clear Filter", action: {})
        )),
        // Every built-in palette in one image, drawn by Lumen's miniature (U5d; code strip since Lumen
        // 0.37.1): chrome values and syntax.* colours (with the current line and selection) show up
        // here. listing.* values are guarded by the listing-rows subject (5 themes and 3 splits).
        Subject(name: "theme-miniatures", size: CGSize(width: 1080, height: 150), view: AnyView(
            HStack(spacing: Lumen.Space.s4) {
                ForEach(DSBuiltInThemes.all, id: \.id) { theme in
                    ForEach(theme.supportedColorSchemes, id: \.self) { scheme in
                        LumenThemeMiniature(theme: theme, registry: MacScopeLumen.registry, appearance: LumenAppearance(isDark: scheme == .dark, isHighContrast: false))
                            .frame(width: 200)
                            .clipShape(.rect(cornerRadius: Lumen.Radius.md))
                    }
                }
            }.padding(Lumen.Space.s4)
        ), variants: [Variant.all[0]]),
    ]
}
