import Foundation
import XCTest
@testable import MacScope

/// The A64 lifter oracle (`GoldenFixtures/a64-lifter-oracle/`) run against MacIR: each
/// fixture's word is decoded with `ARM64Decoder`, lifted with `MacIRBuilder`, evaluated
/// concretely (`MacIRConcreteEvaluator`, C semantics of the rendered IR) and compared with the
/// oracle's expected state plus every unchanged-state invariant.
///
/// Gate: every fixture listed in `baseline-pass.txt` must still PASS, so a lifting PR may turn
/// vectors green but never red. Record a new baseline with
/// `TEST_RUNNER_MACSCOPE_A64_ORACLE_RECORD_BASELINE=1`. The full report (per-family counts, the
/// smallest failing word per family) goes to `TEST_RUNNER_MACSCOPE_A64_ORACLE_REPORT=<dir>`, or
/// to the temporary directory when unset.
final class A64LifterOracleTests: XCTestCase {
    private static let baselineURL = A64OracleFile.fixtureDirectory.appendingPathComponent("baseline-pass.txt")

    /// The DP02 fixture is restricted to the 552 LD4/ST3 rows that were UNLIFTED in the
    /// #679 result. Their expected states are copied from the QEMU-checked source vectors.
    func testDP02LD4ST3PreviouslyUnliftedVectors() throws {
        let fixtureURL = A64OracleFile.fixtureDirectory.appendingPathComponent("dp02-ld4-st3-unlifted.json.gz")
        let compressed = try Data(contentsOf: fixtureURL)
        let file = try JSONDecoder().decode(A64OracleFile.self, from: A64OracleGzip.decompress(compressed))
        XCTAssertEqual(file.schema, "macscope-a64-lifter-oracle-1")
        XCTAssertEqual(file.vectors.count, 552)
        XCTAssertEqual(Set(file.vectors.map(\.id)).count, 552)
        XCTAssertEqual(file.vectors.filter { $0.family.hasSuffix(" / LD4") }.count, 276)
        XCTAssertEqual(file.vectors.filter { $0.family.hasSuffix(" / ST3") }.count, 276)

        let outcomes = file.vectors.map(A64OracleRunner.run)
        let failures = outcomes.filter { $0.status != .pass }
        XCTAssertTrue(failures.isEmpty, "LD4/ST3 oracle: \(outcomes.count - failures.count)/552 PASS; \(failures.count) non-PASS:\n"
            + failures.prefix(20).map { "\($0.vector.id) \($0.vector.asm) [\($0.decoded)]: \($0.status.rawValue) \($0.reason)" }.joined(separator: "\n"))
        print("DP02 LD4/ST3 oracle: \(outcomes.count - failures.count)/552 PASS")
    }

