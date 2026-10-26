import CryptoKit
import Foundation

enum LLDBVariableScope: String, CaseIterable, Equatable, Hashable, Sendable {
    case argument
    case local
    case staticVariable = "static"

    fileprivate var order: Int {
        switch self {
        case .argument: 0
        case .local: 1
        case .staticVariable: 2
        }
    }
}

struct LLDBVariableSnapshotValue: Equatable, Hashable, Sendable {
    let scope: LLDBVariableScope
    let ordinal: UInt32
    let name: String
    let typeName: String
    let valueState: LLDBVariableDecodedValueState
    let hasChildren: Bool
    let childCount: UInt32

    var value: String? {
        guard case .available(let value, _) = valueState else { return nil }
        return value
    }

    var summary: String? {
        guard case .available(_, let summary) = valueState else { return nil }
        return summary
    }
}

enum LLDBVariableDecodedValueState: Equatable, Hashable, Sendable {
    case available(value: String?, summary: String?)
    case optimizedOut
    case unavailable
    case failed(diagnostic: String)
}

struct LLDBVariableSnapshot: Equatable, Sendable {
    let token: Data
    let observedProcessID: Int32
    let observedStopID: UInt32
    let threadID: UInt64
    let frameIndex: UInt32
    let programCounter: UInt64
    let variables: [LLDBVariableSnapshotValue]
    let argumentOmittedCount: UInt32
    let argumentWasTruncated: Bool
    let localOmittedCount: UInt32
    let localWasTruncated: Bool
    let staticOmittedCount: UInt32
    let staticWasTruncated: Bool
    let totalOmittedCount: UInt32
    let wasTruncated: Bool
}

enum LLDBVariableSnapshotDiagnosticCode: String, Equatable, Sendable {
    case capacity
    case invalidFraming
    case invalidJSON
    case noncanonicalJSON
    case invalidSchema
    case invalidValue
    case invalidOrdering
    case processNotStopped
}

struct LLDBVariableSnapshotFailure: Error, LocalizedError, Equatable, Sendable {
    let code: LLDBVariableSnapshotDiagnosticCode
    let evidenceByteCount: Int
    let evidenceSHA256: Data

    var errorDescription: String? { "LLDB variable snapshot rejected (\(code.rawValue))." }
}

/// Fail-closed decoder for the extractor's canonical, top-level SBValue snapshot.
/// It intentionally has no dependency on CLI transcript types so retained-LLDB orchestration can
/// bind framing and process observations separately from this immutable wire contract.
struct LLDBVariableSnapshotDecoder: Sendable {
    static let maximumSnapshotBytes = 256 * 1_024
    static let maximumVariableCount = 256
    static let maximumVariablesPerScope = 128
    static let maximumNameBytes = 256
    static let maximumTypeBytes = 512
    static let maximumValueBytes = 4_096
    static let maximumSummaryBytes = 4_096
    static let maximumDiagnosticBytes = 1_024
    static let maximumChildCount = 65_535

    private static let rootKeys: Set<String> = [
        "argument_omitted", "argument_truncated", "frame_index", "local_omitted",
        "local_truncated", "observed_pid",
        "observed_state", "observed_stop_id", "ok", "omitted_count", "pc", "schema",
        "static_omitted", "static_truncated", "thread_id", "token", "truncated", "variables",
    ]
    private static let variableKeys: Set<String> = [
        "child_count", "diagnostic", "has_children", "name", "ordinal", "scope",
        "state", "summary", "type", "value",
    ]

    private static let sentinel = "MACSCOPE_LLDB_VARIABLE_SNAPSHOT_V1 "

    func decodeSemanticTranscript(_ text: String) throws -> LLDBVariableSnapshot {
        let evidence = Data(text.utf8)
        guard text.hasPrefix(Self.sentinel), text.hasSuffix("\n"),
              text.utf8.filter({ $0 == 0x0a }).count == 1,
              !text.utf8.contains(0x0d) else {
            throw failure(.invalidFraming, evidence)
        }
        let start = text.index(text.startIndex, offsetBy: Self.sentinel.count)
        let end = text.index(before: text.endIndex)
        guard start < end else { throw failure(.invalidFraming, evidence) }
        return try decodeCanonicalSnapshot(Data(text[start..<end].utf8))
    }

