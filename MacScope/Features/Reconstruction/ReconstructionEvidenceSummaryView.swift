import SwiftUI
import LumenUI

struct ReconstructionEvidenceSummaryView: View {
    let summary: ReconstructionEvidenceSummary
    let currentGap: ReconstructionStatusGapProjection?

    var body: some View {
        ReconstructionSummaryCard(title: "Evidence", systemImage: "checkmark.seal") {
            VStack(alignment: .leading, spacing: Lumen.Space.s6) {
                ReconstructionMetricGrid(metrics: [
                    .init(title: "Current", value: summary.currentCount),
                    .init(title: "Historical", value: summary.historicalCount),
                    .init(title: "Stale", value: summary.staleCount),
                    .init(title: "Unavailable", value: summary.unavailableCount)
                ])

                if let currentGap {
                    Divider()
                    VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                        Text("Current unresolved gap")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(currentGap.operationID)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(currentGap.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
