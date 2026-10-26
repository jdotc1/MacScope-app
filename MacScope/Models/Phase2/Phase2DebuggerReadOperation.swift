import Foundation

/// Closed, read-only debugger operations that a future provider projection may expose.
///
/// Operation handles are minted by ``Phase2DebuggerReadOperationPlan`` from one exact stopped
/// evidence snapshot. A provider-facing wire representation needs only `id` and `operation`; the
/// coordinate binding remains app-owned in the plan and cannot be rewritten by the provider.
struct Phase2DebuggerReadOperationHandle: Equatable, Hashable, Sendable {
    let id: UUID
    let operation: Phase2DebuggerReadOperationID
}

struct Phase2DebuggerReadOperationRequest: Equatable, Sendable {
    let handleID: UUID
    let operation: Phase2DebuggerReadOperationID
}

struct Phase2DebuggerSummaryReadResult: Equatable, Sendable {
    let processID: Int32
    let processStateDetail: String
    let statusMessage: String
    let selectedThreadIndex: Int
    let selectedFrameIndex: Int
    let selectedFrameAddress: UInt64
}

struct Phase2DebuggerFramesReadResult: Equatable, Sendable {
    let frames: [Phase2DebuggerFrameEvidence]
    let wasTruncated: Bool
}

struct Phase2DebuggerRegistersReadResult: Equatable, Sendable {
    let registers: [Phase2DebuggerRegisterEvidence]
    let wasTruncated: Bool
}

struct Phase2DebuggerVariablesReadResult: Equatable, Sendable {
    let availability: Phase2DebuggerVariableEvidenceAvailability
}

struct Phase2DebuggerMemoryReadResult: Equatable, Sendable {
    /// Only the bounded previews already present in the exact evidence snapshot. This contract
    /// intentionally has no address/count input and therefore cannot authorize a new LLDB read.
    let regions: [Phase2DebuggerMemoryEvidence]
    let wasTruncated: Bool
}

enum Phase2DebuggerReadOperationPayload: Equatable, Sendable {
    case summary(Phase2DebuggerSummaryReadResult)
    case frames(Phase2DebuggerFramesReadResult)
    case registers(Phase2DebuggerRegistersReadResult)
    case variables(Phase2DebuggerVariablesReadResult)
    case memory(Phase2DebuggerMemoryReadResult)

    var operation: Phase2DebuggerReadOperationID {
        switch self {
        case .summary: .summary
        case .frames: .frames
        case .registers: .registers
        case .variables: .variables
        case .memory: .memory
        }
    }
}

enum Phase2DebuggerReadOperationRejection: Equatable, Sendable {
    case unknownHandle
    case operationMismatch
    case staleCoordinate
    case staleEvidence
}

enum Phase2DebuggerReadOperationOutcome: Equatable, Sendable {
    case value(Phase2DebuggerReadOperationPayload)
    case rejected(Phase2DebuggerReadOperationRejection)
}

struct Phase2DebuggerReadOperationProvenance: Equatable, Sendable {
    let evidenceDigest: String
    let targetDigest: String
    let sessionEpoch: UUID
    let lifecycleRevision: UInt64
    let stopRevision: UInt64
    let threadIndex: Int
    let frameIndex: Int
    let frameAddress: UInt64

    init(evidence: Phase2DebuggerReadEvidenceSnapshot) {
        evidenceDigest = evidence.evidenceDigest
        targetDigest = evidence.coordinate.targetDigest.lowercaseHex
        sessionEpoch = evidence.coordinate.stop.session.epoch.rawValue
        lifecycleRevision = evidence.coordinate.stop.session.lifecycleRevision.rawValue
        stopRevision = evidence.coordinate.stop.stopRevision.rawValue
        threadIndex = evidence.coordinate.thread.index
        frameIndex = evidence.coordinate.frame.frameIndex
        frameAddress = evidence.coordinate.frame.programCounter
    }
}

struct Phase2DebuggerReadOperationResult: Equatable, Sendable {
    let operation: Phase2DebuggerReadOperationID
    let provenance: Phase2DebuggerReadOperationProvenance?
    let outcome: Phase2DebuggerReadOperationOutcome
}

