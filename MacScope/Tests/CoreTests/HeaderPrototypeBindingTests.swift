import Foundation
import XCTest
@testable import MacScope

@MainActor
final class HeaderPrototypeBindingTests: XCTestCase {
    func testExactExportAdmissionAndLocalIsolation() throws {
        let store = try makeStore()
        store.defineTypesFromCHeader("struct S { int field; }; int read_header(struct S *s, int flag);")
        let signatures = store.snapshot.functionSignatureOverrides(in: .primary)
        let signature = try XCTUnwrap(signatures[0x1000])
        XCTAssertEqual(signature.returnType, "int32_t")
        XCTAssertEqual(signature.args.map(\.type), ["struct S *", "int32_t"])
        XCTAssertEqual(signature.args.map(\.name), ["s", "flag"])
        XCTAssertNil(signatures[0x2000])
        XCTAssertTrue(store.snapshot.addressOverrides.isEmpty)
        let text = render(store.snapshot)
        XCTAssertTrue(text.contains("int32_t read_header(struct S * s, int32_t flag)"), text)
    }

    func testPointerTypedefCanonicalizesToRecord() throws {
        let store = try makeStore()
        store.defineTypesFromCHeader("struct S { int field; }; typedef struct S *S_ptr; int read_header(S_ptr s);")
        let signature = try XCTUnwrap(store.snapshot.functionSignatureOverrides(in: .primary)[0x1000])
        XCTAssertEqual(signature.args.first?.type, "struct S *")
    }

    func testVoidPrototypeIsAnExplicitReturnContract() throws {
        let store = try makeStore()
        store.defineTypesFromCHeader("void read_header(void);")
        let signature = try XCTUnwrap(store.snapshot.functionSignatureOverrides(in: .primary)[0x1000])
        XCTAssertEqual(signature.returnType, "void")
        XCTAssertTrue(signature.args.isEmpty)
        XCTAssertFalse(signature.isNoReturn)
        let text = render(store.snapshot)
        XCTAssertTrue(text.contains("void read_header("), text)
        XCTAssertFalse(text.contains("unresolved_return_contract"), text)
    }

