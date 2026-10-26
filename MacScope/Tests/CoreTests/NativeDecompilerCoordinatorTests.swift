import Foundation

#if NATIVE_DECOMPILER_COORDINATOR_FOCUSED_MAIN
@main
private enum NativeDecompilerCoordinatorFocusedMain {
    static func main() async {
        let tests: [(String, @Sendable () async throws -> Void)] = [
            ("policy defaults enabled", NativeDecompilerCoordinatorScenarios.policyDefaultsEnabled),
            ("disabled performs zero dispatch", NativeDecompilerCoordinatorScenarios.disabledPerformsZeroDispatch),
            ("enabled dispatch freezes immutable request", NativeDecompilerCoordinatorScenarios.enabledDispatchFreezesRequest),
            ("cancellation suppresses late completion", NativeDecompilerCoordinatorScenarios.cancellationSuppressesLateCompletion),
            ("owner-scoped cancellation preserves replacement", NativeDecompilerCoordinatorScenarios.ownerScopedCancellationCannotCancelReplacement),
            ("rapid replacement publishes latest only", NativeDecompilerCoordinatorScenarios.rapidReplacementPublishesLatestOnly),
            ("failures remain observational", NativeDecompilerCoordinatorScenarios.failuresRemainObservational),
            ("history and mismatches stay bounded", NativeDecompilerCoordinatorScenarios.historyAndMismatchesStayBounded),
        ]

        var failures = 0
        for (name, test) in tests {
            do {
                try await test()
                print("PASS: \(name)")
            } catch {
                failures += 1
                fputs("FAIL: \(name): \(error)\n", stderr)
            }
        }
        if failures > 0 { exit(1) }
    }
}
#else
import XCTest
@testable import MacScope

final class NativeDecompilerCoordinatorTests: XCTestCase {
    func testAdmissionFenceExhaustionFailsClosedWithoutWrappingOrTrapping() {
        let fence = NativeDecompilerAdmissionFence(maximumGeneration: 1)

        XCTAssertNotNil(fence.advance())
        XCTAssertNil(fence.advance())
        XCTAssertNil(fence.advance())
    }

    func testCoordinatorGenerationExhaustionBecomesTerminal() async {
        let dispatcher = NativeDecompilerTestDispatcher(mode: .success)
        let coordinator = NativeDecompilerCoordinator(
            policy: .enabled,
            dispatcher: dispatcher,
            configuration: .init(maximumGeneration: 1),
            logSink: { _ in }
        )

        let first = await coordinator.submit(makeSubmission(label: "first"))
        let exhausted = await coordinator.submit(makeSubmission(label: "exhausted"))
        let stillExhausted = await coordinator.submit(makeSubmission(label: "still-exhausted"))
        XCTAssertTrue(first)
        XCTAssertFalse(exhausted)
        XCTAssertFalse(stillExhausted)
    }

    func testPolicyDefaultsEnabled() async throws {
        try await NativeDecompilerCoordinatorScenarios.policyDefaultsEnabled()
    }

    func testDisabledPerformsZeroDispatch() async throws {
        try await NativeDecompilerCoordinatorScenarios.disabledPerformsZeroDispatch()
    }

    func testEnabledDispatchFreezesImmutableRequest() async throws {
        try await NativeDecompilerCoordinatorScenarios.enabledDispatchFreezesRequest()
    }

    func testCancellationSuppressesLateCompletion() async throws {
        try await NativeDecompilerCoordinatorScenarios.cancellationSuppressesLateCompletion()
    }

    func testOwnerScopedCancellationCannotCancelReplacement() async throws {
        try await NativeDecompilerCoordinatorScenarios.ownerScopedCancellationCannotCancelReplacement()
    }

    func testRapidReplacementPublishesLatestOnly() async throws {
        try await NativeDecompilerCoordinatorScenarios.rapidReplacementPublishesLatestOnly()
    }

