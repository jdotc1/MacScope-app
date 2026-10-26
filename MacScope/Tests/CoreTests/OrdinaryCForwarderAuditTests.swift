import Foundation
import XCTest
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

final class OrdinaryCForwarderAuditTests: XCTestCase {
    func testActualUpsamplerBreakRejectsPayloadAndContradictoryForwarders() throws {
        // The certified full/opaque pair retains the complete decoder-faithful input.
        // Bounded negative certificate mutations never render a mutated instruction.
        let fixtures = try OrdinaryCUpsamplerFixturePair.make(.jinit)
        try fixtures.requireFullTypedRowOwnership()
        // Forwarder visibility remains an obligation of the ACTUAL full typed document.
        let fixture = fixtures.full
        let function = fixture.function
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        func block(_ address: UInt64) throws -> Int {
            try XCTUnwrap(cfg.blocks.first { candidate in
                candidate.instructionRange.contains { function.instructions[$0].source.address == address }
            }?.index)
        }
        let origin = try block(0x3b134), forwarder = try block(0x3b138), destination = try block(0x3b15c)
        let row = cfg.blocks[forwarder].startIndex
        XCTAssertEqual(cfg.blocks[forwarder].instructionRange.count, 1)
        XCTAssertEqual(function.instructions[row].source.mnemonic, "b")
        XCTAssertEqual(function.instructions[row].source.operands, "0x000000000003b15c")
        let observed = Set(fixture.document.lines.compactMap(\.sourceAddress))
        func route(_ candidate: MacIRFunction? = nil, graph: CFG? = nil,
                   visible: Set<UInt64>? = nil, forbidden: Set<Int> = []) -> [Int]? {
            OrdinaryCOutputAudit.unprintedBranchPath(from: origin, to: destination,
                function: candidate ?? function, cfg: graph ?? cfg, observedSourceAddresses: visible ?? observed,
                forbiddenIntermediateBlocks: forbidden)
        }
        XCTAssertEqual(cfg.blocks[origin].successors[1], forwarder)
        XCTAssertEqual(cfg.blocks[forwarder].successors, [destination])
        XCTAssertEqual(route(), [origin, forwarder, destination])
        XCTAssertNil(route(visible: observed.union([0x3b138])), "no skipping a printed copy/payload at the forwarder")
        XCTAssertNil(route(forbidden: [forwarder]), "no skipped body block")
        var candidate = function
        candidate.instructions[row].operation = .assign(destination: .register(name: "x9", version: 99), source: .immediate(0))
        XCTAssertNil(route(candidate), "an effectful row cannot be an epsilon edge")
        candidate = function
        candidate.instructions[row].memoryAccess = .init(byteWidth: 8)
        XCTAssertNil(route(candidate), "no hidden side metadata")
        candidate = function
        candidate.instructions[row].operation = .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x3b138)])
        XCTAssertNil(route(candidate), "IR cannot contradict the immutable decoded B target")
        candidate = function
        candidate.instructions[row].source.byteText = "00 00 00 94"
        XCTAssertNil(route(candidate), "BL encoding cannot certify B-only forwarding")
        candidate = function
        let envelope = try XCTUnwrap(candidate.instructions[row].source.structuredOperands)
        candidate.instructions[row].source.structuredOperands = .init(architecture: envelope.architecture,
            schemaVersion: envelope.schemaVersion, coverage: envelope.coverage, opcodeClass: envelope.opcodeClass,
            operands: [.pcRelative(.init(baseAddress: 0x3b138, displacement: 0))],
            presentation: envelope.presentation, semantics: envelope.semantics, legacyText: envelope.legacyText)
        XCTAssertNil(route(candidate), "contradictory typed target cannot be bypassed")
        var graph = cfg
        graph.blocks[forwarder].successors = [forwarder]
        XCTAssertNil(route(graph: graph), "cycles/contradictory successors fail closed")
    }
}
