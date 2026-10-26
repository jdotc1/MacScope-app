import Foundation

enum NativeDecompilerAccessibilityIdentifiers {
    static let status = "native.status"
    static let statusValue = "native.status.value"
    static let request = "native.action.request"
    static let retry = "native.action.retry"
    static let refresh = "native.action.refresh"
    static let cancel = "native.action.cancel"
    static let sourceSegmented = "native.source.segmented"
    static let sourceMenu = "native.source.menu"
    static let document = "native.document"
    static let tokenSourceAction = "native.token.sourceAction"
    static let tokenSourceChooser = "native.token.sourceChooser"
    static let tokenEntityDetail = "native.token.entityDetail"
    static let comparison = "native.comparison"
    static let comparisonInstructions = "native.comparison.instructions"
    static let comparisonBlocks = "native.comparison.blocks"
    static let comparisonEdges = "native.comparison.edges"
    static let comparisonCalls = "native.comparison.calls"

    static let all = [
        status,
        statusValue,
        request,
        retry,
        refresh,
        cancel,
        sourceSegmented,
        sourceMenu,
        document,
        documentLine(1),
        tokenSourceAction,
        tokenSourceChooser,
        tokenEntityDetail,
        comparison,
        comparisonInstructions,
        comparisonBlocks,
        comparisonEdges,
        comparisonCalls,
    ]

    static func documentLine(_ oneBasedLine: Int) -> String {
        "native.document.line.\(oneBasedLine)"
    }

    static func action(_ command: NativeDecompilerControlCommand) -> String {
        switch command {
        case .request: request
        case .retry: retry
        case .refresh: refresh
        case .cancel: cancel
        }
    }

    static func comparisonRow(_ category: NativeDecompilerComparisonCategory) -> String {
        switch category {
        case .instructions: comparisonInstructions
        case .blocks: comparisonBlocks
        case .edges: comparisonEdges
        case .calls: comparisonCalls
        }
    }
}

/// Pure production projection for focused editor, inspector, and graph accessibility. SwiftUI's private
/// macOS accessibility proxies are not stable unit-test objects, so the views and focused tests
/// share this exact formatter rather than re-deriving owner-sensitive wording on either side.
enum FocusedPresentationAccessibility {
    struct InspectorPresentation: Equatable {
        let label: String
        /// Inspector detail remains on independently reachable descendants. Supplying no
        /// container value prevents VoiceOver from announcing the same summary twice.
        let value: String?
    }

    struct BreakpointGutterControlPresentation: Equatable {
        let label: String
        let hint: String
        let help: String
        let identifier: String
    }

    struct NativeStatusPresentation: Equatable {
        let label: String
        let value: String
    }

    enum NativeSourceSelectorMode: Equatable {
        case segmented
        case compactMenu
    }

    struct NativeSourceSelectorPresentation: Equatable {
        let label: String
        let value: String
        let hint: String
    }

    struct NativeComparisonRowPresentation: Equatable {
        let label: String
        let value: String
        let combinesChildren: Bool
    }

    struct NativeFailureAccessibilityPresentation: Equatable {
        let label: String
        let hint: String
        let primaryAction: NativeDecompilerFailureAction?
        let secondaryAction: NativeDecompilerFailureAction?
    }

    static func nativeStatus(
        state: NativeDecompilerLayeredPresentationState,
        usesMacScopeFallback: Bool
    ) -> NativeStatusPresentation {
        let intent: String
        switch state.intent {
        case .none: intent = "No intent"
        case .request: intent = "Request"
        case .retry: intent = "Retry"
        case .refresh: intent = "Refresh"
        }

        let attempt: String
        switch state.attempt {
        case .none: attempt = state.content == nil ? "Idle" : "Ready"
        case .preparing: attempt = "Preparing"
        case .queued: attempt = "Queued"
        case .running: attempt = "Running"
        case .cancelling: attempt = "Cancelling"
        }

        let origin: String
        let completeness: String
        let mapping: String
        if let content = state.content {
            origin = content.origin == .cache ? "Cached" : "Live"
            if content.completeness == .truncated {
                completeness = "Truncated"
            } else {
                completeness = "Complete"
            }
            switch content.mappingState {
            case .verified: mapping = "Token mapping verified"
            case .degraded: mapping = "Plain text"
            }
        } else {
            origin = "No content"
            completeness = "No document"
            mapping = "No token mapping"
        }

        let notice: String
        switch state.notice {
        case .none:
            notice = "No notice"
        case .cancelled:
            notice = "Cancelled"
        case let .failure(failure):
            notice = "Failure: \(failure.title)"
        case let .unavailable(failure):
            notice = "Unavailable: \(failure.title)"
        }

        return NativeStatusPresentation(
            label: "Native pseudocode status",
            value: [
                intent,
                attempt,
                origin,
                completeness,
                mapping,
                usesMacScopeFallback ? "Fallback disclosed" : "No fallback",
                notice,
            ].joined(separator: ", ")
        )
    }

