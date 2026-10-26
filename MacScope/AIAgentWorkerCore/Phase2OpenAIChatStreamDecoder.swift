import Foundation

struct Phase2OpenAIChatStreamLimits: Equatable, Sendable {
    let maximumMetadataBytes: Int
    let maximumContentDeltaBytes: Int
    let maximumCumulativeContentBytes: Int
    let maximumReportedTokens: Int
    let maximumCumulativeReasoningBytes: Int
    let maximumToolSelectionChunks: Int

    init(
        maximumMetadataBytes: Int = 512,
        maximumContentDeltaBytes: Int = 16_384,
        maximumCumulativeContentBytes: Int = 65_536,
        maximumReportedTokens: Int = 1_000_000,
        maximumCumulativeReasoningBytes: Int = 1_048_576,
        maximumToolSelectionChunks: Int = 256
    ) {
        precondition(maximumMetadataBytes >= 0)
        precondition(maximumContentDeltaBytes >= 0)
        precondition(maximumCumulativeContentBytes >= 0)
        precondition(maximumReportedTokens >= 0)
        precondition(maximumCumulativeReasoningBytes >= 0)
        precondition(maximumToolSelectionChunks > 0 && maximumToolSelectionChunks <= 256)
        self.maximumMetadataBytes = maximumMetadataBytes
        self.maximumContentDeltaBytes = maximumContentDeltaBytes
        self.maximumCumulativeContentBytes = maximumCumulativeContentBytes
        self.maximumReportedTokens = maximumReportedTokens
        self.maximumCumulativeReasoningBytes = maximumCumulativeReasoningBytes
        self.maximumToolSelectionChunks = maximumToolSelectionChunks
    }
}

struct Phase2OpenAIChatUsage: Equatable, Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
}

enum Phase2OpenAIChatStreamEvent: Equatable, Sendable {
    case contentDelta(String)
    /// Progress only; private reasoning never enters structured final content.
    case reasoningProgress(byteCount: Int)
    case finished
    case usage(Phase2OpenAIChatUsage)
    case done
    case toolCall(Phase2OpenAIToolCall)
    case shellProposal(Phase2OpenAIShellProposalToolCall)
    case debuggerActionProposal(Phase2OpenAIDebuggerActionProposalToolCall)
    case awaitingTools
}

enum Phase2OpenAIChatStreamError: Error, Equatable, Sendable {
    case unsupportedEvent
    case malformedStream
    case malformedJSON
    case providerError
    case invalidChunk
    case inconsistentStream
    case contentLimitExceeded
    case chunkLimitExceeded
    case unsupportedCapability
    case unsupportedFinishReason
    case outputLimitExceeded
    case invalidUsage
    case invalidToolCall
    case unexpectedDone
    case incompleteStream
    case alreadyFinished
    case alreadyFailed
}

struct Phase2OpenAIChatCompletionDecoder: Sendable {
    private enum Mode: Sendable {
        case finalization(acceptsShellProposalTool: Bool)
        case shellContinuation
        case toolSelection

        var isToolSelection: Bool {
            if case .toolSelection = self { return true }
            return false
        }

        var acceptsShellProposalTool: Bool {
            if case .finalization(let acceptsShellProposalTool) = self {
                return acceptsShellProposalTool
            }
            return false
        }
    }

    private let expectedModel: String
    private let acceptsInlineFinishUsage: Bool
    private let limits: Phase2OpenAIChatStreamLimits
    private let mode: Mode
    private var toolAssembler: Phase2OpenAIToolCallAssembler?
    private var shellProposalAssembler: Phase2OpenAIShellProposalToolCallAssembler?
    private var debuggerProposalAssembler: Phase2OpenAIDebuggerActionProposalToolCallAssembler?
    private var streamID: String?
    private var created: Int?
    private var acceptsMTPLXToolSelectionPreamble = false
    private var cumulativeContentBytes = 0
    private var cumulativeReasoningBytes = 0
    private(set) var modelProgressRevision = 0
    private var ordinaryChunkCount = 0
    private var sawFinish = false
    private var sawUsage = false
    private var pendingFinalizationUsage: Phase2OpenAIChatUsage?
    private var sawDone = false
    private var requiresFinalizationShellProposal = false
    private var isFinished = false
    private var isFailed = false

