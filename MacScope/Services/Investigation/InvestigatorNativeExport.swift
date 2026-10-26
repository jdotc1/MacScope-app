import CryptoKit
import Foundation

/// A selected function export for the Investigator v1 evidence shape. The wire data is
/// inert: the reverse map and publication authority never leave the app.
struct InvestigatorNativeExport: Sendable {
    struct ReverseEntry: Sendable, Equatable {
        let recordID: String
        let image: Phase2ReadImageIdentity
        let artifact: MachOSliceArtifactIdentity
        let functionID: UUID
        let functionRange: Range<UInt64>
        /// Each exported line has one exact static image-virtual instruction address.
        let lineAddresses: [UInt64]
    }

    let bytes: Data
    let captureID: UUID
    let documentID: UUID
    let workspaceID: UUID
    let precondition: Phase2ReadPrecondition
    let reverse: [String: ReverseEntry]

    func mayPublish(documentID: UUID, workspaceID: UUID, activeCaptureID: UUID,
                    currentState: Phase2ReadCurrentState) -> Bool {
        self.documentID == documentID && self.workspaceID == workspaceID
            && captureID == activeCaptureID
            && precondition.image == currentState.image
            && precondition.compared(to: currentState).isCurrent
    }
}

enum InvestigatorNativeExportError: Error, Equatable {
    case missingSelectedSlice, unsupportedArchitecture, missingAnalysisFingerprint
    case invalidFunction, ambiguousFunction, noEvidence, invalidTitle, invalidInstructionText, budgetExceeded
}

struct InvestigatorNativeExportInput: Sendable {
    let captureID: UUID
    let documentID: UUID
    let workspaceID: UUID
    let precondition: Phase2ReadPrecondition
    let binary: BinaryImage
    let analysis: ImageAnalysis
    let functionID: UUID
}

enum InvestigatorNativeExporter {
    private static let maximumTextBytes = 16_384
    private static let maximumWireBytes = 8 * 1_024 * 1_024

    static func export(_ input: InvestigatorNativeExportInput) throws -> InvestigatorNativeExport {
        guard let image = input.precondition.image,
              image.owner.binaryID == input.binary.id,
              image.owner.slot == input.binary.slot,
              image.owner.sliceIndex == input.binary.selectedSliceIndex,
              case .verified = input.binary.artifactIntegrityState,
              let artifact = input.binary.artifactIdentity,
              artifact.architectureVariant == MachOSliceArchitectureVariant.classify(
                rawCPUType: artifact.rawCPUType, rawCPUSubtype: artifact.rawCPUSubtype
              ) else { throw InvestigatorNativeExportError.missingSelectedSlice }
        guard let architecture = Architecture(artifact.architectureVariant) else {
            throw InvestigatorNativeExportError.unsupportedArchitecture
        }
        guard let analysisFingerprint = input.analysis.analysisInputFingerprint,
              let fingerprint = image.analysisFingerprintSHA256,
              fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              analysisFingerprint.overallSHA256 == fingerprint,
              analysisFingerprint.imageSlot == input.binary.slot,
              analysisFingerprint.binaryID == input.binary.id,
              analysisFingerprint.selectedSliceIndex == input.binary.selectedSliceIndex,
              analysisFingerprint.artifactIdentity == artifact else {
            throw InvestigatorNativeExportError.missingAnalysisFingerprint
        }
        guard image.analysisRevision <= 9_007_199_254_740_991,
              input.binary.slot.rawValue >= 0,
              (1...256).contains(input.binary.name.utf8.count),
              input.binary.selectedSliceIndex.map({ $0 >= 0 }) ?? true else {
            throw InvestigatorNativeExportError.missingSelectedSlice
        }
        let matches = input.analysis.functions.filter { $0.id == input.functionID }
        guard matches.count == 1, let function = matches.first else {
            throw matches.isEmpty ? InvestigatorNativeExportError.invalidFunction : .ambiguousFunction
        }
        guard function.startAddress < function.endAddress,
              !input.analysis.functions.contains(where: {
                  $0.id != function.id && $0.startAddress == function.startAddress
                      && $0.endAddress == function.endAddress
              }) else { throw InvestigatorNativeExportError.ambiguousFunction }
        guard (1...256).contains(function.name.utf8.count),
              !function.name.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw InvestigatorNativeExportError.invalidTitle
        }