    static func nativeAnnouncement(
        from previous: NativeDecompilerLayeredPresentationState,
        to current: NativeDecompilerLayeredPresentationState,
        usesMacScopeFallback: Bool
    ) -> String? {
        guard previous != current else { return nil }

        switch current.notice {
        case .cancelled:
            return "Native decompilation cancelled"
        case let .failure(failure):
            if current.content != nil {
                return "Native refresh failed; prior native content retained"
            }
            return failure.accessibilityLabel
        case let .unavailable(failure):
            return failure.accessibilityLabel
        case .none:
            break
        }

        switch current.attempt {
        case .queued:
            return "Native decompilation queued"
        case .running:
            return "Native decompilation running"
        case .none where current.content != nil:
            return "Native decompilation ready"
        case .preparing, .cancelling, .none:
            return usesMacScopeFallback ? "MacScope fallback disclosed" : nil
        }
    }

    static func nativeSourceSelector(
        source: PseudocodeSource,
        mode: NativeSourceSelectorMode
    ) -> NativeSourceSelectorPresentation {
        let hint: String
        switch mode {
        case .segmented:
            hint = "Choose Native, MacScope, or Compare with the segmented control."
        case .compactMenu:
            hint = "Open the source menu to choose Native, MacScope, or Compare."
        }
        return NativeSourceSelectorPresentation(
            label: "Pseudocode source",
            value: source.rawValue,
            hint: hint
        )
    }

    static func nativeComparisonRow(
        _ result: NativeDecompilerComparisonCategoryResult
    ) -> NativeComparisonRowPresentation {
        let category: String
        switch result.category {
        case .instructions: category = "Instructions"
        case .blocks: category = "Blocks"
        case .edges: category = "Edges"
        case .calls: category = "Calls"
        }
        let uncomparable = result.counts.uncomparableNativeCount
            + result.counts.uncomparableMacScopeCount
        let coverage: String
        switch result.coverage {
        case .complete: coverage = "Complete coverage"
        case .partial: coverage = "Partial coverage"
        case .none: coverage = "No coverage"
        }
        let correspondence: String
        switch result.correspondence {
        case .exact: correspondence = "Exact correspondence"
        case .divergent: correspondence = "Divergent correspondence"
        case .noComparableRecords: correspondence = "No comparable records"
        }
        return NativeComparisonRowPresentation(
            label: "\(category) structural summary",
            value: [
                "\(result.counts.matchedCount) matched",
                "\(result.counts.nativeOnlyCount) native only",
                "\(result.counts.macScopeOnlyCount) MacScope only",
                "\(uncomparable) uncomparable",
                coverage,
                correspondence,
            ].joined(separator: ", "),
            combinesChildren: true
        )
    }

    static func nativeFailure(
        _ failure: NativeDecompilerFailurePresentation
    ) -> NativeFailureAccessibilityPresentation {
        NativeFailureAccessibilityPresentation(
            label: failure.accessibilityLabel,
            hint: failure.accessibilityHint,
            primaryAction: failure.primaryAction,
            secondaryAction: failure.secondaryAction
        )
    }

