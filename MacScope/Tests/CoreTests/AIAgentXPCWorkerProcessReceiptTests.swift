import XCTest

@testable import MacScope

final class AIAgentXPCWorkerProcessReceiptTests: XCTestCase {
    func testProviderPreparesAndRevalidatesExactGenerationBoundReceipt() async throws {
        let transport = ReceiptAIAgentTransport()
        let provider = AIAgentXPCInferenceProvider(transport: transport)

        let receipt = try await provider.prepareWorkerProcessReceipt()

        XCTAssertEqual(receipt.processIdentifier, 4242)
        XCTAssertEqual(receipt.providerGeneration, 0)
        XCTAssertEqual(receipt.connectionIdentity, receiptConnectionID)
        XCTAssertEqual(receipt.profileID, receiptProfileID)
        XCTAssertEqual(receipt.configurationGeneration, 7)
        XCTAssertEqual(
            receipt.protocolManifestDigest,
            Phase2AIWorkerProductionProtocol.manifestDigest
        )
        let remainsValid = await provider.revalidateWorkerProcessReceipt(receipt)
        let preparationCount = await transport.prepareCount()
        let revalidationCount = await transport.revalidationCount()
        XCTAssertTrue(remainsValid)
        XCTAssertEqual(preparationCount, 1)
        XCTAssertEqual(revalidationCount, 1)
    }

    func testResetInvalidatesReceiptAndResetsConcreteTransport() async throws {
        let transport = ReceiptAIAgentTransport()
        let provider = AIAgentXPCInferenceProvider(transport: transport)
        let receipt = try await provider.prepareWorkerProcessReceipt()

        await provider.resetConnection()

        let remainsValid = await provider.revalidateWorkerProcessReceipt(receipt)
        let resetCount = await transport.resetCount()
        XCTAssertFalse(remainsValid)
        XCTAssertEqual(resetCount, 1)
    }

    func testResetDuringSuspendedRevalidationCannotReturnStaleSuccess() async throws {
        let transport = SuspendedRevalidationAIAgentTransport()
        let provider = AIAgentXPCInferenceProvider(transport: transport)
        let receipt = try await provider.prepareWorkerProcessReceipt()
        let validation = Task {
            await provider.revalidateWorkerProcessReceipt(receipt)
        }
        await transport.waitUntilRevalidationStarts()

        await provider.resetConnection()
        await transport.releaseRevalidation(as: true)

        let remainsValid = await validation.value
        let resetCount = await transport.resetCount()
        XCTAssertFalse(remainsValid)
        XCTAssertEqual(resetCount, 1)
    }

    func testUnsupportedTransportFailsClosedWithoutStartingInference() async {
        let transport = UnsupportedReceiptAIAgentTransport()
        let provider = AIAgentXPCInferenceProvider(transport: transport)

        do {
            _ = try await provider.prepareWorkerProcessReceipt()
            XCTFail("Expected unsupported receipt preparation to fail closed")
        } catch {
            XCTAssertEqual(
                error as? AIAgentXPCTransportError,
                .unavailable("AI worker process receipt unavailable")
            )
        }
        let runCount = await transport.runCount()
        XCTAssertEqual(runCount, 0)
    }

    func testReceiptValidationRejectsUnsafeProcessAndManifestClaims() {
        XCTAssertThrowsError(try Phase2InferenceWorkerProcessReceipt(
            processIdentifier: 1,
            providerGeneration: 0,
            connectionIdentity: receiptConnectionID,
            profileID: receiptProfileID,
            configurationGeneration: 7,
            protocolManifestDigest: Phase2AIWorkerProductionProtocol.manifestDigest
        )) {
            XCTAssertEqual(
                $0 as? Phase2InferenceWorkerProcessReceipt.ValidationError,
                .invalidProcessIdentifier
            )
        }
        XCTAssertThrowsError(try Phase2InferenceWorkerProcessReceipt(
            processIdentifier: 4242,
            providerGeneration: 0,
            connectionIdentity: receiptConnectionID,
            profileID: receiptProfileID,
            configurationGeneration: 7,
            protocolManifestDigest: "not-a-digest"
        )) {
            XCTAssertEqual(
                $0 as? Phase2InferenceWorkerProcessReceipt.ValidationError,
                .invalidManifestDigest
            )
        }
    }