    func testFailuresRemainObservational() async throws {
        try await NativeDecompilerCoordinatorScenarios.failuresRemainObservational()
    }

    func testHistoryAndMismatchesStayBounded() async throws {
        try await NativeDecompilerCoordinatorScenarios.historyAndMismatchesStayBounded()
    }

    func testReplyRuntimeIdentityMismatchNeverPublishesAsReady() async throws {
        let dispatcher = NativeDecompilerTestDispatcher(mode: .success)
        let coordinator = NativeDecompilerCoordinator(
            policy: .enabled,
            dispatcher: dispatcher,
            logSink: { _ in }
        )
        let expected = NativeDecompilerRuntimeIdentity(
            backendID: "independently-attested-backend",
            engineVersion: "12.1.2",
            engineRevision: String(repeating: "b", count: 40),
            wrapperVersion: "dcp03b5-v1",
            wrapperRevision: String(repeating: "c", count: 40),
            packageManifestSHA256: String(repeating: "d", count: 64),
            packageTreeSHA256: String(repeating: "e", count: 64),
            languageID: "AARCH64:LE:64:AppleSilicon",
            compilerSpecID: "default",
            targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
            contextProfileSHA256:
                "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5"
        )

        let completion = try await coordinator.perform(
            makeSubmission(label: "identity-mismatch"),
            executionToken: UUID(),
            expectedRuntimeIdentity: expected
        )

        XCTAssertEqual(completion, .terminal(.invalidReply))
        let observations = await coordinator.observationSnapshot()
        XCTAssertEqual(observations.map(\.status), [.invalidReply])
    }
}
#endif

private enum NativeDecompilerCoordinatorScenarios {
    static func policyDefaultsEnabled() async throws {
        try expect(
            NativeDecompilerRuntimePolicy.productPolicy(environment: [:], defaultsValue: nil)
                == .enabled,
            "absence of an override must enable native product execution"
        )
        try expect(
            NativeDecompilerRuntimePolicy.productPolicy(environment: [:], defaultsValue: true)
                .isEnabled,
            "an explicitly injected product default should enable native execution"
        )
        try expect(
            NativeDecompilerRuntimePolicy.productPolicy(
                environment: [NativeDecompilerRuntimePolicy.environmentKey: "yes"],
                defaultsValue: false
            ).isEnabled,
            "the explicit environment flag should enable native execution"
        )
        try expect(
            !NativeDecompilerRuntimePolicy.productPolicy(
                environment: [NativeDecompilerRuntimePolicy.environmentKey: "0"],
                defaultsValue: true
            ).isEnabled,
            "an explicit false environment flag must override the product default"
        )
        try expect(
            NativeDecompilerRuntimePolicy.productPolicy(
                environment: [NativeDecompilerRuntimePolicy.environmentKey: "invalid"],
                defaultsValue: false
            ).isEnabled,
            "an invalid environment token must use the enabled product default"
        )
    }

    static func disabledPerformsZeroDispatch() async throws {
        let dispatcher = NativeDecompilerTestDispatcher(mode: .success)
        let logs = NativeDecompilerTestLogSink()
        let coordinator = NativeDecompilerCoordinator(
            dispatcher: dispatcher,
            logSink: logs.record
        )

        let accepted = await coordinator.submit(makeSubmission(label: "disabled"))

        try expect(!accepted, "disabled native execution must reject submissions")
        let dispatchCount = await dispatcher.callCount
        let observations = await coordinator.observationSnapshot()
        try expect(dispatchCount == 0, "disabled native execution dispatched work")
        try expect(observations.isEmpty, "disabled execution recorded metadata")
        try expect(logs.snapshot.isEmpty, "disabled execution emitted an operational log")
    }