        // A function record contains only observed static instruction rows. No pseudocode
        // or inferred behavior is promoted to evidence. Preserve whole lines under the v1 cap.
        let rows = input.analysis.instructions.filter {
            $0.address >= function.startAddress && $0.address < function.endAddress
        }.sorted { $0.address < $1.address }
        guard !rows.isEmpty else { throw InvestigatorNativeExportError.noEvidence }
        guard Set(rows.map(\.address)).count == rows.count else {
            throw InvestigatorNativeExportError.ambiguousFunction
        }
        var lines: [String] = []
        var addresses: [UInt64] = []
        var textBytes = 0
        var nextAddress = function.startAddress
        var hasGap = false
        for row in rows {
            guard !row.mnemonic.contains("\n"), !row.mnemonic.contains("\r"),
                  !row.operands.contains("\n"), !row.operands.contains("\r") else {
                throw InvestigatorNativeExportError.invalidInstructionText
            }
            let line = "0x\(String(row.address, radix: 16))  \(row.mnemonic) \(row.operands)"
            let additional = line.utf8.count + (lines.isEmpty ? 0 : 1)
            if textBytes + additional > maximumTextBytes { break }
            if row.address != nextAddress { hasGap = true }
            let end = row.address.addingReportingOverflow(row.byteWidth)
            guard !end.overflow, end.partialValue <= function.endAddress else {
                throw InvestigatorNativeExportError.invalidFunction
            }
            nextAddress = end.partialValue
            lines.append(line)
            addresses.append(row.address)
            textBytes += additional
        }
        guard !lines.isEmpty else { throw InvestigatorNativeExportError.budgetExceeded }
        let complete = lines.count == rows.count && !hasGap && nextAddress == function.endAddress
        let imageID = "i-\(input.binary.id.uuidString.lowercased())-\(input.binary.slot.rawValue)"
        let recordID = "f-\(input.binary.id.uuidString.lowercased())-\(function.id.uuidString.lowercased())"
        let text = lines.joined(separator: "\n")
        let record = Record(recordID: recordID, imageID: imageID,
                            address: "0x\(String(function.startAddress, radix: 16))",
                            title: function.name, text: text, contentSHA256: sha256(text),
                            sourceRevision: fingerprint, completeness: complete ? "complete" : "partial",
                            limitations: complete ? [] : ["Selected function instruction coverage is partial."])
        let snapshot = Snapshot(workspaceID: input.workspaceID.uuidString.lowercased(),
                                snapshotID: input.captureID.uuidString.lowercased(),
                                generation: Int64(image.analysisRevision),
                                images: [.init(imageID: imageID,
                                               contentSHA256: artifact.selectedSliceSHA256,
                                               architecture: architecture.rawValue,
                                               sliceID: "s-\(artifact.selectedSliceSHA256)-\(input.binary.selectedSliceIndex.map { String($0) } ?? "thin")",
                                               displayName: input.binary.name)],
                                records: [record],
                                coverage: .init(completeForScope: complete,
                                                omissions: complete ? [] : ["Function instruction listing is partial."]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(snapshot)
        guard bytes.count <= maximumWireBytes else { throw InvestigatorNativeExportError.budgetExceeded }
        return .init(bytes: bytes, captureID: input.captureID,
                     documentID: input.documentID, workspaceID: input.workspaceID,
                     precondition: input.precondition,
                     reverse: [recordID: .init(recordID: recordID, image: image, artifact: artifact,
                                               functionID: function.id,
                                               functionRange: function.startAddress..<function.endAddress,
                                               lineAddresses: addresses)])
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private enum Architecture: String {
        case arm64, arm64e, x86_64
        init?(_ variant: MachOSliceArchitectureVariant) {
            self.init(rawValue: variant.rawValue)
        }
    }

    private struct Snapshot: Encodable {
        let schemaVersion = 1
        let workspaceID: String
        let snapshotID: String
        let generation: Int64
        let images: [Image]
        let records: [Record]
        let relations: [String] = []
        let coverage: Coverage
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", workspaceID = "workspace_id"
            case snapshotID = "snapshot_id", generation, images, records, relations, coverage
        }
    }

    private struct Image: Encodable {
        let imageID: String
        let contentSHA256: String
        let architecture: String
        let sliceID: String
        let displayName: String
        enum CodingKeys: String, CodingKey {
            case imageID = "image_id", contentSHA256 = "content_sha256"
            case architecture, sliceID = "slice_id", displayName = "display_name"
        }
    }

    private struct Record: Encodable {
        let recordID: String
        let imageID: String
        let kind = "function"
        let address: String?
        let title: String
        let text: String
        let contentSHA256: String
        let provenance = "static"
        let sourceTool = "macscope"
        let sourceRevision: String
        let completeness: String
        let scenarioID: String? = nil
        let limitations: [String]
        enum CodingKeys: String, CodingKey {
            case recordID = "record_id", imageID = "image_id", kind, address, title, text
            case contentSHA256 = "content_sha256", provenance, sourceTool = "source_tool"
            case sourceRevision = "source_revision", completeness, scenarioID = "scenario_id", limitations
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(recordID, forKey: .recordID)
            try c.encode(imageID, forKey: .imageID)
            try c.encode(kind, forKey: .kind)
            try c.encode(address, forKey: .address)
            try c.encode(title, forKey: .title)
            try c.encode(text, forKey: .text)
            try c.encode(contentSHA256, forKey: .contentSHA256)
            try c.encode(provenance, forKey: .provenance)
            try c.encode(sourceTool, forKey: .sourceTool)
            try c.encode(sourceRevision, forKey: .sourceRevision)
            try c.encode(completeness, forKey: .completeness)
            try c.encode(scenarioID, forKey: .scenarioID)
            try c.encode(limitations, forKey: .limitations)
        }
    }

    private struct Coverage: Encodable {
        let declaredRecords = 1
        let scope = "selected_subsystem"
        let completeForScope: Bool
        let omissions: [String]
        enum CodingKeys: String, CodingKey {
            case declaredRecords = "declared_records", scope
            case completeForScope = "complete_for_scope", omissions
        }
    }
}