    func decodeCanonicalSnapshot(_ data: Data) throws -> LLDBVariableSnapshot {
        guard !data.isEmpty, data.count <= Self.maximumSnapshotBytes else {
            throw failure(.capacity, data)
        }
        let root: Phase2ProductionJSONValue
        do {
            root = try Phase2StrictJSONParser().parse(
                data,
                limits: Phase2StrictJSONLimits(
                    maximumBytes: Self.maximumSnapshotBytes,
                    maximumDepth: 4,
                    maximumTokens: Self.maximumVariableCount * 64 + 128,
                    maximumMembersAndElements: Self.maximumVariableCount * 12 + 128
                )
            )
        } catch {
            throw failure(.invalidJSON, data)
        }
        guard root.canonicalJSONBytes() == data else { throw failure(.noncanonicalJSON, data) }
        guard case .object(let object) = root, Set(object.keys) == Self.rootKeys else {
            throw failure(.invalidSchema, data)
        }
        guard object["ok"]?.boolValue == true,
              unsigned(object["schema"], maximum: 1) == 1,
              let token = hex(object["token"]?.stringValue, byteCount: 32),
              let pidRaw = unsigned(object["observed_pid"], maximum: UInt64(Int32.max)), pidRaw > 0,
              let stopRaw = unsigned(object["observed_stop_id"], maximum: UInt64(UInt32.max)), stopRaw > 0,
              let threadID = unsigned(object["thread_id"], maximum: UInt64.max), threadID > 0,
              let frameRaw = unsigned(object["frame_index"], maximum: UInt64(UInt32.max)),
              let pc = unsigned(object["pc"], maximum: UInt64.max), pc > 0,
              let argumentOmitted = unsigned(object["argument_omitted"], maximum: UInt64(UInt32.max)),
              let argumentTruncated = object["argument_truncated"]?.boolValue,
              let localOmitted = unsigned(object["local_omitted"], maximum: UInt64(UInt32.max)),
              let localTruncated = object["local_truncated"]?.boolValue,
              let staticOmitted = unsigned(object["static_omitted"], maximum: UInt64(UInt32.max)),
              let staticTruncated = object["static_truncated"]?.boolValue,
              let totalOmitted = unsigned(object["omitted_count"], maximum: UInt64(UInt32.max)),
              let wasTruncated = object["truncated"]?.boolValue,
              let values = object["variables"]?.arrayValue,
              values.count <= Self.maximumVariableCount else {
            throw failure(.invalidValue, data)
        }
        let summedOmitted = argumentOmitted.addingReportingOverflow(localOmitted)
        let completeOmitted = summedOmitted.partialValue.addingReportingOverflow(staticOmitted)
        guard !summedOmitted.overflow, !completeOmitted.overflow,
              completeOmitted.partialValue == totalOmitted,
              argumentTruncated == (argumentOmitted > 0),
              localTruncated == (localOmitted > 0),
              staticTruncated == (staticOmitted > 0),
              wasTruncated == (totalOmitted > 0) else {
            throw failure(.invalidValue, data)
        }
        guard object["observed_state"]?.stringValue == "stopped" else {
            throw failure(.processNotStopped, data)
        }

        var decoded: [LLDBVariableSnapshotValue] = []
        decoded.reserveCapacity(values.count)
        var previousScopeOrder = -1
        var expectedOrdinal: UInt64 = 0
        var scopeCount = 0
        for value in values {
            guard case .object(let fields) = value, Set(fields.keys) == Self.variableKeys,
                  let scopeText = fields["scope"]?.stringValue,
                  let scope = LLDBVariableScope(rawValue: scopeText),
                  let ordinal = unsigned(fields["ordinal"], maximum: UInt64(UInt32.max)),
                  let name = boundedText(fields["name"], maximumBytes: Self.maximumNameBytes, allowEmpty: false),
                  let type = boundedText(fields["type"], maximumBytes: Self.maximumTypeBytes, allowEmpty: false),
                  let hasChildren = fields["has_children"]?.boolValue,
                  let childCount = unsigned(fields["child_count"], maximum: UInt64(Self.maximumChildCount)),
                  hasChildren == (childCount > 0) else {
                throw failure(.invalidValue, data)
            }
            if scope.order != previousScopeOrder {
                guard scope.order > previousScopeOrder else { throw failure(.invalidOrdering, data) }
                previousScopeOrder = scope.order
                expectedOrdinal = 0
                scopeCount = 0
            }
            guard ordinal == expectedOrdinal, scopeCount < Self.maximumVariablesPerScope else {
                throw failure(.invalidOrdering, data)
            }
            expectedOrdinal += 1
            scopeCount += 1
            let state: LLDBVariableDecodedValueState
            switch fields["state"]?.stringValue {
            case "available":
                let rendered = nullableText(fields["value"], maximumBytes: Self.maximumValueBytes, allowEmpty: true)
                let availableSummary = nullableText(fields["summary"], maximumBytes: Self.maximumSummaryBytes, allowEmpty: false)
                guard fields["diagnostic"] == .null, rendered.isValid, availableSummary.isValid,
                      rendered.value != nil || availableSummary.value != nil else {
                    throw failure(.invalidValue, data)
                }
                state = .available(value: rendered.value, summary: availableSummary.value)
            case "optimized_out":
                guard fields["value"] == .null, fields["summary"] == .null, fields["diagnostic"] == .null else {
                    throw failure(.invalidValue, data)
                }
                state = .optimizedOut
            case "unavailable":
                guard fields["value"] == .null, fields["summary"] == .null, fields["diagnostic"] == .null else {
                    throw failure(.invalidValue, data)
                }
                state = .unavailable
            case "failed":
                guard fields["value"] == .null, fields["summary"] == .null,
                      let diagnostic = boundedText(fields["diagnostic"], maximumBytes: Self.maximumDiagnosticBytes, allowEmpty: false) else {
                    throw failure(.invalidValue, data)
                }
                state = .failed(diagnostic: diagnostic)
            default:
                throw failure(.invalidValue, data)
            }
            decoded.append(LLDBVariableSnapshotValue(
                scope: scope, ordinal: UInt32(ordinal), name: name, typeName: type,
                valueState: state, hasChildren: hasChildren,
                childCount: UInt32(childCount)
            ))
        }
        return LLDBVariableSnapshot(
            token: token, observedProcessID: Int32(pidRaw), observedStopID: UInt32(stopRaw),
            threadID: threadID, frameIndex: UInt32(frameRaw), programCounter: pc,
            variables: decoded,
            argumentOmittedCount: UInt32(argumentOmitted),
            argumentWasTruncated: argumentTruncated,
            localOmittedCount: UInt32(localOmitted),
            localWasTruncated: localTruncated,
            staticOmittedCount: UInt32(staticOmitted),
            staticWasTruncated: staticTruncated,
            totalOmittedCount: UInt32(totalOmitted),
            wasTruncated: wasTruncated
        )
    }

