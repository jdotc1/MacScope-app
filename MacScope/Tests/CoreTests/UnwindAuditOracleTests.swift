import Foundation
import XCTest
@testable import MacScope

final class UnwindAuditOracleTests: XCTestCase {
    private struct Expected {
        let name: String
        let start: UInt64
        let end: UInt64
        let instructions: Int
        let verdict: String
        let coverage: String
        let mode: String
        let scope: String
        let encoding: UInt32
        let reason: String
        let pcs: [UInt64]
    }

    func testLoopsMatchesSavedOwnedOracle() throws {
        let binary = try loadFixture(
            "UnwindLoops.dylib",
            digest: "e4957a86d91eb3722f975b48aee12bace61211e7a737a56a9249dad9b598d8d1",
            byteCount: 17480, uuid: "9f20e834-0ec1-31f0-aa9c-6153bbab70c6"
        )
        let expected: [Expected] = [
            Expected(name: "_loop_zero", start: 0x340, end: 0x36c,
                     instructions: 11, verdict: "agreement", coverage: "compact",
                     mode: "frameless", scope: "modeled_leaf_body", encoding: 0x02000000,
                     reason: "supported_model_agreement", pcs: [0x340, 0x344, 0x348, 0x34c, 0x35c, 0x360]),
            Expected(name: "_loop_one", start: 0x36c, end: 0x398,
                     instructions: 11, verdict: "agreement", coverage: "compact",
                     mode: "frameless", scope: "modeled_leaf_body", encoding: 0x02000000,
                     reason: "supported_model_agreement", pcs: [0x36c, 0x370, 0x374, 0x378, 0x37c, 0x380, 0x384, 0x388, 0x38c]),
            Expected(name: "_loop_three", start: 0x398, end: 0x3c4,
                     instructions: 11, verdict: "agreement", coverage: "compact",
                     mode: "frameless", scope: "modeled_leaf_body", encoding: 0x02000000,
                     reason: "supported_model_agreement", pcs: [0x398, 0x39c, 0x3a0, 0x3a4, 0x3a8, 0x3ac, 0x3b0, 0x3b4, 0x3b8]),
            Expected(name: "_loop_unknown", start: 0x3c4, end: 0x3e0,
                     instructions: 7, verdict: "agreement", coverage: "compact",
                     mode: "frameless", scope: "modeled_leaf_body", encoding: 0x02000000,
                     reason: "supported_model_agreement", pcs: [0x3c4, 0x3c8, 0x3cc, 0x3d0, 0x3d4, 0x3d8]),
            Expected(name: "_loop_stable", start: 0x3e0, end: 0x3ec,
                     instructions: 3, verdict: "agreement", coverage: "compact",
                     mode: "frameless", scope: "modeled_leaf_body", encoding: 0x02000000,
                     reason: "supported_model_agreement", pcs: [0x3e0, 0x3e4]),
            Expected(name: "_loop_bad_rule", start: 0x3ec, end: 0x404,
                     instructions: 6, verdict: "inconsistency", coverage: "compact",
                     mode: "frameless", scope: "modeled_leaf_body", encoding: 0x02002000,
                     reason: "caller_state_mismatch", pcs: [0x3f0, 0x3f4, 0x3f8]),
            Expected(name: "_loop_unknown_recovery", start: 0x404, end: 0x42c,
                     instructions: 10, verdict: "unresolved", coverage: "compact",
                     mode: "frameless", scope: "modeled_leaf_body", encoding: 0x02000000,
                     reason: "unknown_recovery_value", pcs: []),
            Expected(name: "_loop_possible_only", start: 0x42c, end: 0x450,
                     instructions: 9, verdict: "unresolved", coverage: "compact",
                     mode: "frameless", scope: "modeled_leaf_body", encoding: 0x02000000,
                     reason: "cfg_path_feasibility_unknown", pcs: []),
            Expected(name: "_loop_no_exit", start: 0x450, end: 0x460,
                     instructions: 4, verdict: "unresolved", coverage: "compact",
                     mode: "frameless", scope: "metadata_only", encoding: 0x02000000,
                     reason: "no_supported_observation", pcs: []),
            Expected(name: "_loop_multiple_entry", start: 0x460, end: 0x474,
                     instructions: 5, verdict: "unresolved", coverage: "compact",
                     mode: "frameless", scope: "metadata_only", encoding: 0x02000000,
                     reason: "cfg_loop_shape_not_modeled", pcs: []),
            Expected(name: "_loop_multiple_backedges", start: 0x474, end: 0x488,
                     instructions: 5, verdict: "unresolved", coverage: "compact",
                     mode: "frameless", scope: "metadata_only", encoding: 0x02000000,
                     reason: "cfg_loop_shape_not_modeled", pcs: []),
            Expected(name: "_loop_call_inside", start: 0x488, end: 0x4a0,
                     instructions: 6, verdict: "unresolved", coverage: "compact",
                     mode: "frame", scope: "metadata_only", encoding: 0x04000000,
                     reason: "cfg_loop_call_not_modeled", pcs: []),
            Expected(name: "_loop_frame_after", start: 0x4a0, end: 0x4c0,
                     instructions: 8, verdict: "agreement", coverage: "dwarf_evaluated",
                     mode: "dwarf", scope: "synchronous_call_sites", encoding: 0x03000014,
                     reason: "supported_model_agreement", pcs: [0x4b4]),
            Expected(name: "_loop_fde_bad", start: 0x4c0, end: 0x4e0,
                     instructions: 8, verdict: "inconsistency", coverage: "dwarf_evaluated",
                     mode: "dwarf", scope: "synchronous_call_sites", encoding: 0x03000040,
                     reason: "caller_state_mismatch", pcs: [0x4d4]),
            Expected(name: "_loop_sink", start: 0x4e0, end: 0x4e8,
                     instructions: 2, verdict: "agreement", coverage: "compact",
                     mode: "frameless", scope: "modeled_leaf_body", encoding: 0x02000000,
                     reason: "supported_model_agreement", pcs: [0x4e0]),
        ]
        let report = try UnwindAuditService.audit(binary: binary)
        try assertOracle(report, binary: binary, expected: expected)
        XCTAssertEqual(report.findings.filter { $0.verdict == "agreement" }.count, 7)
        XCTAssertEqual(report.findings.filter { $0.verdict == "inconsistency" }.count, 2)
        XCTAssertEqual(report.findings.filter { $0.verdict == "unresolved" }.count, 6)
        XCTAssertEqual(report.findings.reduce(0) { $0 + $1.checkedPCs.count }, 38)
        let loop_bad_rule = try XCTUnwrap(report.findings.first { $0.function.symbolName == "_loop_bad_rule" })
        XCTAssertTrue(loop_bad_rule.evidence.contains {
            $0.code == "caller_state_mismatch" && $0.address == 0x3f0
                && $0.expected == "entry SP" && $0.observed == "entry SP+16"
        })
        let loop_fde_bad = try XCTUnwrap(report.findings.first { $0.function.symbolName == "_loop_fde_bad" })
        XCTAssertTrue(loop_fde_bad.evidence.contains {
            $0.code == "caller_state_mismatch" && $0.address == 0x4d4
                && $0.expected == "original x30" && $0.observed == "constant 0x4d8"
        })
    }