extension Phase2DebuggerReadOperationResult {
    func providerVisibleEvidenceText(maximumUTF8Bytes: Int = 4_096) -> String? {
        guard maximumUTF8Bytes > 0, case .value(let payload) = outcome else { return nil }
        guard let provenance else { return nil }
        var lines = [
            "Debugger typed read: \(operation.rawValue)",
            "Target identity digest: \(provenance.targetDigest)",
            "Session epoch: \(provenance.sessionEpoch.uuidString)",
            "Lifecycle revision: \(provenance.lifecycleRevision)",
            "Stop revision: \(provenance.stopRevision)",
            "Selected thread: #\(provenance.threadIndex)",
            "Selected frame: #\(provenance.frameIndex) \(provenance.frameAddress.hexAddress)",
        ]
        switch payload {
        case .summary(let summary):
            lines += [
                "Target process ID: \(summary.processID)",
                "State: \(summary.processStateDetail)",
                "Status: \(summary.statusMessage)",
                "Selected thread: #\(summary.selectedThreadIndex)",
                "Selected frame: #\(summary.selectedFrameIndex) \(summary.selectedFrameAddress.hexAddress)",
            ]
        case .frames(let result):
            lines.append("Frames\(result.wasTruncated ? " (truncated)" : ""):")
            lines += result.frames.map {
                "- #\($0.index) \($0.address.hexAddress) \($0.functionName)"
            }
        case .registers(let result):
            lines.append("Registers\(result.wasTruncated ? " (truncated)" : ""):")
            lines += result.registers.map { "- \($0.name): \($0.value)" }
        case .variables(let result):
            switch result.availability {
            case .available(let scopes, let wasTruncated):
                return Phase2DebuggerReadEvidenceSnapshot.completeVariableLineBoundedText(
                    prefixLines: lines,
                    scopes: scopes,
                    evidenceWasTruncated: wasTruncated,
                    maximumUTF8Bytes: maximumUTF8Bytes
                )
            case .unavailable(let reason):
                lines.append("Variables: unavailable — \(reason.rawValue)")
            }
        case .memory(let result):
            lines.append("Memory previews\(result.wasTruncated ? " (truncated)" : ""):")
            lines += result.regions.map { region in
                let bytes = region.previewBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
                return "- \(region.address.hexAddress) \(region.byteCount) bytes: \(bytes)"
            }
        }
        return Phase2DebuggerReadEvidenceSnapshot.completeLineBoundedText(
            lines,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
    }
}

/// App-owned handle inventory for one immutable, exact stopped-frame evidence cut.
struct Phase2DebuggerReadOperationPlan: Equatable, Sendable {
    let handles: [Phase2DebuggerReadOperationHandle]

    private let evidence: Phase2DebuggerReadEvidenceSnapshot

    init?(
        evidence: Phase2DebuggerReadEvidenceSnapshot,
        handleIDProvider: () -> UUID = { UUID() }
    ) {
        var handles: [Phase2DebuggerReadOperationHandle] = []
        var issuedIDs: Set<UUID> = []
        for operation in Phase2DebuggerReadOperationID.allCases {
            let id = handleIDProvider()
            guard issuedIDs.insert(id).inserted else { return nil }
            handles.append(.init(id: id, operation: operation))
        }
        self.evidence = evidence
        self.handles = handles
    }

    func resolve(
        _ request: Phase2DebuggerReadOperationRequest,
        against currentEvidence: Phase2DebuggerReadEvidenceSnapshot?
    ) -> Phase2DebuggerReadOperationResult {
        guard let handle = handles.first(where: { $0.id == request.handleID }) else {
            return rejected(request.operation, .unknownHandle)
        }
        guard handle.operation == request.operation else {
            return rejected(request.operation, .operationMismatch)
        }
        guard let currentEvidence,
              evidence.coordinate == currentEvidence.coordinate else {
            return rejected(request.operation, .staleCoordinate)
        }
        guard evidence.evidenceDigest == currentEvidence.evidenceDigest else {
            return rejected(request.operation, .staleEvidence)
        }

        let payload: Phase2DebuggerReadOperationPayload
        switch request.operation {
        case .summary:
            payload = .summary(.init(
                processID: evidence.processID,
                processStateDetail: evidence.processStateDetail,
                statusMessage: evidence.statusMessage,
                selectedThreadIndex: evidence.coordinate.thread.index,
                selectedFrameIndex: evidence.coordinate.frame.frameIndex,
                selectedFrameAddress: evidence.coordinate.frame.programCounter
            ))
        case .frames:
            payload = .frames(.init(
                frames: evidence.frames,
                wasTruncated: evidence.framesWereTruncated
            ))
        case .registers:
            payload = .registers(.init(
                registers: evidence.registers,
                wasTruncated: evidence.registersWereTruncated
            ))
        case .variables:
            payload = .variables(.init(availability: evidence.variables))
        case .memory:
            payload = .memory(.init(
                regions: evidence.memoryRegions,
                wasTruncated: evidence.memoryRegionsWereTruncated
            ))
        }
        return .init(
            operation: request.operation,
            provenance: .init(evidence: evidence),
            outcome: .value(payload)
        )
    }

    private func rejected(
        _ operation: Phase2DebuggerReadOperationID,
        _ rejection: Phase2DebuggerReadOperationRejection
    ) -> Phase2DebuggerReadOperationResult {
        .init(operation: operation, provenance: nil, outcome: .rejected(rejection))
    }
}
