import XCTest
@testable import MacScope

final class NativeDecompilerFailurePresentationTests: XCTestCase {
    func testClosedCatalogContainsTheExactTwelveRows() throws {
        let rows = NativeDecompilerFailureCatalog.allRows
        XCTAssertEqual(rows.map(\.rowID), Array(1 ... 12))
        XCTAssertEqual(rows.map(\.title), [
            "Native request cancelled",
            "Native decompiler busy",
            "Native decompilation failed",
            "Native runtime unavailable",
            "Native runtime updating",
            "Native target unsupported",
            "Native runtime verification failed",
            "Authored types need attention",
            "Native safety limit reached",
            "Native result rejected",
            "Native protocol error",
            "Native session ended",
        ])
        XCTAssertEqual(try XCTUnwrap(NativeDecompilerFailureCatalog.row(10)).primaryAction, .refresh)
        XCTAssertEqual(
            try XCTUnwrap(NativeDecompilerFailureCatalog.row(10)).fallback,
            .disclosedMacScopeNeverRetainRejectedResult
        )
    }

    func testEveryCatalogTupleIsStableAndComplete() {
        let expected: [(NativeDecompilerRecoveryDisposition, Bool, NativeDecompilerFailureAction?, NativeDecompilerFailureAction?, NativeDecompilerFallbackDisposition)] = [
            (.requestAgain, true, .retry, nil, .exactPriorRefreshContentOrMacScope),
            (.retrySameAuthority, true, .retry, nil, .exactPriorRefreshContentOrMacScope),
            (.retrySameAuthority, true, .retry, nil, .exactPriorRefreshContentOrMacScope),
            (.retryAfterReadiness, true, .retry, nil, .disclosedMacScope),
            (.retryAfterReadiness, true, .retry, nil, .disclosedMacScope),
            (.unsupportedForCurrentTarget, false, nil, .useMacScopeAnalysis, .disclosedMacScope),
            (.repairRuntimeAuthority, false, nil, .useMacScopeAnalysis, .disclosedMacScope),
            (.repairAuthoredInput, false, nil, .reviewTypes, .disclosedMacScope),
            (.changeSemanticInput, false, nil, .useMacScopeAnalysis, .disclosedMacScope),
            (.refreshCurrentAuthority, false, .refresh, .useMacScopeAnalysis, .disclosedMacScopeNeverRetainRejectedResult),
            (.repairRuntimeAuthority, false, nil, .useMacScopeAnalysis, .disclosedMacScope),
            (.terminalOwner, false, nil, nil, .disclosedMacScope),
        ]
        XCTAssertEqual(NativeDecompilerFailureCatalog.allRows.count, expected.count)
        for (row, tuple) in zip(NativeDecompilerFailureCatalog.allRows, expected) {
            XCTAssertEqual(row.recovery, tuple.0, "row \(row.rowID) recovery")
            XCTAssertEqual(row.retryable, tuple.1, "row \(row.rowID) retryable")
            XCTAssertEqual(row.primaryAction, tuple.2, "row \(row.rowID) primary")
            XCTAssertEqual(row.secondaryAction, tuple.3, "row \(row.rowID) secondary")
            XCTAssertEqual(row.fallback, tuple.4, "row \(row.rowID) fallback")
            XCTAssertFalse(row.explanation.isEmpty, "row \(row.rowID) explanation")
            XCTAssertEqual(row.accessibilityLabel, row.title, "row \(row.rowID) label")
            XCTAssertFalse(row.accessibilityHint.isEmpty, "row \(row.rowID) hint")
        }
    }

