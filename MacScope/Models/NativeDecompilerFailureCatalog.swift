import Foundation

enum NativeDecompilerFailureCatalog {
    static let allRows: [NativeDecompilerFailurePresentation] = [
        row(1, "Native request cancelled", "The current native request was cancelled.", .requestAgain, true, .retry, nil, .exactPriorRefreshContentOrMacScope, "Retry the native request; exact prior content remains only after a cancelled Refresh."),
        row(2, "Native decompiler busy", "MacScope has reached its bounded native work limit.", .retrySameAuthority, true, .retry, nil, .exactPriorRefreshContentOrMacScope, "Retry with the same verified authority or use MacScope Analysis."),
        row(3, "Native decompilation failed", "The verified native operation did not complete.", .retrySameAuthority, true, .retry, nil, .exactPriorRefreshContentOrMacScope, "Retry with the same verified authority or use MacScope Analysis."),
        row(4, "Native runtime unavailable", "The verified native service is not currently available.", .retryAfterReadiness, true, .retry, nil, .disclosedMacScope, "Retry after the verified native runtime becomes available."),
        row(5, "Native runtime updating", "MacScope is revalidating the native runtime.", .retryAfterReadiness, true, .retry, nil, .disclosedMacScope, "Retry after MacScope finishes revalidating the native runtime."),
        row(6, "Native target unsupported", "The current image is not supported by the verified native profile.", .unsupportedForCurrentTarget, false, nil, .useMacScopeAnalysis, .disclosedMacScope, "Use MacScope Analysis for the current target."),
        row(7, "Native runtime verification failed", "MacScope could not verify the installed native runtime.", .repairRuntimeAuthority, false, nil, .useMacScopeAnalysis, .disclosedMacScope, "Repair the verified native runtime or use MacScope Analysis."),
        row(8, "Authored types need attention", "The current authored names or types cannot be applied exactly.", .repairAuthoredInput, false, nil, .reviewTypes, .disclosedMacScope, "Review authored types before submitting native work again."),
        row(9, "Native safety limit reached", "The native request or result exceeds MacScope’s safety limit.", .changeSemanticInput, false, nil, .useMacScopeAnalysis, .disclosedMacScope, "Change the semantic input or use MacScope Analysis."),
        row(10, "Native result rejected", "The native result did not match the current verified request.", .refreshCurrentAuthority, false, .refresh, .useMacScopeAnalysis, .disclosedMacScopeNeverRetainRejectedResult, "Refresh current authority or use MacScope Analysis; the rejected result is never retained."),
        row(11, "Native protocol error", "MacScope rejected an invalid native exchange.", .repairRuntimeAuthority, false, nil, .useMacScopeAnalysis, .disclosedMacScope, "Repair the verified native runtime or use MacScope Analysis."),
        row(12, "Native session ended", "This workspace can no longer submit native work.", .terminalOwner, false, nil, nil, .disclosedMacScope, "No native commands are available for this workspace."),
    ]

    static let unknownProtocolFailure = allRows[10]

    static func row(_ rowID: Int) -> NativeDecompilerFailurePresentation? {
        guard allRows.indices.contains(rowID - 1) else { return nil }
        return allRows[rowID - 1]
    }

    static func presentation(
        for reason: NativeDecompilerPresentationTerminalReason
    ) -> NativeDecompilerFailurePresentation {
        switch reason {
        case let .provider(code, _): presentation(for: code)
        case let .client(failure): presentation(for: failure)
        case .invalidReply: row(10)!
        case .transportFailure: row(4)!
        case let .projection(error): presentation(for: error)
        case let .runtimeValidation(error): presentation(for: error)
        case let .runtime(error): presentation(for: error)
        }
    }

    static func presentation(for code: NativeDecompilerWireFailureCode) -> NativeDecompilerFailurePresentation {
        switch code {
        case .cancelled: row(1)!
        case .busy: row(2)!
        case .nativeFailure, .timedOut: row(3)!
        case .unavailable: row(4)!
        case .unsupportedCompiler: row(6)!
        case .packageVerificationFailed: row(7)!
        case .requestTooLarge, .responseTooLarge: row(9)!
        case .requestIDMismatch: row(10)!
        case .malformedRequest, .malformedReply, .invalidRequest, .unsupportedSchemaVersion: row(11)!
        }
    }

    static func presentation(for failure: NativeDecompilerXPCClientFailure) -> NativeDecompilerFailurePresentation {
        switch failure {
        case .cancelled: row(1)!
        case .duplicateRequestIdentifier: row(2)!
        case .timedOut: row(3)!
        case .connectionFailure, .connectionUnavailable, .interrupted, .invalidated: row(4)!
        case .requestTooLarge, .responseTooLarge: row(9)!
        case .replyRequestMismatch: row(10)!
        case .requestEncodingFailed, .malformedReply: row(11)!
        }
    }

    static func presentation(
        for error: NativeDecompilerRuntimeValidationError
    ) -> NativeDecompilerFailurePresentation {
        switch error {
        case .runtimeAuthorityMismatch: row(7)!
        case .replyRuntimeIdentityMismatch: row(10)!
        }
    }

    static func presentation(
        for error: NativeDecompilerProcessRuntimeError
    ) -> NativeDecompilerFailurePresentation {
        switch error {
        case .staleEpoch, .runtimeTransitionInProgress: row(5)!
        case .runtimeAuthorityUnavailable: row(7)!
        case .shutDown: row(12)!
        }
    }

    static func presentation(
        for error: NativeDecompilerSnapshotProjectionError
    ) -> NativeDecompilerFailurePresentation {
        switch error {
        case .invalidBudgets, .functionExceedsBudget, .tooManyMemoryRegions,
             .tooManySymbols, .requestTooLarge:
            row(9)!
        // A loader layout the native profile cannot project is a property of the current
        // image, not a broken native exchange: present it as an unsupported target.
        case .unsupportedArchitecture, .patchedControlFlowLeavesFunction,
             .invalidSegmentLayout, .overlappingSegmentLayout,
             .missingHeaderMappingSegment:
            row(6)!
        case .unverifiedArtifact, .missingArtifactIdentity, .missingArtifactUUID,
             .effectiveLoadImageAuthorityUnavailable, .invalidEffectiveLoadImageAttestation:
            row(7)!
        case .analysisCoordinateMismatch, .analysisFingerprintMismatch, .selectedSliceMismatch:
            row(10)!
        case .binaryNotFound, .analysisNotFound, .functionNotFound, .missingSegmentLayout,
             .missingAnalysisFingerprint, .emptySelectedSlice, .invalidFunctionRange,
             .invalidPatchRange, .intersectingPatch, .invalidRelocationRange,
             .intersectingRelocation, .invalidFunctionCoverage, .invalidProjectedRequest:
            row(11)!
        }
    }

    private static func row(
        _ id: Int,
        _ title: String,
        _ explanation: String,
        _ recovery: NativeDecompilerRecoveryDisposition,
        _ retryable: Bool,
        _ primary: NativeDecompilerFailureAction?,
        _ secondary: NativeDecompilerFailureAction?,
        _ fallback: NativeDecompilerFallbackDisposition,
        _ accessibilityHint: String
    ) -> NativeDecompilerFailurePresentation {
        NativeDecompilerFailurePresentation(
            rowID: id,
            title: title,
            explanation: explanation,
            recovery: recovery,
            retryable: retryable,
            primaryAction: primary,
            secondaryAction: secondary,
            fallback: fallback,
            accessibilityLabel: title,
            accessibilityHint: accessibilityHint
        )
    }
}
