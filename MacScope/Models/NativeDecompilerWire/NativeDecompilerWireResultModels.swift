import Foundation

enum NativeDecompilerWireAddressSpaceKind: String, Sendable, Equatable, Codable {
    case constant
    case processor
    case spacebase
    case unique
    case fspec
    case iop
    case join
}

enum NativeDecompilerWireTypeKind: String, Sendable, Equatable, Codable {
    case array
    case boolean
    case enumeration
    case floatingPoint = "floating-point"
    case function
    case integer
    case pointer
    case structure
    case union
    case unknown
    case void
}

enum NativeDecompilerWireVarnodeRole: String, Sendable, Equatable, Codable {
    case address
    case constant
    case internalValue
    case join
    case memory
    case register
    case stack
    case unique

    private enum CodingKeys: String, CodingKey { case value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "internal" {
            self = .internalValue
        } else if let decoded = Self(rawValue: value) {
            self = decoded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown varnode role.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self == .internalValue ? "internal" : rawValue)
    }
}

enum NativeDecompilerWireOpcode: String, CaseIterable, Sendable, Equatable, Codable {
    case copy, load, store, branch, cbranch, branchind, call, callind, callother
    case `return`
    case intEqual = "int_equal"
    case intNotEqual = "int_notequal"
    case intSignedLess = "int_sless"
    case intSignedLessEqual = "int_slessequal"
    case intLess = "int_less"
    case intLessEqual = "int_lessequal"
    case intZeroExtend = "int_zext"
    case intSignExtend = "int_sext"
    case intAdd = "int_add"
    case intSubtract = "int_sub"
    case intCarry = "int_carry"
    case intSignedCarry = "int_scarry"
    case intSignedBorrow = "int_sborrow"
    case intTwosComplement = "int_2comp"
    case intNegate = "int_negate"
    case intExclusiveOr = "int_xor"
    case intAnd = "int_and"
    case intOr = "int_or"
    case intLeft = "int_left"
    case intRight = "int_right"
    case intSignedRight = "int_sright"
    case intMultiply = "int_mult"
    case intDivide = "int_div"
    case intSignedDivide = "int_sdiv"
    case intRemainder = "int_rem"
    case intSignedRemainder = "int_srem"
    case booleanNegate = "bool_negate"
    case booleanExclusiveOr = "bool_xor"
    case booleanAnd = "bool_and"
    case booleanOr = "bool_or"
    case floatEqual = "float_equal"
    case floatNotEqual = "float_notequal"
    case floatLess = "float_less"
    case floatLessEqual = "float_lessequal"
    case floatNaN = "float_nan"
    case floatAdd = "float_add"
    case floatDivide = "float_div"
    case floatMultiply = "float_mult"
    case floatSubtract = "float_sub"
    case floatNegate = "float_neg"
    case floatAbsolute = "float_abs"
    case floatSquareRoot = "float_sqrt"
    case floatIntToFloat = "float_int2float"
    case floatToFloat = "float_float2float"
    case floatTruncate = "float_trunc"
    case floatCeiling = "float_ceil"
    case floatFloor = "float_floor"
    case floatRound = "float_round"
    case multiequal, indirect, piece, subpiece, cast
    case pointerAdd = "ptradd"
    case pointerSubtract = "ptrsub"
    case segmentOperation = "segmentop"
    case constantPoolReference = "cpoolref"
    case new, insert, extract
    case populationCount = "popcount"
    case leadingZeroCount = "lzcount"
    case signedExtract = "spull"
}

enum NativeDecompilerWireBlockTerminatorKind: String, Sendable, Equatable, Codable {
    case splice
    case branch
    case conditional
    case exit
    case `fallthrough`
    case `return`
    case `switch`
}

enum NativeDecompilerWireEdgeKind: String, Sendable, Equatable, Codable {
    case splice
    case branch
    case `fallthrough`
    case falseBranch = "false"
    case switchCase = "switch-case"
    case switchDefault = "switch-default"
    case trueBranch = "true"
}

