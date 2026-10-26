import CryptoKit
import Foundation

protocol DebuggerRuntimeModuleInventoryCollectorClock: Sendable {
    func uptimeNanoseconds() async -> UInt64
}

struct DebuggerRuntimeModuleInventorySystemClock: DebuggerRuntimeModuleInventoryCollectorClock {
    func uptimeNanoseconds() async -> UInt64 {
        let nanoseconds = ProcessInfo.processInfo.systemUptime * 1_000_000_000
        guard nanoseconds.isFinite, nanoseconds >= 0 else { return 0 }
        return nanoseconds >= Double(UInt64.max) ? UInt64.max : UInt64(nanoseconds)
    }
}

struct DebuggerRuntimeModuleInventoryCollectionPlan: Sendable {
    let parentContext: DebuggerRequestContext
    let internalContexts: [DebuggerRequestContext]
    let adapterGeneration: UInt64
    let expectedProcessID: Int32
    let token: Data
}

enum DebuggerRuntimeModuleInventoryCollectorFailureCode: String, Equatable, Sendable {
    case invalidReservation
    case invalidProgram
    case deadlineExceeded
    case cancelledBetweenExchanges
    case exchangeFailed
    case responseMismatch
    case installNotProven
    case cleanupNotProven
}

struct DebuggerRuntimeModuleInventoryCollectorFailure: Error, LocalizedError, Equatable, Sendable {
    let code: DebuggerRuntimeModuleInventoryCollectorFailureCode
    let evidenceByteCount: Int
    let evidenceSHA256: Data
    let requiresAdapterInvalidation: Bool

    init(
        code: DebuggerRuntimeModuleInventoryCollectorFailureCode,
        evidence: Data = Data(),
        requiresAdapterInvalidation: Bool? = nil
    ) {
        self.code = code
        self.evidenceByteCount = evidence.count
        self.evidenceSHA256 = Data(SHA256.hash(data: evidence))
        self.requiresAdapterInvalidation = requiresAdapterInvalidation
            ?? Self.defaultInvalidationDisposition(for: code)
    }

    var errorDescription: String? {
        "Runtime module inventory collection failed (\(code.rawValue))."
    }

    private static func defaultInvalidationDisposition(
        for code: DebuggerRuntimeModuleInventoryCollectorFailureCode
    ) -> Bool {
        switch code {
        case .exchangeFailed, .responseMismatch, .cleanupNotProven:
            true
        case .invalidReservation, .invalidProgram, .deadlineExceeded,
             .cancelledBetweenExchanges, .installNotProven:
            false
        }
    }
}