    init(
        expectedModel: String,
        acceptsInlineFinishUsage: Bool = false,
        acceptsShellProposalTool: Bool = false,
        limits: Phase2OpenAIChatStreamLimits = .init()
    ) {
        precondition(!expectedModel.isEmpty)
        precondition(expectedModel.utf8.count <= limits.maximumMetadataBytes)
        self.expectedModel = expectedModel
        self.acceptsInlineFinishUsage = acceptsInlineFinishUsage
        self.limits = limits
        mode = .finalization(acceptsShellProposalTool: acceptsShellProposalTool)
        toolAssembler = nil
        shellProposalAssembler = acceptsShellProposalTool
            ? Phase2OpenAIShellProposalToolCallAssembler()
            : nil
        debuggerProposalAssembler = acceptsShellProposalTool
            ? Phase2OpenAIDebuggerActionProposalToolCallAssembler()
            : nil
    }

    init(
        expectedModel: String,
        acceptsInlineFinishUsage: Bool = false,
        shellContinuation: Bool,
        limits: Phase2OpenAIChatStreamLimits = .init()
    ) {
        precondition(shellContinuation)
        precondition(!expectedModel.isEmpty)
        precondition(expectedModel.utf8.count <= limits.maximumMetadataBytes)
        self.expectedModel = expectedModel
        self.acceptsInlineFinishUsage = acceptsInlineFinishUsage
        self.limits = limits
        mode = .shellContinuation
        toolAssembler = nil
        shellProposalAssembler = nil
        debuggerProposalAssembler = nil
    }

    init(
        expectedModel: String,
        acceptsInlineFinishUsage: Bool = false,
        toolSelectionFunctionHandles: [String: UUID],
        acceptsMTPLXToolSelectionPreamble: Bool = false,
        limits: Phase2OpenAIChatStreamLimits = .init(),
        toolCallLimits: Phase2OpenAIToolCallLimits = .init()
    ) {
        precondition(!expectedModel.isEmpty)
        precondition(expectedModel.utf8.count <= limits.maximumMetadataBytes)
        self.expectedModel = expectedModel
        self.acceptsInlineFinishUsage = acceptsInlineFinishUsage
        self.limits = limits
        mode = .toolSelection
        self.acceptsMTPLXToolSelectionPreamble = acceptsMTPLXToolSelectionPreamble
        toolAssembler = Phase2OpenAIToolCallAssembler(
            offeredFunctionHandles: toolSelectionFunctionHandles,
            limits: toolCallLimits
        )
        shellProposalAssembler = nil
        debuggerProposalAssembler = nil
    }

    init(
        expectedModel: String,
        acceptsInlineFinishUsage: Bool = false,
        toolSelectionAllowedHandles: [String: Set<UUID>],
        acceptsMTPLXToolSelectionPreamble: Bool = false,
        limits: Phase2OpenAIChatStreamLimits = .init(),
        toolCallLimits: Phase2OpenAIToolCallLimits = .init()
    ) {
        precondition(!expectedModel.isEmpty)
        precondition(expectedModel.utf8.count <= limits.maximumMetadataBytes)
        self.expectedModel = expectedModel
        self.acceptsInlineFinishUsage = acceptsInlineFinishUsage
        self.limits = limits
        mode = .toolSelection
        self.acceptsMTPLXToolSelectionPreamble = acceptsMTPLXToolSelectionPreamble
        toolAssembler = Phase2OpenAIToolCallAssembler(
            allowedFunctionHandles: toolSelectionAllowedHandles,
            limits: toolCallLimits
        )
        shellProposalAssembler = nil
        debuggerProposalAssembler = nil
    }

    mutating func append(record: Phase2SSERecord) throws -> [Phase2OpenAIChatStreamEvent] {
        guard !isFailed else { throw Phase2OpenAIChatStreamError.alreadyFailed }
        guard !isFinished, !sawDone else { throw Phase2OpenAIChatStreamError.alreadyFinished }

        do {
            guard record.event == "message" else {
                throw Phase2OpenAIChatStreamError.unsupportedEvent
            }
            if record.data == "[DONE]" {
                guard sawFinish, sawUsage else {
                    throw Phase2OpenAIChatStreamError.unexpectedDone
                }
                sawDone = true
                return mode.isToolSelection || mode.acceptsShellProposalTool ? [] : [.done]
            }

            let object = try decodeObject(record.data)
            if object.member("error") != nil {
                throw Phase2OpenAIChatStreamError.providerError
            }
            try validateAndFreezeMetadata(object)

            guard let choices = object.member("choices")?.arrayValue else {
                throw Phase2OpenAIChatStreamError.invalidChunk
            }
            if choices.isEmpty {
                return try decodeUsageChunk(object)
            }
            return try decodeOrdinaryChunk(object, choices: choices)
        } catch {
            isFailed = true
            throw error
        }
    }

