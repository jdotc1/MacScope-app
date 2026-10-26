import Foundation
import XCTest
@testable import MacScope

final class CompilerRTFunctionSignatureOracleTests: XCTestCase {
    func testGeneratedCorpusMatchesEverySourceFixtureUniquely() throws {
        let fixtures = try loadFixtures()
        let database = FunctionSignatureCorpus.database
        let matcher = FunctionSignatureMatcher(database: database)

        XCTAssertEqual(fixtures.count, 244)
        XCTAssertEqual(database.signatures.count, 244)
        XCTAssertEqual(matcher.validatedSignatureCount, 244)
        XCTAssertTrue(matcher.validationIssues.isEmpty, "\(matcher.validationIssues)")

        let signaturesByIdentity = Dictionary(
            uniqueKeysWithValues: database.signatures.map {
                (FunctionSignatureIdentity(name: $0.name, libraryName: $0.libraryName), $0)
            }
        )
        XCTAssertEqual(signaturesByIdentity.count, fixtures.count)

        for fixture in fixtures {
            let identity = fixture.identity
            guard let signature = signaturesByIdentity[identity] else {
                XCTFail("Missing generated signature for \(identity)")
                continue
            }

            let result = matcher.match(fixture.candidate)
            if case let .ambiguous(identities) = result {
                XCTFail("Source fixture \(identity) cross-matched: \(identities)")
            }
            XCTAssertEqual(result, .unique(identity), "Source fixture \(identity)")
            XCTAssertEqual(fixture.bytes.count, Int(signature.totalLength), "Source fixture \(identity)")
        }
    }

    func testWildcardMutationsPreserveIntendedIdentity() throws {
        let fixtures = try loadFixtures()
        let matcher = FunctionSignatureMatcher(database: FunctionSignatureCorpus.database)
        let signaturesByIdentity = signaturesByIdentity()
        var mutatedFixtureCount = 0

        for fixture in fixtures {
            guard let signature = signaturesByIdentity[fixture.identity] else {
                XCTFail("Missing generated signature for \(fixture.identity)")
                continue
            }
            var bytes = fixture.bytes
            var didMutate = false

            for index in signature.prefix.comparisonMask.indices
            where signature.prefix.comparisonMask[index] == 0 {
                bytes[index] ^= 0xA5
                didMutate = true
            }
            for run in signature.collisionTail.byteRuns {
                for index in run.comparisonMask.indices where run.comparisonMask[index] == 0 {
                    bytes[Int(run.offset) + index] ^= 0xA5
                    didMutate = true
                }
            }

            guard didMutate else { continue }
            mutatedFixtureCount += 1
            XCTAssertEqual(
                matcher.match(fixture.candidate(bytes: bytes)),
                .unique(fixture.identity),
                "Wildcard mutation changed identity for \(fixture.identity)"
            )
        }

        XCTAssertGreaterThan(mutatedFixtureCount, 0)
    }

