import XCTest
@testable import MacScope

final class LLDBLogicalBreakpointTransactionCollectorTests: XCTestCase {
    func testReservationCoversFrozenWorstCaseBeforeAdmission() throws {
        let reservation = try LLDBLogicalBreakpointTransactionReservation(
            helperPreparation: .proveInstallAndReprove,
            planPageCount: LLDBLogicalBreakpointProgram.maximumPlanPageCount,
            receiptByteCountUpperBound: LLDBLogicalBreakpointProgram.maximumReceiptBytes
        )

        let expectedReceiptPages = 1_366
        let expectedHelperRequests = LLDBLogicalBreakpointProgram.current.installChunkCommands.count + 3
        let expectedTransactionRequests = 1
            + LLDBLogicalBreakpointProgram.maximumPlanPageCount
            + 1
            + expectedReceiptPages
            + 1
        XCTAssertEqual(reservation.receiptPageCountUpperBound, expectedReceiptPages)
        XCTAssertEqual(reservation.helperPreparationRequestCount, expectedHelperRequests)
        XCTAssertEqual(reservation.transactionRequestCount, expectedTransactionRequests)
        XCTAssertEqual(
            reservation.physicalRequestCount,
            expectedHelperRequests + expectedTransactionRequests
        )
        XCTAssertEqual(reservation.eventSequenceCount, 1)
        XCTAssertEqual(reservation.cleanupPhysicalRequestOffset, reservation.physicalRequestCount - 1)
    }

    func testReservationRejectsAnyUnboundedPageOrReceiptInput() {
        XCTAssertThrowsError(try reservation(planPages: 0, receiptBytes: 1))
        XCTAssertThrowsError(try reservation(
            planPages: LLDBLogicalBreakpointProgram.maximumPlanPageCount + 1,
            receiptBytes: 1
        ))
        XCTAssertThrowsError(try reservation(planPages: 1, receiptBytes: 0))
        XCTAssertThrowsError(try reservation(
            planPages: 1,
            receiptBytes: LLDBLogicalBreakpointProgram.maximumReceiptBytes + 1
        ))
    }

    func testHappyPathTracksExactOrderAndMarksWriteOnlyWhenApplyDispatches() throws {
        var collector = try makeCollector(planPages: 2, receiptBytes: 1_600)

        XCTAssertEqual(try collector.dispatchNextStep(), .begin)
        XCTAssertFalse(collector.mayHaveWritten)
        try collector.completeDispatchedStep()

        XCTAssertEqual(try collector.dispatchNextStep(), .upload(pageIndex: 0))
        try collector.completeDispatchedStep()
        XCTAssertEqual(try collector.dispatchNextStep(), .upload(pageIndex: 1))
        try collector.completeDispatchedStep()

        XCTAssertEqual(try collector.dispatchNextStep(), .apply)
        XCTAssertTrue(collector.mayHaveWritten)
        try collector.completeDispatchedStep()

        XCTAssertEqual(try collector.dispatchNextStep(), .receipt(pageIndex: 0, cursor: 0))
        try collector.completeDispatchedStep(
            .receiptPage(payloadByteCount: 1_536, isFinal: false)
        )
        XCTAssertEqual(try collector.dispatchNextStep(), .receipt(pageIndex: 1, cursor: 1_536))
        try collector.completeDispatchedStep(
            .receiptPage(payloadByteCount: 64, isFinal: true)
        )
        XCTAssertTrue(collector.hasCompleteReceiptBytes)
        XCTAssertFalse(collector.hasValidatedCompleteReceipt)
        try collector.markCompleteReceiptValidated()
        XCTAssertTrue(collector.hasValidatedCompleteReceipt)

        XCTAssertEqual(try collector.dispatchNextStep(), .cleanup)
        try collector.completeDispatchedStep()
        XCTAssertTrue(collector.cleanupProven)
        XCTAssertTrue(collector.isComplete)
        XCTAssertThrowsError(try collector.dispatchNextStep())
    }

    func testCleanupCannotRunBeforeReceiptOnSuccessfulPath() throws {
        var collector = try makeCollector(planPages: 1, receiptBytes: 1)
        XCTAssertThrowsError(try collector.forceCleanupAfterFailure())

        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()

        XCTAssertEqual(collector.nextStep, .receipt(pageIndex: 0, cursor: 0))
        XCTAssertThrowsError(try collector.completeDispatchedStep())
    }

    func testPreApplyFailureRequiresCleanupButNeverClaimsTargetWrite() throws {
        var collector = try makeCollector(planPages: 1, receiptBytes: 1)
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        _ = try collector.dispatchNextStep()

        XCTAssertEqual(
            collector.failureClassification,
            .cancelBeforeWrite(cleanup: .required)
        )
        XCTAssertThrowsError(try collector.forceCleanupAfterFailure())
        try collector.failDispatchedStep(.writeUncertain)
        try collector.forceCleanupAfterFailure()
        XCTAssertEqual(try collector.dispatchNextStep(), .cleanup)
        try collector.completeDispatchedStep()
        XCTAssertEqual(
            collector.failureClassification,
            .cancelBeforeWrite(cleanup: .proven)
        )
    }

