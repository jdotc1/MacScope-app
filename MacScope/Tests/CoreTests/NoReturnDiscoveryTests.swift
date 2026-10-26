import Foundation
import XCTest
@testable import MacScope

/// HOP-1: no-return knowledge in discovery. TinyMachO fixtures in the style of
/// RecursiveDescentDiscoveryTests (no symbols, no LC_FUNCTION_STARTS).
@MainActor
final class NoReturnDiscoveryTests: XCTestCase {
    // 0x00 f0 (entry): stp x29, x30, [sp, #-0x10]! ; bl f_halt
    // 0x08 f1:         stp x29, x30, [sp, #-0x10]! ; ret      <- hidden behind the call
    // 0x10 f_halt:     brk #0                                  <- every exit halts
    private static let haltingCallCode = Data([
        0xfd, 0x7b, 0xbf, 0xa9, // stp x29, x30, [sp, #-0x10]!
        0x03, 0x00, 0x00, 0x94, // bl +0xc (f_halt)
        0xfd, 0x7b, 0xbf, 0xa9, // stp x29, x30, [sp, #-0x10]!
        0xc0, 0x03, 0x5f, 0xd6, // ret
        0x00, 0x00, 0x20, 0xd4, // brk #0
    ])

    // 0x00 cbz x0, +8   (makes 0x08 a block leader inside the same function, as in
    //                    RecursiveDescentDiscoveryTests' trap/call fall-through tests)
    // 0x04 bl  +0xc     (-> 0x10)
    // 0x08 ret
    // 0x0c ret
    // 0x10 brk #0 | ret (halting or returning callee)
    private static func leaderFixture(calleeHalts: Bool) -> TinyMachO {
        TinyMachO.make(code: Data(
            [0x40, 0x00, 0x00, 0xb4, 0x03, 0x00, 0x00, 0x94,
             0xc0, 0x03, 0x5f, 0xd6, 0xc0, 0x03, 0x5f, 0xd6]
                + (calleeHalts ? [0x00, 0x00, 0x20, 0xd4] : [0xc0, 0x03, 0x5f, 0xd6])
        ))
    }

    func testCallToNoReturnTargetHasNoFallthroughEdge() throws {
        let fixture = Self.leaderFixture(calleeHalts: true)
        let snapshot = try AnalysisEngine().analyze(url: try fixture.write())
        XCTAssertFalse(snapshot.controlFlowEdges.contains {
            $0.from == fixture.baseAddress + 4 && $0.kind == "fallthrough"
        })
        XCTAssertTrue(snapshot.controlFlowEdges.contains {
            $0.from == fixture.baseAddress + 4 && $0.to == fixture.baseAddress + 0x10 && $0.kind == "call"
        })
        XCTAssertTrue(snapshot.basicBlocks.contains { $0.startAddress == fixture.baseAddress + 8 })
    }

    func testCallToReturningTargetKeepsFallthroughEdge() throws {
        let fixture = Self.leaderFixture(calleeHalts: false)
        let snapshot = try AnalysisEngine().analyze(url: try fixture.write())
        XCTAssertTrue(snapshot.controlFlowEdges.contains {
            $0.from == fixture.baseAddress + 4 && $0.to == fixture.baseAddress + 8 && $0.kind == "fallthrough"
        })
        XCTAssertTrue(snapshot.functions.allSatisfy { $0.noReturnProvenance == nil })
    }

    func testEveryExitHaltsPropagatesToCallers() throws {
        let fixture = TinyMachO.make(code: Self.haltingCallCode)
        let snapshot = try AnalysisEngine().analyze(url: try fixture.write())
        let byStart = Dictionary(uniqueKeysWithValues: snapshot.functions.map { ($0.startAddress, $0) })
        XCTAssertEqual(byStart[fixture.baseAddress + 0x10]?.noReturnProvenance, .propagated)
        XCTAssertEqual(byStart[fixture.baseAddress]?.noReturnProvenance, .propagated,
                       "the caller's only exit is the call to the halting callee")
        XCTAssertNil(byStart[fixture.baseAddress + 0x08]?.noReturnProvenance, "f1 returns")
    }

