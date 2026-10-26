import Foundation
import XCTest
@testable import MacScope

private struct FragmentedCFGFixtureLoader: BinaryLoader {
    let binary: LoadedBinary
    func load(at url: URL) throws -> LoadedBinary { binary }
}

/// Regression coverage for the 2026-10-03 roadmap P0 fixes. The real-binary cases compile tiny
/// Objective-C/C programs with `xcrun clang` (skipped when unavailable), exactly like
/// `StubCallSymbolicationTests.RealImportBinary`.
final class RoadmapP0RegressionTests: XCTestCase {

    // MARK: - P0-01/P0-02: chained-fixup image base + ObjC references

    func testChainedFixupSelectorReferencesResolveInArm64AndArm64eExecutables() throws {
        for arch in ["arm64", "arm64e"] {
            let binary = try RoadmapFixtureBinary.build(.objcExecutable, arch: arch)
            let machO = try MachOParser().parse(Data(contentsOf: binary))
            let selrefs = machO.objectiveCMetadata.selectorReferences
            XCTAssertFalse(selrefs.isEmpty, arch)
            XCTAssertTrue(selrefs.allSatisfy { $0.resolvedName != nil },
                          "\(arch): every chained-fixup selref must resolve")
            let names = Set(selrefs.compactMap(\.resolvedName))
            XCTAssertTrue(names.isSuperset(of: ["alpha", "betaWith:and:"]), "\(arch): \(names)")
        }
    }

    func testDylibWithTextAtZeroRecoversObjCClassesAndSelectors() throws {
        // A dylib's __TEXT is at vmaddr 0; the old "lowest non-zero vmaddr" base picked
        // __DATA_CONST and displaced every DYLD_CHAINED_PTR_64_OFFSET rebase target.
        let dylib = try RoadmapFixtureBinary.build(.objcDylib, arch: "arm64")
        let machO = try MachOParser().parse(Data(contentsOf: dylib))
        XCTAssertEqual(machO.segments.first { $0.name == "__TEXT" }?.vmAddress, 0)
        let classes = machO.objectiveCMetadata.classes
        let widget = try XCTUnwrap(classes.first { $0.name == "RoadmapWidget" }, "class must be recovered")
        XCTAssertEqual(widget.superclassName, "NSObject")
        XCTAssertEqual(Set(widget.instanceMethods.map(\.selector)), ["spin", "spinBy:"])
        let text = try XCTUnwrap(machO.sections.first { $0.sectionName == "__text" })
        for method in widget.instanceMethods {
            let imp = try XCTUnwrap(method.implementation)
            XCTAssertTrue(imp >= text.address && imp < text.address + text.size, "IMP inside __text")
        }
        XCTAssertTrue(machO.objectiveCMetadata.selectorReferences.allSatisfy { $0.resolvedName != nil })
    }

    // MARK: - P0-03/P0-04: __objc_stubs names and named call targets

    func testObjCStubsAreNamedAndPseudocodeNamesCallTargetsInStrippedBinary() throws {
        let binary = try RoadmapFixtureBinary.build(.objcExecutable, arch: "arm64", strip: true)
        let snapshot = try AnalysisEngine().analyze(url: binary)
        let stubNames = Set(snapshot.symbols.filter { $0.kind == "stub" }.map(\.name))
        XCTAssertTrue(stubNames.isSuperset(of: ["_objc_msgSend$alpha", "_objc_msgSend$betaWith:and:"]),
                      "\(stubNames)")
        // Every direct call in every function's pseudocode input, after symbolization.
        let calls = snapshot.functions.flatMap { function in
            (snapshot.pseudocodeTarget(selectedAddress: function.startAddress)?.instructions ?? [])
                .filter { $0.mnemonic == "bl" }.map(\.operands)
        }
        XCTAssertTrue(calls.contains("_objc_msgSend$alpha"), "\(calls)")
    }

