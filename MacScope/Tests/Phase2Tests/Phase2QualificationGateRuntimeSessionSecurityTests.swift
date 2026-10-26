import Foundation
import XCTest

@testable import MacScope

@MainActor
final class Phase2QualificationGateRuntimeSessionSecurityTests: XCTestCase {
    func testFinalAuthoritySandwichesFullArtifactRehashWithEnvironmentChecks() {
        var calls: [String] = []

        let accepted = Phase2QualificationGateFinalAuthorityClosure.validate(
            environmentIsCurrent: {
                calls.append("environment")
                return true
            },
            artifactIsCryptographicallyCurrent: {
                calls.append("artifact")
                return true
            }
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(calls, ["environment", "artifact", "environment"])
    }

    func testFinalAuthorityRejectsDriftBeforeRehashWithoutReadingArtifact() {
        var artifactWasRead = false

        let accepted = Phase2QualificationGateFinalAuthorityClosure.validate(
            environmentIsCurrent: { false },
            artifactIsCryptographicallyCurrent: {
                artifactWasRead = true
                return true
            }
        )

        XCTAssertFalse(accepted)
        XCTAssertFalse(artifactWasRead)
    }

    func testFinalAuthorityRejectsDriftAfterRehash() {
        var environmentChecks = [true, false].makeIterator()
        var calls: [String] = []

        let accepted = Phase2QualificationGateFinalAuthorityClosure.validate(
            environmentIsCurrent: {
                calls.append("environment")
                return environmentChecks.next() ?? false
            },
            artifactIsCryptographicallyCurrent: {
                calls.append("artifact")
                return true
            }
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(calls, ["environment", "artifact", "environment"])
    }

    func testFinalAuthorityStillChecksEnvironmentAfterArtifactFailure() {
        var environmentCheckCount = 0

        let accepted = Phase2QualificationGateFinalAuthorityClosure.validate(
            environmentIsCurrent: {
                environmentCheckCount += 1
                return true
            },
            artifactIsCryptographicallyCurrent: { false }
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(environmentCheckCount, 2)
    }

    func testComposerGuardsFinalAuthorityBeforeReportCompositionAndWrite() throws {
        let source = try String(
            contentsOf: TestSourceRoot.fileURL(#filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Services/Phase2/QualificationGate/Phase2QualificationGateComposer.swift"
                ),
            encoding: .utf8
        )
        let authority = try XCTUnwrap(
            source.range(of: "guard session.validateArtifactCryptographically() else")
        )
        let composition = try XCTUnwrap(source.range(of: "let report = try composeStandardReport("))
        let write = try XCTUnwrap(
            source.range(of: "Phase2QualificationGateArtifactWriter.write(")
        )

        XCTAssertLessThan(authority.lowerBound, composition.lowerBound)
        XCTAssertLessThan(composition.lowerBound, write.lowerBound)
    }
}