enum NativeDecompilerWireSSAValueKind: String, Sendable, Equatable, Codable {
    case annotation
    case constant
    case functionEntry = "function-entry"
    case operationResult = "operation-result"
    case phiResult = "phi-result"
}

enum NativeDecompilerWireMemoryVersionKind: String, Sendable, Equatable, Codable {
    case functionEntry = "function-entry"
    case operationResult = "operation-result"
    case phiResult = "phi-result"
}

enum NativeDecompilerWireMemoryEffectKind: String, Sendable, Equatable, Codable {
    case read
    case write
    case readWrite = "read-write"
}

enum NativeDecompilerWireVariableRole: String, Sendable, Equatable, Codable {
    case global
    case local
    case parameter
    case result
    case temporary
}

enum NativeDecompilerWireCallKind: String, Sendable, Equatable, Codable {
    case direct
    case indirect
}

enum NativeDecompilerWireRegionKind: String, Sendable, Equatable, Codable {
    case condition
    case doWhile = "do-while"
    case goto
    case `if`
    case infiniteLoop = "infinite-loop"
    case multiGoto = "multi-goto"
    case root
    case sequence
    case `switch`
    case `while`
}

enum NativeDecompilerWireTokenEntityKind: String, Sendable, Equatable, Codable {
    case block
    case call
    case instruction
    case operation
    case region
    case type
    case variable
    case varnode
}

enum NativeDecompilerWireTokenKind: String, Sendable, Equatable, Codable {
    case comment
    case identifier
    case keyword
    case literal
    case operation
    case punctuation
    case type
    case whitespace
}

enum NativeDecompilerWireDiagnosticSeverity: String, Sendable, Equatable, Codable {
    case error
    case information
    case warning
}

struct NativeDecompilerWireSourceRange: Sendable, Equatable, Codable {
    let imageID: String
    let startAddress: NativeDecompilerWireUInt64
    let endAddressExclusive: NativeDecompilerWireUInt64
}

struct NativeDecompilerWireAddressSpaceRecord: Sendable, Equatable, Codable {
    let id: String
    let name: String
    let kind: NativeDecompilerWireAddressSpaceKind
    let addressSizeBytes: UInt32
    let isProcessorSpace: Bool
}

struct NativeDecompilerWireTypeFieldRecord: Sendable, Equatable, Codable {
    let name: String
    let typeID: String
    let bitOffset: NativeDecompilerWireUInt64
    let bitSize: NativeDecompilerWireUInt64
}

struct NativeDecompilerWireTypeRecord: Sendable, Equatable, Codable {
    let id: String
    let kind: NativeDecompilerWireTypeKind
    let name: String
    let byteSize: NativeDecompilerWireUInt64?
    let isSigned: Bool?
    let pointeeTypeID: String?
    let fields: [NativeDecompilerWireTypeFieldRecord]
    let confidence: NativeDecompilerWireConfidence
    let provenance: String
    let returnTypeID: String?
    let parameterTypeIDs: [String]
}

struct NativeDecompilerWireInstructionRecord: Sendable, Equatable, Codable {
    let id: String
    let address: NativeDecompilerWireUInt64
    let bytes: Data
    let mnemonic: String
    let body: String
    let operationIDs: [String]
    let sourceRanges: [NativeDecompilerWireSourceRange]
}

struct NativeDecompilerWireVarnodeRecord: Sendable, Equatable, Codable {
    let id: String
    let addressSpaceID: String
    let offset: NativeDecompilerWireUInt64
    let sizeBytes: UInt32
    let role: NativeDecompilerWireVarnodeRole
    let typeID: String?
    let registerName: String?
}

enum NativeDecompilerWireAuthenticationEffectKind: String, Sendable, Equatable, Codable {
    case none
    case transformedOutput = "transformed-output"
    case authenticatedMemoryAccessWithoutTransformedAddress = "authenticated-memory-access-without-transformed-address"
    case authenticatedControlTransferWithoutTransformedTarget = "authenticated-control-transfer-without-transformed-target"
    case standaloneAuthenticationWithoutTransformedOutput = "standalone-authentication-without-transformed-output"
}