    private func unsigned(_ value: Phase2ProductionJSONValue?, maximum: UInt64) -> UInt64? {
        guard case .number(let text) = value, !text.isEmpty,
              text == "0" || (text.first != "0" && text.utf8.allSatisfy { (0x30...0x39).contains($0) }),
              let result = UInt64(text), result <= maximum else { return nil }
        return result
    }

    private func boundedText(
        _ value: Phase2ProductionJSONValue?, maximumBytes: Int, allowEmpty: Bool
    ) -> String? {
        guard let text = value?.stringValue,
              (allowEmpty || !text.isEmpty), text.utf8.count <= maximumBytes,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            return nil
        }
        return text
    }

    private func nullableText(
        _ value: Phase2ProductionJSONValue?, maximumBytes: Int, allowEmpty: Bool
    ) -> (isValid: Bool, value: String?) {
        if value == .null { return (true, nil) }
        guard let text = boundedText(value, maximumBytes: maximumBytes, allowEmpty: allowEmpty) else {
            return (false, nil)
        }
        return (true, text)
    }

    private func hex(_ text: String?, byteCount: Int) -> Data? {
        guard let text, text.utf8.count == byteCount * 2,
              text.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteCount)
        var index = text.startIndex
        for _ in 0..<byteCount {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private func failure(_ code: LLDBVariableSnapshotDiagnosticCode, _ data: Data) -> LLDBVariableSnapshotFailure {
        LLDBVariableSnapshotFailure(
            code: code, evidenceByteCount: data.count,
            evidenceSHA256: Data(SHA256.hash(data: data.prefix(Self.maximumSnapshotBytes)))
        )
    }
}
