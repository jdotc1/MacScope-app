import SwiftUI
import LumenUI

struct ReconstructionProgressSummaryView: View {
    let summary: ReconstructionProgressSummary

    var body: some View {
        ReconstructionSummaryCard(title: "Progress", systemImage: "chart.bar") {
            VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                ProgressView(value: summary.completedFraction)
                    .accessibilityLabel("Reconstruction task completion")
                    .accessibilityValue(
                        "\(summary.completedTaskCount) of \(summary.totalTaskCount) tasks completed"
                    )

                ReconstructionMetricGrid(metrics: [
                    .init(title: "Pending", value: summary.pendingTaskCount),
                    .init(title: "Running", value: summary.runningTaskCount),
                    .init(title: "Completed", value: summary.completedTaskCount),
                    .init(title: "Failed", value: summary.failedTaskCount),
                    .init(title: "Blocked", value: summary.blockedTaskCount)
                ])
                .accessibilityRepresentation {
                    Text(verbatim: progressAccessibilityValue)
                        .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.progress)
                        .accessibilityLabel("Reconstruction progress")
                        .accessibilityValue(progressAccessibilityValue)
                }
            }
        }
    }

    private var progressAccessibilityValue: String {
        "\(summary.completedTaskCount) of \(summary.totalTaskCount) tasks completed; "
            + "\(summary.pendingTaskCount) pending, \(summary.runningTaskCount) running, "
            + "\(summary.completedTaskCount) completed, \(summary.failedTaskCount) failed, "
            + "\(summary.blockedTaskCount) blocked"
    }
}
