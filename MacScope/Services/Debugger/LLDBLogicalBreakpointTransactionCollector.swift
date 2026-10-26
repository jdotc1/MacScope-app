import Foundation

enum LLDBLogicalBreakpointHelperPreparation: Hashable, Sendable {
    /// The exact helper digest was already proven for the retained adapter generation.
    case alreadyProvenForGeneration
    /// One exact digest proof is required before the transaction.
    case proveOnly
    /// Reserve a failed proof, every frozen install chunk, finalize, and a second proof.
    case proveInstallAndReprove
}

enum LLDBLogicalBreakpointTransactionCollectorError: Error, Equatable, Sendable {
    case invalidPlanPageCount
    case invalidReceiptByteBound
    case reservationOverflow
    case commandAlreadyInFlight
    case noCommandAvailable
    case unexpectedCompletion
    case invalidReceiptPage
    case receiptCapacityExceeded
    case receiptValidationUnavailable
    case cleanupUnavailable
}

/// Complete capacity required before a binding plan is admitted. Logical binding reducer
/// transitions do not consume event envelopes; the single event slot is reserved for the only
/// fail-closed contingency owned by the coordinator: session invalidation after uncertainty.
struct LLDBLogicalBreakpointTransactionReservation: Equatable, Sendable {
    /// Frozen by the reviewed helper's `receipt_page` implementation.
    static let receiptPagePayloadByteCount = 1_536
    static let eventSequenceCountUpperBound = 1

    let helperPreparation: LLDBLogicalBreakpointHelperPreparation
    let planPageCount: Int
    let receiptByteCountUpperBound: Int
    let receiptPageCountUpperBound: Int
    let helperPreparationRequestCount: Int
    let transactionRequestCount: Int
    let physicalRequestCount: Int
    let eventSequenceCount: Int
    let cleanupPhysicalRequestOffset: Int

    init(
        helperPreparation: LLDBLogicalBreakpointHelperPreparation,
        planPageCount: Int,
        receiptByteCountUpperBound: Int
    ) throws {
        guard (1...LLDBLogicalBreakpointProgram.maximumPlanPageCount).contains(planPageCount) else {
            throw LLDBLogicalBreakpointTransactionCollectorError.invalidPlanPageCount
        }
        guard (1...LLDBLogicalBreakpointProgram.maximumReceiptBytes)
            .contains(receiptByteCountUpperBound) else {
            throw LLDBLogicalBreakpointTransactionCollectorError.invalidReceiptByteBound
        }

        let receiptPages = Self.ceilingDivision(
            receiptByteCountUpperBound,
            by: Self.receiptPagePayloadByteCount
        )
        let helperRequests: Int
        switch helperPreparation {
        case .alreadyProvenForGeneration:
            helperRequests = 0
        case .proveOnly:
            helperRequests = 1
        case .proveInstallAndReprove:
            // Initial proof + all chunks + finalize + final proof.
            helperRequests = LLDBLogicalBreakpointProgram.current.installChunkCommands.count + 3
        }

        // begin + every upload + apply + maximum receipt pages + cleanup
        let transactionParts = [1, planPageCount, 1, receiptPages, 1]
        guard let transactionRequests = Self.checkedSum(transactionParts),
              let physicalRequests = Self.checkedSum([helperRequests, transactionRequests]),
              physicalRequests > 0 else {
            throw LLDBLogicalBreakpointTransactionCollectorError.reservationOverflow
        }

        self.helperPreparation = helperPreparation
        self.planPageCount = planPageCount
        self.receiptByteCountUpperBound = receiptByteCountUpperBound
        receiptPageCountUpperBound = receiptPages
        helperPreparationRequestCount = helperRequests
        transactionRequestCount = transactionRequests
        physicalRequestCount = physicalRequests
        eventSequenceCount = Self.eventSequenceCountUpperBound
        cleanupPhysicalRequestOffset = physicalRequests - 1
    }

    private static func ceilingDivision(_ value: Int, by divisor: Int) -> Int {
        1 + ((value - 1) / divisor)
    }

    private static func checkedSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
}

enum LLDBLogicalBreakpointTransactionStep: Equatable, Sendable {
    case begin
    case upload(pageIndex: Int)
    case apply
    case receipt(pageIndex: Int, cursor: Int)
    case cleanup
}

enum LLDBLogicalBreakpointTransactionStepCompletion: Equatable, Sendable {
    case acknowledged
    case receiptPage(payloadByteCount: Int, isFinal: Bool)
}