    mutating func finish() throws -> [Phase2OpenAIChatStreamEvent] {
        guard !isFailed else { throw Phase2OpenAIChatStreamError.alreadyFailed }
        guard !isFinished else { throw Phase2OpenAIChatStreamError.alreadyFinished }
        guard sawDone else {
            isFailed = true
            throw Phase2OpenAIChatStreamError.incompleteStream
        }
        do {
            isFinished = true
            if mode.isToolSelection {
                guard var assembler = toolAssembler else {
                    throw Phase2OpenAIChatStreamError.invalidToolCall
                }
                let calls: [Phase2OpenAIToolCall]
                do {
                    calls = try assembler.finish()
                } catch {
                    throw Phase2OpenAIChatStreamError.invalidToolCall
                }
                toolAssembler = assembler
                return calls.map(Phase2OpenAIChatStreamEvent.toolCall) + [.awaitingTools]
            }
            if mode.acceptsShellProposalTool {
                guard var shellAssembler = shellProposalAssembler,
                      var debuggerAssembler = debuggerProposalAssembler else {
                    throw Phase2OpenAIChatStreamError.invalidToolCall
                }
                let proposals: [Phase2OpenAIShellProposalToolCall]
                let debuggerProposals: [Phase2OpenAIDebuggerActionProposalToolCall]
                do {
                    proposals = try shellAssembler.finishIfPresent()
                    debuggerProposals = try debuggerAssembler.finishIfPresent()
                } catch {
                    throw Phase2OpenAIChatStreamError.invalidToolCall
                }
                let hasProposal = !proposals.isEmpty || !debuggerProposals.isEmpty
                guard requiresFinalizationShellProposal == hasProposal else {
                    throw Phase2OpenAIChatStreamError.invalidToolCall
                }
                guard proposals.isEmpty || debuggerProposals.isEmpty else {
                    throw Phase2OpenAIChatStreamError.invalidToolCall
                }
                guard let usage = pendingFinalizationUsage else {
                    throw Phase2OpenAIChatStreamError.invalidUsage
                }
                shellProposalAssembler = shellAssembler
                debuggerProposalAssembler = debuggerAssembler
                return proposals.map(Phase2OpenAIChatStreamEvent.shellProposal)
                    + debuggerProposals.map(Phase2OpenAIChatStreamEvent.debuggerActionProposal)
                    + [.usage(usage), .done]
            }
            return []
        } catch {
            isFailed = true
            throw error
        }
    }

    private func decodeObject(_ text: String) throws -> Phase2ProductionJSONValue {
        do {
            let value = try Phase2StrictJSONParser().parse(Data(text.utf8), limits: .providerEnvelope)
            guard value.objectValue != nil else { throw Phase2OpenAIChatStreamError.malformedJSON }
            return value
        } catch is Phase2OpenAIChatStreamError {
            throw Phase2OpenAIChatStreamError.malformedJSON
        } catch {
            throw Phase2OpenAIChatStreamError.malformedJSON
        }
    }

    private mutating func validateAndFreezeMetadata(_ object: Phase2ProductionJSONValue) throws {
        guard object.member("object")?.stringValue == "chat.completion.chunk",
              let id = object.member("id")?.stringValue,
              !id.isEmpty,
              id.utf8.count <= limits.maximumMetadataBytes,
              let model = object.member("model")?.stringValue,
              !model.isEmpty,
              model.utf8.count <= limits.maximumMetadataBytes,
              let currentCreated = object.member("created")?.integerValue,
              currentCreated >= 0 else {
            throw Phase2OpenAIChatStreamError.invalidChunk
        }
        guard model == expectedModel else {
            throw Phase2OpenAIChatStreamError.inconsistentStream
        }

        if let streamID {
            guard streamID == id, created == currentCreated else {
                throw Phase2OpenAIChatStreamError.inconsistentStream
            }
        } else {
            streamID = id
            created = currentCreated
        }
    }