    func testCFARegisterMatchesSavedOwnedOracle() throws {
        let binary = try loadFixture(
            "CFARegister.dylib",
            digest: "e3ef10557917add67fd62dcebc9ea7f0893339a362325e3511ed4c5f7e9e9a93",
            byteCount: 16904, uuid: "eada8dec-ff01-3904-b0b8-2365df568169"
        )
        let expected: [Expected] = [
            Expected(name: "_cfa_register_agree", start: 0x338, end: 0x34c,
                     instructions: 5, verdict: "agreement", coverage: "dwarf_evaluated",
                     mode: "dwarf", scope: "synchronous_call_sites", encoding: 0x03000014,
                     reason: "supported_model_agreement", pcs: [0x340]),
            Expected(name: "_cfa_register_bad_lr", start: 0x34c, end: 0x360,
                     instructions: 5, verdict: "inconsistency", coverage: "dwarf_evaluated",
                     mode: "dwarf", scope: "synchronous_call_sites", encoding: 0x03000040,
                     reason: "caller_state_mismatch", pcs: [0x354]),
            Expected(name: "_cfa_register_sink", start: 0x360, end: 0x368,
                     instructions: 0, verdict: "unresolved", coverage: "none",
                     mode: "none", scope: "metadata_only", encoding: 0x00000000,
                     reason: "empty_unwind_rule", pcs: []),
        ]
        let report = try UnwindAuditService.audit(binary: binary)
        try assertOracle(report, binary: binary, expected: expected)
        XCTAssertEqual(report.findings.filter { $0.verdict == "agreement" }.count, 1)
        XCTAssertEqual(report.findings.filter { $0.verdict == "inconsistency" }.count, 1)
        XCTAssertEqual(report.findings.filter { $0.verdict == "unresolved" }.count, 1)
        XCTAssertEqual(report.findings.reduce(0) { $0 + $1.checkedPCs.count }, 2)
        let cfa_register_bad_lr = try XCTUnwrap(report.findings.first { $0.function.symbolName == "_cfa_register_bad_lr" })
        XCTAssertTrue(cfa_register_bad_lr.evidence.contains {
            $0.code == "caller_state_mismatch" && $0.address == 0x354
                && $0.expected == "original x30" && $0.observed == "constant 0x358"
        })
    }

