import Foundation
import XCTest

@testable import MacScope

final class ReconstructionEvidenceIntegrityTests: XCTestCase {
    func testSchemaV4FunctionFocusParticipatesInDurableMetadataBounds() throws {
        let digest = String(repeating: "a", count: 64)
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: UUID()),
            contentIdentity: try ReconstructionContentIdentity(algorithm: .sha256,
                digest: digest, byteCount: 1))
        func focus(symbolLength: Int) throws -> ReconstructionSubjectCoordinate {
            .function(try ReconstructionFunctionCoordinate(artifact: artifact,
                image: ReconstructionImageBinding(binaryID: UUID(), imageSlot: .primary,
                    selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
                analysisFingerprintSHA256: digest, startAddress: 0x1000,
                endAddressExclusive: 0x1010, boundarySchemaVersion: 1,
                functionUUIDHint: nil, symbolHint: String(repeating: "f", count: symbolLength)))
        }
        func validate(_ focus: ReconstructionSubjectCoordinate?) throws {
            let job = try ReconstructionJobRecord(jobID: UUID(), reconstructionProjectID: UUID(),
                objective: "Recover", objectiveSHA256: digest,
                creationCorpusManifestSHA256: digest, state: .created,
                currentCheckpointID: nil, terminalReason: nil,
                budget: ReconstructionJobBudget(maxRounds: 1, maxTasks: 1,
                    maxEvidenceRecords: 1, maxEncodedBytes: 1024), focus: focus)
            try ReconstructionEvidenceIntegrity.validateDurableBounds(projects: [],
                corpusManifests: [], evidence: [], relations: [], gaps: [], jobs: [job],
                tasks: [], checkpoints: [], toolReceipts: [], modelReceipts: [])
        }
        XCTAssertNoThrow(try validate(nil))
        let limit = ReconstructionEvidenceIntegrity.DurableLimits.maximumStringUTF8Bytes
        XCTAssertNoThrow(try validate(focus(symbolLength: limit)))
        XCTAssertThrowsError(try validate(focus(symbolLength: limit + 1))) { error in
            XCTAssertEqual(error as? ReconstructionEvidenceIntegrity.DurableAdmissionFailure,
                .stringUTF8Limit(field: "function symbol hint"))
        }
    }

}