/// Runs the frozen runtime-module extractor as a bounded series of physically reserved adapter
/// requests. The parent context is correlation authority only and is never submitted to LLDB.
actor DebuggerRuntimeModuleInventoryCollector {
    static let internalContextCount = 112
    static let totalDeadlineNanoseconds: UInt64 = 10_000_000_000
    static let collectionDeadlineNanoseconds: UInt64 = 9_000_000_000
    static let cleanupDeadlineNanoseconds: UInt64 = 1_000_000_000

    private let program: LLDBRuntimeModuleExtractorProgram
    private let decoder: LLDBRuntimeModuleInventoryDecoder
    private let clock: any DebuggerRuntimeModuleInventoryCollectorClock

    private(set) var installedAdapterGeneration: UInt64?

    init(
        program: LLDBRuntimeModuleExtractorProgram = .current,
        decoder: LLDBRuntimeModuleInventoryDecoder = .init(),
        clock: any DebuggerRuntimeModuleInventoryCollectorClock = DebuggerRuntimeModuleInventorySystemClock()
    ) {
        self.program = program
        self.decoder = decoder
        self.clock = clock
    }

    func collect(
        plan: DebuggerRuntimeModuleInventoryCollectionPlan,
        executor: any PersistentLLDBCLIExecuting
    ) async throws -> DebuggerRuntimeModuleDecodedCollection {
        try validate(plan)
        try validateProgramWires()

        let startedAt = await clock.uptimeNanoseconds()
        var nextContextIndex = 0
        var didTouchInterpreter = false
        var collectionResult: Result<DebuggerRuntimeModuleDecodedCollection, Error>

        do {
            if installedAdapterGeneration == plan.adapterGeneration {
                // The cached fact is only valid if this exact generation proves the installed
                // program again. Clear it before touching LLDB so any semantic proof failure can
                // recover by reinstalling on the next stopped-state refresh.
                installedAdapterGeneration = nil
                try throwIfCancelledBetweenExchanges()
                let context = try takeContext(plan, index: &nextContextIndex)
                didTouchInterpreter = true
                let response = try await exchange(
                    command: program.installedProofCommand,
                    context: context,
                    plan: plan,
                    startedAt: startedAt,
                    executor: executor
                )
                try validateExactReceipt(
                    response.transcript,
                    expected: installReceipt,
                    failureCode: .installNotProven,
                    expectedProcessID: plan.expectedProcessID
                )
                installedAdapterGeneration = plan.adapterGeneration
            } else {
                installedAdapterGeneration = nil
                for command in program.installChunkCommands {
                    try throwIfCancelledBetweenExchanges()
                    let context = try takeContext(plan, index: &nextContextIndex)
                    didTouchInterpreter = true
                    let response = try await exchange(
                        command: command,
                        context: context,
                        plan: plan,
                        startedAt: startedAt,
                        executor: executor
                    )
                    try validateExactReceipt(
                        response.transcript,
                        expected: "",
                        failureCode: .installNotProven,
                        expectedProcessID: plan.expectedProcessID
                    )
                }

                try throwIfCancelledBetweenExchanges()
                let context = try takeContext(plan, index: &nextContextIndex)
                let response = try await exchange(
                    command: program.installFinalizeCommand,
                    context: context,
                    plan: plan,
                    startedAt: startedAt,
                    executor: executor
                )
                try validateExactReceipt(
                    response.transcript,
                    expected: installReceipt,
                    failureCode: .installNotProven,
                    expectedProcessID: plan.expectedProcessID
                )
                installedAdapterGeneration = plan.adapterGeneration
            }

            var assembler = try DebuggerRuntimeModuleCollectionAssembler(
                expectedToken: plan.token,
                expectedProcessID: plan.expectedProcessID,
                startedAtUptimeNanoseconds: startedAt
            )
            var cursor: UInt32 = 0
            var completed: DebuggerRuntimeModuleDecodedCollection?

            while completed == nil {
                try throwIfCancelledBetweenExchanges()
                let context = try takeContext(plan, index: &nextContextIndex)
                let command = try program.pageCommand(token: plan.token, cursor: cursor)
                let response = try await exchange(
                    command: command,
                    context: context,
                    plan: plan,
                    startedAt: startedAt,
                    executor: executor
                )
                let page = try decoder.decodePage(from: response.transcript)
                let now = await clock.uptimeNanoseconds()
                completed = try assembler.append(page, nowUptimeNanoseconds: now)
                cursor = page.end
            }
            collectionResult = .success(completed!)
        } catch {
            collectionResult = .failure(error)
        }

        guard didTouchInterpreter else {
            return try collectionResult.get()
        }

        do {
            try await cleanup(plan: plan, startedAt: startedAt, executor: executor)
        } catch {
            installedAdapterGeneration = nil
            throw DebuggerRuntimeModuleInventoryCollectorFailure(
                code: .cleanupNotProven,
                evidence: failureEvidence(error),
                requiresAdapterInvalidation: true
            )
        }
        return try collectionResult.get()
    }

    private var installReceipt: String {
        "MACSCOPE_LLDB_MODULE_INSTALL_V1 {\"ok\":true,\"schema\":1,\"sha256\":\"\(program.sourceSHA256Hex)\"}\n"
    }

    private func cleanupReceipt(token: Data) -> String {
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        return "MACSCOPE_LLDB_MODULE_CLEANUP_V1 {\"ok\":true,\"schema\":1,\"token\":\"\(tokenHex)\"}\n"
    }

    private func validate(_ plan: DebuggerRuntimeModuleInventoryCollectionPlan) throws {
        let parent = plan.parentContext
        guard parent.isInternallyConsistent,
              parent.operation == .refreshRuntimeModules,
              parent.requiredStop != nil,
              plan.adapterGeneration > 0,
              plan.expectedProcessID > 0,
              plan.token.count == 32,
              plan.internalContexts.count == Self.internalContextCount,
              parent.id.sequence <= UInt64.max - UInt64(Self.internalContextCount) else {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(code: .invalidReservation)
        }
        for (index, context) in plan.internalContexts.enumerated() {
            guard context.isInternallyConsistent,
                  context.id.epoch == parent.id.epoch,
                  context.id.sequence == parent.id.sequence + UInt64(index + 1),
                  context.operation == parent.operation,
                  context.expectedSession == parent.expectedSession,
                  context.requiredStop == parent.requiredStop else {
                throw DebuggerRuntimeModuleInventoryCollectorFailure(code: .invalidReservation)
            }
        }
    }

    private func validateProgramWires() throws {
        let commands = program.installChunkCommands
            + [program.installFinalizeCommand, program.installedProofCommand]
        do {
            for command in commands {
                _ = try program.completeEncodedWireByteCount(for: command)
            }
        } catch {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(
                code: .invalidProgram,
                evidence: failureEvidence(error)
            )
        }
    }

    private func takeContext(
        _ plan: DebuggerRuntimeModuleInventoryCollectionPlan,
        index: inout Int
    ) throws -> DebuggerRequestContext {
        // The final physical context is reserved exclusively for cleanup.
        guard index < plan.internalContexts.count - 1 else {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(code: .invalidReservation)
        }
        defer { index += 1 }
        return plan.internalContexts[index]
    }

    private func exchange(
        command: String,
        context: DebuggerRequestContext,
        plan: DebuggerRuntimeModuleInventoryCollectionPlan,
        startedAt: UInt64,
        executor: any PersistentLLDBCLIExecuting
    ) async throws -> PersistentLLDBCLIResponse {
        try throwIfCancelledBetweenExchanges()
        _ = try program.completeEncodedWireByteCount(for: command)
        let now = await clock.uptimeNanoseconds()
        guard now >= startedAt,
              now - startedAt < Self.collectionDeadlineNanoseconds else {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(code: .deadlineExceeded)
        }
        let remaining = Self.collectionDeadlineNanoseconds - (now - startedAt)
        let request: PersistentLLDBCLIRequest
        do {
            request = try PersistentLLDBCLIRequest(
                context: context,
                semanticCommands: [command],
                observedPIDRequirement: .required,
                timeout: duration(nanoseconds: remaining)
            )
        } catch {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(
                code: .invalidProgram,
                evidence: failureEvidence(error)
            )
        }

        let response: PersistentLLDBCLIResponse
        do {
            response = try await executor.execute(request)
        } catch {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(
                code: .exchangeFailed,
                evidence: failureEvidence(error),
                requiresAdapterInvalidation: true
            )
        }
        guard response.requestID == context.id,
              response.generation == plan.adapterGeneration else {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(
                code: .responseMismatch,
                evidence: Data("\(response.requestID.sequence):\(response.generation)".utf8),
                requiresAdapterInvalidation: true
            )
        }
        return response
    }

    private func cleanup(
        plan: DebuggerRuntimeModuleInventoryCollectionPlan,
        startedAt: UInt64,
        executor: any PersistentLLDBCLIExecuting
    ) async throws {
        let command = try program.cleanupCommand(token: plan.token)
        _ = try program.completeEncodedWireByteCount(for: command)
        let context = plan.internalContexts[Self.internalContextCount - 1]
        let now = await clock.uptimeNanoseconds()
        guard now >= startedAt, now - startedAt < Self.totalDeadlineNanoseconds else {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(code: .cleanupNotProven)
        }
        let remaining = min(
            Self.cleanupDeadlineNanoseconds,
            Self.totalDeadlineNanoseconds - (now - startedAt)
        )
        let request = try PersistentLLDBCLIRequest(
            context: context,
            semanticCommands: [command],
            observedPIDRequirement: .required,
            timeout: duration(nanoseconds: remaining)
        )

        // Cleanup must still be attempted if the caller was cancelled after an earlier write.
        let cleanupTask = Task.detached(priority: .userInitiated) {
            try await executor.execute(request)
        }
        let response: PersistentLLDBCLIResponse
        do {
            response = try await cleanupTask.value
        } catch {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(
                code: .cleanupNotProven,
                evidence: failureEvidence(error),
                requiresAdapterInvalidation: true
            )
        }
        guard response.requestID == context.id,
              response.generation == plan.adapterGeneration else {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(
                code: .cleanupNotProven,
                evidence: Data("\(response.requestID.sequence):\(response.generation)".utf8),
                requiresAdapterInvalidation: true
            )
        }
        try validateExactReceipt(
            response.transcript,
            expected: cleanupReceipt(token: plan.token),
            failureCode: .cleanupNotProven,
            expectedProcessID: plan.expectedProcessID
        )
    }

    private func validateExactReceipt(
        _ result: LLDBCLITranscriptResult,
        expected: String,
        failureCode: DebuggerRuntimeModuleInventoryCollectorFailureCode,
        expectedProcessID: Int32
    ) throws {
        let evidence = Data(result.trustedSemanticTranscript.utf8)
        guard result.semanticCommandsSucceeded,
              result.firstFailedSemanticCommandIndex == nil,
              result.semanticCommandTranscripts == [expected],
              result.observedProcessID == expectedProcessID,
              result.observedProcessState == .stopped(processID: expectedProcessID),
              result.exchangeByteCount >= 0,
              result.exchangeByteCount <= LLDBCLITranscriptDecoder.maximumExchangeBytes else {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(
                code: failureCode,
                evidence: evidence,
                requiresAdapterInvalidation: failureCode == .cleanupNotProven
            )
        }
    }

    private func throwIfCancelledBetweenExchanges() throws {
        if Task.isCancelled {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(code: .cancelledBetweenExchanges)
        }
    }

    private func duration(nanoseconds: UInt64) -> Duration {
        .nanoseconds(Int64(min(nanoseconds, UInt64(Int64.max))))
    }

    private func failureEvidence(_ error: Error) -> Data {
        Data(String(reflecting: error).utf8.prefix(4_096))
    }
}