    private mutating func decodeOrdinaryChunk(
        _ object: Phase2ProductionJSONValue,
        choices: [Phase2ProductionJSONValue]
    ) throws -> [Phase2OpenAIChatStreamEvent] {
        let hasInlineUsage = object.member("usage").map { $0 != .null } ?? false
        guard !sawFinish, !sawUsage,
              !hasInlineUsage || acceptsInlineFinishUsage,
              choices.count == 1,
              let choice = choices[0].objectValue,
              choice.member("index")?.integerValue == 0,
              let delta = choice.member("delta")?.objectValue,
              choice.hasMember("finish_reason") else {
            throw Phase2OpenAIChatStreamError.invalidChunk
        }

        // Reasoning-only chunks do not consume the bounded tool-fragment budget.
        let hasToolFragments = delta.member("tool_calls").map { $0 != .null } ?? false
        let hasReasoning = ["reasoning", "reasoning_content"].contains {
            delta.member($0).map { $0 != .null } ?? false
        }
        if hasToolFragments || !hasReasoning {
            ordinaryChunkCount += 1
        }
        if mode.isToolSelection, ordinaryChunkCount > limits.maximumToolSelectionChunks {
            throw Phase2OpenAIChatStreamError.chunkLimitExceeded
        }
        // MTPLX 2.12.2 combines the terminal choice and usage in one SSE record.
        // Accept that provider-scoped form only after ordinary finish validation succeeds.
        guard !hasInlineUsage || choice.member("finish_reason") != .null else {
            throw Phase2OpenAIChatStreamError.invalidChunk
        }
        var events = mode.isToolSelection
            ? try decodeToolSelectionChunk(delta: delta, finishReason: choice.member("finish_reason"))
            : try decodeFinalizationChunk(delta: delta, finishReason: choice.member("finish_reason"))
        if hasInlineUsage { events += try decodeUsageChunk(object) }
        return events
    }

    private mutating func decodeFinalizationChunk(
        delta: [String: Phase2ProductionJSONValue],
        finishReason: Phase2ProductionJSONValue?
    ) throws -> [Phase2OpenAIChatStreamEvent] {
        let unsupportedFields = mode.acceptsShellProposalTool
            ? ["function_call", "refusal", "audio"]
            : ["tool_calls", "function_call", "refusal", "audio"]
        for field in unsupportedFields {
            if let value = delta.member(field), value != .null {
                throw Phase2OpenAIChatStreamError.unsupportedCapability
            }
        }
        if let role = delta.member("role") {
            guard role == .null || role.stringValue == "assistant" else {
                throw Phase2OpenAIChatStreamError.invalidChunk
            }
        }

        var events = try decodeReasoningProgress(delta)
        if let content = delta.member("content"), content != .null {
            guard let text = content.stringValue else { throw Phase2OpenAIChatStreamError.invalidChunk }
            if !text.isEmpty {
                let byteCount = text.utf8.count
                guard byteCount <= limits.maximumContentDeltaBytes,
                      byteCount <= limits.maximumCumulativeContentBytes - cumulativeContentBytes else {
                    throw Phase2OpenAIChatStreamError.contentLimitExceeded
                }
                cumulativeContentBytes += byteCount
                modelProgressRevision += 1
                events.append(.contentDelta(text))
            }
        }
        if mode.acceptsShellProposalTool, let calls = delta.member("tool_calls"), calls != .null {
            guard let callValues = calls.arrayValue else {
                throw Phase2OpenAIChatStreamError.invalidToolCall
            }
            for call in callValues {
                let fragment = try decodeToolFragment(call)
                try appendFinalizationProposalFragment(fragment)
            }
        }
        if finishReason?.stringValue == "length" {
            throw Phase2OpenAIChatStreamError.outputLimitExceeded
        }
        if finishReason != .null {
            guard let reason = finishReason?.stringValue,
                  reason == "stop" || (mode.acceptsShellProposalTool && reason == "tool_calls") else {
                throw Phase2OpenAIChatStreamError.unsupportedFinishReason
            }
            if reason == "tool_calls" {
                requiresFinalizationShellProposal = true
            }
            sawFinish = true
            events.append(.finished)
        }
        return events
    }

