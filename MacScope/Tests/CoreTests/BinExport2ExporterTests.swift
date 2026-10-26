import XCTest
import Foundation

@testable import MacScope

/// Tests for the BinExport2Exporter. These tests build a synthetic snapshot,
/// export it using the exporter, then parse the resulting bytes back to ensure
/// that the structure round-trips. Parsing is done with a minimal proto3 reader.
final class BinExport2ExporterTests: XCTestCase {
    private func importSlot(_ address: UInt64, name: String, library: String = "libSystem",
                            local: Bool = false, kind: String = "symbolStub",
                            section: String = "__TEXT,__stubs", entrySize: UInt32 = 12) -> IndirectSymbolSummary {
        IndirectSymbolSummary(id: UUID(), kind: kind, sourceSection: section,
            address: address, entrySize: entrySize, tableIndex: 0, rawSymbolIndex: 0,
            symbolIndex: 0, symbolName: name, libraryOrdinal: 1, libraryName: library,
            isLocal: local, isAbsolute: false)
    }

    private func section(_ name: String, _ address: UInt64, size: UInt64 = 0x20,
                         fileOffset: UInt64? = nil, executable: Bool = true) -> SectionSummary {
        SectionSummary(id: UUID(), name: name, address: address, size: size,
                       fileOffset: fileOffset ?? address, isExecutable: executable)
    }

    /// Loader-shaped linkage layout: executable `__stubs` islands at every import address the
    /// fixtures use, an executable `__objc_stubs` section, and non-executable pointer sections.
    /// Section file offsets are identity-mapped into a 0x5000-byte `imageBytes`.
    private func linkageSections() -> [SectionSummary] {
        [section("__TEXT,__stubs", 0x0800), section("__TEXT,__stubs", 0x1800),
         section("__TEXT,__stubs", 0x3000), section("__TEXT,__objc_stubs", 0x3020),
         section("__DATA_CONST,__got", 0x4000, size: 0x40, executable: false),
         section("__DATA,__la_symbol_ptr", 0x4040, size: 0x20, executable: false),
         section("__DATA_CONST,__auth_got", 0x4060, size: 0x20, executable: false)]
    }

    private func edgeList(_ parsed: ParsedExport) -> [String] {
        parsed.callGraphEdges.map { "\($0.0):\($0.1)" }
    }