    func testLoopCallModelUsesRetainedOriginalImageAndExactModelIdentity() throws {
        // Original saved identity and original words; no new hashing or fixture generation.
        let binary = try loadFixture(
            "UnwindLoops.dylib",
            digest: "e4957a86d91eb3722f975b48aee12bace61211e7a737a56a9249dad9b598d8d1",
            byteCount: 17480, uuid: "9f20e834-0ec1-31f0-aa9c-6153bbab70c6"
        )
        let report = try UnwindAuditService.audit(binary: binary, model: .boundedLoopCalls)
        XCTAssertEqual(report.analysisModelVersion, "arm64-bounded-loop-calls-cfa-register-v2")
        XCTAssertEqual(report.identity, binary.artifactIdentity)
        XCTAssertEqual(report.findings.count, 15)
        XCTAssertEqual(report.findings.filter { $0.verdict == "agreement" }.count, 8)
        XCTAssertEqual(report.findings.filter { $0.verdict == "inconsistency" }.count, 2)
        XCTAssertEqual(report.findings.filter { $0.verdict == "unresolved" }.count, 5)
        let finding = try XCTUnwrap(report.findings.first { $0.function.symbolName == "_loop_call_inside" })
        XCTAssertEqual(finding.function.address, 0x488)
        XCTAssertEqual(finding.endAddress, 0x4a0)
        XCTAssertEqual(finding.identity, binary.artifactIdentity)
        XCTAssertEqual(finding.verdict, "agreement")
        XCTAssertEqual(finding.scope, "synchronous_call_sites")
        XCTAssertEqual(finding.checkedPCs, [0x490])
        XCTAssertEqual(finding.reasonCodes, ["supported_model_agreement"])
        XCTAssertTrue(finding.evidence.contains { $0.code == "cfg_loop_checked" && $0.address == 0x490 })
        let decoded = try JSONDecoder().decode(UnwindAuditReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded, report)
        // Existing known reachable inconsistency retains original-PC recovery evidence.
        let bad = try XCTUnwrap(report.findings.first { $0.function.symbolName == "_loop_fde_bad" })
        XCTAssertEqual(bad.verdict, "inconsistency")
        XCTAssertTrue(bad.evidence.contains {
            $0.address == 0x4d4 && $0.expected == "original x30" && $0.observed == "constant 0x4d8"
        })
    }

    func testLoopCallModelRetainsAttributedUnresolvedBudgetOutcome() throws {
        let binary = try loadFixture(
            "UnwindLoops.dylib",
            digest: "e4957a86d91eb3722f975b48aee12bace61211e7a737a56a9249dad9b598d8d1",
            byteCount: 17480, uuid: "9f20e834-0ec1-31f0-aa9c-6153bbab70c6"
        )
        var limits = UnwindAuditLimits()
        limits.maxObservations = 1
        let report = try UnwindAuditService.audit(binary: binary, limits: limits, model: .boundedLoopCalls)
        let finding = try XCTUnwrap(report.findings.first { $0.function.symbolName == "_loop_call_inside" })
        XCTAssertEqual(report.configuration, limits)
        XCTAssertEqual(report.findings.count, 15)
        XCTAssertEqual(finding.verdict, "unresolved")
        XCTAssertEqual(finding.checkedPCs, [])
        XCTAssertEqual(finding.reasonCodes, ["observation_limit"])
        XCTAssertTrue(finding.evidence.contains { $0.code == "observation_limit" && $0.address == 0x490 })
    }