    static func enabledDispatchFreezesRequest() async throws {
        let dispatcher = NativeDecompilerTestDispatcher(mode: .success)
        let logs = NativeDecompilerTestLogSink()
        let clock = NativeDecompilerTestClock(values: [1_000_000, 8_000_000])
        var sourceBytes = Data([0xc0, 0x03, 0x5f, 0xd6])
        let submission = makeSubmission(
            label: "immutable",
            bytes: sourceBytes,
            referenceCounts: .init(instructions: 1, blocks: 1, edges: 0, calls: 0)
        )
        sourceBytes[0] = 0xff
        let coordinator = NativeDecompilerCoordinator(
            policy: .init(isEnabled: true),
            dispatcher: dispatcher,
            monotonicNanoseconds: clock.next,
            logSink: logs.record
        )

        let accepted = await coordinator.submit(submission)
        try expect(accepted, "enabled coordinator rejected submission")
        try await waitUntil("successful dispatch did not finish") {
            await coordinator.observationSnapshot().count == 1
        }

        let requests = await dispatcher.requests
        try expect(requests.count == 1, "enabled coordinator must dispatch exactly once")
        let request = try unwrap(requests.first, "missing dispatched request")
        try expect(
            request.body.memoryRegions.first?.effectiveBytes == Data([0xc0, 0x03, 0x5f, 0xd6]),
            "submission did not freeze effective bytes by value"
        )
        try expect(
            request.body.memoryRegions.first?.rawBytes == Data([0xc0, 0x03, 0x5f, 0xd6]),
            "submission did not freeze provenance bytes by value"
        )
        try expect(request.requestID == request.body.requestID, "client request identity was not rebound atomically")

        let observations = await coordinator.observationSnapshot()
        try expect(observations.count == 1, "successful dispatch must record one observation")
        let observation = try unwrap(observations.first, "missing success observation")
        try expect(observation.status == .success, "successful dispatch recorded the wrong status")
        try expect(observation.durationMilliseconds == 7, "monotonic duration was not recorded")
        try expect(observation.recordCounts?.instructions == 1, "instruction count was not recorded")
        try expect(observation.mismatchCategories.isEmpty, "matching structural counts reported mismatches")
        try expect(observation.provider?.backendID == "native-decompiler", "provider identity was not recorded")
        try expect(observation.function.functionID == "function:immutable", "function identity was not recorded")
        try expect(logs.snapshot.count == 1, "successful dispatch must emit one bounded operational log")
    }

    static func cancellationSuppressesLateCompletion() async throws {
        let dispatcher = NativeDecompilerTestDispatcher(mode: .suspendedSuccess)
        let logs = NativeDecompilerTestLogSink()
        let coordinator = NativeDecompilerCoordinator(
            policy: .init(isEnabled: true),
            dispatcher: dispatcher,
            logSink: logs.record
        )

        let accepted = await coordinator.submit(makeSubmission(label: "cancelled"))
        try expect(accepted, "submission was rejected")
        try await waitUntil("dispatcher never received suspended request") {
            await dispatcher.callCount == 1
        }
        await coordinator.cancel()
        await dispatcher.resumeAllSuspended()
        try await waitUntil("cancelled completion never returned to the coordinator") {
            await dispatcher.completedCallCount == 1
        }
        for _ in 0..<20 { await Task.yield() }
        let cancelledObservations = await coordinator.observationSnapshot()
        try expect(
            cancelledObservations.isEmpty,
            "a completion arriving after explicit cancellation must be suppressed"
        )
        try expect(logs.snapshot.isEmpty, "a late cancelled completion must not be logged as terminal")

        await dispatcher.setMode(.success)
        let freshAccepted = await coordinator.submit(makeSubmission(label: "fresh"))
        try expect(freshAccepted, "fresh submission was rejected")
        try await waitUntil("fresh generation did not finish") {
            await coordinator.observationSnapshot().count == 1
        }

        let freshObservations = await coordinator.observationSnapshot()
        try expect(
            freshObservations.count == 1,
            "a fresh generation should produce exactly one observation"
        )
        try expect(logs.snapshot.count == 1, "a fresh generation should log exactly once")
    }