    private func callGraphFixture() -> WorkspaceSnapshot {
        var analysis = ImageAnalysis()
        analysis.functions = [
            FunctionSummary(id: UUID(), name: "caller", startAddress: 0x1000, endAddress: 0x1010, confidence: 1),
            FunctionSummary(id: UUID(), name: "lastTextFunction", startAddress: 0x2000, endAddress: 0x2010, confidence: 1),
        ]
        analysis.indirectSymbols = [importSlot(0x3000, name: "_printf"), importSlot(0x3010, name: "_puts")]
        analysis.sections = linkageSections()
        analysis.imageBytes = Data(count: 0x5000)
        analysis.xrefs = [
            XRef(id: UUID(), from: 0x1000, to: 0x3000, kind: XRefKind.call),
            XRef(id: UUID(), from: 0x1004, to: 0x3010, kind: XRefKind.call),
            XRef(id: UUID(), from: 0x1008, to: 0x2000, kind: XRefKind.call),
        ]
        return WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "imports", path: "/fixture", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis]
        )
    }

    private func interleavedCallGraphFixture() -> WorkspaceSnapshot {
        var snapshot = callGraphFixture()
        snapshot.indirectSymbols = [importSlot(0x3000, name: "_after"),
                                    importSlot(0x0800, name: "_before"),
                                    importSlot(0x1800, name: "_between")]
        snapshot.xrefs = [
            XRef(id: UUID(), from: 0x1000, to: 0x0800, kind: XRefKind.call),
            XRef(id: UUID(), from: 0x1004, to: 0x1800, kind: XRefKind.call),
            XRef(id: UUID(), from: 0x1008, to: 0x3000, kind: XRefKind.call),
            XRef(id: UUID(), from: 0x100c, to: 0x2000, kind: XRefKind.call),
            XRef(id: UUID(), from: 0x2000, to: 0x1000, kind: XRefKind.call),
            XRef(id: UUID(), from: 0x2004, to: 0x2000, kind: XRefKind.call),
        ]
        return snapshot
    }

    func testCompleteVertexOrderRemapsBothCallEndpointsForInterleavedImports() {
        var snapshot = interleavedCallGraphFixture()
        let bytes = BinExport2Exporter().export(snapshot)
        let parsed = Self.parseExport(data: bytes)
        // google/binexport binexport2.proto: vertex addresses ascend; edge fields
        // index that complete array. Hand-derived positions include all imports.
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x0800, 0x1000, 0x1800, 0x2000, 0x3000])
        XCTAssertEqual(parsed.callGraphVertices.map(\.type), [2, 0, 2, 0, 2])
        XCTAssertEqual(parsed.callGraphVertices.map(\.name), ["_before", "caller", "_between", "lastTextFunction", "_after"])
        XCTAssertEqual(parsed.callGraphEdges.map { "\($0.0):\($0.1)" }, ["1:0", "1:2", "1:3", "1:4", "3:1", "3:3"])
        snapshot.functions.reverse()
        snapshot.indirectSymbols.reverse()
        XCTAssertEqual(BinExport2Exporter().export(snapshot), bytes)
    }

    func testReusedImportStartAndVertexZeroRecursionSurviveCompleteOrdering() {
        var snapshot = interleavedCallGraphFixture()
        snapshot.functions.append(FunctionSummary(id: UUID(), name: "stub", startAddress: 0x0800, endAddress: 0x080c, confidence: 1))
        snapshot.xrefs.insert(XRef(id: UUID(), from: 0x0800, to: 0x0800, kind: XRefKind.call), at: 0)
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x0800, 0x1000, 0x1800, 0x2000, 0x3000])
        XCTAssertEqual(parsed.callGraphVertices.map(\.type), [2, 0, 2, 0, 2])
        XCTAssertEqual(parsed.callGraphVertices[0].name, "_before")
        XCTAssertEqual(parsed.callGraphEdges.map { "\($0.0):\($0.1)" }, ["0:0", "1:0", "1:2", "1:3", "1:4", "3:1", "3:3"])
    }

    func testCompleteCallGraphDecodesWithProtocSchema() throws {
        let protocPath = "/opt/homebrew/bin/protoc"
        guard FileManager.default.fileExists(atPath: protocPath) else {
            throw XCTSkip("protoc not installed")
        }
        let schemaURL: URL
        if let path = ProcessInfo.processInfo.environment["MACSCOPE_BINEXPORT2_PROTO"] {
            schemaURL = URL(fileURLWithPath: path)
        } else {
            schemaURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "binexport2", withExtension: "proto"))
        }
        let bytes = BinExport2Exporter().export(interleavedCallGraphFixture())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: protocPath)
        process.arguments = ["--decode=BinExport2", "--proto_path=\(schemaURL.deletingLastPathComponent().path)", schemaURL.lastPathComponent]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let outputDrain = CoreTestPipeDrain(output)
        let errorDrain = CoreTestPipeDrain(errors)
        try input.fileHandleForWriting.write(contentsOf: bytes)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let decoded = outputDrain.text()
        let stderr = errorDrain.text()
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        // Independent schema decoder returns these exact decimal addresses and
        // remapped indices. Compare the complete graph, including vertex zero.
        let graph = try XCTUnwrap(decoded.range(of: "call_graph {"))
        // The bundled schema is the full upstream proto2 (RX-04), which names
        // vertex type 2 IMPORTED. Normalize only that textual enum spelling.
        let decodedGraph = String(decoded[graph.lowerBound...])
            .replacingOccurrences(of: "type: IMPORTED", with: "type: 2")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(decodedGraph, """
        call_graph {
          vertex {
            address: 2048
            type: 2
            mangled_name: "_before"
            demangled_name: "_before"
          }
          vertex {
            address: 4096
            mangled_name: "caller"
            demangled_name: "caller"
          }
          vertex {
            address: 6144
            type: 2
            mangled_name: "_between"
            demangled_name: "_between"
          }
          vertex {
            address: 8192
            mangled_name: "lastTextFunction"
            demangled_name: "lastTextFunction"
          }
          vertex {
            address: 12288
            type: 2
            mangled_name: "_after"
            demangled_name: "_after"
          }
          edge {
            source_vertex_index: 1
            target_vertex_index: 0
          }
          edge {
            source_vertex_index: 1
            target_vertex_index: 2
          }
          edge {
            source_vertex_index: 1
            target_vertex_index: 3
          }
          edge {
            source_vertex_index: 1
            target_vertex_index: 4
          }
          edge {
            source_vertex_index: 3
            target_vertex_index: 1
          }
          edge {
            source_vertex_index: 3
            target_vertex_index: 3
          }
        }
        """)
    }

    func testImportCallsUseAddressedImportedVerticesInsteadOfLastTextFunction() {
        var snapshot = callGraphFixture()
        snapshot.imports = [ImportSummary(id: UUID(), name: "_unaddressed", libraryName: "libSystem", libraryOrdinal: 1)]
        snapshot.symbols = [SymbolSummary(id: UUID(), name: "_objc_msgSend$length", address: 0x3020, kind: "stub", libraryName: nil)]
        snapshot.xrefs.append(XRef(id: UUID(), from: 0x100c, to: 0x3020, kind: XRefKind.call))
        let bytes = BinExport2Exporter().export(snapshot)
        let parsed = Self.parseExport(data: bytes)
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x1000, 0x2000, 0x3000, 0x3010, 0x3020])
        // The selector stub is THUNK (3), not IMPORTED (2): it forwards inside this image.
        XCTAssertEqual(parsed.callGraphVertices.map(\.type), [0, 0, 2, 2, 3])
        XCTAssertEqual(parsed.callGraphVertices.map(\.name), ["caller", "lastTextFunction", "_printf", "_puts", "_objc_msgSend$length"])
        XCTAssertEqual(parsed.callGraphEdges.map { "\($0.0):\($0.1)" }, ["0:1", "0:2", "0:3", "0:4"])
        snapshot.indirectSymbols.reverse()
        XCTAssertEqual(BinExport2Exporter().export(snapshot), bytes)
    }

    func testUnknownGapAndAmbiguousCallEndpointsAbstain() {
        var snapshot = callGraphFixture()
        snapshot.xrefs += [
            XRef(id: UUID(), from: 0x1000, to: 0x1010, kind: XRefKind.call), // half-open end
            XRef(id: UUID(), from: 0x1000, to: 0x1800, kind: XRefKind.call), // gap
            XRef(id: UUID(), from: 0x1000, to: 0x9999, kind: XRefKind.call), // beyond last function
            XRef(id: UUID(), from: 0x1800, to: 0x3000, kind: XRefKind.call), // unowned caller
        ]
        XCTAssertEqual(Self.parseExport(data: BinExport2Exporter().export(snapshot)).callGraphEdges.count, 3)
        snapshot.functions.append(FunctionSummary(id: UUID(), name: "overlap", startAddress: 0x1004, endAddress: 0x100c, confidence: 1))
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(parsed.callGraphEdges.count, 1) // only the uniquely owned call at 0x1000
        XCTAssertEqual(parsed.callGraphVertices[Int(parsed.callGraphEdges[0].1)].address, 0x3000)
    }

    func testConflictingImportIdentityAndLocalSlotsDoNotCreateCallees() {
        var snapshot = callGraphFixture()
        snapshot.indirectSymbols += [importSlot(0x3000, name: "_printf", library: "otherLibrary"),
                                     importSlot(0x4000, name: "local", local: true)]
        snapshot.xrefs.append(XRef(id: UUID(), from: 0x100c, to: 0x4000, kind: XRefKind.call))
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x1000, 0x2000, 0x3010])
        XCTAssertEqual(parsed.callGraphEdges.map { "\($0.0):\($0.1)" }, ["0:1", "0:2"])
    }

    func testExplicitImageExportDoesNotJoinEqualAddressesAcrossSlots() throws {
        var snapshot = callGraphFixture()
        let slot = ImageSlot(rawValue: 1)
        snapshot.binaries.append(BinaryImage(id: UUID(), name: "second", path: "/second", kind: "Mach-O", architecture: "arm64", slot: slot))
        var second = try XCTUnwrap(snapshot.analysis(in: .primary))
        second.functions[0].name = "secondCaller"
        second.indirectSymbols = [importSlot(0x0800, name: "_secondBefore"), importSlot(0x3000, name: "_secondImport")]
        second.xrefs = [XRef(id: UUID(), from: 0x1000, to: 0x3000, kind: XRefKind.call),
                        XRef(id: UUID(), from: 0x2000, to: 0x0800, kind: XRefKind.call)]
        snapshot.analysisBySlot[slot] = second
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot, in: slot))
        XCTAssertEqual(parsed.callGraphVertices.map(\.name), ["_secondBefore", "secondCaller", "lastTextFunction", "_secondImport"])
        XCTAssertEqual(parsed.callGraphEdges.map { "\($0.0):\($0.1)" }, ["1:3", "2:0"])
        XCTAssertEqual(Self.parseExport(data: BinExport2Exporter().export(snapshot)).callGraphEdges.count, 3)
    }

    func testImportAtExistingFunctionStartReusesVertexWithoutDuplicateAddress() {
        var snapshot = callGraphFixture()
        snapshot.functions.append(FunctionSummary(id: UUID(), name: "stub", startAddress: 0x3000, endAddress: 0x300c, confidence: 1))
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x1000, 0x2000, 0x3000, 0x3010])
        XCTAssertEqual(parsed.callGraphVertices[2].type, 2)
        XCTAssertEqual(parsed.callGraphVertices[2].name, "_printf")
        XCTAssertEqual(parsed.callGraphEdges.map { "\($0.0):\($0.1)" }, ["0:1", "0:2", "0:3"])
    }

    func testDataPointerIdentitiesAreNeverCallableVerticesOrCallTargets() {
        var snapshot = callGraphFixture()
        // GOT / lazy / authenticated pointer slots name imports but hold DATA. The loader also
        // labels them with derived "stub" symbols; neither source may become forwarding code.
        snapshot.indirectSymbols += [
            importSlot(0x4000, name: "_malloc", kind: "nonLazySymbolPointer", section: "__DATA_CONST,__got", entrySize: 8),
            importSlot(0x4040, name: "_free", kind: "lazySymbolPointer", section: "__DATA,__la_symbol_ptr", entrySize: 8),
            importSlot(0x4060, name: "_strlen", kind: "nonLazySymbolPointer", section: "__DATA_CONST,__auth_got", entrySize: 8),
            // A pointer section row whose declared kind claims a stub is still data.
            importSlot(0x4008, name: "_calloc", kind: "symbolStub", section: "__DATA_CONST,__got", entrySize: 8),
        ]
        snapshot.symbols = [
            SymbolSummary(id: UUID(), name: "_malloc", address: 0x4000, kind: "stub", libraryName: nil),
            SymbolSummary(id: UUID(), name: "_realloc", address: 0x4010, kind: "stub", libraryName: nil),
        ]
        // A function range spanning the pointer slots must not absorb those call targets.
        snapshot.functions.append(FunctionSummary(id: UUID(), name: "spansPointers", startAddress: 0x3f00, endAddress: 0x4080, confidence: 1))
        snapshot.xrefs += ([0x4000, 0x4008, 0x4010, 0x4040, 0x4060] as [UInt64]).map {
            XRef(id: UUID(), from: 0x100c, to: $0, kind: XRefKind.call)
        }
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x1000, 0x2000, 0x3000, 0x3010, 0x3f00])
        XCTAssertEqual(parsed.callGraphVertices.map(\.type), [0, 0, 2, 2, 0])
        XCTAssertFalse(parsed.callGraphVertices.contains { ["_malloc", "_free", "_strlen", "_calloc", "_realloc"].contains($0.name) })
        XCTAssertEqual(edgeList(parsed), ["0:1", "0:2", "0:3"])
    }

    func testLinkageEndpointOutsideExecutableSectionOrFileExtentAbstains() {
        var snapshot = callGraphFixture()
        snapshot.sections += [
            section("__TEXT,__stubs", 0x6000, fileOffset: 0x10000),            // file bytes beyond imageBytes
            section("__TEXT,__stubs", 0x6100, executable: false),              // not executable
            section("__TEXT,__stubs", 0x6200, size: 0x20),                     // entry crosses section end
            section("__TEXT,__stubs", 0x6300, executable: true),               // overlapping declarations
            section("__TEXT,__text", 0x6300, size: 0x40),
        ]
        snapshot.indirectSymbols += [
            importSlot(0x6000, name: "_beyondFile"),
            importSlot(0x6100, name: "_notExecutable"),
            importSlot(0x6218, name: "_crossesEnd"),
            importSlot(0x6300, name: "_overlapped"),
            importSlot(0x6400, name: "_noSection"),
            importSlot(0x3018, name: "_wrongKind", kind: "lazySymbolPointer"),
            importSlot(0x0800, name: "_sectionMismatch", section: "__TEXT,__auth_stubs"),
        ]
        snapshot.xrefs += ([0x6000, 0x6100, 0x6218, 0x6300, 0x6400, 0x3018, 0x0800] as [UInt64]).map {
            XRef(id: UUID(), from: 0x100c, to: $0, kind: XRefKind.call)
        }
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x1000, 0x2000, 0x3000, 0x3010])
        XCTAssertEqual(edgeList(parsed), ["0:1", "0:2", "0:3"])
        // No section evidence at all (e.g. a reload without derived sections) abstains too.
        snapshot.sections = []
        let unsectioned = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(unsectioned.callGraphVertices.map(\.address), [0x1000, 0x2000])
        XCTAssertEqual(edgeList(unsectioned), ["0:1"])
    }

    func testLinkageEntrySuffixOverlapAbstainsButAdjacentSectionDoesNot() {
        var overlapping = callGraphFixture()
        // The stub begins uniquely in __stubs, but four bytes of its 12-byte entry
        // are also declared data. Neither a callable vertex nor its edge is justified.
        overlapping.sections.append(section("__DATA,__suffix", 0x3004, size: 4, executable: false))
        let rejected = Self.parseExport(data: BinExport2Exporter().export(overlapping))
        XCTAssertEqual(rejected.callGraphVertices.map(\.address), [0x1000, 0x2000, 0x3010])
        XCTAssertEqual(edgeList(rejected), ["0:1", "0:2"])

        var adjacent = callGraphFixture()
        // Half-open extents permit a section beginning exactly after the entry.
        adjacent.sections.append(section("__DATA,__adjacent", 0x300c, size: 4, executable: false))
        let admitted = Self.parseExport(data: BinExport2Exporter().export(adjacent))
        XCTAssertEqual(admitted.callGraphVertices.map(\.address), [0x1000, 0x2000, 0x3000, 0x3010])
        XCTAssertEqual(edgeList(admitted), ["0:1", "0:2", "0:3"])
    }

    func testExecutableImportStubKeepsItsImportIdentity() {
        var snapshot = callGraphFixture()
        snapshot.indirectSymbols.append(importSlot(0x1800, name: "_objc_retain", library: "libobjc",
                                                   section: "__TEXT,__auth_stubs", entrySize: 16))
        snapshot.sections.append(section("__TEXT,__auth_stubs", 0x1800))
        snapshot.sections.removeAll { $0.address == 0x1800 && $0.name == "__TEXT,__stubs" }
        // The engine's derived stub label agrees with the indirect row and changes nothing.
        snapshot.symbols = [SymbolSummary(id: UUID(), name: "_printf", address: 0x3000, kind: "stub", libraryName: nil)]
        snapshot.xrefs.append(XRef(id: UUID(), from: 0x100c, to: 0x1800, kind: XRefKind.call))
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x1000, 0x1800, 0x2000, 0x3000, 0x3010])
        XCTAssertEqual(parsed.callGraphVertices.map(\.type), [0, 2, 0, 2, 2])
        XCTAssertEqual(parsed.callGraphVertices.map(\.name), ["caller", "_objc_retain", "lastTextFunction", "_printf", "_puts"])
        XCTAssertEqual(edgeList(parsed), ["0:1", "0:2", "0:3", "0:4"])
        // A disagreeing derived label is a conflicting identity: the stub abstains.
        snapshot.symbols = [SymbolSummary(id: UUID(), name: "_other", address: 0x3000, kind: "stub", libraryName: nil)]
        let conflicted = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(conflicted.callGraphVertices.map(\.address), [0x1000, 0x1800, 0x2000, 0x3010])
        XCTAssertEqual(edgeList(conflicted), ["0:1", "0:2", "0:3"])
    }

    func testObjectiveCSelectorStubIsThunkNeverImported() {
        var snapshot = callGraphFixture()
        snapshot.symbols = [
            SymbolSummary(id: UUID(), name: "_objc_msgSend$count", address: 0x3020, kind: "stub", libraryName: nil),
            // Selector-stub label outside __objc_stubs: unproven code identity, abstain.
            SymbolSummary(id: UUID(), name: "_objc_msgSend$stray", address: 0x2008, kind: "stub", libraryName: nil),
        ]
        snapshot.sections.append(section("__TEXT,__text", 0x2000, size: 0x10))
        // An indirect import row spelled as a selector stub is never an IMPORTED vertex.
        snapshot.indirectSymbols.append(importSlot(0x1800, name: "_objc_msgSend$bogus"))
        snapshot.xrefs += ([0x3020, 0x2008, 0x1800] as [UInt64]).map {
            XRef(id: UUID(), from: 0x100c, to: $0, kind: XRefKind.call)
        }
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x1000, 0x2000, 0x3000, 0x3010, 0x3020])
        XCTAssertEqual(parsed.callGraphVertices.map(\.type), [0, 0, 2, 2, 3])
        XCTAssertEqual(parsed.callGraphVertices[4].name, "_objc_msgSend$count")
        XCTAssertFalse(parsed.callGraphVertices.contains { $0.name.hasPrefix("_objc_msgSend$") && $0.type == 2 })
        // Only the validated selector stub gains an edge; 0x2008 and 0x1800 abstain.
        XCTAssertEqual(edgeList(parsed), ["0:1", "0:2", "0:3", "0:4"])
    }

    func testDuplicateCallsEmitOneEdgeInSortedOrderIndependentOfXrefOrder() {
        var snapshot = interleavedCallGraphFixture()
        // Repeat every call from different call sites and in reverse order.
        snapshot.xrefs += snapshot.xrefs.reversed().map {
            XRef(id: UUID(), from: $0.from + 2, to: $0.to, kind: XRefKind.call)
        }
        snapshot.xrefs += snapshot.xrefs
        let bytes = BinExport2Exporter().export(snapshot)
        let parsed = Self.parseExport(data: bytes)
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x0800, 0x1000, 0x1800, 0x2000, 0x3000])
        XCTAssertEqual(edgeList(parsed), ["1:0", "1:2", "1:3", "1:4", "3:1", "3:3"])
        snapshot.xrefs.shuffle()
        XCTAssertEqual(BinExport2Exporter().export(snapshot), bytes)
        XCTAssertEqual(BinExport2Exporter().export(interleavedCallGraphFixture()), bytes)
    }

    func testLargeBlockIndexPreservesHalfOpenRangesAndFunctionGroups() {
        var snapshot = callGraphFixture()
        snapshot.functions = (0..<2000).map { index in
            let start = UInt64(0x1000 + index * 16)
            return FunctionSummary(id: UUID(), name: "f\(index)", startAddress: start, endAddress: start + 8, confidence: 1)
        }
        snapshot.basicBlocks = snapshot.functions.map {
            BasicBlockSummary(id: UUID(), functionID: $0.id, startAddress: $0.startAddress, endAddress: $0.endAddress, instructionCount: 2)
        }
        snapshot.instructions = snapshot.functions.flatMap { function in
            [function.startAddress, function.startAddress + 4, function.endAddress].map {
                InstructionRow(address: $0, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil)
            }
        }
        snapshot.xrefs = []
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(parsed.basicBlockRanges.count, 2000)
        XCTAssertEqual(parsed.flowGraphBlocks, (0..<2000).map { [$0] })
        XCTAssertTrue(parsed.basicBlockRanges.allSatisfy { $0.1 - $0.0 == 2 })
        XCTAssertEqual(parsed.basicBlockRanges.last?.0, 5997)
        XCTAssertEqual(parsed.basicBlockRanges.last?.1, 5999)
    }

    func testSerializedFlowEdgesPreserveKindsAndExcludeRecursiveCalls() {
        let functionID = UUID()
        let ranges: [(UInt64, UInt64)] = [(0x1000, 0x1008), (0x1008, 0x100c),
                                         (0x100c, 0x1010), (0x1010, 0x1018)]
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "edges", path: "/fixture", kind: "Mach-O", architecture: "arm64")],
            functions: [FunctionSummary(id: functionID, name: "recursive", startAddress: 0x1000,
                                        endAddress: 0x1018, confidence: 1)],
            basicBlocks: ranges.map { BasicBlockSummary(id: UUID(), functionID: functionID,
                startAddress: $0.0, endAddress: $0.1, instructionCount: Int(($0.1 - $0.0) / 4)) },
            instructions: stride(from: UInt64(0x1000), to: 0x1018, by: 4).map {
                InstructionRow(address: $0, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "",
                               hasBreakpoint: false, comment: nil)
            },
            xrefs: [XRef(id: UUID(), from: 0x1010, to: 0x1000, kind: XRefKind.call)],
            controlFlowEdges: [
                ControlFlowEdge(id: UUID(), from: 0x1004, to: 0x100c, kind: "branch"),
                ControlFlowEdge(id: UUID(), from: 0x1004, to: 0x1008, kind: "fallthrough"),
                ControlFlowEdge(id: UUID(), from: 0x1008, to: 0x1010, kind: "branch"),
                ControlFlowEdge(id: UUID(), from: 0x100c, to: 0x1010, kind: "switch"),
                ControlFlowEdge(id: UUID(), from: 0x1010, to: 0x1000, kind: "call"),
            ], hexBytes: Data()
        )
        let bytes = BinExport2Exporter().export(snapshot)
        var reader = ProtoReader(data: bytes)
        var types: [UInt64] = []
        while let (field, wire) = reader.nextTag() {
            guard field == 7, wire == 2 else { reader.skipField(wireType: wire); continue }
            var graph = ProtoReader(data: reader.readLengthDelimited())
            while let (graphField, graphWire) = graph.nextTag() {
                guard graphField == 2, graphWire == 2 else { graph.skipField(wireType: graphWire); continue }
                var edge = ProtoReader(data: graph.readLengthDelimited())
                var type: UInt64 = 3 // BinExport2's proto default is UNCONDITIONAL (= 3).
                while let (edgeField, edgeWire) = edge.nextTag() {
                    if edgeField == 3, edgeWire == 0 { type = edge.readVarint().0 }
                    else { edge.skipField(wireType: edgeWire) }
                }
                types.append(type)
            }
        }
        // binexport2.proto: CONDITION_TRUE = 1, CONDITION_FALSE = 2, UNCONDITIONAL = 3, SWITCH = 4.
        XCTAssertEqual(types, [1, 2, 3, 4])
        XCTAssertEqual(Self.parseExport(data: bytes).callGraphEdges.count, 1)
    }

    // MARK: - Forwarding thunks
    //
    // Encodings below are little-endian AArch64 words, cross-checked by assembling the same
    // instructions with clang (-arch arm64e) and disassembling with objdump at these addresses:
    //   0x2800  17fffe00  b 0x2000            0x2800  17fffa02  b 0x1008
    //   0x2800  14000200  b 0x3000            0x2808  17fffdfe  b 0x2000
    //   0x2804  17fffdff  b 0x2000            0x2800  14000000  b 0x2800 (self)
    //   0x2900  14000200  b 0x3100
    //   d503201f nop     d503245f bti c (decoder: "hint #34")    d2800020 mov x0, #1
    //   d0000010 adrp x16, page+2 (0x4000 from 0x2800/0x2900)    d0000011 adrp x17, (same)
    //   f9400610 ldr x16, [x16, #8]   f9400a10 ldr x16, [x16, #16]   f9400230 ldr x16, [x17]
    //   91002231 add x17, x17, #8     d61f0200 br x16                d71f0a11 braa x16, x17

    private func forwardingFunction(_ name: String, at start: UInt64,
                                    _ code: [(bytes: String, mnemonic: String)]) -> (FunctionSummary, [InstructionRow]) {
        let function = FunctionSummary(id: UUID(), name: name, startAddress: start,
                                       endAddress: start + UInt64(code.count * 4), confidence: 1)
        let rows = code.enumerated().map {
            InstructionRow(address: start + UInt64($0.offset * 4), bytes: $0.element.bytes,
                           mnemonic: $0.element.mnemonic, operands: "", hasBreakpoint: false, comment: nil)
        }
        return (function, rows)
    }

    private func addForwarding(_ snapshot: inout WorkspaceSnapshot, _ name: String, at start: UInt64,
                               _ code: [(bytes: String, mnemonic: String)]) {
        let (function, rows) = forwardingFunction(name, at: start, code)
        snapshot.functions.append(function)
        snapshot.instructions += rows
    }

    func testSingleBranchFunctionIsThunkWithEdgeToTarget() {
        var snapshot = callGraphFixture()
        addForwarding(&snapshot, "forward", at: 0x2800, [("00 fe ff 17", "b")])          // b 0x2000
        let bytes = BinExport2Exporter().export(snapshot)
        let parsed = Self.parseExport(data: bytes)
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x1000, 0x2000, 0x2800, 0x3000, 0x3010])
        XCTAssertEqual(parsed.callGraphVertices.map(\.type), [0, 0, 3, 2, 2])
        XCTAssertEqual(parsed.callGraphVertices[2].name, "forward")
        // The forwarding relation is the thunk's one call edge, in sorted, deduplicated order.
        XCTAssertEqual(edgeList(parsed), ["0:1", "0:3", "0:4", "2:1"])
        snapshot.functions.reverse()
        snapshot.instructions.reverse()
        XCTAssertEqual(BinExport2Exporter().export(snapshot), bytes)

        // Stack-neutral no-ops (nop, bti c) before the branch.
        var padded = callGraphFixture()
        addForwarding(&padded, "padded", at: 0x2800,
                      [("1f 20 03 d5", "nop"), ("5f 24 03 d5", "hint"), ("fe fd ff 17", "b")])  // b 0x2000
        // The same word at 0x2900 targets 0x3100, which is no function start or stub: NORMAL.
        addForwarding(&padded, "nowhere", at: 0x2900, [("00 02 00 14", "b")])                   // b 0x3100
        let paddedParsed = Self.parseExport(data: BinExport2Exporter().export(padded))
        XCTAssertEqual(paddedParsed.callGraphVertices.map(\.address), [0x1000, 0x2000, 0x2800, 0x2900, 0x3000, 0x3010])
        XCTAssertEqual(paddedParsed.callGraphVertices.map(\.type), [0, 0, 3, 0, 2, 2])
        XCTAssertEqual(edgeList(paddedParsed), ["0:1", "0:4", "0:5", "2:1"])

        var toStub = callGraphFixture()
        addForwarding(&toStub, "toImport", at: 0x2800, [("00 02 00 14", "b")])                  // b 0x3000 (_printf stub)
        let stubParsed = Self.parseExport(data: BinExport2Exporter().export(toStub))
        XCTAssertEqual(stubParsed.callGraphVertices.map(\.type), [0, 0, 3, 2, 2])
        XCTAssertEqual(edgeList(stubParsed), ["0:1", "0:3", "0:4", "2:3"])
    }

    func testGOTTrampolineIsThunkWithImportTarget() {
        var snapshot = callGraphFixture()
        // The GOT slot names the same import (name, library, ordinal) as the admitted
        // `__stubs` vertex at 0x3000; the slot itself stays data, never a vertex.
        snapshot.indirectSymbols.append(importSlot(0x4008, name: "_printf", kind: "nonLazySymbolPointer",
                                                   section: "__DATA_CONST,__got", entrySize: 8))
        addForwarding(&snapshot, "trampoline", at: 0x2800,
                      [("10 00 00 d0", "adrp"), ("10 06 40 f9", "ldr"), ("00 02 1f d6", "br")])
        // arm64e authenticated form: adrp x17; add x17, x17, #8; ldr x16, [x17]; braa x16, x17.
        addForwarding(&snapshot, "authTrampoline", at: 0x2900,
                      [("11 00 00 d0", "adrp"), ("31 22 00 91", "add"), ("30 02 40 f9", "ldr"), ("11 0a 1f d7", "braa")])
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x1000, 0x2000, 0x2800, 0x2900, 0x3000, 0x3010])
        XCTAssertEqual(parsed.callGraphVertices.map(\.type), [0, 0, 3, 3, 2, 2])
        XCTAssertEqual(edgeList(parsed), ["0:1", "0:4", "0:5", "2:4", "3:4"])
    }

    func testGOTTrampolineRejectsIncompleteOrOverlappingPointerWord() throws {
        for malformed in ["short-file-span", "overlapping-section"] {
            var snapshot = callGraphFixture()
            snapshot.indirectSymbols.append(importSlot(0x4008, name: "_printf", kind: "nonLazySymbolPointer",
                                                       section: "__DATA_CONST,__got", entrySize: 8))
            addForwarding(&snapshot, "trampoline", at: 0x2800,
                          [("10 00 00 d0", "adrp"), ("10 06 40 f9", "ldr"), ("00 02 1f d6", "br")])
            if malformed == "short-file-span" {
                let index = try XCTUnwrap(snapshot.sections.firstIndex { $0.name == "__DATA_CONST,__got" })
                snapshot.sections[index].fileSize = 12
            } else {
                snapshot.sections.append(section("__DATA,__late", 0x400c, size: 8, fileOffset: 0x400c,
                                                  executable: false))
            }

            let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
            XCTAssertEqual(parsed.callGraphVertices.first { $0.address == 0x2800 }?.type, 0, malformed)
            XCTAssertFalse(edgeList(parsed).contains("2:4"), malformed)
        }
    }

    func testForwardingFunctionWithSideEffectOrUnresolvedSlotStaysNormal() {
        var snapshot = callGraphFixture()
        // mov x0, #1 changes an argument register before forwarding: not a thunk.
        addForwarding(&snapshot, "sideEffect", at: 0x2800, [("20 00 80 d2", "mov"), ("ff fd ff 17", "b")])
        // A GOT slot whose import has no admitted vertex: the target is unresolved.
        snapshot.indirectSymbols.append(importSlot(0x4010, name: "_malloc", kind: "nonLazySymbolPointer",
                                                   section: "__DATA_CONST,__got", entrySize: 8))
        addForwarding(&snapshot, "unresolvedSlot", at: 0x2900,
                      [("10 00 00 d0", "adrp"), ("10 0a 40 f9", "ldr"), ("00 02 1f d6", "br")])
        // Row text that disagrees with its encoding is inconsistent evidence.
        addForwarding(&snapshot, "mislabelled", at: 0x2a00, [("00 fe ff 17", "nop")])
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x1000, 0x2000, 0x2800, 0x2900, 0x2a00, 0x3000, 0x3010])
        XCTAssertEqual(parsed.callGraphVertices.map(\.type), [0, 0, 0, 0, 0, 2, 2])
        XCTAssertEqual(edgeList(parsed), ["0:1", "0:5", "0:6"])
    }

    func testBranchToNonFunctionAddressStaysNormal() {
        var snapshot = callGraphFixture()
        addForwarding(&snapshot, "intoBody", at: 0x2800, [("02 fa ff 17", "b")])  // b 0x1008: inside caller
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(parsed.callGraphVertices.map(\.type), [0, 0, 0, 2, 2])
        XCTAssertEqual(edgeList(parsed), ["0:1", "0:3", "0:4"])

        var selfLoop = callGraphFixture()
        addForwarding(&selfLoop, "spin", at: 0x2800, [("00 00 00 14", "b")])        // b . (own extent)
        let selfParsed = Self.parseExport(data: BinExport2Exporter().export(selfLoop))
        XCTAssertEqual(selfParsed.callGraphVertices.map(\.type), [0, 0, 0, 2, 2])
        XCTAssertEqual(edgeList(selfParsed), ["0:1", "0:3", "0:4"])
    }

    func testNamedSelectorStubInObjCStubsSectionIsThunk() {
        var snapshot = callGraphFixture()
        // Unstripped binary: the loader carries a real local symbol, so no derived "stub"
        // label exists. Section membership, not symbol origin, makes it a selector stub.
        snapshot.symbols = [SymbolSummary(id: UUID(), name: "_objc_msgSend$count", address: 0x3020,
                                          kind: "local", libraryName: nil, rawLinkageName: "_objc_msgSend$count")]
        // A discovered function covering one second-section entry, with no symbol at all.
        snapshot.sections.append(section("__TEXT,__objc_stubs", 0x3800, size: 0x40))
        snapshot.functions.append(FunctionSummary(id: UUID(), name: "sub_3800", startAddress: 0x3800,
                                                  endAddress: 0x3820, confidence: 1))
        snapshot.xrefs += ([0x3020, 0x3800] as [UInt64]).map {
            XRef(id: UUID(), from: 0x100c, to: $0, kind: XRefKind.call)
        }
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertEqual(parsed.callGraphVertices.map(\.address), [0x1000, 0x2000, 0x3000, 0x3010, 0x3020, 0x3800])
        XCTAssertEqual(parsed.callGraphVertices.map(\.type), [0, 0, 2, 2, 3, 3])
        XCTAssertEqual(parsed.callGraphVertices[4].name, "_objc_msgSend$count")
        XCTAssertEqual(edgeList(parsed), ["0:1", "0:2", "0:3", "0:4", "0:5"])
    }

    /// A minimal proto3 reader for testing. Supports varint and length-delimited fields.
    struct ProtoReader {
        let data: Data
        var index: Int = 0

        /// Reads the next field tag, returning (fieldNumber, wireType), or nil when
        /// at end of data.
        mutating func nextTag() -> (Int, Int)? {
            guard index < data.count else { return nil }
            let (key, _) = readVarint()
            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 0x7)
            return (fieldNumber, wireType)
        }

        /// Reads a varint and returns its value and the number of bytes consumed.
        @discardableResult
        mutating func readVarint() -> (UInt64, Int) {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            var bytesRead = 0
            while index < data.count {
                let byte = data[index]
                index += 1
                bytesRead += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            return (result, bytesRead)
        }

        /// Reads a length-delimited field and returns the bytes.
        mutating func readLengthDelimited() -> Data {
            let (len, _) = readVarint()
            guard len > 0, index + Int(len) <= data.count else { return Data() }
            let start = index
            let end = index + Int(len)
            index = end
            return data.subdata(in: start..<end)
        }

        /// Skips a field of the given wire type.
        mutating func skipField(wireType: Int) {
            switch wireType {
            case 0:
                _ = readVarint()
            case 1:
                // 64-bit fixed
                index += 8
            case 2:
                let (len, _) = readVarint()
                index += Int(len)
            case 5:
                // 32-bit fixed
                index += 4
            default:
                break
            }
        }
    }

    /// Parses the top-level BinExport2 message for test purposes.
    struct ParsedExport {
        struct ParsedExpression {
            var type: Int32
            var symbol: String
            var immediate: UInt64
            var parentIndex: Int32?
        }
        var mnemonics: [String] = []
        // Expressions table (field 2)
        var expressions: [ParsedExpression] = []
        // Operand table: each operand is a list of expression indices (field 3)
        var operands: [[Int32]] = []
        // Instruction table: each instruction includes its operand indices
        var instructions: [(address: UInt64, bytes: Data, mnemonicIndex: Int32, operandIndices: [Int32])] = []
        var callGraphEdges: [(Int32, Int32)] = []
        var callGraphVertices: [(address: UInt64, type: UInt64, name: String)] = []
        var basicBlockRanges: [(Int, Int)] = []
        var flowGraphBlocks: [[Int]] = []
    }

    /// Reads a BinExport2 message and extracts the mnemonics, instructions,
    /// and call graph edges for verification.
    static func parseExport(data: Data) -> ParsedExport {
        var reader = ProtoReader(data: data)
        var result = ParsedExport()
        while let (fieldNumber, wireType) = reader.nextTag() {
            switch fieldNumber {
            case 2: // expression messages (BinExport2.expression = 2)
                let exprData = reader.readLengthDelimited()
                var exprReader = ProtoReader(data: exprData)
                var type: Int32 = 2 // default IMMEDIATE_INT
                var symbol: String = ""
                var immediate: UInt64 = 0
                var parent: Int32? = nil
                while let (fNum, fType) = exprReader.nextTag() {
                    switch fNum {
                    case 1: // type
                        let (val, _) = exprReader.readVarint()
                        type = Int32(bitPattern: UInt32(val))
                    case 2: // symbol
                        let nameData = exprReader.readLengthDelimited()
                        symbol = String(data: nameData, encoding: .utf8) ?? ""
                    case 3: // immediate
                        let (val, _) = exprReader.readVarint()
                        immediate = val
                    case 4: // parent_index
                        let (val, _) = exprReader.readVarint()
                        parent = Int32(bitPattern: UInt32(val))
                    default:
                        exprReader.skipField(wireType: fType)
                    }
                }
                result.expressions.append(.init(type: type, symbol: symbol, immediate: immediate, parentIndex: parent))
            case 3: // operand messages (BinExport2.operand = 3)
                let opData = reader.readLengthDelimited()
                var opReader = ProtoReader(data: opData)
                var exprIndices: [Int32] = []
                while let (fNum, fType) = opReader.nextTag() {
                    if fNum == 1 {
                        let (val, _) = opReader.readVarint()
                        exprIndices.append(Int32(bitPattern: UInt32(val)))
                    } else {
                        opReader.skipField(wireType: fType)
                    }
                }
                result.operands.append(exprIndices)
            case 4: // mnemonic messages (BinExport2.mnemonic = 4)
                let msgData = reader.readLengthDelimited()
                // parse Mnemonic message: field 1 string
                var msgReader = ProtoReader(data: msgData)
                while let (fNum, fType) = msgReader.nextTag() {
                    if fNum == 1 && fType == 2 {
                        let nameData = msgReader.readLengthDelimited()
                        if let name = String(data: nameData, encoding: .utf8) {
                            result.mnemonics.append(name)
                        }
                    } else {
                        msgReader.skipField(wireType: fType)
                    }
                }
            case 5: // instruction messages (BinExport2.instruction = 5)
                let msgData = reader.readLengthDelimited()
                var msgReader = ProtoReader(data: msgData)
                var addr: UInt64 = 0
                var raw: Data = Data()
                var mIndex: Int32 = 0
                var operandIndices: [Int32] = []
                while let (fNum, fType) = msgReader.nextTag() {
                    switch fNum {
                    case 1: // address
                        let (value, _) = msgReader.readVarint()
                        addr = value
                    case 3: // mnemonic_index
                        let (value, _) = msgReader.readVarint()
                        mIndex = Int32(bitPattern: UInt32(value))
                    case 4: // operand_index (repeated int32)
                        let (val, _) = msgReader.readVarint()
                        operandIndices.append(Int32(bitPattern: UInt32(val)))
                    case 5: // raw_bytes
                        raw = msgReader.readLengthDelimited()
                    default:
                        msgReader.skipField(wireType: fType)
                    }
                }
                result.instructions.append((addr, raw, mIndex, operandIndices))
            case 6:
                var blockReader = ProtoReader(data: reader.readLengthDelimited())
                while let (field, wire) = blockReader.nextTag() {
                    guard field == 1 else { blockReader.skipField(wireType: wire); continue }
                    var rangeReader = ProtoReader(data: blockReader.readLengthDelimited())
                    var begin = 0
                    var end = 0
                    while let (rangeField, rangeWire) = rangeReader.nextTag() {
                        if rangeField == 1 { begin = Int(rangeReader.readVarint().0) }
                        else if rangeField == 2 { end = Int(rangeReader.readVarint().0) }
                        else { rangeReader.skipField(wireType: rangeWire) }
                    }
                    result.basicBlockRanges.append((begin, end))
                }
            case 7:
                var graphReader = ProtoReader(data: reader.readLengthDelimited())
                var blocks: [Int] = []
                while let (field, wire) = graphReader.nextTag() {
                    if field == 1 { blocks.append(Int(graphReader.readVarint().0)) }
                    else { graphReader.skipField(wireType: wire) }
                }
                result.flowGraphBlocks.append(blocks)
            case 8: // call_graph (BinExport2.call_graph = 8)
                let callGraphData = reader.readLengthDelimited()
                var cgReader = ProtoReader(data: callGraphData)
                while let (cgField, cgType) = cgReader.nextTag() {
                    if cgField == 1 {
                        var vertexReader = ProtoReader(data: cgReader.readLengthDelimited())
                        var address: UInt64 = 0
                        var type: UInt64 = 0
                        var name = ""
                        while let (field, wire) = vertexReader.nextTag() {
                            if field == 1 { address = vertexReader.readVarint().0 }
                            else if field == 2 { type = vertexReader.readVarint().0 }
                            else if field == 3 { name = String(decoding: vertexReader.readLengthDelimited(), as: UTF8.self) }
                            else { vertexReader.skipField(wireType: wire) }
                        }
                        result.callGraphVertices.append((address, type, name))
                    } else if cgField == 2 { // edges list
                        let edgeData = cgReader.readLengthDelimited()
                        var edgeReader = ProtoReader(data: edgeData)
                        var srcIdx: Int32 = 0
                        var dstIdx: Int32 = 0
                        while let (eField, eType) = edgeReader.nextTag() {
                            switch eField {
                            case 1:
                                let (val, _) = edgeReader.readVarint()
                                srcIdx = Int32(bitPattern: UInt32(val))
                            case 2:
                                let (val, _) = edgeReader.readVarint()
                                dstIdx = Int32(bitPattern: UInt32(val))
                            default:
                                edgeReader.skipField(wireType: eType)
                            }
                        }
                        result.callGraphEdges.append((srcIdx, dstIdx))
                    } else {
                        cgReader.skipField(wireType: cgType)
                    }
                }
            default:
                // skip unhandled top-level fields
                reader.skipField(wireType: wireType)
            }
        }
        return result
    }

    /// Tests that a synthetic snapshot exports correctly and round-trips via the parser.
    func testRoundTripExport() {
        // Build a synthetic snapshot
        let f1ID = UUID()
        let f2ID = UUID()
        let function1 = FunctionSummary(id: f1ID, name: "func1", startAddress: 0x1000, endAddress: 0x1010, confidence: 1.0)
        let function2 = FunctionSummary(id: f2ID, name: "func2", startAddress: 0x2000, endAddress: 0x2008, confidence: 1.0)
        // Basic blocks: each function has one block covering its address range
        let block1 = BasicBlockSummary(id: UUID(), functionID: f1ID, startAddress: 0x1000, endAddress: 0x1010, instructionCount: 3)
        let block2 = BasicBlockSummary(id: UUID(), functionID: f2ID, startAddress: 0x2000, endAddress: 0x2008, instructionCount: 2)
        // Instructions: three in function1, two in function2
        let instrRows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "01 00 00 58", mnemonic: "ldr", operands: "x0, [x1]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "20 00 80 D2", mnemonic: "mov", operands: "x0, #1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 80 D2", mnemonic: "mov", operands: "x1, #0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x2000, bytes: "00 00 80 D2", mnemonic: "mov", operands: "x0, #0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x2004, bytes: "C0 03 5F D6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
        ]
        // Call xref: from instruction at 0x1004 to function2 at 0x2000
        let xref = XRef(id: UUID(), from: 0x1004, to: 0x2000, kind: XRefKind.call)
        // Control flow edges: simple fall-throughs within functions
        let cfEdges: [ControlFlowEdge] = [
            ControlFlowEdge(id: UUID(), from: 0x1000, to: 0x1004, kind: "") ,
            ControlFlowEdge(id: UUID(), from: 0x1004, to: 0x1008, kind: ""),
            ControlFlowEdge(id: UUID(), from: 0x2000, to: 0x2004, kind: ""),
        ]
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "testbin", path: "/test", kind: "", architecture: "aarch64")],
            functions: [function1, function2],
            symbols: [],
            imports: [],
            indirectSymbols: [],
            exports: [],
            stringLiterals: [],
            basicBlocks: [block1, block2],
            instructions: instrRows,
            xrefs: [xref],
            controlFlowEdges: cfEdges,
            hexBytes: Data()
        )
        // Export snapshot
        let exporter = BinExport2Exporter()
        let data1 = exporter.export(snapshot)
        let data2 = exporter.export(snapshot)
        // The output must be deterministic
        XCTAssertEqual(data1, data2, "Export must be deterministic")
        // Parse exported data
        let parsed = Self.parseExport(data: data1)
        // There should be three unique mnemonics: ldr, mov, ret
        XCTAssertEqual(parsed.mnemonics.sorted(), ["ldr", "mov", "ret"].sorted())
        // All instructions should be present in instruction table
        XCTAssertEqual(parsed.instructions.count, 5)
        // Each instruction's mnemonic index should be within mnemonics array bounds
        for instr in parsed.instructions {
            XCTAssertTrue(instr.mnemonicIndex >= 0 && instr.mnemonicIndex < Int32(parsed.mnemonics.count))
        }
        // The expression table should include registers x0/x1 (both root and child), immediates 0/1, and dereference for [x1]
        XCTAssertEqual(parsed.expressions.count, 6)
        // The operand table should have one entry per unique operand
        XCTAssertEqual(parsed.operands.count, 5)
        // Build expression index lookup based on type and value
        var exprIndexMap: [String: Int] = [:]
        for (idx, expr) in parsed.expressions.enumerated() {
            switch expr.type {
            case 1: // SYMBOL
                exprIndexMap["sym:\(expr.symbol)"] = idx
            case 2: // IMMEDIATE_INT
                exprIndexMap["imm:\(expr.immediate)"] = idx
            case 4: // OPERATOR
                exprIndexMap["op:\(expr.symbol)"] = idx
            case 5: // REGISTER
                // Disambiguate a root register (e.g. `x1` in `mov x1,#0`) from the SAME register
                // spelling nested under a dereference (e.g. the `x1` inside `[x1]`). They are
                // DISTINCT expressions because their parent links differ, so they must key apart.
                if expr.parentIndex == nil {
                    exprIndexMap["reg:\(expr.symbol)"] = idx
                } else {
                    exprIndexMap["reg:\(expr.symbol)@child"] = idx
                }
            case 6: // SIZE_PREFIX
                exprIndexMap["size:\(expr.symbol)"] = idx
            case 7: // DEREFERENCE
                exprIndexMap["deref"] = idx
            default:
                continue
            }
        }
        // Build operand index lookup: operand list of expression indices -> operand table index
        var operandIndexMap: [[Int32]: Int] = [:]
        for (idx, operand) in parsed.operands.enumerated() {
            operandIndexMap[operand] = idx
        }
        // Define expected operand ordering for each instruction based on the snapshot.
        // Each inner array represents one operand's constituent expression keys in order.
        let expectedInstrOperandKeyLists: [[[String]]] = [
            // ldr x0, [x1] — the x1 here is a CHILD of the dereference, distinct from the root x1
            [["reg:x0"], ["deref", "reg:x1@child"]],
            // mov x0, #1
            [["reg:x0"], ["imm:1"]],
            // mov x1, #0
            [["reg:x1"], ["imm:0"]],
            // mov x0, #0
            [["reg:x0"], ["imm:0"]],
            // ret (no operands)
            []
        ]
        // Compute expected operand indices for each instruction
        var expectedOperandIndices: [[Int32]] = []
        for operandKeyLists in expectedInstrOperandKeyLists {
            var opIndices: [Int32] = []
            for exprKeys in operandKeyLists {
                var exprListIndices: [Int32] = []
                for key in exprKeys {
                    if let exprIdx = exprIndexMap[key] {
                        exprListIndices.append(Int32(exprIdx))
                    }
                }
                if let opIdx = operandIndexMap[exprListIndices] {
                    opIndices.append(Int32(opIdx))
                }
            }
            expectedOperandIndices.append(opIndices)
        }
        // Verify that each instruction's operand indices match the expected ordering
        for (i, instr) in parsed.instructions.enumerated() {
            let expectedOps = expectedOperandIndices[i]
            XCTAssertEqual(instr.operandIndices, expectedOps, "Instruction at index \(i) operands do not match")
        }
        // Check that call graph edges include the single call from func1 to func2
        XCTAssertEqual(parsed.callGraphEdges.count, 1)
        if let edge = parsed.callGraphEdges.first {
            // function1 index should be 0 and function2 index should be 1 because functions are sorted by start address
            XCTAssertEqual(edge.0, 0)
            XCTAssertEqual(edge.1, 1)
        }
    }

    /// Operand classification: a register spelling that is also valid hex ("d0") must be a REGISTER,
    /// and a bare call-target identifier ("printf") must be a SYMBOL — not the reverse.
    func testOperandClassificationRegisterVsSymbol() {
        let fn = FunctionSummary(id: UUID(), name: "f", startAddress: 0x1000, endAddress: 0x1004, confidence: 1.0)
        let rows = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "op",
                           operands: "d0, printf", hasBreakpoint: false, comment: nil)
        ]
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "x", path: "/x", kind: "", architecture: "aarch64")],
            functions: [fn], symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            basicBlocks: [], instructions: rows, xrefs: [], controlFlowEdges: [], hexBytes: Data()
        )
        let parsed = Self.parseExport(data: BinExport2Exporter().export(snapshot))
        XCTAssertTrue(parsed.expressions.contains { $0.symbol == "d0" && $0.type == 5 }, "d0 must be REGISTER (type 5)")
        XCTAssertTrue(parsed.expressions.contains { $0.symbol == "printf" && $0.type == 1 }, "printf must be SYMBOL (type 1)")
        XCTAssertFalse(parsed.expressions.contains { $0.type == 2 }, "no operand here is an immediate")
    }
}
