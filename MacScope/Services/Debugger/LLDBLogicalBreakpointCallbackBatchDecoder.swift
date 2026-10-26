import Foundation

enum LLDBLogicalBreakpointCallbackBatchDecoderError: Error, Equatable, Sendable {
    case capacityExceeded
    case invalidJSON
    case noncanonicalJSON
    case invalidSchema
    case authorityMismatch
}

/// Strict decoder for one already-correlated `drain_logs` record array. Transport framing and the
/// token are proved by ``LLDBLogicalBreakpointResponseDecoder``; this seam turns the opaque
/// canonical array into bounded domain records against the retained generation's exact wire ledger.
struct LLDBLogicalBreakpointCallbackBatchDecoder: Sendable {
    static let maximumCanonicalRecordsBytes = 64 * 1_024
    static let maximumWireBindingCount = 4_096

    let expectedSessionEpoch: DebuggerSessionEpoch
    let expectedAdapterGeneration: UInt64
    let expectedProcessID: Int32
    let bindingIDsByWireID: [String: DebuggerTransientBreakpointBindingID]

    func decode(
        canonicalRecords: Data,
        afterSequence: UInt64,
        nextSequence: UInt64,
        isFinal: Bool
    ) throws -> DebuggerBreakpointCallbackBatch {
        guard canonicalRecords.count <= Self.maximumCanonicalRecordsBytes,
              bindingIDsByWireID.count <= Self.maximumWireBindingCount else {
            throw LLDBLogicalBreakpointCallbackBatchDecoderError.capacityExceeded
        }
        guard expectedAdapterGeneration > 0,
              expectedProcessID > 0,
              bindingIDsByWireID.allSatisfy({ Self.isCanonicalWireID($0.key) }) else {
            throw LLDBLogicalBreakpointCallbackBatchDecoderError.authorityMismatch
        }

        let value: Phase2ProductionJSONValue
        do {
            value = try Phase2StrictJSONParser().parse(
                canonicalRecords,
                limits: Phase2StrictJSONLimits(
                    maximumBytes: Self.maximumCanonicalRecordsBytes,
                    maximumDepth: 6,
                    maximumTokens: 32_768,
                    maximumMembersAndElements: 24_576
                )
            )
        } catch {
            throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidJSON
        }
        guard value.canonicalJSONBytes() == canonicalRecords else {
            throw LLDBLogicalBreakpointCallbackBatchDecoderError.noncanonicalJSON
        }
        guard let values = value.arrayValue,
              values.count <= DebuggerBreakpointCallbackBatch.maximumRecordCount else {
            throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidSchema
        }

        var expectedSequence = afterSequence
        var records: [DebuggerBreakpointCallbackRecord] = []
        records.reserveCapacity(values.count)
        for value in values {
            let next = expectedSequence.addingReportingOverflow(1)
            guard !next.overflow else {
                throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidSchema
            }
            let record = try decodeRecord(value, expectedSequence: next.partialValue)
            records.append(record)
            expectedSequence = record.sequence
        }
        guard expectedSequence == nextSequence,
              let batch = DebuggerBreakpointCallbackBatch(
                sessionEpoch: expectedSessionEpoch,
                adapterGeneration: expectedAdapterGeneration,
                processID: expectedProcessID,
                afterSequence: afterSequence,
                nextSequence: nextSequence,
                isFinal: isFinal,
                records: records
              ) else {
            throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidSchema
        }
        return batch
    }