    private func assertOracle(_ report: UnwindAuditReport, binary: LoadedBinary,
                              expected: [Expected], file: StaticString = #filePath,
                              line: UInt = #line) throws {
        let identity = try XCTUnwrap(binary.artifactIdentity, file: file, line: line)
        XCTAssertEqual(report.identity, identity, file: file, line: line)
        XCTAssertEqual(report.findings.count, expected.count, file: file, line: line)
        XCTAssertEqual(Set(report.findings.compactMap { $0.function.symbolName }),
                       Set(expected.map(\.name)), file: file, line: line)
        for row in expected {
            let finding = try XCTUnwrap(report.findings.first { $0.function.symbolName == row.name },
                                        row.name, file: file, line: line)
            XCTAssertEqual(finding.identity, identity, row.name, file: file, line: line)
            XCTAssertEqual(finding.function.address, row.start, row.name, file: file, line: line)
            XCTAssertEqual(finding.endAddress, row.end, row.name, file: file, line: line)
            XCTAssertEqual(finding.function.size, row.end - row.start, row.name, file: file, line: line)
            XCTAssertEqual(finding.instructionCount, row.instructions, row.name, file: file, line: line)
            XCTAssertEqual(finding.verdict, row.verdict, row.name, file: file, line: line)
            XCTAssertEqual(finding.coverage, row.coverage, row.name, file: file, line: line)
            XCTAssertEqual(finding.mode, row.mode, row.name, file: file, line: line)
            XCTAssertEqual(finding.scope, row.scope, row.name, file: file, line: line)
            XCTAssertEqual(finding.encoding, row.encoding, row.name, file: file, line: line)
            XCTAssertEqual(finding.reasonCodes, [row.reason], row.name, file: file, line: line)
            XCTAssertEqual(finding.checkedPCs, row.pcs, row.name, file: file, line: line)
        }
    }

    /// Reuses saved first-audit identity; parser-derived facts remain the byte/address authority.
    private func loadFixture(_ name: String, digest: String, byteCount: UInt64,
                             uuid: String) throws -> LoadedBinary {
        let url = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent(name)
        let bytes = try Data(contentsOf: url)
        let parsed = try MachOParser().parse(bytes, options: MachOParseOptions(
            recoverStringLiterals: false, recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: false, parseCodeSignature: false
        ))
        let identity = try MachOSliceArtifactIdentity(
            uuid: UUID(uuidString: uuid), rawCPUType: 0x0100000c, rawCPUSubtype: 0,
            selectedSliceSHA256: digest, selectedSliceByteCount: byteCount
        )
        let layout = try MachOPreferredSegmentLayout(records: parsed.segments.map {
            MachOPreferredSegmentLayout.Record(
                name: $0.name, preferredVMStart: $0.vmAddress, preferredVMSize: $0.vmSize,
                sliceRelativeFileOffset: $0.fileOffset, fileSize: $0.fileSize,
                initialProtections: $0.initialProtection
            )
        }, selectedSliceByteCount: byteCount)
        func section(_ source: MachOSection) -> BinarySection {
            BinarySection(name: "\(source.segmentName),\(source.sectionName)",
                          address: source.address, size: source.size,
                          fileOffset: UInt64(source.fileOffset),
                          isExecutable: source.isExecutableInstructions, isZeroFill: source.isZeroFill)
        }
        return LoadedBinary(
            name: name, path: url.path, isBundle: false,
            cpuType: parsed.header.cpuType, cpuSubtype: parsed.header.cpuSubtype,
            fileTypeName: parsed.fileTypeName, architectureDisplayName: parsed.architectureDisplayName,
            metadata: BinaryMetadataSummary(uuid: parsed.uuid?.stringValue),
            artifactIdentity: identity, preferredSegmentLayout: layout, artifactIntegrityState: .verified,
            bytes: bytes, sliceOffset: parsed.selectedSliceOffset, sliceSize: byteCount,
            sections: parsed.sections.map(section), executableTextSection: parsed.executableTextSection.map(section),
            entryPointAddress: parsed.entryPointAddress,
            symbols: parsed.symbols.map {
                SymbolSummary(id: UUID(), name: $0.name, address: $0.address,
                              kind: $0.kind.rawValue, libraryName: $0.libraryName, rawLinkageName: $0.name)
            },
            imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            functionStarts: parsed.functionStarts.map(\.address), objcSelectors: [:]
        )
    }
}