    private mutating func appendFinalizationProposalFragment(
        _ fragment: Phase2OpenAIToolCallFragment
    ) throws {
        do {
            if fragment.name == Phase2OpenAIShellProposalFunctionTool.functionName
                || (fragment.name == nil
                    && shellProposalAssembler?.hasFragments == true
                    && debuggerProposalAssembler?.hasFragments != true) {
                guard debuggerProposalAssembler?.hasFragments != true else {
                    throw Phase2OpenAIChatStreamError.invalidToolCall
                }
                try shellProposalAssembler?.append(fragment)
                return
            }
            if fragment.name == Phase2OpenAIDebuggerActionProposalFunctionTool.functionName
                || (fragment.name == nil
                    && debuggerProposalAssembler?.hasFragments == true
                    && shellProposalAssembler?.hasFragments != true) {
                guard shellProposalAssembler?.hasFragments != true else {
                    throw Phase2OpenAIChatStreamError.invalidToolCall
                }
                try debuggerProposalAssembler?.append(fragment)
                return
            }
            throw Phase2OpenAIChatStreamError.invalidToolCall
        } catch is Phase2OpenAIChatStreamError {
            throw Phase2OpenAIChatStreamError.invalidToolCall
        } catch {
            throw Phase2OpenAIChatStreamError.invalidToolCall
        }
    }

    private mutating func decodeToolSelectionChunk(
        delta: [String: Phase2ProductionJSONValue],
        finishReason: Phase2ProductionJSONValue?
    ) throws -> [Phase2OpenAIChatStreamEvent] {
        // MTPLX can stream prose before a subsequently valid tool call. It carries
        // no authority and never becomes an answer or a persisted content event.
        if let value = delta.member("content"), value != .null {
            guard acceptsMTPLXToolSelectionPreamble else {
                throw Phase2OpenAIChatStreamError.unsupportedCapability
            }
            guard let text = value.stringValue else {
                throw Phase2OpenAIChatStreamError.invalidChunk
            }
            let count = text.utf8.count
            guard count <= limits.maximumContentDeltaBytes,
                  count <= limits.maximumCumulativeContentBytes - cumulativeContentBytes else {
                throw Phase2OpenAIChatStreamError.contentLimitExceeded
            }
            cumulativeContentBytes += count
        }
        for field in ["function_call", "refusal", "audio"] {
            if let value = delta.member(field), value != .null {
                throw Phase2OpenAIChatStreamError.unsupportedCapability
            }
        }
        if let role = delta.member("role") {
            guard role == .null || role.stringValue == "assistant" else {
                throw Phase2OpenAIChatStreamError.invalidChunk
            }
        }
        let events = try decodeReasoningProgress(delta)
        if let calls = delta.member("tool_calls"), calls != .null {
            guard let callValues = calls.arrayValue else {
                throw Phase2OpenAIChatStreamError.invalidToolCall
            }
            for call in callValues {
                let fragment = try decodeToolFragment(call)
                do {
                    try toolAssembler?.append(fragment)
                } catch {
                    throw Phase2OpenAIChatStreamError.invalidToolCall
                }
            }
        }
        if finishReason?.stringValue == "length" {
            throw Phase2OpenAIChatStreamError.outputLimitExceeded
        }
        if finishReason != .null {
            guard finishReason?.stringValue == "tool_calls" else {
                throw Phase2OpenAIChatStreamError.unsupportedFinishReason
            }
            sawFinish = true
        }
        return events
    }

    private mutating func decodeReasoningProgress(
        _ delta: [String: Phase2ProductionJSONValue]
    ) throws -> [Phase2OpenAIChatStreamEvent] {
        var bytes = 0
        for field in ["reasoning", "reasoning_content"] {
            guard let value = delta.member(field), value != .null else { continue }
            guard let text = value.stringValue else {
                throw Phase2OpenAIChatStreamError.invalidChunk
            }
            let count = text.utf8.count
            guard count <= limits.maximumContentDeltaBytes,
                  count <= limits.maximumCumulativeReasoningBytes - cumulativeReasoningBytes else {
                throw Phase2OpenAIChatStreamError.contentLimitExceeded
            }
            cumulativeReasoningBytes += count
            if count > 0 { modelProgressRevision += 1 }
            bytes += count
        }
        return bytes == 0 ? [] : [.reasoningProgress(byteCount: bytes)]
    }

