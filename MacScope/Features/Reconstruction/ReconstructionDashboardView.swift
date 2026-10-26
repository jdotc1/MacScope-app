import Foundation
import SwiftUI
import LumenTokens
import LumenUI

/// Value-semantic command router shared by the native controls and focused behavioral tests.
/// It maps only the frozen five product commands and owns no durable or pending state.
struct ReconstructionDashboardCommandDispatcher {
    let onCreate: (() -> Void)?
    let onStart: (() -> Void)?
    let onPause: (() -> Void)?
    let onResume: (() -> Void)?
    let onCancel: (() -> Void)?

    func action(for command: ReconstructionCommandKind) -> (() -> Void)? {
        switch command {
        case .create: onCreate
        case .start: onStart
        case .pause: onPause
        case .resume: onResume
        case .cancel: onCancel
        }
    }

    @discardableResult
    func dispatch(_ command: ReconstructionCommandKind) -> Bool {
        guard let action = action(for: command) else { return false }
        action()
        return true
    }
}

/// A bounded, window-local notice supplied by the dashboard host. It is presentation state only:
/// no durable diagnostic, provider payload, or source-coordinate detail crosses this seam.
struct ReconstructionDashboardTransientNotice: Equatable, Sendable {
    let title: String
    let detail: String
    let tone: ReconstructionStatusTone
}

/// Native central-editor destination for one immutable reconstruction presentation cut.
/// Every mutation leaves through one of the five explicit intent closures.
struct ReconstructionDashboardView: View {
    let projection: ReconstructionStatusProjection
    let onCreate: (() -> Void)?
    let onStart: (() -> Void)?
    let onPause: (() -> Void)?
    let onResume: (() -> Void)?
    let onCancel: (() -> Void)?
    let onSelectJob: ((UUID) -> Void)?
    let onSelectTask: ((UUID) -> Void)?
    let onSelectEvidence: ((UUID) -> Void)?
    let onRevealEvidenceSource: ((UUID) -> Void)?
    let sourceNavigableEvidenceIDs: Set<UUID>
    var transientNotice: ReconstructionDashboardTransientNotice? = nil
    var onSourceExample: (() -> Void)? = nil
    var onImport: (() -> Void)? = nil
    var onCancelImport: (() -> Void)? = nil
    var onSaveBeforeImport: (() -> Void)? = nil
    var importStatus: String = "Import selected artifacts to build a reconstruction corpus."
    var importFailureDetails: [String] = []