    private func decodeRecord(
        _ value: Phase2ProductionJSONValue,
        expectedSequence: UInt64
    ) throws -> DebuggerBreakpointCallbackRecord {
        guard let object = value.objectValue,
              let outcomeText = object["outcome"]?.stringValue else {
            throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidSchema
        }

        let commonKeys: Set<String> = [
            "adapter_generation", "backend_breakpoint_id", "backend_location_id", "binding_id",
            "hit_count", "issuance_digest", "logical_id", "outcome", "process_id", "sequence",
            "session_epoch", "specification_revision",
        ]
        let outcome: DebuggerBreakpointCallbackOutcome
        let outputs: [DebuggerBreakpointCallbackActionOutput]
        let dropCount: UInt64?
        switch outcomeText {
        case "ignored":
            guard Set(object.keys) == commonKeys else {
                throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidSchema
            }
            outcome = .ignored
            outputs = []
            dropCount = nil
        case "condition_false":
            guard Set(object.keys) == commonKeys else {
                throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidSchema
            }
            outcome = .conditionFalse
            outputs = []
            dropCount = nil
        case "stop", "continue_after_successful_actions":
            guard Set(object.keys) == commonKeys.union(["outputs"]),
                  let outputValues = object["outputs"]?.arrayValue,
                  outputValues.count <= DebuggerBreakpointCallbackRecord.maximumActionOutputCount
            else {
                throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidSchema
            }
            outcome = outcomeText == "stop" ? .stopped : .continued
            outputs = try outputValues.map(decodeOutput)
            dropCount = nil
        case "fault_stop":
            guard Set(object.keys) == commonKeys.union(["code", "drop_count"]),
                  let code = object["code"]?.stringValue,
                  let reportedDropCount = unsigned(object["drop_count"], maximum: UInt64.max)
            else {
                throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidSchema
            }
            outcome = .fault(code: code)
            outputs = []
            dropCount = reportedDropCount
        default:
            throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidSchema
        }

        guard unsigned(object["adapter_generation"], maximum: UInt64.max)
                == expectedAdapterGeneration,
              signedPositiveInt32(object["process_id"]) == expectedProcessID,
              unsigned(object["sequence"], maximum: UInt64.max) == expectedSequence,
              let wireID = object["binding_id"]?.stringValue,
              Self.isCanonicalWireID(wireID),
              let bindingID = bindingIDsByWireID[wireID],
              let sessionText = object["session_epoch"]?.stringValue,
              canonicalUUID(sessionText) == expectedSessionEpoch.rawValue,
              let logicalText = object["logical_id"]?.stringValue,
              canonicalUUID(logicalText) == bindingID.logicalID.rawValue,
              let specificationRevision = unsigned(
                object["specification_revision"],
                maximum: DebuggerLogicalBreakpointRevision.maximum
              ),
              specificationRevision == bindingID.siteID.specificationRevision.rawValue,
              let issuanceBytes = lowercaseHexData(
                object["issuance_digest"]?.stringValue,
                byteCount: 32
              ),
              let issuanceDigest = DebuggerBreakpointDigest(issuanceBytes),
              let backendBreakpointID = positive(object["backend_breakpoint_id"]),
              let backendLocationID = positive(object["backend_location_id"]),
              let hitCount = unsigned(object["hit_count"], maximum: UInt64.max),
              let record = DebuggerBreakpointCallbackRecord(
                sessionEpoch: expectedSessionEpoch,
                adapterGeneration: expectedAdapterGeneration,
                processID: expectedProcessID,
                sequence: expectedSequence,
                logicalID: bindingID.logicalID,
                specificationRevision: bindingID.siteID.specificationRevision,
                bindingID: bindingID,
                backendBreakpointID: backendBreakpointID,
                backendLocationID: backendLocationID,
                issuanceDigest: issuanceDigest,
                observedLogicalHitCount: hitCount,
                outcome: outcome,
                actionOutputs: outputs,
                reportedDropCount: dropCount
              ) else {
            throw LLDBLogicalBreakpointCallbackBatchDecoderError.authorityMismatch
        }
        return record
    }

    private func decodeOutput(
        _ value: Phase2ProductionJSONValue
    ) throws -> DebuggerBreakpointCallbackActionOutput {
        guard let object = value.objectValue,
              let kind = object["kind"]?.stringValue else {
            throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidSchema
        }
        switch kind {
        case "log":
            guard Set(object.keys) == ["kind", "text"],
                  let text = object["text"]?.stringValue,
                  let output = DebuggerBreakpointCallbackActionOutput.makeLog(text: text) else {
                throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidSchema
            }
            return output
        case "evaluate_target_expression":
            guard Set(object.keys) == ["kind", "label", "value"],
                  let label = object["label"]?.stringValue,
                  let value = object["value"]?.stringValue,
                  let output = DebuggerBreakpointCallbackActionOutput.makeTargetExpression(
                    label: label,
                    value: value
                  ) else {
                throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidSchema
            }
            return output
        default:
            throw LLDBLogicalBreakpointCallbackBatchDecoderError.invalidSchema
        }
    }

    private func positive(_ value: Phase2ProductionJSONValue?) -> UInt64? {
        guard let result = unsigned(value, maximum: UInt64.max), result > 0 else { return nil }
        return result
    }

    private func signedPositiveInt32(_ value: Phase2ProductionJSONValue?) -> Int32? {
        guard let raw = unsigned(value, maximum: UInt64(Int32.max)), raw > 0 else { return nil }
        return Int32(raw)
    }

    private func unsigned(
        _ value: Phase2ProductionJSONValue?,
        maximum: UInt64
    ) -> UInt64? {
        guard case .number(let text) = value,
              !text.isEmpty,
              text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              (text == "0" || text.first != "0"),
              let result = UInt64(text),
              result <= maximum else {
            return nil
        }
        return result
    }

    private func canonicalUUID(_ text: String) -> UUID? {
        guard let uuid = UUID(uuidString: text), uuid.uuidString.lowercased() == text else {
            return nil
        }
        return uuid
    }

    private func lowercaseHexData(_ text: String?, byteCount: Int) -> Data? {
        guard let text else { return nil }
        let bytes = Array(text.utf8)
        guard bytes.count == byteCount * 2 else { return nil }
        var result = Data(capacity: byteCount)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else {
                return nil
            }
            result.append((high << 4) | low)
        }
        return result
    }

    private func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private static func isCanonicalWireID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 67, bytes[0...2].elementsEqual(Array("b1.".utf8)) else {
            return false
        }
        return bytes.dropFirst(3).allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }
}
