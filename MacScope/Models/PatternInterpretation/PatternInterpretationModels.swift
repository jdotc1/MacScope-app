import Foundation

// Shared wire values compiled once in MacScopeAnalysisCore.
struct PatternInterpretationKey: Codable, Hashable, Sendable {
    var imageIdentity: String
    var byteSnapshotID: UUID
    var patternIdentity: String
    var selectionImageOffset: UInt64
    var selectionByteCount: UInt64
}

struct PatternInterpretationRequest: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var requestID: UUID
    var key: PatternInterpretationKey
    var bytes: Data
    var source: String
    var maximumNodes: Int = 4096
    var maximumDepth: Int = 24
    var maximumArrayChildren: Int = 256
    var cooperativeTimeoutMS: Int = 2000

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              !bytes.isEmpty, bytes.count <= 1_048_576,
              key.selectionByteCount == UInt64(bytes.count),
              key.selectionImageOffset <= UInt64.max - UInt64(bytes.count),
              !source.isEmpty, source.utf8.count <= 32_768,
              (1...4096).contains(maximumNodes),
              (1...24).contains(maximumDepth),
              (1...256).contains(maximumArrayChildren),
              (1...2000).contains(cooperativeTimeoutMS),
              Self.validIdentity(key.imageIdentity, maximum: 256),
              Self.validIdentity(key.patternIdentity, maximum: 128)
        else { throw PatternInterpretationError.invalidRequest }
    }

    private static func validIdentity(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.utf8.allSatisfy { (0x20...0x7E).contains($0) }
    }
}

enum PatternInterpretationError: Error {
    case invalidRequest, malformedReply, staleReply, nativeUnavailable, alreadyRun
}

struct PatternInterpretationReply: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case completed, partial, rejected, cancelled, timedOut, failed
    }
    var schemaVersion: Int
    var engineCommit: String
    var requestID: String
    var imageIdentity: String
    var patternIdentity: String
    var byteSnapshotID: UUID
    var selectionImageOffset: UInt64
    var selectionByteCount: UInt64
    var status: Status
    var nodes: [PatternField]
    var diagnostics: [PatternDiagnostic]

    var key: PatternInterpretationKey {
        .init(imageIdentity: imageIdentity, byteSnapshotID: byteSnapshotID,
              patternIdentity: patternIdentity, selectionImageOffset: selectionImageOffset,
              selectionByteCount: selectionByteCount)
    }
}

struct PatternField: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case array, bitfieldArray, bitfield, bitfieldField, `struct`, union
        case `enum`, unsigned, signed, boolean, character, float, string, padding, unsupported
    }
    enum Backing: String, Codable, Sendable {
        case file, synthetic, empty, outOfRange, unsupported
    }
    struct BackedRange: Codable, Equatable, Sendable {
        var selectionOffset: UInt64
        var length: UInt64
    }
    struct Bits: Codable, Sendable {
        enum Numbering: String, Codable, Sendable { case lsb0, msb0 }
        var offsetWithinFirstByte: UInt64
        var count: UInt64
        var numbering: Numbering
    }

    var id: UInt64
    var parentID: UInt64?
    var depth: UInt32
    var kind: Kind
    var name: String
    var typeName: String
    var sectionID: UInt64
    var patternOffset: UInt64
    var declaredSize: UInt64
    var backing: Backing
    var ranges: [BackedRange]
    var bits: Bits?
    var value: String
    var flags: [String]
    var childCount: UInt64
    var childrenTruncated: Bool
}

struct PatternDiagnostic: Codable, Sendable {
    enum Severity: String, Codable, Sendable { case info, warning, error }
    var code: String
    var severity: Severity
    var fieldID: UInt64?
    var message: String
    var line: UInt32
    var column: UInt32
}

