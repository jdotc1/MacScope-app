import CryptoKit
import Foundation

enum LLDBLogicalBreakpointProgramError: Error, Equatable, Sendable {
    case invalidToken
    case invalidDigest
    case invalidGeneration
    case invalidProcess
    case invalidStop
    case invalidPage
    case invalidPayload
    case invalidCursor
    case sourceTooLarge
    case tooManyInstallChunks
    case encodedWireTooLarge
}

enum LLDBLogicalBreakpointCapability: String, Hashable, Sendable {
    case condition
    case ignoreFirst
    case actions
    case targetExpression
    case continueAfterSuccessfulActions
}

enum LLDBLogicalBreakpointCommandPhase: Hashable, Sendable {
    case install
    case proof
    case begin
    case upload
    case apply
    case receipt
    case logs
    case cleanup
    case privateCleanup

    /// `apply` creates/reconciles owned bindings; `privateCleanup` may delete only one already
    /// proven private binding. Every other phase remains target-read-only, so callers can honor
    /// cancellation before `apply` by cleaning uploaded scratch state without ambiguity.
    var mayWriteTarget: Bool { self == .apply || self == .privateCleanup }
}

enum LLDBLogicalBreakpointResponseExpectation: Equatable, Sendable {
    case install(sourceSHA256: Data)
    case begin(token: Data)
    case upload(token: Data, pageIndex: Int)
    case apply(token: Data)
    case receiptPage(token: Data, cursor: Int)
    case logs(
        token: Data,
        sessionEpoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64,
        processID: Int32,
        afterSequence: UInt64
    )
    case cleanup(token: Data)
    case privateCleanup(
        token: Data,
        backendBreakpointID: Int,
        backendLocationID: Int,
        ownerTagDigest: Data,
        nameSHA256: Data,
        runtimeAddress: UInt64
    )
}

enum LLDBLogicalBreakpointResponse: Equatable, Sendable {
    case installed(sourceSHA256: Data)
    case begun(token: Data)
    case uploaded(token: Data, pageIndex: Int)
    case applied(token: Data, locationCount: Int, receiptSHA256: Data)
    case receiptPage(
        token: Data,
        cursor: Int,
        nextCursor: Int,
        isFinal: Bool,
        receiptSHA256: Data,
        payload: Data
    )
    case logs(
        token: Data,
        sessionEpoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64,
        processID: Int32,
        afterSequence: UInt64,
        nextSequence: UInt64,
        isFinal: Bool,
        canonicalRecords: Data
    )
    case cleaned(token: Data)
    case privateCleaned(
        token: Data,
        backendBreakpointID: Int,
        backendLocationID: Int,
        ownerTagDigest: Data,
        nameSHA256: Data,
        runtimeAddress: UInt64,
        wasPresent: Bool
    )
}

enum LLDBLogicalBreakpointResponseError: Error, Equatable, Sendable {
    case semanticCommandFailed
    case invalidFraming
    case capacityExceeded
    case invalidJSON
    case noncanonicalJSON
    case invalidSchema
    case authorityMismatch
}

/// Decodes only the correlated per-command semantic transcript. Raw target stdout and the aggregate
/// transcript are never authority, even when they contain a byte-for-byte plausible sentinel.
struct LLDBLogicalBreakpointResponseDecoder: Sendable {
    static let maximumSemanticResponseBytes = 96 * 1_024

    func decode(
        _ result: LLDBCLITranscriptResult,
        expecting expectation: LLDBLogicalBreakpointResponseExpectation
    ) throws -> LLDBLogicalBreakpointResponse {
        guard result.semanticCommandsSucceeded,
              result.firstFailedSemanticCommandIndex == nil else {
            throw LLDBLogicalBreakpointResponseError.semanticCommandFailed
        }
        guard result.semanticCommandTranscripts.count == 1,
              result.semanticCommandResultLineByteCounts.count == 1 else {
            throw LLDBLogicalBreakpointResponseError.invalidFraming
        }
        let semantic = result.semanticCommandTranscripts[0]
        let semanticBytes = Data(semantic.utf8)
        guard result.exchangeByteCount >= 0,
              result.exchangeByteCount <= LLDBCLITranscriptDecoder.maximumExchangeBytes,
              semanticBytes.count <= Self.maximumSemanticResponseBytes,
              result.semanticCommandResultLineByteCounts[0] >= semanticBytes.count,
              result.semanticCommandResultLineByteCounts[0] <= Self.maximumSemanticResponseBytes else {
            throw LLDBLogicalBreakpointResponseError.capacityExceeded
        }
        guard semantic.hasSuffix("\n"),
              semantic.utf8.filter({ $0 == 0x0a }).count == 1,
              !semantic.utf8.contains(0x0d) else {
            throw LLDBLogicalBreakpointResponseError.invalidFraming
        }

        let sentinel = sentinel(for: expectation)
        guard semantic.hasPrefix(sentinel) else {
            throw LLDBLogicalBreakpointResponseError.invalidFraming
        }
        let start = semantic.index(semantic.startIndex, offsetBy: sentinel.count)
        let end = semantic.index(before: semantic.endIndex)
        let jsonData = Data(semantic[start..<end].utf8)
        guard jsonData.first == 0x7b, jsonData.last == 0x7d else {
            throw LLDBLogicalBreakpointResponseError.invalidFraming
        }

        let value: Phase2ProductionJSONValue
        do {
            value = try Phase2StrictJSONParser().parse(
                jsonData,
                limits: Phase2StrictJSONLimits(
                    maximumBytes: Self.maximumSemanticResponseBytes,
                    maximumDepth: 12,
                    maximumTokens: 100_000,
                    maximumMembersAndElements: 50_000
                )
            )
        } catch {
            throw LLDBLogicalBreakpointResponseError.invalidJSON
        }
        guard value.canonicalJSONBytes() == jsonData else {
            throw LLDBLogicalBreakpointResponseError.noncanonicalJSON
        }
        guard case .object(let object) = value else {
            throw LLDBLogicalBreakpointResponseError.invalidSchema
        }
        return try decode(object, expectation: expectation)
    }

    private func decode(
        _ object: [String: Phase2ProductionJSONValue],
        expectation: LLDBLogicalBreakpointResponseExpectation
    ) throws -> LLDBLogicalBreakpointResponse {
        switch expectation {
        case .install(let expectedDigest):
            if Set(object.keys) == ["ok", "schema", "sha256"],
               object["ok"]?.boolValue == false,
               unsigned(object["schema"], maximum: 1) == 1 {
                guard expectedDigest.count == 32,
                      let digest = hexData(object["sha256"]?.stringValue, byteCount: 32),
                      digest == expectedDigest else {
                    throw LLDBLogicalBreakpointResponseError.authorityMismatch
                }
                throw LLDBLogicalBreakpointResponseError.semanticCommandFailed
            }
            try requireBaseSuccess(object, keys: ["ok", "schema", "sha256"])
            guard expectedDigest.count == 32,
                  let digest = hexData(object["sha256"]?.stringValue, byteCount: 32),
                  digest == expectedDigest else {
                throw LLDBLogicalBreakpointResponseError.authorityMismatch
            }
            return .installed(sourceSHA256: digest)

        case .begin(let expectedToken):
            try requireBaseSuccess(object, keys: ["ok", "schema", "token"])
            let token = try requiredToken(object, expected: expectedToken)
            return .begun(token: token)

        case .upload(let expectedToken, let expectedIndex):
            try requireBaseSuccess(object, keys: ["index", "ok", "schema", "token"])
            let token = try requiredToken(object, expected: expectedToken)
            guard expectedIndex >= 0,
                  let index = unsigned(object["index"], maximum: UInt64(Int.max)),
                  index == UInt64(expectedIndex) else {
                throw LLDBLogicalBreakpointResponseError.authorityMismatch
            }
            return .uploaded(token: token, pageIndex: expectedIndex)

        case .apply(let expectedToken):
            try requireBaseSuccess(
                object,
                keys: ["count", "digest", "ok", "schema", "token"]
            )
            let token = try requiredToken(object, expected: expectedToken)
            guard let count = unsigned(object["count"], maximum: 4_096),
                  let digest = hexData(object["digest"]?.stringValue, byteCount: 32) else {
                throw LLDBLogicalBreakpointResponseError.invalidSchema
            }
            return .applied(
                token: token,
                locationCount: Int(count),
                receiptSHA256: digest
            )

        case .receiptPage(let expectedToken, let expectedCursor):
            try requireBaseSuccess(
                object,
                keys: [
                    "cursor", "digest", "final", "next", "ok", "payload_b64", "schema",
                    "token",
                ]
            )
            let token = try requiredToken(object, expected: expectedToken)
            guard expectedCursor >= 0,
                  let cursor = unsigned(
                object["cursor"],
                maximum: UInt64(LLDBLogicalBreakpointProgram.maximumReceiptBytes)
            ), cursor == UInt64(expectedCursor),
            let next = unsigned(
                object["next"],
                maximum: UInt64(LLDBLogicalBreakpointProgram.maximumReceiptBytes)
            ), next >= cursor,
            let isFinal = object["final"]?.boolValue,
            let digest = hexData(object["digest"]?.stringValue, byteCount: 32),
            let payload64 = object["payload_b64"]?.stringValue,
            let payload = Data(base64Encoded: payload64),
            payload.base64EncodedString() == payload64,
            UInt64(payload.count) == next - cursor else {
                throw LLDBLogicalBreakpointResponseError.invalidSchema
            }
            return .receiptPage(
                token: token,
                cursor: Int(cursor),
                nextCursor: Int(next),
                isFinal: isFinal,
                receiptSHA256: digest,
                payload: payload
            )

        case .logs(
            let expectedToken,
            let expectedSessionEpoch,
            let expectedGeneration,
            let expectedProcessID,
            let afterSequence
        ):
            try requireBaseSuccess(
                object,
                keys: [
                    "adapter_generation", "after_sequence", "final", "next_sequence", "ok",
                    "process_id", "records", "schema", "session_epoch", "token",
                ]
            )
            let token = try requiredToken(object, expected: expectedToken)
            guard expectedGeneration > 0,
                  expectedProcessID > 0,
                  unsigned(object["adapter_generation"], maximum: UInt64.max)
                    == expectedGeneration,
                  unsigned(object["after_sequence"], maximum: UInt64.max) == afterSequence,
                  unsigned(object["process_id"], maximum: UInt64(Int32.max))
                    == UInt64(expectedProcessID),
                  object["session_epoch"]?.stringValue
                    == expectedSessionEpoch.rawValue.uuidString.lowercased(),
                  let next = unsigned(object["next_sequence"], maximum: UInt64.max),
                  next >= afterSequence,
                  let isFinal = object["final"]?.boolValue,
                  let records = object["records"]?.arrayValue else {
                throw LLDBLogicalBreakpointResponseError.authorityMismatch
            }
            let canonicalRecords = Phase2ProductionJSONValue.array(records).canonicalJSONBytes()
            guard canonicalRecords.count <= 64 * 1_024 else {
                throw LLDBLogicalBreakpointResponseError.capacityExceeded
            }
            return .logs(
                token: token,
                sessionEpoch: expectedSessionEpoch,
                adapterGeneration: expectedGeneration,
                processID: expectedProcessID,
                afterSequence: afterSequence,
                nextSequence: next,
                isFinal: isFinal,
                canonicalRecords: canonicalRecords
            )

        case .cleanup(let expectedToken):
            try requireBaseSuccess(object, keys: ["ok", "schema", "token"])
            let token = try requiredToken(object, expected: expectedToken)
            return .cleaned(token: token)

        case .privateCleanup(
            let expectedToken,
            let expectedBreakpointID,
            let expectedLocationID,
            let expectedOwnerTagDigest,
            let expectedNameSHA256,
            let expectedRuntimeAddress
        ):
            try requireBaseSuccess(
                object,
                keys: [
                    "backend_breakpoint_id", "backend_location_id", "name_sha256", "ok",
                    "owner_tag_digest", "runtime_address", "schema", "token", "was_present",
                ]
            )
            let token = try requiredToken(object, expected: expectedToken)
            guard expectedBreakpointID > 0,
                  expectedLocationID > 0,
                  let breakpointID = unsigned(object["backend_breakpoint_id"], maximum: UInt64(Int.max)),
                  breakpointID == UInt64(expectedBreakpointID),
                  let locationID = unsigned(object["backend_location_id"], maximum: UInt64(Int.max)),
                  locationID == UInt64(expectedLocationID),
                  expectedOwnerTagDigest.count == 32,
                  hexData(object["owner_tag_digest"]?.stringValue, byteCount: 32) == expectedOwnerTagDigest,
                  expectedNameSHA256.count == 32,
                  hexData(object["name_sha256"]?.stringValue, byteCount: 32) == expectedNameSHA256,
                  object["runtime_address"]?.stringValue == String(format: "%016llx", expectedRuntimeAddress),
                  let wasPresent = object["was_present"]?.boolValue else {
                throw LLDBLogicalBreakpointResponseError.authorityMismatch
            }
            return .privateCleaned(
                token: token,
                backendBreakpointID: expectedBreakpointID,
                backendLocationID: expectedLocationID,
                ownerTagDigest: expectedOwnerTagDigest,
                nameSHA256: expectedNameSHA256,
                runtimeAddress: expectedRuntimeAddress,
                wasPresent: wasPresent
            )
        }
    }

