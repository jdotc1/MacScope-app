import SwiftUI
import LumenUI

struct ReconstructionJobCreationItem: Identifiable, Hashable, Sendable {
    let projectID: UUID
    let occurrenceID: ReconstructionArtifactOccurrenceID
    let contentIdentity: ReconstructionContentIdentity
    let displayName: String
    let detail: String?

    var id: ReconstructionArtifactOccurrenceID { occurrenceID }

    var artifactCoordinate: ReconstructionArtifactCoordinate {
        ReconstructionArtifactCoordinate(
            occurrenceID: occurrenceID,
            contentIdentity: contentIdentity
        )
    }

    /// Projects only the exact occurrences named by each project's committed current manifest.
    /// Historical manifests remain durable evidence, but never silently re-enter a new job draft.
    /// Root order is the canonical semantic-set order `(projectID, occurrenceID)`, never toggle
    /// history, user priority, or scheduler fairness.
    static func committedItems(
        in workspace: ReconstructionWorkspaceState
    ) -> [ReconstructionJobCreationItem] {
        let currentManifestDigests = Dictionary(
            uniqueKeysWithValues: workspace.projects.compactMap { project in
                project.currentCorpusManifestSHA256.map { (project.projectID, $0) }
            }
        )
        let projectNames = Dictionary(
            uniqueKeysWithValues: workspace.projects.map { ($0.projectID, $0.name) }
        )
        return workspace.corpusManifests
            .filter { manifest in
                currentManifestDigests[manifest.reconstructionProjectID]
                    == manifest.canonicalSHA256
            }
            .flatMap { manifest in
                manifest.artifacts.map { (manifest.reconstructionProjectID, $0) }
            }
            .map { projectID, occurrence in
                let kind = occurrence.kind.rawValue
                let name = occurrence.originalName ?? kind
                let byteCount = occurrence.contentIdentity.byteCount.formatted()
                let digestPrefix = occurrence.contentIdentity.digest.prefix(12)
                let projectName = projectNames[projectID] ?? "Committed project"
                return ReconstructionJobCreationItem(
                    projectID: projectID,
                    occurrenceID: occurrence.occurrenceID,
                    contentIdentity: occurrence.contentIdentity,
                    displayName: name,
                    detail: "\(projectName) · \(kind) · \(byteCount) bytes · \(digestPrefix)…"
                )
            }
            .sorted(by: canonicalSetOrder)
    }

    static func canonicalSetOrder(
        _ lhs: ReconstructionJobCreationItem,
        _ rhs: ReconstructionJobCreationItem
    ) -> Bool {
        if lhs.projectID != rhs.projectID {
            return lhs.projectID.uuidString < rhs.projectID.uuidString
        }
        return lhs.occurrenceID.rawValue.uuidString < rhs.occurrenceID.rawValue.uuidString
    }
}

/// Product policy for newly-created jobs. Durable historical budgets deliberately remain valid
/// outside these ranges; only the creation surface and request boundary consume this policy.
enum ReconstructionNewJobBudgetPolicy {
    static let maxRounds: ClosedRange<Int> = 1...64
    static let maxTasks: ClosedRange<Int> = 32...16_384
    static let maxEvidenceRecords: ClosedRange<Int> = 64...65_536
    static let maxEncodedMiB: ClosedRange<Int> = 1...1_024

    private static let bytesPerMiB: UInt64 = 1_024 * 1_024
    static let maxEncodedBytes: ClosedRange<UInt64> = (
        UInt64(maxEncodedMiB.lowerBound) * bytesPerMiB
    )...(
        UInt64(maxEncodedMiB.upperBound) * bytesPerMiB
    )

    static func accepts(_ budget: ReconstructionJobBudget) -> Bool {
        maxRounds.contains(budget.maxRounds)
            && maxTasks.contains(budget.maxTasks)
            && maxEvidenceRecords.contains(budget.maxEvidenceRecords)
            && maxEncodedBytes.contains(budget.maxEncodedBytes)
    }

    static func encodedBytes(forMiB mebibytes: Int) -> UInt64? {
        guard maxEncodedMiB.contains(mebibytes) else { return nil }
        return UInt64(mebibytes) * bytesPerMiB
    }
}