    static func ownerScopedCancellationCannotCancelReplacement() async throws {
        let dispatcher = NativeDecompilerTestDispatcher(mode: .suspendedSuccess)
        let coordinator = NativeDecompilerCoordinator(
            policy: .init(isEnabled: true),
            dispatcher: dispatcher,
            logSink: { _ in }
        )
        let displacedOwner = UUID()
        let currentOwner = UUID()

        let displacedAccepted = await coordinator.submit(
            makeSubmission(label: "displaced-owner"),
            ownerToken: displacedOwner
        )
        try expect(displacedAccepted, "displaced owner submission was rejected")
        try await waitUntil("displaced owner never entered dispatch") {
            await dispatcher.callCount == 1
        }

        let currentAccepted = await coordinator.submit(
            makeSubmission(label: "current-owner"),
            ownerToken: currentOwner
        )
        try expect(currentAccepted, "current owner submission was rejected")
        try await waitUntil("current owner never entered dispatch") {
            await dispatcher.callCount == 2
        }

        await coordinator.cancel(ownerToken: displacedOwner)
        await dispatcher.resumeAllSuspended()
        try await waitUntil("current owner completion did not publish") {
            await coordinator.observationSnapshot().first?.function.functionID
                == "function:current-owner"
        }
        let observations = await coordinator.observationSnapshot()
        try expect(observations.count == 1, "late displaced-owner cancellation changed the result")
    }

    static func rapidReplacementPublishesLatestOnly() async throws {
        let dispatcher = NativeDecompilerTestDispatcher(mode: .success)
        let admission = NativeDecompilerTestAdmissionGate()
        let logs = NativeDecompilerTestLogSink()
        let coordinator = NativeDecompilerCoordinator(
            policy: .init(isEnabled: true),
            dispatcher: dispatcher,
            logSink: logs.record,
            dispatchAdmission: admission.wait
        )

        let obsoleteAccepted = await coordinator.submit(makeSubmission(label: "obsolete"))
        try await waitUntil("obsolete generation never reached the admission barrier") {
            await admission.entryCount == 1
        }
        let currentAccepted = await coordinator.submit(makeSubmission(label: "current"))
        try expect(obsoleteAccepted && currentAccepted, "rapid replacement rejected a submission")
        try await waitUntil("current generation never reached the admission barrier") {
            await admission.entryCount == 2
        }
        await admission.releaseAll()
        try await waitUntil("current generation did not publish") {
            await coordinator.observationSnapshot().first?.function.functionID == "function:current"
        }
        for _ in 0..<20 { await Task.yield() }

        let observations = await coordinator.observationSnapshot()
        let callCount = await dispatcher.callCount
        try expect(observations.count == 1, "obsolete generation published a second observation")
        try expect(callCount == 1, "obsolete generation entered the dispatcher after cancellation")
        try expect(
            observations.first?.function.functionID == "function:current",
            "obsolete generation replaced current metadata"
        )
        try expect(logs.snapshot.count == 1, "obsolete generation emitted an extra terminal log")
        let cancelledEntryCount = await dispatcher.cancelledEntryCount
        try expect(
            cancelledEntryCount == 0,
            "a task cancelled before dispatch still entered the dispatcher"
        )
    }

    static func failuresRemainObservational() async throws {
        let cases: [(NativeDecompilerTestDispatcher.Mode, NativeDecompilerTerminalStatus)] = [
            (.clientFailure(.malformedReply), .clientFailure(.malformedReply)),
            (.clientFailure(.interrupted), .clientFailure(.interrupted)),
            (.clientFailure(.timedOut), .clientFailure(.timedOut)),
            (.providerFailure(.nativeFailure), .providerFailure(.nativeFailure)),
            (.malformedSuccess, .invalidReply),
        ]

        for (index, testCase) in cases.enumerated() {
            let dispatcher = NativeDecompilerTestDispatcher(mode: testCase.0)
            let coordinator = NativeDecompilerCoordinator(
                policy: .init(isEnabled: true),
                dispatcher: dispatcher
            )
            let accepted = await coordinator.submit(makeSubmission(label: "failure-\(index)"))
            try expect(
                accepted,
                "failure-isolation submission was rejected"
            )
            try await waitUntil("failure did not finish") {
                await coordinator.observationSnapshot().count == 1
            }
            let observations = await coordinator.observationSnapshot()
            let observation = try unwrap(
                observations.first,
                "failure did not produce bounded operational metadata"
            )
            try expect(observation.status == testCase.1, "failure status was misclassified")
            try expect(observation.recordCounts == nil, "failed output must not publish record counts")
            try expect(observation.provider == nil, "failed output must not publish provider metadata")
        }
    }

