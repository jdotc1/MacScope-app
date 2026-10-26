import Foundation
import XCTest
@testable import MacScope

/// Reproducible scripted engineering proof, not autonomous model-quality evidence.
final class ReconstructionSourceRepairFixtureTests: XCTestCase {
    func testBrokenCandidateBuildsFailsBehaviorAndChildRepairPassesSavedOracle() throws {
        let fixture = try ReconstructionSourceRepairFixture()
        let first = try fixture.propose(files: files(ReconstructionSourceRepairFixture.broken), parentID: nil)
        let toolchain = try fixture.toolchain(first)
        XCTAssertEqual(toolchain.exitCode, 0)
        XCTAssertTrue(toolchain.output.lowercased().contains("clang"))
        let firstBuild = try fixture.build(first)
        XCTAssertEqual(firstBuild.exitCode, 0, firstBuild.output)
        let firstBehavior = try fixture.behavior(first)
        XCTAssertEqual(firstBehavior.exitCode, 1, firstBehavior.output)
        XCTAssertTrue(firstBehavior.output.contains("CASE:3:FAIL"))

        let repaired = try fixture.propose(files: files(ReconstructionSourceRepairFixture.repaired), parentID: first.id)
        XCTAssertEqual(repaired.parentID, first.id)
        XCTAssertNotEqual(repaired.treeSHA256, first.treeSHA256)
        XCTAssertEqual(repaired.files["oracle.c"], first.files["oracle.c"])
        let repairedBuild = try fixture.build(repaired)
        XCTAssertEqual(repairedBuild.exitCode, 0, repairedBuild.output)
        let repairedBehavior = try fixture.behavior(repaired)
        XCTAssertEqual(repairedBehavior.exitCode, 0, repairedBehavior.output)
        for testID in 0..<4 { XCTAssertTrue(repairedBehavior.output.contains("CASE:\(testID):PASS")) }
        XCTAssertTrue(repairedBehavior.cleanupObservedAbsent)
        XCTAssertEqual(repairedBuild.sourceTreeSHA256, repaired.treeSHA256)
        XCTAssertEqual(repairedBuild.objectiveSHA256, first.objectiveSHA256)
        XCTAssertEqual(repaired.objectiveSHA256, first.objectiveSHA256)
        XCTAssertEqual(repairedBuild.executableSHA256, firstBuild.executableSHA256)
        // Re-run the exact saved immutable revision, not a repaired in-memory string.
        let reproduced = try fixture.behavior(repaired)
        XCTAssertEqual(reproduced.exitCode, 0)
        XCTAssertEqual(reproduced.sourceTreeSHA256, repairedBehavior.sourceTreeSHA256)
        XCTAssertEqual(reproduced.executableSHA256, repairedBehavior.executableSHA256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory(for: first).appendingPathComponent("revision.json").path))
        XCTAssertThrowsError(try fixture.propose(files: files(ReconstructionSourceRepairFixture.repaired), parentID: repaired.id)) {
            XCTAssertEqual($0 as? ReconstructionSourceRepairFixture.Failure, .repairBudgetExhausted)
        }
    }

    func testUnsafePathsStaleParentsAndSourceTamperingCannotProduceReceipts() throws {
        let fixture = try ReconstructionSourceRepairFixture()
        XCTAssertThrowsError(try fixture.propose(files: ["../candidate.c": "x"], parentID: nil)) {
            XCTAssertEqual($0 as? ReconstructionSourceRepairFixture.Failure, .unsafePath)
        }
        let first = try fixture.propose(files: files(ReconstructionSourceRepairFixture.broken), parentID: nil)
        XCTAssertThrowsError(try fixture.propose(files: files(ReconstructionSourceRepairFixture.repaired), parentID: "stale")) {
            XCTAssertEqual($0 as? ReconstructionSourceRepairFixture.Failure, .staleParent)
        }
        try Data(ReconstructionSourceRepairFixture.repaired.utf8).write(to: fixture.directory(for: first).appendingPathComponent("candidate.c"))
        XCTAssertThrowsError(try fixture.build(first)) {
            XCTAssertEqual($0 as? ReconstructionSourceRepairFixture.Failure, .sourceTampered)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.directory(for: first).path).contains { $0.hasPrefix("build-") })
    }

    func testReplacementOracleCannotCreateFirstOrChildRevisionOrConsumeRepairBudget() throws {
        let fixture = try ReconstructionSourceRepairFixture()
        let initialContents = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        let objective = try Data(contentsOf: fixture.root.appendingPathComponent("objective.json"))
        var tampered = files(ReconstructionSourceRepairFixture.broken)
        tampered["oracle.c"] = "int main(void) { return 0; }\n"
        XCTAssertThrowsError(try fixture.propose(files: tampered, parentID: nil)) {
            XCTAssertEqual($0 as? ReconstructionSourceRepairFixture.Failure, .sourceTampered)
        }
        XCTAssertNil(fixture.current)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted(), initialContents)
        let first = try fixture.propose(files: files(ReconstructionSourceRepairFixture.broken), parentID: nil)
        let firstContents = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        let revisionBytes = try Data(contentsOf: fixture.directory(for: first).appendingPathComponent("revision.json"))
        XCTAssertThrowsError(try fixture.propose(files: tampered, parentID: first.id)) {
            XCTAssertEqual($0 as? ReconstructionSourceRepairFixture.Failure, .sourceTampered)
        }
        XCTAssertEqual(fixture.current, first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted(), firstContents)
        XCTAssertEqual(try Data(contentsOf: fixture.directory(for: first).appendingPathComponent("revision.json")), revisionBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("objective.json")), objective)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory(for: first).path).sorted(),
                       ["candidate.c", "oracle.c", "revision.json"])
        // Both rejected proposals leave the two-revision budget available.
        let child = try fixture.propose(files: files(ReconstructionSourceRepairFixture.repaired), parentID: first.id)
        XCTAssertEqual(child.files["oracle.c"], first.files["oracle.c"])
        XCTAssertEqual(child.objectiveSHA256, first.objectiveSHA256)
    }

    func testCancellationDuringOwnedCompilerWorkCleansGroupAndPublishesNoSuccessReceipt() throws {
        let fixture = try ReconstructionSourceRepairFixture()
        let revision = try fixture.propose(files: files(ReconstructionSourceRepairFixture.broken), parentID: nil)
        var polls = 0
        // clang is genuinely running, waiting for developer-controlled stdin;
        // cancellation is deterministic rather than racing a tiny compilation.
        XCTAssertThrowsError(try fixture.run(revision, stage: "cancelled-build",
            executable: ReconstructionSourceRepairFixture.compiler,
            arguments: ["-x", "c", "-fsyntax-only", "-"], cancel: {
                polls += 1
                return polls >= 4
            })) {
            XCTAssertEqual($0 as? ReconstructionSourceRepairFixture.Failure, .cancelled)
        }
        XCTAssertTrue(try XCTUnwrap(fixture.lastCleanupProof).observedProcessAbsent)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.directory(for: revision).path).contains { $0.hasPrefix("cancelled-build-") })
    }

    private func files(_ candidate: String) -> [String: String] {
        ["candidate.c": candidate, "oracle.c": ReconstructionSourceRepairFixture.oracle]
    }
}