    func testAuthoredOverrideWinsWithoutRewritingAuthoredMap() throws {
        let store = try makeStore()
        let authored = FunctionSignatureOverride(returnType: "uint64_t", args: [])
        store.snapshot.addressOverrides[.primary(0x1000)] = AddressOverride(signature: authored)
        store.defineTypesFromCHeader("int read_header(int flag);")
        XCTAssertEqual(store.snapshot.importedPrototypes[.primary(0x1000)]?.returnType, "int32_t")
        XCTAssertEqual(store.snapshot.functionSignatureOverrides(in: .primary)[0x1000], authored)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.signature, authored)
    }

    func testNonRegularExportsRefuseAlongsidePositiveAdmission() throws {
        for flags in [UInt64(0x08), 0x10, 1, 2, 0x20] {
            let store = try makeStore()
            store.snapshot.exports.append(ExportSummary(id: UUID(), name: "_blocked", address: 0x2000,
                                                        source: "export trie", terminalFlags: flags))
            let summary = store.defineTypesFromCHeader("int read_header(int flag); void blocked(void);")
            XCTAssertNotNil(store.snapshot.functionSignatureOverrides(in: .primary)[0x1000])
            XCTAssertNil(store.snapshot.functionSignatureOverrides(in: .primary)[0x2000])
            XCTAssertEqual(summary.importedPrototypeCount, 1)
            XCTAssertEqual(summary.skippedPrototypeCount, 1)
        }
    }

    func testExactUnderscoreAndNlistOnlyRefusalAlongsidePositiveAdmission() throws {
        for export in [ExportSummary(id: UUID(), name: "blocked", address: 0x2000, source: "export trie", terminalFlags: 0),
                       ExportSummary(id: UUID(), name: "_blocked", address: 0x2000, source: "nlist")] {
            let store = try makeStore()
            store.snapshot.exports.append(export)
            store.defineTypesFromCHeader("int read_header(int flag); void blocked(void);")
            XCTAssertNotNil(store.snapshot.functionSignatureOverrides(in: .primary)[0x1000])
            XCTAssertNil(store.snapshot.functionSignatureOverrides(in: .primary)[0x2000])
        }
    }

    func testDuplicateExportAndIncompatibleAliasRefusalAlongsidePositiveAdmission() throws {
        for duplicateName in [true, false] {
            let store = try makeStore()
            store.snapshot.exports += [
                ExportSummary(id: UUID(), name: "_blocked", address: 0x2000, source: "export trie", terminalFlags: 0),
                ExportSummary(id: UUID(), name: duplicateName ? "_blocked" : "_alias", address: 0x2000,
                              source: "export trie", terminalFlags: 0)
            ]
            store.defineTypesFromCHeader("int read_header(int flag); void blocked(void); int alias(int n);")
            XCTAssertNotNil(store.snapshot.functionSignatureOverrides(in: .primary)[0x1000])
            XCTAssertNil(store.snapshot.functionSignatureOverrides(in: .primary)[0x2000])
        }
    }

    func testImportIsImageScopedAndRequiresFunctionStart() throws {
        let store = try makeStore()
        let sibling = ImageSlot(rawValue: 9)
        var binary = BinaryImage(id: UUID(), name: "sibling", path: "/sibling", kind: "Mach-O", architecture: "arm64")
        binary.slot = sibling
        store.snapshot.binaries.append(binary)
        store.snapshot.analysisBySlot[sibling] = store.snapshot.analysisBySlot[.primary]
        store.snapshot.exports.append(ExportSummary(id: UUID(), name: "_middle", address: 0x1002,
                                                    source: "export trie", terminalFlags: 0))
        store.defineTypesFromCHeader("int read_header(int flag); void middle(void);")
        XCTAssertNotNil(store.snapshot.functionSignatureOverrides(in: .primary)[0x1000])
        XCTAssertNil(store.snapshot.functionSignatureOverrides(in: .primary)[0x1002])
        XCTAssertTrue(store.snapshot.functionSignatureOverrides(in: sibling).isEmpty)
    }

    func testDisjointHeaderImportsPreservePriorContractsAndRefuseConflicts() throws {
        let store = try makeStore()
        store.snapshot.exports.append(ExportSummary(id: UUID(), name: "_other", address: 0x2000,
                                                    source: "export trie", terminalFlags: 0))
        store.defineTypesFromCHeader("int read_header(int flag);")
        store.defineTypesFromCHeader("void other(void);")
        XCTAssertEqual(store.snapshot.importedPrototypes.count, 2)
        let summary = store.defineTypesFromCHeader("void read_header(void);")
        XCTAssertEqual(summary.skippedPrototypeCount, 1)
        XCTAssertNil(store.snapshot.importedPrototypes[.primary(0x1000)])
        XCTAssertNotNil(store.snapshot.importedPrototypes[.primary(0x2000)])
    }

    func testInlineTaggedRecordPointerTypedefKeepsIndirection() throws {
        let parsed = CTypeHeaderParser.parse("typedef struct S { int field; } *S_ptr; int read_header(S_ptr s);")
        XCTAssertEqual(try XCTUnwrap(parsed.prototypes.first).signature.args.first?.type, "struct S *")
    }

    func testUnresolvedPrototypeIsCountedAndVariadicIsRetained() {
        let parsed = CTypeHeaderParser.parse("int log_values(int n, ...); mystery bad(mystery value);")
        XCTAssertEqual(parsed.prototypes.count, 1)
        XCTAssertEqual(parsed.prototypes.first?.signature.variadicState, .variadic)
        XCTAssertFalse(parsed.prototypes.first?.signature.isNoReturn ?? true)
        XCTAssertEqual(parsed.skippedPrototypeCount, 1)
    }

    func testPackageRoundTripAndLegacyMissingKeyIsEmpty() throws {
        let store = try makeStore()
        store.defineTypesFromCHeader("int read_header(int flag);")
        let analysis = WorkspacePackageAnalysis(snapshot: store.snapshot)
        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: data)
        XCTAssertEqual(decoded.snapshot(binaries: store.snapshot.binaries, hexBytes: Data()).importedPrototypes,
                       store.snapshot.importedPrototypes)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "importedPrototypes")
        let old = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(old.importedPrototypes.isEmpty)
        XCTAssertTrue(old.snapshot(binaries: store.snapshot.binaries, hexBytes: Data()).importedPrototypes.isEmpty)
        let oldExport = try JSONDecoder().decode(ExportSummary.self, from: Data("""
        {"id":"00000000-0000-0000-0000-000000000001","name":"_read_header","address":4096,"source":"export trie"}
        """.utf8))
        XCTAssertNil(oldExport.terminalFlags)
    }

    func testDatabaseRoundTripKeepsImageSlotAndExportFlags() throws {
        let store = try makeStore()
        store.defineTypesFromCHeader("int read_header(int flag);")
        var snapshot = store.snapshot
        snapshot.remapImageSlot(from: .primary, to: ImageSlot(rawValue: 7))
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let saved = try database.saveSnapshot(workspaceName: "H1", snapshot: snapshot)
        let restored = try XCTUnwrap(database.loadSnapshot(workspaceID: XCTUnwrap(saved.id)))
        XCTAssertEqual(restored.importedPrototypes, snapshot.importedPrototypes)
        XCTAssertNil(restored.functionSignatureOverrides(in: .primary)[0x1000])
        XCTAssertNotNil(restored.functionSignatureOverrides(in: ImageSlot(rawValue: 7))[0x1000])
        XCTAssertEqual(restored.exports.first?.terminalFlags, 0)
        XCTAssertEqual(restored.exports.first?.name, "_read_header")
    }

    func testImportInvalidatesMemoAndUndoRestoresBothContractsAndTypes() throws {
        let store = try makeStore()
        XCTAssertNotNil(store.snapshot.imageWideIndirectCalls(in: .primary, compute: true))
        XCTAssertNotNil(store.snapshot.imageWideIndirectCalls(in: .primary, compute: false))
        store.undoManager.groupsByEvent = false
        store.defineTypesFromCHeader("struct S { int field; }; int read_header(struct S *s);")
        XCTAssertNil(store.snapshot.imageWideIndirectCalls(in: .primary, compute: false))
        XCTAssertNotNil(store.snapshot.importedPrototypes[.primary(0x1000)])
        store.undoManager.undo()
        XCTAssertTrue(store.snapshot.importedPrototypes.isEmpty)
        XCTAssertTrue(store.snapshot.typeDefinitions.isEmpty)
    }

    func testImportedRecordParameterRendersNamedMember() throws {
        let store = try makeStore()
        store.snapshot.functions[0].endAddress = 0x1008
        store.snapshot.instructions = [
            InstructionRow(address: 0x1000, bytes: "00 04 40 f9", mnemonic: "ldr", operands: "x0, [x0, #8]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        store.defineTypesFromCHeader("struct S { long pad; long field; }; long read_header(struct S *s);")
        let text = render(store.snapshot)
        XCTAssertTrue(text.contains("s->field"), text)
    }

    func testRealPublicLibjpegHeaderPrototypeRecovery() throws {
        let fixture = TestSourceRoot.url.appendingPathComponent("MacScope/Tests/CoreTests/Fixtures/libjpeg-turbo-3.2.0/public-layout.c")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = ["-E", "-P", "-x", "c", fixture.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let parsed = CTypeHeaderParser.parse(String(decoding: data, as: UTF8.self))
        print("H1 libjpeg-turbo 3.2.0 public prototypes: recovered=\(parsed.prototypes.count), skipped=\(parsed.skippedPrototypeCount)")
        let read = try XCTUnwrap(parsed.prototypes.first { $0.name == "jpeg_read_header" })
        XCTAssertEqual(read.signature.returnType, "int32_t")
        XCTAssertEqual(read.signature.args.map(\.type), ["struct jpeg_decompress_struct *", "int32_t"])
        let destroy = try XCTUnwrap(parsed.prototypes.first { $0.name == "jpeg_destroy_decompress" })
        XCTAssertEqual(destroy.signature.returnType, "void")
        XCTAssertEqual(destroy.signature.args.first?.type, "struct jpeg_decompress_struct *")
        let error = try XCTUnwrap(parsed.prototypes.first { $0.name == "jpeg_std_error" })
        XCTAssertEqual(error.signature.returnType, "struct jpeg_error_mgr *")
        XCTAssertEqual(error.signature.args.first?.type, "struct jpeg_error_mgr *")
        XCTAssertEqual(parsed.diagnostics.filter { $0.hasPrefix("Skipped function prototype") }.count, parsed.skippedPrototypeCount)
    }

    func testTrieTerminalOverridesSameNamedNlistFacts() throws {
        var fixture = MachOFixture.makeExecutableWithSymbols(useExportsTrieCommand: true, exportFlags: 2, exportValue: 0x5555)
        let old = Data("_exported_entry\0".utf8)
        let range = try XCTUnwrap(fixture.bytes.range(of: old))
        var replacement = Data("_trie_export\0".utf8)
        replacement.append(Data(repeating: 0, count: old.count - replacement.count))
        fixture.bytes.replaceSubrange(range, with: replacement)
        let parsed = try MachOParser().parse(fixture.bytes)
        let exports = parsed.exports.filter { $0.name == "_trie_export" }
        XCTAssertEqual(exports.count, 1)
        XCTAssertEqual(exports.first?.flags, 2)
        XCTAssertEqual(exports.first?.address, 0x5555)
    }

    private func render(_ snapshot: WorkspaceSnapshot) -> String {
        let printer = PseudocodePrinter()
        let function = printer.buildFunction(functionName: "read_header", startAddress: 0x1000,
            signatureOverrides: snapshot.functionSignatureOverrides(in: .primary), types: snapshot.typeDefinitions,
            instructions: snapshot.instructions.filter { $0.address >= 0x1000 && $0.address < 0x2000 })
        return printer.print(function: function, types: snapshot.typeDefinitions).text
    }

    private func makeStore() throws -> WorkspaceStore {
        // Decode the new optional fact through the persistence seam so this
        // tests-only commit compiles on the unchanged baseline.
        let export = try JSONDecoder().decode(ExportSummary.self, from: Data("""
        {"id":"00000000-0000-0000-0000-000000000001","name":"_read_header","address":4096,"source":"export trie","terminalFlags":0}
        """.utf8))
        var analysis = ImageAnalysis()
        analysis.exports = [export]
        analysis.functions = [0x1000, 0x2000].map { address in
            FunctionSummary(id: UUID(), name: "read_header", startAddress: UInt64(address), endAddress: UInt64(address + 4), confidence: 1)
        }
        analysis.instructions = [0x1000, 0x2000].map { address in
            InstructionRow(address: UInt64(address), bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        }
        return WorkspaceStore(workspaceName: "H1", snapshot: WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "synthetic", path: "/synthetic", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis]
        ), engine: AnalysisEngine(), autosaveScheduler: nil)
    }
}
