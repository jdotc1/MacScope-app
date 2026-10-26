import Foundation
import XCTest
@testable import MacScope

/// External WS-14 ABI oracle. The Python driver compiles and executes a real
/// arm64 fixture, reads compiler DWARF with dwarfdump, and anchors entry-state
/// observations to otool output. The app's own DWARF reader is deliberately not
/// part of this ground-truth path.
final class ParameterIdentityABIOracleTests: XCTestCase {
    func testActiveCompilerOracleMatchesStrictBinder() throws {
        let result = try runOracle(["--json"])
        XCTAssertEqual(result.status, 0, result.stderr)

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        )
        XCTAssertEqual(root["schema"] as? String, "parameter-binding-oracle-v1")

        let proofs = try XCTUnwrap(root["proofs"] as? [String: Any])
        for proof in ["runtime_sentinels", "dwarf_source_order", "otool_entry_capture"] {
            XCTAssertEqual(proofs[proof] as? Bool, true, "missing external proof: \(proof)")
        }

        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let requiredCases = Set([
            "mixed_scalars",
            "bank_collision",
            "ninth_integer",
            "packed_chars",
            "shared_nsaa",
            "independent_bank_spill",
        ])
        XCTAssertEqual(Set(cases.compactMap { $0["name"] as? String }), requiredCases)

        for fixtureCase in cases {
            let name = try XCTUnwrap(fixtureCase["name"] as? String)
            let parameterTypes = try XCTUnwrap(fixtureCase["parameter_types"] as? [String])
            let externalLocations = try XCTUnwrap(fixtureCase["locations"] as? [String])
            let binderLocations = DarwinARM64ParameterBinder
                .bind(parameterTypes: parameterTypes)
                .map(renderLocation)
            XCTAssertEqual(
                binderLocations,
                externalLocations,
                "strict binder diverged from the active Darwin compiler for \(name)"
            )
        }

        let returns = try XCTUnwrap(root["returns"] as? [String: String])
        XCTAssertEqual(returns, [
            "int32": "w0",
            "int64": "x0",
            "float": "s0",
            "double": "d0",
        ])

        let negative = try XCTUnwrap(root["x8_negative_control"] as? [String: Any])
        XCTAssertEqual(negative["source_formal_count"] as? Int, 1)
        XCTAssertEqual(negative["source_formal_location"] as? String, "x0")
        XCTAssertEqual(negative["hidden_result_channel"] as? String, "x8")
    }

    func testStructuralCandidateAuditPassesWithoutClaimingExternalComparison() throws {
        let payload: [String: Any] = [
            "schema": "parameter-binding-audit-v1",
            "validation_scope": "structural-candidate",
            "combined_oracle_comparison": false,
            "function": "mixed_scalars",
            "address": "0x1000",
            "declaration_mode": "ordinary",
            "dangling_body_uses": [],
            "records": [[
                "function": "mixed_scalars",
                "declaration_mode": "ordinary",
                "row_ordinal": 0,
                "binding": "gpr:0",
                "source_position": 0,
                "location": "w0",
                "evidence": "authoritative_debug",
                "name": "integer_value",
                "type": "int",
                "body_uses": [["address": "0x1000", "occurrence": 0]],
            ]],
        ]
        let audit = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-parameter-audit-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: audit, options: .atomic)
        defer { try? FileManager.default.removeItem(at: audit) }

        let result = try runOracle(["--validate-audit", audit.path, "--json"])
        XCTAssertEqual(result.status, 0, result.stderr)

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        )
        XCTAssertEqual(root["schema"] as? String, "parameter-binding-audit-validation-v1")
        XCTAssertEqual(root["validation_scope"] as? String, "structural-candidate")
        XCTAssertEqual(root["combined_oracle_comparison"] as? Bool, false)
        XCTAssertEqual(root["valid"] as? Bool, true)
        XCTAssertEqual(root["record_count"] as? Int, 1)
    }

    func testOracleSelfTestExercisesFalsePassRejections() throws {
        let result = try runOracle(["--self-test"])
        XCTAssertEqual(result.status, 0, result.stderr)
        let output = String(decoding: result.stdout, as: UTF8.self)
        for gate in [
            "duplicate binding",
            "dangling body use",
            "compressed sparse input",
            "embedded comparison fields",
            "source order",
            "combined comparison disabled",
        ] {
            XCTAssertTrue(output.contains(gate), "self-test did not exercise \(gate)")
        }
    }

    func testCallClobberComparatorSelfTestExercisesWS14Guards() throws {
        let result = try runPythonScript(
            "Scripts/decompiler-oracles/call_clobber_oracle.py",
            arguments: ["--self-test"]
        )
        XCTAssertEqual(result.status, 0, result.stderr)

        let output = String(decoding: result.stdout, as: UTF8.self)
        XCTAssertTrue(output.contains("all gate negative controls"))
        XCTAssertTrue(output.contains("schema/producer/artifact guards"))
    }

    private var repositoryRoot: URL {
        TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent() // CoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MacScope
            .deletingLastPathComponent() // repository root
    }

    private func runOracle(_ arguments: [String]) throws -> ProcessResult {
        try runPythonScript(
            "Scripts/decompiler-oracles/parameter_binding_oracle.py",
            arguments: arguments
        )
    }

    private func runPythonScript(
        _ repositoryRelativePath: String,
        arguments: [String]
    ) throws -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            repositoryRoot.appendingPathComponent(repositoryRelativePath).path,
        ] + arguments
        process.currentDirectoryURL = repositoryRoot
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let stdoutDrain = CoreTestPipeDrain(stdout)
        let stderrDrain = CoreTestPipeDrain(stderr)
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: stdoutDrain.data(),
            stderr: stderrDrain.text()
        )
    }

    private func renderLocation(_ location: MacIRABIParameterLocation) -> String {
        switch location {
        case let .gpr(index, carrierWidth):
            "\(carrierWidth == 32 ? "w" : "x")\(index)"
        case let .simd(index, scalarWidth):
            "\(scalarWidth == 32 ? "s" : "d")\(index)"
        case let .entryStack(byteOffset, size, alignment):
            "entry_sp+\(byteOffset)[\(size)/\(alignment)]"
        case let .unbound(reason):
            "unbound:\(reason)"
        }
    }
}

private struct ProcessResult {
    var status: Int32
    var stdout: Data
    var stderr: String
}