    static func historyAndMismatchesStayBounded() async throws {
        let dispatcher = NativeDecompilerTestDispatcher(mode: .longProviderSuccess)
        let coordinator = NativeDecompilerCoordinator(
            policy: .init(isEnabled: true),
            dispatcher: dispatcher,
            configuration: .init(
                maximumObservations: 2,
                maximumMismatchCategories: 2,
                maximumIdentifierUTF8Bytes: 24
            )
        )

        for index in 0..<3 {
            let label = "very-long-function-identifier-\(index)-that-must-be-bounded"
            let submission = makeSubmission(
                label: label,
                referenceCounts: .init(instructions: 99, blocks: 99, edges: 99, calls: 99)
            )
            let accepted = await coordinator.submit(submission)
            try expect(accepted, "bounded submission was rejected")
            try await waitUntil("bounded submission did not finish") {
                let requests = await dispatcher.requests
                guard requests.count == index + 1, let requestID = requests.last?.requestID else {
                    return false
                }
                return await coordinator.observationSnapshot().last?.requestID == requestID
            }
        }

        let observations = await coordinator.observationSnapshot()
        try expect(observations.count == 2, "observation history exceeded its configured ring bound")
        try expect(
            observations.allSatisfy { $0.mismatchCategories.count == 2 },
            "mismatch categories exceeded or missed the configured bound"
        )
        try expect(
            observations.allSatisfy { $0.function.functionID.utf8.count <= 24 },
            "function metadata exceeded its configured UTF-8 bound"
        )
        try expect(
            observations.allSatisfy { $0.provider?.backendID == "provider-identity-provid" },
            "provider metadata was not truncated at the configured UTF-8 bound"
        )
    }
}

private actor NativeDecompilerTestDispatcher: NativeDecompilerDispatching {
    enum Mode: Sendable {
        case success
        case longProviderSuccess
        case suspendedSuccess
        case clientFailure(NativeDecompilerXPCClientFailure)
        case providerFailure(NativeDecompilerWireFailureCode)
        case malformedSuccess
    }

    private struct Pending {
        let request: NativeDecompilerWireRequestEnvelope
        let continuation: CheckedContinuation<NativeDecompilerWireReplyEnvelope, Error>
    }

    private(set) var requests: [NativeDecompilerWireRequestEnvelope] = []
    private(set) var completedCallCount = 0
    private(set) var cancelledEntryCount = 0
    private var mode: Mode
    private var pending: [Pending] = []

    init(mode: Mode) {
        self.mode = mode
    }

    var callCount: Int { requests.count }

    func setMode(_ mode: Mode) {
        self.mode = mode
    }

    func decompile(
        request dispatchRequest: NativeDecompilerPreencodedDispatchRequest,
        elapsedTimeBudget _: Duration?
    ) async throws -> NativeDecompilerWireReplyEnvelope {
        if Task.isCancelled { cancelledEntryCount += 1 }
        let request = dispatchRequest.envelope
        requests.append(request)
        defer { completedCallCount += 1 }
        switch mode {
        case .success:
            return makeSuccessReply(for: request)
        case .longProviderSuccess:
            return makeSuccessReply(
                for: request,
                providerBackendID: String(repeating: "provider-identity-", count: 32)
            )
        case .suspendedSuccess:
            return try await withCheckedThrowingContinuation { continuation in
                pending.append(Pending(request: request, continuation: continuation))
            }
        case let .clientFailure(failure):
            throw failure
        case let .providerFailure(code):
            return NativeDecompilerWireReplyEnvelope(
                requestID: request.requestID,
                failure: .init(code: code, detail: "bounded-test-detail")
            )
        case .malformedSuccess:
            return NativeDecompilerWireReplyEnvelope(
                requestID: request.requestID,
                outcome: .success,
                success: nil,
                failure: nil
            )
        }
    }

    func resumeAllSuspended() {
        let suspended = pending
        pending.removeAll()
        suspended.forEach { $0.continuation.resume(returning: makeSuccessReply(for: $0.request)) }
    }
}