    static func editorSelection(
        snapshot: WorkspaceSnapshot,
        target: ImageAddress?,
        liveProgramCounter: ImageAddress?,
        breakpointGutter: DebuggerLogicalBreakpointGutterPresentation? = nil
    ) -> String {
        guard let target else {
            return "No selection"
        }

        let ownerName = snapshot.binaries.count > 1
            ? snapshot.binary(in: target.slot)?.name
            : nil
        guard let instruction = snapshot.instruction(at: target) else {
            return [ownerName, "selected address \(target.address.hexAddress)"]
                .compactMap { $0 }
                .joined(separator: ", ")
        }

        // Resolve only the selected row (as the listing does), not the whole image's listing.
        let rowState: DisassemblyListingBuilder.ResolvedInstruction? = DisassemblyListingBuilder.resolvedInstruction(
            instruction,
            snapshot: snapshot,
            slot: target.slot,
            programCounterRow: liveProgramCounter?.slot == target.slot
                ? DisassemblyListingBuilder.liveProgramCounterRowAddress(
                    snapshot: snapshot, programCounter: liveProgramCounter?.address, slot: target.slot)
                : nil
        )
        let displayed: (mnemonic: String, operands: String)
        if rowState?.isUndefined == true {
            let directive = rowState?.undefinedDirective ?? {
                let raw = WorkspaceSnapshot.dataDirective(forBytes: instruction.bytes)
                return DataDirective(
                    mnemonic: raw.mnemonic,
                    operands: raw.operands + "  ; undefined"
                )
            }()
            displayed = (directive.mnemonic, directive.operands)
        } else if rowState?.isData == true || snapshot.isData(at: target) {
            if let directive = rowState?.shapeDirective {
                displayed = (directive.mnemonic, directive.operands)
            } else {
                displayed = WorkspaceSnapshot.dataDirective(forBytes: instruction.bytes)
            }
        } else {
            let operands = rowState?.operandFormat.map {
                OperandFormat.apply(to: instruction.operands, format: $0)
            } ?? instruction.operands
            displayed = (instruction.mnemonic, operands)
        }
        let operands = displayed.operands.isEmpty ? "no operands" : displayed.operands

        var components: [String] = []
        if let ownerName {
            components.append(ownerName)
        }
        components.append(contentsOf: [instruction.address.hexAddress, displayed.mnemonic, operands])
        if let breakpointGutter,
           let summary = breakpointRowSummary(breakpointGutter) {
            components.append(summary)
        } else if instruction.hasBreakpoint {
            // Compatibility for pure callers that have not supplied the durable projection. The
            // installed editor always supplies `breakpointGutter`, so legacy instruction bits are
            // never runtime presentation authority.
            components.append("breakpoint set")
        }
        if let comment = DisassemblyListingBuilder.resolvedComment(
            snapshot: snapshot,
            instruction: instruction,
            slot: target.slot
        ), !comment.isEmpty {
            components.append("comment: \(comment)")
        }
        if let tag = rowState?.tag, !tag.isEmpty {
            components.append("tag \(tag)")
        }
        if let colorTag = rowState?.colorTag {
            components.append("\(colorTag.displayName) highlight")
        }
        if rowState?.isPatched == true {
            components.append("patched")
        }
        if rowState?.isLiveProgramCounter == true {
            components.append("current program counter")
        }
        if let source = snapshot.sourceLine(at: target) {
            let location = source.file.map { "\($0):\(source.line)" } ?? "line \(source.line)"
            components.append("source \(location)")
        }
        return components.joined(separator: ", ")
    }

    static func breakpointGutterControl(
        _ gutter: DebuggerLogicalBreakpointGutterPresentation,
        target: ImageAddress,
        isCatalogAvailable: Bool
    ) -> BreakpointGutterControlPresentation {
        let hint: String
        if !isCatalogAvailable {
            hint = "Open the Breakpoints deck and repair the unavailable catalog before authoring."
        } else {
            switch gutter.action {
            case .set:
                hint = "Creates a saved logical breakpoint qualified to this exact image."
            case .remove:
                hint = "Removes this saved logical breakpoint from the workspace."
            case .manage(let count):
                hint = "Opens the Breakpoints deck to manage \(count) saved logical breakpoints at this location."
            }
        }
        return BreakpointGutterControlPresentation(
            label: gutter.accessibilityLabel,
            hint: hint,
            help: "\(gutter.accessibilityLabel). \(hint)",
            identifier: [
                "disassembly",
                "breakpoint",
                String(target.slot.rawValue),
                String(format: "%016llx", target.address),
            ].joined(separator: ".")
        )
    }

    static func breakpointRowSummary(
        _ gutter: DebuggerLogicalBreakpointGutterPresentation
    ) -> String? {
        if gutter.stateDescription == "Breakpoint catalog unavailable" {
            return "breakpoint catalog unavailable, no saved breakpoint is armed"
        }
        guard gutter.logicalBreakpointCount > 0 else { return nil }
        let breakpointNoun = gutter.logicalBreakpointCount == 1
            ? "logical breakpoint" : "logical breakpoints"
        let locationNoun = gutter.locationCount == 1
            ? "proven runtime location" : "proven runtime locations"
        return [
            "\(gutter.logicalBreakpointCount) \(breakpointNoun)",
            gutter.stateDescription,
            "\(gutter.locationCount) \(locationNoun)",
        ].joined(separator: ", ")
    }