    func testEveryCurrentProviderAndClientCaseMapsExactlyOnce() {
        let providerRows: [NativeDecompilerWireFailureCode: Int] = [
            .busy: 2, .cancelled: 1, .invalidRequest: 11, .malformedReply: 11,
            .malformedRequest: 11, .nativeFailure: 3, .packageVerificationFailed: 7,
            .requestIDMismatch: 10, .requestTooLarge: 9, .responseTooLarge: 9,
            .timedOut: 3, .unavailable: 4, .unsupportedCompiler: 6,
            .unsupportedSchemaVersion: 11,
        ]
        XCTAssertEqual(Set(providerRows.keys), Set(NativeDecompilerWireFailureCode.allCases))
        for (source, rowID) in providerRows {
            XCTAssertEqual(
                NativeDecompilerFailureCatalog.presentation(for: .provider(source)).rowID,
                rowID,
                "provider case \(source)"
            )
        }

        let clientRows: [NativeDecompilerXPCClientFailure: Int] = [
            .cancelled: 1, .connectionFailure: 4, .connectionUnavailable: 4,
            .duplicateRequestIdentifier: 2, .interrupted: 4, .invalidated: 4,
            .malformedReply: 11, .replyRequestMismatch: 10, .requestEncodingFailed: 11,
            .requestTooLarge: 9, .responseTooLarge: 9, .timedOut: 3,
        ]
        XCTAssertEqual(Set(clientRows.keys), Set(NativeDecompilerXPCClientFailure.allCases))
        for (source, rowID) in clientRows {
            XCTAssertEqual(
                NativeDecompilerFailureCatalog.presentation(for: .client(source)).rowID,
                rowID,
                "client case \(source)"
            )
        }
    }

    func testEveryCurrentProjectionCaseMapsToTheFrozenRow() {
        let cases: [(NativeDecompilerSnapshotProjectionError, Int)] = [
            (.invalidBudgets, 9), (.binaryNotFound, 11), (.analysisNotFound, 11),
            (.functionNotFound, 11), (.unverifiedArtifact, 7), (.missingArtifactIdentity, 7),
            (.missingArtifactUUID, 7), (.unsupportedArchitecture, 6), (.missingSegmentLayout, 11),
            (.invalidSegmentLayout, 6), (.overlappingSegmentLayout, 6),
            (.missingHeaderMappingSegment, 6), (.missingAnalysisFingerprint, 11),
            (.analysisCoordinateMismatch, 10), (.analysisFingerprintMismatch, 10),
            (.emptySelectedSlice, 11), (.selectedSliceMismatch, 10), (.invalidFunctionRange, 11),
            (.functionExceedsBudget, 9), (.invalidPatchRange, 11), (.intersectingPatch, 11),
            (.patchedControlFlowLeavesFunction, 6),
            (.invalidRelocationRange, 11), (.intersectingRelocation, 11),
            (.effectiveLoadImageAuthorityUnavailable, 7), (.invalidEffectiveLoadImageAttestation, 7),
            (.invalidFunctionCoverage, 11), (.tooManyMemoryRegions, 9), (.tooManySymbols, 9),
            (.requestTooLarge, 9), (.invalidProjectedRequest, 11),
        ]
        XCTAssertEqual(cases.count, 31)
        for (source, rowID) in cases {
            XCTAssertEqual(
                NativeDecompilerFailureCatalog.presentation(for: .projection(source)).rowID,
                rowID,
                "projection case \(source)"
            )
        }
    }

    func testRuntimeAuthorityAndReplyIdentityRemainDistinct() {
        XCTAssertEqual(
            NativeDecompilerFailureCatalog.presentation(
                for: .runtimeValidation(.runtimeAuthorityMismatch)
            ).rowID,
            7
        )
        XCTAssertEqual(
            NativeDecompilerFailureCatalog.presentation(
                for: .runtimeValidation(.replyRuntimeIdentityMismatch)
            ).rowID,
            10
        )
    }

    func testUnknownFutureCodeFailsClosedWithoutRawDetail() {
        let row = NativeDecompilerFailureCatalog.unknownProtocolFailure
        XCTAssertEqual(row.rowID, 11)
        XCTAssertEqual(row.title, "Native protocol error")
        XCTAssertFalse(row.explanation.contains("FUTURE_RAW_DETAIL"))
        XCTAssertFalse(row.accessibilityHint.contains("FUTURE_RAW_DETAIL"))
    }
}