    private mutating func decodeToolFragment(_ value: Phase2ProductionJSONValue) throws -> Phase2OpenAIToolCallFragment {
        guard let object = value.objectValue,
              object.keysAreSubset(of: ["index", "id", "type", "function"]),
              let index = object.member("index")?.integerValue else {
            throw Phase2OpenAIChatStreamError.invalidToolCall
        }
        let id = try optionalString(object.member("id"))
        let type = try optionalString(object.member("type"))
        var name: String?
        var arguments: String?
        if let function = object.member("function") {
            guard let functionObject = function.objectValue,
                  functionObject.keysAreSubset(of: ["name", "arguments"]) else {
                throw Phase2OpenAIChatStreamError.invalidToolCall
            }
            name = try optionalString(functionObject.member("name"))
            arguments = try optionalString(functionObject.member("arguments"))
        }
        if [id, name, arguments].contains(where: { $0?.isEmpty == false }) {
            modelProgressRevision += 1
        }
        return .init(index: index, id: id, type: type, name: name, arguments: arguments)
    }

    private func optionalString(_ value: Phase2ProductionJSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let string = value.stringValue else { throw Phase2OpenAIChatStreamError.invalidToolCall }
        return string
    }

    private mutating func decodeUsageChunk(
        _ object: Phase2ProductionJSONValue
    ) throws -> [Phase2OpenAIChatStreamEvent] {
        guard sawFinish, !sawUsage,
              let usage = object.member("usage")?.objectValue,
              let prompt = usage.member("prompt_tokens")?.integerValue,
              let completion = usage.member("completion_tokens")?.integerValue,
              let total = usage.member("total_tokens")?.integerValue,
              prompt >= 0,
              completion >= 0,
              total >= 0,
              prompt <= limits.maximumReportedTokens,
              completion <= limits.maximumReportedTokens,
              total <= limits.maximumReportedTokens else {
            throw Phase2OpenAIChatStreamError.invalidUsage
        }
        let (sum, overflow) = prompt.addingReportingOverflow(completion)
        guard !overflow, sum == total else { throw Phase2OpenAIChatStreamError.invalidUsage }
        sawUsage = true
        let decoded = Phase2OpenAIChatUsage(promptTokens: prompt, completionTokens: completion, totalTokens: total)
        if mode.acceptsShellProposalTool {
            // EOF validates proposal assembly. Preserve the worker accumulator contract:
            // completed proposals precede usage, followed by the unique done event.
            pendingFinalizationUsage = decoded
            return []
        }
        return [.usage(decoded)]
    }
}

struct Phase2OpenAIChatStreamDecoder: Sendable {
    private var sseDecoder: Phase2SSEDecoder
    private var completionDecoder: Phase2OpenAIChatCompletionDecoder
    private var isFailed = false

    init(
        expectedModel: String,
        acceptsInlineFinishUsage: Bool = false,
        acceptsShellProposalTool: Bool = false,
        limits: Phase2OpenAIChatStreamLimits = .init(),
        sseLimits: Phase2SSEDecoderLimits = Self.productionSSELimits
    ) {
        sseDecoder = Phase2SSEDecoder(limits: sseLimits, defaultEvent: "message")
        completionDecoder = Phase2OpenAIChatCompletionDecoder(
            expectedModel: expectedModel,
            acceptsInlineFinishUsage: acceptsInlineFinishUsage,
            acceptsShellProposalTool: acceptsShellProposalTool,
            limits: limits
        )
    }

    init(
        expectedModel: String,
        acceptsInlineFinishUsage: Bool = false,
        shellContinuation: Bool,
        limits: Phase2OpenAIChatStreamLimits = .init(),
        sseLimits: Phase2SSEDecoderLimits = Self.productionSSELimits
    ) {
        sseDecoder = Phase2SSEDecoder(limits: sseLimits, defaultEvent: "message")
        completionDecoder = Phase2OpenAIChatCompletionDecoder(
            expectedModel: expectedModel,
            acceptsInlineFinishUsage: acceptsInlineFinishUsage,
            shellContinuation: shellContinuation,
            limits: limits
        )
    }

    init(
        expectedModel: String,
        acceptsInlineFinishUsage: Bool = false,
        toolSelectionFunctionHandles: [String: UUID],
        acceptsMTPLXToolSelectionPreamble: Bool = false,
        limits: Phase2OpenAIChatStreamLimits = .init(),
        toolCallLimits: Phase2OpenAIToolCallLimits = .init(),
        sseLimits: Phase2SSEDecoderLimits = Self.productionSSELimits
    ) {
        sseDecoder = Phase2SSEDecoder(limits: sseLimits, defaultEvent: "message")
        completionDecoder = Phase2OpenAIChatCompletionDecoder(
            expectedModel: expectedModel,
            acceptsInlineFinishUsage: acceptsInlineFinishUsage,
            toolSelectionFunctionHandles: toolSelectionFunctionHandles,
            acceptsMTPLXToolSelectionPreamble: acceptsMTPLXToolSelectionPreamble,
            limits: limits,
            toolCallLimits: toolCallLimits
        )
    }

