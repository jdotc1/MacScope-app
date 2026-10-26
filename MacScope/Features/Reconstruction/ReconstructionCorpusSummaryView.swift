import SwiftUI
import LumenUI

struct ReconstructionCorpusSummaryView: View {
    let summary: ReconstructionCorpusSummary

    var body: some View {
        ReconstructionSummaryCard(title: "Corpus", systemImage: "shippingbox") {
            ReconstructionMetricGrid(metrics: [
                .init(title: "Occurrences", value: summary.occurrenceCount),
                .init(title: "Unique content", value: summary.uniqueContentCount),
                .init(title: "Relations", value: summary.relationCount),
                .init(title: "Unresolved", value: summary.unresolvedRelationCount)
            ])
        }
        .accessibilityLabel(
            "Corpus, \(summary.occurrenceCount) occurrences, "
                + "\(summary.uniqueContentCount) unique content items, "
                + "\(summary.unresolvedRelationCount) unresolved relations"
        )
    }
}

struct ReconstructionSummaryMetric: Identifiable {
    let title: String
    let value: Int
    var id: String { title }
}

struct ReconstructionMetricGrid: View {
    let metrics: [ReconstructionSummaryMetric]

    private let columns = [
        GridItem(.flexible(), alignment: .leading),
        GridItem(.flexible(), alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Lumen.Space.s5) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                    Text(metric.value, format: .number)
                        .font(.title3.monospacedDigit().weight(.semibold))
                    Text(metric.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ReconstructionSummaryCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(Lumen.Space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .workbenchSurface(radius: Lumen.Radius.lg)
    }
}