    static func inspector(
        snapshot: WorkspaceSnapshot,
        focusedSlot: ImageSlot,
        target: ImageAddress?
    ) -> InspectorPresentation {
        let ownerName = snapshot.binaries.count > 1
            ? snapshot.binary(in: target?.slot ?? focusedSlot)?.name
            : nil
        let label = AppAccessibilityText.inspectorLabel(
            selectionAddress: target?.address.hexAddress,
            imageName: ownerName,
            isInstruction: target.map { snapshot.instruction(at: $0) != nil } ?? false
        )
        return InspectorPresentation(label: label, value: nil)
    }

    static func inspectorEmptySelectionDetail(hasSelectedAddress: Bool) -> String {
        if hasSelectedAddress {
            return "Selected address has no decoded instruction. Address details remain available below."
        }
        return "Select an instruction to inspect bytes, operands, xrefs, and debugger context."
    }

    // MARK: - Focused graph

    static func graphCanvasLabel(binaryName: String?) -> String {
        binaryName.map { "Control-flow graph, \($0)" } ?? "Control-flow graph"
    }

    static let graphCanvasHint =
        "Use arrow keys to move between graph nodes. Command-click nodes to multi-select, "
            + "then apply a color. Select an edge label to inspect that connection."

    static func graphMinimapLabel(binaryName: String?) -> String {
        binaryName.map { "Graph minimap, \($0)" } ?? "Graph minimap"
    }

    static func graphMinimapValue(binaryName: String?, visibleWidthPercent: Int) -> String {
        if let binaryName {
            return "Showing \(visibleWidthPercent) percent of the \(binaryName) graph width"
        }
        return "Showing \(visibleWidthPercent) percent of the graph width"
    }

    static func graphOverviewLabel(
        binaryName: String?,
        layout: FocusedGraphModel,
        selectedAddress: ImageAddress?,
        selectedGraphElementID: String?
    ) -> String {
        let summary: String
        if let selectedGraphElementID,
           let selectedEdge = layout.edges.first(where: { $0.id == selectedGraphElementID }) {
            summary = "\(selectedEdge.label.capitalized) edge: "
                + "\(selectedEdge.fromAddress.hexAddress) -> \(selectedEdge.toAddress.hexAddress)"
        } else if let selectedAddress,
                  let node = layout.nodes.first(where: { $0.contains(selectedAddress) }) {
            summary = "\(selectedAddress.address.hexAddress) in \(node.displayTitle)"
        } else if let selectedAddress {
            summary = "\(selectedAddress.address.hexAddress) outside visible graph nodes"
        } else {
            summary = "No selected block"
        }
        return binaryName.map { "\($0), \(summary)" } ?? summary
    }

    static func graphOverviewValue(binaryName: String?, layout: FocusedGraphModel) -> String {
        let counts = "\(layout.sections.count) functions, "
            + "\(layout.nodes.count) nodes, \(layout.edges.count) edges"
        return binaryName.map { "\($0) graph, \(counts)" } ?? counts
    }

    static func graphEdgeLabel(binaryName: String?, edge: GraphEdgeModel) -> String {
        binaryName.map { "\($0), \(edge.accessibilityText)" } ?? edge.accessibilityText
    }

    static func graphNodeLabel(binaryName: String?, node: GraphNodeModel) -> String {
        var label = [binaryName, node.kind.displayName, node.displayTitle, node.addressRangeText]
            .compactMap { $0 }
            .joined(separator: ", ")
        if let tag = node.tag, !tag.isEmpty {
            label += ", tag \(tag)"
        }
        if let colorTag = node.colorTag {
            label += ", \(colorTag.displayName) highlight"
        }
        return label
    }

    static func graphNodeHelp(binaryName: String?, node: GraphNodeModel) -> String {
        let detail = "\(node.kind.displayName.capitalized) "
            + "\(node.displayTitle), \(node.addressRangeText)"
        return binaryName.map { "\($0), \(detail)" } ?? detail
    }

    static func graphNodeValue(binaryName: String?, isMultiSelected: Bool) -> String {
        guard isMultiSelected else { return "" }
        return binaryName.map { "Grouped in \($0)" } ?? "Grouped"
    }

    static func graphNodeGroupActionLabel(isMultiSelected: Bool) -> String {
        isMultiSelected ? "Remove from color group" : "Add to color group"
    }

    static func graphGroupSelectionLabel(binaryName: String?, selectionCount: Int) -> String {
        let label = "\(selectionCount) nodes selected"
        return binaryName.map { "\(label) in \($0)" } ?? label
    }

    static func graphGroupToolsLabel(binaryName: String?) -> String {
        binaryName.map { "Node group color tools, \($0)" } ?? "Node group color tools"
    }
}
