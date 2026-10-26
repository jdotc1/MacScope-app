import CryptoKit
import Foundation

enum LLDBRuntimeModuleInventoryDiagnosticCode: String, Equatable, Sendable {
    case invalidFraming
    case semanticCommandFailed
    case invalidJSON
    case noncanonicalJSON
    case invalidSchema
    case capacity
    case invalidBase64
    case invalidText
    case invalidUUID
    case invalidNumber
    case invalidOrdinal
    case invalidRange
    case processMismatch
    case processNotStopped
    case tokenMismatch
    case collectionMismatch
    case intervalMismatch
    case digestMismatch
    case duplicateFingerprint
    case rawPageTooLarge
    case wrappedResultTooLarge
    case exchangeTooLarge
    case capacityExceeded
    case deadlineExceeded
    case completedCollection
}

struct LLDBRuntimeModuleInventoryFailure: Error, LocalizedError, Equatable, Sendable {
    let code: LLDBRuntimeModuleInventoryDiagnosticCode
    let evidenceByteCount: Int
    let evidenceSHA256: Data

    var errorDescription: String? { "Runtime module inventory rejected (\(code.rawValue))." }
}

struct LLDBRuntimeModuleDecodedSection: Sendable {
    let ordinal: UInt32
    let name: String?
    let staticStart: UInt64
    let runtimeStart: UInt64?
    let byteCount: UInt64
    let permissions: UInt8
    fileprivate let canonicalTupleWithoutOrdinal: Phase2ProductionJSONValue
}

struct LLDBRuntimeModuleDecodedRecord: Sendable {
    let ordinal: UInt32
    let uuid: UUID?
    let fullPath: String
    let normalizedArchitectureTriple: String
    let sections: [LLDBRuntimeModuleDecodedSection]
    let fingerprintSHA256: Data
    let canonicalRecord: Phase2ProductionJSONValue
}

struct LLDBRuntimeModuleDecodedPage: Sendable {
    let token: Data
    let digest: Data
    let observedProcessID: Int32
    let observedStopID: UInt32
    let moduleCount: UInt32
    let start: UInt32
    let end: UInt32
    let isFinal: Bool
    let modules: [LLDBRuntimeModuleDecodedRecord]
    let rawPageByteCount: Int
}

struct LLDBRuntimeModuleInventoryDecoder: Sendable {
    static let maximumRawPageBytes = 128 * 1_024
    static let maximumWrappedResultLineBytes = 192 * 1_024
    static let maximumModuleCount = 4_096
    static let maximumSectionsPerModule = 128

    private static let sentinel = "MACSCOPE_LLDB_MODULE_PAGE_V1 "
    private static let successKeys: Set<String> = [
        "digest", "end", "final", "module_count", "modules", "observed_pid",
        "observed_state", "observed_stop_id", "ok", "schema", "start", "token",
    ]
    private static let capacityKeys: Set<String> = ["code", "ok", "schema", "token"]