struct NativeDecompilerWireAuthenticationEffect: Sendable, Equatable, Codable {
    let kind: NativeDecompilerWireAuthenticationEffectKind
    let outputSSAValueID: String?

    static let none = Self(kind: .none, outputSSAValueID: nil)

    init(kind: NativeDecompilerWireAuthenticationEffectKind, outputSSAValueID: String? = nil) {
        self.kind = kind
        self.outputSSAValueID = outputSSAValueID
    }

    private enum CodingKeys: String, CodingKey { case kind, outputSSAValueID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(NativeDecompilerWireAuthenticationEffectKind.self, forKey: .kind)
        outputSSAValueID = try values.decodeIfPresent(String.self, forKey: .outputSSAValueID)
        guard (kind == .transformedOutput) == (outputSSAValueID != nil),
              outputSSAValueID.map({ !$0.isEmpty && $0.utf8.count <= 1_024 }) ?? true else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values,
                debugDescription: "Invalid authentication effect payload.")
        }
    }
}

struct NativeDecompilerWireOperationRecord: Sendable, Equatable, Codable {
    let id: String
    let blockID: String
    let sequence: NativeDecompilerWireUInt64
    let opcode: NativeDecompilerWireOpcode
    let outputVarnodeID: String?
    let inputVarnodeIDs: [String]
    let directTargetAddress: NativeDecompilerWireUInt64?
    let sourceRanges: [NativeDecompilerWireSourceRange]
    var userOperationName: String? = nil
    var authenticationEffect: NativeDecompilerWireAuthenticationEffect = .none
}

struct NativeDecompilerWireBlockRecord: Sendable, Equatable, Codable {
    let id: String
    let startAddress: NativeDecompilerWireUInt64
    let endAddressExclusive: NativeDecompilerWireUInt64
    let operationIDs: [String]
    let predecessorEdgeIDs: [String]
    let successorEdgeIDs: [String]
    let terminatorKind: NativeDecompilerWireBlockTerminatorKind
}

struct NativeDecompilerWireEdgeRecord: Sendable, Equatable, Codable {
    let id: String
    let sourceBlockID: String
    let targetBlockID: String?
    let targetAddress: NativeDecompilerWireUInt64
    let kind: NativeDecompilerWireEdgeKind
    let operationID: String?
}

enum NativeDecompilerWireInstructionDisposition: String, Sendable, Equatable, Codable {
    case retained, eliminated
}

enum NativeDecompilerWireTransferKind: String, Sendable, Equatable, Codable {
    case direct
    case rewrittenDirect = "rewritten-direct"
    case intraInstruction = "intra-instruction"
    case rewrittenIntraInstruction = "rewritten-intra-instruction"
    case `fallthrough`, indirect, splice
}

struct NativeDecompilerWireInstructionBlockSpan: Sendable, Equatable, Codable {
    let blockID: String
    let firstOperationIndex: UInt32
    let operationCount: UInt32
}

struct NativeDecompilerWireInstructionOwnership: Sendable, Equatable, Codable {
    let instructionID: String
    let disposition: NativeDecompilerWireInstructionDisposition
    let spans: [NativeDecompilerWireInstructionBlockSpan]
}

struct NativeDecompilerWireBlockPartitionBlock: Sendable, Equatable, Codable {
    let blockID: String
    let ordinal: UInt32
    let entryAddress: NativeDecompilerWireUInt64
    let sourceRanges: [NativeDecompilerWireSourceRange]
}

struct NativeDecompilerWireBlockPartitionEdge: Sendable, Equatable, Codable {
    let edgeID: String
    let sourceSlot: UInt32
    let targetSlot: UInt32
    let transferKind: NativeDecompilerWireTransferKind
}

struct NativeDecompilerWireBlockPartition: Sendable, Equatable, Codable {
    let version: UInt32
    let entryBlockID: String
    let blocks: [NativeDecompilerWireBlockPartitionBlock]
    let instructions: [NativeDecompilerWireInstructionOwnership]
    let edges: [NativeDecompilerWireBlockPartitionEdge]
}