/// Transport evidence for a command which was marked dispatched but did not produce an accepted
/// typed response. Only the adapter's explicit before-write dispositions may select the first case.
enum LLDBLogicalBreakpointDispatchedStepFailureEvidence: Equatable, Sendable {
    case provenBeforeWrite
    case writeUncertain
}

enum LLDBLogicalBreakpointCleanupEvidence: Equatable, Sendable {
    case notRequired
    case required
    case proven
    case failedOrUnproven
}

enum LLDBLogicalBreakpointTransactionFailureClassification: Equatable, Sendable {
    case cancelBeforeWrite(cleanup: LLDBLogicalBreakpointCleanupEvidence)
    case rejectMalformedAfterPossibleWrite(
        cleanup: LLDBLogicalBreakpointCleanupEvidence,
        retainValidatedCompleteReceipt: Bool,
        targetRecoveryRequired: Bool
    )
}

/// Pure order and failure-evidence collector. It executes no commands and admits no reducer input;
/// the coordinator owns those effects and records dispatch immediately before an adapter exchange.
struct LLDBLogicalBreakpointTransactionCollector: Sendable {
    let reservation: LLDBLogicalBreakpointTransactionReservation

    private(set) var nextStep: LLDBLogicalBreakpointTransactionStep?
    private(set) var dispatchedStep: LLDBLogicalBreakpointTransactionStep?
    private(set) var mayHaveWritten = false
    private(set) var hasCompleteReceiptBytes = false
    private(set) var hasValidatedCompleteReceipt = false
    private(set) var cleanupProven = false
    private(set) var isComplete = false

    private var beginMayHaveExecuted = false
    private var cleanupAttempted = false
    private var cleanupIsUnavailable = false
    private var failureWasRecorded = false
    private var failureCleanupForced = false
    private var receivedReceiptBytes = 0

    init(reservation: LLDBLogicalBreakpointTransactionReservation) {
        self.reservation = reservation
        nextStep = .begin
    }

    var failureClassification: LLDBLogicalBreakpointTransactionFailureClassification {
        let cleanup = cleanupEvidence
        if mayHaveWritten {
            return .rejectMalformedAfterPossibleWrite(
                cleanup: cleanup,
                retainValidatedCompleteReceipt: hasValidatedCompleteReceipt,
                targetRecoveryRequired: true
            )
        }
        return .cancelBeforeWrite(cleanup: cleanup)
    }

    @discardableResult
    mutating func dispatchNextStep() throws -> LLDBLogicalBreakpointTransactionStep {
        guard dispatchedStep == nil else {
            throw LLDBLogicalBreakpointTransactionCollectorError.commandAlreadyInFlight
        }
        guard let step = nextStep, !isComplete else {
            throw LLDBLogicalBreakpointTransactionCollectorError.noCommandAvailable
        }
        if step == .cleanup,
           !failureCleanupForced,
           !hasValidatedCompleteReceipt {
            throw LLDBLogicalBreakpointTransactionCollectorError.receiptValidationUnavailable
        }
        nextStep = nil
        dispatchedStep = step
        switch step {
        case .begin:
            beginMayHaveExecuted = true
        case .apply:
            // Dispatch is the first instant at which a timeout or lost response can conceal a
            // target mutation. Merely reserving or selecting the apply phase is not a write.
            mayHaveWritten = true
        case .cleanup:
            cleanupAttempted = true
        case .upload, .receipt:
            break
        }
        return step
    }

    mutating func completeDispatchedStep(
        _ completion: LLDBLogicalBreakpointTransactionStepCompletion = .acknowledged
    ) throws {
        guard let step = dispatchedStep else {
            throw LLDBLogicalBreakpointTransactionCollectorError.noCommandAvailable
        }

        switch (step, completion) {
        case (.begin, .acknowledged):
            dispatchedStep = nil
            nextStep = .upload(pageIndex: 0)

        case (.upload(let pageIndex), .acknowledged):
            guard (0..<reservation.planPageCount).contains(pageIndex) else {
                throw LLDBLogicalBreakpointTransactionCollectorError.unexpectedCompletion
            }
            dispatchedStep = nil
            let nextIndex = pageIndex + 1
            nextStep = nextIndex < reservation.planPageCount
                ? .upload(pageIndex: nextIndex)
                : .apply

        case (.apply, .acknowledged):
            dispatchedStep = nil
            nextStep = .receipt(pageIndex: 0, cursor: 0)

        case (.receipt(let pageIndex, let cursor), .receiptPage(let byteCount, let isFinal)):
            try completeReceiptPage(
                pageIndex: pageIndex,
                cursor: cursor,
                payloadByteCount: byteCount,
                isFinal: isFinal
            )

        case (.cleanup, .acknowledged):
            dispatchedStep = nil
            cleanupProven = true
            isComplete = true
            nextStep = nil

        default:
            throw LLDBLogicalBreakpointTransactionCollectorError.unexpectedCompletion
        }
    }

