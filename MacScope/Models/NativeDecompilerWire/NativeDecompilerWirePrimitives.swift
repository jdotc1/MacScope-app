import Foundation

@objc protocol NativeDecompilerXPCProtocol {
    func decompile(
        requestID: NSUUID,
        payload: NSData,
        withReply reply: @escaping (NSData) -> Void
    )

    func cancel(requestID: NSUUID)
}

enum NativeDecompilerWireValueError: Error, Equatable, Sendable {
    case nonCanonicalUInt64(String)
}

/// The sole wire representation for C++ `uint64_t` values, addresses, offsets,
/// semantic sequence numbers, bit sizes, and elapsed-time budgets.
struct NativeDecompilerWireUInt64: Sendable, Equatable, Hashable, Codable {
    let hex: String

    var value: UInt64 {
        // Construction and decoding prove this conversion succeeds.
        UInt64(hex, radix: 16)!
    }

    init(_ value: UInt64) {
        hex = String(format: "%016llx", value)
    }

    init(parsing value: String) throws {
        guard Self.isCanonical(value) else {
            throw NativeDecompilerWireValueError.nonCanonicalUInt64(value)
        }
        hex = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard Self.isCanonical(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected exactly 16 lowercase hexadecimal characters."
            )
        }
        hex = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    private static func isCanonical(_ value: String) -> Bool {
        guard value.utf8.count == 16 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

enum NativeDecompilerWireRequestOperation: String, Sendable, Equatable, Codable {
    case decompile
    /// The reply carries only the pseudocode document and warnings (every structured-graph
    /// collection empty). Whole-image export uses it.
    case decompileDocument = "decompile-document"
}

enum NativeDecompilerWireMemoryPermissions: String, Sendable, Equatable, Codable {
    case none = "---"
    case read = "r--"
    case write = "-w-"
    case execute = "--x"
    case readWrite = "rw-"
    case readExecute = "r-x"
    case writeExecute = "-wx"
    case readWriteExecute = "rwx"
}

enum NativeDecompilerWireSymbolKind: String, Sendable, Equatable, Codable {
    case alias
    case data
    case function
    case label
    case object
    case section
    case unknown
}

enum NativeDecompilerWireTypeHintSubjectKind: String, Sendable, Equatable, Codable {
    case address
    case function
    case variable
}

enum NativeDecompilerWireConfidence: String, Sendable, Equatable, Codable {
    case asserted
    case high
    case medium
    case low
    case unknown
}

struct NativeDecompilerWireImageIdentity: Sendable, Equatable, Codable {
    let imageID: String
    let uuid: UUID
    let preferredLoadAddress: NativeDecompilerWireUInt64
}

struct NativeDecompilerWireFunctionIdentity: Sendable, Equatable, Codable {
    let functionID: String
    let name: String
    let entryAddress: NativeDecompilerWireUInt64
    let endAddressExclusive: NativeDecompilerWireUInt64
    /// Absent on schema v3; schema v4 carries the exact disjoint code extent.
    let codeRanges: [NativeDecompilerWireCodeRange]?

    init(
        functionID: String,
        name: String,
        entryAddress: NativeDecompilerWireUInt64,
        endAddressExclusive: NativeDecompilerWireUInt64,
        codeRanges: [NativeDecompilerWireCodeRange]? = nil
    ) {
        self.functionID = functionID
        self.name = name
        self.entryAddress = entryAddress
        self.endAddressExclusive = endAddressExclusive
        self.codeRanges = codeRanges
    }
}

struct NativeDecompilerWireCodeRange: Sendable, Equatable, Codable {
    let startAddress: NativeDecompilerWireUInt64
    let endAddressExclusive: NativeDecompilerWireUInt64
}

struct NativeDecompilerWireMemoryRegion: Sendable, Equatable, Codable {
    let name: String
    let startAddress: NativeDecompilerWireUInt64
    let permissions: NativeDecompilerWireMemoryPermissions
    let rawBytes: Data
    let effectiveBytes: Data
    let appliedPatchIDs: [String]

    /// Native execution may consume this view only. `rawBytes` is provenance.
    var executableBytes: Data { effectiveBytes }
}

struct NativeDecompilerWireSymbolRecord: Sendable, Equatable, Codable {
    let imageID: String
    let address: NativeDecompilerWireUInt64
    let name: String
    let kind: NativeDecompilerWireSymbolKind
}

struct NativeDecompilerWireTypeHintRecord: Sendable, Equatable, Codable {
    let subjectKind: NativeDecompilerWireTypeHintSubjectKind
    let address: NativeDecompilerWireUInt64
    let typeName: String
    let confidence: NativeDecompilerWireConfidence
    let source: String
}

struct NativeDecompilerWireAnalysisBudgets: Sendable, Equatable, Codable {
    let profileID: String
    let maxCodeBytes: UInt32
    let maxInstructions: UInt32
    let maxOperations: UInt32
    let maxOutputBytes: UInt32
    let maxWallTimeMilliseconds: NativeDecompilerWireUInt64

    init(
        profileID: String = "native-product-budget-v1",
        maxCodeBytes: UInt32,
        maxInstructions: UInt32,
        maxOperations: UInt32,
        maxOutputBytes: UInt32,
        maxWallTimeMilliseconds: NativeDecompilerWireUInt64
    ) {
        self.profileID = profileID
        self.maxCodeBytes = maxCodeBytes
        self.maxInstructions = maxInstructions
        self.maxOperations = maxOperations
        self.maxOutputBytes = maxOutputBytes
        self.maxWallTimeMilliseconds = maxWallTimeMilliseconds
    }

    init(_ profile: NativeDecompilerProfiledAnalysisBudgets) {
        profileID = profile.profileID
        maxCodeBytes = profile.maxCodeBytes
        maxInstructions = profile.maxInstructions
        maxOperations = profile.maxOperations
        maxOutputBytes = profile.maxOutputBytes
        maxWallTimeMilliseconds = profile.maxWallTimeMilliseconds
    }
}

struct NativeDecompilerWireRequest: Sendable, Equatable, Codable {
    let requestID: UUID
    let requestSHA256: String
    let target: NativeDecompilerWireTarget
    let image: NativeDecompilerWireImageIdentity
    let function: NativeDecompilerWireFunctionIdentity
    let memoryRegions: [NativeDecompilerWireMemoryRegion]
    let symbols: [NativeDecompilerWireSymbolRecord]
    let authoredInputs: NativeDecompilerWireAuthoredInputs
    let budgets: NativeDecompilerWireAnalysisBudgets
}

struct NativeDecompilerWireRequestEnvelope: Sendable, Equatable, Codable {
    static let currentSchemaVersion: UInt32 = 3
    static let sparseCodeSchemaVersion: UInt32 = 4

    let schemaVersion: UInt32
    let requestID: UUID
    let operation: NativeDecompilerWireRequestOperation
    let body: NativeDecompilerWireRequest

    init(
        schemaVersion: UInt32 = Self.currentSchemaVersion,
        requestID: UUID,
        operation: NativeDecompilerWireRequestOperation = .decompile,
        body: NativeDecompilerWireRequest
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.operation = operation
        self.body = body
    }
}

/// Immutable correlation authority retained by the caller after a validated
/// request is sent. A successful reply is never trusted from its UUID alone.
struct NativeDecompilerWireExpectedRequestBinding: Sendable, Equatable {
    let schemaVersion: UInt32
    let requestID: UUID
    let requestSHA256: String
    let image: NativeDecompilerWireImageIdentity
    let function: NativeDecompilerWireFunctionIdentity
    let analysisRequest: NativeDecompilerWireRequest
    let operation: NativeDecompilerWireRequestOperation

    init(request: NativeDecompilerWireRequestEnvelope) {
        operation = request.operation
        schemaVersion = request.schemaVersion
        requestID = request.requestID
        requestSHA256 = request.body.requestSHA256
        image = request.body.image
        function = request.body.function
        analysisRequest = request.body
    }
}
