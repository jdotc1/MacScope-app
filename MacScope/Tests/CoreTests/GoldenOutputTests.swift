import XCTest
@testable import MacScope

/// Tests for the normalized golden-output harness (`GoldenOutput`) and the analysis
/// performance benchmark seam (`AnalysisBenchmark`).
///
/// The determinism tests analyze a real system binary (`/bin/ls`) through the EXISTING
/// pipeline twice and assert the emitted JSON is byte-identical, proving every
/// nondeterministic field (UUIDs, paths, the embedded image UUID) is normalized away.
/// No binary fixtures are committed — the binary is read in place and the test skips
/// when it is unreadable.
@MainActor
final class GoldenOutputTests: XCTestCase {
    /// A small, always-present in-scope system binary used as the golden input. arm64
    /// on Apple Silicon. If it is ever unreadable the dependent tests `XCTSkip`.
    private let systemBinaryURL = URL(fileURLWithPath: "/bin/ls")

    private func analyzeSystemBinary() throws -> WorkspaceSnapshot {
        guard FileManager.default.isReadableFile(atPath: systemBinaryURL.path) else {
            throw XCTSkip("/bin/ls is not readable on this host")
        }
        return try AnalysisEngine().analyze(url: systemBinaryURL)
    }

    // MARK: - Determinism

    func testGoldenJSONIsByteIdenticalAcrossTwoAnalyses() throws {
        // Two INDEPENDENT analyses of the same binary, each producing its own snapshot
        // with fresh runtime UUIDs, must serialize to the same bytes.
        let firstSnapshot = try analyzeSystemBinary()
        let secondSnapshot = try analyzeSystemBinary()

        let firstJSON = try GoldenOutput(snapshot: firstSnapshot).jsonData()
        let secondJSON = try GoldenOutput(snapshot: secondSnapshot).jsonData()

        XCTAssertEqual(firstJSON, secondJSON, "GoldenOutput JSON must be byte-identical across two analyses of the same binary")
    }

    func testGoldenModelIsEqualAcrossTwoAnalyses() throws {
        // The structured model (not just its bytes) must compare equal too — guards
        // against an encoding-only coincidence masking a model-level nondeterminism.
        let first = GoldenOutput(snapshot: try analyzeSystemBinary())
        let second = GoldenOutput(snapshot: try analyzeSystemBinary())
        XCTAssertEqual(first, second)
    }

    func testGoldenJSONIsStableAcrossRepeatedSerialization() throws {
        // The SAME snapshot serialized twice must also be byte-identical (the encoder
        // options are deterministic; this catches accidental set/dict ordering leaks).
        let snapshot = try analyzeSystemBinary()
        let golden = GoldenOutput(snapshot: snapshot)
        XCTAssertEqual(try golden.jsonData(), try golden.jsonData())
    }

    // MARK: - Shape

    func testGoldenOutputHasExpectedNonEmptyShapeForSystemBinary() throws {
        let golden = GoldenOutput(snapshot: try analyzeSystemBinary())

        // Metadata: a real binary has a name, an in-scope architecture, and a path that
        // was stripped to its basename (no directory separators leaked).
        XCTAssertEqual(golden.binary.name, "ls")
        XCTAssertEqual(golden.binary.pathBasename, "ls")
        XCTAssertFalse(golden.binary.pathBasename.contains("/"), "path must be stripped to a basename")
        // The architecture display name may carry slice info (e.g.
        // "arm64 (universal slice 2/2 @ 0x10000)"), so match on an in-scope prefix.
        XCTAssertTrue(["arm64", "x86_64"].contains { golden.binary.architecture.hasPrefix($0) },
                      "architecture must be in-scope (arm64/x86_64), got \(golden.binary.architecture)")

        // Core tables a normal executable always populates.
        XCTAssertFalse(golden.sections.isEmpty, "expected non-empty sections")
        XCTAssertFalse(golden.symbols.isEmpty, "expected non-empty symbols")
        XCTAssertFalse(golden.imports.isEmpty, "expected non-empty imports")
        XCTAssertFalse(golden.instructions.isEmpty, "expected decoded instructions")
        XCTAssertFalse(golden.procedures.isEmpty, "expected recovered procedures")

        // An executable section must be present and addresses render as 0x-prefixed hex.
        XCTAssertTrue(golden.sections.contains { $0.isExecutable }, "expected an executable section")
        XCTAssertTrue(golden.instructions.allSatisfy { $0.address.hasPrefix("0x") })
        XCTAssertTrue(golden.procedures.allSatisfy { $0.startAddress.hasPrefix("0x") })
    }