    private let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 420), spacing: Lumen.Space.s6)
    ]

    private var commandDispatcher: ReconstructionDashboardCommandDispatcher {
        ReconstructionDashboardCommandDispatcher(
            onCreate: onCreate,
            onStart: onStart,
            onPause: onPause,
            onResume: onResume,
            onCancel: onCancel
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Lumen.Space.s7) {
                    if projection.isEmpty {
                        emptyHeader
                    } else {
                        header
                    }
                    noticePanel
                    ReconstructionCorpusImportControls(
                        onImport: onImport,
                        onCancel: onCancelImport,
                        onSave: onSaveBeforeImport,
                        status: importStatus,
                        failureDetails: importFailureDetails
                    )
                    readinessPanel

                    LazyVGrid(columns: columns, alignment: .leading, spacing: Lumen.Space.s6) {
                        ReconstructionCorpusSummaryView(summary: projection.corpus)
                            .accessibilityRepresentation {
                                Text(verbatim: corpusAccessibilityValue)
                                    .accessibilityIdentifier(
                                        ReconstructionAccessibilityIdentifiers.corpusSummary
                                    )
                                    .accessibilityLabel("Corpus summary")
                                    .accessibilityValue(corpusAccessibilityValue)
                                    .accessibilityHint(
                                        "Reports occurrence, unique-content, relation, and unresolved-"
                                            + "relation counts for the selected job."
                                    )
                            }
                        ReconstructionProgressSummaryView(summary: projection.progress)
                        ReconstructionEvidenceSummaryView(
                            summary: projection.evidence,
                            currentGap: nil
                        )
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier(
                            ReconstructionAccessibilityIdentifiers.evidenceSummary
                        )
                        .accessibilityLabel("Evidence summary")
                        .accessibilityValue(evidenceAccessibilityValue)
                        .accessibilityHint(
                            "Reports bounded current, historical, stale, and unavailable evidence "
                                + "counts for the selected job."
                        )
                    }

                    phasesPanel
                    currentGapPanel
                    detailsPanel
                }
                .padding(Lumen.Space.s8)
                .frame(maxWidth: 1_120, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                // The multi-child content owns the dashboard group. The outer single-child
                // destination may reuse the scroll view's element, so it must not own both IDs.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.dashboard)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .workbenchPaneBackground(.editor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.destination)
        .accessibilityLabel(ReconstructionStatusProjection.destinationTitle)
    }

    private var emptyHeader: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            EmptyStateView(
                title: "No reconstruction job",
                detail: "Create a bounded job from deliberately selected project items. "
                    + "The destination remains available when the local model is not ready.",
                systemImage: ReconstructionStatusProjection.destinationSymbol
            )
            .frame(maxHeight: 320)
            .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.jobIdentity)

            Text("No committed job state")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.jobState)

            commandSurface
        }
        .padding(Lumen.Space.s6)
        .workbenchSurface(radius: Lumen.Radius.lg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            HStack(alignment: .top, spacing: Lumen.Space.s6) {
                Button {
                    guard let jobID = projection.jobID else { return }
                    onSelectJob?(jobID)
                } label: {
                    VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                        Text(
                            projection.projectName
                                ?? ReconstructionStatusProjection.destinationTitle
                        )
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        if let objective = projection.objective {
                            Text(objective)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(projection.jobID == nil || onSelectJob == nil)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.jobIdentity)
                .accessibilityLabel("Reconstruction job")
                .accessibilityValue(jobAccessibilityValue)

                Spacer(minLength: Lumen.Space.s6)

                LumenBadge(projection.stateTitle, systemImage: stateSymbol, tone: stateBadgeTone)
                .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.jobState)
                .accessibilityLabel("Reconstruction job state")
                .accessibilityValue(projection.state?.rawValue ?? "No job")
                .accessibilityHint(
                    "Reports committed state; pending command intent is announced separately."
                )
            }

            Text(projection.stateDetail)
                .font(.callout)
                .foregroundStyle(.secondary)

            commandSurface

            if let revision = projection.checkpointRevision {
                if projection.checkpointFreshness.isCurrent {
                    Text("Checkpoint \(revision) is current")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Checkpoint \(revision) is not current")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.lumen(.statusWarning))
                }
            }
        }
        .padding(Lumen.Space.s6)
        .workbenchSurface(radius: Lumen.Radius.lg)
    }

    private var commandSurface: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            HStack(spacing: Lumen.Space.s4) {
                createButton
                Button("Reconstruct C Sample", systemImage: "curlybraces") { onSourceExample?() }
                    .disabled(onSourceExample == nil)
                    .help("Build a fixed C sample, reconstruct its source with the local model, and compare actual behavior. Save the workspace first.")
                    .accessibilityIdentifier("reconstruction.sourceExample")
                startButton
                pauseButton
                resumeButton
                cancelButton
                Spacer(minLength: 0)
            }
            .controlSize(.regular)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.primaryAction)
            .accessibilityLabel("Primary Reconstruction action")
            .accessibilityValue(
                "\(projection.controls.primaryAction.label); committed state "
                    + "\(projection.state?.rawValue ?? "none"); pending intent "
                    + projection.pendingIntent.kind.rawValue
            )
            .accessibilityHint(
                projection.controls.availability(for: projection.controls.primaryAction).help
            )

            if projection.pendingIntent.isPending {
                Label(
                    "Requesting \(projection.pendingIntent.kind.rawValue). "
                        + "Committed state remains \(projection.state?.rawValue ?? "absent").",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var createButton: some View {
        commandButton(.create, systemImage: "plus")
            .accessibilityIdentifier("reconstruction.create")
    }

    private var startButton: some View {
        commandButton(.start, systemImage: "play.fill")
            .accessibilityIdentifier("reconstruction.start")
    }

    private var pauseButton: some View {
        commandButton(.pause, systemImage: "pause.fill")
            .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.pause)
    }

    private var resumeButton: some View {
        commandButton(.resume, systemImage: "play.fill")
            .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.resume)
    }

    private var cancelButton: some View {
        commandButton(.cancel, systemImage: "xmark")
            .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.cancel)
    }

    @ViewBuilder
    private func commandButton(
        _ command: ReconstructionCommandKind,
        systemImage: String
    ) -> some View {
        let availability = projection.controls.availability(for: command)
        let commandAction = commandDispatcher.action(for: command)
        let enabled = availability.enabled && commandAction != nil
        let button = Button(
            role: command == .cancel ? .destructive : nil,
            action: { _ = commandDispatcher.dispatch(command) }
        ) {
            Label(command.label, systemImage: systemImage)
        }
        .disabled(!enabled)
        .help(commandHelp(command))
        .accessibilityLabel(command.label)
        .accessibilityValue(enabled ? "Available" : "Unavailable")
        .accessibilityHint(commandHelp(command))

        if projection.controls.primaryAction == command {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func commandHelp(_ command: ReconstructionCommandKind) -> String {
        let availability = projection.controls.availability(for: command)
        guard availability.enabled else { return availability.help }
        guard commandDispatcher.action(for: command) != nil else {
            return "The Reconstruction command boundary is unavailable in this window."
        }
        return availability.help
    }

    private var noticePanel: some View {
        ReconstructionSummaryCard(title: presentedNoticeTitle, systemImage: noticeSymbol) {
            if let detail = presentedNoticeDetail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.terminalNotice)
        .accessibilityLabel(presentedNoticeTitle)
        .accessibilityValue(presentedNoticeDetail ?? presentedNoticeTitle)
        .accessibilityHint("A bounded Reconstruction notice with no raw provider diagnostic.")
    }

    private var readinessPanel: some View {
        ReconstructionSummaryCard(title: "Model readiness", systemImage: "brain") {
            VStack(alignment: .leading, spacing: Lumen.Space.s4) {
                LumenBadge(projection.readiness.title, systemImage: projection.readiness.isExecutable
                        ? "checkmark.circle"
                        : "pause.circle", tone: projection.readiness.isExecutable ? .success : .warning)
                Text(projection.readiness.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("Readiness", value: projection.readiness.readinessCase.rawValue)
                    .font(.caption)
                LabeledContent("Activity", value: projection.readiness.activity.title)
                    .font(.caption)
                LabeledContent(
                    "Provider revision",
                    value: projection.readiness.providerRevision.formatted()
                )
                .font(.caption.monospacedDigit())
                if let endpoint = projection.readiness.endpoint {
                    LabeledContent("Endpoint", value: endpoint).font(.caption)
                }
                if let model = projection.readiness.model {
                    LabeledContent("Model", value: model).font(.caption)
                }
            }
        }
    }

    private var phasesPanel: some View {
        ReconstructionSummaryCard(title: "Task phases", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: Lumen.Space.s4) {
                ForEach(projection.phases, id: \.kind) { phase in
                    LabeledContent(phase.kind.rawValue.capitalized) {
                        Text("\(phase.status.rawValue) · \(phase.completed)/\(phase.total)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
                if projection.progress.cancelledTaskCount > 0 {
                    Text("Cancelled tasks: \(projection.progress.cancelledTaskCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.taskSummary)
        .accessibilityLabel("Task summary")
        .accessibilityValue(taskAccessibilityValue)
    }

    private var currentGapPanel: some View {
        ReconstructionSummaryCard(title: "Current gap", systemImage: "questionmark.diamond") {
            VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                Text(projection.currentGap.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !projection.currentGap.operationID.isEmpty {
                    Text(projection.currentGap.operationID)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.currentGap)
        .accessibilityLabel("Current unresolved gap")
        .accessibilityValue(currentGapAccessibilityValue)
        .accessibilityHint(
            projection.currentGap.status == .current
                ? "Reports the current bounded operation identity."
                : "No current unresolved gap."
        )
    }

    private var detailsPanel: some View {
        ReconstructionSummaryCard(title: "Details", systemImage: "sidebar.right") {
            VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                finalResultView

                Divider()
                selectedDetailView

                if !projection.taskSamples.isEmpty {
                    Divider()
                    Text("Task sample")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(projection.taskSamples) { sample in
                        Button {
                            onSelectTask?(sample.taskID)
                        } label: {
                            HStack(spacing: Lumen.Space.s4) {
                                Image(
                                    systemName: projection.windowState.selectedTaskID
                                        == sample.taskID ? "checkmark.circle.fill" : "circle"
                                )
                                Text("\(sample.kind.rawValue) · \(sample.state.rawValue)")
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(onSelectTask == nil)
                        .accessibilityLabel("Select \(sample.kind.rawValue) task")
                        .accessibilityValue(sample.state.rawValue)
                    }
                }

                if !projection.evidenceSamples.isEmpty {
                    Divider()
                    Text("Evidence sample")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(projection.evidenceSamples) { sample in
                        HStack(spacing: Lumen.Space.s4) {
                            Button {
                                onSelectEvidence?(sample.evidenceID)
                            } label: {
                                HStack(spacing: Lumen.Space.s4) {
                                    Image(
                                        systemName: projection.windowState.selectedEvidenceID
                                            == sample.evidenceID
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    Text(
                                        "\(sample.classification.rawValue) · \(sample.payloadKind.rawValue)"
                                    )
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(onSelectEvidence == nil)
                            .accessibilityLabel(
                                "Select \(sample.classification.rawValue) evidence"
                            )
                            .accessibilityValue(sample.payloadKind.rawValue)

                            if sample.sourceNavigationEligible,
                               sourceNavigableEvidenceIDs.contains(sample.evidenceID) {
                                Button("Reveal Source", systemImage: "arrow.up.right.square") {
                                    onRevealEvidenceSource?(sample.evidenceID)
                                }
                                .buttonStyle(.borderless)
                                .disabled(onRevealEvidenceSource == nil)
                                .help("Reveal the exact current function source")
                                .accessibilityIdentifier("reconstruction.revealSource")
                                .accessibilityHint(
                                    "Revalidates current workspace, corpus, image, analysis, "
                                        + "and function authority before navigation."
                                )
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.inspector)
            .accessibilityLabel("Reconstruction inspector")
            .accessibilityHint(
                "Shows window-local bounded detail without changing durable authority."
            )
        }
        .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.details)
        .accessibilityLabel("Reconstruction details")
        .accessibilityValue(selectedDetailAccessibilityValue)
    }

    @ViewBuilder
    private var finalResultView: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            switch projection.finalResult {
            case .unavailable(let reason):
                Label(finalResultUnavailableTitle(reason), systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Text(finalResultUnavailableDetail(reason))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .synthesis(let summary):
                finalResultSummary(
                    summary,
                    title: "Final synthesis",
                    systemImage: "doc.text.fill"
                )
            case .insufficientEvidence(let summary):
                finalResultSummary(
                    summary,
                    title: "Insufficient evidence",
                    systemImage: "questionmark.text.page"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ReconstructionAccessibilityIdentifiers.result)
        .accessibilityLabel("Reconstruction final result")
        .accessibilityValue(finalResultAccessibilityValue)
        .accessibilityHint(
            "Shows bounded durable result text and aggregate citation metadata only."
        )
    }

    private func finalResultSummary(
        _ summary: ReconstructionFinalResultSummary,
        title: String,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(summary.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if summary.textWasTruncated {
                Label(
                    "The durable result is longer than the bounded display excerpt.",
                    systemImage: "ellipsis.rectangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            LabeledContent("Checkpoint", value: summary.checkpointRevision.formatted())
            LabeledContent("Cited evidence", value: summary.citedEvidenceCount.formatted())
            LabeledContent(
                "Durable result size",
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: summary.sourcePayloadByteCount),
                    countStyle: .file
                )
            )
        }
    }

    private func finalResultUnavailableTitle(
        _ reason: ReconstructionFinalResultUnavailability
    ) -> String {
        switch reason {
        case .notCommitted: "No durable final result"
        case .ambiguous: "Final result unavailable"
        case .authorityMismatch: "Final result authority mismatch"
        case .unsafePayload: "Final result suppressed"
        }
    }

    private func finalResultUnavailableDetail(
        _ reason: ReconstructionFinalResultUnavailability
    ) -> String {
        switch reason {
        case .notCommitted:
            "This job has not committed a terminal synthesis or an evidence abstention."
        case .ambiguous:
            "More than one result claims this job, so no result is presented."
        case .authorityMismatch:
            "The result does not match the current completed checkpoint and receipt authority."
        case .unsafePayload:
            "The durable text failed the bounded presentation privacy policy."
        }
    }

    private var finalResultAccessibilityValue: String {
        switch projection.finalResult {
        case .unavailable(let reason):
            return finalResultUnavailableTitle(reason)
        case .synthesis(let summary):
            return finalResultAccessibilityValue("Final synthesis", summary: summary)
        case .insufficientEvidence(let summary):
            return finalResultAccessibilityValue("Insufficient evidence", summary: summary)
        }
    }

    private func finalResultAccessibilityValue(
        _ title: String,
        summary: ReconstructionFinalResultSummary
    ) -> String {
        let excerpt = ReconstructionPresentationPrivacy.boundedSafeText(
            summary.text,
            maximumUTF8Bytes: 512
        ) ?? "Result text suppressed"
        return "\(title). \(excerpt). Checkpoint \(summary.checkpointRevision). "
            + "\(summary.citedEvidenceCount) cited evidence records."
    }

    @ViewBuilder
    private var selectedDetailView: some View {
        switch projection.selectedDetail {
        case .unavailable(let reason):
            Text("Detail unavailable: \(reason.rawValue)")
                .foregroundStyle(.secondary)
        case .job(let detail):
            LabeledContent("Selected job", value: "Job \(detail.creationOrdinal ?? 0)")
            LabeledContent("Committed state", value: detail.state.rawValue)
        case .task(let sample):
            LabeledContent("Selected task", value: sample.kind.rawValue)
            LabeledContent("Task state", value: sample.state.rawValue)
        case .evidence(let sample):
            LabeledContent("Selected evidence", value: sample.classification.rawValue)
            LabeledContent("Payload kind", value: sample.payloadKind.rawValue)
        }
    }

    private var jobAccessibilityValue: String {
        guard let ordinal = projection.jobCreationOrdinal else { return "No job" }
        return "Job \(ordinal)"
    }

    private var taskAccessibilityValue: String {
        let progress = projection.progress
        return "\(progress.pendingTaskCount) pending, \(progress.runningTaskCount) running, "
            + "\(progress.completedTaskCount) completed, \(progress.failedTaskCount) failed, "
            + "\(progress.blockedTaskCount) blocked, \(progress.cancelledTaskCount) cancelled"
    }

    private var corpusAccessibilityValue: String {
        Self.corpusAccessibilityValue(projection.corpus)
    }

    static func corpusAccessibilityValue(_ summary: ReconstructionCorpusSummary) -> String {
        "\(summary.occurrenceCount) occurrences, \(summary.uniqueContentCount) unique content "
            + "items, \(summary.relationCount) relations, "
            + "\(summary.unresolvedRelationCount) unresolved relations"
    }

    private var evidenceAccessibilityValue: String {
        Self.evidenceAccessibilityValue(projection.evidence)
    }

    static func evidenceAccessibilityValue(_ summary: ReconstructionEvidenceSummary) -> String {
        "\(summary.currentCount) current, \(summary.historicalCount) historical, "
            + "\(summary.staleCount) stale, \(summary.unavailableCount) unavailable"
    }

    private var currentGapAccessibilityValue: String {
        Self.currentGapAccessibilityValue(projection.currentGap)
    }

    static func currentGapAccessibilityValue(
        _ gap: ReconstructionStatusGapProjection
    ) -> String {
        guard gap.status == .current,
              let operationID = ReconstructionPresentationPrivacy.boundedSafeText(
                  gap.operationID,
                  maximumUTF8Bytes: 80
              ), !operationID.isEmpty,
              operationID == gap.operationID else { return gap.reason }
        return "\(gap.reason) Operation \(operationID)"
    }

    private var presentedNoticeTitle: String {
        transientNotice?.title ?? projection.notice.title
    }

    private var presentedNoticeDetail: String? {
        transientNotice?.detail ?? projection.notice.detail
    }

    private var selectedDetailAccessibilityValue: String {
        switch projection.selectedDetail {
        case .unavailable(let reason): "Unavailable: \(reason.rawValue)"
        case .job(let detail): "Job \(detail.creationOrdinal ?? 0), \(detail.state.rawValue)"
        case .task(let sample): "Task \(sample.kind.rawValue), \(sample.state.rawValue)"
        case .evidence(let sample):
            "Evidence \(sample.classification.rawValue), \(sample.payloadKind.rawValue)"
        }
    }

    private var stateBadgeTone: LumenBadge.Tone {
        switch projection.stateTone {
        case .neutral: .neutral
        case .active: .accent
        case .ready: .success
        case .warning: .warning
        case .failure: .danger
        }
    }

    private var stateSymbol: String {
        switch projection.stateTone {
        case .neutral: "circle"
        case .active: ReconstructionStatusProjection.destinationSymbol
        case .ready: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .failure: "xmark.octagon"
        }
    }

    private var noticeSymbol: String {
        switch transientNotice?.tone ?? projection.notice.tone {
        case .neutral: "info.circle"
        case .active: ReconstructionStatusProjection.destinationSymbol
        case .ready: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .failure: "xmark.octagon"
        }
    }
}

/// Import progress is transient presentation. All acquisition and durable publication leave
/// through the document runtime command; this control never receives a sidecar or database.
private struct ReconstructionCorpusImportControls: View {
    let onImport: (() -> Void)?
    let onCancel: (() -> Void)?
    let onSave: (() -> Void)?
    let status: String
    let failureDetails: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            HStack {
                Button("Import Corpus…", systemImage: "square.and.arrow.down") {
                    onImport?()
                }
                .disabled(onImport == nil)
                .accessibilityIdentifier("reconstruction.import")
                .help(status)
                if let onCancel {
                    ProgressView().controlSize(.small)
                    Button("Cancel Import", action: onCancel)
                        .accessibilityIdentifier("reconstruction.import.cancel")
                }
                if let onSave {
                    Button("Save Workspace", action: onSave)
                        .accessibilityIdentifier("reconstruction.import.saveWorkspace")
                }
                Spacer(minLength: 0)
            }
            Text(status)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("reconstruction.import.status")
            if !failureDetails.isEmpty {
                Text(failureDetails.joined(separator: "\n"))
                    .font(.caption)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("reconstruction.import.failures")
            }
        }
        .padding(Lumen.Space.s6)
        .workbenchSurface(radius: Lumen.Radius.lg)
    }
}