    func testObjCStubSelectorRecoveryDecodesAdrpLdrPairs() {
        // adrp x1, #0x8000 page (+8 pages from 0x100000a40) ; ldr x1, [x1, #0x90]
        let pc: UInt64 = 0x1_0000_0A40
        let adrp: UInt32 = 0x9000_0001 | (0 << 29) | (2 << 5)   // immlo=0, immhi=2 → +0x8000
        let ldr: UInt32 = 0xF940_0021 | (0x12 << 10)              // imm12=0x12 → +0x90
        var bytes = Data()
        for word in [adrp, ldr, 0x1400_0002] as [UInt32] {
            withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) }
        }
        let names = ObjCStubSelectorRecovery.names(
            stubBytes: bytes, sectionAddress: pc,
            selectorBySelrefAddress: [0x1_0000_8090: "length"], messageSendTargets: [pc + 16]
        )
        XCTAssertEqual(names, [pc: "_objc_msgSend$length"])
    }

    func testObjCSelectorLoadsWithoutValidatedDispatchRemainUnnamed() {
        let pc: UInt64 = 0x1_0000_0A40
        let pair: [UInt32] = [0x9000_0041, 0xF940_4821]
        for tail: [UInt32] in [[], [0xD65F_03C0], [0xD503_201F], [0x1400_0002], [0xD61F_0200]] {
            var bytes = Data()
            for word in pair + tail { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
            XCTAssertEqual(ObjCStubSelectorRecovery.names(stubBytes: bytes, sectionAddress: pc,
                selectorBySelrefAddress: [0x1_0000_8090: "length"], messageSendTargets: [pc + 20]), [:])
        }
    }

    func testCompleteAuthenticatedObjCStubRequiresExactMessageSendSlot() {
        // Same complete ld64 shape observed in Calculator and TextEdit.
        let pc: UInt64 = 0x1000
        let words: [UInt32] = [0x9000_0001, 0xF940_0021, 0x9000_0011, 0x9100_4231,
            0xF940_0230, 0xD71F_0A11, 0xD420_0020, 0xD420_0020]
        var bytes = Data()
        for word in words { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
        XCTAssertEqual(ObjCStubSelectorRecovery.names(stubBytes: bytes, sectionAddress: pc,
            selectorBySelrefAddress: [pc: "length"], messageSendPointerSlots: [pc + 16]),
            [pc: "_objc_msgSend$length"])
        XCTAssertEqual(ObjCStubSelectorRecovery.names(stubBytes: bytes, sectionAddress: pc,
            selectorBySelrefAddress: [pc: "length"], messageSendPointerSlots: [pc + 24]), [:])
        XCTAssertEqual(ObjCStubSelectorRecovery.names(stubBytes: Data(bytes.dropLast(4)), sectionAddress: pc,
            selectorBySelrefAddress: [pc: "length"], messageSendPointerSlots: [pc + 16]), [:])
    }

    func testBranchTargetSymbolizerRewritesOnlyKnownTrailingTargets() {
        let symbolizer = BranchTargetSymbolizer(namesByAddress: [0x1000: "_printf", 0x2000: "loop"])
        XCTAssertEqual(symbolizer.symbolizedOperands(mnemonic: "bl", operands: "0x0000000000001000", callsOnly: true), "_printf")
        XCTAssertEqual(symbolizer.symbolizedOperands(mnemonic: "cbz", operands: "x0, 0x2000", callsOnly: false), "x0, loop")
        XCTAssertEqual(symbolizer.symbolizedOperands(mnemonic: "b.ne", operands: "0x2000", callsOnly: false), "loop")
        XCTAssertNil(symbolizer.symbolizedOperands(mnemonic: "b.ne", operands: "0x2000", callsOnly: true),
                     "pseudocode keeps intra-function branch targets as addresses")
        XCTAssertNil(symbolizer.symbolizedOperands(mnemonic: "bl", operands: "0x3000", callsOnly: true))
        XCTAssertNil(symbolizer.symbolizedOperands(mnemonic: "ldr", operands: "x0, [x1, #0x1000]", callsOnly: false))
    }

    // MARK: - Symbol recovery cap keeps imports

    func testSymbolCapKeepsImportsAndExportsBeforeLocals() {
        // 24,000 locals, 500 external definitions, 500 undefined (imports): over the 20,000 cap.
        let dysymtab = MachODysymtabCommand(
            index: 0, localSymbolIndex: 0, localSymbolCount: 24_000,
            externalDefinedSymbolIndex: 24_000, externalDefinedSymbolCount: 500,
            undefinedSymbolIndex: 24_500, undefinedSymbolCount: 500,
            indirectSymbolOffset: 0, indirectSymbolCount: 0
        )
        let indices = MachOParser.recoveredSymbolIndices(
            declaredCount: 25_000, readableCount: 25_000, dysymtab: dysymtab
        )
        XCTAssertEqual(indices.count, MachORecoveryLimits.maximumSymbols)
        XCTAssertTrue(Set(indices).isSuperset(of: 24_000..<25_000), "every import and export survives the cap")
        XCTAssertEqual(indices, indices.sorted())
        // Under the cap, and without a dysymtab, the table is read in order as before.
        XCTAssertEqual(MachOParser.recoveredSymbolIndices(declaredCount: 3, readableCount: 3, dysymtab: dysymtab), [0, 1, 2])
        XCTAssertEqual(MachOParser.recoveredSymbolIndices(declaredCount: 30_000, readableCount: 30_000, dysymtab: nil).count,
                       MachORecoveryLimits.maximumSymbols)
    }

    func testZeroVMSizeSegmentWithFileBytesIsAccepted() throws {
        // Go binaries carry __DWARF with vmsize 0 and real file bytes (e.g. 3.5 MB).
        let layout = try MachOPreferredSegmentLayout(records: [
            .init(name: "__TEXT", preferredVMStart: 0x1_0000_0000, preferredVMSize: 0x4000,
                  sliceRelativeFileOffset: 0, fileSize: 0x4000, initialProtections: 5),
            .init(name: "__DWARF", preferredVMStart: 0x1_0000_8000, preferredVMSize: 0,
                  sliceRelativeFileOffset: 0x4000, fileSize: 0x1000, initialProtections: 3),
        ], selectedSliceByteCount: 0x5000)
        XCTAssertEqual(layout.records.count, 2)
        XCTAssertThrowsError(try MachOPreferredSegmentLayout(records: [
            .init(name: "__BAD", preferredVMStart: UInt64.max - 1, preferredVMSize: 4,
                  sliceRelativeFileOffset: 0, fileSize: 0, initialProtections: 1),
        ], selectedSliceByteCount: 0x5000), "a wrapping span is still rejected")
    }

    func testBinExportOperandParserNegatesInt64MinWithoutTrapping() {
        // -Int64.min traps; each of the three negation sites must wrap instead.
        for operand in ["#-0x8000000000000000", "[x0, #-0x8000000000000000]", "-0x8000000000000000(%rax)"] {
            let nodes = BinExport2OperandParser.parseOperandTree(operand, arch: operand.contains("%") ? "x86_64" : "arm64")
            XCTAssertFalse(nodes.isEmpty, operand)
            XCTAssertTrue(nodes.contains { $0.immediate == 0x8000_0000_0000_0000 }, "\(operand): \(nodes)")
        }
    }

    // MARK: - P0-05: implicit fall-through edges

    func testBlockEndingAtALeaderGetsAFallthroughEdge() {
        // 0x1000 mov ; 0x1004 add (loop header, target of b.ne) ; 0x1008 subs ; 0x100c b.ne 0x1004 ; 0x1010 ret
        func insn(_ a: UInt64, _ m: String, target: UInt64? = nil, flow: InstructionFlow = .normal) -> DecodedInstruction {
            DecodedInstruction(address: a, bytes: [0, 0, 0, 0], mnemonic: m, operands: "",
                               branchTarget: target, comment: nil, flow: flow)
        }
        let instructions = [
            insn(0x1000, "mov"), insn(0x1004, "add"), insn(0x1008, "subs"),
            insn(0x100C, "b.ne", target: 0x1004, flow: .conditionalJump), insn(0x1010, "ret", flow: .return),
        ]
        let function = FunctionSummary(id: UUID(), name: "f", startAddress: 0x1000, endAddress: 0x1014, confidence: 1)
        let engine = AnalysisEngine()
        let blocks = engine.buildBasicBlocks(from: instructions, functions: [function], codeStart: 0x1000)
        let edges = engine.buildControlFlowEdges(from: instructions, basicBlocks: blocks)
        XCTAssertTrue(edges.contains { $0.from == 0x1000 && $0.to == 0x1004 && $0.kind == "fallthrough" },
                      "entry block must flow into the loop header")
        XCTAssertTrue(edges.contains { $0.from == 0x100C && $0.to == 0x1010 && $0.kind == "fallthrough" })
        XCTAssertFalse(edges.contains { $0.from == 0x1010 }, "ret has no successor")
    }

    func testNoFallthroughOrBlockMergeAcrossARemovedDataRange() {
        // 0x1000 cmp ; 0x1004 b.ne 0x1010 ; [0x1008..0x100c data-in-code removed] ; 0x100c add ; 0x1010 ret
        func insn(_ a: UInt64, _ m: String, target: UInt64? = nil, flow: InstructionFlow = .normal) -> DecodedInstruction {
            DecodedInstruction(address: a, bytes: [0, 0, 0, 0], mnemonic: m, operands: "",
                               branchTarget: target, comment: nil, flow: flow)
        }
        let instructions = [
            insn(0x1000, "cmp"), insn(0x1004, "b.ne", target: 0x1010, flow: .conditionalJump),
            insn(0x100C, "add"), insn(0x1010, "ret", flow: .return),
        ]
        let function = FunctionSummary(id: UUID(), name: "f", startAddress: 0x1000, endAddress: 0x1014, confidence: 1)
        let engine = AnalysisEngine()
        let blocks = engine.buildBasicBlocks(from: instructions, functions: [function], codeStart: 0x1000)
        XCTAssertTrue(blocks.contains { $0.startAddress == 0x100C }, "a row after a gap starts a block")
        let edges = engine.buildControlFlowEdges(from: instructions, basicBlocks: blocks)
        XCTAssertFalse(edges.contains { $0.from == 0x1004 && $0.kind == "fallthrough" },
                       "the conditional's fall-through would execute the data at 0x1008")
        XCTAssertTrue(edges.contains { $0.from == 0x100C && $0.to == 0x1010 && $0.kind == "fallthrough" })
    }

    func testDisjointExecutableSectionsDecodeWithoutGapOrFunctionEnvelope() throws {
        let text = BinarySection(name: "__TEXT,__text", address: 0x1000, size: 8, fileOffset: 0, isExecutable: true)
        let cold = BinarySection(name: "__TEXT,__cold", address: 0x2000, size: 8, fileOffset: 8, isExecutable: true)
        var bytes = Data()
        for word: UInt32 in [0xD503_201F, 0xD65F_03C0, 0xD503_201F, 0xD65F_03C0] {
            withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) }
        }
        let loaded = LoadedBinary(name: "disjoint", path: "/fixture", isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64, fileTypeName: "fixture", architectureDisplayName: "arm64",
            metadata: .empty, bytes: bytes, sliceOffset: 0, sections: [text, cold],
            executableTextSection: text, entryPointAddress: 0x1000, symbols: [], imports: [],
            indirectSymbols: [], exports: [], stringLiterals: [], functionStarts: [0x1000, 0x2000], objcSelectors: [:])
        let snapshot = try AnalysisEngine(loader: FragmentedCFGFixtureLoader(binary: loaded))
            .analyze(url: URL(fileURLWithPath: "/fixture"))
        XCTAssertEqual(snapshot.instructions.map(\.address), [0x1000, 0x1004, 0x2000, 0x2004])
        XCTAssertEqual(snapshot.functions.map(\.startAddress), [0x1000, 0x2000])
        XCTAssertEqual(snapshot.functions.map(\.endAddress), [0x1008, 0x2008])
        XCTAssertFalse(snapshot.controlFlowEdges.contains { $0.kind == "fallthrough" && $0.to == 0x2000 })
        var alias = loaded
        alias.sections[1].fileOffset = 0
        let refused = try AnalysisEngine(loader: FragmentedCFGFixtureLoader(binary: alias))
            .analyze(url: URL(fileURLWithPath: "/fixture"))
        XCTAssertFalse(refused.instructions.contains { $0.address == 0x2000 })
    }

    func testConditionalFallthroughRequiresOwnedAdjacentBytesAndSwitchSameFunction() {
        func row(_ address: UInt64, bytes: [UInt8] = [0, 0, 0, 0], flow: InstructionFlow = .normal) -> DecodedInstruction {
            .init(address: address, bytes: bytes, mnemonic: "fixture", operands: "", branchTarget: nil, comment: nil, flow: flow)
        }
        let functions = [
            FunctionSummary(id: UUID(), name: "a", startAddress: 0x1000, endAddress: 0x1004, confidence: 1),
            FunctionSummary(id: UUID(), name: "b", startAddress: 0x1004, endAddress: 0x1008, confidence: 1),
        ]
        let rows = [row(0x1000, flow: .conditionalJump), row(0x1004), row(0x1010)]
        let engine = AnalysisEngine()
        let blocks = engine.buildBasicBlocks(from: rows, functions: functions, codeStart: 0x1000)
        XCTAssertFalse(blocks.contains { $0.startAddress == 0x1010 })
        XCTAssertTrue(engine.buildControlFlowEdges(from: rows, basicBlocks: blocks,
            jumpTables: [0x1000: [0x1004]]).isEmpty)
        XCTAssertFalse(AnalysisEngine.isPhysicallyAdjacent(row(0x1000, bytes: []), 0x1004))
        XCTAssertFalse(AnalysisEngine.isPhysicallyAdjacent(row(UInt64.max - 1), 2))
    }

    // MARK: - P0-06: export-trie addresses

    func testExportTrieAddressesAreImageBaseRelative() throws {
        let binary = try RoadmapFixtureBinary.build(.cExecutable, arch: "arm64")
        var bytes = try Data(contentsOf: binary)
        // Zero LC_SYMTAB.nsyms so exports can only come from LC_DYLD_EXPORTS_TRIE.
        let ncmds = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
        var offset = 32
        for _ in 0..<ncmds {
            let (cmd, size) = bytes.withUnsafeBytes {
                ($0.loadUnaligned(fromByteOffset: offset, as: UInt32.self),
                 $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
            }
            if cmd == 0x2 { bytes.replaceSubrange((offset + 12)..<(offset + 16), with: [0, 0, 0, 0]) }
            offset += Int(size)
        }
        let machO = try MachOParser().parse(bytes)
        let main = try XCTUnwrap(machO.exports.first { $0.name == "_main" })
        let header = try XCTUnwrap(machO.exports.first { $0.name == "__mh_execute_header" })
        XCTAssertEqual(header.address, 0x1_0000_0000)
        XCTAssertGreaterThan(try XCTUnwrap(main.address), 0x1_0000_0000)
    }

    // MARK: - P0-07: native bridge admissibility
    // The per-request authored-input filter that lived here was retired: the production
    // builder supplies a relevance-ranked context subset and drops only the authored inputs
    // whose subject it explicitly omits (NativeDecompilerSnapshotBuilderTests covers it).

    // MARK: - P0-08: MCP schema/validator contract (schemas from external patch 02; error text and hints here)

    @MainActor
    func testMCPAdvertisesTypedArgumentsAndReturnsScriptingErrors() {
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "t", path: "/tmp/t", kind: "Mach-O executable", architecture: "arm64")],
            functions: [FunctionSummary(id: UUID(), name: "_main", startAddress: 0x1000, endAddress: 0x1008, confidence: 1)],
            symbols: [],
            instructions: [
                InstructionRow(address: 0x1000, bytes: "e0 03 01 aa", mnemonic: "mov", operands: "x0, x1", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ],
            xrefs: [],
            hexBytes: Data()
        )
        let store = WorkspaceStore(workspaceName: "MCP", snapshot: snapshot, engine: AnalysisEngine())
        let server = MCPServer(api: WorkspaceScriptingAPI(store: store))
        func call(_ method: String, _ params: ScriptValue? = nil) -> ScriptValue? {
            var object: [String: ScriptValue] = ["jsonrpc": .string("2.0"), "id": .int(1), "method": .string(method)]
            if let params { object["params"] = params }
            return server.handle(.object(object))
        }
        let tools = call("tools/list")?["result"]?["tools"]?.arrayValue ?? []
        let functions = tools.first { $0["name"]?.stringValue == "functions" }
        XCTAssertEqual(functions?["inputSchema"]?["properties"]?["limit"]?["type"]?.stringValue, "integer")
        XCTAssertEqual(functions?["annotations"]?["readOnlyHint"]?.boolValue, true)

        let listed = call("tools/call", .object(["name": .string("functions"),
                                                 "arguments": .object(["limit": .int(5)])]))
        XCTAssertEqual(listed?["result"]?["isError"]?.boolValue, false, "\(String(describing: listed))")

        let failed = call("tools/call", .object(["name": .string("decompile"),
                                                 "arguments": .object(["function": .string("nope")])]))
        XCTAssertEqual(failed?["result"]?["isError"]?.boolValue, true)
        let message = failed?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(message.contains("nope"), "the scripting error must reach the client: \(message)")
    }

    // MARK: - P1-01: wildcard hex patterns

    func testMaskedHexPatternParsesWildcards() throws {
        let pattern = try XCTUnwrap(BinarySearchService.parseMaskedHexPattern("48 ?? e5 4?"))
        XCTAssertEqual(pattern.bytes, [0x48, 0x00, 0xE5, 0x40])
        XCTAssertEqual(pattern.mask, [0xFF, 0x00, 0xFF, 0xF0])
        XCTAssertEqual(pattern.preview, "48 ?? e5 4?")
        XCTAssertNil(BinarySearchService.parseMaskedHexPattern("?? ??"), "all-wildcard pattern")
        XCTAssertNil(BinarySearchService.parseMaskedHexPattern("4"), "odd nibble count")
        XCTAssertNil(BinarySearchService.parseMaskedHexPattern("+f+f"), "a sign is not a hex digit")
        XCTAssertNil(BinarySearchService.parseMaskedHexPattern("zz"))
        XCTAssertEqual(BinarySearchService.parseMaskedHexPattern("0x48 0x89")?.mask, [0xFF, 0xFF])
    }
}