    func testGoldenCollectionsAreSortedDeterministically() throws {
        let golden = GoldenOutput(snapshot: try analyzeSystemBinary())

        // Instructions ascending by address.
        XCTAssertEqual(golden.instructions.map(\.address), golden.instructions.map(\.address).sorted())
        // Sections by (address, name).
        let sectionKeys = golden.sections.map { [$0.address, $0.name] }
        XCTAssertEqual(sectionKeys, sectionKeys.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) })
        // CFG edges by (from, to, kind).
        let edgeKeys = golden.controlFlowEdges.map { [$0.from, $0.to, $0.kind] }
        XCTAssertEqual(edgeKeys, edgeKeys.sorted { ($0[0], $0[1], $0[2]) < ($1[0], $1[1], $1[2]) })
        // Cross-references by (from, to, kind).
        let xrefKeys = golden.crossReferences.map { [$0.from, $0.to, $0.kind] }
        XCTAssertEqual(xrefKeys, xrefKeys.sorted { ($0[0], $0[1], $0[2]) < ($1[0], $1[1], $1[2]) })
    }

    func testGoldenBasicBlocksReferenceProcedureByAddressNotUUID() throws {
        let golden = GoldenOutput(snapshot: try analyzeSystemBinary())
        guard !golden.basicBlocks.isEmpty else {
            throw XCTSkip("no basic blocks recovered for this binary")
        }
        // Every block's owning-procedure key is either nil or a 0x hex address — never a
        // raw UUID string.
        for block in golden.basicBlocks {
            if let owner = block.procedureStartAddress {
                XCTAssertTrue(owner.hasPrefix("0x"), "block owner must be a hex address, got \(owner)")
            }
        }
    }

    func testGoldenJSONDoesNotEmbedAbsolutePathOrRawUUID() throws {
        let snapshot = try analyzeSystemBinary()
        let json = try GoldenOutput(snapshot: snapshot).jsonString()

        // The analyzed binary's own absolute path must never appear in the output (it is
        // stripped to a basename). NOTE: legitimate library install-names in the import
        // table ARE absolute paths (e.g. "/usr/lib/libSystem.B.dylib") and are kept as
        // real metadata — so we assert only that the INPUT path does not leak, not that
        // no slash-prefixed string exists anywhere.
        XCTAssertFalse(json.contains("/bin/ls"), "the analyzed binary's absolute path must not appear in golden JSON")

        // The embedded Mach-O UUID, when present, is replaced by a boolean flag — the raw
        // hyphenated UUID string must not appear.
        if let rawUUID = snapshot.binaries.first?.metadata.uuid, !rawUUID.isEmpty {
            XCTAssertFalse(json.contains(rawUUID), "raw embedded UUID must be normalized out of golden JSON")
        }
    }

    func testGoldenPseudocodeIsBoundedAndStable() throws {
        let snapshot = try analyzeSystemBinary()
        // A small cap keeps the output bounded; the field must still be exercised on a
        // binary with procedures.
        let golden = GoldenOutput(snapshot: snapshot, maxProcedurePseudocode: 3)
        XCTAssertLessThanOrEqual(golden.pseudocode.count, 3)
        if !snapshot.functions.isEmpty {
            XCTAssertFalse(golden.pseudocode.isEmpty, "expected pseudocode for at least one procedure")
            XCTAssertTrue(golden.pseudocode.allSatisfy { !$0.lines.isEmpty }, "each pseudocode entry should have lines")
        }
        // Pseudocode disabled -> empty, and the rest of the output still builds.
        let withoutPseudocode = GoldenOutput(snapshot: snapshot, maxProcedurePseudocode: 0)
        XCTAssertTrue(withoutPseudocode.pseudocode.isEmpty)
    }

    func testBasenameNormalizationHandlesEdgeCases() {
        XCTAssertEqual(GoldenOutput.basename(of: "/bin/ls"), "ls")
        XCTAssertEqual(GoldenOutput.basename(of: "/private/tmp/Fixture.bin"), "Fixture.bin")
        XCTAssertEqual(GoldenOutput.basename(of: "/a/b/"), "b")
        XCTAssertEqual(GoldenOutput.basename(of: "bare"), "bare")
        XCTAssertEqual(GoldenOutput.basename(of: ""), "")
    }
}