    func testApplyUncertaintyRequiresMalformedRejectionInvalidationAndReap() throws {
        var collector = try makeCollector(planPages: 1, receiptBytes: 1)
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        XCTAssertEqual(try collector.dispatchNextStep(), .apply)

        XCTAssertEqual(
            collector.failureClassification,
            .rejectMalformedAfterPossibleWrite(
                cleanup: .required,
                retainValidatedCompleteReceipt: false,
                targetRecoveryRequired: true
            )
        )
    }

    func testApplyAdapterProofBeforeWriteDowngradesToCancellation() throws {
        var collector = try makeCollector(planPages: 1, receiptBytes: 1)
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        XCTAssertEqual(try collector.dispatchNextStep(), .apply)
        XCTAssertTrue(collector.mayHaveWritten)

        try collector.failDispatchedStep(.provenBeforeWrite)

        XCTAssertFalse(collector.mayHaveWritten)
        XCTAssertEqual(
            collector.failureClassification,
            .cancelBeforeWrite(cleanup: .required)
        )
        try collector.forceCleanupAfterFailure()
        XCTAssertEqual(try collector.dispatchNextStep(), .cleanup)
    }

    func testFinalReceiptBytesAreNotRetainableUntilExplicitValidation() throws {
        var collector = try advancedToReceipt(receiptBytes: 1)
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep(.receiptPage(payloadByteCount: 1, isFinal: true))

        XCTAssertTrue(collector.hasCompleteReceiptBytes)
        XCTAssertFalse(collector.hasValidatedCompleteReceipt)
        XCTAssertEqual(
            collector.failureClassification,
            .rejectMalformedAfterPossibleWrite(
                cleanup: .required,
                retainValidatedCompleteReceipt: false,
                targetRecoveryRequired: true
            )
        )
        XCTAssertThrowsError(try collector.dispatchNextStep())

        try collector.markCompleteReceiptValidated()
        XCTAssertEqual(
            collector.failureClassification,
            .rejectMalformedAfterPossibleWrite(
                cleanup: .required,
                retainValidatedCompleteReceipt: true,
                targetRecoveryRequired: true
            )
        )
        XCTAssertEqual(try collector.dispatchNextStep(), .cleanup)
    }

    func testCleanupUnavailableRecordsFailedEvidenceWithoutDispatch() throws {
        var collector = try makeCollector(planPages: 1, receiptBytes: 1)
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        _ = try collector.dispatchNextStep()
        try collector.failDispatchedStep(.writeUncertain)

        try collector.markCleanupUnavailableAfterFailure()

        XCTAssertEqual(
            collector.failureClassification,
            .cancelBeforeWrite(cleanup: .failedOrUnproven)
        )
        XCTAssertThrowsError(try collector.forceCleanupAfterFailure())
        XCTAssertThrowsError(try collector.dispatchNextStep())
    }

    func testCompleteReceiptSurvivesCleanupFailureClassification() throws {
        var collector = try makeCollector(planPages: 1, receiptBytes: 1)
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep(.receiptPage(payloadByteCount: 1, isFinal: true))
        try collector.markCompleteReceiptValidated()
        XCTAssertEqual(try collector.dispatchNextStep(), .cleanup)

        XCTAssertEqual(
            collector.failureClassification,
            .rejectMalformedAfterPossibleWrite(
                cleanup: .failedOrUnproven,
                retainValidatedCompleteReceipt: true,
                targetRecoveryRequired: true
            )
        )
    }

    func testNonfinalReceiptMustFillPageAndCannotExceedReservedBound() throws {
        var shortPage = try advancedToReceipt(receiptBytes: 1_600)
        _ = try shortPage.dispatchNextStep()
        XCTAssertThrowsError(try shortPage.completeDispatchedStep(
            .receiptPage(payloadByteCount: 1_535, isFinal: false)
        ))

        var overflow = try advancedToReceipt(receiptBytes: 1)
        _ = try overflow.dispatchNextStep()
        XCTAssertThrowsError(try overflow.completeDispatchedStep(
            .receiptPage(payloadByteCount: 2, isFinal: true)
        ))
    }

    private func reservation(
        planPages: Int,
        receiptBytes: Int
    ) throws -> LLDBLogicalBreakpointTransactionReservation {
        try LLDBLogicalBreakpointTransactionReservation(
            helperPreparation: .alreadyProvenForGeneration,
            planPageCount: planPages,
            receiptByteCountUpperBound: receiptBytes
        )
    }

    private func makeCollector(
        planPages: Int,
        receiptBytes: Int
    ) throws -> LLDBLogicalBreakpointTransactionCollector {
        LLDBLogicalBreakpointTransactionCollector(
            reservation: try reservation(planPages: planPages, receiptBytes: receiptBytes)
        )
    }

    private func advancedToReceipt(
        receiptBytes: Int
    ) throws -> LLDBLogicalBreakpointTransactionCollector {
        var collector = try makeCollector(planPages: 1, receiptBytes: receiptBytes)
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        _ = try collector.dispatchNextStep()
        try collector.completeDispatchedStep()
        return collector
    }
}