/// Builds small real Mach-O fixtures with `xcrun clang`.
enum RoadmapFixtureBinary {
    enum Kind { case objcExecutable, objcDylib, cExecutable }

    static func build(_ kind: Kind, arch: String, strip: Bool = false) throws -> URL {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else {
            throw XCTSkip("xcrun unavailable on this host")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-roadmap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (source, file, flags): (String, String, [String])
        switch kind {
        case .objcExecutable:
            source = """
            #import <Foundation/Foundation.h>
            @interface Foo : NSObject - (void)alpha; - (int)betaWith:(int)x and:(int)y; @end
            @implementation Foo - (void)alpha { NSLog(@"a"); } - (int)betaWith:(int)x and:(int)y { return x + y; } @end
            int main(void) { Foo *f = [Foo new]; [f alpha]; return [f betaWith:1 and:2]; }
            """
            (file, flags) = ("t.m", ["-fobjc-arc", "-framework", "Foundation", "-O1"])
        case .objcDylib:
            source = """
            #import <Foundation/Foundation.h>
            @interface RoadmapWidget : NSObject - (void)spin; - (int)spinBy:(int)n; @end
            @implementation RoadmapWidget - (void)spin { [self spinBy:1]; } - (int)spinBy:(int)n { return n * 2; } @end
            """
            (file, flags) = ("w.m", ["-fobjc-arc", "-framework", "Foundation", "-O1", "-dynamiclib"])
        case .cExecutable:
            source = "int exported_fn(int x) { return x * 3; }\nint main(void) { return exported_fn(2); }\n"
            (file, flags) = ("e.c", ["-O1"])
        }
        let sourceURL = dir.appendingPathComponent(file)
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let binary = dir.appendingPathComponent("out")
        try run(xcrun, ["clang", "-arch", arch] + flags + ["-o", binary.path, sourceURL.path])
        if strip {
            try run(xcrun, ["strip", binary.path])
        }
        return binary
    }

    private static func run(_ tool: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let drain = CoreTestPipeDrain(pipe)
        process.waitUntilExit()
        let out = drain.text()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("\(arguments.first ?? "tool") failed on this host: \(out)")
        }
    }
}
