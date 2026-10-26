import SwiftUI
import LumenTokens
import LumenUI

enum NativeDecompilerEditorComposition {
    /// One band for status and actions, at Lumen's status-strip height.
    static let statusBandHeight: CGFloat = DSStatusStripMetrics.height
    static let persistentStatusAndActionBandCount = 1
    static let visibleCommands: [NativeDecompilerControlCommand] = [
        .request,
        .retry,
        .refresh,
        .cancel,
    ]
    static let structuralRows: [NativeDecompilerComparisonCategory] = [
        .instructions,
        .blocks,
        .edges,
        .calls,
    ]
}

struct NativeDecompilerStatusBandLayout: Equatable {
    enum MetadataVisibility: Equatable {
        case expanded
        case collapsed
    }

    let commands: [NativeDecompilerControlCommand]
    let metadataVisibility: MetadataVisibility
    let providerDisplay: String?
    let failureTitle: String?

    static func project(
        availableWidth: CGFloat,
        providerDisplay: String?,
        failure: NativeDecompilerFailurePresentation?
    ) -> Self {
        let metadataVisibility: MetadataVisibility = availableWidth >= 720
            ? .expanded
            : .collapsed
        return Self(
            commands: NativeDecompilerEditorComposition.visibleCommands,
            metadataVisibility: metadataVisibility,
            providerDisplay: providerDisplay.map(Self.boundedProviderDisplay),
            failureTitle: failure?.title
        )
    }

    private static func boundedProviderDisplay(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let candidate = result + String(scalar)
            guard candidate.utf8.count <= 64 else { break }
            result = candidate
        }
        return result
    }
}

struct NativeStatusStripAccessibilityFacts: Equatable {
    let status: String
    let provider: String?
    let isTruncated: Bool
    let isPlainText: Bool
    let fallbackDescription: String?
    let failureTitle: String?
}

struct NativeStatusStripAccessibilityPresentation: Equatable {
    let label: String
    let value: String
}

enum NativeStatusStripAccessibilityProjection {
    static func project(
        _ facts: NativeStatusStripAccessibilityFacts
    ) -> NativeStatusStripAccessibilityPresentation {
        var components = [facts.status]
        if let provider = facts.provider {
            components.append(provider)
        }
        if facts.isTruncated {
            components.append("Truncated")
        }
        if facts.isPlainText {
            components.append("Plain text")
        }
        if let fallbackDescription = facts.fallbackDescription {
            components.append("MacScope fallback: \(fallbackDescription)")
        }
        if let failureTitle = facts.failureTitle {
            components.append("Failure: \(failureTitle)")
        }
        return NativeStatusStripAccessibilityPresentation(
            label: "Native pseudocode status",
            value: components.joined(separator: ", ")
        )
    }
}

struct NativePseudocodeView: View {
    let presentation: NativePseudocodePresentation
    var enabledCommands: Set<NativeDecompilerControlCommand> = []
    var onCommand: (NativeDecompilerControlCommand) -> Void = { _ in }
    var onSourceAction: (NativePseudocodeSourceRequest) -> Void = { _ in }
    var onEntityDetail: (NativePseudocodeEntityDetail) -> Void = { _ in }
    var onValueAction: (NativePseudocodeValueRequest) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            NativePseudocodeStatusStrip(
                presentation: presentation,
                enabledCommands: enabledCommands,
                onCommand: onCommand
            )

            Divider()

            if let document = presentation.document {
                nativeListing(document)
            } else {
                nativeState
            }
        }
    }

    private func nativeListing(
        _ document: NativeDecompilerDocumentProjection
    ) -> some View {
        NativePseudocodeTextView(
            document: document,
            onSourceAction: onSourceAction,
            onEntityDetail: onEntityDetail,
            onValueAction: onValueAction
        )
        .accessibilityLabel("Native pseudocode")
        .accessibilityIdentifier(NativeDecompilerAccessibilityIdentifiers.document)
        .help("Press Return to reveal a token's source. Option-Return or the context menu opens recovered entity details.")
    }

    @ViewBuilder
    private var nativeState: some View {
        switch presentation.status {
        case .analyzing:
            LoadingStateView(
                title: "Decompiling function",
                detail: "The native decompiler is analyzing the current image and function."
            )
        case .idle:
            EmptyStateView(
                title: "Native decompilation pending",
                detail: "Load and analyze a function to produce native pseudocode.",
                systemImage: "text.page.badge.magnifyingglass"
            )
        case .unavailable:
            EmptyStateView(
                title: presentation.failurePresentation?.title
                    ?? "Native decompiler unavailable",
                detail: fallbackDetail,
                systemImage: "exclamationmark.shield"
            )
        case .failed:
            ErrorStateView(
                title: presentation.failurePresentation?.title
                    ?? "Native decompilation failed",
                detail: fallbackDetail,
                recovery: presentation.failurePresentation?.accessibilityHint
                    ?? "MacScope pseudocode remains available when the current analysis can be rendered."
            )
        case .stale:
            EmptyStateView(
                title: "Native result no longer matches",
                detail: "The selected image or function changed. Waiting for a matching native result.",
                systemImage: "arrow.triangle.2.circlepath"
            )
        case .ready:
            EmptyStateView(
                title: "Native document unavailable",
                detail: "The native result did not contain a displayable pseudocode document.",
                systemImage: "doc.questionmark"
            )
        }
    }

    private var fallbackDetail: String {
        presentation.failurePresentation?.explanation
            ?? "No native pseudocode is available for the current function."
    }
}

