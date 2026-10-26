import XCTest
@testable import MacScope

final class DebuggerTransportDomainTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )

    func testTransportDomainValuesAreSendableAndHashable() {
        assertSendableAndHashable(DebuggerSessionEpoch.self)
        assertSendableAndHashable(DebuggerRequestID.self)
        assertSendableAndHashable(DebuggerLifecycleRevision.self)
        assertSendableAndHashable(DebuggerStopRevision.self)
        assertSendableAndHashable(DebuggerEventSequence.self)
        assertSendableAndHashable(DebuggerSessionCoordinate.self)
        assertSendableAndHashable(DebuggerStopCoordinate.self)
        assertSendableAndHashable(DebuggerRequestContext.self)
        assertSendableAndHashable(DebuggerTransportCapabilities.self)
        assertSendableAndHashable(DebuggerStoppedData.self)
        assertSendableAndHashable(DebuggerDiagnostic.self)
        assertSendableAndHashable(DebuggerEventEnvelope.self)
    }

    func testMonotonicValueTypesIncrementWithoutWrapping() {
        XCTAssertEqual(
            DebuggerLifecycleRevision(rawValue: 41).incremented(),
            DebuggerLifecycleRevision(rawValue: 42)
        )
        XCTAssertEqual(
            DebuggerStopRevision(rawValue: 7).incremented(),
            DebuggerStopRevision(rawValue: 8)
        )
        XCTAssertEqual(
            DebuggerEventSequence(rawValue: 99).incremented(),
            DebuggerEventSequence(rawValue: 100)
        )

        XCTAssertNil(DebuggerLifecycleRevision(rawValue: .max).incremented())
        XCTAssertNil(DebuggerStopRevision(rawValue: .max).incremented())
        XCTAssertNil(DebuggerEventSequence(rawValue: .max).incremented())
    }

    func testEverySemanticOperationHasTheFrozenClassification() {
        let expected: [DebuggerOperation: DebuggerOperationClassification] = [
            .launch: .sessionEstablishing,
            .attach: .sessionEstablishing,
            .continue: .lifecycleMutating,
            .runToCursor: .lifecycleMutating,
            .stepOver: .lifecycleMutating,
            .stepInto: .lifecycleMutating,
            .stepOut: .lifecycleMutating,
            .pause: .lifecycleMutating,
            .detach: .lifecycleMutating,
            .terminate: .lifecycleMutating,
            .replaceBreakpoints: .presentationOnly,
            .reconcileLogicalBreakpoints: .stoppedStateMutating,
            .writeRegister: .stoppedStateMutating,
            .readMemory: .stoppedStateReading,
            .writeMemory: .stoppedStateMutating,
            .updateWatchpoints: .stoppedStateMutating,
            .evaluateExpression: .stoppedStateReading,
            .expandVariableChildren: .stoppedStateReading,
            .selectThread: .stoppedStateMutating,
            .selectFrame: .stoppedStateMutating,
            .refreshSnapshot: .stoppedStateReading,
            .refreshRuntimeModules: .stoppedStateReading,
            .pollProcessStatus: .sessionObserving,
        ]

        XCTAssertEqual(Set(expected.keys), Set(DebuggerOperation.allCases))
        let stopBoundLifecycleOperations: Set<DebuggerOperation> = [
            .continue, .runToCursor, .stepOver, .stepInto, .stepOut,
        ]
        for operation in DebuggerOperation.allCases {
            XCTAssertEqual(operation.classification, expected[operation], "Unexpected classification for \(operation)")
            XCTAssertEqual(
                operation.requiresStopCoordinate,
                operation.classification == .stoppedStateMutating
                    || operation.classification == .stoppedStateReading
                    || stopBoundLifecycleOperations.contains(operation)
            )
        }

        XCTAssertFalse(DebuggerOperation.pollProcessStatus.requiresStopCoordinate)
    }

    func testSemanticOperationLabelsCannotBecomeRawLLDBCommands() {
        for operation in DebuggerOperation.allCases {
            XCTAssertFalse(operation.displayLabel.isEmpty)
            XCTAssertFalse(operation.displayLabel.contains(";"))
            XCTAssertFalse(operation.displayLabel.contains("\n"))
            XCTAssertFalse(operation.displayLabel.contains("`"))
            XCTAssertFalse(operation.displayLabel.contains("--"))
        }
    }

    func testRequestContextRequiresOneConsistentEpochAndExactStopCoordinate() {
        let session = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 3)
        )
        let stop = DebuggerStopCoordinate(
            session: session,
            stopRevision: DebuggerStopRevision(rawValue: 8)
        )
        let requestID = DebuggerRequestID(epoch: epoch, sequence: 12)

        let stoppedRead = DebuggerRequestContext(
            id: requestID,
            operation: .readMemory,
            expectedSession: session,
            requiredStop: stop
        )
        XCTAssertTrue(stoppedRead.isInternallyConsistent)

        let stoppedRun = DebuggerRequestContext(
            id: requestID,
            operation: .continue,
            expectedSession: session,
            requiredStop: stop
        )
        XCTAssertTrue(stoppedRun.isInternallyConsistent)

        let unboundRun = DebuggerRequestContext(
            id: requestID,
            operation: .stepOver,
            expectedSession: session
        )
        XCTAssertFalse(unboundRun.isInternallyConsistent)

        let missingStop = DebuggerRequestContext(
            id: requestID,
            operation: .readMemory,
            expectedSession: session
        )
        XCTAssertFalse(missingStop.isInternallyConsistent)

        let unexpectedStop = DebuggerRequestContext(
            id: requestID,
            operation: .pause,
            expectedSession: session,
            requiredStop: stop
        )
        XCTAssertFalse(unexpectedStop.isInternallyConsistent)

        let foreignEpoch = DebuggerSessionEpoch(
            rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        let foreignRequest = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: foreignEpoch, sequence: 12),
            operation: .continue,
            expectedSession: session
        )
        XCTAssertFalse(foreignRequest.isInternallyConsistent)

        let foreignStop = DebuggerRequestContext(
            id: requestID,
            operation: .selectFrame,
            expectedSession: session,
            requiredStop: DebuggerStopCoordinate(
                session: DebuggerSessionCoordinate(
                    epoch: epoch,
                    lifecycleRevision: DebuggerLifecycleRevision(rawValue: 2)
                ),
                stopRevision: DebuggerStopRevision(rawValue: 8)
            )
        )
        XCTAssertFalse(foreignStop.isInternallyConsistent)
    }

    func testPersistentCLICapabilitiesAreTotalAndAttachRemainsPolicyDenied() {
        let policyReason = "Production arbitrary attach remains closed during WS-19."
        let capabilities = DebuggerTransportCapabilities.persistentCLI(
            attachPolicyReason: policyReason
        )

        for operation in DebuggerOperation.allCases
            where operation != .attach && operation != .detach {
            XCTAssertEqual(capabilities.capability(for: operation), .supportedAndObserved)
            XCTAssertTrue(capabilities.capability(for: operation).isSupported)
        }
        XCTAssertEqual(
            capabilities.capability(for: .attach),
            .policyDenied(reason: policyReason)
        )
        XCTAssertFalse(capabilities.capability(for: .attach).isSupported)
        XCTAssertEqual(
            capabilities.capability(for: .detach),
            .policyDenied(reason: DebuggerTransportCapabilities.detachUnavailableReason)
        )
        XCTAssertFalse(capabilities.capability(for: .detach).isSupported)

        XCTAssertTrue(capabilities.mechanics.supportsExactCorrelatedTranscriptBoundaries)
        XCTAssertEqual(capabilities.mechanics.eventSource, .correlatedCLITranscript)
        XCTAssertTrue(capabilities.mechanics.supportsCancellationBeforeWrite)
        XCTAssertEqual(
            capabilities.mechanics.postWriteCancellationBehavior,
            .invalidateAdapterGeneration
        )
        XCTAssertTrue(capabilities.mechanics.transportFailureInvalidatesEpoch)
        XCTAssertTrue(capabilities.mechanics.rawConsoleSharesAcceptedSession)
        XCTAssertFalse(capabilities.mechanics.supportsPostFailureInterpreterReuse)
    }

    func testStoppedDataDistinguishesUnavailableFromAnObservedEmptyReplacement() {
        XCTAssertNotEqual(DebuggerStoppedData.unavailable, DebuggerStoppedData.empty)

        guard case .unavailable = DebuggerStoppedData.unavailable.frames else {
            return XCTFail("Unavailable parsing must remain distinct from an observed empty frame list.")
        }
        guard case .available(let frames) = DebuggerStoppedData.empty.frames else {
            return XCTFail("An observed empty frame list must be representable.")
        }
        XCTAssertTrue(frames.isEmpty)
        guard case .unavailable = DebuggerStoppedData.unavailable.variables else {
            return XCTFail("Unavailable variable evidence must remain explicit.")
        }
        guard case .available(let scopes) = DebuggerStoppedData.empty.variables else {
            return XCTFail("An observed empty variable projection must be representable.")
        }
        XCTAssertTrue(scopes.isEmpty)
    }

    func testEventEnvelopeCarriesEveryFrozenCorrelationCoordinate() {
        let requestID = DebuggerRequestID(epoch: epoch, sequence: 4)
        let envelope = DebuggerEventEnvelope(
            sessionEpoch: epoch,
            eventSequence: DebuggerEventSequence(rawValue: 9),
            requestID: requestID,
            operation: .refreshSnapshot,
            capturedLifecycleRevision: DebuggerLifecycleRevision(rawValue: 5),
            boundStopRevision: DebuggerStopRevision(rawValue: 3),
            payload: .stoppedDataRefreshed(.empty)
        )

        XCTAssertEqual(envelope.sessionEpoch, epoch)
        XCTAssertEqual(envelope.eventSequence, DebuggerEventSequence(rawValue: 9))
        XCTAssertEqual(envelope.requestID, requestID)
        XCTAssertEqual(envelope.operation, .refreshSnapshot)
        XCTAssertEqual(
            envelope.capturedLifecycleRevision,
            DebuggerLifecycleRevision(rawValue: 5)
        )
        XCTAssertEqual(envelope.boundStopRevision, DebuggerStopRevision(rawValue: 3))
        XCTAssertEqual(envelope.payload, .stoppedDataRefreshed(.empty))
    }

    func testRuntimeModuleRefreshEventCarriesOneCompleteExactStopPayload() throws {
        let range = try XCTUnwrap(DebuggerRuntimeModuleMappedRangeObservation(
            sectionOrdinal: 0,
            sectionName: "__TEXT",
            staticStart: 0x1000,
            runtimeStart: 0x9000,
            byteCount: 0x100,
            permissions: 5
        ))
        let observation = try XCTUnwrap(DebuggerRuntimeModuleObservation(
            uuid: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            processID: 42,
            observedStopID: 7,
            mappedRanges: [range],
            fullPath: "/tmp/Fixture",
            normalizedArchitectureTriple: "arm64-apple-macosx",
            displayIndex: 1,
            fingerprintSHA256: Data(repeating: 0xA5, count: 32)
        ))
        let payload = DebuggerRuntimeModulesRefreshPayload(
            observations: [observation],
            observedStopID: 7,
            processID: 42,
            adapterGeneration: 1
        )

        XCTAssertEqual(DebuggerEventPayload.runtimeModulesRefreshed(payload), .runtimeModulesRefreshed(payload))
        XCTAssertTrue(DebuggerOperation.refreshRuntimeModules.requiresStopCoordinate)
        XCTAssertEqual(DebuggerOperation.refreshRuntimeModules.classification, .stoppedStateReading)
        XCTAssertEqual(DebuggerOperation.refreshRuntimeModules.displayLabel, "Refresh Runtime Modules")
    }

    func testRequestDispositionsNeverOverclaimPostWriteCancellationOrFailure() {
        let dispositions: [DebuggerRequestDisposition] = [
            .cancelledBeforeWrite,
            .failedBeforeWrite,
            .invalidatedAfterWrite(reason: .cancellationAfterWrite, target: .unknown),
            .invalidatedAfterWrite(reason: .timeoutAfterWrite, target: .unknown),
            .invalidatedAfterWrite(reason: .endOfFileAfterWrite, target: .unknown),
            .invalidatedAfterWrite(reason: .oversizedTranscript, target: .unknown),
            .invalidatedAfterWrite(reason: .framingLoss, target: .unknown),
            .invalidatedAfterWrite(reason: .adapterFailure, target: .unknown),
        ]

        XCTAssertEqual(Set(dispositions).count, dispositions.count)
        for disposition in dispositions.dropFirst(2) {
            guard case .invalidatedAfterWrite(_, target: .unknown) = disposition else {
                return XCTFail("Post-write loss must leave target disposition unknown.")
            }
        }
    }

    func testDiagnosticUsesDeterministicSHA256() {
        let diagnostic = DebuggerDiagnostic.make(
            code: .operationFailed,
            severity: .error,
            rawText: "abc",
            targetDisposition: .notApplicable
        )

        XCTAssertEqual(
            diagnostic.fullContentSHA256,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(diagnostic.preview, "abc")
        XCTAssertEqual(diagnostic.originalByteCount, 3)
        XCTAssertFalse(diagnostic.isTruncated)
    }

    func testDiagnosticRedactsSecretsHomePathsAndControlCharactersBeforePublication() {
        let diagnostic = DebuggerDiagnostic.make(
            code: .transportFailure,
            severity: .warning,
            rawText: "env=alpha-token arg=--password=bravo condition=x0==secret expr=secretResult write=feedface /Users/example/work\nnext\t\u{0001}",
            operation: .evaluateExpression,
            sensitivityCatalog: DebuggerDiagnosticSensitivityCatalog(
                environmentValues: ["alpha-token"],
                authoredArguments: ["--password=bravo"],
                breakpointConditions: ["x0==secret"],
                expressionTextsAndResults: ["secretResult"],
                registerAndMemoryWriteValues: ["feedface"]
            ),
            userHomeDirectory: "/Users/example",
            targetDisposition: .unknown
        )

        XCTAssertFalse(diagnostic.preview.contains("alpha-token"))
        XCTAssertFalse(diagnostic.preview.contains("--password=bravo"))
        XCTAssertFalse(diagnostic.preview.contains("secretResult"))
        XCTAssertFalse(diagnostic.preview.contains("x0==secret"))
        XCTAssertFalse(diagnostic.preview.contains("feedface"))
        XCTAssertFalse(diagnostic.preview.contains("/Users/example"))
        XCTAssertTrue(diagnostic.preview.contains("env=<redacted>"))
        XCTAssertTrue(diagnostic.preview.contains("arg=<redacted>"))
        XCTAssertTrue(diagnostic.preview.contains("expr=<redacted>"))
        XCTAssertTrue(diagnostic.preview.contains("condition=<redacted>"))
        XCTAssertTrue(diagnostic.preview.contains("write=<redacted>"))
        XCTAssertTrue(diagnostic.preview.contains("<home>/work"))
        XCTAssertTrue(diagnostic.preview.contains("\\nnext\\t\\u{0001}"))
        XCTAssertFalse(diagnostic.preview.contains("\n"))
        XCTAssertFalse(diagnostic.preview.contains("\t"))
        XCTAssertEqual(diagnostic.semanticLabel, "Evaluate Expression")
        XCTAssertEqual(diagnostic.redactedByteCount, diagnostic.preview.utf8.count)
    }

    func testDiagnosticUsesLongestSensitiveMatchFirst() {
        let diagnostic = DebuggerDiagnostic.make(
            code: .protocolViolation,
            severity: .error,
            rawText: "abcdef abc",
            environmentValues: ["abc", "abcdef"],
            targetDisposition: .unknown
        )

        XCTAssertEqual(diagnostic.preview, "<redacted> <redacted>")
    }

    func testDiagnosticRedactsControlBearingSensitiveValuesBeforeEscaping() {
        let sensitiveResult = "secret\nvalue\t\u{0001}"
        let diagnostic = DebuggerDiagnostic.make(
            code: .operationFailed,
            severity: .error,
            rawText: "result=\(sensitiveResult) tail\n",
            sensitivityCatalog: DebuggerDiagnosticSensitivityCatalog(
                expressionTextsAndResults: [sensitiveResult]
            ),
            targetDisposition: .notApplicable
        )

        XCTAssertEqual(diagnostic.preview, "result=<redacted> tail\\n")
        XCTAssertFalse(diagnostic.preview.contains("secret"))
        XCTAssertFalse(diagnostic.preview.contains("value"))
        XCTAssertFalse(diagnostic.preview.contains("\n"))
        XCTAssertFalse(diagnostic.preview.contains("\t"))
    }

    func testDiagnosticRedactsSensitiveValueAcrossRawInputBoundBeforeTruncating() {
        let compressibleSecret = String(repeating: "B", count: 1_024)
        let boundarySecret = "boundary-secret"
        let rawText = String(repeating: compressibleSecret, count: 256) + boundarySecret
        XCTAssertGreaterThan(rawText.utf8.count, DebuggerDiagnostic.maximumInputByteCount)

        let diagnostic = DebuggerDiagnostic.make(
            code: .transportFailure,
            severity: .error,
            rawText: rawText,
            environmentValues: [compressibleSecret, boundarySecret],
            targetDisposition: .unknown
        )

        XCTAssertTrue(diagnostic.isTruncated)
        XCTAssertFalse(diagnostic.preview.contains("B"))
        XCTAssertFalse(diagnostic.preview.contains(boundarySecret))
        XCTAssertTrue(diagnostic.preview.hasSuffix("<redacted>"))
        XCTAssertLessThanOrEqual(
            diagnostic.preview.utf8.count,
            DebuggerDiagnostic.maximumPreviewByteCount
        )
    }

    func testDiagnosticBoundsInputAndPreviewOnUTF8ScalarBoundaries() {
        let oversized = String(repeating: "🙂", count: DebuggerDiagnostic.maximumInputByteCount)
        let diagnostic = DebuggerDiagnostic.make(
            code: .transportFailure,
            severity: .error,
            rawText: oversized,
            targetDisposition: .unknown
        )

        XCTAssertEqual(
            diagnostic.originalByteCount,
            DebuggerDiagnostic.maximumInputByteCount * 4
        )
        XCTAssertLessThanOrEqual(
            diagnostic.preview.utf8.count,
            DebuggerDiagnostic.maximumPreviewByteCount
        )
        XCTAssertTrue(diagnostic.isTruncated)
        XCTAssertFalse(diagnostic.preview.contains("�"))

        let boundedSource = String(
            repeating: "🙂",
            count: DebuggerDiagnostic.maximumInputByteCount / 4
        )
        let boundedDiagnostic = DebuggerDiagnostic.make(
            code: .transportFailure,
            severity: .error,
            rawText: boundedSource,
            targetDisposition: .unknown
        )
        XCTAssertEqual(diagnostic.fullContentSHA256, boundedDiagnostic.fullContentSHA256)
    }

    private func assertSendableAndHashable<T: Sendable & Hashable>(_ type: T.Type) {}
}