    func testProloguePastNoReturnCallIsRecoveredAsFunction() throws {
        let fixture = TinyMachO.make(code: Self.haltingCallCode)
        let snapshot = try AnalysisEngine().analyze(url: try fixture.write())
        XCTAssertEqual(snapshot.functions.map(\.startAddress), [
            fixture.baseAddress, fixture.baseAddress + 0x08, fixture.baseAddress + 0x10,
        ])
        XCTAssertEqual(snapshot.functions.first?.endAddress, fixture.baseAddress + 0x08)
        XCTAssertEqual(snapshot.functions[1].confidence, 0.6)
    }

    func testReturningCalleeKeepsPrologueMerged() throws {
        // Same shape, but the callee returns: the prologue after the call is NOT split off
        // (the existing conservative behaviour) and nothing is marked no-return.
        var code = Self.haltingCallCode
        code.replaceSubrange(16..<20, with: [0xc0, 0x03, 0x5f, 0xd6]) // ret instead of brk
        let fixture = TinyMachO.make(code: code)
        let snapshot = try AnalysisEngine().analyze(url: try fixture.write())
        XCTAssertEqual(snapshot.functions.map(\.startAddress), [fixture.baseAddress, fixture.baseAddress + 0x10])
        XCTAssertTrue(snapshot.functions.allSatisfy { $0.noReturnProvenance == nil })
    }

    func testCatalogTargetsUseSymbolsAndStubsButNotExtendedOnlyNames() {
        let symbols = [
            SymbolSummary(id: UUID(), name: "_abort", address: 0x100, kind: "function", libraryName: nil),
            SymbolSummary(id: UUID(), name: "_printf", address: 0x110, kind: "function", libraryName: nil),
            SymbolSummary(id: UUID(), name: "___stack_chk_fail", address: 0x120, kind: "function", libraryName: nil),
            SymbolSummary(id: UUID(), name: "fatalError", address: 0x130, kind: "function", libraryName: nil,
                          rawLinkageName: "_$ss10fatalError_4file4lines5NeverOSSyXK_s12StaticStringVSutF"),
            SymbolSummary(id: UUID(), name: "_exit", address: nil, kind: "import", libraryName: nil),
        ]
        let targets = NoReturnAnalysis.catalogTargets(
            symbols: symbols,
            stubNamesByAddress: [0x200: "_exit", 0x210: "_malloc", 0x220: "imp___stubs__objc_exception_throw"]
        )
        XCTAssertEqual(targets, [0x100, 0x130, 0x200, 0x220])
    }

    // HOP-5: a callee that RETURNS (`ret`) but whose symbol only the SDK pack marks noReturn.
    // Discovery trusts the pack name: no fall-through after the call, provenance `sdkPack`.
    func testCallToPackOnlyNoReturnSymbolHasNoFallthroughEdge() throws {
        let code = Data([0x40, 0x00, 0x00, 0xb4, 0x03, 0x00, 0x00, 0x94,
                         0xc0, 0x03, 0x5f, 0xd6, 0xc0, 0x03, 0x5f, 0xd6, 0xc0, 0x03, 0x5f, 0xd6])
        let fixture = TinyMachO.make(code: code, symbols: [("_main", 0), ("_macscope_pack_only_halt", 0x10)])
        XCTAssertFalse(NoReturnCatalog.isNoReturn("_macscope_pack_only_halt"))

        var engine = AnalysisEngine()
        engine.sdkPackNoReturnNames = ["macscope_pack_only_halt"]
        let snapshot = try engine.analyze(url: try fixture.write())
        XCTAssertFalse(snapshot.controlFlowEdges.contains {
            $0.from == fixture.baseAddress + 4 && $0.kind == "fallthrough"
        })
        XCTAssertTrue(snapshot.controlFlowEdges.contains {
            $0.from == fixture.baseAddress + 4 && $0.to == fixture.baseAddress + 0x10 && $0.kind == "call"
        })
        let callee = try XCTUnwrap(snapshot.functions.first { $0.startAddress == fixture.baseAddress + 0x10 })
        XCTAssertEqual(callee.noReturnProvenance, .sdkPack)

        // Without the pack name the same binary keeps its fall-through edge.
        var plain = AnalysisEngine()
        plain.sdkPackNoReturnNames = []
        let control = try plain.analyze(url: try fixture.write())
        XCTAssertTrue(control.controlFlowEdges.contains {
            $0.from == fixture.baseAddress + 4 && $0.to == fixture.baseAddress + 8 && $0.kind == "fallthrough"
        })
    }