    func testLiveBindingRejectsAlternateExecutableWithAcceptedProtocolAndSigner() {
        let manifestDigest = Phase2AIWorkerProductionProtocol.reconstructionR1.manifestDigest
        let receipt = AIAgentXPCWorkerProcessReceipt(
            processIdentifier: 4242,
            connectionIdentity: receiptConnectionID,
            profileID: receiptProfileID,
            configurationGeneration: 7,
            protocolManifestDigest: manifestDigest
        )
        let expected = Phase2LiveAIAgentWorkerExecutableIdentity(
            canonicalPath:
                "/Applications/MacScope.app/Contents/XPCServices/"
                + "AIAgentWorkerXPCService.xpc/Contents/MacOS/AIAgentWorkerXPCService",
            sha256: String(repeating: "a", count: 64),
            cdHash: String(repeating: "b", count: 40)
        )
        let accepted = Phase2LiveAIAgentWorkerProcessObservation(
            processIdentifier: receipt.processIdentifier,
            startIdentity: .init(seconds: 1, microseconds: 0),
            executableIdentity: expected,
            signingRequirementAccepted: true
        )
        XCTAssertEqual(receipt.protocolManifestDigest, manifestDigest)
        XCTAssertTrue(accepted.signingRequirementAccepted)
        XCTAssertTrue(
            Phase2LiveAIAgentWorkerProcessIdentityBinding.accepts(
                receipt: receipt,
                expectedProtocolManifestDigest: manifestDigest,
                expectedExecutableIdentity: expected,
                observation: accepted
            )
        )

        let alternateExecutable = Phase2LiveAIAgentWorkerProcessObservation(
            processIdentifier: receipt.processIdentifier,
            startIdentity: accepted.startIdentity,
            executableIdentity: .init(
                canonicalPath:
                    "/private/tmp/AcceptedSigner/AIAgentWorkerXPCService.xpc/Contents/"
                    + "MacOS/AIAgentWorkerXPCService",
                sha256: String(repeating: "c", count: 64),
                cdHash: String(repeating: "d", count: 40)
            ),
            signingRequirementAccepted: true
        )
        XCTAssertTrue(alternateExecutable.signingRequirementAccepted)
        XCTAssertFalse(
            Phase2LiveAIAgentWorkerProcessIdentityBinding.accepts(
                receipt: receipt,
                expectedProtocolManifestDigest: manifestDigest,
                expectedExecutableIdentity: expected,
                observation: alternateExecutable
            ),
            "an accepted-protocol, accepted-signer worker cannot substitute another executable"
        )
    }
}

private let receiptConnectionID = UUID(
    uuidString: "00000000-0000-4000-8000-000000000001"
)!
private let receiptProfileID = UUID(
    uuidString: "00000000-0000-4000-8000-000000000002"
)!

private actor ReceiptAIAgentTransport: AIAgentXPCTransport {
    private var preparations = 0
    private var revalidations = 0
    private var resets = 0

    func run(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        _ = requestID
        _ = requestData
        _ = receive
    }

    func cancel(requestID: UUID) async { _ = requestID }
    func reset() async { resets += 1 }

    func prepareWorkerProcessReceipt() async throws -> AIAgentXPCWorkerProcessReceipt {
        preparations += 1
        return .init(
            processIdentifier: 4242,
            connectionIdentity: receiptConnectionID,
            profileID: receiptProfileID,
            configurationGeneration: 7,
            protocolManifestDigest: Phase2AIWorkerProductionProtocol.manifestDigest
        )
    }

    func revalidateWorkerProcessReceipt(
        _ receipt: AIAgentXPCWorkerProcessReceipt
    ) async -> Bool {
        revalidations += 1
        return receipt == AIAgentXPCWorkerProcessReceipt(
            processIdentifier: 4242,
            connectionIdentity: receiptConnectionID,
            profileID: receiptProfileID,
            configurationGeneration: 7,
            protocolManifestDigest: Phase2AIWorkerProductionProtocol.manifestDigest
        )
    }

    func prepareCount() -> Int { preparations }
    func revalidationCount() -> Int { revalidations }
    func resetCount() -> Int { resets }
}

private actor UnsupportedReceiptAIAgentTransport: AIAgentXPCTransport {
    private var runs = 0

    func run(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        _ = requestID
        _ = requestData
        _ = receive
        runs += 1
    }

    func cancel(requestID: UUID) async { _ = requestID }
    func reset() async {}
    func runCount() -> Int { runs }
}

private actor SuspendedRevalidationAIAgentTransport: AIAgentXPCTransport {
    private var revalidationStarted = false
    private var revalidationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var revalidationContinuation: CheckedContinuation<Bool, Never>?
    private var resets = 0

    func run(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        _ = requestID
        _ = requestData
        _ = receive
    }

    func cancel(requestID: UUID) async { _ = requestID }

    func reset() async { resets += 1 }

    func prepareWorkerProcessReceipt() async throws -> AIAgentXPCWorkerProcessReceipt {
        .init(
            processIdentifier: 4242,
            connectionIdentity: receiptConnectionID,
            profileID: receiptProfileID,
            configurationGeneration: 7,
            protocolManifestDigest: Phase2AIWorkerProductionProtocol.manifestDigest
        )
    }

    func revalidateWorkerProcessReceipt(
        _ receipt: AIAgentXPCWorkerProcessReceipt
    ) async -> Bool {
        _ = receipt
        revalidationStarted = true
        let waiters = revalidationStartWaiters
        revalidationStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            revalidationContinuation = continuation
        }
    }

    func waitUntilRevalidationStarts() async {
        guard !revalidationStarted else { return }
        await withCheckedContinuation { revalidationStartWaiters.append($0) }
    }

    func releaseRevalidation(as result: Bool) {
        let continuation = revalidationContinuation
        revalidationContinuation = nil
        continuation?.resume(returning: result)
    }

    func resetCount() -> Int { resets }
}