struct NativeDecompilerWireSSAValueRecord: Sendable, Equatable, Codable {
    let id: String
    let varnodeID: String
    let kind: NativeDecompilerWireSSAValueKind
    let definingOperationID: String?
    let definingPhiID: String?
}

struct NativeDecompilerWireSSABindingRecord: Sendable, Equatable, Codable {
    let operationID: String
    let inputSSAValueIDs: [String]
    let outputSSAValueID: String?
}

struct NativeDecompilerWirePhiIncomingRecord: Sendable, Equatable, Codable {
    let sourceBlockID: String?
    let edgeID: String?
    let ssaValueID: String
}

struct NativeDecompilerWirePhiRecord: Sendable, Equatable, Codable {
    let id: String
    let blockID: String
    let varnodeID: String
    let outputSSAValueID: String
    let incoming: [NativeDecompilerWirePhiIncomingRecord]
}

struct NativeDecompilerWireMemoryVersionRecord: Sendable, Equatable, Codable {
    let id: String
    let partition: String
    let kind: NativeDecompilerWireMemoryVersionKind
    let definingOperationID: String?
    let definingMemoryPhiID: String?
}

struct NativeDecompilerWireMemoryPhiIncomingRecord: Sendable, Equatable, Codable {
    let sourceBlockID: String?
    let edgeID: String?
    let memoryVersionID: String
}

struct NativeDecompilerWireMemoryPhiRecord: Sendable, Equatable, Codable {
    let id: String
    let blockID: String
    let partition: String
    let outputMemoryVersionID: String
    let incoming: [NativeDecompilerWireMemoryPhiIncomingRecord]
}

struct NativeDecompilerWireMemoryEffectRecord: Sendable, Equatable, Codable {
    let id: String
    let operationID: String
    let kind: NativeDecompilerWireMemoryEffectKind
    let partition: String
    let inputMemoryVersionID: String?
    let outputMemoryVersionID: String?
}

struct NativeDecompilerWireVariableRecord: Sendable, Equatable, Codable {
    let id: String
    let name: String
    let role: NativeDecompilerWireVariableRole
    let typeID: String?
    let storageVarnodeIDs: [String]
    let liveRanges: [NativeDecompilerWireSourceRange]
    let confidence: NativeDecompilerWireConfidence
    let provenance: String
}

struct NativeDecompilerWireCallRecord: Sendable, Equatable, Codable {
    let id: String
    let operationID: String
    let kind: NativeDecompilerWireCallKind
    let targetAddress: NativeDecompilerWireUInt64?
    let targetSymbol: String?
    let prototypeTypeID: String?
    let argumentVariableIDs: [String]
    let resultVariableID: String?
    let sourceRanges: [NativeDecompilerWireSourceRange]
}

struct NativeDecompilerWireRegionRecord: Sendable, Equatable, Codable {
    let id: String
    let kind: NativeDecompilerWireRegionKind
    let parentRegionID: String?
    let childRegionIDs: [String]
    let blockIDs: [String]
    let conditionOperationID: String?
    let sourceRanges: [NativeDecompilerWireSourceRange]
}

struct NativeDecompilerWireTokenEntityReference: Sendable, Equatable, Codable {
    let kind: NativeDecompilerWireTokenEntityKind
    let id: String
}

struct NativeDecompilerWirePseudocodeTokenRecord: Sendable, Equatable, Codable {
    let id: String
    let text: String
    let kind: NativeDecompilerWireTokenKind
    let line: UInt32
    let column: UInt32
    let sourceRanges: [NativeDecompilerWireSourceRange]
    let entityReferences: [NativeDecompilerWireTokenEntityReference]
}

struct NativeDecompilerWirePseudocodeDocument: Sendable, Equatable, Codable {
    let text: String
    let language: String
    let isComplete: Bool
    let isTruncated: Bool
}

struct NativeDecompilerWireDiagnosticRecord: Sendable, Equatable, Codable {
    let code: String
    let severity: NativeDecompilerWireDiagnosticSeverity
    let message: String
    let sourceRanges: [NativeDecompilerWireSourceRange]
}