    func testFixedPrefixChecksumTailReferenceAndLengthMutationsReject() throws {
        let fixtures = try loadFixtures()
        let matcher = FunctionSignatureMatcher(database: FunctionSignatureCorpus.database)
        let signaturesByIdentity = signaturesByIdentity()
        var checksumMutationCount = 0
        var tailMutationCount = 0
        var referenceMutationCount = 0

        for fixture in fixtures {
            guard let signature = signaturesByIdentity[fixture.identity] else {
                XCTFail("Missing generated signature for \(fixture.identity)")
                continue
            }

            guard let fixedPrefixIndex = signature.prefix.comparisonMask.firstIndex(of: 0xFF) else {
                XCTFail("Missing fixed prefix byte for \(fixture.identity)")
                continue
            }
            assertRejected(
                fixture,
                matcher: matcher,
                mutatingByteAt: fixedPrefixIndex,
                evidence: "fixed prefix"
            )

            if signature.checksum.byteCount > 0 {
                checksumMutationCount += 1
                assertRejected(
                    fixture,
                    matcher: matcher,
                    mutatingByteAt: Int(signature.checksum.offset),
                    evidence: "checksum"
                )
            }

            if let run = signature.collisionTail.byteRuns.first,
               let exactIndex = run.comparisonMask.firstIndex(of: 0xFF) {
                tailMutationCount += 1
                assertRejected(
                    fixture,
                    matcher: matcher,
                    mutatingByteAt: Int(run.offset) + exactIndex,
                    evidence: "collision tail"
                )
            }

            if let reference = signature.collisionTail.importedReferences.first {
                referenceMutationCount += 1
                var references = fixture.importedReferences
                references[reference.instructionOffset] = "__MacScope_mutated_reference__"
                XCTAssertEqual(
                    matcher.match(fixture.candidate(importedReferences: references)),
                    .noMatch,
                    "Reference mutation did not reject \(fixture.identity)"
                )
            }

            var shorterBytes = fixture.bytes
            shorterBytes.removeLast()
            XCTAssertEqual(
                matcher.match(fixture.candidate(bytes: shorterBytes)),
                .noMatch,
                "Shortened candidate did not reject \(fixture.identity)"
            )
            XCTAssertEqual(
                matcher.match(fixture.candidate(bytes: fixture.bytes + [0])),
                .noMatch,
                "Lengthened candidate did not reject \(fixture.identity)"
            )
        }

        XCTAssertGreaterThan(checksumMutationCount, 0)
        XCTAssertGreaterThan(tailMutationCount, 0)
        XCTAssertGreaterThan(referenceMutationCount, 0)
    }

    private func assertRejected(
        _ fixture: SourceFixture,
        matcher: FunctionSignatureMatcher,
        mutatingByteAt index: Int,
        evidence: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var bytes = fixture.bytes
        bytes[index] ^= 0x01
        XCTAssertEqual(
            matcher.match(fixture.candidate(bytes: bytes)),
            .noMatch,
            "\(evidence) mutation did not reject \(fixture.identity)",
            file: file,
            line: line
        )
    }

    private func signaturesByIdentity() -> [FunctionSignatureIdentity: FunctionSignature] {
        Dictionary(
            uniqueKeysWithValues: FunctionSignatureCorpus.database.signatures.map {
                (FunctionSignatureIdentity(name: $0.name, libraryName: $0.libraryName), $0)
            }
        )
    }

    private func loadFixtures() throws -> [SourceFixture] {
        let fixtureURL = try repositoryRoot().appendingPathComponent(
            "Scripts/function-signatures/compiler_rt_source_fixtures.json"
        )
        return try JSONDecoder().decode([SourceFixture].self, from: Data(contentsOf: fixtureURL))
    }

    private func repositoryRoot() throws -> URL {
        var directory = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while directory.path != "/" {
            let fixture = directory.appendingPathComponent(
                "Scripts/function-signatures/compiler_rt_source_fixtures.json"
            )
            if fileManager.fileExists(atPath: fixture.path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw FixtureError.repositoryRootNotFound
    }
}

private struct SourceFixture: Decodable {
    struct Reference: Decodable {
        let instructionOffset: UInt32
        let symbolName: String

        enum CodingKeys: String, CodingKey {
            case instructionOffset = "instruction_offset"
            case symbolName = "symbol_name"
        }
    }

    let bytes: [UInt8]
    let libraryName: String
    let name: String
    let references: [Reference]

    var identity: FunctionSignatureIdentity {
        FunctionSignatureIdentity(name: name, libraryName: libraryName)
    }

    var importedReferences: [UInt32: String] {
        Dictionary(uniqueKeysWithValues: references.map { ($0.instructionOffset, $0.symbolName) })
    }

    var candidate: FunctionSignatureCandidate {
        candidate(bytes: bytes)
    }

    func candidate(
        bytes: [UInt8]? = nil,
        importedReferences: [UInt32: String]? = nil
    ) -> FunctionSignatureCandidate {
        FunctionSignatureCandidate(
            architecture: .arm64,
            bytes: bytes ?? self.bytes,
            importedReferences: importedReferences ?? self.importedReferences
        )
    }

    enum CodingKeys: String, CodingKey {
        case bytes
        case libraryName = "library_name"
        case name
        case references
    }
}

private enum FixtureError: Error {
    case repositoryRootNotFound
}