    private func requireBaseSuccess(
        _ object: [String: Phase2ProductionJSONValue],
        keys: Set<String>
    ) throws {
        guard Set(object.keys) == keys,
              object["ok"]?.boolValue == true,
              unsigned(object["schema"], maximum: 1) == 1 else {
            throw LLDBLogicalBreakpointResponseError.invalidSchema
        }
    }

    private func requiredToken(
        _ object: [String: Phase2ProductionJSONValue],
        expected: Data
    ) throws -> Data {
        guard expected.count == 32,
              let token = hexData(object["token"]?.stringValue, byteCount: 32),
              token == expected else {
            throw LLDBLogicalBreakpointResponseError.authorityMismatch
        }
        return token
    }

    private func unsigned(
        _ value: Phase2ProductionJSONValue?,
        maximum: UInt64
    ) -> UInt64? {
        guard case .number(let text) = value,
              !text.isEmpty,
              text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              (text == "0" || text.first != "0"),
              let number = UInt64(text),
              number <= maximum else {
            return nil
        }
        return number
    }

    private func hexData(_ text: String?, byteCount: Int) -> Data? {
        guard let text else { return nil }
        let bytes = Array(text.utf8)
        guard bytes.count == byteCount * 2 else { return nil }
        var data = Data(capacity: byteCount)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else {
                return nil
            }
            data.append((high << 4) | low)
        }
        return data
    }

    private func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private func sentinel(for expectation: LLDBLogicalBreakpointResponseExpectation) -> String {
        switch expectation {
        case .install: LLDBLogicalBreakpointProgram.installSentinel
        case .begin: LLDBLogicalBreakpointProgram.beginSentinel
        case .upload: LLDBLogicalBreakpointProgram.uploadSentinel
        case .apply: LLDBLogicalBreakpointProgram.applySentinel
        case .receiptPage: LLDBLogicalBreakpointProgram.receiptSentinel
        case .logs: LLDBLogicalBreakpointProgram.logsSentinel
        case .cleanup: LLDBLogicalBreakpointProgram.cleanupSentinel
        case .privateCleanup: LLDBLogicalBreakpointProgram.privateCleanupSentinel
        }
    }
}

/// Frozen app-authored SB/Python program for one retained adapter generation. All mutable plan,
/// authored-expression, condition, log-template, path, and symbol values enter only as validated
/// Base64 JSON data. No such value is interpolated into executable source.
struct LLDBLogicalBreakpointProgram: Sendable {
    static let maximumSourceBytes = 50 * 1_024
    static let installChunkCharacterCount = 512
    static let maximumInstallChunkCount = 134
    static let maximumEncodedWireBytes = 4 * 1_024
    static let maximumPlanBytes = 2 * 1_024 * 1_024
    static let maximumPlanPageBase64Characters = 2_048
    static let maximumPlanPageCount = 8_192
    static let maximumReceiptBytes = 2 * 1_024 * 1_024

    // Updated only when the reviewed static helper bytes intentionally change.
    static let expectedSourceByteCount = 49_760
    static let expectedSourceSHA256Hex = "73f9058650135f4f0d46b460292c13507e02cb04797c95ea3292559b19c3b734"

    /// Exact current-Xcode capabilities accepted by the serialized signed-fixture D4 matrix.
    /// Keeping this set closed prevents supported-but-unproved helper syntax from becoming
    /// authorable without an equivalent live proof.
    static let liveProvenCapabilities: Set<LLDBLogicalBreakpointCapability> = [
        .condition,
        .ignoreFirst,
        .actions,
        .targetExpression,
        .continueAfterSuccessfulActions,
    ]

    static let installSentinel = "MACSCOPE_LLDB_LOGICAL_INSTALL_V1 "
    static let beginSentinel = "MACSCOPE_LLDB_LOGICAL_BEGIN_V1 "
    static let uploadSentinel = "MACSCOPE_LLDB_LOGICAL_UPLOAD_V1 "
    static let applySentinel = "MACSCOPE_LLDB_LOGICAL_APPLY_V1 "
    static let receiptSentinel = "MACSCOPE_LLDB_LOGICAL_RECEIPT_V1 "
    static let logsSentinel = "MACSCOPE_LLDB_LOGICAL_LOGS_V1 "
    static let cleanupSentinel = "MACSCOPE_LLDB_LOGICAL_CLEANUP_V1 "
    static let privateCleanupSentinel = "MACSCOPE_LLDB_PRIVATE_CLEANUP_V1 "

    static let current: LLDBLogicalBreakpointProgram = {
        do {
            let program = try LLDBLogicalBreakpointProgram(source: helperSource)
            precondition(
                program.sourceByteCount == expectedSourceByteCount
                    && program.sourceSHA256Hex == expectedSourceSHA256Hex,
                "The frozen LLDB logical-breakpoint helper changed without contract review."
            )
            return program
        } catch {
            preconditionFailure("The frozen LLDB logical-breakpoint helper is invalid: \(error)")
        }
    }()

    let source: String
    let sourceByteCount: Int
    let sourceSHA256: Data
    let sourceSHA256Hex: String
    let installChunks: [String]
    let installChunkCommands: [String]
    let installFinalizeCommand: String
    let installedProofCommand: String