    /// Records transport evidence for the exact dispatched step. The apply dispatch is
    /// conservative until the adapter explicitly proves that request was cancelled or failed
    /// before its bytes could be written.
    mutating func failDispatchedStep(
        _ evidence: LLDBLogicalBreakpointDispatchedStepFailureEvidence
    ) throws {
        guard let step = dispatchedStep else {
            throw LLDBLogicalBreakpointTransactionCollectorError.noCommandAvailable
        }
        if evidence == .provenBeforeWrite {
            switch step {
            case .begin:
                beginMayHaveExecuted = false
            case .apply:
                mayHaveWritten = false
            case .upload, .receipt, .cleanup:
                break
            }
        }
        dispatchedStep = nil
        nextStep = nil
        failureWasRecorded = true
    }

    /// Promotes final bounded bytes to retainable authority only after the external strict codec
    /// has verified the aggregate digest, canonical schema, exact plan, and complete typed receipt.
    mutating func markCompleteReceiptValidated() throws {
        guard hasCompleteReceiptBytes,
              !hasValidatedCompleteReceipt,
              dispatchedStep == nil,
              nextStep == .cleanup,
              !failureCleanupForced,
              !cleanupAttempted,
              !cleanupIsUnavailable else {
            throw LLDBLogicalBreakpointTransactionCollectorError.receiptValidationUnavailable
        }
        hasValidatedCompleteReceipt = true
    }

    /// Abandons an unsuccessful transaction and makes cleanup the sole final command. An in-flight
    /// exchange must first be classified through `failDispatchedStep`; cleanup may never replace an
    /// unaccounted command which could still be executing on the retained adapter.
    mutating func forceCleanupAfterFailure() throws {
        guard beginMayHaveExecuted,
              dispatchedStep == nil,
              !cleanupProven,
              !cleanupAttempted,
              !cleanupIsUnavailable else {
            throw LLDBLogicalBreakpointTransactionCollectorError.cleanupUnavailable
        }
        nextStep = .cleanup
        failureWasRecorded = true
        failureCleanupForced = true
    }

    /// Records that cleanup cannot be attempted on the retained generation, for example after an
    /// adapter-invalidating exchange. This is evidence of failed/unproven cleanup without issuing
    /// a request that is already known to target a stale generation.
    mutating func markCleanupUnavailableAfterFailure() throws {
        guard failureWasRecorded,
              beginMayHaveExecuted,
              !cleanupProven,
              !cleanupIsUnavailable else {
            throw LLDBLogicalBreakpointTransactionCollectorError.cleanupUnavailable
        }
        cleanupIsUnavailable = true
        dispatchedStep = nil
        nextStep = nil
    }

    private var cleanupEvidence: LLDBLogicalBreakpointCleanupEvidence {
        if cleanupProven { return .proven }
        if cleanupAttempted || cleanupIsUnavailable { return .failedOrUnproven }
        if beginMayHaveExecuted { return .required }
        return .notRequired
    }

    private mutating func completeReceiptPage(
        pageIndex: Int,
        cursor: Int,
        payloadByteCount: Int,
        isFinal: Bool
    ) throws {
        guard pageIndex >= 0,
              pageIndex < reservation.receiptPageCountUpperBound,
              cursor == receivedReceiptBytes,
              payloadByteCount > 0,
              payloadByteCount <= LLDBLogicalBreakpointTransactionReservation
                .receiptPagePayloadByteCount,
              isFinal || payloadByteCount == LLDBLogicalBreakpointTransactionReservation
                .receiptPagePayloadByteCount else {
            throw LLDBLogicalBreakpointTransactionCollectorError.invalidReceiptPage
        }
        let total = receivedReceiptBytes.addingReportingOverflow(payloadByteCount)
        guard !total.overflow,
              total.partialValue <= reservation.receiptByteCountUpperBound else {
            throw LLDBLogicalBreakpointTransactionCollectorError.receiptCapacityExceeded
        }
        if !isFinal {
            guard pageIndex + 1 < reservation.receiptPageCountUpperBound else {
                throw LLDBLogicalBreakpointTransactionCollectorError.receiptCapacityExceeded
            }
        }

        dispatchedStep = nil
        receivedReceiptBytes = total.partialValue
        if isFinal {
            hasCompleteReceiptBytes = true
            nextStep = .cleanup
        } else {
            nextStep = .receipt(
                pageIndex: pageIndex + 1,
                cursor: receivedReceiptBytes
            )
        }
    }
}
