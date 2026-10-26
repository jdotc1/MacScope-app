import SwiftUI
import LumenUI

/// The "Signature & Dependencies" panel — surfaces the Mach-O load-command metadata the loader
/// computes at import time (`MachOLoadMetadata`): the code signature (team identifier, signing
/// identifier, hash type, flags, entitlement keys), the imported symbols with their source dylib,
/// and the dependent dylib list with versions. Presented as a sheet from View ▸ Signature &
/// Dependencies, mirroring the Problems panel's chrome. A dumb view driven entirely by
/// `store.snapshot.machOMetadata` (a pure, derived value) — nil for non-Mach-O formats and after a
/// package reload, in which case it shows an "unavailable" state.
struct MachOMetadataSheet: View {
    @ObservedObject var store: WorkspaceStore

    private var metadata: MachOLoadMetadata? { store.snapshot.machOMetadata }
    private var signatureScope: MachOSignatureCoveragePresentation? {
        guard metadata != nil,
              let binary = store.snapshot.binary(in: store.snapshot.primarySlot) else { return nil }
        let witness = binary.containerAdmissionWitness
        let otherBytes = witness.map {
            $0.sliceOffset != 0 || $0.sliceSize != $0.containerByteCount
        }
        let variant = binary.artifactIdentity?.architectureVariant
        let architecture = variant == .other ? binary.architecture : (variant?.rawValue ?? binary.architecture)
        return .init(imageName: binary.name, architecture: architecture,
                     selectedSliceIndex: binary.selectedSliceIndex,
                     hasOtherContainerBytes: otherBytes,
                     hasCodeSignature: metadata?.codeSignature != nil,
                     machOSelectedSliceFact: binary.machOSelectedSliceFact)
    }
    private var imageGraph: ApplicationImageGraph {
        ApplicationImageGraphBuilder().build(from: store.snapshot)
    }
    private var hasRenderableGraph: Bool {
        imageGraph.nodes.count > 1 || !imageGraph.edges.isEmpty
    }
    private var hasRenderableMetadata: Bool {
        guard let metadata else { return false }
        return signatureScope != nil
            || metadata.codeSignature != nil
            || !metadata.importedSymbols.isEmpty
            || !metadata.dependentDylibs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 460, idealWidth: 560, minHeight: 360, idealHeight: 520)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Signature and Dependencies")
    }

    private var header: some View {
        HStack(spacing: Lumen.Space.s5) {
            Label("Signature & Dependencies", systemImage: "lock.doc")
                .font(.headline)
                .lumenNeverTruncates("Signature & Dependencies")
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: Lumen.Space.s5)

            Button("REA Inspection") {
                store.showMachOMetadata = false
                store.showREAWorkbench = true
            }
            .disabled(store.focusedBinary == nil)
            Button("Done") { store.showMachOMetadata = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Lumen.Space.s6)
        .padding(.vertical, Lumen.Space.s5)
    }

    var hasRenderableContent: Bool {
        hasRenderableMetadata || hasRenderableGraph || !store.snapshot.binaries.isEmpty
    }

    @ViewBuilder
    private var content: some View {
        if hasRenderableContent {
            ScrollView {
                // §4.38: one flat lazy stack. Every section's header and rows are its direct
                // children (`section` returns a flattening Group), so an image with thousands of
                // imported symbols or dependencies only builds the rows near the viewport.
                LazyVStack(alignment: .leading, spacing: Lumen.Space.s4) {
                    UnwindAuditView(store: store)
                    Divider()
                    if store.snapshot.binaries.count >= 2 {
                        EntitlementComparisonView(store: store)
                        Divider()
                    }
                    if hasRenderableGraph {
                        imageGraphSection(imageGraph)
                    }
                    if let scope = signatureScope {
                        section("Selected Slice Signature Coverage", systemImage: "doc.text.magnifyingglass") {
                            Text(scope.source).font(.caption.weight(.semibold)).textSelection(.enabled)
                            Text(scope.coverage).font(.caption).foregroundStyle(.secondary)
                            Text(scope.signature).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let signature = metadata?.codeSignature {
                        codeSignatureSection(signature)
                    }
                    if let importedSymbols = metadata?.importedSymbols, !importedSymbols.isEmpty {
                        importedSymbolsSection(importedSymbols)
                    }
                    if let dependentDylibs = metadata?.dependentDylibs, !dependentDylibs.isEmpty {
                        dependentDylibsSection(dependentDylibs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Lumen.Space.s6)
            }
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        VStack(spacing: Lumen.Space.s4) {
            Spacer()
            Image(systemName: "questionmark.folder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No load metadata available.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Signature, imports, and dependencies are read from the Mach-O at import time. They are unavailable for non-Mach-O binaries and after reopening a saved workspace (re-import to populate).")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Lumen.Space.s7)
    }

    // MARK: - Sections

    private func imageGraphSection(_ graph: ApplicationImageGraph) -> some View {
        section("Application Image Graph", systemImage: "point.3.connected.trianglepath.dotted") {
            let presentation = ApplicationImageGraphPresentation(graph: graph)

            Text(presentation.summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: Lumen.Space.s4) {
                ForEach(presentation.resolutionRows) { row in
                    imageGraphSummaryPill(row)
                }
            }

            // §4.38: each list's caption and rows are direct children of the sheet's lazy stack
            // (no wrapping VStack), so an image with thousands of dependencies stays lazy.
            if !presentation.workspaceRows.isEmpty {
                Text("Loaded images")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, Lumen.Space.s4)
                ForEach(presentation.workspaceRows) { row in
                    imageGraphNodeRow(row)
                }
            }

            if !presentation.unresolvedRows.isEmpty {
                Text("Unresolved dependencies")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.lumen(.statusWarning))
                    .padding(.top, Lumen.Space.s4)
                ForEach(presentation.unresolvedRows) { row in
                    imageGraphUnresolvedRow(row)
                }
            }

            if !presentation.edgeRows.isEmpty {
                Text("Declared edges")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, Lumen.Space.s4)
                ForEach(presentation.edgeRows) { row in
                    imageGraphEdgeRow(row)
                }
            } else {
                Text("No declared dependency edges are available for the currently loaded images.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func imageGraphSummaryPill(_ row: ApplicationImageGraphPresentation.SummaryRow) -> some View {
        HStack(spacing: Lumen.Space.s2) {
            Text(row.value)
                .font(.caption2.weight(.semibold))
            Text(row.label)
                .font(.caption2)
        }
        .foregroundStyle(toneColor(row.tone))
        .padding(.horizontal, Lumen.Space.s4)
        .padding(.vertical, Lumen.Space.s1)
        .background(
            Capsule()
                .fill(toneBackground(row.tone))
        )
    }

    private func imageGraphNodeRow(_ row: ApplicationImageGraphPresentation.NodeRow) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s4) {
                Text(row.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.edgeSummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let path = row.path {
                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func imageGraphUnresolvedRow(_ row: ApplicationImageGraphPresentation.UnresolvedRow) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s1) {
            Text(row.sourceToTarget)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(row.rawPath)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(row.reason)
                .font(.caption2)
                .foregroundStyle(Color.lumen(.statusWarning))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func imageGraphEdgeRow(_ row: ApplicationImageGraphPresentation.EdgeRow) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s4) {
                Text(row.sourceTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(row.targetTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text(row.rawPath)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: Lumen.Space.s5) {
                Text(row.loadKind)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("ordinal \(row.ordinal)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(row.resolutionTitle)
                    .font(.caption2)
                    .foregroundStyle(toneColor(row.tone))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codeSignatureSection(_ signature: MachOLoadMetadata.CodeSignatureInfo) -> some View {
        section("Selected Slice Code Signature", systemImage: "checkmark.seal") {
            keyValueRow("Team ID", signature.teamIdentifier ?? "—")
            keyValueRow("Identifier", signature.identifier ?? "—")
            keyValueRow("Hash Type", signature.hashTypeName ?? "—")
            if let flags = signature.codeSignatureFlags {
                keyValueRow("Flags", String(format: "0x%x", flags))
            }
            if signature.entitlementsParsed {
                keyValueRow("Entitlements", String(AttributedString(localized: "^[\(signature.entitlementsKeyCount ?? signature.entitlementsKeys.count) key](inflect: true)").characters))
                ForEach(signature.entitlementsKeys, id: \.self) { key in
                    Text(key)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if signature.entitlementsDER {
                keyValueRow("Entitlements", "DER (not decoded)")
            } else {
                keyValueRow("Entitlements", "None")
            }
        }
    }

    private func importedSymbolsSection(_ symbols: [MachOLoadMetadata.ImportedSymbol]) -> some View {
        section("Imported Symbols (\(symbols.count))", systemImage: "arrow.down.doc") {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                    Text(symbol.name)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: Lumen.Space.s5) {
                        Text(symbol.libraryName ?? "—")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if symbol.isWeak {
                            Text("weak").font(.caption2).foregroundStyle(.lumen(.statusWarning))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func dependentDylibsSection(_ dylibs: [MachOLoadMetadata.DependentDylib]) -> some View {
        section("Dependencies (\(dylibs.count))", systemImage: "building.2") {
            ForEach(Array(dylibs.enumerated()), id: \.offset) { _, dylib in
                VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                    Text(dylib.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: Lumen.Space.s5) {
                        Text(dylib.kind).font(.caption2).foregroundStyle(.secondary)
                        Text("current \(dylib.currentVersion)").font(.caption2).foregroundStyle(.tertiary)
                        Text("compat \(dylib.compatibilityVersion)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder _ content: () -> Content) -> some View {
        Group {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lumenNeverTruncates(title)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, Lumen.Space.s5)
            Group { content() }
                .padding(.leading, Lumen.Space.s5)
        }
    }

    private func keyValueRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toneColor(_ tone: ApplicationImageGraphPresentation.Tone) -> Color {
        switch tone {
        case .success:
            Color.lumen(.statusSuccess)
        case .secondary:
            Color.lumen(.statusNeutral)
        case .warning:
            Color.lumen(.statusWarning)
        }
    }

    /// Contrast-verified backgrounds for the tone text above (>= 4.5:1 in every theme).
    private func toneBackground(_ tone: ApplicationImageGraphPresentation.Tone) -> Color {
        switch tone {
        case .success: Color.lumen(.statusSuccessBackground)
        case .secondary: Color.lumen(.statusNeutralBackground)
        case .warning: Color.lumen(.statusWarningBackground)
        }
    }
}

struct ApplicationImageGraphPresentation: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case success
        case secondary
        case warning
    }

    struct SummaryRow: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let value: String
        let tone: Tone
    }

    struct NodeRow: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let path: String?
        let edgeSummary: String
    }

    struct EdgeRow: Identifiable, Equatable, Sendable {
        let id: String
        let sourceTitle: String
        let targetTitle: String
        let rawPath: String
        let loadKind: String
        let ordinal: Int
        let resolutionTitle: String
        let tone: Tone
    }

    struct UnresolvedRow: Identifiable, Equatable, Sendable {
        let id: String
        let sourceToTarget: String
        let rawPath: String
        let reason: String
    }

    let summaryText: String
    let resolutionRows: [SummaryRow]
    let workspaceRows: [NodeRow]
    let edgeRows: [EdgeRow]
    let unresolvedRows: [UnresolvedRow]

    init(graph: ApplicationImageGraph) {
        let resolvedCount = graph.edges.filter(\.isResolvedWorkspaceImage).count
        let externalCount = graph.edges.filter(\.isExternal).count
        let unresolvedCount = graph.edges.filter(\.isUnresolved).count
        summaryText = "\(graph.nodes.count) image node\(graph.nodes.count == 1 ? "" : "s"), \(graph.edges.count) declared dependenc\(graph.edges.count == 1 ? "y" : "ies")"
        resolutionRows = [
            SummaryRow(id: "resolved", label: "resolved", value: "\(resolvedCount)", tone: .success),
            SummaryRow(id: "external", label: "external", value: "\(externalCount)", tone: .secondary),
            SummaryRow(id: "unresolved", label: "unresolved", value: "\(unresolvedCount)", tone: unresolvedCount == 0 ? .secondary : .warning),
        ]

        let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let outgoingCounts = Dictionary(grouping: graph.edges, by: \.fromSlot)
            .mapValues(\.count)
        workspaceRows = graph.nodes.compactMap { node in
            guard case let .workspaceImage(slot) = node.kind else { return nil }
            let count = outgoingCounts[slot, default: 0]
            return NodeRow(
                id: node.id,
                title: node.displayName,
                path: node.path,
                edgeSummary: "\(count) outgoing"
            )
        }

        edgeRows = graph.edges.map { edge in
            let source = Self.sourceTitle(for: edge.fromSlot, in: graph)
            let target = nodesByID[edge.toNodeID]?.displayName ?? edge.rawPath
            return EdgeRow(
                id: edge.id,
                sourceTitle: source,
                targetTitle: target,
                rawPath: edge.rawPath,
                loadKind: edge.loadKind,
                ordinal: edge.ordinal,
                resolutionTitle: Self.resolutionTitle(edge.resolution),
                tone: Self.tone(for: edge.resolution)
            )
        }

        unresolvedRows = graph.edges.compactMap { edge in
            guard case .unresolved = edge.resolution else { return nil }
            let source = Self.sourceTitle(for: edge.fromSlot, in: graph)
            let target = nodesByID[edge.toNodeID]?.displayName ?? edge.rawPath
            return UnresolvedRow(
                id: edge.id,
                sourceToTarget: "\(source) → \(target)",
                rawPath: edge.rawPath,
                reason: Self.unresolvedReason(for: edge.rawPath)
            )
        }
    }
}

private extension ApplicationImageGraph.Edge {
    var isResolvedWorkspaceImage: Bool {
        if case .resolvedWorkspaceImage = resolution { return true }
        return false
    }

    var isExternal: Bool {
        if case .external = resolution { return true }
        return false
    }

    var isUnresolved: Bool {
        if case .unresolved = resolution { return true }
        return false
    }
}

private extension ApplicationImageGraphPresentation {
    static func sourceTitle(
        for slot: ImageSlot,
        in graph: ApplicationImageGraph
    ) -> String {
        graph.nodes.first { $0.kind == .workspaceImage(slot: slot) }?.displayName
            ?? "Image \(slot.rawValue)"
    }

    static func resolutionTitle(_ resolution: ApplicationImageGraph.Edge.Resolution) -> String {
        switch resolution {
        case .resolvedWorkspaceImage:
            "resolved in workspace"
        case .external:
            "external"
        case .unresolved:
            "unresolved"
        }
    }

    static func tone(for resolution: ApplicationImageGraph.Edge.Resolution) -> Tone {
        switch resolution {
        case .resolvedWorkspaceImage:
            .success
        case .external:
            .secondary
        case .unresolved:
            .warning
        }
    }

    static func unresolvedReason(for rawPath: String) -> String {
        if rawPath.hasPrefix("@") {
            return "Tokenized loader path; v0 does not resolve @rpath/@loader_path."
        }
        return "No unambiguous loaded workspace image matches this path."
    }
}