    func decodePage(from result: LLDBCLITranscriptResult) throws -> LLDBRuntimeModuleDecodedPage {
        let semantic = try trustedSemanticTranscript(from: result)
        let semanticBytes = Data(semantic.utf8)
        guard result.exchangeByteCount >= 0,
              result.exchangeByteCount <= LLDBCLITranscriptDecoder.maximumExchangeBytes else {
            throw makeLLDBRuntimeModuleInventoryFailure(.exchangeTooLarge, semanticBytes, originalCount: result.exchangeByteCount)
        }
        let calculatedWrapped = Self.wrappedResultLineByteCount(forPayloadByteCount: semanticBytes.count)
        guard result.semanticCommandResultLineByteCounts.count == 1 else {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidFraming, semanticBytes)
        }
        let wrappedCount = result.semanticCommandResultLineByteCounts[0]
        guard wrappedCount >= calculatedWrapped, wrappedCount <= Self.maximumWrappedResultLineBytes else {
            throw makeLLDBRuntimeModuleInventoryFailure(.wrappedResultTooLarge, semanticBytes, originalCount: wrappedCount)
        }
        guard semanticBytes.count <= Self.maximumRawPageBytes else {
            throw makeLLDBRuntimeModuleInventoryFailure(.rawPageTooLarge, semanticBytes)
        }
        guard semantic.hasPrefix(Self.sentinel), semantic.hasSuffix("\n"),
              semantic.utf8.filter({ $0 == 0x0a }).count == 1,
              !semantic.utf8.contains(0x0d) else {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidFraming, semanticBytes)
        }
        let jsonStart = semantic.index(semantic.startIndex, offsetBy: Self.sentinel.count)
        let jsonEnd = semantic.index(before: semantic.endIndex)
        guard jsonStart <= jsonEnd else { throw makeLLDBRuntimeModuleInventoryFailure(.invalidFraming, semanticBytes) }
        let jsonData = Data(semantic[jsonStart..<jsonEnd].utf8)
        guard jsonData.first == 0x7b, jsonData.last == 0x7d else {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidFraming, semanticBytes)
        }
        let value: Phase2ProductionJSONValue
        do {
            value = try Phase2StrictJSONParser().parse(
                jsonData,
                limits: Phase2StrictJSONLimits(
                    maximumBytes: Self.maximumRawPageBytes,
                    maximumDepth: 8,
                    maximumTokens: 500_000,
                    maximumMembersAndElements: 250_000
                )
            )
        } catch {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidJSON, jsonData)
        }
        guard value.canonicalJSONBytes() == jsonData else {
            throw makeLLDBRuntimeModuleInventoryFailure(.noncanonicalJSON, jsonData)
        }
        guard case .object(let object) = value else { throw makeLLDBRuntimeModuleInventoryFailure(.invalidSchema, jsonData) }
        if Set(object.keys) == Self.capacityKeys {
            guard object["code"]?.stringValue == "capacity",
                  object["ok"]?.boolValue == false,
                  canonicalUnsigned(object["schema"], maximum: 1) == 1,
                  decodeHexData(object["token"]?.stringValue, byteCount: 32) != nil else {
                throw makeLLDBRuntimeModuleInventoryFailure(.invalidSchema, jsonData)
            }
            throw makeLLDBRuntimeModuleInventoryFailure(.capacity, jsonData)
        }
        guard Set(object.keys) == Self.successKeys,
              object["ok"]?.boolValue == true,
              canonicalUnsigned(object["schema"], maximum: 1) == 1,
              let token = decodeHexData(object["token"]?.stringValue, byteCount: 32),
              let digest = decodeHexData(object["digest"]?.stringValue, byteCount: 32),
              let pidValue = canonicalUnsigned(object["observed_pid"], maximum: UInt64(Int32.max)),
              pidValue > 0,
              let stopValue = canonicalUnsigned(object["observed_stop_id"], maximum: UInt64(UInt32.max)),
              let countValue = canonicalUnsigned(object["module_count"], maximum: UInt64(Self.maximumModuleCount)),
              let startValue = canonicalUnsigned(object["start"], maximum: countValue),
              let endValue = canonicalUnsigned(object["end"], maximum: countValue),
              startValue <= endValue,
              let isFinal = object["final"]?.boolValue,
              isFinal == (endValue == countValue),
              let moduleValues = object["modules"]?.arrayValue,
              UInt64(moduleValues.count) == endValue - startValue else {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidSchema, jsonData)
        }
        guard object["observed_state"]?.stringValue == "stopped" else {
            throw makeLLDBRuntimeModuleInventoryFailure(.processNotStopped, jsonData)
        }
        let pid = Int32(pidValue)
        guard result.observedProcessID == pid else { throw makeLLDBRuntimeModuleInventoryFailure(.processMismatch, jsonData) }
        guard result.observedProcessState == .stopped(processID: pid) else {
            throw makeLLDBRuntimeModuleInventoryFailure(.processNotStopped, jsonData)
        }

        var modules: [LLDBRuntimeModuleDecodedRecord] = []
        modules.reserveCapacity(moduleValues.count)
        for (offset, moduleValue) in moduleValues.enumerated() {
            let expectedOrdinal = startValue + UInt64(offset)
            modules.append(try decodeModule(moduleValue, expectedOrdinal: expectedOrdinal, evidence: jsonData))
        }
        return LLDBRuntimeModuleDecodedPage(
            token: token,
            digest: digest,
            observedProcessID: pid,
            observedStopID: UInt32(stopValue),
            moduleCount: UInt32(countValue),
            start: UInt32(startValue),
            end: UInt32(endValue),
            isFinal: isFinal,
            modules: modules,
            rawPageByteCount: semanticBytes.count
        )
    }

    private func trustedSemanticTranscript(from result: LLDBCLITranscriptResult) throws -> String {
        guard result.semanticCommandsSucceeded else {
            throw makeLLDBRuntimeModuleInventoryFailure(.semanticCommandFailed, Data(result.trustedSemanticTranscript.utf8))
        }
        guard result.firstFailedSemanticCommandIndex == nil,
              result.semanticCommandTranscripts.count == 1 else {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidFraming, Data(result.trustedSemanticTranscript.utf8))
        }
        return result.semanticCommandTranscripts[0]
    }

    private func decodeModule(
        _ value: Phase2ProductionJSONValue,
        expectedOrdinal: UInt64,
        evidence: Data
    ) throws -> LLDBRuntimeModuleDecodedRecord {
        guard case .array(let fields) = value, fields.count == 5,
              canonicalUnsigned(fields[0], maximum: UInt64(Self.maximumModuleCount - 1)) == expectedOrdinal else {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidOrdinal, evidence)
        }
        let uuid: UUID?
        switch fields[1] {
        case .null:
            uuid = nil
        case .string(let text):
            guard text.count == 36,
                  text == text.lowercased(),
                  let parsed = UUID(uuidString: text),
                  parsed.uuidString.lowercased() == text else {
                throw makeLLDBRuntimeModuleInventoryFailure(.invalidUUID, evidence)
            }
            uuid = parsed
        default:
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidUUID, evidence)
        }
        let path = try decodeBase64Text(fields[2], maximumBytes: 4_096, allowEmpty: true, evidence: evidence)
        guard case .string(let triple) = fields[3], isArchitectureTriple(triple),
              case .array(let sectionValues) = fields[4],
              sectionValues.count <= Self.maximumSectionsPerModule else {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidSchema, evidence)
        }
        var sections: [LLDBRuntimeModuleDecodedSection] = []
        sections.reserveCapacity(sectionValues.count)
        for (index, sectionValue) in sectionValues.enumerated() {
            sections.append(try decodeSection(sectionValue, expectedOrdinal: UInt64(index), evidence: evidence))
        }
        let fingerprintInput: Phase2ProductionJSONValue = .array([
            uuid.map { .string($0.uuidString.lowercased()) } ?? .null,
            .string(triple),
            fields[2],
            .array(sections.map(\.canonicalTupleWithoutOrdinal)),
        ])
        return LLDBRuntimeModuleDecodedRecord(
            ordinal: UInt32(expectedOrdinal),
            uuid: uuid,
            fullPath: path,
            normalizedArchitectureTriple: triple,
            sections: sections,
            fingerprintSHA256: Data(SHA256.hash(data: fingerprintInput.canonicalJSONBytes())),
            canonicalRecord: value
        )
    }

    private func decodeSection(
        _ value: Phase2ProductionJSONValue,
        expectedOrdinal: UInt64,
        evidence: Data
    ) throws -> LLDBRuntimeModuleDecodedSection {
        guard case .array(let fields) = value, fields.count == 6,
              canonicalUnsigned(fields[0], maximum: UInt64(Self.maximumSectionsPerModule - 1)) == expectedOrdinal else {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidOrdinal, evidence)
        }
        let name: String?
        switch fields[1] {
        case .null:
            name = nil
        default:
            name = try decodeBase64Text(fields[1], maximumBytes: 256, allowEmpty: false, evidence: evidence)
        }
        guard let staticStart = decodeFixedHex(fields[2]),
              staticStart != .max,
              let byteCount = decodeFixedHex(fields[4]), byteCount > 0,
              let permissionsValue = canonicalUnsigned(fields[5], maximum: 7) else {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidRange, evidence)
        }
        let runtimeStart: UInt64?
        switch fields[3] {
        case .null:
            runtimeStart = nil
        default:
            guard let decoded = decodeFixedHex(fields[3]), decoded != .max else {
                throw makeLLDBRuntimeModuleInventoryFailure(.invalidRange, evidence)
            }
            runtimeStart = decoded
        }
        let (lastOffset, underflowed) = byteCount.subtractingReportingOverflow(1)
        guard !underflowed,
              !staticStart.addingReportingOverflow(lastOffset).overflow,
              runtimeStart.map({ !$0.addingReportingOverflow(lastOffset).overflow }) ?? true else {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidRange, evidence)
        }
        let tuple: Phase2ProductionJSONValue = .array(Array(fields.dropFirst()))
        return LLDBRuntimeModuleDecodedSection(
            ordinal: UInt32(expectedOrdinal),
            name: name,
            staticStart: staticStart,
            runtimeStart: runtimeStart,
            byteCount: byteCount,
            permissions: UInt8(permissionsValue),
            canonicalTupleWithoutOrdinal: tuple
        )
    }

    private func decodeBase64Text(
        _ value: Phase2ProductionJSONValue,
        maximumBytes: Int,
        allowEmpty: Bool,
        evidence: Data
    ) throws -> String {
        guard case .string(let encoded) = value,
              let bytes = Data(base64Encoded: encoded),
              bytes.base64EncodedString() == encoded else {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidBase64, evidence)
        }
        guard bytes.count <= maximumBytes,
              (allowEmpty || !bytes.isEmpty),
              let text = String(data: bytes, encoding: .utf8),
              text.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) else {
            throw makeLLDBRuntimeModuleInventoryFailure(.invalidText, evidence)
        }
        return text
    }

    private func canonicalUnsigned(_ value: Phase2ProductionJSONValue?, maximum: UInt64) -> UInt64? {
        guard case .number(let text) = value,
              !text.isEmpty,
              text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              (text == "0" || text.first != "0"),
              let number = UInt64(text), number <= maximum else { return nil }
        return number
    }

    private func decodeFixedHex(_ value: Phase2ProductionJSONValue) -> UInt64? {
        guard case .string(let text) = value,
              text.utf8.count == 16,
              text.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            return nil
        }
        return UInt64(text, radix: 16)
    }

    private func decodeHexData(_ text: String?, byteCount: Int) -> Data? {
        guard let text else { return nil }
        let bytes = Array(text.utf8)
        guard bytes.count == byteCount * 2 else { return nil }
        var result = Data(capacity: byteCount)
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = hexNibble(bytes[offset]),
                  let low = hexNibble(bytes[offset + 1]) else { return nil }
            result.append((high << 4) | low)
        }
        return result
    }

    private func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39:
            return byte - 0x30
        case 0x61...0x66:
            return byte - 0x61 + 10
        default:
            return nil
        }
    }

    private func isArchitectureTriple(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 256, text == text.lowercased() else { return false }
        return text.utf8.allSatisfy {
            (0x61...0x7a).contains($0) || (0x30...0x39).contains($0)
                || $0 == 0x2b || $0 == 0x2d || $0 == 0x2e || $0 == 0x5f
        }
    }

    private static func wrappedResultLineByteCount(forPayloadByteCount count: Int) -> Int {
        let base64Count = ((count + 2) / 3) * 4
        return "__MACSCOPE_LLDB_COMMAND_RESULT_".utf8.count + 64 + "_0_".utf8.count
            + base64Count + "__\n".utf8.count
    }
}

func makeLLDBRuntimeModuleInventoryFailure(
    _ code: LLDBRuntimeModuleInventoryDiagnosticCode,
    _ evidence: Data,
    originalCount: Int? = nil
) -> LLDBRuntimeModuleInventoryFailure {
    LLDBRuntimeModuleInventoryFailure(
        code: code,
        evidenceByteCount: originalCount ?? evidence.count,
        evidenceSHA256: Data(SHA256.hash(data: evidence))
    )
}