    func testOracleVectorsAgainstMacIR() throws {
        let file = try A64OracleFile.load()
        XCTAssertEqual(file.schema, "macscope-a64-lifter-oracle-1")
        XCTAssertEqual(file.vectors.count, 9_368)

        let outcomes = file.vectors.map(A64OracleRunner.run)
        let harnessFailures = outcomes.filter { $0.status == .harness }
        XCTAssertTrue(harnessFailures.isEmpty,
                      "harness could not read \(harnessFailures.count) fixtures, first: \(harnessFailures.first.map { "\($0.vector.id) \($0.reason)" } ?? "")")

        let environment = ProcessInfo.processInfo.environment
        let reportDirectory = environment["MACSCOPE_A64_ORACLE_REPORT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("a64-lifter-oracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let report = A64OracleReport(outcomes: outcomes, oracleRevision: file.repositoryRevision)
        try report.markdown().write(to: reportDirectory.appendingPathComponent("a64-oracle-report.md"), atomically: true, encoding: .utf8)
        try report.json().write(to: reportDirectory.appendingPathComponent("a64-oracle-results.json"))
        print("A64 oracle: \(report.summaryLine) → \(reportDirectory.path)")

        let passing = Set(outcomes.filter { $0.status == .pass }.map(\.vector.id))
        if environment["MACSCOPE_A64_ORACLE_RECORD_BASELINE"] == "1" {
            try (passing.sorted().joined(separator: "\n") + "\n").write(to: Self.baselineURL, atomically: true, encoding: .utf8)
            return
        }
        guard let baselineText = try? String(contentsOf: Self.baselineURL, encoding: .utf8) else {
            return XCTFail("no baseline-pass.txt; record one with TEST_RUNNER_MACSCOPE_A64_ORACLE_RECORD_BASELINE=1")
        }
        let baseline = Set(baselineText.split(whereSeparator: \.isNewline).map(String.init))
        let regressed = outcomes.filter { baseline.contains($0.vector.id) && $0.status != .pass }
        XCTAssertTrue(regressed.isEmpty, "\(regressed.count) baseline vectors no longer pass:\n"
            + regressed.prefix(20).map { "\($0.vector.id) \($0.vector.asm) [\($0.decoded)]: \($0.status.rawValue) \($0.reason)" }.joined(separator: "\n"))
        let newlyPassing = passing.subtracting(baseline)
        if !newlyPassing.isEmpty {
            print("A64 oracle: \(newlyPassing.count) vectors now pass beyond the baseline; re-record it in this PR.")
        }
    }

    /// The extended QEMU-checked forms retain their original expected architectural state.
    /// Unsupported/unlifted outcomes are reported, never promoted to numeric passes.
    func testExtendedFormsAgainstMacIR() throws {
        let file = try A64OracleFile.load(filename: "extended-forms.json.gz")
        XCTAssertEqual(file.schema, "macscope-a64-lifter-oracle-1")
        XCTAssertEqual(file.vectors.count, 1_656)
        XCTAssertEqual(Set(file.vectors.map(\.id)).count, 1_656)
        let outcomes = file.vectors.map(A64OracleRunner.run)
        let report = A64OracleReport(outcomes: outcomes, oracleRevision: file.repositoryRevision)
        let environment = ProcessInfo.processInfo.environment
        let reportDirectory = environment["MACSCOPE_A64_ORACLE_REPORT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("a64-lifter-oracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        try report.markdown().write(to: reportDirectory.appendingPathComponent("extended-forms-report.md"), atomically: true, encoding: .utf8)
        try report.json().write(to: reportDirectory.appendingPathComponent("extended-forms-results.json"))
        print("Extended forms oracle: \(report.summaryLine) → \(reportDirectory.path)")
        let failures = outcomes.filter { $0.status == .fail || $0.status == .harness }
        XCTAssertTrue(failures.isEmpty, "Extended forms oracle numeric or harness failures: \(report.summaryLine)\n"
            + failures.prefix(20).map { "\($0.vector.id) \($0.vector.asm) [\($0.decoded)]: \($0.status.rawValue) \($0.reason)" }.joined(separator: "\n"))
        // This previously recorded PASS floor may only be raised.
        let minimumPassingVectorCount = 1_415
        let passingCount = outcomes.filter { $0.status == .pass }.count
        XCTAssertGreaterThanOrEqual(passingCount, minimumPassingVectorCount,
                                   "Extended forms oracle coverage regressed: \(report.summaryLine)")
    }

    // MARK: Evaluator self-checks (hand-built IR, so the harness's own semantics are pinned)

    private func function(_ rows: [(String, String)]) -> MacIRFunction {
        MacIRBuilder().buildFunction(name: "selfcheck", instructions: rows.enumerated().map { index, row in
            InstructionRow(address: A64MachineState.defaultPC + UInt64(index * 4), bytes: "00 00 00 00",
                           mnemonic: row.0, operands: row.1, hasBreakpoint: false, comment: nil)
        })
    }

    private func run(_ rows: [(String, String)], _ seed: (inout A64MachineState) -> Void) throws -> A64MachineState {
        var state = try A64MachineState(seeding: try JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
        seed(&state)
        let lifted = function(rows)
        var evaluator = MacIRConcreteEvaluator(function: lifted, state: state)
        try evaluator.run(lifted.instructions)
        return evaluator.state
    }

    func testEvaluatorWRegisterArithmeticWrapsAndZeroExtends() throws {
        let final = try run([("add", "w0, w1, w2")]) { state in
            state.x[0] = 0xfeed_face_feed_face
            state.x[1] = 0xffff_ffff
            state.x[2] = 2
        }
        XCTAssertEqual(final.x[0], 1, "a W write keeps the low 32 bits and clears the top half")
        XCTAssertEqual(final.pc, A64MachineState.defaultPC + 4)
    }

    func testEvaluatorShiftRightFollowsTheRenderedCType() throws {
        // `lsr` renders as `>>` with no unsigned cast, so on a signed int64 it is arithmetic.
        var lifted = function([("lsr", "x0, x1, #4")])
        lifted.instructions[0].operation = .binary(destination: .register(name: "x0", version: 1), op: ">>", left: .register(name: "x1", version: 0), right: .immediate(4))
        var state = try A64MachineState(seeding: try JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
        state.x[1] = 0x8000_0000_0000_0000
        var signed = MacIRConcreteEvaluator(function: lifted, state: state)
        try signed.run(lifted.instructions)
        XCTAssertEqual(signed.state.x[0], 0xf800_0000_0000_0000)
        var unsigned = MacIRConcreteEvaluator(function: lifted, state: state)
        unsigned.alternateSignedness = true
        try unsigned.run(lifted.instructions)
        XCTAssertEqual(unsigned.state.x[0], 0x0800_0000_0000_0000)
    }

    func testEvaluatorLoadsTheRegisterWidthAndReportsUndefinedDivision() throws {
        let final = try run([("ldr", "w0, [x1]")]) { state in
            state.x[1] = 0x50_0000
            for (offset, byte) in [0x11, 0x22, 0x33, 0x44, 0x55].enumerated() { state.memory[0x50_0000 + UInt64(offset)] = UInt8(byte) }
        }
        XCTAssertEqual(final.x[0], 0x4433_2211)
        var legacy = function([("udiv", "x0, x1, x2")])
        legacy.instructions[0].operation = .binary(destination: .register(name: "x0", version: 1), op: "/", left: .immediate(7), right: .immediate(0))
        let state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
        var evaluator = MacIRConcreteEvaluator(function: legacy, state: state)
        XCTAssertThrowsError(try evaluator.run(legacy.instructions)) { error in
            XCTAssertEqual(error as? MacIRConcreteEvaluator.Failure, .undefined("division by zero"))
        }
    }

    func testSynthesizedCompareCoversEveryProducibleFlagState() {
        // A subtraction reaches exactly seven NZCV states: Z=1 forces 0110; signed overflow
        // pins C to the operands' signs (0011 or 1001); without overflow N and C are free.
        let produced = Set(A64OracleRunner.compareOperands.keys)
        XCTAssertEqual(produced, [0b0000, 0b0010, 0b0011, 0b0110, 0b1000, 0b1001, 0b1010])
    }
}
