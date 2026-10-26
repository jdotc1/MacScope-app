import SwiftUI
import LumenUI

struct DecompilerComparisonView: View {
    let projection: DecompilerComparisonProjection
    var onShowNative: (() -> Void)? = nil

    var body: some View {
        switch projection {
        case let .ready(comparison):
            VStack(spacing: 0) {
                comparisonHeader(comparison)
                Divider()
                comparisonRows(comparison)
            }
            .accessibilityIdentifier(NativeDecompilerAccessibilityIdentifiers.comparison)
        case let .unavailable(reason):
            EmptyStateView(
                title: "Comparison unavailable",
                detail: unavailableDescription(reason),
                systemImage: "rectangle.split.2x1"
            )
        }
    }

    private func comparisonHeader(_ comparison: DecompilerComparison) -> some View {
        let divergentCount = comparison.structural.categories.filter {
            $0.correspondence == .divergent
        }.count
        let comparableCount = comparison.structural.categories.filter {
            $0.coverage != .none
        }.count
        return HStack(spacing: Lumen.Space.s5) {
            Label("Structural summary", systemImage: "rectangle.split.2x1")
                .font(.caption.weight(.semibold))

            Text("\(comparableCount) comparable · \(divergentCount) divergent")
            .font(.caption)
            .foregroundStyle(divergentCount == 0 ? .secondary : Color.lumen(.statusWarning))

            Spacer(minLength: Lumen.Space.s5)

            if let onShowNative {
                Button("View Native Pseudocode", action: onShowNative)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("native.comparison.showNative")
            }

            Text("Identity-qualified · no text diff")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Lumen.Space.s7)
        .frame(height: AppEditorChrome.hexStatusBarHeight, alignment: .center)
        .workbenchPaneBackground(.toolbar)
    }

    private func comparisonRows(_ comparison: DecompilerComparison) -> some View {
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(NativeDecompilerEditorComposition.structuralRows, id: \.self) { category in
                    if let result = comparison.structural.categories.first(where: {
                        $0.category == category
                    }) {
                        let accessibility = FocusedPresentationAccessibility.nativeComparisonRow(result)
                        HStack(spacing: Lumen.Space.s7) {
                            Text(categoryLabel(result.category))
                                .font(.body.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            comparisonValue("Matched", value: result.counts.matchedCount)
                            comparisonValue("Native only", value: result.counts.nativeOnlyCount)
                            comparisonValue("MacScope only", value: result.counts.macScopeOnlyCount)

                            Image(systemName: correspondenceSymbol(result.correspondence))
                                .foregroundStyle(correspondenceColor(result.correspondence))
                                .frame(width: 18)
                        }
                        .accessibilityElement(children: accessibility.combinesChildren ? .combine : .contain)
                        .accessibilityLabel(accessibility.label)
                        .accessibilityValue(accessibility.value)
                        .accessibilityIdentifier(
                            NativeDecompilerAccessibilityIdentifiers.comparisonRow(category)
                        )
                        .padding(.horizontal, Lumen.Space.s7)
                        .frame(minHeight: 42)
                        .background(
                            result.correspondence == .divergent
                                ? Color.lumen(.statusWarningBackground) : Color.clear
                        )
                    } else {
                        HStack {
                            Text(categoryLabel(category))
                            Spacer()
                            Text("Unavailable")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(categoryLabel(category)) structural summary")
                        .accessibilityValue("Unavailable")
                        .accessibilityIdentifier(
                            NativeDecompilerAccessibilityIdentifiers.comparisonRow(category)
                        )
                        .padding(.horizontal, Lumen.Space.s7)
                        .frame(minHeight: 42)
                    }

                    Divider()
                }
            }
        }
        .textSelection(.enabled)
    }

    private func categoryLabel(_ category: NativeDecompilerComparisonCategory) -> String {
        switch category {
        case .instructions: "Instructions"
        case .blocks: "Blocks"
        case .edges: "Edges"
        case .calls: "Calls"
        }
    }

    private func comparisonValue(_ label: String, value: Int) -> some View {
        VStack(alignment: .trailing, spacing: Lumen.Space.s2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.body.monospacedDigit())
        }
        .frame(width: 82, alignment: .trailing)
    }

    private func correspondenceSymbol(
        _ correspondence: NativeDecompilerComparisonCorrespondence
    ) -> String {
        switch correspondence {
        case .exact: "checkmark"
        case .divergent: "exclamationmark.triangle"
        case .noComparableRecords: "minus"
        }
    }

    private func correspondenceColor(
        _ correspondence: NativeDecompilerComparisonCorrespondence
    ) -> Color {
        switch correspondence {
        case .exact: Color.lumen(.statusSuccess)
        case .divergent: Color.lumen(.statusWarning)
        case .noComparableRecords: .secondary
        }
    }

    private func unavailableDescription(
        _ reason: DecompilerComparisonUnavailableReason
    ) -> String {
        switch reason {
        case .nativeUnavailable:
            "A matching native structured result is not available for this function."
        case .macScopeUnavailable:
            "MacScope analysis is not available for this function."
        case .coordinateMismatch:
            "The native result belongs to a different image, function, or analysis generation."
        case .invalidStructure:
            "The current structured records cannot be compared safely."
        }
    }
}