struct ReconstructionJobCreationRequest: Sendable {
    static let maximumObjectiveUTF8Bytes = 4_096

    let projectID: UUID
    let selectedItems: [ReconstructionJobCreationItem]
    let objective: String
    let budget: ReconstructionJobBudget
    let focus: ReconstructionSubjectCoordinate?
    let sourceProfileID: String?

    static func committedFunctions(
        in workspace: ReconstructionWorkspaceState
    ) -> [ReconstructionFunctionCoordinate] {
        let artifacts = Set(ReconstructionJobCreationItem.committedItems(in: workspace).map(\.artifactCoordinate))
        var seen: Set<ReconstructionFunctionCoordinate> = []
        return workspace.evidence.compactMap { evidence in
            guard evidence.classification == .acceptedCurrent,
                  evidence.supersededByEvidenceID == nil,
                  case let .function(function) = evidence.subject,
                  artifacts.contains(function.artifact), seen.insert(function).inserted else { return nil }
            return function
        }.sorted {
            if $0.artifact.occurrenceID != $1.artifact.occurrenceID {
                return $0.artifact.occurrenceID.rawValue.uuidString < $1.artifact.occurrenceID.rawValue.uuidString
            }
            if $0.startAddress != $1.startAddress { return $0.startAddress < $1.startAddress }
            return $0.analysisFingerprintSHA256 < $1.analysisFingerprintSHA256
        }
    }

    static func acceptsFocus(
        _ focus: ReconstructionSubjectCoordinate?,
        selectedItems: [ReconstructionJobCreationItem],
        committedFunctions: [ReconstructionFunctionCoordinate]
    ) -> Bool {
        let artifacts = Set(selectedItems.map(\.artifactCoordinate))
        switch focus {
        case nil: return true
        case let .artifact(artifact): return artifacts.contains(artifact)
        case let .function(function):
            return artifacts.contains(function.artifact) && committedFunctions.contains(function)
        case .image: return false
        }
    }

    static func normalizedObjective(_ rawValue: String) -> String? {
        let normalized = rawValue
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty,
              normalized.utf8.count <= maximumObjectiveUTF8Bytes else {
            return nil
        }
        return normalized
    }

    init?(
        selectedItems: [ReconstructionJobCreationItem],
        committedItems: [ReconstructionJobCreationItem],
        objective: String,
        budget: ReconstructionJobBudget,
        focus: ReconstructionSubjectCoordinate? = nil,
        committedFunctions: [ReconstructionFunctionCoordinate] = [],
        sourceProfileID: String? = nil
    ) {
        guard sourceProfileID == nil || sourceProfileID == ReconstructionSourceExecutionTaskContract.profileID,
              let normalizedObjective = Self.normalizedObjective(objective) else {
            return nil
        }
        var committedByOccurrenceID: [
            ReconstructionArtifactOccurrenceID: ReconstructionJobCreationItem
        ] = [:]
        for item in committedItems {
            guard committedByOccurrenceID.updateValue(
                item,
                forKey: item.occurrenceID
            ) == nil else {
                return nil
            }
        }
        guard let projectID = selectedItems.first?.projectID,
              selectedItems.allSatisfy({ $0.projectID == projectID }),
              Set(selectedItems.map(\.occurrenceID)).count == selectedItems.count,
              selectedItems.allSatisfy({ selected in
                  guard let committed = committedByOccurrenceID[selected.occurrenceID] else {
                      return false
                  }
                  return committed.projectID == selected.projectID
                      && committed.contentIdentity == selected.contentIdentity
              }),
              ReconstructionNewJobBudgetPolicy.accepts(budget),
              Self.acceptsFocus(focus, selectedItems: selectedItems, committedFunctions: committedFunctions) else {
            return nil
        }
        let canonicalSelectedItems = selectedItems.sorted(
            by: ReconstructionJobCreationItem.canonicalSetOrder
        )
        self.projectID = projectID
        self.selectedItems = canonicalSelectedItems
        self.objective = normalizedObjective
        self.budget = budget
        self.focus = focus
        self.sourceProfileID = sourceProfileID
    }

    var selectedArtifacts: [ReconstructionArtifactCoordinate] {
        selectedItems.map(\.artifactCoordinate)
    }
}