struct NativeDecompilerWireStructuredResult: Sendable, Equatable, Codable {
    let requestID: UUID
    let requestSHA256: String
    let image: NativeDecompilerWireImageIdentity
    let function: NativeDecompilerWireFunctionIdentity
    let addressSpaces: [NativeDecompilerWireAddressSpaceRecord]
    let types: [NativeDecompilerWireTypeRecord]
    let instructions: [NativeDecompilerWireInstructionRecord]
    let varnodes: [NativeDecompilerWireVarnodeRecord]
    let operations: [NativeDecompilerWireOperationRecord]
    let blocks: [NativeDecompilerWireBlockRecord]
    let edges: [NativeDecompilerWireEdgeRecord]
    let ssaValues: [NativeDecompilerWireSSAValueRecord]
    let ssaBindings: [NativeDecompilerWireSSABindingRecord]
    let phis: [NativeDecompilerWirePhiRecord]
    let memoryVersions: [NativeDecompilerWireMemoryVersionRecord]
    let memoryPhis: [NativeDecompilerWireMemoryPhiRecord]
    let memoryEffects: [NativeDecompilerWireMemoryEffectRecord]
    let variables: [NativeDecompilerWireVariableRecord]
    let calls: [NativeDecompilerWireCallRecord]
    let regions: [NativeDecompilerWireRegionRecord]
    let tokens: [NativeDecompilerWirePseudocodeTokenRecord]
    let pseudocodeDocument: NativeDecompilerWirePseudocodeDocument?
    let warnings: [NativeDecompilerWireDiagnosticRecord]
    let blockPartition: NativeDecompilerWireBlockPartition?

    var requiredReplySchemaVersion: UInt32 {
        function.codeRanges != nil || blockPartition != nil || operations.contains {
            $0.authenticationEffect.kind == .standaloneAuthenticationWithoutTransformedOutput
        } ? 4 : 3
    }

    init(
        requestID: UUID,
        requestSHA256: String,
        image: NativeDecompilerWireImageIdentity,
        function: NativeDecompilerWireFunctionIdentity,
        addressSpaces: [NativeDecompilerWireAddressSpaceRecord],
        types: [NativeDecompilerWireTypeRecord],
        instructions: [NativeDecompilerWireInstructionRecord],
        varnodes: [NativeDecompilerWireVarnodeRecord],
        operations: [NativeDecompilerWireOperationRecord],
        blocks: [NativeDecompilerWireBlockRecord],
        edges: [NativeDecompilerWireEdgeRecord],
        ssaValues: [NativeDecompilerWireSSAValueRecord],
        ssaBindings: [NativeDecompilerWireSSABindingRecord],
        phis: [NativeDecompilerWirePhiRecord],
        memoryVersions: [NativeDecompilerWireMemoryVersionRecord],
        memoryPhis: [NativeDecompilerWireMemoryPhiRecord],
        memoryEffects: [NativeDecompilerWireMemoryEffectRecord],
        variables: [NativeDecompilerWireVariableRecord],
        calls: [NativeDecompilerWireCallRecord],
        regions: [NativeDecompilerWireRegionRecord],
        tokens: [NativeDecompilerWirePseudocodeTokenRecord],
        pseudocodeDocument: NativeDecompilerWirePseudocodeDocument? = nil,
        warnings: [NativeDecompilerWireDiagnosticRecord],
        blockPartition: NativeDecompilerWireBlockPartition? = nil
    ) {
        self.requestID = requestID
        self.requestSHA256 = requestSHA256
        self.image = image
        self.function = function
        self.addressSpaces = addressSpaces
        self.types = types
        self.instructions = instructions
        self.varnodes = varnodes
        self.operations = operations
        self.blocks = blocks
        self.edges = edges
        self.ssaValues = ssaValues
        self.ssaBindings = ssaBindings
        self.phis = phis
        self.memoryVersions = memoryVersions
        self.memoryPhis = memoryPhis
        self.memoryEffects = memoryEffects
        self.variables = variables
        self.calls = calls
        self.regions = regions
        self.tokens = tokens
        self.pseudocodeDocument = pseudocodeDocument
        self.warnings = warnings
        self.blockPartition = blockPartition
    }
}

