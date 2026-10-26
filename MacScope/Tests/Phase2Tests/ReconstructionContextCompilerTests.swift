import XCTest

@testable import MacScope

final class ReconstructionContextCompilerTests: XCTestCase {
    func testContextRejectsGapAuthorityBeyondWireCeiling() throws {
        let cut = try emptyContextCut()
        XCTAssertThrowsError(try ReconstructionContextCompiler().compile(
            cut: cut,
            query: emptyContextQuery(corpusManifestSHA256: cut.corpusManifestSHA256),
            allowedGapSubjects: (0..<65).map { "subject:\($0)" },
            allowedGapCategories: []
        )) { error in
            XCTAssertEqual(error as? ReconstructionContextCompilerError, .invalidGapAuthority)
        }
    }

    func testContextIsDeterministicAcrossGapAuthorityOrder() throws {
        let cut = try emptyContextCut()
        let query = try emptyContextQuery(corpusManifestSHA256: cut.corpusManifestSHA256)
        let compiler = ReconstructionContextCompiler()

        let first = try compiler.compile(
            cut: cut,
            query: query,
            allowedGapSubjects: ["image:beta", "image:alpha"],
            allowedGapCategories: ["symbols", "dependencies"]
        )
        let second = try compiler.compile(
            cut: cut,
            query: query,
            allowedGapSubjects: ["image:alpha", "image:beta"],
            allowedGapCategories: ["dependencies", "symbols"]
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.allowedGapSubjects, ["image:alpha", "image:beta"])
        XCTAssertEqual(first.allowedGapCategories, ["dependencies", "symbols"])
        XCTAssertEqual(first.evidenceIDs, [])
        XCTAssertFalse(first.canonicalBytes.isEmpty)
    }

    func testContextRejectsDuplicateOrEmptyGapAuthorityBeforeEncoding() throws {
        let cut = try emptyContextCut()
        let query = try emptyContextQuery(corpusManifestSHA256: cut.corpusManifestSHA256)
        let compiler = ReconstructionContextCompiler()

        XCTAssertThrowsError(try compiler.compile(
            cut: cut,
            query: query,
            allowedGapSubjects: ["image:alpha", "image:alpha"],
            allowedGapCategories: ["symbols"]
        )) { error in
            XCTAssertEqual(error as? ReconstructionContextCompilerError, .invalidGapAuthority)
        }
        XCTAssertThrowsError(try compiler.compile(
            cut: cut,
            query: query,
            allowedGapSubjects: [""],
            allowedGapCategories: ["symbols"]
        )) { error in
            XCTAssertEqual(error as? ReconstructionContextCompilerError, .invalidGapAuthority)
        }
    }

    func testContextPreservesRetrievalCorpusFence() throws {
        let cut = try emptyContextCut()
        let query = try emptyContextQuery(corpusManifestSHA256: contextDigest(99))

        XCTAssertThrowsError(try ReconstructionContextCompiler().compile(
            cut: cut,
            query: query,
            allowedGapSubjects: [],
            allowedGapCategories: []
        )) { error in
            XCTAssertEqual(
                error as? ReconstructionContextCompilerError,
                .retrieval(.queryCorpusMismatch)
            )
        }
    }

    func testContextRejectsEncodedArtifactBeyondItsExplicitBudget() throws {
        let cut = try emptyContextCut()
        let query = try emptyContextQuery(corpusManifestSHA256: cut.corpusManifestSHA256)

        XCTAssertThrowsError(try ReconstructionContextCompiler(maximumContextBytes: 1).compile(
            cut: cut,
            query: query,
            allowedGapSubjects: [],
            allowedGapCategories: []
        )) { error in
            XCTAssertEqual(error as? ReconstructionContextCompilerError, .contextBudgetExceeded)
        }
    }
}

private func emptyContextCut() throws -> ReconstructionEvidenceCut {
    let corpus = contextDigest(1)
    let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(
        corpusManifestSHA256: corpus,
        records: [],
        projectedClassificationsByEvidenceID: [:],
        relations: [],
        gaps: [],
        checkpointRevisionsByID: [:]
    )
    return try ReconstructionEvidenceCut(
        corpusManifestSHA256: corpus,
        records: [],
        relations: [],
        gaps: [],
        frontierSHA256: frontier,
        projectedClassificationsByEvidenceID: [:],
        checkpointRevisionsByID: [:]
    )
}

private func emptyContextQuery(
    corpusManifestSHA256: String
) throws -> ReconstructionRetrievalQuery {
    try ReconstructionRetrievalQuery(
        corpusManifestSHA256: corpusManifestSHA256,
        subject: nil,
        operationIDs: [.evidenceQuery],
        classifications: [.acceptedCurrent, .acceptedHistorical],
        cursor: nil,
        maximumRecords: 16,
        maximumEncodedBytes: 16_384
    )
}

private func contextDigest(_ value: Int) -> String {
    String(format: "%064x", value)
}