/// Native creation sheet. Item acquisition and durable job creation remain explicit parent intents;
/// this view owns only draft editing and validated request construction.
struct ReconstructionJobCreationSheet: View {
    let availableItems: [ReconstructionJobCreationItem]
    let availableFunctions: [ReconstructionFunctionCoordinate]
    let submissionAvailable: Bool
    let onImport: (() -> Void)?
    let onCancel: () -> Void
    let onCreate: (ReconstructionJobCreationRequest) -> Void

    @State private var selectedItemIDs: Set<ReconstructionArtifactOccurrenceID>
    @State private var objective = ""
    @State private var focus: ReconstructionSubjectCoordinate?
    @State private var maxRounds = 8
    @State private var maxTasks = 1_024
    @State private var maxEvidenceRecords = 4_096
    @State private var maxEncodedMiB = 64

    init(
        availableItems: [ReconstructionJobCreationItem],
        availableFunctions: [ReconstructionFunctionCoordinate] = [],
        initiallySelectedItemIDs: Set<ReconstructionArtifactOccurrenceID> = [],
        submissionAvailable: Bool,
        onImport: (() -> Void)? = nil,
        onCancel: @escaping () -> Void,
        onCreate: @escaping (ReconstructionJobCreationRequest) -> Void
    ) {
        self.availableItems = availableItems
        self.availableFunctions = availableFunctions
        self.submissionAvailable = submissionAvailable
        self.onImport = onImport
        self.onCancel = onCancel
        self.onCreate = onCreate
        _selectedItemIDs = State(initialValue: initiallySelectedItemIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section("Committed corpus items") {
                    Button("Import Corpus…", systemImage: "square.and.arrow.down") {
                        onImport?()
                    }
                    .disabled(onImport == nil)
                    .accessibilityIdentifier("reconstruction.creation.import")
                    if availableItems.isEmpty {
                        Text("No committed corpus items are available.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(availableItems) { item in
                            Toggle(isOn: selectionBinding(for: item.id)) {
                                VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                                    Text(item.displayName)
                                    if let detail = item.detail {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            .accessibilityIdentifier(
                                "reconstruction.creation.item."
                                    + item.id.rawValue.uuidString.lowercased()
                            )
                            .disabled(
                                selectedProjectID.map { selectedProjectID in
                                    selectedProjectID != item.projectID
                                        && !selectedItemIDs.contains(item.id)
                                } ?? false
                            )
                        }
                    }
                }

                ReconstructionCreationFocusSection(
                    selectedItems: selectedItems,
                    availableFunctions: availableFunctions,
                    focus: $focus,
                    isValid: focusIsValid
                )

                Section("Objective") {
                    TextField(
                        "Describe the bounded reconstruction objective",
                        text: $objective,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .accessibilityIdentifier("reconstruction.creation.objective")
                }

                Section("Resource budgets") {
                    Stepper(
                        "Consecutive model rounds without new evidence: \(maxRounds)",
                        value: $maxRounds,
                        in: ReconstructionNewJobBudgetPolicy.maxRounds
                    )
                    .help(
                        "Maximum consecutive ordinary model rounds allowed without newly "
                            + "accepted evidence"
                    )
                    Stepper(
                        "Tasks: \(maxTasks)",
                        value: $maxTasks,
                        in: ReconstructionNewJobBudgetPolicy.maxTasks,
                        step: 32
                    )
                    Stepper(
                        "Evidence records: \(maxEvidenceRecords)",
                        value: $maxEvidenceRecords,
                        in: ReconstructionNewJobBudgetPolicy.maxEvidenceRecords,
                        step: 64
                    )
                    Stepper(
                        "Encoded evidence: \(maxEncodedMiB) MiB",
                        value: $maxEncodedMiB,
                        in: ReconstructionNewJobBudgetPolicy.maxEncodedMiB
                    )
                }
            }
            .formStyle(.grouped)

            Divider()
            actions
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 560, idealHeight: 640)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reconstruction.creation.sheet")
        .accessibilityLabel("Create reconstruction job")
    }

    private var header: some View {
        HStack(spacing: Lumen.Space.s5) {
            Label("Create Reconstruction Job", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.headline)
                .lumenNeverTruncates("Create Reconstruction Job")
            Spacer()
            Text("\(selectedItems.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Lumen.Space.s6)
    }

    private var actions: some View {
        HStack(spacing: Lumen.Space.s5) {
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Create and Start", action: create)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("reconstruction.creation.submit")
                .disabled(!canCreate || !submissionAvailable)
                .help(
                    submissionAvailable
                        ? "Create and start the bounded reconstruction job"
                        : "Reconstruction runtime commands are not available in this window"
                )
        }
        .padding(Lumen.Space.s6)
    }

    private var selectedItems: [ReconstructionJobCreationItem] {
        availableItems.filter { selectedItemIDs.contains($0.id) }
    }

    private var canCreate: Bool {
        !selectedItems.isEmpty
            && Set(selectedItems.map(\.projectID)).count == 1
            && ReconstructionJobCreationRequest.normalizedObjective(objective) != nil
            && makeBudget() != nil
            && focusIsValid
    }

    private var focusIsValid: Bool {
        ReconstructionJobCreationRequest.acceptsFocus(
            focus, selectedItems: selectedItems, committedFunctions: availableFunctions
        )
    }

    private var selectedProjectID: UUID? {
        let projectIDs = Set(selectedItems.map(\.projectID))
        return projectIDs.count == 1 ? projectIDs.first : nil
    }

    private func selectionBinding(
        for id: ReconstructionArtifactOccurrenceID
    ) -> Binding<Bool> {
        Binding(
            get: { selectedItemIDs.contains(id) },
            set: { selected in
                if selected { selectedItemIDs.insert(id) }
                else { selectedItemIDs.remove(id) }
            }
        )
    }

    private func makeBudget() -> ReconstructionJobBudget? {
        guard let maxEncodedBytes = ReconstructionNewJobBudgetPolicy.encodedBytes(
            forMiB: maxEncodedMiB
        ) else { return nil }
        return try? ReconstructionJobBudget(
            maxRounds: maxRounds,
            maxTasks: maxTasks,
            maxEvidenceRecords: maxEvidenceRecords,
            maxEncodedBytes: maxEncodedBytes
        )
    }

    private func create() {
        guard let budget = makeBudget(), canCreate, submissionAvailable,
              let request = ReconstructionJobCreationRequest(
                selectedItems: selectedItems,
                committedItems: availableItems,
                objective: objective,
                budget: budget,
                focus: focus,
                committedFunctions: availableFunctions
              ) else { return }
        onCreate(request)
    }
}

private struct ReconstructionCreationFocusSection: View {
    let selectedItems: [ReconstructionJobCreationItem]
    let availableFunctions: [ReconstructionFunctionCoordinate]
    @Binding var focus: ReconstructionSubjectCoordinate?
    let isValid: Bool

    var body: some View {
        Section("Reconstruction focus") {
            Picker("Focus", selection: $focus) {
                Text("Selected corpus").tag(ReconstructionSubjectCoordinate?.none)
                ForEach(selectedItems) { item in
                    Text("Artifact: \(item.displayName)")
                        .tag(Optional(ReconstructionSubjectCoordinate.artifact(item.artifactCoordinate)))
                }
                ForEach(functions, id: \.self) { function in
                    Text("Function: \(function.symbolHint ?? "Unnamed") at \(String(function.startAddress, radix: 16))")
                        .tag(Optional(ReconstructionSubjectCoordinate.function(function)))
                }
                if !isValid, let focus {
                    Text("Unavailable focus — choose another")
                        .tag(Optional(focus))
                }
            }
            .accessibilityIdentifier("reconstruction.creation.focus")
            .accessibilityLabel("Reconstruction focus")
            Text("Choose a committed artifact or function, or reconstruct the selected corpus.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !isValid {
                Text("The focused subject is no longer selected. Choose a focus before creating the job.")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("reconstruction.creation.focus.invalid")
            }
        }
    }

    private var functions: [ReconstructionFunctionCoordinate] {
        let artifacts = Set(selectedItems.map(\.artifactCoordinate))
        return availableFunctions.filter { artifacts.contains($0.artifact) }
    }
}