private actor NativeDecompilerTestAdmissionGate {
    private(set) var entryCount = 0
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entryCount += 1
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseAll() {
        isReleased = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private func makeSubmission(
    label: String,
    bytes: Data = Data([0xc0, 0x03, 0x5f, 0xd6]),
    referenceCounts: NativeDecompilerReferenceCounts = .init()
) -> NativeDecompilerSubmission {
    let placeholderID = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
    let target = try! NativeDecompilerSealedTargetProfile.normalizedTarget(
        rawCPUType: 0x0100_000c,
        rawCPUSubtype: 0,
        selectedSliceSHA256: String(repeating: "a", count: 64),
        selectedSliceByteCount: UInt64(bytes.count)
    )
    let image = NativeDecompilerWireImageIdentity(
        imageID: "image:main",
        uuid: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
        preferredLoadAddress: .init(0x1000)
    )
    let function = NativeDecompilerWireFunctionIdentity(
        functionID: "function:\(label)",
        name: label,
        entryAddress: .init(0x1000),
        endAddressExclusive: .init(0x1004)
    )
    let memoryRegions = [
        NativeDecompilerWireMemoryRegion(
            name: "__text",
            startAddress: .init(0x1000),
            permissions: .readExecute,
            rawBytes: bytes,
            effectiveBytes: bytes,
            appliedPatchIDs: []
        ),
    ]
    let symbols: [NativeDecompilerWireSymbolRecord] = []
    let authoredInputs = NativeDecompilerWireAuthoredInputs.empty
    let budgets = NativeDecompilerProductBudgetProfile.v1
    let requestSHA256 = try! NativeDecompilerWireCanonicalRequest.sha256(
        schemaVersion: NativeDecompilerWireRequestEnvelope.currentSchemaVersion,
        operation: .decompile,
        target: target,
        image: image,
        function: function,
        memoryRegions: memoryRegions,
        symbols: symbols,
        authoredInputs: authoredInputs,
        budgets: budgets
    )
    let body = NativeDecompilerWireRequest(
        requestID: placeholderID,
        requestSHA256: requestSHA256,
        target: target,
        image: image,
        function: function,
        memoryRegions: memoryRegions,
        symbols: symbols,
        authoredInputs: authoredInputs,
        budgets: budgets.wireValue
    )
    return try! NativeDecompilerSubmission(
        projection: .init(request: body),
        elapsedTimeBudget: .seconds(5),
        referenceCounts: referenceCounts
    )
}

private func makeSuccessReply(
    for request: NativeDecompilerWireRequestEnvelope,
    providerBackendID: String = "native-decompiler"
) -> NativeDecompilerWireReplyEnvelope {
    let range = NativeDecompilerWireSourceRange(
        imageID: request.body.image.imageID,
        startAddress: request.body.function.entryAddress,
        endAddressExclusive: request.body.function.endAddressExclusive
    )
    let result = NativeDecompilerWireStructuredResult(
        requestID: request.requestID,
        requestSHA256: request.body.requestSHA256,
        image: request.body.image,
        function: request.body.function,
        addressSpaces: [
            .init(
                id: "space:ram",
                name: "ram",
                kind: .processor,
                addressSizeBytes: 8,
                isProcessorSpace: true
            ),
        ],
        types: [],
        instructions: [
            .init(
                id: "instruction:0",
                address: request.body.function.entryAddress,
                bytes: request.body.memoryRegions[0].effectiveBytes,
                mnemonic: "ret",
                body: "",
                operationIDs: ["operation:0"],
                sourceRanges: [range]
            ),
        ],
        varnodes: [
            .init(
                id: "varnode:0",
                addressSpaceID: "space:ram",
                offset: .init(0),
                sizeBytes: 8,
                role: .register,
                typeID: nil,
                registerName: "x0"
            ),
        ],
        operations: [
            .init(
                id: "operation:0",
                blockID: "block:0",
                sequence: .init(0),
                opcode: .return,
                outputVarnodeID: nil,
                inputVarnodeIDs: ["varnode:0"],
                directTargetAddress: nil,
                sourceRanges: [range]
            ),
        ],
        blocks: [
            .init(
                id: "block:0",
                startAddress: request.body.function.entryAddress,
                endAddressExclusive: request.body.function.endAddressExclusive,
                operationIDs: ["operation:0"],
                predecessorEdgeIDs: [],
                successorEdgeIDs: [],
                terminatorKind: .return
            ),
        ],
        edges: [],
        ssaValues: [
            .init(
                id: "ssa:0",
                varnodeID: "varnode:0",
                kind: .functionEntry,
                definingOperationID: nil,
                definingPhiID: nil
            ),
        ],
        ssaBindings: [
            .init(
                operationID: "operation:0",
                inputSSAValueIDs: ["ssa:0"],
                outputSSAValueID: nil
            ),
        ],
        phis: [],
        memoryVersions: [],
        memoryPhis: [],
        memoryEffects: [],
        variables: [],
        calls: [],
        regions: [
            .init(
                id: "region:root",
                kind: .root,
                parentRegionID: nil,
                childRegionIDs: [],
                blockIDs: ["block:0"],
                conditionOperationID: nil,
                sourceRanges: [range]
            ),
        ],
        tokens: [],
        warnings: []
    )
    let availability = NativeDecompilerWireBackendAvailability(
        available: true,
        reasonCode: "",
        runtimeIdentity: .init(
            backendID: providerBackendID,
            engineVersion: "12.1.2",
            engineRevision: String(repeating: "b", count: 40),
            wrapperVersion: "dcp03b5-v1",
            wrapperRevision: String(repeating: "c", count: 40),
            packageManifestSHA256: String(repeating: "d", count: 64),
            packageTreeSHA256: String(repeating: "e", count: 64),
            languageID: "AARCH64:LE:64:AppleSilicon", compilerSpecID: "default",
            targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
            contextProfileSHA256: "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5"
        ),
        capabilities: .init(
            nativeDecompilerHeritage: true,
            completeRegisterSSA: false,
            memorySSA: false,
            recoveredVariables: false,
            recoveredTypes: false,
            structuredControlFlow: true,
            tokenizedPseudocode: false,
            imageQualifiedSourceRanges: true
        )
    )
    return NativeDecompilerWireReplyEnvelope(
        requestID: request.requestID,
        success: .init(availability: availability, result: result)
    )
}

private final class NativeDecompilerTestLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [NativeDecompilerLogRecord] = []

    var snapshot: [NativeDecompilerLogRecord] {
        lock.withLock { records }
    }

    func record(_ record: NativeDecompilerLogRecord) {
        lock.withLock { records.append(record) }
    }
}

private final class NativeDecompilerTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64 {
        lock.withLock {
            guard !values.isEmpty else { return 0 }
            return values.removeFirst()
        }
    }
}

private struct NativeDecompilerTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw NativeDecompilerTestFailure(description: message) }
}

private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NativeDecompilerTestFailure(description: message) }
    return value
}

private func waitUntil(
    _ message: String,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        await Task.yield()
    }
    throw NativeDecompilerTestFailure(description: message)
}
