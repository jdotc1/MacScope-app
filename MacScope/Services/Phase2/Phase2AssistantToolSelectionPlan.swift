import Foundation

enum Phase2AssistantToolSelectionPlanError: Error, Equatable, Sendable {
    case noToolOperations
    case unsupportedOperation(Phase2ReadOperationID)
    case duplicateOperation(Phase2ReadOperationID)
    case invalidHandle(UUID)
    case duplicateHandle(UUID)
    case registryProjectionFailed
}

struct Phase2AssistantToolSelectionPlan: Equatable, Sendable {
    let handles: [Phase2InferenceToolHandle]
    let projectedTools: [Phase2ProductionProjectedTool]
    let reaSelectors: [UUID: REAResultReadSelector]
    let reaPageCoverage: String

    init(
        operations: [Phase2ReadOperationID],
        debuggerPlan: Phase2DebuggerReadOperationPlan? = nil,
        reaStore: REAResultEvidenceStore? = nil,
        reaWorkspaceID: UUID? = nil,
        readLimits: Phase2ReadLimits = .maximum,
        maximumHandles: Int = Phase2InferenceLimits.assistantMaximum.maximumToolHandles,
        maximumAdditionalReads: Int = Phase2InferenceLimits.assistantMaximum.maximumToolProposals,
        handleIDProvider: () -> UUID = { UUID() },
        registry: Phase2ProductionToolRegistry = Phase2ProductionToolRegistry(version: .assistantR2)
    ) throws {
        guard (1...Phase2InferenceLimits.assistantMaximum.maximumToolHandles).contains(maximumHandles),
              readLimits.validationIssues.isEmpty else {
            throw Phase2AssistantToolSelectionPlanError.registryProjectionFailed
        }
        guard !operations.isEmpty else {
            throw Phase2AssistantToolSelectionPlanError.noToolOperations
        }

        var seenOperations: Set<Phase2ReadOperationID> = []
        var handlesByOperation: [Phase2ReadOperationID: Phase2InferenceToolHandle] = [:]
        var seenHandles: Set<UUID> = []

        for operation in operations {
            guard registry.entry(forOperationID: operation.rawValue) != nil else {
                throw Phase2AssistantToolSelectionPlanError.unsupportedOperation(operation)
            }
            guard seenOperations.insert(operation).inserted else {
                throw Phase2AssistantToolSelectionPlanError.duplicateOperation(operation)
            }
            let handleID = handleIDProvider()
            guard handleID != Phase2AssistantShellTurnIdentity.zeroUUID else {
                throw Phase2AssistantToolSelectionPlanError.invalidHandle(handleID)
            }
            guard seenHandles.insert(handleID).inserted else {
                throw Phase2AssistantToolSelectionPlanError.duplicateHandle(handleID)
            }
            handlesByOperation[operation] = Phase2InferenceToolHandle(
                handleID: handleID,
                operationID: operation
            )
        }

        if let debuggerPlan {
            for debuggerHandle in debuggerPlan.handles {
                let operation = Phase2ReadOperationID(rawValue: debuggerHandle.operation.rawValue)
                guard registry.entry(forOperationID: operation.rawValue) != nil else {
                    throw Phase2AssistantToolSelectionPlanError.unsupportedOperation(operation)
                }
                guard seenOperations.insert(operation).inserted else {
                    throw Phase2AssistantToolSelectionPlanError.duplicateOperation(operation)
                }
                guard debuggerHandle.id != Phase2AssistantShellTurnIdentity.zeroUUID else {
                    throw Phase2AssistantToolSelectionPlanError.invalidHandle(debuggerHandle.id)
                }
                guard seenHandles.insert(debuggerHandle.id).inserted else {
                    throw Phase2AssistantToolSelectionPlanError.duplicateHandle(debuggerHandle.id)
                }
                handlesByOperation[operation] = Phase2InferenceToolHandle(
                    handleID: debuggerHandle.id,
                    operationID: operation
                )
            }
        }

        var orderedHandles = registry.entries.compactMap { entry -> Phase2InferenceToolHandle? in
            handlesByOperation[Phase2ReadOperationID(rawValue: entry.operationID)]
        }
        var selectors: [UUID: REAResultReadSelector] = [:]
        var coverage: [String] = []
        if let reaStore, let reaWorkspaceID, seenOperations.contains(.reaResultsGet) {
            orderedHandles.removeAll { $0.operationID == .reaResultsGet }
            let capacity = max(0, maximumHandles - orderedHandles.count)
            let records = Array(reaStore.records.filter { $0.authority.workspaceID == reaWorkspaceID }.reversed())
            let pageBytes = min(REAResultReadProjection.maximumPageBytes, max(1, (readLimits.stringBytes - 2048) / 2))
            var offsets = Array(repeating: 0, count: records.count)
            var completed = Set<Int>()
            var issued: [Phase2InferenceToolHandle] = []
            // Round-robin retains historical choices before adding further pages. No data is
            // collected here: only exact selectors for the existing bounded read are issued.
            while issued.count < capacity && completed.count < records.count {
                for (index, record) in records.enumerated() where !completed.contains(index) && issued.count < capacity {
                    let page = try REAResultReadProjection.getText(store: reaStore, workspaceID: reaWorkspaceID,
                        activeAuthority: nil, evidenceID: record.evidenceID, responseSHA256: record.responseSHA256,
                        offset: offsets[index], maximumBytes: pageBytes)
                    let id = handleIDProvider()
                    guard id != Phase2AssistantShellTurnIdentity.zeroUUID else { throw Phase2AssistantToolSelectionPlanError.invalidHandle(id) }
                    guard seenHandles.insert(id).inserted else { throw Phase2AssistantToolSelectionPlanError.duplicateHandle(id) }
                    selectors[id] = .init(offset: offsets[index], evidenceID: record.evidenceID, responseSHA256: record.responseSHA256)
                    issued.append(.init(handleID: id, operationID: .reaResultsGet))
                    coverage.append("handle=\(id.uuidString) evidence=\(record.evidenceID.uuidString) operation=\(record.operation) responseSHA256=\(record.responseSHA256) offset=\(offsets[index]) end=\(page.nextOffset ?? record.responseJSON.count) total=\(record.responseJSON.count)")
                    if let next = page.nextOffset { offsets[index] = next } else { completed.insert(index) }
                }
            }
            orderedHandles.append(contentsOf: issued)
            coverage.append("Bounded page choices: \(issued.count); complete records covered: \(completed.count)/\(records.count). Unoffered pages are unavailable in this turn. Select at most \(maximumAdditionalReads) additional reads; selected pages do not imply a complete result.")
        }
        guard orderedHandles.count <= maximumHandles else { throw Phase2AssistantToolSelectionPlanError.registryProjectionFailed }
        reaSelectors = selectors
        reaPageCoverage = coverage.joined(separator: "\n")
        let productionHandles = orderedHandles.map {
            Phase2ProductionToolHandle(
                handleID: $0.handleID,
                operationID: $0.operationID.rawValue
            )
        }

        do {
            handles = orderedHandles
            projectedTools = try registry.project(productionHandles)
        } catch {
            throw Phase2AssistantToolSelectionPlanError.registryProjectionFailed
        }
    }
}

extension Phase2AssistantIntent {
    var providerVisibleToolOperations: [Phase2ReadOperationID] {
        switch self {
        case .reviewFunction:
            [.functionReview, .decompilerNativeResult, .decompilerMacScopeResult, .decompilerCompare]
        case .askMacScope, .explainSelection:
            requiredOperations
        }
    }
}