    func testSDKPackTargetsMatchSymbolsAndStubsAndShippedPackFeedsDiscovery() {
        let symbols = [
            SymbolSummary(id: UUID(), name: "_pack_halt", address: 0x100, kind: "function", libraryName: nil),
            SymbolSummary(id: UUID(), name: "_printf", address: 0x110, kind: "function", libraryName: nil),
        ]
        XCTAssertEqual(NoReturnAnalysis.sdkPackTargets(
            symbols: symbols, stubNamesByAddress: [0x200: "imp___stubs__pack_halt", 0x210: "_malloc"],
            noReturnNames: ["pack_halt"]
        ), [0x100, 0x200])
        XCTAssertEqual(NoReturnAnalysis.sdkPackTargets(symbols: symbols, stubNamesByAddress: [:], noReturnNames: []), [])
        // The shipped pack carries the header-declared no-return set (keys canonicalized).
        for name in ["exit", "abort", "assert_rtn", "pthread_exit", "objc_exception_throw"] {
            XCTAssertTrue(CallSignaturePack.bundledNoReturnCanonicalNames.contains(name), name)
        }
        XCTAssertEqual(AnalysisEngine().sdkPackNoReturnNames, CallSignaturePack.bundledNoReturnCanonicalNames)
        XCTAssertEqual(AnalysisNoReturnProvenance(rawValue: "sdkPack"), .sdkPack)
    }

    func testProjectorCarriesRecoveredNoReturnWithDistinctProvenanceAndUserWins() throws {
        let fixture = TinyMachO.make(code: Self.haltingCallCode)
        var snapshot = try AnalysisEngine().analyze(url: try fixture.write())
        let halting = try XCTUnwrap(snapshot.functions.first { $0.startAddress == fixture.baseAddress + 0x10 })
        let caller = try XCTUnwrap(snapshot.functions.first { $0.startAddress == fixture.baseAddress })

        func noReturnSignatures(_ workspace: WorkspaceSnapshot) throws -> [UInt64: NativeDecompilerWireAuthoredNoReturnState] {
            guard case let .valid(projection) = NativeDecompilerAuthoredInputProjector.project(
                workspace: workspace, imageSlot: workspace.primarySlot, functionID: caller.id
            ) else { XCTFail("projection invalid"); return [:] }
            return Dictionary(uniqueKeysWithValues: projection.authoredInputs.signatures.map {
                ($0.functionAddress.value, $0.noReturnState)
            })
        }
        XCTAssertEqual(try noReturnSignatures(snapshot)[halting.startAddress], .noReturn)
        XCTAssertEqual(try noReturnSignatures(snapshot)[caller.startAddress], .noReturn)

        // An explicit user `returns` beats the analysis.
        snapshot.addressOverrides[ImageAddress(slot: snapshot.primarySlot, address: halting.startAddress)] =
            AddressOverride(signature: .init(noReturnState: .returns))
        XCTAssertEqual(try noReturnSignatures(snapshot)[halting.startAddress], .returns)
    }
}