struct NativeDecompilerRuntimeIdentity: Sendable, Equatable, Hashable, Codable {
    let backendID: String
    let engineVersion: String
    let engineRevision: String
    let wrapperVersion: String
    let wrapperRevision: String
    let packageManifestSHA256: String
    let packageTreeSHA256: String
    let languageID: String
    let compilerSpecID: String
    let targetProfileID: String
    let contextProfileSHA256: String
}

struct NativeDecompilerWireBackendCapabilities: Sendable, Equatable, Codable {
    let nativeDecompilerHeritage: Bool
    let completeRegisterSSA: Bool
    let memorySSA: Bool
    let recoveredVariables: Bool
    let recoveredTypes: Bool
    let structuredControlFlow: Bool
    let tokenizedPseudocode: Bool
    let imageQualifiedSourceRanges: Bool
}

struct NativeDecompilerWireBackendAvailability: Sendable, Equatable, Codable {
    let available: Bool
    let reasonCode: String
    let runtimeIdentity: NativeDecompilerRuntimeIdentity
    let capabilities: NativeDecompilerWireBackendCapabilities
}

struct NativeDecompilerWireSuccess: Sendable, Equatable, Codable {
    let availability: NativeDecompilerWireBackendAvailability
    let result: NativeDecompilerWireStructuredResult
}

enum NativeDecompilerWireFailureCode: String, CaseIterable, Sendable, Equatable, Codable {
    case malformedRequest = "malformed-request"
    case malformedReply = "malformed-reply"
    case invalidRequest = "invalid-request"
    case nativeFailure = "native-failure"
    case packageVerificationFailed = "package-verification-failed"
    case busy
    case cancelled
    case timedOut = "timed-out"
    case unavailable
    case unsupportedSchemaVersion = "unsupported-schema-version"
    case requestIDMismatch = "request-id-mismatch"
    case unsupportedCompiler = "unsupported-compiler"
    case requestTooLarge = "request-too-large"
    case responseTooLarge = "response-too-large"
}

struct NativeDecompilerWireFailure: Sendable, Equatable, Codable {
    let code: NativeDecompilerWireFailureCode
    let detail: String?
}

enum NativeDecompilerWireReplyOutcome: String, Sendable, Equatable, Codable {
    case success
    case failure
}

struct NativeDecompilerWireReplyEnvelope: Sendable, Equatable, Codable {
    static let currentSchemaVersion: UInt32 = 4
    static let legacySchemaVersion: UInt32 = 3

    let schemaVersion: UInt32
    let requestID: UUID
    let outcome: NativeDecompilerWireReplyOutcome
    let success: NativeDecompilerWireSuccess?
    let failure: NativeDecompilerWireFailure?

    init(
        schemaVersion: UInt32? = nil,
        requestID: UUID,
        outcome: NativeDecompilerWireReplyOutcome,
        success: NativeDecompilerWireSuccess?,
        failure: NativeDecompilerWireFailure?
    ) {
        self.schemaVersion = schemaVersion ?? success?.result.requiredReplySchemaVersion ?? Self.legacySchemaVersion
        self.requestID = requestID
        self.outcome = outcome
        self.success = success
        self.failure = failure
    }

    init(
        schemaVersion: UInt32? = nil,
        requestID: UUID,
        success: NativeDecompilerWireSuccess
    ) {
        self.init(
            schemaVersion: schemaVersion, requestID: requestID, outcome: .success,
            success: success, failure: nil
        )
    }

    init(
        schemaVersion: UInt32? = nil,
        requestID: UUID,
        failure: NativeDecompilerWireFailure
    ) {
        self.init(
            schemaVersion: schemaVersion, requestID: requestID, outcome: .failure,
            success: nil, failure: failure
        )
    }
}