/// Shared status strip used above native output and above a disclosed MacScope fallback.
struct NativePseudocodeStatusStrip: View {
    let presentation: NativePseudocodePresentation
    var enabledCommands: Set<NativeDecompilerControlCommand> = []
    var onCommand: (NativeDecompilerControlCommand) -> Void = { _ in }

    var body: some View {
        let accessibility = accessibilityPresentation
        // Lumen status strip: the status as a dot and a
        // word, warning chips, icon-only commands; provider and engine move into the status help.
        DSStatusStrip(
            status: DSStripStatus(
                title: statusTitle,
                tone: statusTone,
                help: statusHelp,
                accessibilityLabel: accessibility.label,
                accessibilityValue: accessibility.value,
                accessibilityIdentifier: NativeDecompilerAccessibilityIdentifiers.statusValue
            ),
            chips: chips,
            actions: NativeDecompilerControlCommand.allCases.filter(enabledCommands.contains).map { command in
                DSStripAction(
                    id: command.title,
                    title: command.title,
                    systemImage: command.systemImage,
                    help: command.accessibilityHint,
                    accessibilityLabel: "Native decompiler \(command.title)",
                    accessibilityHint: command.accessibilityHint,
                    accessibilityIdentifier: NativeDecompilerAccessibilityIdentifiers.action(command)
                ) {
                    onCommand(command)
                }
            }
        ) {
            EmptyView()
        }
        .frame(height: NativeDecompilerEditorComposition.statusBandHeight, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
        .accessibilityIdentifier(NativeDecompilerAccessibilityIdentifiers.status)
    }

    private var chips: [LumenStripChip] {
        var chips: [LumenStripChip] = []
        if presentation.document?.isTruncated == true {
            chips.append(LumenStripChip("Truncated", help: "The native document was truncated."))
        }
        if case .degraded = presentation.document?.mappingState {
            chips.append(LumenStripChip("Plain text", help: "Token mapping is unavailable; the text is shown plain."))
        }
        if presentation.structureOmitted {
            chips.append(LumenStripChip(
                "Structure omitted",
                help: "The function's structure was too large to load; only the pseudocode text is shown."
            ))
        }
        if presentation.usesMacScopeFallback {
            chips.append(LumenStripChip("Fallback", help: fallbackDescription))
        }
        return chips
    }

    private var statusHelp: String {
        guard let provider = presentation.provider else { return statusTitle }
        return "\(statusTitle) · \(provider.backendID), engine \(provider.engineVersion)"
    }

    private var statusTone: LumenToken {
        switch presentation.status {
        case .ready: .statusSuccess
        case .failed: .statusDanger
        case .unavailable, .stale: .statusWarning
        case .idle, .analyzing: .fgTertiary
        }
    }

    private var accessibilityPresentation: NativeStatusStripAccessibilityPresentation {
        let provider = presentation.provider.map {
            "\($0.backendID), engine \($0.engineVersion)"
        }
        return NativeStatusStripAccessibilityProjection.project(
            NativeStatusStripAccessibilityFacts(
                status: statusTitle,
                provider: provider,
                isTruncated: presentation.document?.isTruncated == true,
                isPlainText: {
                    if case .degraded = presentation.document?.mappingState {
                        return true
                    }
                    return false
                }(),
                fallbackDescription: presentation.usesMacScopeFallback
                    ? fallbackDescription : nil,
                failureTitle: presentation.failurePresentation?.title
            )
        )
    }

    private var statusTitle: String {
        switch presentation.status {
        case .idle: "Pending"
        case .analyzing: "Analyzing"
        case .ready: "Ready"
        case .unavailable: "Unavailable"
        case .failed: "Failed"
        case .stale: "Stale"
        }
    }

    private var fallbackDescription: String {
        guard let reason = presentation.fallbackReason else {
            return "The native source is unavailable."
        }
        switch reason {
        case let .terminal(terminalReason):
            return NativeDecompilerFailureCatalog.presentation(for: terminalReason).explanation
        case .idle:
            return "Native decompilation has not started for the current function."
        case .staleResult:
            return "The prior native result no longer matches the current image and function."
        case .missingDocument:
            return "The native result did not contain a displayable pseudocode document."
        }
    }
}