    init(source: String) throws {
        let bytes = Data(source.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumSourceBytes else {
            throw LLDBLogicalBreakpointProgramError.sourceTooLarge
        }
        let digest = Data(SHA256.hash(data: bytes))
        let digestHex = Self.hex(digest)
        let encoded = bytes.base64EncodedString()
        let chunks = stride(from: 0, to: encoded.utf8.count, by: Self.installChunkCharacterCount)
            .map { String(encoded.dropFirst($0).prefix(Self.installChunkCharacterCount)) }
        guard !chunks.isEmpty, chunks.count <= Self.maximumInstallChunkCount else {
            throw LLDBLogicalBreakpointProgramError.tooManyInstallChunks
        }
        self.source = source
        sourceByteCount = bytes.count
        sourceSHA256 = digest
        sourceSHA256Hex = digestHex
        installChunks = chunks
        installChunkCommands = chunks.enumerated().map { index, chunk in
            Self.installChunkCommand(
                index: index,
                count: chunks.count,
                sourceByteCount: bytes.count,
                digestHex: digestHex,
                chunk: chunk
            )
        }
        installFinalizeCommand = Self.finalizeCommand(
            chunkCount: chunks.count,
            sourceByteCount: bytes.count,
            digestHex: digestHex
        )
        installedProofCommand = Self.proofCommand(digestHex: digestHex)
    }

    func beginCommand(
        token: Data,
        adapterGeneration: UInt64,
        expectedProcessID: Int32,
        expectedStopID: UInt32,
        pageCount: Int,
        planByteCount: Int,
        planSHA256: Data
    ) throws -> String {
        guard token.count == 32 else { throw LLDBLogicalBreakpointProgramError.invalidToken }
        guard planSHA256.count == 32 else { throw LLDBLogicalBreakpointProgramError.invalidDigest }
        guard adapterGeneration > 0 else { throw LLDBLogicalBreakpointProgramError.invalidGeneration }
        guard expectedProcessID > 0 else { throw LLDBLogicalBreakpointProgramError.invalidProcess }
        guard expectedStopID > 0 else { throw LLDBLogicalBreakpointProgramError.invalidStop }
        guard (1...Self.maximumPlanPageCount).contains(pageCount),
              (1...Self.maximumPlanBytes).contains(planByteCount) else {
            throw LLDBLogicalBreakpointProgramError.invalidPage
        }
        return try invocationCommand(
            function: "begin",
            arguments: [
                Self.quoted(Self.hex(token)),
                String(adapterGeneration),
                String(expectedProcessID),
                String(expectedStopID),
                String(pageCount),
                String(planByteCount),
                Self.quoted(Self.hex(planSHA256)),
            ]
        )
    }

    func uploadPageCommand(
        token: Data,
        pageIndex: Int,
        pageCount: Int,
        payloadBase64: String,
        payloadSHA256: Data
    ) throws -> String {
        guard token.count == 32 else { throw LLDBLogicalBreakpointProgramError.invalidToken }
        guard payloadSHA256.count == 32 else { throw LLDBLogicalBreakpointProgramError.invalidDigest }
        guard (1...Self.maximumPlanPageCount).contains(pageCount),
              (0..<pageCount).contains(pageIndex) else {
            throw LLDBLogicalBreakpointProgramError.invalidPage
        }
        guard !payloadBase64.isEmpty,
              payloadBase64.utf8.count <= Self.maximumPlanPageBase64Characters,
              payloadBase64.utf8.count.isMultiple(of: 4),
              payloadBase64.utf8.allSatisfy(Self.isBase64Byte),
              let decoded = Data(base64Encoded: payloadBase64),
              decoded.base64EncodedString() == payloadBase64,
              Data(SHA256.hash(data: decoded)) == payloadSHA256 else {
            throw LLDBLogicalBreakpointProgramError.invalidPayload
        }
        return try invocationCommand(
            function: "upload",
            arguments: [
                Self.quoted(Self.hex(token)),
                String(pageIndex),
                String(pageCount),
                Self.quoted(payloadBase64),
                Self.quoted(Self.hex(payloadSHA256)),
            ]
        )
    }

    func applyCommand(token: Data) throws -> String {
        try tokenInvocation(function: "apply", token: token)
    }

    func receiptPageCommand(token: Data, cursor: Int) throws -> String {
        guard (0...Self.maximumReceiptBytes).contains(cursor) else {
            throw LLDBLogicalBreakpointProgramError.invalidCursor
        }
        return try tokenInvocation(function: "receipt_page", token: token, suffix: String(cursor))
    }

    func drainLogsCommand(
        token: Data,
        sessionEpoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64,
        expectedProcessID: Int32,
        afterSequence: UInt64
    ) throws -> String {
        guard token.count == 32 else { throw LLDBLogicalBreakpointProgramError.invalidToken }
        guard adapterGeneration > 0 else { throw LLDBLogicalBreakpointProgramError.invalidGeneration }
        guard expectedProcessID > 0 else { throw LLDBLogicalBreakpointProgramError.invalidProcess }
        return try invocationCommand(
            function: "drain_logs",
            arguments: [
                Self.quoted(Self.hex(token)),
                Self.quoted(sessionEpoch.rawValue.uuidString.lowercased()),
                String(adapterGeneration),
                String(expectedProcessID),
                String(afterSequence),
            ]
        )
    }

    func cleanupCommand(token: Data) throws -> String {
        try tokenInvocation(function: "cleanup", token: token)
    }

    func privateBreakpointCleanupCommand(
        token: Data,
        adapterGeneration: UInt64,
        expectedProcessID: Int32,
        backendBreakpointID: Int,
        backendLocationID: Int,
        ownerTagDigest: Data,
        nameSHA256: Data,
        runtimeAddress: UInt64
    ) throws -> String {
        guard token.count == 32 else { throw LLDBLogicalBreakpointProgramError.invalidToken }
        guard ownerTagDigest.count == 32, nameSHA256.count == 32 else {
            throw LLDBLogicalBreakpointProgramError.invalidDigest
        }
        guard adapterGeneration > 0 else { throw LLDBLogicalBreakpointProgramError.invalidGeneration }
        guard expectedProcessID > 0 else { throw LLDBLogicalBreakpointProgramError.invalidProcess }
        guard backendBreakpointID > 0, backendLocationID > 0 else {
            throw LLDBLogicalBreakpointProgramError.invalidPayload
        }
        return try invocationCommand(
            function: "cleanup_private",
            arguments: [
                Self.quoted(Self.hex(token)),
                String(adapterGeneration),
                String(expectedProcessID),
                String(backendBreakpointID),
                String(backendLocationID),
                Self.quoted(Self.hex(ownerTagDigest)),
                Self.quoted(Self.hex(nameSHA256)),
                Self.quoted(String(format: "%016llx", runtimeAddress)),
            ]
        )
    }

    func completeEncodedWireByteCount(for command: String) throws -> Int {
        let markers = try LLDBCLIExchangeMarkers(
            token: String(repeating: "f", count: LLDBCLIExchangeMarkers.tokenCharacterCount)
        )
        let count = PersistentLLDBCLIAdapter.encodedWirePayload(
            semanticCommands: [command],
            markers: markers
        ).count
        guard count <= Self.maximumEncodedWireBytes else {
            throw LLDBLogicalBreakpointProgramError.encodedWireTooLarge
        }
        return count
    }

    private func tokenInvocation(
        function: String,
        token: Data,
        suffix: String? = nil
    ) throws -> String {
        guard token.count == 32 else { throw LLDBLogicalBreakpointProgramError.invalidToken }
        var arguments = [Self.quoted(Self.hex(token))]
        if let suffix { arguments.append(suffix) }
        return try invocationCommand(function: function, arguments: arguments)
    }

    private func invocationCommand(function: String, arguments: [String]) throws -> String {
        let script = "import builtins;n=builtins.__dict__.get('\(Self.programKey)');assert isinstance(n,dict) and n.get('__source_sha256__')=='\(sourceSHA256Hex)' and callable(n.get('\(function)'));n['\(function)'](\(arguments.joined(separator: ",")))"
        let command = Self.encodedScriptCommand(script)
        _ = try completeEncodedWireByteCount(for: command)
        return command
    }

    private static let installBufferKey = "__ms_lbi1"
    private static let programKey = "__ms_lbp1"
    private static let moduleKey = "__ms_lbm1"

    private static func installChunkCommand(
        index: Int,
        count: Int,
        sourceByteCount: Int,
        digestHex: String,
        chunk: String
    ) -> String {
        let initial = "{'n':0,'c':\(count),'b':\(sourceByteCount),'h':'\(digestHex)','p':[]}"
        return encodedScriptCommand(
            "import builtins;d=builtins.__dict__;k='\(installBufferKey)';i=\(index);s=\(index == 0 ? initial : "d.get(k)");assert isinstance(s,dict) and s.get('n')==i and s.get('c')==\(count) and s.get('b')==\(sourceByteCount) and s.get('h')=='\(digestHex)' and isinstance(s.get('p'),list);s['p'].append('\(chunk)');s['n']+=1;d[k]=s"
        )
    }

    private static func finalizeCommand(
        chunkCount: Int,
        sourceByteCount: Int,
        digestHex: String
    ) -> String {
        encodedScriptCommand(
            "import __main__ as j,base64 as b,builtins,hashlib as q,sys;d=builtins.__dict__;k='\(installBufferKey)';s=d.get(k);assert (s['n'],s['c'],s['b'],s['h'],len(s['p']))==(\(chunkCount),\(chunkCount),\(sourceByteCount),'\(digestHex)',\(chunkCount));h=s['h'];x=b.b64decode(''.join(s['p']),validate=1);assert len(x)==\(sourceByteCount) and q.sha256(x).hexdigest()==h;u,w,y='\(moduleKey)','\(programKey)','__ms_lbp1_callback';l='logical_callback';r='__source_sha256__';z=j.__dict__;i=(u in sys.modules,w in d,y in z);o=sys.modules.get(u);p=d.get(w);v=i[0] and i[1] and o and p is getattr(o,'__dict__',0) and p.get(r)==h and callable(p.get(l));assert (v and (not i[2] or z[y] is p[l])) or not any(i);m=o if v else type(sys)(u);n=m.__dict__;v or exec(compile(x.decode(),'','exec'),n,n);n[r]=h;sys.modules[u]=m;d[w]=n;z[y]=n[l];d.pop(k,None);print('\(installSentinel){\"ok\":true,\"schema\":1,\"sha256\":\"'+h+'\"}')"
        )
    }

    private static func proofCommand(digestHex: String) -> String {
        encodedScriptCommand(
            "import __main__,builtins,sys;n=builtins.__dict__.get('\(programKey)');m=sys.modules.get('\(moduleKey)');o=isinstance(n,dict) and m is not None and n is m.__dict__ and n.get('__source_sha256__')=='\(digestHex)' and all(callable(n.get(v)) for v in ('begin','upload','apply','receipt_page','drain_logs','cleanup','cleanup_private','logical_callback')) and getattr(__main__,'__ms_lbp1_callback',None) is n.get('logical_callback');print('\(installSentinel){\"ok\":'+('true' if o else 'false')+',\"schema\":1,\"sha256\":\"\(digestHex)\"}')"
        )
    }

    private static func quoted(_ value: String) -> String { "'\(value)'" }

    private static func encodedScriptCommand(_ script: String) -> String {
        // A JSON string is also a valid Python string literal. The LLDB command therefore has one
        // fixed `script exec(...)` argv shape and never relies on shell or debugger quote parsing.
        let literal = String(data: try! JSONEncoder().encode(script), encoding: .utf8)!
        return "script exec(\(literal))"
    }

    private static func isBase64Byte(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
            || (0x30...0x39).contains(byte)
            || byte == 0x2B || byte == 0x2F || byte == 0x3D
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Ordinary, reviewable Python. It consumes only canonical decoded plan data and never builds
    /// or executes Python, debugger-command, shell, command-file, or alias text from that data.
    private static let helperSource = #"""
import base64
import hashlib
import json
import lldb
import time
import unicodedata
import uuid

_STATE = None
_RECEIPT = None
_LEDGER = {}
_PRIVATE_LEDGER = {}
_HITS = {}
_LOGS = []
_LOG_BYTES = 0
_CALLBACK_SEQUENCE = 0
_CALLBACK_ACTIVE = False
_SESSION_EPOCH = None
_SESSION_TOKEN = None
_SESSION_GENERATION = None
_SESSION_PID = None
_LOG_ACK_SEQUENCE = 0
_LOG_DROP_COUNT = 0
_MAX_U64 = (1 << 64) - 1
_MAX_BINDINGS = 4096
_MAX_PLAN_BYTES = 2 * 1024 * 1024
_MAX_RECEIPT_BYTES = 2 * 1024 * 1024
_MAX_PAGE_B64 = 2048
_MAX_LOG_RECORDS = 1024
_MAX_LOG_BYTES = 1024 * 1024
_MAX_LOG_RECORD_BYTES = 4096
_MAX_CALLBACK_SECONDS = 1.0
_MAX_EXPRESSION_BYTES = 1024
_MAX_ACTIONS = 16
_MAX_FRAGMENTS = 32
_CAP_CONDITION = True
_CAP_ACTIONS = True
_CAP_TARGET_EXPRESSION = True
_CAP_CONTINUE = True
_BEGIN_SENTINEL = "MACSCOPE_LLDB_LOGICAL_BEGIN_V1 "
_UPLOAD_SENTINEL = "MACSCOPE_LLDB_LOGICAL_UPLOAD_V1 "
_APPLY_SENTINEL = "MACSCOPE_LLDB_LOGICAL_APPLY_V1 "
_RECEIPT_SENTINEL = "MACSCOPE_LLDB_LOGICAL_RECEIPT_V1 "
_LOGS_SENTINEL = "MACSCOPE_LLDB_LOGICAL_LOGS_V1 "
_CLEANUP_SENTINEL = "MACSCOPE_LLDB_LOGICAL_CLEANUP_V1 "
_PRIVATE_CLEANUP_SENTINEL = "MACSCOPE_LLDB_PRIVATE_CLEANUP_V1 "
_CALLBACK_NAME = "__main__.__ms_lbp1_callback"
_PURPOSE_LOGICAL = "logical"
_PURPOSE_RUN_TO_CURSOR = "run_to_cursor"

class _LogCapacity(Exception):
    pass

class _CallbackTimeout(Exception):
    pass

def _canonical(value):
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True)

def _emit(sentinel, value):
    print(sentinel + _canonical(value))

def _exact_keys(value, required):
    if not isinstance(value, dict) or set(value.keys()) != set(required):
        raise RuntimeError("invalid logical breakpoint object")

def _hex(value, count=64):
    return isinstance(value, str) and len(value) == count and all(c in "0123456789abcdef" for c in value)

def _token(value):
    if not _hex(value):
        raise RuntimeError("invalid logical breakpoint token")
    return value

def _positive(value, maximum=_MAX_U64):
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0 or value > maximum:
        raise RuntimeError("invalid positive integer")
    return value

def _nonnegative(value, maximum=_MAX_U64):
    if not isinstance(value, int) or isinstance(value, bool) or value < 0 or value > maximum:
        raise RuntimeError("invalid nonnegative integer")
    return value

def _address(value):
    if not _hex(value, 16):
        raise RuntimeError("invalid canonical address")
    return int(value, 16)

def _uuid(value):
    if not isinstance(value, str) or str(uuid.UUID(value)) != value.lower():
        raise RuntimeError("invalid canonical UUID")
    return value.lower()

def _safe_identifier(value, maximum=256):
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > maximum:
        raise RuntimeError("invalid identifier")
    if not all(c.isascii() and (c.isalnum() or c in "-_.:") for c in value):
        raise RuntimeError("invalid identifier")
    return value

def _purpose(value):
    if value not in (_PURPOSE_LOGICAL, _PURPOSE_RUN_TO_CURSOR):
        raise RuntimeError("invalid logical breakpoint purpose")
    return value

def _decoded_text(value, maximum, allow_empty=False):
    if not isinstance(value, str):
        raise RuntimeError("invalid encoded text")
    try:
        raw = base64.b64decode(value, validate=True)
        text = raw.decode("utf-8")
    except Exception as error:
        raise RuntimeError("invalid encoded text") from error
    if len(raw) > maximum or (not allow_empty and not raw):
        raise RuntimeError("encoded text bound exceeded")
    if any(
        ord(c) < 32 or ord(c) == 127 or ord(c) in (0x2028, 0x2029)
        or unicodedata.category(c) in ("Cc", "Cf")
        for c in text
    ):
        raise RuntimeError("encoded text control rejected")
    return text

def _observe():
    target = lldb.debugger.GetSelectedTarget()
    process = target.GetProcess()
    pid = int(process.GetProcessID())
    stop_id = int(process.GetStopID())
    state = int(process.GetState())
    if pid <= 0 or pid > 2147483647 or stop_id <= 0 or stop_id > 4294967295 or state != int(lldb.eStateStopped):
        raise RuntimeError("logical breakpoint target is not at the admitted stop")
    return target, process, pid, stop_id

def _observe_drain():
    target = lldb.debugger.GetSelectedTarget()
    process = target.GetProcess()
    if not target.IsValid() or not process.IsValid():
        raise RuntimeError("logical breakpoint log process invalid")
    state = int(process.GetState())
    if state not in (int(lldb.eStateRunning), int(lldb.eStateStopped), int(lldb.eStateExited)):
        raise RuntimeError("logical breakpoint log process state invalid")
    pid = int(process.GetProcessID())
    if state == int(lldb.eStateExited):
        if pid not in (0, _SESSION_PID):
            raise RuntimeError("logical breakpoint exited process changed")
    elif pid != _SESSION_PID:
        raise RuntimeError("logical breakpoint log process changed")
    return _SESSION_PID

def _breakpoint_names(breakpoint):
    names = lldb.SBStringList()
    breakpoint.GetNames(names)
    return [names.GetStringAtIndex(index) for index in range(names.GetSize())]

def _owned_prefix(purpose, generation, owner_tag):
    purpose = _purpose(purpose)
    namespace = "macscope_logical_g" if purpose == _PURPOSE_LOGICAL else "macscope_private_run_to_cursor_g"
    return namespace + str(generation) + "_" + owner_tag + "_"

def _owned_name(purpose, generation, owner_tag, binding_id, policy_digest, issuance_digest):
    return _owned_prefix(purpose, generation, owner_tag) + hashlib.sha256((binding_id + policy_digest + issuance_digest).encode("ascii")).hexdigest()

def _owned_inventory(target, purpose, generation, owner_tag):
    prefix = _owned_prefix(purpose, generation, owner_tag)
    records = []
    for index in range(int(target.GetNumBreakpoints())):
        breakpoint = target.GetBreakpointAtIndex(index)
        matching = [name for name in _breakpoint_names(breakpoint) if isinstance(name, str) and name.startswith(prefix)]
        if not matching:
            continue
        backend_id = int(breakpoint.GetID())
        if backend_id <= 0 or len(matching) != 1 or int(breakpoint.GetNumLocations()) != 1:
            raise RuntimeError("owned breakpoint inventory is incomplete")
        location = breakpoint.GetLocationAtIndex(0)
        location_id = int(location.GetID())
        load_address = int(location.GetAddress().GetLoadAddress(target))
        if location_id <= 0 or load_address < 0 or load_address > _MAX_U64:
            raise RuntimeError("owned breakpoint location is invalid")
        records.append({
            "backend_breakpoint_id": backend_id,
            "backend_location_id": location_id,
            "auto_continue": bool(breakpoint.GetAutoContinue()),
            "enabled": bool(breakpoint.IsEnabled()),
            "name": matching[0],
            "one_shot": bool(breakpoint.IsOneShot()),
            "runtime_address": format(load_address, "016x"),
        })
    records.sort(key=lambda item: (item["backend_breakpoint_id"], item["backend_location_id"]))
    return records

def _validate_hit_policy(value):
    _exact_keys(value, ("kind", "count"))
    if value["kind"] == "always":
        if value["count"] is not None:
            raise RuntimeError("invalid always policy")
        return {"kind": "always", "count": None}
    if value["kind"] == "ignore_first":
        count = _positive(value["count"], 4294967295)
        return {"kind": "ignore_first", "count": count}
    raise RuntimeError("unknown hit policy")

def _validate_actions(actions):
    if not isinstance(actions, list) or len(actions) > _MAX_ACTIONS:
        raise RuntimeError("invalid action count")
    accepted = []
    for action in actions:
        if not isinstance(action, dict) or action.get("kind") not in ("log", "evaluate_target_expression"):
            raise RuntimeError("invalid action")
        if action["kind"] == "evaluate_target_expression":
            _exact_keys(action, ("kind", "label_b64", "expression_b64"))
            accepted.append({
                "kind": action["kind"],
                "label": _decoded_text(action["label_b64"], 256),
                "expression": _decoded_text(action["expression_b64"], _MAX_EXPRESSION_BYTES),
            })
        else:
            _exact_keys(action, ("kind", "fragments"))
            fragments = action["fragments"]
            if not isinstance(fragments, list) or len(fragments) > _MAX_FRAGMENTS:
                raise RuntimeError("invalid log fragments")
            decoded = []
            for fragment in fragments:
                _exact_keys(fragment, ("kind", "value_b64"))
                if fragment["kind"] not in ("literal", "target_expression"):
                    raise RuntimeError("invalid log fragment")
                decoded.append({
                    "kind": fragment["kind"],
                    "value": _decoded_text(
                        fragment["value_b64"],
                        4096 if fragment["kind"] == "literal" else _MAX_EXPRESSION_BYTES,
                        True,
                    ),
                })
            accepted.append({"kind": "log", "fragments": decoded})
            if sum(len(item["value"].encode("utf-8")) for item in decoded) > 4096:
                raise RuntimeError("log template capacity")
    combined_bytes = 0
    for action in accepted:
        if action["kind"] == "evaluate_target_expression":
            combined_bytes += len(action["label"].encode("utf-8"))
            combined_bytes += len(action["expression"].encode("utf-8"))
        else:
            combined_bytes += sum(len(item["value"].encode("utf-8")) for item in action["fragments"])
    if combined_bytes > 16 * 1024:
        raise RuntimeError("combined action capacity")
    return accepted

def _validate_binding(value, purpose, generation, expected_pid, expected_stop_id):
    _exact_keys(value, (
        "artifact_uuid", "binding_id", "condition_b64", "disposition", "hit_policy",
        "issuance_digest", "logical_id", "mapped_byte_count", "mapped_runtime_start",
        "mapped_static_start", "owner_tag_digest", "policy_action_digest", "runtime_address",
        "specification_revision", "static_address", "actions",
    ))
    binding_id = _safe_identifier(value["binding_id"])
    owner_tag = value["owner_tag_digest"]
    policy_digest = value["policy_action_digest"]
    issuance_digest = value["issuance_digest"]
    if not _hex(owner_tag) or not _hex(policy_digest) or not _hex(issuance_digest):
        raise RuntimeError("invalid binding digest")
    runtime_address = _address(value["runtime_address"])
    static_address = _address(value["static_address"])
    runtime_start = _address(value["mapped_runtime_start"])
    static_start = _address(value["mapped_static_start"])
    byte_count = _positive(value["mapped_byte_count"])
    if runtime_address < runtime_start or static_address < static_start:
        raise RuntimeError("binding precedes mapped range")
    static_offset = static_address - static_start
    runtime_offset = runtime_address - runtime_start
    if static_offset != runtime_offset or static_offset >= byte_count:
        raise RuntimeError("binding mapping relationship is invalid")
    condition = None if value["condition_b64"] is None else _decoded_text(
        value["condition_b64"], _MAX_EXPRESSION_BYTES
    )
    if condition is not None and not _CAP_CONDITION:
        raise RuntimeError("condition capability unavailable")
    actions = _validate_actions(value["actions"])
    if actions and not _CAP_ACTIONS:
        raise RuntimeError("action capability unavailable")
    if not _CAP_TARGET_EXPRESSION and any(
        action["kind"] == "evaluate_target_expression"
        or any(fragment["kind"] == "target_expression" for fragment in action.get("fragments", []))
        for action in actions
    ):
        raise RuntimeError("target expression capability unavailable")
    disposition = value["disposition"]
    if disposition not in ("stop", "continue_after_successful_actions"):
        raise RuntimeError("invalid disposition")
    if disposition == "continue_after_successful_actions" and not _CAP_CONTINUE:
        raise RuntimeError("continue capability unavailable")
    return {
        "actions": actions,
        "artifact_uuid": _uuid(value["artifact_uuid"]),
        "binding_id": binding_id,
        "condition": condition,
        "disposition": disposition,
        "expected_pid": expected_pid,
        "expected_stop_id": expected_stop_id,
        "generation": generation,
        "hit_policy": _validate_hit_policy(value["hit_policy"]),
        "issuance_digest": issuance_digest,
        "logical_id": _uuid(value["logical_id"]),
        "mapped_byte_count": byte_count,
        "mapped_runtime_start": runtime_start,
        "mapped_static_start": static_start,
        "name": _owned_name(purpose, generation, owner_tag, binding_id, policy_digest, issuance_digest),
        "owner_tag_digest": owner_tag,
        "policy_action_digest": policy_digest,
        "purpose": purpose,
        "runtime_address": runtime_address,
        "specification_revision": _positive(value["specification_revision"], 9223372036854775807),
        "static_address": static_address,
    }

def _validate_plan(value, state):
    required_keys = (
        "adapter_generation", "bindings", "observed_pid", "observed_stop_id",
        "owner_tag_digest", "purpose", "schema", "session_epoch", "transaction_id",
    )
    _exact_keys(value, required_keys)
    if value["purpose"] != _PURPOSE_LOGICAL:
        raise RuntimeError("invalid logical breakpoint object")
    purpose = _purpose(value["purpose"])
    if value["schema"] != 1:
        raise RuntimeError("logical breakpoint plan authority mismatch")
    generation = _positive(value["adapter_generation"])
    pid = _positive(value["observed_pid"], 2147483647)
    stop_id = _positive(value["observed_stop_id"], 4294967295)
    if generation != state["generation"] or pid != state["pid"] or stop_id != state["stop_id"]:
        raise RuntimeError("logical breakpoint plan coordinate mismatch")
    owner_tag = value["owner_tag_digest"]
    if not _hex(owner_tag):
        raise RuntimeError("logical breakpoint ownership tag invalid")
    bindings = value["bindings"]
    if not isinstance(bindings, list) or len(bindings) > _MAX_BINDINGS:
        raise RuntimeError("logical breakpoint binding capacity")
    accepted = [_validate_binding(item, purpose, generation, pid, stop_id) for item in bindings]
    if any(item["owner_tag_digest"] != owner_tag for item in accepted):
        raise RuntimeError("logical breakpoint ownership tag mismatch")
    if len({item["binding_id"] for item in accepted}) != len(accepted):
        raise RuntimeError("duplicate binding identity")
    if len({item["runtime_address"] for item in accepted}) != len(accepted):
        raise RuntimeError("ambiguous runtime address")
    session_epoch = _uuid(value["session_epoch"])
    for item in accepted:
        item["session_epoch"] = session_epoch
    accepted.sort(key=lambda item: (item["runtime_address"], item["binding_id"]))
    return _safe_identifier(value["transaction_id"]), session_epoch, generation, owner_tag, purpose, accepted

def _validate_private_plan(value, state):
    _exact_keys(value, (
        "adapter_generation", "authority_revision", "binding", "inventory_revision",
        "lifecycle_revision", "observed_pid", "observed_stop_id", "owner_digest",
        "run_id", "schema", "session_epoch", "stop_revision",
        "workspace_catalog_revision",
    ))
    if value["schema"] != 1:
        raise RuntimeError("private breakpoint plan schema mismatch")
    generation = _positive(value["adapter_generation"])
    pid = _positive(value["observed_pid"], 2147483647)
    stop_id = _positive(value["observed_stop_id"], 4294967295)
    if generation != state["generation"] or pid != state["pid"] or stop_id != state["stop_id"]:
        raise RuntimeError("private breakpoint plan coordinate mismatch")
    _positive(value["authority_revision"])
    _positive(value["inventory_revision"])
    _positive(value["workspace_catalog_revision"])
    _nonnegative(value["lifecycle_revision"])
    _nonnegative(value["stop_revision"])
    owner_digest = value["owner_digest"]
    if not _hex(owner_digest):
        raise RuntimeError("private breakpoint owner digest invalid")
    run_id = _uuid(value["run_id"])
    binding = value["binding"]
    _exact_keys(binding, (
        "artifact_uuid", "mapped_byte_count", "mapped_runtime_start", "mapped_static_start",
        "module_ordinal", "name_owner_digest", "one_shot", "owned_name_b64", "purpose",
        "runtime_address", "static_address", "workspace_binary_id",
        "workspace_owner_revision", "workspace_slot",
    ))
    if binding["purpose"] != _PURPOSE_RUN_TO_CURSOR or binding["one_shot"] is not True:
        raise RuntimeError("private breakpoint purpose mismatch")
    artifact_uuid = _uuid(binding["artifact_uuid"])
    _uuid(binding["workspace_binary_id"])
    _nonnegative(binding["module_ordinal"], 4294967295)
    _nonnegative(binding["workspace_slot"])
    _positive(binding["workspace_owner_revision"])
    runtime_address = _address(binding["runtime_address"])
    static_address = _address(binding["static_address"])
    runtime_start = _address(binding["mapped_runtime_start"])
    static_start = _address(binding["mapped_static_start"])
    byte_count = _positive(binding["mapped_byte_count"])
    if runtime_address < runtime_start or static_address < static_start:
        raise RuntimeError("private breakpoint precedes mapped range")
    if runtime_address - runtime_start != static_address - static_start:
        raise RuntimeError("private breakpoint displacement mismatch")
    if runtime_address - runtime_start >= byte_count:
        raise RuntimeError("private breakpoint lies outside mapped range")
    owned_name = _decoded_text(binding["owned_name_b64"], 256)
    expected_name = (
        _owned_prefix(_PURPOSE_RUN_TO_CURSOR, generation, owner_digest)
        + run_id.replace("-", "")
    )
    name_owner_digest = binding["name_owner_digest"]
    if (
        owned_name != expected_name or not _hex(name_owner_digest)
        or hashlib.sha256(owned_name.encode("utf-8")).hexdigest() != name_owner_digest
    ):
        raise RuntimeError("private breakpoint name ownership mismatch")
    return run_id, _uuid(value["session_epoch"]), generation, owner_digest, {
        "artifact_uuid": artifact_uuid,
        "expected_pid": pid,
        "expected_stop_id": stop_id,
        "generation": generation,
        "mapped_byte_count": byte_count,
        "mapped_runtime_start": runtime_start,
        "mapped_static_start": static_start,
        "name": owned_name,
        "name_owner_digest": name_owner_digest,
        "owner_tag_digest": owner_digest,
        "purpose": _PURPOSE_RUN_TO_CURSOR,
        "run_id": run_id,
        "runtime_address": runtime_address,
        "static_address": static_address,
    }

def begin(token, generation, expected_pid, expected_stop_id, page_count, byte_count, digest):
    global _STATE, _RECEIPT
    _token(token)
    generation = _positive(generation)
    expected_pid = _positive(expected_pid, 2147483647)
    expected_stop_id = _positive(expected_stop_id, 4294967295)
    page_count = _positive(page_count, 8192)
    byte_count = _positive(byte_count, _MAX_PLAN_BYTES)
    if not _hex(digest):
        raise RuntimeError("invalid plan digest")
    if _STATE is not None or _RECEIPT is not None:
        raise RuntimeError("logical breakpoint scratch state is busy")
    target, process, pid, stop_id = _observe()
    if pid != expected_pid or stop_id != expected_stop_id:
        raise RuntimeError("logical breakpoint begin coordinate changed")
    _STATE = {
        "byte_count": byte_count,
        "digest": digest,
        "generation": generation,
        "next": 0,
        "page_count": page_count,
        "pages": [],
        "pid": pid,
        "stop_id": stop_id,
        "token": token,
    }
    _RECEIPT = None
    _emit(_BEGIN_SENTINEL, {"ok": True, "schema": 1, "token": token})

def upload(token, page_index, page_count, payload64, page_digest):
    global _STATE
    state = _STATE
    if not isinstance(state, dict) or state.get("token") != _token(token):
        raise RuntimeError("logical breakpoint upload token mismatch")
    if page_count != state["page_count"] or page_index != state["next"]:
        raise RuntimeError("logical breakpoint upload sequence mismatch")
    if not isinstance(payload64, str) or not payload64 or len(payload64) > _MAX_PAGE_B64 or not _hex(page_digest):
        raise RuntimeError("invalid logical breakpoint page")
    try:
        page = base64.b64decode(payload64, validate=True)
    except Exception as error:
        raise RuntimeError("invalid logical breakpoint page encoding") from error
    if base64.b64encode(page).decode("ascii") != payload64 or hashlib.sha256(page).hexdigest() != page_digest:
        raise RuntimeError("logical breakpoint page digest mismatch")
    state["pages"].append(page)
    state["next"] += 1
    _emit(_UPLOAD_SENTINEL, {
        "index": page_index, "ok": True, "schema": 1, "token": token,
    })

def _delete_exact(target, backend_id):
    breakpoint = target.FindBreakpointByID(backend_id)
    if not breakpoint.IsValid() or not target.BreakpointDelete(backend_id):
        raise RuntimeError("exact owned breakpoint deletion failed")
    if target.FindBreakpointByID(backend_id).IsValid():
        raise RuntimeError("exact owned breakpoint absence not proven")

def _rollback_created(target, backend_ids):
    for backend_id in reversed(backend_ids):
        if target.FindBreakpointByID(backend_id).IsValid():
            _delete_exact(target, backend_id)
        for key in [key for key in _LEDGER if key[0] == backend_id]:
            _LEDGER.pop(key, None)
        for key in [key for key in _PRIVATE_LEDGER if key[0] == backend_id]:
            _PRIVATE_LEDGER.pop(key, None)

def _stage_binding(target, metadata):
    breakpoint = target.BreakpointCreateByAddress(metadata["runtime_address"])
    backend_id = int(breakpoint.GetID())
    if backend_id <= 0:
        raise RuntimeError("owned breakpoint creation failed")
    try:
        breakpoint.SetEnabled(False)
        breakpoint.SetOneShot(metadata["purpose"] == _PURPOSE_RUN_TO_CURSOR)
        breakpoint.SetAutoContinue(False)
        if not breakpoint.AddName(metadata["name"]):
            raise RuntimeError("owned breakpoint naming failed")
        callback_error = breakpoint.SetScriptCallbackFunction(_CALLBACK_NAME, lldb.SBStructuredData())
        if not callback_error.Success():
            raise RuntimeError("owned breakpoint callback install failed")
        if int(breakpoint.GetNumLocations()) != 1:
            raise RuntimeError("owned breakpoint location is not exact")
        location = breakpoint.GetLocationAtIndex(0)
        location_id = int(location.GetID())
        load_address = int(location.GetAddress().GetLoadAddress(target))
        if location_id <= 0 or load_address != metadata["runtime_address"]:
            raise RuntimeError("owned breakpoint address readback failed")
        if (
            breakpoint.IsEnabled()
            or bool(breakpoint.IsOneShot()) != (metadata["purpose"] == _PURPOSE_RUN_TO_CURSOR)
            or breakpoint.GetAutoContinue()
        ):
            raise RuntimeError("owned breakpoint staging readback failed")
        if metadata["purpose"] == _PURPOSE_RUN_TO_CURSOR:
            _PRIVATE_LEDGER[(backend_id, location_id)] = dict(metadata)
        else:
            _LEDGER[(backend_id, location_id)] = dict(metadata)
        return backend_id
    except Exception:
        if target.FindBreakpointByID(backend_id).IsValid():
            _delete_exact(target, backend_id)
        for key in [key for key in _LEDGER if key[0] == backend_id]:
            _LEDGER.pop(key, None)
        for key in [key for key in _PRIVATE_LEDGER if key[0] == backend_id]:
            _PRIVATE_LEDGER.pop(key, None)
        raise

def _receipt_record(location):
    metadata = _LEDGER.get((location["backend_breakpoint_id"], location["backend_location_id"]))
    if not isinstance(metadata, dict):
        raise RuntimeError("owned breakpoint ledger is incomplete")
    if (
        not location["enabled"]
        or location["one_shot"] != (metadata["purpose"] == _PURPOSE_RUN_TO_CURSOR)
        or location["auto_continue"]
        or location["name"] != metadata["name"]
        or location["runtime_address"] != format(metadata["runtime_address"], "016x")
    ):
        raise RuntimeError("owned breakpoint receipt readback mismatch")
    return {
        "backend_breakpoint_id": location["backend_breakpoint_id"],
        "backend_location_id": location["backend_location_id"],
        "auto_continue": location["auto_continue"],
        "binding_id": metadata["binding_id"],
        "enabled": location["enabled"],
        "issuance_digest": metadata["issuance_digest"],
        "logical_id": metadata["logical_id"],
        "name_sha256": hashlib.sha256(location["name"].encode("utf-8")).hexdigest(),
        "owner_tag_digest": metadata["owner_tag_digest"],
        "one_shot": location["one_shot"],
        "policy_action_digest": metadata["policy_action_digest"],
        "runtime_address": location["runtime_address"],
        "specification_revision": metadata["specification_revision"],
    }

def _prestate_record(location):
    return {
        "auto_continue": location["auto_continue"],
        "backend_breakpoint_id": location["backend_breakpoint_id"],
        "backend_location_id": location["backend_location_id"],
        "enabled": location["enabled"],
        "name_sha256": hashlib.sha256(location["name"].encode("utf-8")).hexdigest(),
        "one_shot": location["one_shot"],
        "runtime_address": location["runtime_address"],
    }

def _inventory_matches(locations, bindings):
    if len(locations) != len(bindings):
        return False
    desired = {item["binding_id"]: item for item in bindings}
    if len(desired) != len(bindings):
        return False
    for location in locations:
        metadata = _LEDGER.get((location["backend_breakpoint_id"], location["backend_location_id"]))
        if not isinstance(metadata, dict):
            return False
        expected = desired.get(metadata.get("binding_id"))
        if expected is None or metadata != expected:
            return False
        if (
            not location["enabled"]
            or location["one_shot"] != (expected["purpose"] == _PURPOSE_RUN_TO_CURSOR)
            or location["auto_continue"]
            or location["name"] != expected["name"]
            or location["runtime_address"] != format(expected["runtime_address"], "016x")
        ):
            return False
    return True

def _publish_receipt(state, token, transaction_id, session_epoch, generation, pid, stop_id, pre_state, deleted_ids, complete, did_write):
    global _RECEIPT
    receipt = {
        "adapter_generation": generation,
        "deleted_backend_ids": deleted_ids,
        "did_write_backend": did_write,
        "locations": [_receipt_record(item) for item in complete],
        "observed_pid": pid,
        "observed_stop_id": stop_id,
        "ok": True,
        "plan_digest": state["digest"],
        "pre_state": [_prestate_record(item) for item in pre_state],
        "schema": 1,
        "session_epoch": session_epoch,
        "token": token,
        "transaction_id": transaction_id,
    }
    encoded = _canonical(receipt).encode("utf-8")
    if len(encoded) > _MAX_RECEIPT_BYTES:
        raise RuntimeError("logical breakpoint receipt capacity")
    _RECEIPT = {
        "bytes": encoded,
        "digest": hashlib.sha256(encoded).hexdigest(),
        "token": token,
    }
    _emit(_APPLY_SENTINEL, {
        "count": len(complete), "digest": _RECEIPT["digest"], "ok": True,
        "schema": 1, "token": token,
    })

def _publish_private_receipt(state, token, generation, pid, stop_id, metadata, complete):
    global _RECEIPT
    if len(complete) != 1:
        raise RuntimeError("private breakpoint receipt inventory mismatch")
    location = complete[0]
    ledger = _PRIVATE_LEDGER.get((
        location["backend_breakpoint_id"], location["backend_location_id"],
    ))
    if ledger != metadata:
        raise RuntimeError("private breakpoint receipt ledger mismatch")
    if (
        not location["enabled"] or not location["one_shot"] or location["auto_continue"]
        or location["name"] != metadata["name"]
        or location["runtime_address"] != format(metadata["runtime_address"], "016x")
    ):
        raise RuntimeError("private breakpoint receipt readback mismatch")
    receipt = {
        "adapter_generation": generation,
        "backend_breakpoint_id": location["backend_breakpoint_id"],
        "backend_location_id": location["backend_location_id"],
        "name_owner_digest": metadata["name_owner_digest"],
        "observed_pid": pid,
        "observed_stop_id": stop_id,
        "ok": True,
        "one_shot": True,
        "plan_digest": state["digest"],
        "purpose": _PURPOSE_RUN_TO_CURSOR,
        "run_id": metadata["run_id"],
        "runtime_address": format(metadata["runtime_address"], "016x"),
        "schema": 1,
    }
    encoded = _canonical(receipt).encode("utf-8")
    if len(encoded) > 4096:
        raise RuntimeError("private breakpoint receipt capacity")
    _RECEIPT = {
        "bytes": encoded,
        "digest": hashlib.sha256(encoded).hexdigest(),
        "token": token,
    }
    _emit(_APPLY_SENTINEL, {
        "count": 1, "digest": _RECEIPT["digest"], "ok": True,
        "schema": 1, "token": token,
    })

def apply(token):
    global _STATE, _RECEIPT, _SESSION_EPOCH, _SESSION_TOKEN, _SESSION_GENERATION, _SESSION_PID
    global _HITS, _LOGS, _LOG_BYTES, _LOG_ACK_SEQUENCE, _LOG_DROP_COUNT
    state = _STATE
    if not isinstance(state, dict) or state.get("token") != _token(token):
        raise RuntimeError("logical breakpoint apply token mismatch")
    target, process, pid, stop_id = _observe()
    if pid != state["pid"] or stop_id != state["stop_id"] or state["next"] != state["page_count"]:
        raise RuntimeError("logical breakpoint apply coordinate changed")
    raw = b"".join(state["pages"])
    if len(raw) != state["byte_count"] or hashlib.sha256(raw).hexdigest() != state["digest"]:
        raise RuntimeError("logical breakpoint complete plan mismatch")
    try:
        plan_value = json.loads(raw.decode("utf-8"))
    except Exception as error:
        raise RuntimeError("logical breakpoint plan JSON invalid") from error
    if _canonical(plan_value).encode("utf-8") != raw:
        raise RuntimeError("logical breakpoint plan is not canonical")
    private_root_keys = {
        "adapter_generation", "authority_revision", "binding", "inventory_revision",
        "lifecycle_revision", "observed_pid", "observed_stop_id", "owner_digest",
        "run_id", "schema", "session_epoch", "stop_revision",
        "workspace_catalog_revision",
    }
    if isinstance(plan_value, dict) and set(plan_value.keys()) == private_root_keys:
        run_id, session_epoch, generation, owner_tag, metadata = _validate_private_plan(
            plan_value, state
        )
        if _owned_inventory(target, _PURPOSE_RUN_TO_CURSOR, generation, owner_tag):
            raise RuntimeError("private breakpoint owner already has an active binding")
        metadata["cleanup_token"] = token
        created = []
        try:
            created.append(_stage_binding(target, metadata))
            breakpoint = target.FindBreakpointByID(created[0])
            breakpoint.SetEnabled(True)
            if not breakpoint.IsEnabled() or not breakpoint.IsOneShot() or breakpoint.GetAutoContinue():
                raise RuntimeError("private breakpoint enable readback failed")
        except Exception:
            _rollback_created(target, created)
            raise
        complete = _owned_inventory(target, _PURPOSE_RUN_TO_CURSOR, generation, owner_tag)
        if {item["backend_breakpoint_id"] for item in complete} != set(created):
            _rollback_created(target, created)
            raise RuntimeError("private breakpoint complete inventory mismatch")
        _SESSION_EPOCH = session_epoch
        _publish_private_receipt(
            state, token, generation, pid, stop_id, metadata, complete
        )
        return
    transaction_id, session_epoch, generation, owner_tag, purpose, bindings = _validate_plan(plan_value, state)
    if _SESSION_EPOCH != session_epoch:
        _HITS = {}
        _LOGS = []
        _LOG_BYTES = 0
        _LOG_ACK_SEQUENCE = 0
        _LOG_DROP_COUNT = 0
        _SESSION_EPOCH = session_epoch
    _SESSION_TOKEN = token
    _SESSION_GENERATION = generation
    _SESSION_PID = pid
    previous = _owned_inventory(target, purpose, generation, owner_tag)
    previous_ids = [item["backend_breakpoint_id"] for item in previous]
    if _inventory_matches(previous, bindings):
        _publish_receipt(
            state, token, transaction_id, session_epoch, generation, pid, stop_id,
            previous, [], previous, False,
        )
        return
    created = []
    try:
        for metadata in bindings:
            created.append(_stage_binding(target, metadata))
        for backend_id in created:
            breakpoint = target.FindBreakpointByID(backend_id)
            breakpoint.SetEnabled(True)
            if not breakpoint.IsEnabled():
                raise RuntimeError("owned breakpoint enable readback failed")
        for backend_id in previous_ids:
            _delete_exact(target, backend_id)
            for key in [key for key in _LEDGER if key[0] == backend_id]:
                _LEDGER.pop(key, None)
    except Exception:
        _rollback_created(target, created)
        raise
    complete = _owned_inventory(target, purpose, generation, owner_tag)
    expected_ids = set(created)
    if {item["backend_breakpoint_id"] for item in complete} != expected_ids:
        raise RuntimeError("complete owned post-state mismatch")
    _publish_receipt(
        state, token, transaction_id, session_epoch, generation, pid, stop_id,
        previous, previous_ids, complete, True,
    )

def receipt_page(token, cursor):
    receipt = _RECEIPT
    if not isinstance(receipt, dict) or receipt.get("token") != _token(token):
        raise RuntimeError("logical breakpoint receipt token mismatch")
    cursor = _nonnegative(cursor, _MAX_RECEIPT_BYTES)
    encoded = receipt["bytes"]
    if cursor > len(encoded):
        raise RuntimeError("logical breakpoint receipt cursor invalid")
    end = min(len(encoded), cursor + 1536)
    _emit(_RECEIPT_SENTINEL, {
        "cursor": cursor,
        "digest": receipt["digest"],
        "final": end == len(encoded),
        "next": end,
        "ok": True,
        "payload_b64": base64.b64encode(encoded[cursor:end]).decode("ascii"),
        "schema": 1,
        "token": token,
    })

def _deadline(deadline):
    remaining = int((deadline - time.monotonic()) * 1000000)
    if remaining <= 0:
        raise _CallbackTimeout("callback-deadline")
    return remaining

def _expression(frame, text, deadline):
    options = lldb.SBExpressionOptions()
    remaining = _deadline(deadline)
    options.SetTimeoutInMicroSeconds(min(250000, remaining))
    options.SetUnwindOnError(True)
    options.SetIgnoreBreakpoints(True)
    value = frame.EvaluateExpression(text, options)
    _deadline(deadline)
    error = value.GetError()
    if not error.Success():
        if "timed out" in (error.GetCString() or "").lower():
            raise _CallbackTimeout("expression-timeout")
        raise RuntimeError("target expression failed")
    rendered = value.GetValue()
    if rendered is None:
        rendered = value.GetSummary()
    return "" if rendered is None else str(rendered)

def _condition_truth(value):
    if value in ("false", "False"):
        return False
    if value in ("true", "True"):
        return True
    if not isinstance(value, str) or not value or len(value) > _MAX_EXPRESSION_BYTES or not value.isascii():
        raise RuntimeError("ambiguous condition value")
    digits = value[1:] if value[0] in "+-" else value
    if digits and digits.isdecimal():
        return int(value, 10) != 0
    if value.startswith(("0x", "0X")):
        digits = value[2:]
        if digits and all(c in "0123456789abcdefABCDEF" for c in digits):
            return int(value, 16) != 0
    raise RuntimeError("ambiguous condition value")

def _append_log(record, fault_record=False):
    global _LOG_BYTES, _CALLBACK_SEQUENCE
    if _CALLBACK_SEQUENCE == _MAX_U64:
        raise RuntimeError("callback sequence overflow")
    next_sequence = _CALLBACK_SEQUENCE + 1
    record["sequence"] = next_sequence
    encoded = _canonical(record).encode("utf-8")
    if len(encoded) > _MAX_LOG_RECORD_BYTES:
        raise _LogCapacity("expanded log record capacity")
    record_limit = _MAX_LOG_RECORDS if fault_record else _MAX_LOG_RECORDS - 1
    byte_limit = _MAX_LOG_BYTES if fault_record else _MAX_LOG_BYTES - _MAX_LOG_RECORD_BYTES
    if len(_LOGS) >= record_limit or _LOG_BYTES + len(encoded) > byte_limit:
        raise _LogCapacity("correlated log ring capacity")
    _CALLBACK_SEQUENCE = next_sequence
    _LOGS.append(record)
    _LOG_BYTES += len(encoded)

def _callback_fault(breakpoint, metadata, code, dropped_record=False):
    global _LOG_DROP_COUNT
    breakpoint.SetEnabled(False)
    if metadata.get("purpose") == _PURPOSE_RUN_TO_CURSOR:
        return True
    if dropped_record:
        if _LOG_DROP_COUNT == _MAX_U64:
            return True
        _LOG_DROP_COUNT += 1
    try:
        _append_log({
            "adapter_generation": metadata.get("generation"),
            "binding_id": metadata.get("binding_id"),
            "backend_breakpoint_id": int(breakpoint.GetID()),
            "backend_location_id": metadata.get("backend_location_id"),
            "code": code,
            "drop_count": _LOG_DROP_COUNT,
            "hit_count": _HITS.get(metadata.get("logical_id"), 0),
            "issuance_digest": metadata.get("issuance_digest"),
            "logical_id": metadata.get("logical_id"),
            "outcome": "fault_stop",
            "process_id": metadata.get("expected_pid"),
            "session_epoch": metadata.get("session_epoch"),
            "specification_revision": metadata.get("specification_revision"),
        }, True)
    except Exception:
        pass
    return True

def cleanup_private(token, generation, expected_pid, backend_id, location_id, owner_tag, name_digest, runtime_address):
    token = _token(token)
    generation = _positive(generation)
    expected_pid = _positive(expected_pid, 2147483647)
    backend_id = _positive(backend_id, 2147483647)
    location_id = _positive(location_id, 2147483647)
    if not _hex(owner_tag) or not _hex(name_digest):
        raise RuntimeError("private breakpoint cleanup digest invalid")
    runtime_address_value = _address(runtime_address)
    target, process, pid, stop_id = _observe()
    if pid != expected_pid:
        raise RuntimeError("private breakpoint cleanup process changed")
    metadata = _PRIVATE_LEDGER.get((backend_id, location_id))
    if not isinstance(metadata, dict) or metadata.get("purpose") != _PURPOSE_RUN_TO_CURSOR:
        raise RuntimeError("private breakpoint cleanup ledger identity mismatch")
    if metadata.get("cleanup_token") != token:
        raise RuntimeError("private breakpoint cleanup token mismatch")
    expected_name = metadata.get("name")
    if (
        metadata.get("generation") != generation
        or metadata.get("expected_pid") != expected_pid
        or metadata.get("owner_tag_digest") != owner_tag
        or metadata.get("runtime_address") != runtime_address_value
        or not isinstance(expected_name, str)
        or hashlib.sha256(expected_name.encode("utf-8")).hexdigest() != name_digest
    ):
        raise RuntimeError("private breakpoint cleanup expected identity mismatch")
    breakpoint = target.FindBreakpointByID(backend_id)
    was_present = bool(breakpoint.IsValid())
    if was_present:
        names = _breakpoint_names(breakpoint)
        if (
            names != [expected_name]
            or int(breakpoint.GetNumLocations()) != 1
            or not breakpoint.IsEnabled()
            or not breakpoint.IsOneShot()
            or breakpoint.GetAutoContinue()
        ):
            raise RuntimeError("private breakpoint cleanup backend identity mismatch")
        location = breakpoint.GetLocationAtIndex(0)
        if (
            int(location.GetID()) != location_id
            or int(location.GetAddress().GetLoadAddress(target)) != runtime_address_value
        ):
            raise RuntimeError("private breakpoint cleanup location identity mismatch")
        _delete_exact(target, backend_id)
    elif target.FindBreakpointByID(backend_id).IsValid():
        raise RuntimeError("private breakpoint absence not proven")
    _PRIVATE_LEDGER.pop((backend_id, location_id), None)
    if (backend_id, location_id) in _PRIVATE_LEDGER or target.FindBreakpointByID(backend_id).IsValid():
        raise RuntimeError("private breakpoint cleanup not proven")
    _emit(_PRIVATE_CLEANUP_SENTINEL, {
        "backend_breakpoint_id": backend_id,
        "backend_location_id": location_id,
        "name_sha256": name_digest,
        "ok": True,
        "owner_tag_digest": owner_tag,
        "runtime_address": runtime_address,
        "schema": 1,
        "token": token,
        "was_present": was_present,
    })

def logical_callback(frame, bp_loc, extra_args, internal_dict):
    global _CALLBACK_ACTIVE
    breakpoint = bp_loc.GetBreakpoint()
    backend_id = int(breakpoint.GetID())
    location_id = int(bp_loc.GetID())
    metadata = _LEDGER.get((backend_id, location_id))
    if metadata is None:
        metadata = _PRIVATE_LEDGER.get((backend_id, location_id))
    if not isinstance(metadata, dict):
        breakpoint.SetEnabled(False)
        return True
    metadata = dict(metadata)
    metadata["backend_location_id"] = location_id
    if _CALLBACK_ACTIVE:
        return _callback_fault(breakpoint, metadata, "callback-reentrancy")
    _CALLBACK_ACTIVE = True
    deadline = time.monotonic() + _MAX_CALLBACK_SECONDS
    try:
        process = frame.GetThread().GetProcess()
        target = process.GetTarget()
        pid = int(process.GetProcessID())
        load_address = int(bp_loc.GetAddress().GetLoadAddress(target))
        module_uuid = frame.GetModule().GetUUIDString()
        if pid != metadata["expected_pid"] or load_address != metadata["runtime_address"]:
            return _callback_fault(breakpoint, metadata, "runtime-ownership-mismatch")
        if module_uuid is None or str(uuid.UUID(module_uuid)) != metadata["artifact_uuid"]:
            return _callback_fault(breakpoint, metadata, "artifact-ownership-mismatch")
        runtime_offset = load_address - metadata["mapped_runtime_start"]
        static_offset = metadata["static_address"] - metadata["mapped_static_start"]
        if runtime_offset != static_offset or runtime_offset < 0 or runtime_offset >= metadata["mapped_byte_count"]:
            return _callback_fault(breakpoint, metadata, "mapped-range-mismatch")
        _deadline(deadline)
        if metadata["purpose"] == _PURPOSE_RUN_TO_CURSOR:
            return True
        logical_id = metadata["logical_id"]
        count = _HITS.get(logical_id, 0)
        if count == _MAX_U64:
            return _callback_fault(breakpoint, metadata, "hit-count-overflow")
        count += 1
        _HITS[logical_id] = count
        policy = metadata["hit_policy"]
        if policy["kind"] == "ignore_first" and count <= policy["count"]:
            _append_log({
                "adapter_generation": metadata["generation"],
                "binding_id": metadata["binding_id"], "hit_count": count,
                "backend_breakpoint_id": backend_id, "backend_location_id": location_id,
                "issuance_digest": metadata["issuance_digest"],
                "logical_id": logical_id, "outcome": "ignored",
                "process_id": pid, "session_epoch": metadata["session_epoch"],
                "specification_revision": metadata["specification_revision"],
            })
            return False
        if metadata["condition"] is not None:
            condition_value = _expression(frame, metadata["condition"], deadline)
            if not _condition_truth(condition_value):
                _append_log({
                    "adapter_generation": metadata["generation"],
                    "binding_id": metadata["binding_id"], "hit_count": count,
                    "backend_breakpoint_id": backend_id, "backend_location_id": location_id,
                    "issuance_digest": metadata["issuance_digest"],
                    "logical_id": logical_id, "outcome": "condition_false",
                    "process_id": pid, "session_epoch": metadata["session_epoch"],
                    "specification_revision": metadata["specification_revision"],
                })
                return False
        outputs = []
        for action in metadata["actions"]:
            if action["kind"] == "evaluate_target_expression":
                outputs.append({
                    "kind": action["kind"], "label": action["label"],
                    "value": _expression(frame, action["expression"], deadline),
                })
            else:
                fragments = []
                for fragment in action["fragments"]:
                    fragments.append(
                        fragment["value"] if fragment["kind"] == "literal"
                        else _expression(frame, fragment["value"], deadline)
                    )
                    _deadline(deadline)
                text = "".join(fragments)
                if len(text.encode("utf-8")) > _MAX_LOG_RECORD_BYTES:
                    return _callback_fault(breakpoint, metadata, "expanded-log-capacity", True)
                outputs.append({"kind": "log", "text": text})
        outcome = (
            "continue_after_successful_actions"
            if metadata["disposition"] == "continue_after_successful_actions"
            else "stop"
        )
        _deadline(deadline)
        _append_log({
            "adapter_generation": metadata["generation"],
            "binding_id": metadata["binding_id"], "hit_count": count,
            "backend_breakpoint_id": backend_id, "backend_location_id": location_id,
            "issuance_digest": metadata["issuance_digest"],
            "logical_id": logical_id, "outcome": outcome, "outputs": outputs,
            "process_id": pid, "session_epoch": metadata["session_epoch"],
            "specification_revision": metadata["specification_revision"],
        })
        return outcome != "continue_after_successful_actions"
    except _CallbackTimeout as error:
        return _callback_fault(breakpoint, metadata, str(error))
    except _LogCapacity:
        return _callback_fault(breakpoint, metadata, "log-ring-capacity", True)
    except Exception:
        return _callback_fault(breakpoint, metadata, "callback-failure")
    finally:
        _CALLBACK_ACTIVE = False

def drain_logs(token, session_epoch, generation, expected_pid, after_sequence):
    global _LOGS, _LOG_BYTES, _LOG_ACK_SEQUENCE
    token = _token(token)
    session_epoch = _uuid(session_epoch)
    generation = _positive(generation)
    expected_pid = _positive(expected_pid, 2147483647)
    if (
        token != _SESSION_TOKEN or session_epoch != _SESSION_EPOCH
        or generation != _SESSION_GENERATION or expected_pid != _SESSION_PID
    ):
        raise RuntimeError("logical breakpoint log authority mismatch")
    pid = _observe_drain()
    after_sequence = _nonnegative(after_sequence)
    if after_sequence < _LOG_ACK_SEQUENCE or after_sequence > _CALLBACK_SEQUENCE:
        raise RuntimeError("logical breakpoint log acknowledgement mismatch")
    _LOGS = [record for record in _LOGS if record["sequence"] > after_sequence]
    _LOG_BYTES = sum(len(_canonical(record).encode("utf-8")) for record in _LOGS)
    _LOG_ACK_SEQUENCE = after_sequence
    records = [record for record in _LOGS if record["sequence"] > after_sequence]
    selected = []
    for record in records:
        candidate = selected + [record]
        if len(_canonical(candidate).encode("utf-8")) > 64 * 1024:
            break
        selected = candidate
    next_sequence = after_sequence if not selected else selected[-1]["sequence"]
    _emit(_LOGS_SENTINEL, {
        "adapter_generation": generation, "after_sequence": after_sequence,
        "final": len(selected) == len(records), "next_sequence": next_sequence,
        "ok": True, "process_id": expected_pid, "records": selected, "schema": 1,
        "session_epoch": session_epoch, "token": token,
    })

def cleanup(token):
    global _STATE, _RECEIPT
    _token(token)
    if isinstance(_STATE, dict) and _STATE.get("token") not in (None, token):
        raise RuntimeError("logical breakpoint cleanup token mismatch")
    if isinstance(_RECEIPT, dict) and _RECEIPT.get("token") not in (None, token):
        raise RuntimeError("logical breakpoint receipt cleanup token mismatch")
    _STATE = None
    _RECEIPT = None
    if _STATE is not None or _RECEIPT is not None:
        raise RuntimeError("logical breakpoint cleanup not proven")
    _emit(_CLEANUP_SENTINEL, {"ok": True, "schema": 1, "token": token})
"""#
}