    init(
        expectedModel: String,
        acceptsInlineFinishUsage: Bool = false,
        toolSelectionAllowedHandles: [String: Set<UUID>],
        acceptsMTPLXToolSelectionPreamble: Bool = false,
        limits: Phase2OpenAIChatStreamLimits = .init(),
        toolCallLimits: Phase2OpenAIToolCallLimits = .init(),
        sseLimits: Phase2SSEDecoderLimits = Self.productionSSELimits
    ) {
        sseDecoder = Phase2SSEDecoder(limits: sseLimits, defaultEvent: "message")
        completionDecoder = Phase2OpenAIChatCompletionDecoder(
            expectedModel: expectedModel,
            acceptsInlineFinishUsage: acceptsInlineFinishUsage,
            toolSelectionAllowedHandles: toolSelectionAllowedHandles,
            acceptsMTPLXToolSelectionPreamble: acceptsMTPLXToolSelectionPreamble,
            limits: limits,
            toolCallLimits: toolCallLimits
        )
    }

    mutating func append<Bytes: DataProtocol>(_ bytes: Bytes) throws -> [Phase2OpenAIChatStreamEvent] {
        guard !isFailed else { throw Phase2OpenAIChatStreamError.alreadyFailed }
        do {
            let records: [Phase2SSERecord]
            do { records = try sseDecoder.append(bytes) }
            catch is Phase2SSEDecoderError { throw Phase2OpenAIChatStreamError.malformedStream }
            var events: [Phase2OpenAIChatStreamEvent] = []
            for record in records { events += try completionDecoder.append(record: record) }
            return events
        } catch {
            isFailed = true
            throw error
        }
    }

    mutating func finish() throws -> [Phase2OpenAIChatStreamEvent] {
        guard !isFailed else { throw Phase2OpenAIChatStreamError.alreadyFailed }
        do {
            do { _ = try sseDecoder.finish() }
            catch is Phase2SSEDecoderError { throw Phase2OpenAIChatStreamError.malformedStream }
            return try completionDecoder.finish()
        } catch {
            isFailed = true
            throw error
        }
    }

    var modelProgressRevision: Int { completionDecoder.modelProgressRevision }

    static let productionSSELimits = Phase2SSEDecoderLimits(
        maximumPendingBytes: 65_536,
        maximumLineBytes: 16_384,
        maximumRecordBytes: 262_144,
        maximumCumulativeBytes: 8_388_608,
        // A 16K generation may send one record per token, plus role, tool, usage
        // and terminal records. Two records per output token retains a finite budget.
        maximumRecordCount: 32_768
    )

    /// MTPLX 2.12.2 terminal records include bounded engine telemetry on the same data line.
    /// Preserve all production budgets and increase only this provider's line allowance.
    static let mtplxProductionSSELimits = Phase2SSEDecoderLimits(
        maximumPendingBytes: productionSSELimits.maximumPendingBytes,
        maximumLineBytes: 65_536,
        maximumRecordBytes: productionSSELimits.maximumRecordBytes,
        maximumCumulativeBytes: productionSSELimits.maximumCumulativeBytes,
        maximumRecordCount: productionSSELimits.maximumRecordCount
    )

}

private extension Phase2ProductionJSONValue {
    func member(_ key: String) -> Phase2ProductionJSONValue? {
        objectValue?[key]
    }

    var integerValue: Int? {
        guard case .number(let lexeme) = self,
              !lexeme.contains("."),
              !lexeme.contains("e"),
              !lexeme.contains("E") else { return nil }
        return Int(lexeme)
    }
}

private extension Dictionary where Key == String, Value == Phase2ProductionJSONValue {
    func member(_ key: String) -> Phase2ProductionJSONValue? {
        self[key]
    }

    func hasMember(_ key: String) -> Bool { self[key] != nil }

    func keysAreSubset(of allowed: Set<String>) -> Bool {
        keys.allSatisfy(allowed.contains)
    }
}
