import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacScope

private let callArgumentAuditTestOutputLimit = 64 * 1_024

@MainActor
final class ScriptingAPITests: XCTestCase {
    func testCLIReadBoundaryDoesNotRetainAcceptance() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        for _ in 0..<64 {
            let output = try HeadlessAutomationAuthority.execute(
                command: "read-evidence",
                arguments: .object(["operation": .string("workspace.summary")]),
                api: api, proposingPrincipal: .cli
            )
            XCTAssertEqual(output["status"]?.stringValue, "accepted")
            XCTAssertEqual(output["proposingPrincipal"]?.stringValue, "cli")
            XCTAssertEqual(output["facts"]?["workspaceName"]?.stringValue, "Scripting")
            let invocation = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(output["invocationID"]?.stringValue)))
            XCTAssertNil(store.acceptedPhase2Evidence(invocationID: invocation))
            XCTAssertEqual(store.phase2EvidenceAcceptor.terminalCount, 0)
        }
    }

    func testReadEvidenceReturnsOnlyAppAcceptedWorkspaceFacts() throws {
        let store = makeStore()
        let output = try WorkspaceScriptingAPI(store: store).execute(
            "read-evidence", arguments: .object(["operation": .string("workspace.summary")])
        )
        XCTAssertEqual(output["status"]?.stringValue, "accepted")
        XCTAssertEqual(output["proposingPrincipal"]?.stringValue, "human")
        XCTAssertEqual(output["authorizingPrincipal"]?.stringValue, "app")
        XCTAssertEqual(output["facts"]?["workspaceName"]?.stringValue, "Scripting")
        XCTAssertNotNil(output["evidenceID"]?.stringValue)
        XCTAssertNotNil(output["precondition"])
        XCTAssertNotNil(output["citations"]?.arrayValue)
    }

    func testReadEvidenceRejectsForgedArgumentsAndOperations() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())
        for operation in ["decompiler.native.result", "selection.explain", "unknown"] {
            XCTAssertThrowsError(try api.execute("read-evidence", arguments: .object([
                "operation": .string(operation),
            ])))
        }
        for key in ["principal", "subject", "descriptor", "address", "limits"] {
            XCTAssertThrowsError(try api.execute("read-evidence", arguments: .object([
                "operation": .string("workspace.summary"), key: .string("forged"),
            ])))
        }
        XCTAssertThrowsError(try api.execute("read-evidence", arguments: .object([:])))
    }

    func testReadEvidenceUnavailableNeverIncludesFacts() throws {
        let store = makeStore()
        store.selectedAddress = nil
        let output = try WorkspaceScriptingAPI(store: store).execute(
            "read-evidence", arguments: .object(["operation": .string("function.review")])
        )
        XCTAssertEqual(output["status"]?.stringValue, "unavailable")
        XCTAssertEqual(output["reason"]?.stringValue, "noSelection")
        XCTAssertNil(output["facts"])
        XCTAssertNil(output["evidenceID"])
    }

    func testReadEvidencePreservesFullWidthFunctionAddresses() throws {
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "wide.bin", path: "/ignored/wide.bin",
                                   kind: "Mach-O", architecture: "arm64")],
            functions: [FunctionSummary(id: UUID(), name: "wide", startAddress: 0xffffffffffffff00,
                                        endAddress: 0xffffffffffffff04, confidence: 1)],
            instructions: [InstructionRow(address: 0xffffffffffffff00, bytes: "c0 03 5f d6",
                                         mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)],
            xrefs: [], hexBytes: Data()
        )
        let store = WorkspaceStore(workspaceName: "Wide", snapshot: snapshot,
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        let output = try WorkspaceScriptingAPI(store: store).execute(
            "read-evidence", arguments: .object(["operation": .string("function.review")])
        )
        XCTAssertEqual(output["status"]?.stringValue, "accepted")
        XCTAssertEqual(output["facts"]?["start"]?.stringValue, "18446744073709551360")
        XCTAssertEqual(output["facts"]?["endExclusive"]?.stringValue, "18446744073709551364")
        let bytes = try output.jsonData()
        XCTAssertEqual(try ScriptValue.decode(bytes)["facts"]?["start"]?.addressValue,
                       0xffffffffffffff00)
    }

    private func makeStore(instructions: [InstructionRow]? = nil) -> WorkspaceStore {
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "test.bin", path: "/tmp/test.bin", kind: "Mach-O executable", architecture: "arm64")],
            functions: [
                FunctionSummary(id: UUID(), name: "_main", startAddress: 0x1000, endAddress: 0x1008, confidence: 0.9),
                FunctionSummary(id: UUID(), name: "helper", startAddress: 0x1008, endAddress: 0x100C, confidence: 0.7),
            ],
            symbols: [SymbolSummary(id: UUID(), name: "_main", address: 0x1000, kind: "export", libraryName: nil)],
            imports: [ImportSummary(id: UUID(), name: "_printf", libraryName: "libSystem", libraryOrdinal: 1)],
            exports: [ExportSummary(id: UUID(), name: "_main", address: 0x1000, source: "symtab")],
            stringLiterals: [StringLiteralSummary(id: UUID(), value: "hello world", address: 0x2000, sourceSection: "__cstring", byteLength: 12)],
            basicBlocks: [BasicBlockSummary(id: UUID(), functionID: UUID(), startAddress: 0x1000, endAddress: 0x1008, instructionCount: 2)],
            instructions: instructions ?? [
                InstructionRow(address: 0x1000, bytes: "e0 03 01 aa", mnemonic: "mov", operands: "x0, x1", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1004, bytes: "01 00 00 94", mnemonic: "bl", operands: "helper", hasBreakpoint: false, comment: "call"),
                InstructionRow(address: 0x1008, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ],
            xrefs: [XRef(id: UUID(), from: 0x1004, to: 0x1008, kind: "call")],
            controlFlowEdges: [ControlFlowEdge(id: UUID(), from: 0x1004, to: 0x1008, kind: "call")],
            hexBytes: Data(),
            sections: [SectionSummary(id: UUID(), name: "__TEXT,__text", address: 0x1000, size: 0x200, fileOffset: 0x1000, isExecutable: true)]
        )
        return WorkspaceStore(workspaceName: "Scripting", snapshot: snapshot, engine: AnalysisEngine())
    }

    private func temporaryAuditBinary(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-call-audit-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url, options: .atomic)
        return url
    }

    private func makeAuditStore(
        binaryURL: URL,
        name: String = "_audit",
        startAddress: UInt64 = 0x1000,
        instructions: [InstructionRow],
        objcSelectors: [UInt64: String] = [:],
        imageBytes: Data = Data([0xff]),
        addressOverrides: [ImageAddress: AddressOverride] = [:]
    ) -> WorkspaceStore {
        let endAddress = (instructions.map(\.address).max() ?? startAddress) + 4
        let binary = BinaryImage(
            id: UUID(), name: binaryURL.lastPathComponent, path: binaryURL.path,
            kind: "Mach-O executable", architecture: "arm64"
        )
        let snapshot = WorkspaceSnapshot(
            binaries: [binary],
            functions: [FunctionSummary(
                id: UUID(), name: name, startAddress: startAddress,
                endAddress: endAddress, confidence: 1
            )],
            instructions: instructions,
            xrefs: [],
            hexBytes: Data(),
            objcSelectors: objcSelectors,
            imageBytes: imageBytes,
            addressOverrides: addressOverrides
        )
        return WorkspaceStore(
            workspaceName: "Call Argument Audit", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
    }

    private func auditRow(
        _ address: UInt64,
        _ mnemonic: String,
        _ operands: String = ""
    ) -> InstructionRow {
        InstructionRow(
            address: address, bytes: "00 00 00 00", mnemonic: mnemonic,
            operands: operands, hasBreakpoint: false, comment: nil
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func runningExecutableURLForAuditTest() throws -> URL {
        var capacity: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &capacity)
        guard capacity > 0 else {
            throw XCTSkip("_NSGetExecutablePath did not report a required capacity")
        }
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        let status = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &capacity)
        }
        guard status == 0 else {
            throw XCTSkip("_NSGetExecutablePath failed with status \(status)")
        }
        let path = buffer.withUnsafeBufferPointer { pointer in
            String(cString: pointer.baseAddress!)
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    private func objectKeys(_ value: ScriptValue) -> Set<String> {
        guard case let .object(fields) = value else { return [] }
        return Set(fields.keys)
    }

    // MARK: - Reads

    func testInfoAndListings() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())
        let info = try api.execute("info")
        XCTAssertEqual(info["architecture"]?.stringValue, "arm64")
        XCTAssertEqual(info["format"]?.stringValue, "Mach-O executable")
        XCTAssertEqual(info["functionCount"]?.intValue, 2)

        XCTAssertEqual(try api.execute("functions").arrayValue?.count, 2)
        XCTAssertEqual(try api.execute("functions").arrayValue?.first?["name"]?.stringValue, "_main")
        XCTAssertEqual(try api.execute("symbols").arrayValue?.first?["name"]?.stringValue, "_main")
        XCTAssertEqual(try api.execute("strings").arrayValue?.first?["value"]?.stringValue, "hello world")
    }

    func testInstructionsByFunctionAndRange() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())
        // _main spans [0x1000, 0x1008): two instructions.
        let byFunction = try api.execute("instructions", arguments: .object(["function": .string("_main")]))
        XCTAssertEqual(byFunction.arrayValue?.map { $0["mnemonic"]?.stringValue }, ["mov", "bl"])
        // By range.
        let byRange = try api.execute("instructions", arguments: .object(["address": .hex(0x1000), "count": .int(1)]))
        XCTAssertEqual(byRange.arrayValue?.count, 1)
        XCTAssertEqual(byRange.arrayValue?.first?["address"]?.stringValue, "0x1000")
    }

    func testXrefsAndNameAt() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())
        let xrefs = try api.execute("xrefs", arguments: .object(["to": .hex(0x1008)]))
        XCTAssertEqual(xrefs.arrayValue?.first?["from"]?.stringValue, "0x1004")
        XCTAssertEqual(try api.execute("name-at", arguments: .object(["address": .hex(0x1000)])).stringValue, "_main")
    }

    // MARK: - Mutations (undoable)

    func testRenameIsAppliedAndUndoable() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let result = try api.execute("rename", arguments: .object(["address": .hex(0x1000), "name": .string("entry_point")]))
        XCTAssertEqual(result["ok"]?.boolValue, true)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.customName, "entry_point")
        XCTAssertEqual(try api.execute("name-at", arguments: .object(["address": .hex(0x1000)])).stringValue, "entry_point")
        // Scripted edits register undo just like manual ones.
        store.undoManager.undo()
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000)]?.customName)
    }

    // MARK: - Function selector policy (MS-06)

    /// The name `functions` lists after a rename is a usable selector for every general
    /// `function` command; the raw analysis name keeps working while unambiguous.
    func testRenamedFunctionRoundTripsFromEnumerationThroughEveryFunctionSelector() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("rename", arguments: .object([
            "address": .hex(0x1000), "name": .string("entry_point"),
        ]))

        let listed = try XCTUnwrap(try api.execute("functions").arrayValue)
        let listedName = try XCTUnwrap(
            listed.first { $0["address"]?.stringValue == "0x1000" }?["name"]?.stringValue
        )
        XCTAssertEqual(listedName, "entry_point")
        let selector = ScriptValue.object(["function": .string(listedName)])

        let rows = try XCTUnwrap(try api.execute("instructions", arguments: selector).arrayValue)
        XCTAssertEqual(rows.map { $0["address"]?.stringValue }, ["0x1000", "0x1004"])
        XCTAssertEqual(try api.execute("decompile", arguments: selector)["address"]?.stringValue, "0x1000")
        XCTAssertEqual(try api.execute("callers", arguments: selector).arrayValue?.count, 0)
        XCTAssertEqual(
            try api.execute("callees", arguments: selector).arrayValue?.first?["from"]?.stringValue,
            "0x1004"
        )
        let blocks = try XCTUnwrap(try api.execute("basic-blocks", arguments: selector).arrayValue)
        XCTAssertEqual(blocks.map { $0["start"]?.stringValue }, ["0x1000"])
        let audit = try api.execute("parameter-binding-audit", arguments: selector)
        XCTAssertEqual(audit["address"]?.stringValue, "0x1000")
        XCTAssertEqual(audit["function"]?.stringValue, "entry_point")
        let renamedRegister = try api.execute("rename-register", arguments: .object([
            "function": .string(listedName), "register": .string("x19"), "name": .string("ctx"),
        ]))
        XCTAssertEqual(renamedRegister["address"]?.stringValue, "0x1000")
        let registerNames = try api.execute("register-names", arguments: selector)
        XCTAssertEqual(registerNames["address"]?.stringValue, "0x1000")
        XCTAssertEqual(registerNames["renames"]?["x19"]?.stringValue, "ctx")
        let cleared = try api.execute("clear-register-name", arguments: .object([
            "function": .string(listedName), "register": .string("x19"),
        ]))
        XCTAssertEqual(cleared["address"]?.stringValue, "0x1000")

        // Unrenamed raw spelling remains a compatible selector while it is unambiguous.
        XCTAssertEqual(
            try api.execute("decompile", arguments: .object(["function": .string("_main")]))["address"]?.stringValue,
            "0x1000"
        )

        // Undo restores the raw label; the old display label no longer selects anything.
        // (clear-register-name, rename-register and rename are each one undo step.)
        while store.undoManager.canUndo { store.undoManager.undo() }
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000)]?.customName)
        XCTAssertThrowsError(try api.execute("instructions", arguments: selector)) { error in
            XCTAssertEqual(error as? ScriptingError, .invalidArgument("no function named 'entry_point'"))
        }
    }

    /// A display label equal to a different function's raw name must not silently select
    /// either function; both general selector paths reject it with the typed ambiguity.
    func testDisplayLabelCollidingWithAnotherRawNameIsRejected() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("rename", arguments: .object([
            "address": .hex(0x1000), "name": .string("helper"),
        ]))
        let listed = try XCTUnwrap(try api.execute("functions").arrayValue)
        XCTAssertEqual(listed.map { $0["name"]?.stringValue }, ["helper", "helper"])

        let selector = ScriptValue.object(["function": .string("helper")])
        let expected = ScriptingError.ambiguousFunctionSelector(
            name: "helper", addresses: [0x1000, 0x1008]
        )
        for command in [
            "instructions", "decompile", "callers", "callees", "basic-blocks",
            "register-names", "parameter-binding-audit",
        ] {
            XCTAssertThrowsError(try api.execute(command, arguments: selector), command) { error in
                XCTAssertEqual(error as? ScriptingError, expected, command)
            }
        }
        XCTAssertThrowsError(try api.execute("rename-register", arguments: .object([
            "function": .string("helper"), "register": .string("x19"), "name": .string("ctx"),
        ]))) { error in
            XCTAssertEqual(error as? ScriptingError, expected)
        }
        XCTAssertTrue(store.snapshot.registerNameOverrides(forProcedureAt: 0x1000).isEmpty)
        XCTAssertTrue(store.snapshot.registerNameOverrides(forProcedureAt: 0x1008).isEmpty)
        XCTAssertEqual(
            expected.errorDescription,
            "Ambiguous function selector 'helper': 2 functions match (0x1000, 0x1008); select by `address` instead."
        )

        // Address and non-colliding raw selectors are unchanged.
        XCTAssertEqual(
            try api.execute("decompile", arguments: .object(["address": .hex(0x1008)]))["address"]?.stringValue,
            "0x1008"
        )
        XCTAssertEqual(
            try api.execute("decompile", arguments: .object(["function": .string("_main")]))["address"]?.stringValue,
            "0x1000"
        )
    }

    func testDuplicateDisplayLabelsAreRejectedButDistinctRawNamesStillResolve() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        for address: UInt64 in [0x1000, 0x1008] {
            _ = try api.execute("rename", arguments: .object([
                "address": .hex(address), "name": .string("same_label"),
            ]))
        }
        for command in ["instructions", "decompile", "callers", "parameter-binding-audit"] {
            XCTAssertThrowsError(
                try api.execute(command, arguments: .object(["function": .string("same_label")])),
                command
            ) { error in
                XCTAssertEqual(
                    error as? ScriptingError,
                    .ambiguousFunctionSelector(name: "same_label", addresses: [0x1000, 0x1008]),
                    command
                )
            }
        }
        XCTAssertEqual(
            try api.execute("decompile", arguments: .object(["function": .string("_main")]))["address"]?.stringValue,
            "0x1000"
        )
        XCTAssertEqual(
            try api.execute("decompile", arguments: .object(["function": .string("helper")]))["address"]?.stringValue,
            "0x1008"
        )
    }

    /// Duplicate raw names (e.g. two local statics) previously selected the first array
    /// entry; the general resolver now fails closed like the structural audit resolver.
    func testGeneralResolverRejectsDuplicateRawNamesInsteadOfFirstMatch() throws {
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "dup.bin", path: "/tmp/dup.bin",
                                   kind: "Mach-O executable", architecture: "arm64")],
            functions: [
                FunctionSummary(id: UUID(), name: "local_helper", startAddress: 0x1000,
                                endAddress: 0x1004, confidence: 1),
                FunctionSummary(id: UUID(), name: "local_helper", startAddress: 0x2000,
                                endAddress: 0x2004, confidence: 1),
            ],
            instructions: [auditRow(0x1000, "ret"), auditRow(0x2000, "ret")],
            xrefs: [], hexBytes: Data()
        )
        let store = WorkspaceStore(workspaceName: "Duplicate Raw Names", snapshot: snapshot,
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        let api = WorkspaceScriptingAPI(store: store)
        for command in ["instructions", "decompile", "callees"] {
            XCTAssertThrowsError(
                try api.execute(command, arguments: .object(["function": .string("local_helper")])),
                command
            ) { error in
                XCTAssertEqual(
                    error as? ScriptingError,
                    .ambiguousFunctionSelector(name: "local_helper", addresses: [0x1000, 0x2000]),
                    command
                )
            }
        }
        // Renaming one copy makes its label unique, but the shared raw spelling still
        // matches both functions and stays ambiguous.
        _ = try api.execute("rename", arguments: .object([
            "address": .hex(0x2000), "name": .string("second_helper"),
        ]))
        XCTAssertEqual(
            try api.execute("decompile", arguments: .object(["function": .string("second_helper")]))["address"]?.stringValue,
            "0x2000"
        )
        XCTAssertThrowsError(
            try api.execute("decompile", arguments: .object(["function": .string("local_helper")]))
        ) { error in
            XCTAssertEqual(
                error as? ScriptingError,
                .ambiguousFunctionSelector(name: "local_helper", addresses: [0x1000, 0x2000])
            )
        }
    }

    /// Name lookups stay inside each command's existing image scope: primary-image
    /// commands never see a sibling's names/labels, and the focused-image audit never sees
    /// the primary's, even when both images share a virtual address and a display label.
    /// Sibling labels are authored through the GUI path (bare-address `setCustomName`, which
    /// binds to focus); scripted `rename` always targets the primary image.
    func testFunctionNameSelectorsStayInsideTheCommandImageScope() throws {
        let address = 0x5000 as UInt64
        let sibling = ImageSlot(rawValue: 1)
        func image(_ slot: ImageSlot) -> BinaryImage {
            BinaryImage(
                id: UUID(), name: "image-\(slot.rawValue)", path: "/tmp/image-\(slot.rawValue)",
                kind: "Mach-O executable", architecture: "arm64", slot: slot
            )
        }
        func analysis(_ name: String) -> ImageAnalysis {
            var result = ImageAnalysis()
            result.functions = [FunctionSummary(
                id: UUID(), name: name, startAddress: address,
                endAddress: address + 4, confidence: 1
            )]
            result.instructions = [auditRow(address, "ret")]
            return result
        }
        let snapshot = WorkspaceSnapshot(
            binaries: [image(.primary), image(sibling)],
            analysisBySlot: [.primary: analysis("primary_fn"), sibling: analysis("sibling_fn")]
        )
        let store = WorkspaceStore(
            workspaceName: "Selector Image Scope", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        let api = WorkspaceScriptingAPI(store: store)
        store.focusImage(.primary)
        _ = try api.execute("rename", arguments: .object([
            "address": .hex(address), "name": .string("shared_label"),
        ]))
        store.focusImage(sibling)
        XCTAssertEqual(store.focusedImageSlot, sibling)
        store.setCustomName(address, name: "shared_label")
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.customName, "shared_label")
        XCTAssertEqual(
            store.snapshot.addressOverrides[ImageAddress(slot: sibling, address: address)]?.customName,
            "shared_label"
        )

        // Focused-image audit: the same label in another image is not a collision.
        let audit = try api.execute(
            "parameter-binding-audit", arguments: .object(["function": .string("shared_label")])
        )
        XCTAssertEqual(audit["function"]?.stringValue, "shared_label")
        XCTAssertEqual(audit["address"]?.stringValue, "0x5000")
        XCTAssertEqual(
            try api.execute(
                "parameter-binding-audit", arguments: .object(["function": .string("sibling_fn")])
            )["function"]?.stringValue,
            "shared_label"
        )
        XCTAssertThrowsError(try api.execute(
            "parameter-binding-audit", arguments: .object(["function": .string("primary_fn")])
        )) { error in
            XCTAssertEqual(error as? ScriptingError, .invalidArgument("no function named 'primary_fn'"))
        }

        // Primary-image commands: enumeration and lookup use the primary's labels only.
        let listed = try XCTUnwrap(try api.execute("functions").arrayValue)
        XCTAssertEqual(listed.map { $0["name"]?.stringValue }, ["shared_label"])
        XCTAssertEqual(
            try api.execute("decompile", arguments: .object(["function": .string("shared_label")]))["function"]?.stringValue,
            "primary_fn"
        )
        XCTAssertThrowsError(try api.execute(
            "instructions", arguments: .object(["function": .string("sibling_fn")])
        )) { error in
            XCTAssertEqual(error as? ScriptingError, .invalidArgument("no function named 'sibling_fn'"))
        }

        // A sibling-only label is invisible to primary-scoped selectors.
        store.setCustomName(address, name: "sibling_only")
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.customName, "shared_label")
        XCTAssertThrowsError(try api.execute(
            "decompile", arguments: .object(["function": .string("sibling_only")])
        )) { error in
            XCTAssertEqual(error as? ScriptingError, .invalidArgument("no function named 'sibling_only'"))
        }
        XCTAssertEqual(
            try api.execute(
                "parameter-binding-audit", arguments: .object(["function": .string("sibling_only")])
            )["function"]?.stringValue,
            "sibling_only"
        )
    }

    // MARK: - Command image scope for name writes (MS-06 follow-up)

    /// Two images sharing one VA, the sibling focused, and pre-existing sibling authoring
    /// (label, comment, tag, local label, color, operand format, applied type, bookmark, and a
    /// manual xref add `address -> address + 0x10`). Raw
    /// names differ per image so every assertion identifies which image answered. No sibling
    /// structural mark is seeded: the focused audits exclude data/undefined rows, and the
    /// rename tests audit the sibling's only instruction.
    private func makeSiblingFocusedSelectorStore(
        address: UInt64, sibling: ImageSlot,
        primaryArchitecture: String = "arm64", siblingArchitecture: String = "arm64",
        primaryPath: String? = nil, primaryImageBytes: Data = Data()
    ) -> WorkspaceStore {
        func image(_ slot: ImageSlot) -> BinaryImage {
            BinaryImage(
                id: UUID(), name: "image-\(slot.rawValue)",
                path: slot == .primary ? (primaryPath ?? "/tmp/image-primary") : "/tmp/image-\(slot.rawValue)",
                kind: "Mach-O executable",
                architecture: slot == .primary ? primaryArchitecture : siblingArchitecture, slot: slot
            )
        }
        func analysis(_ name: String) -> ImageAnalysis {
            var result = ImageAnalysis()
            result.functions = [FunctionSummary(
                id: UUID(), name: name, startAddress: address,
                endAddress: address + 4, confidence: 1
            )]
            result.instructions = [auditRow(address, "ret")]
            return result
        }
        var siblingOverride = AddressOverride(customName: "sibling_label")
        siblingOverride.customComment = "sibling_note"
        siblingOverride.tag = "sibling_tag"
        siblingOverride.localLabel = "sibling_loc"
        siblingOverride.colorTag = .red
        siblingOverride.operandFormat = .hex
        siblingOverride.appliedTypeName = "SiblingStruct"
        let snapshot = WorkspaceSnapshot(
            binaries: [image(.primary), image(sibling)],
            analysisBySlot: [
                .primary: { var primary = analysis("primary_fn"); primary.imageBytes = primaryImageBytes; return primary }(),
                sibling: analysis("sibling_fn"),
            ],
            addressOverrides: [ImageAddress(slot: sibling, address: address): siblingOverride],
            manualXRefs: [ManualXRef(
                from: address, to: address + 0x10, kind: XRefKind.call,
                isSuppression: false, imageSlot: sibling
            )],
            bookmarks: [Bookmark(address: address, imageSlot: sibling, name: "sibling_mark")]
        )
        let store = WorkspaceStore(
            workspaceName: "Rename Command Image", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        store.focusImage(sibling)
        return store
    }

    /// A scripted rename made while a sibling image is focused lands in the primary image —
    /// the image `functions`, `name-at` and the general `function` selector read — so the
    /// listed name round-trips; the focused sibling is never written; Undo restores both.
    func testRenameWhileSiblingIsFocusedWritesThePrimaryImageThatFunctionsLists() throws {
        let address = 0x5000 as UInt64
        let sibling = ImageSlot(rawValue: 1)
        let siblingKey = ImageAddress(slot: sibling, address: address)
        let store = makeSiblingFocusedSelectorStore(address: address, sibling: sibling)
        let api = WorkspaceScriptingAPI(store: store)
        XCTAssertEqual(store.focusedImageSlot, sibling)
        let siblingBefore = store.snapshot.addressOverrides[siblingKey]
        XCTAssertEqual(siblingBefore?.customName, "sibling_label")

        let result = try api.execute("rename", arguments: .object([
            "address": .hex(address), "name": .string("renamed_fn"),
        ]))
        XCTAssertEqual(result["ok"]?.boolValue, true)
        XCTAssertEqual(store.focusedImageSlot, sibling, "rename must not move focus")
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.customName, "renamed_fn")
        XCTAssertEqual(store.snapshot.addressOverrides[siblingKey], siblingBefore)

        // rename -> functions -> query, all on the primary image.
        let listed = try XCTUnwrap(try api.execute("functions").arrayValue)
        XCTAssertEqual(listed.map { $0["name"]?.stringValue }, ["renamed_fn"])
        XCTAssertEqual(listed.map { $0["address"]?.stringValue }, ["0x5000"])
        let listedName = try XCTUnwrap(listed.first?["name"]?.stringValue)
        XCTAssertEqual(
            try api.execute("name-at", arguments: .object(["address": .hex(address)])).stringValue,
            listedName
        )
        let selector = ScriptValue.object(["function": .string(listedName)])
        let rows = try XCTUnwrap(try api.execute("instructions", arguments: selector).arrayValue)
        XCTAssertEqual(rows.map { $0["address"]?.stringValue }, ["0x5000"])
        let decompiled = try api.execute("decompile", arguments: selector)
        XCTAssertEqual(decompiled["address"]?.stringValue, "0x5000")
        XCTAssertEqual(decompiled["function"]?.stringValue, "primary_fn")

        // The focused-image audit keeps its documented scope: it sees the sibling's own
        // label, not the primary rename.
        XCTAssertEqual(
            try api.execute(
                "parameter-binding-audit", arguments: .object(["function": .string("sibling_label")])
            )["function"]?.stringValue,
            "sibling_label"
        )
        XCTAssertThrowsError(try api.execute("parameter-binding-audit", arguments: selector)) { error in
            XCTAssertEqual(error as? ScriptingError, .invalidArgument("no function named 'renamed_fn'"))
        }

        // Undo restores both images to their pre-command state.
        while store.undoManager.canUndo { store.undoManager.undo() }
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])
        XCTAssertEqual(store.snapshot.addressOverrides[siblingKey], siblingBefore)
        XCTAssertEqual(
            try XCTUnwrap(try api.execute("functions").arrayValue).map { $0["name"]?.stringValue },
            ["primary_fn"]
        )
        XCTAssertThrowsError(try api.execute("instructions", arguments: selector)) { error in
            XCTAssertEqual(error as? ScriptingError, .invalidArgument("no function named 'renamed_fn'"))
        }
    }

    /// Register renames resolve their function in the primary image, so they must also write
    /// the primary image that `register-names` reads, whichever image is focused.
    func testRegisterRenameWhileSiblingIsFocusedWritesThePrimaryImageThatRegisterNamesReads() throws {
        let address = 0x5000 as UInt64
        let sibling = ImageSlot(rawValue: 1)
        let siblingKey = ImageAddress(slot: sibling, address: address)
        let store = makeSiblingFocusedSelectorStore(address: address, sibling: sibling)
        let api = WorkspaceScriptingAPI(store: store)
        let siblingBefore = store.snapshot.addressOverrides[siblingKey]

        _ = try api.execute("rename", arguments: .object([
            "address": .hex(address), "name": .string("renamed_fn"),
        ]))
        let renamed = try api.execute("rename-register", arguments: .object([
            "function": .string("renamed_fn"), "register": .string("x19"), "name": .string("ctx"),
        ]))
        XCTAssertEqual(renamed["address"]?.stringValue, "0x5000")
        XCTAssertEqual(
            try api.execute("register-names", arguments: .object(["function": .string("renamed_fn")]))["renames"]?["x19"]?.stringValue,
            "ctx"
        )
        XCTAssertEqual(store.snapshot.registerNameOverrides(forProcedureAt: address, in: .primary), ["x19": "ctx"])
        XCTAssertTrue(store.snapshot.registerNameOverrides(forProcedureAt: address, in: sibling).isEmpty)
        XCTAssertEqual(store.snapshot.addressOverrides[siblingKey], siblingBefore)

        _ = try api.execute("clear-register-name", arguments: .object([
            "function": .string("renamed_fn"), "register": .string("x19"),
        ]))
        XCTAssertTrue(store.snapshot.registerNameOverrides(forProcedureAt: address, in: .primary).isEmpty)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.customName, "renamed_fn")

        while store.undoManager.canUndo { store.undoManager.undo() }
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])
        XCTAssertEqual(store.snapshot.addressOverrides[siblingKey], siblingBefore)
    }

    /// The address-authoring commands follow the same rule as `rename`: with a sibling
    /// focused, each writes the primary image its scripting read reports; the sibling's
    /// authoring and bookmarks are untouched; focus never moves; Undo restores both images.
    func testAddressAuthoringWhileSiblingIsFocusedWritesThePrimaryImageItsReadsReport() throws {
        let address = 0x5000 as UInt64
        let sibling = ImageSlot(rawValue: 1)
        let siblingKey = ImageAddress(slot: sibling, address: address)
        let store = makeSiblingFocusedSelectorStore(address: address, sibling: sibling)
        let api = WorkspaceScriptingAPI(store: store)
        let siblingBefore = store.snapshot.addressOverrides[siblingKey]
        let siblingBookmarksBefore = store.snapshot.bookmarks.filter { $0.imageSlot == sibling }
        XCTAssertEqual(siblingBookmarksBefore.map(\.name), ["sibling_mark"])
        func assertSiblingUnchanged(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(store.focusedImageSlot, sibling, "focus moved after \(step)", file: file, line: line)
            XCTAssertEqual(store.snapshot.addressOverrides[siblingKey], siblingBefore, step, file: file, line: line)
            XCTAssertEqual(
                store.snapshot.bookmarks.filter { $0.imageSlot == sibling }, siblingBookmarksBefore,
                step, file: file, line: line
            )
        }
        // Reads are primary-scoped before any write: the sibling's authoring is not listed.
        XCTAssertNil(try XCTUnwrap(try api.execute("instructions", arguments: .object([
            "address": .hex(address), "count": .int(1),
        ])).arrayValue).first?["comment"]?.stringValue)
        XCTAssertEqual(try api.execute("local-labels").arrayValue?.count, 0)
        XCTAssertEqual(try api.execute("bookmarks").arrayValue?.count, 0)

        _ = try api.execute("set-comment", arguments: .object([
            "address": .hex(address), "comment": .string("primary_note"),
        ]))
        let rows = try XCTUnwrap(try api.execute("instructions", arguments: .object([
            "function": .string("primary_fn"),
        ])).arrayValue)
        XCTAssertEqual(rows.first?["address"]?.stringValue, "0x5000")
        XCTAssertEqual(rows.first?["comment"]?.stringValue, "primary_note")
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.customComment, "primary_note")
        assertSiblingUnchanged("set-comment")

        _ = try api.execute("set-tag", arguments: .object([
            "address": .hex(address), "tag": .string("primary_tag"),
        ]))
        XCTAssertEqual(store.snapshot.tag(at: address, in: .primary), "primary_tag")
        assertSiblingUnchanged("set-tag")

        _ = try api.execute("set-local-label", arguments: .object([
            "address": .hex(address), "label": .string("primary_loc"),
        ]))
        let labels = try XCTUnwrap(try api.execute("local-labels").arrayValue)
        XCTAssertEqual(labels.map { $0["address"]?.stringValue }, ["0x5000"])
        XCTAssertEqual(labels.map { $0["label"]?.stringValue }, ["primary_loc"])
        assertSiblingUnchanged("set-local-label")

        _ = try api.execute("add-bookmark", arguments: .object([
            "address": .hex(address), "name": .string("primary_mark"),
        ]))
        let marks = try XCTUnwrap(try api.execute("bookmarks").arrayValue)
        XCTAssertEqual(marks.map { $0["address"]?.stringValue }, ["0x5000"])
        XCTAssertEqual(marks.map { $0["name"]?.stringValue }, ["primary_mark"])
        XCTAssertEqual(
            store.snapshot.bookmarks.filter { $0.imageSlot == .primary }.map(\.name), ["primary_mark"]
        )
        assertSiblingUnchanged("add-bookmark")

        _ = try api.execute("clear-local-label", arguments: .object(["address": .hex(address)]))
        XCTAssertEqual(try api.execute("local-labels").arrayValue?.count, 0)
        assertSiblingUnchanged("clear-local-label")
        _ = try api.execute("remove-bookmark", arguments: .object(["address": .hex(address)]))
        XCTAssertEqual(try api.execute("bookmarks").arrayValue?.count, 0)
        assertSiblingUnchanged("remove-bookmark")

        // Undo restores both images to their pre-command state.
        while store.undoManager.canUndo { store.undoManager.undo() }
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])
        XCTAssertTrue(store.snapshot.bookmarks.filter { $0.imageSlot == .primary }.isEmpty)
        XCTAssertNil(try XCTUnwrap(try api.execute("instructions", arguments: .object([
            "address": .hex(address), "count": .int(1),
        ])).arrayValue).first?["comment"]?.stringValue)
        assertSiblingUnchanged("undo")
    }

    /// Display and structural authoring follow the same rule: with a sibling focused,
    /// `set-color`, `set-type`, `set-operand-format` and the make-* marks write the primary
    /// image — the image whose bare-address reads report them and whose analysis a structural
    /// mark re-drives (`codeExcludedAddresses(in:)` is the engine's exclusion input). The
    /// sibling's authoring is untouched, focus never moves, and Undo restores both images.
    /// The fixture has no readable binary, so a structural re-flow finds no source and leaves
    /// derived data alone; the qualified override map is the observable state.
    func testDisplayAndStructuralAuthoringWhileSiblingIsFocusedWritesThePrimaryImage() throws {
        let address = 0x5000 as UInt64
        let sibling = ImageSlot(rawValue: 1)
        let siblingKey = ImageAddress(slot: sibling, address: address)
        let store = makeSiblingFocusedSelectorStore(address: address, sibling: sibling)
        let api = WorkspaceScriptingAPI(store: store)
        let siblingBefore = store.snapshot.addressOverrides[siblingKey]
        XCTAssertEqual(siblingBefore?.colorTag, .red)
        XCTAssertEqual(siblingBefore?.operandFormat, .hex)
        XCTAssertEqual(siblingBefore?.appliedTypeName, "SiblingStruct")
        func assertSiblingUnchanged(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(store.focusedImageSlot, sibling, "focus moved after \(step)", file: file, line: line)
            XCTAssertEqual(store.snapshot.addressOverrides[siblingKey], siblingBefore, step, file: file, line: line)
            XCTAssertFalse(
                store.snapshot.codeExcludedAddresses(in: sibling).contains(address),
                "sibling analysis input changed after \(step)", file: file, line: line
            )
        }
        // Bare-address reads resolve the primary image and see none of the sibling's authoring.
        XCTAssertNil(store.snapshot.colorTag(at: address))
        XCTAssertNil(store.snapshot.operandFormat(at: address))
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])

        _ = try api.execute("set-color", arguments: .object([
            "address": .hex(address), "color": .string("blue"),
        ]))
        XCTAssertEqual(store.snapshot.colorTag(at: address), .blue)
        XCTAssertEqual(store.snapshot.colorTag(at: address, in: .primary), .blue)
        assertSiblingUnchanged("set-color")

        _ = try api.execute("define-type", arguments: .object([
            "kind": .string("struct"), "name": .string("PrimaryStruct"),
            "fields": .array([.object(["name": .string("x"), "type": .string("int32_t")])]),
        ]))
        _ = try api.execute("set-type", arguments: .object([
            "address": .hex(address), "type": .string("PrimaryStruct"),
        ]))
        XCTAssertEqual(store.snapshot.appliedType(at: address)?.name, "PrimaryStruct")
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.appliedTypeName, "PrimaryStruct")
        assertSiblingUnchanged("set-type")

        _ = try api.execute("set-operand-format", arguments: .object([
            "address": .hex(address), "format": .string("decimal"),
        ]))
        XCTAssertEqual(store.snapshot.operandFormat(at: address), .decimal)
        assertSiblingUnchanged("set-operand-format")

        _ = try api.execute("make-data", arguments: .object([
            "address": .hex(address), "isData": .bool(true),
        ]))
        XCTAssertTrue(store.snapshot.isData(at: address))
        XCTAssertTrue(store.snapshot.codeExcludedAddresses(in: .primary).contains(address))
        assertSiblingUnchanged("make-data")
        _ = try api.execute("make-data", arguments: .object([
            "address": .hex(address), "isData": .bool(false),
        ]))
        XCTAssertFalse(store.snapshot.isData(at: address))
        assertSiblingUnchanged("make-data false")

        _ = try api.execute("make-undefined", arguments: .object(["address": .hex(address)]))
        XCTAssertTrue(store.snapshot.isUndefined(at: address))
        XCTAssertTrue(store.snapshot.codeExcludedAddresses(in: .primary).contains(address))
        assertSiblingUnchanged("make-undefined")
        _ = try api.execute("make-undefined", arguments: .object([
            "address": .hex(address), "isUndefined": .bool(false),
        ]))
        XCTAssertFalse(store.snapshot.isUndefined(at: address))
        assertSiblingUnchanged("make-undefined false")

        _ = try api.execute("make-procedure", arguments: .object(["address": .hex(address)]))
        XCTAssertTrue(store.snapshot.isMarkedAsProcedure(at: address))
        assertSiblingUnchanged("make-procedure")

        _ = try api.execute("make-array", arguments: .object([
            "address": .hex(address), "elementType": .string("int32_t"), "count": .int(4),
        ]))
        XCTAssertEqual(store.snapshot.dataShape(at: address)?.kind, .array)
        XCTAssertTrue(store.snapshot.codeExcludedAddresses(in: .primary).contains(address))
        assertSiblingUnchanged("make-array")
        _ = try api.execute("make-alignment", arguments: .object([
            "address": .hex(address), "boundary": .int(8),
        ]))
        XCTAssertEqual(store.snapshot.dataShape(at: address)?.kind, .alignment)
        assertSiblingUnchanged("make-alignment")
        _ = try api.execute("make-string", arguments: .object(["address": .hex(address)]))
        XCTAssertEqual(store.snapshot.dataShape(at: address)?.kind, .string)
        assertSiblingUnchanged("make-string")

        // Undo restores both images (and the type catalog) to their pre-command state.
        while store.undoManager.canUndo { store.undoManager.undo() }
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])
        XCTAssertNil(store.snapshot.colorTag(at: address))
        XCTAssertFalse(store.snapshot.codeExcludedAddresses(in: .primary).contains(address))
        XCTAssertFalse(store.snapshot.typeDefinitions.contains { $0.name == "PrimaryStruct" })
        assertSiblingUnchanged("undo")
    }

    /// Manual xref edits follow the same rule: with a sibling focused, `add-xref` and
    /// `suppress-xref` write the primary image — the only image whose edits `xrefs` merges —
    /// and `manual-xrefs` lists primary-image edits only. The sibling's own add of the same
    /// endpoint is neither listed nor cancelled by the primary suppression; focus never moves;
    /// Undo restores both images.
    func testManualXRefEditsWhileSiblingIsFocusedWriteThePrimaryImageXrefsReads() throws {
        let address = 0x5000 as UInt64
        let target = address + 0x10
        let sibling = ImageSlot(rawValue: 1)
        let store = makeSiblingFocusedSelectorStore(address: address, sibling: sibling)
        let api = WorkspaceScriptingAPI(store: store)
        let siblingEditsBefore = store.snapshot.manualXRefs.filter { $0.imageSlot == sibling }
        XCTAssertEqual(siblingEditsBefore.count, 1)
        func primaryEdits() -> [ManualXRef] {
            store.snapshot.manualXRefs.filter { $0.imageSlot == .primary }
        }
        func xrefsFrom() throws -> [ScriptValue] {
            try XCTUnwrap(try api.execute("xrefs", arguments: .object(["from": .hex(address)])).arrayValue)
        }
        func assertSiblingUnchanged(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(store.focusedImageSlot, sibling, "focus moved after \(step)", file: file, line: line)
            XCTAssertEqual(
                store.snapshot.manualXRefs.filter { $0.imageSlot == sibling }, siblingEditsBefore,
                step, file: file, line: line
            )
            XCTAssertEqual(
                store.snapshot.effectiveXRefs(from: address, in: sibling).map(\.to), [target],
                "sibling effective xrefs changed after \(step)", file: file, line: line
            )
        }
        // Reads are primary-scoped before any write: the sibling's edit is neither merged nor listed.
        XCTAssertEqual(try xrefsFrom().count, 0)
        XCTAssertEqual(try api.execute("manual-xrefs").arrayValue?.count, 0)
        assertSiblingUnchanged("setup")

        _ = try api.execute("add-xref", arguments: .object([
            "from": .hex(address), "to": .hex(target), "kind": .string(XRefKind.call),
        ]))
        let added = try xrefsFrom()
        XCTAssertEqual(added.map { $0["to"]?.stringValue }, ["0x5010"])
        let listedAdd = try XCTUnwrap(try api.execute("manual-xrefs").arrayValue)
        XCTAssertEqual(listedAdd.map { $0["to"]?.stringValue }, ["0x5010"])
        XCTAssertEqual(listedAdd.map { $0["suppressed"]?.boolValue }, [false])
        XCTAssertEqual(primaryEdits().map(\.isSuppression), [false])
        assertSiblingUnchanged("add-xref")

        // The primary suppression cancels the primary add only, never the sibling's add.
        _ = try api.execute("suppress-xref", arguments: .object([
            "from": .hex(address), "to": .hex(target), "kind": .string(XRefKind.call),
        ]))
        XCTAssertEqual(try xrefsFrom().count, 0)
        let listedSuppression = try XCTUnwrap(try api.execute("manual-xrefs").arrayValue)
        XCTAssertEqual(listedSuppression.map { $0["suppressed"]?.boolValue }, [true])
        XCTAssertEqual(primaryEdits().map(\.isSuppression), [true])
        assertSiblingUnchanged("suppress-xref")

        // Undo restores both images to their pre-command state.
        while store.undoManager.canUndo { store.undoManager.undo() }
        XCTAssertTrue(primaryEdits().isEmpty)
        XCTAssertEqual(try xrefsFrom().count, 0)
        XCTAssertEqual(try api.execute("manual-xrefs").arrayValue?.count, 0)
        assertSiblingUnchanged("undo")
    }

    /// Regression for the retained structural policy: `call-argument-audit` still selects
    /// by raw structural name only and reports the raw name, even after a rename that the
    /// general resolver honors.
    func testCallArgumentAuditKeepsStructuralOnlyNamingAfterGeneralResolverChange() throws {
        let binaryURL = try temporaryAuditBinary([0x31, 0x32])
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        let store = makeAuditStore(
            binaryURL: binaryURL,
            instructions: [auditRow(0x1000, "ret")],
            addressOverrides: [
                .primary(0x1000): AddressOverride(customName: "presentation_only_name"),
            ]
        )
        let api = WorkspaceScriptingAPI(store: store)

        XCTAssertThrowsError(try api.execute(
            "call-argument-audit",
            arguments: .object(["function": .string("presentation_only_name")])
        )) { error in
            XCTAssertEqual(
                error as? ScriptingError,
                .invalidArgument("no function named 'presentation_only_name'")
            )
        }
        let structural = try api.execute(
            "call-argument-audit", arguments: .object(["function": .string("_audit")])
        )
        XCTAssertEqual(structural["validation_scope"]?.stringValue, "structural-candidate")
        XCTAssertEqual(structural["function"]?["display_name"]?.stringValue, "_audit")
        XCTAssertEqual(structural["function"]?["start_address"]?.stringValue, "0x1000")

        // The general resolver honors the same rename for presentation-facing commands.
        XCTAssertEqual(
            try api.execute(
                "parameter-binding-audit",
                arguments: .object(["function": .string("presentation_only_name")])
            )["address"]?.stringValue,
            "0x1000"
        )
    }

    func testCommentAndTag() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("set-comment", arguments: .object(["address": .hex(0x1004), "comment": .string("important")]))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1004)]?.customComment, "important")
        _ = try api.execute("set-tag", arguments: .object(["address": .hex(0x1004), "tag": .string("io")]))
        XCTAssertEqual(store.snapshot.tag(at: 0x1004), "io")
    }

    func testGotoAndSearch() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let goto = try api.execute("goto", arguments: .object(["query": .string("_main")]))
        XCTAssertEqual(goto["ok"]?.boolValue, true)
        XCTAssertEqual(store.selectedAddress, 0x1000)

        let search = try api.execute("search", arguments: .object(["query": .string("mov"), "mode": .string("text")]))
        XCTAssertGreaterThanOrEqual(search["total"]?.intValue ?? 0, 1)
    }

    func testAsyncSearchPreservesSmallTextRegexAndHexResultsWithoutMutation() async throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let before = store.snapshot
        let selection = store.selectedImageAddress
        let undo = store.undoManager.canUndo
        for (query, mode) in [("mov", "text"), ("^mov\\b", "regex"), ("e0 03 01 aa", "hex")] {
            let arguments = ScriptValue.object(["query": .string(query), "mode": .string(mode)])
            let legacy = try api.execute("search", arguments: arguments)
            let output = try await api.executeAsync("search", arguments: arguments)
            XCTAssertEqual(output["results"], legacy["results"])
            XCTAssertEqual(output["total"], legacy["total"])
            XCTAssertGreaterThan(output["total"]?.intValue ?? 0, 0)
            XCTAssertEqual(output["lowerBound"], output["total"])
            XCTAssertEqual(output["isTruncated"], .bool(false))
        }
        XCTAssertEqual(store.snapshot.binaries, before.binaries)
        XCTAssertEqual(store.snapshot.instructions, before.instructions)
        XCTAssertEqual(store.snapshot.addressOverrides, before.addressOverrides)
        XCTAssertEqual(store.selectedImageAddress, selection)
        XCTAssertEqual(store.undoManager.canUndo, undo)
    }

    func testAsyncSearchTruncationReportsLowerBoundRatherThanInventedTotal() async throws {
        let rows = (0..<600).map { InstructionRow(address: 0x1000 + UInt64($0 * 4), bytes: "00 00 00 00",
            mnemonic: "mov", operands: "x0, x1", hasBreakpoint: false, comment: nil) }
        let store = makeStore(instructions: rows)
        let output = try await WorkspaceScriptingAPI(store: store).executeAsync("search",
            arguments: .object(["query": .string("mov"), "mode": .string("text")]))
        XCTAssertEqual(output["isTruncated"], .bool(true))
        XCTAssertEqual(output["total"], .null)
        XCTAssertEqual(output["results"]?.arrayValue?.count, 500)
        let lowerBound = try XCTUnwrap(output["lowerBound"]?.intValue)
        XCTAssertGreaterThan(lowerBound, 500)
        XCTAssertLessThanOrEqual(lowerBound, 600)
        XCTAssertEqual(store.snapshot.instructions, rows)
    }

    func testAsyncSearchPrecancelledParentThrowsWithoutPublishingOrMutation() async throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let before = store.snapshot
        let selection = store.selectedImageAddress
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await api.executeAsync("search", arguments: .object(["query": .string("mov")]))
        }
        do { _ = try await operation.value; XCTFail("Precancelled search published a result") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.snapshot.instructions, before.instructions)
        XCTAssertEqual(store.snapshot.addressOverrides, before.addressOverrides)
        XCTAssertEqual(store.selectedImageAddress, selection)
    }

    func testAsyncSearchAdmissionLeavesMainActorAvailableAndSettlesCompletionOrCancellation() async throws {
        // Repeated immutable text keeps allocation bounded while giving the actual scan work.
        let operands = String(repeating: "a", count: 4_000)
        let rows = (0..<10_000).map { InstructionRow(address: 0x1000 + UInt64($0 * 4), bytes: "00 00 00 00",
            mnemonic: "mov", operands: operands, hasBreakpoint: false, comment: nil) }
        let store = makeStore(instructions: rows)
        let api = WorkspaceScriptingAPI(store: store)
        let selection = store.selectedImageAddress
        let overrides = store.snapshot.addressOverrides
        var entered = false
        let operation = Task { @MainActor in
            entered = true
            return try await api.executeAsync("search", arguments: .object([
                "query": .string("never-present"), "mode": .string("regex")]))
        }
        // Entry establishes admission. Scheduling may allow the bounded scan to finish
        // before cancellation arrives; either completion or cancellation is valid.
        while !entered { await Task.yield() }
        let mainActorInfo = try api.execute("info")
        XCTAssertEqual(mainActorInfo["instructionCount"], .int(10_000))
        operation.cancel()
        do {
            let output = try await operation.value
            XCTAssertEqual(output["results"], .array([]))
            XCTAssertEqual(output["lowerBound"], .int(0))
            let truncated = try XCTUnwrap(output["isTruncated"]?.boolValue)
            XCTAssertEqual(output["total"], truncated ? .null : .int(0))
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(store.snapshot.instructions, rows)
        XCTAssertEqual(store.snapshot.addressOverrides, overrides)
        XCTAssertEqual(store.selectedImageAddress, selection)
    }

    func testAsyncSearchUsesCapturedSnapshotAndDoesNotOverwriteConcurrentStoreChanges() async throws {
        let rows = (0..<2_000).map { InstructionRow(address: 0x1000 + UInt64($0 * 4), bytes: "00 00 00 00",
            mnemonic: "mov", operands: $0 == 0 ? "captured-needle" : String(repeating: "a", count: 200),
            hasBreakpoint: false, comment: nil) }
        let store = makeStore(instructions: rows)
        let api = WorkspaceScriptingAPI(store: store)
        var entered = false
        let operation = Task { @MainActor in
            entered = true
            return try await api.executeAsync("search", arguments: .object(["query": .string("captured-needle")]))
        }
        while !entered { await Task.yield() }
        var replacement = store.snapshot
        let replacementRows = [InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "ret",
            operands: "replacement", hasBreakpoint: false, comment: nil)]
        replacement.instructions = replacementRows
        store.snapshot = replacement
        let output = try await operation.value
        let results = try XCTUnwrap(output["results"]?.arrayValue)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?["address"], .hex(0x1000))
        XCTAssertTrue(results.first?["preview"]?.stringValue?.contains("captured-needle") == true)
        XCTAssertEqual(store.snapshot.instructions, replacementRows)
    }

    // MARK: - Async snapshot-read cancellation

    func testAsyncSnapshotReadsMatchSynchronousResultsWithoutMutation() async throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let before = store.snapshot
        let selection = store.selectedImageAddress
        for command in ["decompile", "basic-blocks"] {
            let arguments = ScriptValue.object(["function": .string("_main")])
            let legacy = try api.execute(command, arguments: arguments)
            let output = try await api.executeAsync(command, arguments: arguments)
            XCTAssertEqual(output, legacy, command)
        }
        let auditArguments = ScriptValue.object(["function": .string("_main")])
        let legacyAudit = try? api.execute("parameter-binding-audit", arguments: auditArguments)
        let asyncAudit = try? await api.executeAsync("parameter-binding-audit", arguments: auditArguments)
        XCTAssertEqual(asyncAudit, legacyAudit)
        XCTAssertEqual(store.snapshot.instructions, before.instructions)
        XCTAssertEqual(store.snapshot.addressOverrides, before.addressOverrides)
        XCTAssertEqual(store.selectedImageAddress, selection)
    }

    func testAsyncDecompileCancelledBetweenPhasesStopsBeforeMacIRBuild() async throws {
        let store = makeStore()
        // Checkpoint 1 is entry, 2 follows body extraction (before the MacIR build),
        // 3 follows the build and 4 follows rendering.
        let gate = SnapshotReadCheckpointGate(holdAt: 2)
        let api = WorkspaceScriptingAPI(store: store, snapshotReadCheckpoint: { gate.checkpoint() })
        let selection = store.selectedImageAddress
        let operation = Task { @MainActor in
            try await api.executeAsync("decompile", arguments: .object(["function": .string("_main")]))
        }
        try await gate.waitUntilHeld()
        operation.cancel()
        gate.open()
        do { _ = try await operation.value; XCTFail("Cancelled decompile published a result") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(gate.checkpointCount, 2, "No MacIR build or print phase may run after cancellation")
        XCTAssertEqual(store.selectedImageAddress, selection)
    }

    func testAsyncBasicBlocksCancelledMidLoopStopsAtNextBlock() async throws {
        let store = makeStore()
        var snapshot = store.snapshot
        snapshot.functions = [FunctionSummary(id: UUID(), name: "wide", startAddress: 0x1000,
            endAddress: 0x1000 + 64 * 4, confidence: 0.9)]
        snapshot.basicBlocks = (0..<64).map { index in
            BasicBlockSummary(id: UUID(), functionID: UUID(), startAddress: 0x1000 + UInt64(index * 4),
                endAddress: 0x1004 + UInt64(index * 4), instructionCount: 1)
        }
        store.snapshot = snapshot
        // Checkpoint 1 is entry; checkpoint 2 + n precedes block n. Hold before block 1.
        let gate = SnapshotReadCheckpointGate(holdAt: 3)
        let api = WorkspaceScriptingAPI(store: store, snapshotReadCheckpoint: { gate.checkpoint() })
        let operation = Task { @MainActor in
            try await api.executeAsync("basic-blocks", arguments: .object(["function": .string("wide")]))
        }
        try await gate.waitUntilHeld()
        operation.cancel()
        gate.open()
        do { _ = try await operation.value; XCTFail("Cancelled basic-blocks published a partial result") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(gate.checkpointCount, 3, "62 remaining blocks must not be scanned after cancellation")
        XCTAssertEqual(store.snapshot.basicBlocks, snapshot.basicBlocks)
    }

    func testAsyncMutationCancelledBeforeCommitHasNoEffect() async throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let undo = store.undoManager.canUndo
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await api.executeAsync("set-comment", arguments: .object([
                "address": .string("0x1000"), "comment": .string("must not commit")]))
        }
        do { _ = try await operation.value; XCTFail("Pre-commit cancellation published a receipt") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let row = try api.execute("instructions", arguments: .object(["address": .string("0x1000"), "count": .int(1)]))
        XCTAssertNil(row.arrayValue?.first?["comment"])
        XCTAssertEqual(store.undoManager.canUndo, undo)
        // The same uncancelled request commits and returns its receipt.
        let receipt = try await api.executeAsync("set-comment", arguments: .object([
            "address": .string("0x1000"), "comment": .string("committed")]))
        XCTAssertEqual(receipt["ok"], .bool(true))
    }

    // MARK: - goto mutation classification

    func testGotoIsClassifiedAsMutatingWorkspaceStateCommand() throws {
        let goto = try XCTUnwrap(WorkspaceScriptingAPI.availableCommands.first { $0.name == "goto" })
        XCTAssertTrue(goto.mutates, "goto changes focus/selection/editor mode that later commands observe")
        let headless = try XCTUnwrap(HeadlessAutomationAuthority.availableCommands.first { $0.name == "goto" })
        XCTAssertTrue(headless.mutates)
    }

    func testAsyncGotoCancelledBeforeCommitDoesNotNavigate() async throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        store.editorMode = .pseudocode
        let selection = store.selectedImageAddress
        let editorMode = store.editorMode
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await api.executeAsync("goto", arguments: .object(["query": .string("0x1008")]))
        }
        do { _ = try await operation.value; XCTFail("Pre-commit cancellation published a goto receipt") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(store.selectedImageAddress, selection)
        XCTAssertEqual(store.editorMode, editorMode)
        // The same uncancelled request navigates and returns its receipt.
        let receipt = try await api.executeAsync("goto", arguments: .object(["query": .string("0x1008")]))
        XCTAssertEqual(receipt["ok"], .bool(true))
        XCTAssertEqual(store.selectedAddress, 0x1008)
    }

    // MARK: - Pseudocode printer cooperative cancellation

    /// A straight-line body long enough to cross several printer checkpoint intervals.
    private func longPrinterRows(count: Int = 256) -> [InstructionRow] {
        (0..<count).map { index in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "00 00 80 d2", mnemonic: "mov",
                operands: "x\(index % 8), #0x\(String(index, radix: 16))", hasBreakpoint: false, comment: nil)
        } + [InstructionRow(address: 0x1000 + UInt64(count * 4), bytes: "c0 03 5f d6", mnemonic: "ret",
                operands: "", hasBreakpoint: false, comment: nil)]
    }

    private func printerShapes() -> [(String, [InstructionRow])] {
        func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
            InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands,
                hasBreakpoint: false, comment: nil)
        }
        return [
            ("long", longPrinterRows()),
            ("ifElse", [row(0x1000, "cmp", "x0, #0x0"), row(0x1004, "b.eq", "0x1010"), row(0x1008, "nop", ""),
                        row(0x100c, "b", "0x1014"), row(0x1010, "nop", ""), row(0x1014, "ret", "")]),
            ("while", [row(0x1000, "cmp", "x0, #0x0"), row(0x1004, "b.eq", "0x1010"), row(0x1008, "nop", ""),
                       row(0x100c, "b", "0x1000"), row(0x1010, "ret", "")]),
        ]
    }

    func testCheckpointedPrinterOutputIsIdenticalToUncheckpointedPrinter() throws {
        var gotoForm = DecompilerOptions.default
        gotoForm.structureControlFlow = false
        for options in [DecompilerOptions.default, gotoForm] {
            for (name, rows) in printerShapes() {
                let function = MacIRBuilder().buildFunction(name: name, instructions: rows)
                let printer = PseudocodePrinter(options: options)
                var checkpoints = 0
                let checkpointed = try printer.print(function: function, checkpoint: { checkpoints += 1 })
                XCTAssertEqual(checkpointed, printer.print(function: function), name)
                XCTAssertEqual(checkpointed.text, printer.print(function: function).text, name)
                if name == "long" {
                    XCTAssertGreaterThanOrEqual(checkpoints, 3, "the long body must cross printer checkpoints")
                }
            }
        }
    }

    func testPrinterCancellationStopsAtNextCheckpoint() throws {
        var gotoForm = DecompilerOptions.default
        gotoForm.structureControlFlow = false
        for options in [DecompilerOptions.default, gotoForm] {
            let function = MacIRBuilder().buildFunction(name: "long", instructions: longPrinterRows())
            var checkpoints = 0
            XCTAssertThrowsError(try PseudocodePrinter(options: options).print(function: function, checkpoint: {
                checkpoints += 1
                if checkpoints == 2 { throw CancellationError() }
            })) { error in
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            XCTAssertEqual(checkpoints, 2, "no checkpoint (and so no further emission interval) may follow the cancelled one")
        }
    }

    private func makeLongFunctionStore() -> WorkspaceStore {
        let rows = longPrinterRows()
        let store = makeStore(instructions: rows)
        var snapshot = store.snapshot
        snapshot.functions = [FunctionSummary(id: UUID(), name: "_main", startAddress: 0x1000,
            endAddress: rows[rows.count - 1].address + 4, confidence: 0.9)]
        store.snapshot = snapshot
        return store
    }

    func testAsyncDecompileOfLongFunctionMatchesSynchronousPath() async throws {
        let store = makeLongFunctionStore()
        let counter = SnapshotReadCheckpointGate(holdAt: Int.max)
        let api = WorkspaceScriptingAPI(store: store, snapshotReadCheckpoint: { counter.checkpoint() })
        let arguments = ScriptValue.object(["function": .string("_main")])
        let legacy = try api.execute("decompile", arguments: arguments)
        let output = try await api.executeAsync("decompile", arguments: arguments)
        XCTAssertEqual(output, legacy)
        // entry, extraction, MacIR build, >= 2 printer checkpoints, after print.
        XCTAssertGreaterThanOrEqual(counter.checkpointCount, 6)
    }

    func testAsyncDecompileCancelledMidPrintStopsAtNextPrinterCheckpoint() async throws {
        let store = makeLongFunctionStore()
        // Checkpoints 1-3 are entry, extraction and MacIR build; 4 is the first checkpoint
        // inside the printer, so holding there pins cancellation to the middle of the print.
        let gate = SnapshotReadCheckpointGate(holdAt: 4)
        let api = WorkspaceScriptingAPI(store: store, snapshotReadCheckpoint: { gate.checkpoint() })
        let operation = Task { @MainActor in
            try await api.executeAsync("decompile", arguments: .object(["function": .string("_main")]))
        }
        try await gate.waitUntilHeld()
        operation.cancel()
        gate.open()
        do { _ = try await operation.value; XCTFail("Cancelled decompile published a result") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(gate.checkpointCount, 4, "printing must stop at the checkpoint that observed cancellation")
    }

    // MARK: - Batch script + introspection + errors

    func testRunScriptExecutesStepsInOrder() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let script = ScriptValue.array([
            .object(["command": .string("rename"), "arguments": .object(["address": .hex(0x1000), "name": .string("foo")])]),
            .object(["command": .string("name-at"), "arguments": .object(["address": .hex(0x1000)])]),
        ])
        let results = try api.runScript(script).arrayValue
        XCTAssertEqual(results?.count, 2)
        XCTAssertEqual(results?.last?.stringValue, "foo")
    }

    func testCommandIntrospectionListsMutationFlag() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())
        let commands = try api.execute("commands").arrayValue ?? []
        let rename = commands.first { $0["name"]?.stringValue == "rename" }
        XCTAssertEqual(rename?["mutates"]?.boolValue, true)
        let info = commands.first { $0["name"]?.stringValue == "info" }
        XCTAssertEqual(info?["mutates"]?.boolValue, false)
        let parameterAudit = commands.first { $0["name"]?.stringValue == "parameter-binding-audit" }
        XCTAssertEqual(parameterAudit?["mutates"]?.boolValue, false)
        XCTAssertEqual(
            parameterAudit?["arguments"]?.arrayValue?.compactMap(\.stringValue),
            ["function", "address"]
        )
        let callAudit = commands.first { $0["name"]?.stringValue == "call-argument-audit" }
        XCTAssertEqual(callAudit?["mutates"]?.boolValue, false)
        XCTAssertEqual(
            callAudit?["arguments"]?.arrayValue?.compactMap(\.stringValue),
            ["function", "address"]
        )
        XCTAssertNil(commands.first { $0["name"]?.stringValue == "call-argument-audit-v1" })
    }

    func testErrors() {
        let api = WorkspaceScriptingAPI(store: makeStore())
        XCTAssertThrowsError(try api.execute("nope")) { XCTAssertEqual($0 as? ScriptingError, .unknownCommand("nope")) }
        XCTAssertThrowsError(try api.execute("rename", arguments: .object(["address": .hex(0x1000)]))) {
            XCTAssertEqual($0 as? ScriptingError, .missingArgument("name"))
        }
        // A typo'd enum value errors rather than silently clearing the attribute.
        XCTAssertThrowsError(try api.execute("set-color", arguments: .object(["address": .hex(0x1000), "color": .string("blu")])))
        XCTAssertThrowsError(try api.execute("define-type", arguments: .object(["kind": .string("klass"), "name": .string("X")])))
    }

    // MARK: - Richer commands

    func testDecompileReturnsPseudocode() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())
        let result = try api.execute("decompile", arguments: .object(["function": .string("_main")]))
        XCTAssertEqual(result["function"]?.stringValue, "_main")
        XCTAssertEqual(result["address"]?.stringValue, "0x1000")
        let pseudocode = try XCTUnwrap(result["pseudocode"]?.stringValue)
        XCTAssertFalse(pseudocode.isEmpty)

        XCTAssertEqual(result["structured"]?.boolValue, true)
        XCTAssertNil(result["structureFallback"])
        let lines = try XCTUnwrap(result["lines"]?.arrayValue)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertEqual(lines.compactMap { $0["text"]?.stringValue }.joined(separator: "\n"), pseudocode)
        for (index, line) in lines.enumerated() {
            XCTAssertEqual(line["n"]?.intValue, Int64(index + 1))
            XCTAssertNotNil(line["kind"]?.stringValue)
            XCTAssertNotNil(line["text"]?.stringValue)
        }

        let regions = try XCTUnwrap(result["regions"])
        XCTAssertTrue(["block", "sequence"].contains(regions["kind"]?.stringValue))
        XCTAssertFalse(regionJSONContainsControlConstruct(regions))
        XCTAssertNoThrow(try assertRegionJSON(regions, lineCount: lines.count))
        let data = try result.jsonData()
        let decoded = try ScriptValue.decode(data)
        XCTAssertEqual(decoded, result)
    }

    func testParameterBindingAuditReportsSparsePhysicalInputFromMacIRArgumentNode() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())

        let audit = try api.execute(
            "parameter-binding-audit",
            arguments: .object(["function": .string("_main")])
        )

        XCTAssertEqual(audit["schema"]?.stringValue, "parameter-binding-audit-v1")
        XCTAssertEqual(audit["validation_scope"]?.stringValue, "structural-candidate")
        XCTAssertEqual(audit["combined_oracle_comparison"]?.boolValue, false)
        XCTAssertNil(audit["baseline_body_sha256"])
        XCTAssertNil(audit["candidate_body_sha256"])
        XCTAssertNil(audit["baseline_operands"])
        XCTAssertNil(audit["candidate_operands"])
        XCTAssertEqual(audit["function"]?.stringValue, "_main")
        XCTAssertEqual(audit["address"]?.stringValue, "0x1000")
        XCTAssertEqual(audit["declaration_mode"]?.stringValue, "abi-only")
        XCTAssertEqual(audit["dangling_body_uses"]?.arrayValue, [])
        let records = try XCTUnwrap(audit["records"]?.arrayValue)
        let record = try XCTUnwrap(records.first { $0["binding"]?.stringValue == "gpr:1" })
        XCTAssertEqual(record["function"]?.stringValue, "_main")
        XCTAssertEqual(record["declaration_mode"]?.stringValue, "abi-only")
        XCTAssertEqual(record["row_ordinal"]?.intValue, 0)
        XCTAssertEqual(record["source_position"], .null)
        XCTAssertEqual(record["location"]?.stringValue, "x1")
        XCTAssertNotNil(record["evidence"]?.stringValue)
        XCTAssertEqual(record["name"]?.stringValue, "in_x1")
        XCTAssertEqual(record["type"]?.stringValue, "int64_t")

        let bodyUses = try XCTUnwrap(record["body_uses"]?.arrayValue)
        XCTAssertEqual(
            bodyUses.map { $0["address"]?.stringValue },
            ["0x1000", "0x1004"],
            "the x1 input first feeds mov x0, x1 and then reaches the call as x0"
        )
        XCTAssertEqual(bodyUses.map { $0["occurrence"]?.intValue }, [0, 0])
        XCTAssertNil(bodyUses[0].stringValue, "body uses must be node locations, not rendered names")
    }

    func testActualParameterBindingAuditCommandOutputPassesPythonStructuralValidator() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())
        let audit = try api.execute(
            "parameter-binding-audit",
            arguments: .object(["function": .string("_main")])
        )
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-app-parameter-audit-\(UUID().uuidString).json")
        try audit.jsonData(prettyPrinted: true).write(to: auditURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: auditURL) }

        let repositoryRoot = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent() // CoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MacScope
            .deletingLastPathComponent() // repository root
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            repositoryRoot.appendingPathComponent(
                "Scripts/decompiler-oracles/parameter_binding_oracle.py"
            ).path,
            "--validate-audit",
            auditURL.path,
            "--json",
        ]
        process.currentDirectoryURL = repositoryRoot
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let stdoutDrain = CoreTestPipeDrain(stdout)
        let stderrDrain = CoreTestPipeDrain(stderr)
        process.waitUntilExit()
        let stdoutData = stdoutDrain.data()
        let stderrText = stderrDrain.text()
        XCTAssertEqual(process.terminationStatus, 0, stderrText)

        let validation = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: stdoutData) as? [String: Any]
        )
        XCTAssertEqual(validation["schema"] as? String, "parameter-binding-audit-validation-v1")
        XCTAssertEqual(validation["validation_scope"] as? String, "structural-candidate")
        XCTAssertEqual(validation["combined_oracle_comparison"] as? Bool, false)
        XCTAssertEqual(validation["valid"] as? Bool, true)
    }

    func testParameterBindingAuditReportsAuthoritativeMixedRowsAndActualUses() throws {
        let store = makeStore(instructions: [
            InstructionRow(
                address: 0x1000,
                bytes: "e8 03 00 aa",
                mnemonic: "mov",
                operands: "w8, w0",
                hasBreakpoint: false,
                comment: nil
            ),
            InstructionRow(
                address: 0x1004,
                bytes: "09 00 66 9e",
                mnemonic: "fmov",
                operands: "x9, d0",
                hasBreakpoint: false,
                comment: nil
            ),
        ])
        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000),
            "args": .array([
                .object(["name": .string("count"), "type": .string("int")]),
                .object(["name": .string("ratio"), "type": .string("double")]),
            ]),
        ]))

        let byName = try api.execute(
            "parameter-binding-audit",
            arguments: .object(["function": .string("_main")])
        )
        let byInteriorAddress = try api.execute(
            "parameter-binding-audit",
            arguments: .object(["address": .hex(0x1004)])
        )
        XCTAssertEqual(byInteriorAddress, byName)
        XCTAssertEqual(byName["declaration_mode"]?.stringValue, "ordinary")
        XCTAssertEqual(byName["validation_scope"]?.stringValue, "structural-candidate")
        XCTAssertEqual(byName["combined_oracle_comparison"]?.boolValue, false)
        XCTAssertEqual(byName["dangling_body_uses"]?.arrayValue, [])

        let records = try XCTUnwrap(byName["records"]?.arrayValue)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map { $0["row_ordinal"]?.intValue }, [0, 1])
        XCTAssertEqual(records.map { $0["binding"]?.stringValue }, ["gpr:0", "simd:0"])
        XCTAssertEqual(records.map { $0["source_position"]?.intValue }, [0, 1])
        XCTAssertEqual(records.map { $0["location"]?.stringValue }, ["w0", "d0"])
        XCTAssertEqual(records.map { $0["evidence"]?.stringValue }, [
            "authoritative_user", "authoritative_user",
        ])
        XCTAssertEqual(records.map { $0["name"]?.stringValue }, ["count", "ratio"])
        XCTAssertEqual(records.map { $0["type"]?.stringValue }, ["int", "double"])
        XCTAssertEqual(
            records[0]["body_uses"]?.arrayValue?.map { $0["address"]?.stringValue },
            ["0x1000"]
        )
        XCTAssertEqual(
            records[1]["body_uses"]?.arrayValue?.map { $0["address"]?.stringValue },
            ["0x1004"]
        )
    }

    func testParameterBindingAuditDoesNotFabricateVoidForAnEmptyIRParameterTable() throws {
        let store = makeStore(instructions: [
            InstructionRow(
                address: 0x1000,
                bytes: "c0 03 5f d6",
                mnemonic: "ret",
                operands: "",
                hasBreakpoint: false,
                comment: nil
            ),
        ])
        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000),
            "args": .array([]),
        ]))

        let audit = try api.execute(
            "parameter-binding-audit",
            arguments: .object(["address": .hex(0x1000)])
        )
        XCTAssertEqual(audit["schema"]?.stringValue, "parameter-binding-audit-v1")
        XCTAssertEqual(audit["declaration_mode"]?.stringValue, "abi-only")
        XCTAssertEqual(audit["records"]?.arrayValue, [])
        XCTAssertNil(audit["parameter_list"])
        XCTAssertNil(audit["void"])
    }

    func testParameterBindingAuditUsesFocusedImageForCollidingVirtualAddress() throws {
        let address = 0x5000 as UInt64
        let sibling = ImageSlot(rawValue: 1)

        func image(slot: ImageSlot) -> BinaryImage {
            BinaryImage(
                id: UUID(), name: "image-\(slot.rawValue)", path: "/tmp/image-\(slot.rawValue)",
                kind: "Mach-O executable", architecture: "arm64", slot: slot
            )
        }

        func analysis(name: String, instruction: InstructionRow) -> ImageAnalysis {
            var result = ImageAnalysis()
            result.functions = [FunctionSummary(
                id: UUID(), name: name, startAddress: address,
                endAddress: address + 4, confidence: 1
            )]
            result.instructions = [instruction]
            return result
        }

        let primaryInstruction = InstructionRow(
            address: address, bytes: "e8 03 00 aa", mnemonic: "mov", operands: "w8, w0",
            hasBreakpoint: false, comment: "primary"
        )
        let siblingInstruction = InstructionRow(
            address: address, bytes: "09 00 66 9e", mnemonic: "fmov", operands: "x9, d0",
            hasBreakpoint: false, comment: "sibling"
        )
        let snapshot = WorkspaceSnapshot(
            binaries: [image(slot: .primary), image(slot: sibling)],
            analysisBySlot: [
                .primary: analysis(name: "primary", instruction: primaryInstruction),
                sibling: analysis(name: "sibling", instruction: siblingInstruction),
            ]
        )
        let store = WorkspaceStore(
            workspaceName: "Focused Scripting Audit", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        store.focusImage(sibling)
        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(address),
            "args": .array([
                .object(["name": .string("ratio"), "type": .string("double")]),
            ]),
        ]))

        let audit = try api.execute(
            "parameter-binding-audit",
            arguments: .object(["address": .hex(address)])
        )
        XCTAssertEqual(audit["function"]?.stringValue, "sibling")
        XCTAssertEqual(audit["declaration_mode"]?.stringValue, "ordinary")
        let records = try XCTUnwrap(audit["records"]?.arrayValue)
        XCTAssertEqual(records.map { $0["name"]?.stringValue }, ["ratio"])
        XCTAssertEqual(records.map { $0["binding"]?.stringValue }, ["simd:0"])
        XCTAssertEqual(records.map { $0["location"]?.stringValue }, ["d0"])
        XCTAssertEqual(records.first?["body_uses"]?.arrayValue?.first?["address"]?.stringValue, "0x5000")
    }

    func testCallArgumentAuditNoCallEnvelopeUsesWholeFilesAndActiveToolchain() throws {
        let binaryURL = try temporaryAuditBinary([0x01, 0x02, 0x03, 0x04, 0x05])
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        let store = makeAuditStore(
            binaryURL: binaryURL,
            instructions: [auditRow(0x1000, "ret")],
            imageBytes: Data([0xaa])
        )

        let audit = try WorkspaceScriptingAPI(store: store).execute(
            "call-argument-audit",
            arguments: .object(["function": .string("_audit")])
        )

        XCTAssertEqual(objectKeys(audit), [
            "schema", "validation_scope", "combined_oracle_comparison", "image_slot",
            "binary_sha256", "producer_executable_sha256", "toolchain_identity",
            "function", "calls",
        ])
        XCTAssertEqual(audit["schema"]?.stringValue, "call-argument-audit-v1")
        XCTAssertEqual(audit["validation_scope"]?.stringValue, "structural-candidate")
        XCTAssertEqual(audit["combined_oracle_comparison"]?.boolValue, false)
        XCTAssertEqual(audit["image_slot"]?.intValue, 0)
        XCTAssertEqual(
            audit["binary_sha256"]?.stringValue,
            sha256Hex(try Data(contentsOf: binaryURL))
        )
        XCTAssertNotEqual(audit["binary_sha256"]?.stringValue, sha256Hex(Data([0xaa])))

        let executableURL = try runningExecutableURLForAuditTest()
        XCTAssertEqual(
            audit["producer_executable_sha256"]?.stringValue,
            sha256Hex(try Data(contentsOf: executableURL, options: .mappedIfSafe))
        )
        let toolchain = try XCTUnwrap(audit["toolchain_identity"])
        XCTAssertEqual(objectKeys(toolchain), [
            "xcode_version", "xcode_build", "sdk_canonical_name", "sdk_version",
            "clang_version",
        ])
        for key in objectKeys(toolchain) {
            XCTAssertFalse(try XCTUnwrap(toolchain[key]?.stringValue).isEmpty, key)
        }
        XCTAssertEqual(
            toolchain["sdk_canonical_name"]?.stringValue,
            "macosx" + (toolchain["sdk_version"]?.stringValue ?? "")
        )
        XCTAssertFalse(toolchain["xcode_version"]?.stringValue?.hasPrefix("Xcode ") ?? true)
        XCTAssertFalse(toolchain["xcode_build"]?.stringValue?.hasPrefix("Build version ") ?? true)
        XCTAssertFalse(toolchain["clang_version"]?.stringValue?.contains("\n") ?? true)
        let function = try XCTUnwrap(audit["function"])
        XCTAssertEqual(objectKeys(function), ["start_address", "display_name"])
        XCTAssertEqual(function["start_address"]?.stringValue, "0x1000")
        XCTAssertEqual(function["display_name"]?.stringValue, "_audit")
        XCTAssertEqual(audit["calls"]?.arrayValue, [])
        XCTAssertEqual(try ScriptValue.decode(audit.jsonData()), audit)
    }

    func testCallArgumentAuditRequiresExactlyOneNameOrAddressSelector() throws {
        let binaryURL = try temporaryAuditBinary([0x10])
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        let api = WorkspaceScriptingAPI(store: makeAuditStore(
            binaryURL: binaryURL,
            instructions: [auditRow(0x1000, "ret")]
        ))

        let byName = try api.execute(
            "call-argument-audit",
            arguments: .object(["function": .string("_audit")])
        )
        let byAddress = try api.execute(
            "call-argument-audit",
            arguments: .object(["address": .hex(0x1000)])
        )
        XCTAssertEqual(byAddress, byName)
        XCTAssertThrowsError(try api.execute(
            "call-argument-audit",
            arguments: .object([:])
        ))
        XCTAssertThrowsError(try api.execute(
            "call-argument-audit",
            arguments: .object([
                "function": .string("_audit"),
                "address": .hex(0x1000),
            ])
        ))
        XCTAssertThrowsError(try api.execute(
            "call-argument-audit",
            arguments: .object(["function": .int(1)])
        ))
        XCTAssertThrowsError(try api.execute(
            "call-argument-audit",
            arguments: .object(["address": .string("not-an-address")])
        ))
        XCTAssertThrowsError(try api.execute(
            "call-argument-audit",
            arguments: .object(["function": .string("missing")])
        )) { error in
            XCTAssertEqual(
                error as? ScriptingError,
                .invalidArgument("no function named 'missing'")
            )
        }
        XCTAssertThrowsError(try api.execute(
            "call-argument-audit",
            arguments: .object(["address": .hex(0x1004)])
        )) { error in
            XCTAssertEqual(
                error as? ScriptingError,
                .invalidArgument("no function at that address")
            )
        }
        XCTAssertThrowsError(try api.execute(
            "call-argument-audit",
            arguments: .object(["address": .hex(0x2000)])
        )) { error in
            XCTAssertEqual(
                error as? ScriptingError,
                .invalidArgument("no function at that address")
            )
        }
    }

    func testCallArgumentAuditRejectsAmbiguousDuplicateStructuralNameSelector() throws {
        let binaryURL = try temporaryAuditBinary([0x11])
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        let duplicateName = "local_helper"
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(
                id: UUID(), name: binaryURL.lastPathComponent, path: binaryURL.path,
                kind: "Mach-O executable", architecture: "arm64"
            )],
            functions: [
                FunctionSummary(
                    id: UUID(), name: duplicateName, startAddress: 0x1000,
                    endAddress: 0x1004, confidence: 1
                ),
                FunctionSummary(
                    id: UUID(), name: duplicateName, startAddress: 0x2000,
                    endAddress: 0x2004, confidence: 1
                ),
            ],
            instructions: [
                auditRow(0x1000, "ret"),
                auditRow(0x2000, "ret"),
            ],
            xrefs: [],
            hexBytes: Data(),
            imageBytes: Data([0xff])
        )
        let store = WorkspaceStore(
            workspaceName: "Ambiguous Function Name", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )

        XCTAssertThrowsError(try WorkspaceScriptingAPI(store: store).execute(
            "call-argument-audit",
            arguments: .object(["function": .string(duplicateName)])
        )) { error in
            XCTAssertEqual(
                error as? ScriptingError,
                .invalidArgument("function selector 'local_helper' is ambiguous (2 matches)")
            )
        }
    }

    func testCallArgumentAuditRejectsAmbiguousContainingRangesEvenAtExactStart() throws {
        let binaryURL = try temporaryAuditBinary([0x12])
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        let target = 0x3010 as UInt64
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(
                id: UUID(), name: binaryURL.lastPathComponent, path: binaryURL.path,
                kind: "Mach-O executable", architecture: "arm64"
            )],
            functions: [
                FunctionSummary(
                    id: UUID(), name: "outer", startAddress: 0x3000,
                    endAddress: 0x3040, confidence: 1
                ),
                FunctionSummary(
                    id: UUID(), name: "inner_a", startAddress: target,
                    endAddress: 0x3020, confidence: 1
                ),
                FunctionSummary(
                    id: UUID(), name: "inner_b", startAddress: target,
                    endAddress: 0x3020, confidence: 1
                ),
            ],
            instructions: [
                auditRow(0x3000, "nop"),
                auditRow(target, "ret"),
            ],
            xrefs: [],
            hexBytes: Data(),
            imageBytes: Data([0xff])
        )
        let store = WorkspaceStore(
            workspaceName: "Ambiguous Function Ranges", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )

        XCTAssertThrowsError(try WorkspaceScriptingAPI(store: store).execute(
            "call-argument-audit",
            arguments: .object(["address": .hex(target)])
        )) { error in
            XCTAssertEqual(
                error as? ScriptingError,
                .invalidArgument("address selector 0x3010 is ambiguous (3 matches)")
            )
        }
    }

    func testCallArgumentAuditValueIdentityAllowsEmptyUnknownAndExactDepthBoundary() throws {
        func nestedUnary(depth: Int) -> MacIRValue {
            (0..<depth).reduce(MacIRValue.unknown("")) { value, _ in
                .unary(op: "!", value: value)
            }
        }

        let emptyUnknown = try WorkspaceScriptingAPI.callArgumentAuditValueObject(.unknown(""))
        XCTAssertEqual(objectKeys(emptyUnknown), ["kind", "text"])
        XCTAssertEqual(emptyUnknown["kind"]?.stringValue, "unknown")
        XCTAssertEqual(emptyUnknown["text"]?.stringValue, "")
        XCTAssertNoThrow(try WorkspaceScriptingAPI.callArgumentAuditValueObject(
            nestedUnary(depth: 32)
        ))
        XCTAssertThrowsError(try WorkspaceScriptingAPI.callArgumentAuditValueObject(
            nestedUnary(depth: 33)
        ))
        XCTAssertThrowsError(try WorkspaceScriptingAPI.callArgumentAuditValueObject(.symbol("")))
    }

    func testCallArgumentAuditToolchainPinsOneCanonicalDeveloperDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-toolchain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let developer = root.appendingPathComponent("Developer")
        let xcodebuild = developer.appendingPathComponent("usr/bin/xcodebuild")
        let clang = developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")
        let sdk = developer.appendingPathComponent(
            "Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk"
        )
        try FileManager.default.createDirectory(
            at: xcodebuild.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: clang.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try Data().write(to: xcodebuild)
        try Data().write(to: clang)

        var pinnedDeveloperDirectories: [String] = []
        let identity = try WorkspaceScriptingAPI.sampleCallArgumentAuditToolchainIdentity(
            environment: ["DEVELOPER_DIR": developer.path]
        ) { executableURL, arguments, environment, _ in
            let pinned = try XCTUnwrap(environment["DEVELOPER_DIR"])
            pinnedDeveloperDirectories.append(pinned)
            XCTAssertEqual(pinned, developer.path)
            if executableURL == xcodebuild, arguments == ["-version"] {
                return "\n  Xcode 27.0  \n  Build version 18A123  \n"
            }
            if executableURL == clang, arguments == ["--version"] {
                return "\n  Apple clang version 18.0.0 (clang-1800.0.1)  \n"
                    + "  Target: arm64-apple-darwin  \n"
            }
            XCTAssertEqual(executableURL.path, "/usr/bin/xcrun")
            return switch arguments {
            case ["--find", "xcodebuild"]: "\n  \(xcodebuild.path)  \n"
            case ["--find", "clang"]: "\n  \(clang.path)  \n"
            case ["--sdk", "macosx", "--show-sdk-path"]: "\n  \(sdk.path)  \n"
            case ["--sdk", "macosx", "--show-sdk-version"]: "\n  27.0  \n"
            default: throw ScriptingError.invalidArgument("unexpected fake tool invocation")
            }
        }

        XCTAssertEqual(pinnedDeveloperDirectories.count, 6)
        XCTAssertEqual(Set(pinnedDeveloperDirectories), [developer.path])
        XCTAssertEqual(identity["xcode_version"]?.stringValue, "27.0")
        XCTAssertEqual(identity["xcode_build"]?.stringValue, "18A123")
        XCTAssertEqual(identity["sdk_canonical_name"]?.stringValue, "macosx27.0")
        XCTAssertEqual(identity["sdk_version"]?.stringValue, "27.0")
        XCTAssertEqual(
            identity["clang_version"]?.stringValue,
            "Apple clang version 18.0.0 (clang-1800.0.1)"
        )
        let expectedBytes: [String: Data] = [
            "xcode_version": Data("27.0".utf8),
            "xcode_build": Data("18A123".utf8),
            "sdk_canonical_name": Data("macosx27.0".utf8),
            "sdk_version": Data("27.0".utf8),
            "clang_version": Data("Apple clang version 18.0.0 (clang-1800.0.1)".utf8),
        ]
        for (key, expected) in expectedBytes {
            XCTAssertEqual(identity[key]?.stringValue.map { Data($0.utf8) }, expected, key)
        }
    }

    func testCallArgumentAuditToolchainRejectsMixedOrMalformedIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-toolchain-negative-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let developer = root.appendingPathComponent("Developer")
        let xcodebuild = developer.appendingPathComponent("usr/bin/xcodebuild")
        let clang = developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")
        let sdk = developer.appendingPathComponent(
            "Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk"
        )
        for directory in [
            xcodebuild.deletingLastPathComponent(), clang.deletingLastPathComponent(), sdk,
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: xcodebuild)
        try Data().write(to: clang)

        func output(
            executableURL: URL,
            arguments: [String],
            mixedClang: Bool = false,
            malformedXcode: Bool = false
        ) throws -> String {
            if executableURL == xcodebuild, arguments == ["-version"] {
                return malformedXcode
                    ? "untrusted prefix\nXcode 27.0\nBuild version 18A123"
                    : "Xcode 27.0\nBuild version 18A123"
            }
            if arguments == ["--version"] {
                XCTAssertEqual(executableURL, clang)
                return "Apple clang version 18.0.0"
            }
            switch arguments {
            case ["--find", "xcodebuild"]: return xcodebuild.path
            case ["--find", "clang"]: return mixedClang ? "/usr/bin/clang" : clang.path
            case ["--sdk", "macosx", "--show-sdk-path"]: return sdk.path
            case ["--sdk", "macosx", "--show-sdk-version"]: return "27.0"
            default: throw ScriptingError.invalidArgument("unexpected fake tool invocation")
            }
        }

        XCTAssertThrowsError(try WorkspaceScriptingAPI.sampleCallArgumentAuditToolchainIdentity(
            environment: ["DEVELOPER_DIR": developer.path]
        ) { executableURL, arguments, _, _ in
            try output(
                executableURL: executableURL, arguments: arguments, mixedClang: true
            )
        })
        XCTAssertThrowsError(try WorkspaceScriptingAPI.sampleCallArgumentAuditToolchainIdentity(
            environment: ["DEVELOPER_DIR": developer.path]
        ) { executableURL, arguments, _, _ in
            try output(
                executableURL: executableURL, arguments: arguments, malformedXcode: true
            )
        })
    }

    func testCallArgumentAuditProcessRunnerDrainsSimultaneousUnderCapPipes() throws {
        let byteCount = callArgumentAuditTestOutputLimit - 1_024
        let output = try WorkspaceScriptingAPI.runCallArgumentAuditProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                /usr/bin/head -c \(byteCount) /dev/zero &
                /usr/bin/head -c \(byteCount) /dev/zero >&2 &
                wait
                /usr/bin/printf ok
                """,
            ],
            environment: ["LC_ALL": "C", "PATH": "/usr/bin:/bin"],
            timeout: 2
        )

        XCTAssertEqual(output.utf8.count, byteCount + 2)
        XCTAssertTrue(output.hasSuffix("ok"))
    }

    func testCallArgumentAuditProcessRunnerRejectsStdoutOverflow() {
        let byteCount = callArgumentAuditTestOutputLimit + 1
        XCTAssertThrowsError(try WorkspaceScriptingAPI.runCallArgumentAuditProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "\(byteCount)", "/dev/zero"],
            environment: ["LC_ALL": "C"],
            timeout: 2
        )) { error in
            XCTAssertEqual(
                error as? ScriptingError,
                .invalidArgument(
                    "audit child stdout exceeded \(callArgumentAuditTestOutputLimit) bytes"
                )
            )
        }
    }

    func testCallArgumentAuditProcessRunnerRejectsStderrOverflow() {
        let byteCount = callArgumentAuditTestOutputLimit + 1
        XCTAssertThrowsError(try WorkspaceScriptingAPI.runCallArgumentAuditProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/head -c \(byteCount) /dev/zero >&2"],
            environment: ["LC_ALL": "C", "PATH": "/usr/bin:/bin"],
            timeout: 2
        )) { error in
            XCTAssertEqual(
                error as? ScriptingError,
                .invalidArgument(
                    "audit child stderr exceeded \(callArgumentAuditTestOutputLimit) bytes"
                )
            )
        }
    }

    func testCallArgumentAuditProcessRunnerRejectsInvalidUTF8() {
        XCTAssertThrowsError(try WorkspaceScriptingAPI.runCallArgumentAuditProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["\\377"],
            environment: ["LC_ALL": "C"],
            timeout: 2
        )) { error in
            XCTAssertEqual(
                error as? ScriptingError,
                .invalidArgument("audit child stdout is not valid UTF-8")
            )
        }
    }

    func testCallArgumentAuditProcessRunnerReapsItsTERMIgnoringOwnedPID() throws {
        let pidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-audit-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidURL) }
        let started = Date()
        XCTAssertThrowsError(try WorkspaceScriptingAPI.runCallArgumentAuditProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "trap '' TERM; printf '%d' \"$$\" > \"$MACSCOPE_PID_FILE\"; while :; do :; done",
            ],
            environment: ["LC_ALL": "C", "MACSCOPE_PID_FILE": pidURL.path],
            timeout: 0.2
        )) { error in
            XCTAssertEqual(
                error as? ScriptingError,
                .invalidArgument("audit child sh exceeded 0.2 seconds")
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)

        let pidText = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ownedPID = try XCTUnwrap(pid_t(pidText))
        defer {
            if kill(ownedPID, 0) == 0 {
                _ = kill(ownedPID, SIGKILL)
            }
        }
        errno = 0
        XCTAssertEqual(kill(ownedPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testCallArgumentAuditProcessRunnerRejectsInvalidTimeoutsBeforeLaunch() {
        let executable = URL(fileURLWithPath: "/definitely/not/a/real/executable")
        for timeout in [
            TimeInterval.zero, -1, TimeInterval.infinity, TimeInterval.nan,
        ] {
            XCTAssertThrowsError(try WorkspaceScriptingAPI.runCallArgumentAuditProcess(
                executableURL: executable,
                arguments: [],
                environment: [:],
                timeout: timeout
            )) { error in
                XCTAssertEqual(
                    error as? ScriptingError,
                    .invalidArgument("audit child timeout must be positive and finite")
                )
            }
        }
    }

    func testCallArgumentAuditProcessRunnerTimesOutOnlyItsOwnedPID() throws {
        let started = Date()
        XCTAssertThrowsError(try WorkspaceScriptingAPI.runCallArgumentAuditProcess(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["2"],
            environment: ["LC_ALL": "C"],
            timeout: 0.05
        ))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testCallArgumentAuditRenderedOccurrenceCountsIdenticalUTF8Lines() throws {
        let text = "    _free(x0_1);"
        func source(_ address: UInt64) -> MacIRSourceSpan {
            MacIRSourceSpan(
                address: address, byteText: "00 00 00 94", mnemonic: "bl",
                operands: "_free"
            )
        }
        let document = PseudocodeDocument(
            functionName: "duplicate_calls",
            lines: [
                PseudocodeLine(lineNumber: 1, text: text, source: source(0x1004)),
                PseudocodeLine(lineNumber: 2, text: text, source: source(0x1008)),
            ]
        )
        let first = try WorkspaceScriptingAPI.callArgumentAuditRenderedBinding(
            instructionAddress: 0x1004, document: document
        )
        let second = try WorkspaceScriptingAPI.callArgumentAuditRenderedBinding(
            instructionAddress: 0x1008, document: document
        )
        XCTAssertEqual([first.occurrence, second.occurrence], [0, 1])
        XCTAssertEqual(first.utf8SHA256, second.utf8SHA256)
        XCTAssertEqual(first.line.text, text)
        XCTAssertEqual(second.line.text, text)
    }

    func testCallArgumentAuditFileFingerprintDetectsAtomicAndSymlinkReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-fingerprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("binary")
        try Data([0x01, 0x02]).write(to: binary)
        let initial = try WorkspaceScriptingAPI.callArgumentAuditFileFingerprint(at: binary)
        XCTAssertEqual(
            try WorkspaceScriptingAPI.callArgumentAuditFileFingerprint(at: binary),
            initial
        )

        let replacement = root.appendingPathComponent("replacement")
        try Data([0x03, 0x04]).write(to: replacement)
        XCTAssertEqual(rename(replacement.path, binary.path), 0)
        let replaced = try WorkspaceScriptingAPI.callArgumentAuditFileFingerprint(at: binary)
        XCTAssertNotEqual(replaced, initial)

        let secondTarget = root.appendingPathComponent("second-target")
        try Data([0x05]).write(to: secondTarget)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        let linkedInitial = try WorkspaceScriptingAPI.callArgumentAuditFileFingerprint(at: link)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secondTarget)
        let linkedReplaced = try WorkspaceScriptingAPI.callArgumentAuditFileFingerprint(at: link)
        XCTAssertNotEqual(linkedReplaced, linkedInitial)
        XCTAssertThrowsError(try WorkspaceScriptingAPI.callArgumentAuditFileFingerprint(at: root))
    }

    func testCallArgumentAuditDescriptorDigestIsChunkedAndRejectsSizeDrift() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-fingerprint-chunks-\(UUID().uuidString)")
        let bytes = Data((0..<10_003).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        func digest(
            afterChunk: ((Int64) throws -> Void)? = nil
        ) throws -> String {
            let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw XCTSkip("could not open chunked fingerprint fixture")
            }
            defer { close(descriptor) }
            return try WorkspaceScriptingAPI.callArgumentAuditDescriptorDigest(
                descriptor: descriptor,
                expectedSize: Int64(bytes.count),
                chunkSize: 113,
                afterChunk: afterChunk
            )
        }

        XCTAssertEqual(try digest(), sha256Hex(bytes))

        let appendHandle = try FileHandle(forWritingTo: file)
        defer { try? appendHandle.close() }
        var appended = false
        XCTAssertThrowsError(try digest { _ in
            guard !appended else { return }
            appended = true
            try appendHandle.seekToEnd()
            try appendHandle.write(contentsOf: Data([0xff]))
        }) { error in
            XCTAssertEqual(
                error as? ScriptingError,
                .invalidArgument("audit file changed size while it was fingerprinted")
            )
        }

        try appendHandle.close()
        try bytes.write(to: file, options: .atomic)
        let truncateHandle = try FileHandle(forWritingTo: file)
        defer { try? truncateHandle.close() }
        var truncated = false
        XCTAssertThrowsError(try digest { _ in
            guard !truncated else { return }
            truncated = true
            try truncateHandle.truncate(atOffset: UInt64(bytes.count / 2))
        }) { error in
            XCTAssertEqual(
                error as? ScriptingError,
                .invalidArgument("audit file changed size while it was fingerprinted")
            )
        }
    }

    func testCallArgumentAuditFocusStabilityRejectsSlotOrBinaryMismatch() {
        let captured = BinaryImage(
            id: UUID(), name: "captured", path: "/tmp/captured",
            kind: "Mach-O executable", architecture: "arm64"
        )
        let capturedSnapshot = WorkspaceSnapshot(
            binaries: [captured], analysisBySlot: [.primary: ImageAnalysis()]
        )
        XCTAssertTrue(WorkspaceScriptingAPI.callArgumentAuditFocusIsStable(
            capturedSlot: .primary,
            capturedBinary: captured,
            currentSlot: .primary,
            currentSnapshot: capturedSnapshot
        ))
        XCTAssertFalse(WorkspaceScriptingAPI.callArgumentAuditFocusIsStable(
            capturedSlot: .primary,
            capturedBinary: captured,
            currentSlot: ImageSlot(rawValue: 1),
            currentSnapshot: capturedSnapshot
        ))
        var replacement = captured
        replacement.name = "replaced"
        let replacementSnapshot = WorkspaceSnapshot(
            binaries: [replacement], analysisBySlot: [.primary: ImageAnalysis()]
        )
        XCTAssertFalse(WorkspaceScriptingAPI.callArgumentAuditFocusIsStable(
            capturedSlot: .primary,
            capturedBinary: captured,
            currentSlot: .primary,
            currentSnapshot: replacementSnapshot
        ))
    }

    func testCallArgumentAuditRejectsMissingWholeBinaryAndIgnoresFunctionPresentationName() throws {
        let binaryURL = try temporaryAuditBinary([0x11, 0x12])
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        let store = makeAuditStore(
            binaryURL: binaryURL,
            instructions: [auditRow(0x1000, "ret")],
            addressOverrides: [
                .primary(0x1000): AddressOverride(customName: "presentation_only_name"),
            ]
        )
        let api = WorkspaceScriptingAPI(store: store)
        let structural = try api.execute(
            "call-argument-audit",
            arguments: .object(["address": .hex(0x1000)])
        )
        XCTAssertEqual(structural["function"]?["display_name"]?.stringValue, "_audit")

        try FileManager.default.removeItem(at: binaryURL)
        XCTAssertThrowsError(try api.execute(
            "call-argument-audit",
            arguments: .object(["address": .hex(0x1000)])
        ))
    }

    func testCallArgumentAuditBindsEveryStructuralCallToItsExactRenderedLine() throws {
        let binaryURL = try temporaryAuditBinary([0x20, 0x21])
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        let rows = [
            auditRow(0x1000, "mov", "x0, #1"),
            auditRow(0x1004, "bl", "_free"),
            auditRow(0x1008, "mov", "x0, #2"),
            auditRow(0x100c, "bl", "_free"),
            auditRow(0x1010, "ret"),
        ]
        let api = WorkspaceScriptingAPI(store: makeAuditStore(
            binaryURL: binaryURL, instructions: rows
        ))
        let audit = try api.execute(
            "call-argument-audit",
            arguments: .object(["address": .hex(0x1000)])
        )
        let decompile = try api.execute(
            "decompile",
            arguments: .object(["address": .hex(0x1000)])
        )
        let renderedLines = try XCTUnwrap(decompile["lines"]?.arrayValue)
        let calls = try XCTUnwrap(audit["calls"]?.arrayValue)

        XCTAssertEqual(calls.map { $0["instruction_address"]?.stringValue }, [
            "0x1004", "0x100c",
        ])
        for call in calls {
            XCTAssertEqual(objectKeys(call), [
                "instruction_address", "target", "known_signature_id", "tail_count_evidence",
                "rendered_line_ordinal", "rendered_occurrence_ordinal", "rendered_utf8_sha256",
                "observation", "control_inputs", "arguments",
            ])
            let ordinal = try XCTUnwrap(call["rendered_line_ordinal"]?.intValue)
            let rendered = renderedLines[Int(ordinal - 1)]
            let lineText = try XCTUnwrap(rendered["text"]?.stringValue)
            XCTAssertEqual(rendered["address"]?.stringValue, call["instruction_address"]?.stringValue)
            XCTAssertEqual(call["rendered_utf8_sha256"]?.stringValue, sha256Hex(Data(lineText.utf8)))
            let earlier = renderedLines.prefix(Int(ordinal - 1)).filter {
                Data(($0["text"]?.stringValue ?? "").utf8) == Data(lineText.utf8)
            }
            XCTAssertEqual(call["rendered_occurrence_ordinal"]?.intValue, Int64(earlier.count))
            XCTAssertEqual(call["target"]?.stringValue, "_free")
            XCTAssertEqual(call["known_signature_id"]?.stringValue, "_free")
            XCTAssertEqual(call["tail_count_evidence"], .null)

            let observation = try XCTUnwrap(call["observation"])
            XCTAssertEqual(observation["gpr_indices"]?.arrayValue, [])
            XCTAssertEqual(observation["scalar_simd_indices"]?.arrayValue, [])
            XCTAssertEqual(observation["call_stack_ranges"]?.arrayValue, [])
            XCTAssertEqual(call["control_inputs"]?.arrayValue, [])
            let argument = try XCTUnwrap(call["arguments"]?.arrayValue?.first)
            XCTAssertEqual(objectKeys(argument), [
                "location", "role", "source_position", "tail_ordinal", "value_identity",
                "selector_name", "selector_selref_address", "safe_render_included",
                "safe_render_reason",
            ])
            XCTAssertEqual(argument["role"]?.stringValue, "fixed")
            XCTAssertEqual(argument["source_position"]?.intValue, 0)
            XCTAssertEqual(argument["tail_ordinal"], .null)
            XCTAssertEqual(argument["selector_name"], .null)
            XCTAssertEqual(argument["selector_selref_address"], .null)
            XCTAssertEqual(argument["safe_render_included"]?.boolValue, true)
            XCTAssertEqual(argument["safe_render_reason"]?.stringValue, "fixed-prefix")
            let location = try XCTUnwrap(argument["location"])
            XCTAssertEqual(objectKeys(location), [
                "kind", "index", "carrier_width", "scalar_width", "byte_offset", "size",
                "alignment",
            ])
            XCTAssertEqual(location["kind"]?.stringValue, "gpr")
            XCTAssertEqual(location["index"]?.intValue, 0)
            XCTAssertEqual(location["carrier_width"]?.intValue, 64)
            for key in ["scalar_width", "byte_offset", "size", "alignment"] {
                XCTAssertEqual(location[key], .null, key)
            }
        }
    }

    func testCallArgumentAuditUnknownSparseGPRUsesOnlyDenseSafePrefix() throws {
        let binaryURL = try temporaryAuditBinary([0x30])
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        let api = WorkspaceScriptingAPI(store: makeAuditStore(
            binaryURL: binaryURL,
            instructions: [
                auditRow(0x1000, "mov", "w0, #1"),
                auditRow(0x1004, "mov", "x2, #2"),
                auditRow(0x1008, "bl", "mystery_target"),
                auditRow(0x100c, "ret"),
            ]
        ))
        let call = try XCTUnwrap(try api.execute(
            "call-argument-audit",
            arguments: .object(["address": .hex(0x1000)])
        )["calls"]?.arrayValue?.first)

        XCTAssertEqual(call["known_signature_id"], .null)
        let arguments = try XCTUnwrap(call["arguments"]?.arrayValue)
        XCTAssertEqual(arguments.map { $0["location"]?["index"]?.intValue }, [0, 2])
        XCTAssertEqual(arguments.map { $0["role"]?.stringValue }, ["unknown", "unknown"])
        XCTAssertEqual(arguments[0]["source_position"], .null)
        XCTAssertEqual(arguments[1]["source_position"], .null)
        XCTAssertEqual(arguments[0]["tail_ordinal"], .null)
        XCTAssertEqual(arguments[1]["tail_ordinal"], .null)
        XCTAssertEqual(arguments.map { $0["safe_render_included"]?.boolValue }, [true, false])
        XCTAssertEqual(arguments.map { $0["safe_render_reason"]?.stringValue }, [
            "unknown-gpr-prefix", "unknown-gap",
        ])
        for argument in arguments {
            let identity = try XCTUnwrap(argument["value_identity"])
            XCTAssertEqual(objectKeys(identity), ["kind", "name", "version"])
            XCTAssertEqual(identity["kind"]?.stringValue, "register")
            XCTAssertNotNil(identity["name"]?.stringValue)
            XCTAssertNotNil(identity["version"]?.intValue)
        }
        XCTAssertEqual(
            call["observation"]?["gpr_indices"]?.arrayValue?.compactMap(\.intValue),
            Array(0...7).map { Int64($0) }
        )
    }

    func testCallArgumentAuditPreservesSameRegisterAuthenticatedControlsTwice() throws {
        let binaryURL = try temporaryAuditBinary([0x40])
        defer { try? FileManager.default.removeItem(at: binaryURL) }
        let api = WorkspaceScriptingAPI(store: makeAuditStore(
            binaryURL: binaryURL,
            instructions: [
                auditRow(0x1000, "mov", "x1, #0x4000"),
                auditRow(0x1004, "blraa", "x1, x1"),
                auditRow(0x1008, "ret"),
            ]
        ))
        let call = try XCTUnwrap(try api.execute(
            "call-argument-audit",
            arguments: .object(["address": .hex(0x1000)])
        )["calls"]?.arrayValue?.first)

        XCTAssertEqual(call["target"]?.stringValue, "(*x1)")
        XCTAssertEqual(call["known_signature_id"], .null)
        let controls = try XCTUnwrap(call["control_inputs"]?.arrayValue)
        XCTAssertEqual(controls.map { $0["role"]?.stringValue }, [
            "indirect-target", "pointer-authentication-modifier",
        ])
        XCTAssertEqual(controls.map { $0["register"]?.stringValue }, ["x1", "x1"])
        let targetIdentity = try XCTUnwrap(controls[0]["value_identity"])
        let modifierIdentity = try XCTUnwrap(controls[1]["value_identity"])
        XCTAssertEqual(objectKeys(targetIdentity), ["kind", "name", "version"])
        XCTAssertEqual(objectKeys(modifierIdentity), ["kind", "name", "version"])
        XCTAssertEqual(targetIdentity["kind"]?.stringValue, "register")
        XCTAssertEqual(targetIdentity["name"]?.stringValue, "x1")
        XCTAssertNotNil(targetIdentity["version"]?.intValue)
        XCTAssertEqual(modifierIdentity, targetIdentity)
        XCTAssertFalse(call["arguments"]?.arrayValue?.contains {
            $0["location"]?["kind"]?.stringValue == "gpr"
                && $0["location"]?["index"]?.intValue == 1
        } ?? true)
        XCTAssertFalse(
            call["observation"]?["gpr_indices"]?.arrayValue?.compactMap(\.intValue).contains(1)
                ?? true
        )
    }

    func testCallArgumentAuditSelectorEvidenceControlsSafePresentationClassification() throws {
        func audit(selector: String, marker: UInt8) throws -> (call: ScriptValue, line: String) {
            let binaryURL = try temporaryAuditBinary([marker])
            defer { try? FileManager.default.removeItem(at: binaryURL) }
            let selectorAddress = 0x1000_08010 as UInt64
            let api = WorkspaceScriptingAPI(store: makeAuditStore(
                binaryURL: binaryURL,
                name: "selector_case",
                startAddress: 0x6000,
                instructions: [
                    auditRow(0x6000, "adrp", "x1, 0x100008000"),
                    auditRow(0x6004, "ldr", "x1, [x1, #0x10]"),
                    auditRow(0x6008, "mov", "x0, #1"),
                    auditRow(0x600c, "bl", "_objc_msgSend"),
                    auditRow(0x6010, "ret"),
                ],
                objcSelectors: [selectorAddress: selector]
            ))
            let audit = try api.execute(
                "call-argument-audit",
                arguments: .object(["address": .hex(0x6000)])
            )
            let call = try XCTUnwrap(audit["calls"]?.arrayValue?.first)
            let decompile = try api.execute(
                "decompile", arguments: .object(["address": .hex(0x6000)])
            )
            let ordinal = try XCTUnwrap(call["rendered_line_ordinal"]?.intValue)
            let line = try XCTUnwrap(
                decompile["lines"]?.arrayValue?[Int(ordinal - 1)]["text"]?.stringValue
            )
            return (call, line)
        }

        let positiveResult = try audit(selector: "setObject:", marker: 0x50)
        let positive = positiveResult.call
        XCTAssertEqual(
            positive["tail_count_evidence"]?["kind"]?.stringValue,
            "objective-c-selector-colon-count"
        )
        XCTAssertEqual(
            objectKeys(try XCTUnwrap(positive["tail_count_evidence"])),
            ["kind", "expected_tail_count"]
        )
        XCTAssertEqual(positive["tail_count_evidence"]?["expected_tail_count"]?.intValue, 1)
        let positiveArguments = try XCTUnwrap(positive["arguments"]?.arrayValue)
        XCTAssertEqual(positiveArguments.map { $0["role"]?.stringValue }, ["fixed", "fixed"])
        XCTAssertEqual(positiveArguments.map { $0["safe_render_reason"]?.stringValue }, [
            "fixed-prefix", "fixed-prefix",
        ])
        XCTAssertEqual(positiveArguments.map { $0["safe_render_included"]?.boolValue }, [
            true, true,
        ])
        XCTAssertEqual(positive["observation"]?["gpr_indices"]?.arrayValue, [])
        XCTAssertEqual(positive["observation"]?["scalar_simd_indices"]?.arrayValue, [])
        XCTAssertEqual(positive["observation"]?["call_stack_ranges"]?.arrayValue, [])
        XCTAssertEqual(positiveArguments[1]["selector_name"]?.stringValue, "setObject:")
        XCTAssertEqual(positiveArguments[1]["selector_selref_address"]?.stringValue, "0x100008010")
        XCTAssertEqual(positiveArguments[1]["value_identity"]?["kind"]?.stringValue, "register")
        XCTAssertTrue(positiveResult.line.contains("_objc_msgSend("), positiveResult.line)
        XCTAssertTrue(positiveResult.line.contains("\"setObject:\""), positiveResult.line)
        XCTAssertFalse(positiveResult.line.contains("["), positiveResult.line)

        let completeResult = try audit(selector: "viewDidLoad", marker: 0x51)
        let complete = completeResult.call
        XCTAssertEqual(complete["tail_count_evidence"]?["expected_tail_count"]?.intValue, 0)
        XCTAssertEqual(
            complete["arguments"]?.arrayValue?.map { $0["safe_render_reason"]?.stringValue },
            ["objc-complete-message", "objc-complete-message"]
        )
        XCTAssertEqual(
            complete["arguments"]?.arrayValue?.map { $0["safe_render_included"]?.boolValue },
            [true, true]
        )
        XCTAssertEqual(complete["observation"]?["gpr_indices"]?.arrayValue, [])
        XCTAssertEqual(complete["observation"]?["scalar_simd_indices"]?.arrayValue, [])
        XCTAssertEqual(complete["observation"]?["call_stack_ranges"]?.arrayValue, [])
        XCTAssertTrue(completeResult.line.contains(" viewDidLoad]"), completeResult.line)
        let completeStatement = String(completeResult.line.prefix { $0 != ";" })
        XCTAssertFalse(completeStatement.contains("_objc_msgSend("), completeResult.line)
        XCTAssertTrue(completeResult.line.contains("// call; signature id _objc_msgSend("))

        let grammarFallbackResult = try audit(selector: "safe-name", marker: 0x52)
        let grammarFallback = grammarFallbackResult.call
        XCTAssertEqual(grammarFallback["tail_count_evidence"]?["expected_tail_count"]?.intValue, 0)
        XCTAssertEqual(
            grammarFallback["arguments"]?.arrayValue?.map { $0["safe_render_reason"]?.stringValue },
            ["fixed-prefix", "fixed-prefix"]
        )
        XCTAssertEqual(
            grammarFallback["arguments"]?.arrayValue?.map {
                $0["safe_render_included"]?.boolValue
            },
            [true, true]
        )
        XCTAssertEqual(grammarFallback["observation"]?["gpr_indices"]?.arrayValue, [])
        XCTAssertEqual(grammarFallback["observation"]?["scalar_simd_indices"]?.arrayValue, [])
        XCTAssertEqual(grammarFallback["observation"]?["call_stack_ranges"]?.arrayValue, [])
        XCTAssertTrue(grammarFallbackResult.line.contains("_objc_msgSend("), grammarFallbackResult.line)
        XCTAssertTrue(grammarFallbackResult.line.contains("\"safe-name\""), grammarFallbackResult.line)
        XCTAssertFalse(grammarFallbackResult.line.contains("["), grammarFallbackResult.line)
    }

    func testCallArgumentAuditZeroSelectorRequiresOneOuterBracketExpression() {
        XCTAssertTrue(WorkspaceScriptingAPI.isExactZeroSelectorMessageForAudit(
            "return [[factory receiver] viewDidLoad]; // call; signature id _objc_msgSend(id, SEL)",
            selector: "viewDidLoad"
        ))
        XCTAssertFalse(WorkspaceScriptingAPI.isExactZeroSelectorMessageForAudit(
            "[x foo] [attacker viewDidLoad]; // call; signature id _objc_msgSend(id, SEL)",
            selector: "viewDidLoad"
        ))
        XCTAssertFalse(WorkspaceScriptingAPI.isExactZeroSelectorMessageForAudit(
            "[x viewDidLoad]; [attacker viewDidLoad]",
            selector: "viewDidLoad"
        ))
    }

    func testCallArgumentAuditUsesFocusedSiblingForCollidingVirtualAddressAndDigest() throws {
        let primaryURL = try temporaryAuditBinary([0x60])
        let siblingURL = try temporaryAuditBinary([0x61, 0x62])
        defer {
            try? FileManager.default.removeItem(at: primaryURL)
            try? FileManager.default.removeItem(at: siblingURL)
        }
        let address = 0x5000 as UInt64
        let sibling = ImageSlot(rawValue: 1)
        func binary(_ slot: ImageSlot, _ url: URL) -> BinaryImage {
            BinaryImage(
                id: UUID(), name: url.lastPathComponent, path: url.path,
                kind: "Mach-O executable", architecture: "arm64", slot: slot
            )
        }
        var primaryAnalysis = ImageAnalysis()
        primaryAnalysis.functions = [FunctionSummary(
            id: UUID(), name: "primary", startAddress: address,
            endAddress: address + 4, confidence: 1
        )]
        primaryAnalysis.instructions = [auditRow(address, "ret")]
        primaryAnalysis.imageBytes = Data([0xa0])
        var siblingAnalysis = ImageAnalysis()
        siblingAnalysis.functions = [FunctionSummary(
            id: UUID(), name: "sibling", startAddress: address,
            endAddress: address + 12, confidence: 1
        )]
        siblingAnalysis.instructions = [
            auditRow(address, "mov", "x0, #7"),
            auditRow(address + 4, "bl", "_free"),
            auditRow(address + 8, "ret"),
        ]
        siblingAnalysis.imageBytes = Data([0xb0])
        let snapshot = WorkspaceSnapshot(
            binaries: [binary(.primary, primaryURL), binary(sibling, siblingURL)],
            analysisBySlot: [.primary: primaryAnalysis, sibling: siblingAnalysis]
        )
        let store = WorkspaceStore(
            workspaceName: "Call Audit Focus", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        store.focusImage(sibling)

        let audit = try WorkspaceScriptingAPI(store: store).execute(
            "call-argument-audit",
            arguments: .object(["address": .hex(address)])
        )
        XCTAssertEqual(audit["image_slot"]?.intValue, 1)
        XCTAssertEqual(audit["function"]?["display_name"]?.stringValue, "sibling")
        XCTAssertEqual(audit["calls"]?.arrayValue?.count, 1)
        XCTAssertEqual(
            audit["binary_sha256"]?.stringValue,
            sha256Hex(try Data(contentsOf: siblingURL))
        )
        XCTAssertNotEqual(
            audit["binary_sha256"]?.stringValue,
            sha256Hex(try Data(contentsOf: primaryURL))
        )
    }

    private func assertRegionJSON(_ node: ScriptValue, lineCount: Int) throws {
        let startLine = try XCTUnwrap(node["startLine"]?.intValue)
        let endLine = try XCTUnwrap(node["endLine"]?.intValue)
        XCTAssertGreaterThanOrEqual(startLine, 1)
        XCTAssertLessThanOrEqual(endLine, Int64(lineCount))
        XCTAssertLessThanOrEqual(startLine, endLine)
        XCTAssertNotNil(node["kind"]?.stringValue)
        let children = try XCTUnwrap(node["children"]?.arrayValue)
        var previousEnd: Int64?
        for child in children {
            let childStart = try XCTUnwrap(child["startLine"]?.intValue)
            let childEnd = try XCTUnwrap(child["endLine"]?.intValue)
            XCTAssertGreaterThanOrEqual(childStart, startLine)
            XCTAssertLessThanOrEqual(childEnd, endLine)
            if let previousEnd {
                XCTAssertLessThan(previousEnd, childStart)
            }
            previousEnd = childEnd
            try assertRegionJSON(child, lineCount: lineCount)
        }
    }

    private func regionJSONContainsControlConstruct(_ node: ScriptValue) -> Bool {
        switch node["kind"]?.stringValue {
        case "ifThen", "ifThenElse", "whileLoop", "doWhileLoop", "switchDispatch":
            return true
        default:
            return node["children"]?.arrayValue?.contains { regionJSONContainsControlConstruct($0) } ?? false
        }
    }

    func testCallersCalleesAndResolveSymbol() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())
        // The fixture has a call edge 0x1004 -> 0x1008 (helper at 0x1008).
        let callees = try api.execute("callees", arguments: .object(["function": .string("_main")])).arrayValue
        XCTAssertEqual(callees?.first?["from"]?.stringValue, "0x1004")
        let callers = try api.execute("callers", arguments: .object(["address": .hex(0x1008)])).arrayValue
        XCTAssertEqual(callers?.first?["to"]?.stringValue, "0x1008")
        XCTAssertEqual(try api.execute("resolve-symbol", arguments: .object(["name": .string("_main")])).stringValue, "0x1000")
    }

    func testImportsExportsAndBasicBlocks() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())

        let imports = try api.execute("imports").arrayValue
        XCTAssertEqual(imports?.first?["name"]?.stringValue, "_printf")
        XCTAssertEqual(imports?.first?["library"]?.stringValue, "libSystem")
        XCTAssertEqual(imports?.first?["ordinal"]?.intValue, 1)

        let exports = try api.execute("exports").arrayValue
        XCTAssertEqual(exports?.first?["name"]?.stringValue, "_main")
        XCTAssertEqual(exports?.first?["address"]?.stringValue, "0x1000")

        let sections = try api.execute("sections").arrayValue
        XCTAssertEqual(sections?.first?["name"]?.stringValue, "__TEXT,__text")
        XCTAssertEqual(sections?.first?["address"]?.stringValue, "0x1000")
        XCTAssertEqual(sections?.first?["fileOffset"]?.stringValue, "0x1000")
        XCTAssertEqual(sections?.first?["size"]?.intValue, 0x200)
        XCTAssertEqual(sections?.first?["executable"]?.boolValue, true)

        // basic-blocks of _main: one block 0x1000..<0x1008 with the call edge as a successor.
        let blocks = try api.execute("basic-blocks", arguments: .object(["function": .string("_main")])).arrayValue
        XCTAssertEqual(blocks?.count, 1)
        let block = try XCTUnwrap(blocks?.first)
        XCTAssertEqual(block["start"]?.stringValue, "0x1000")
        XCTAssertEqual(block["end"]?.stringValue, "0x1008")
        XCTAssertEqual(block["instructionCount"]?.intValue, 2)
        let successors = block["successors"]?.arrayValue
        XCTAssertEqual(successors?.first?["to"]?.stringValue, "0x1008")
        XCTAssertEqual(successors?.first?["kind"]?.stringValue, "call")

        // A function with no blocks in range yields an empty list (not an error).
        let helperBlocks = try api.execute("basic-blocks", arguments: .object(["function": .string("helper")])).arrayValue
        XCTAssertEqual(helperBlocks?.count, 0)
    }

    // read-bytes maps a virtual address through the section table to the retained slice,
    // clamps to the section end, and rejects an address outside every section.
    func testReadBytesMapsAddressThroughSections() throws {
        let bytes = Data([0xde, 0xad, 0xbe, 0xef, 0x11, 0x22])
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "b.bin", path: "/tmp/b", kind: "Mach-O executable", architecture: "arm64")],
            functions: [], instructions: [], xrefs: [], hexBytes: Data(),
            sections: [
                SectionSummary(id: UUID(), name: "__TEXT,__text", address: 0x4000, size: 6, fileOffset: 0, isExecutable: true),
                // A zero-fill (BSS) section: fileOffset 0 placeholder, real VA far from slice start.
                SectionSummary(id: UUID(), name: "__DATA,__bss", address: 0x5000, size: 0x100, fileOffset: 0, isExecutable: false, isZeroFill: true),
                // A malformed section whose fileOffset is near UInt64.max (wrapping bait).
                SectionSummary(id: UUID(), name: "__EVIL", address: 0x6000, size: 0x100, fileOffset: .max - 4, isExecutable: false),
            ],
            imageBytes: bytes
        )
        let api = WorkspaceScriptingAPI(store: WorkspaceStore(workspaceName: "B", snapshot: snapshot, engine: AnalysisEngine()))

        let head = try api.execute("read-bytes", arguments: .object(["address": .hex(0x4000), "count": .int(4)]))
        XCTAssertEqual(head["hex"]?.stringValue, "deadbeef")
        XCTAssertEqual(head["length"]?.intValue, 4)

        // Interior address, request beyond the section end -> clamped to what's available.
        let tail = try api.execute("read-bytes", arguments: .object(["address": .hex(0x4002), "count": .int(99)]))
        XCTAssertEqual(tail["hex"]?.stringValue, "beef1122")
        XCTAssertEqual(tail["length"]?.intValue, 4)

        // A zero-fill section returns ZEROS (the in-memory image), NOT bytes from fileOffset 0.
        let bss = try api.execute("read-bytes", arguments: .object(["address": .hex(0x5008), "count": .int(4)]))
        XCTAssertEqual(bss["hex"]?.stringValue, "00000000")
        XCTAssertEqual(bss["length"]?.intValue, 4)

        // A wrapping fileOffset must NOT alias into a valid index and return wrong bytes.
        let evil = try api.execute("read-bytes", arguments: .object(["address": .hex(0x6010), "count": .int(8)]))
        XCTAssertEqual(evil["length"]?.intValue, 0)
        XCTAssertEqual(evil["hex"]?.stringValue, "")

        // A negative count clamps to 0 (no trap); an out-of-section address throws.
        XCTAssertEqual(try api.execute("read-bytes", arguments: .object(["address": .hex(0x4000), "count": .int(-3)]))["length"]?.intValue, 0)
        XCTAssertThrowsError(try api.execute("read-bytes", arguments: .object(["address": .hex(0x9999)])))
    }

    // A section whose declared size has the high bit set (only from malformed/adversarial
    // input, which a binary-analysis tool must ingest) must render as a NON-NEGATIVE number,
    // not wrap to a negative via Int64(bitPattern:).
    func testSectionSizeAboveInt64MaxRendersNonNegative() throws {
        let huge: UInt64 = 0x8000_0000_0000_0000
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "m.bin", path: "/tmp/m", kind: "Mach-O executable", architecture: "arm64")],
            functions: [], instructions: [], xrefs: [], hexBytes: Data(),
            sections: [SectionSummary(id: UUID(), name: "__DATA,__data", address: 0x1000, size: huge, fileOffset: 0x1000, isExecutable: false)]
        )
        let api = WorkspaceScriptingAPI(store: WorkspaceStore(workspaceName: "M", snapshot: snapshot, engine: AnalysisEngine()))
        let size = try XCTUnwrap(try api.execute("sections").arrayValue?.first?["size"])
        let value = try XCTUnwrap(size.doubleValue)
        XCTAssertGreaterThanOrEqual(value, 0, "size must never render negative")
        XCTAssertEqual(value, Double(huge), accuracy: 1)
        // A normal size stays an exact integer.
        XCTAssertEqual(ScriptValue.count(0x200).intValue, 0x200)
    }

    // A zero-width function (end collapsed to start — e.g. a DB-loaded null end, or a
    // trailing function with no code section) must still resolve its blocks, instructions,
    // and INTERIOR addresses. A bare [start, end) range would yield empty/throw.
    func testZeroWidthFunctionStillResolvesBlocksInstructionsAndInteriorAddress() throws {
        let fnID = UUID()
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "z.bin", path: "/tmp/z", kind: "Mach-O executable", architecture: "arm64")],
            functions: [FunctionSummary(id: fnID, name: "zero", startAddress: 0x4000, endAddress: 0x4000, confidence: 0.5)],
            basicBlocks: [BasicBlockSummary(id: UUID(), functionID: fnID, startAddress: 0x4000, endAddress: 0x4004, instructionCount: 1)],
            instructions: [InstructionRow(address: 0x4000, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)],
            xrefs: [],
            hexBytes: Data()
        )
        let api = WorkspaceScriptingAPI(store: WorkspaceStore(workspaceName: "Zero", snapshot: snapshot, engine: AnalysisEngine()))

        // By name: the start block + instruction are returned (was [] before the guard).
        XCTAssertEqual(try api.execute("basic-blocks", arguments: .object(["function": .string("zero")])).arrayValue?.count, 1)
        XCTAssertEqual(try api.execute("instructions", arguments: .object(["function": .string("zero")])).arrayValue?.count, 1)

        // By an INTERIOR address (0x4002): resolves to `zero` (was a throw before the guard).
        let byInterior = try api.execute("basic-blocks", arguments: .object(["address": .hex(0x4002)])).arrayValue
        XCTAssertEqual(byInterior?.count, 1)
        XCTAssertEqual(byInterior?.first?["start"]?.stringValue, "0x4000")
    }

    func testTypeSignatureColorFormatAndDataAuthoring() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)

        _ = try api.execute("set-type", arguments: .object(["address": .hex(0x1000), "type": .string("MyStruct")]))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.appliedTypeName, "MyStruct")

        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000), "returnType": .string("int"),
            "args": .array([.object(["name": .string("argc"), "type": .string("int")])]),
        ]))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.signature?.returnType, "int")
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.signature?.args.first?.name, "argc")

        _ = try api.execute("set-color", arguments: .object(["address": .hex(0x1000), "color": .string("blue")]))
        XCTAssertEqual(store.snapshot.colorTag(at: 0x1000), .blue)

        _ = try api.execute("set-operand-format", arguments: .object(["address": .hex(0x1004), "format": .string("hex")]))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1004)]?.operandFormat, .hex)

        _ = try api.execute("make-data", arguments: .object(["address": .hex(0x1004), "isData": .bool(true)]))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1004)]?.isData, true)
    }

    func testTypeCatalog() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("define-type", arguments: .object([
            "kind": .string("struct"), "name": .string("Point"),
            "fields": .array([
                .object(["name": .string("x"), "type": .string("int32_t")]),
                .object(["name": .string("y"), "type": .string("int32_t")]),
            ]),
        ]))
        let types = try api.execute("list-types").arrayValue
        let point = types?.first { $0["name"]?.stringValue == "Point" }
        XCTAssertEqual(point?["kind"]?.stringValue, "struct")
        XCTAssertEqual(point?["fields"]?.arrayValue?.count, 2)
        XCTAssertEqual(point?["fields"]?.arrayValue?.first?["name"]?.stringValue, "x")

        // define-type is a true upsert by name: re-defining "Point" UPDATES it (one
        // entry), it does not append a duplicate that would violate UNIQUE(name).
        _ = try api.execute("define-type", arguments: .object([
            "kind": .string("struct"), "name": .string("Point"),
            "fields": .array([.object(["name": .string("z"), "type": .string("int32_t")])]),
        ]))
        XCTAssertEqual(store.snapshot.typeDefinitions.filter { $0.name == "Point" }.count, 1)
        XCTAssertEqual(store.snapshot.typeDefinitions.first { $0.name == "Point" }?.fields.map(\.name), ["z"])

        // Changing only the kind keeps the fields; omitting kind keeps the kind.
        _ = try api.execute("define-type", arguments: .object(["kind": .string("union"), "name": .string("Point")]))
        XCTAssertEqual(store.snapshot.typeDefinitions.first { $0.name == "Point" }?.kind, .union)
        XCTAssertEqual(store.snapshot.typeDefinitions.first { $0.name == "Point" }?.fields.map(\.name), ["z"])
        _ = try api.execute("define-type", arguments: .object([
            "name": .string("Point"),
            "fields": .array([.object(["name": .string("w"), "type": .string("int8_t")])]),
        ]))
        XCTAssertEqual(store.snapshot.typeDefinitions.first { $0.name == "Point" }?.kind, .union)
        // Malformed fields are rejected instead of silently becoming `field: int64_t` or erasing.
        XCTAssertThrowsError(try api.execute("define-type", arguments: .object([
            "name": .string("Point"), "fields": .string("x:int"),
        ])))
        XCTAssertThrowsError(try api.execute("define-type", arguments: .object([
            "name": .string("Point"), "fields": .array([.object(["name": .string("q")])]),
        ])))
        XCTAssertEqual(store.snapshot.typeDefinitions.first { $0.name == "Point" }?.fields.map(\.name), ["w"])
    }

    func testSignatureNoReturnStateSetClearAndLegacyBooleanMapping() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)

        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000),
            "noReturnState": .string("noReturn"),
        ]))
        XCTAssertEqual(
            store.snapshot.addressOverrides[.primary(0x1000)]?.signature?.noReturnState,
            .noReturn
        )

        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000),
            "returnType": .string("int"),
        ]))
        XCTAssertEqual(
            store.snapshot.addressOverrides[.primary(0x1000)]?.signature?.noReturnState,
            .noReturn,
            "omitting noReturnState must preserve the prior authored state"
        )

        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000),
            "noReturnState": .string("returns"),
        ]))
        XCTAssertEqual(
            store.snapshot.addressOverrides[.primary(0x1000)]?.signature?.noReturnState,
            .returns
        )

        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000),
            "isNoReturn": .bool(true),
        ]))
        XCTAssertEqual(
            store.snapshot.addressOverrides[.primary(0x1000)]?.signature?.noReturnState,
            .noReturn
        )

        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000),
            "isNoReturn": .bool(false),
        ]))
        XCTAssertEqual(
            store.snapshot.addressOverrides[.primary(0x1000)]?.signature?.noReturnState,
            .returns,
            "legacy false is an explicit clear at the mutation boundary"
        )
    }

    func testSetSignatureOmittedFieldsPreserveExistingTriStateIdentityAndQuarantine() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let original = FunctionSignatureOverride(
            returnType: "intptr_t",
            parameterList: .authoritative([
                ArgOverride(rowToken: "script-stable-a", name: "count", type: "size_t", provenance: .script),
                ArgOverride(rowToken: "script-stable-b", name: "buffer", type: "void *", provenance: .script),
            ]),
            variadicState: .variadic,
            quarantinedLegacyArgs: [
                LegacyArgOverride(originalIndex: 4, originalOrder: 0, name: "legacy", type: "double"),
            ],
            noReturnState: .noReturn
        )
        store.setSignature(0x1000, original)

        _ = try api.execute("set-signature", arguments: .object(["address": .hex(0x1000)]))

        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.signature, original)
    }

    func testSetSignatureArgsNullResetsToRecoveredAndClearsQuarantine() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        store.setSignature(0x1000, FunctionSignatureOverride(
            returnType: "int",
            parameterList: .authoritative([
                ArgOverride(rowToken: "old-row", name: "value", type: "int", provenance: .user),
            ]),
            variadicState: .fixed,
            quarantinedLegacyArgs: [
                LegacyArgOverride(originalIndex: 3, originalOrder: 0, name: "legacy", type: "float"),
            ],
            noReturnState: .returns
        ))

        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000),
            "args": .null,
        ]))

        let signature = try XCTUnwrap(store.snapshot.addressOverrides[.primary(0x1000)]?.signature)
        if case .unspecified = signature.parameterList {} else {
            XCTFail("args: null must restore the recovered parameter list")
        }
        XCTAssertEqual(signature.variadicState, .fixed, "omitted variadicState must be preserved")
        XCTAssertTrue(signature.quarantinedLegacyArgs.isEmpty)
    }

    func testSetSignatureEmptyArgsMeansExplicitVoid() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)

        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000),
            "returnType": .string("void"),
            "args": .array([]),
        ]))

        let signature = try XCTUnwrap(store.snapshot.addressOverrides[.primary(0x1000)]?.signature)
        guard case let .authoritative(rows) = signature.parameterList else {
            return XCTFail("args: [] must be an authoritative void parameter list")
        }
        XCTAssertTrue(rows.isEmpty)
    }

    func testSetSignatureNonemptyArgsPreserveSourceOrderAndCreateScriptRows() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)

        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000),
            "args": .array([
                .object(["name": .string("ratio"), "type": .string("double")]),
                .object(["type": .string("int *")]),
                .object(["name": .string("enabled"), "type": .string("bool")]),
            ]),
        ]))

        let signature = try XCTUnwrap(store.snapshot.addressOverrides[.primary(0x1000)]?.signature)
        guard case let .authoritative(rows) = signature.parameterList else {
            return XCTFail("a nonempty args array must be authoritative")
        }
        XCTAssertEqual(rows.map(\.name), ["ratio", "arg1", "enabled"])
        XCTAssertEqual(rows.map(\.type), ["double", "int *", "bool"])
        XCTAssertEqual(rows.map(\.provenance), [.script, .script, .script])
        XCTAssertEqual(Set(rows.map(\.rowToken)).count, rows.count)
        XCTAssertTrue(rows.allSatisfy { !$0.rowToken.isEmpty })
    }

    func testSetSignatureMalformedArgsFailAtomically() throws {
        let malformedArgs: [ScriptValue] = [
            .int(1),
            .object([:]),
            .array([.string("not-an-object")]),
            .array([.object(["name": .string("missing-type")])]),
            .array([.object(["type": .string("")])]),
            .array([.object(["type": .int(64)])]),
            .array([.object(["name": .bool(true), "type": .string("int")])]),
        ]

        for malformed in malformedArgs {
            let store = makeStore()
            let api = WorkspaceScriptingAPI(store: store)
            let original = FunctionSignatureOverride(
                returnType: "void",
                parameterList: .authoritative([
                    ArgOverride(rowToken: "unchanged-row", name: "old", type: "long", provenance: .user),
                ]),
                variadicState: .fixed,
                quarantinedLegacyArgs: [
                    LegacyArgOverride(originalIndex: 9, originalOrder: 0, name: "legacy", type: "float"),
                ],
                noReturnState: .noReturn
            )
            store.setSignature(0x1000, original)

            XCTAssertThrowsError(try api.execute("set-signature", arguments: .object([
                "address": .hex(0x1000),
                "returnType": .string("must-not-apply"),
                "args": malformed,
                "isNoReturn": .bool(false),
            ]))) { error in
                XCTAssertNotNil(error as? ScriptingError)
            }
            XCTAssertEqual(
                store.snapshot.addressOverrides[.primary(0x1000)]?.signature,
                original,
                "the entire signature update must fail before store mutation for args=\(malformed)"
            )
        }
    }

    func testSetSignatureRejectsMalformedNonemptyDeclaratorTypes() throws {
        let malformedTypes = [
            "int(",
            "double)",
            "struct",
            "unsigned float",
            "int ** trailing",
            "int[4",
            "int[]]",
            "int;",
            "*",
            "const",
        ]

        for malformedType in malformedTypes {
            let store = makeStore()
            let api = WorkspaceScriptingAPI(store: store)

            XCTAssertThrowsError(try api.execute("set-signature", arguments: .object([
                "address": .hex(0x1000),
                "args": .array([
                    .object(["name": .string("value"), "type": .string(malformedType)]),
                ]),
            ])), "expected malformed declarator to be rejected: \(malformedType)") { error in
                guard case let ScriptingError.invalidArgument(message) = error else {
                    return XCTFail("expected invalidArgument for \(malformedType), got \(error)")
                }
                XCTAssertEqual(message, "args[0].type must be a valid parameter type declaration")
            }
            XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000)])
        }
    }

    func testSetSignatureValidUnsupportedTypesPersistWithScriptProvenanceAndRemainUnbound() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let acceptedTypes = [
            "OpaquePayload",
            "struct LargeValue",
            "const OpaquePayload * volatile",
            "uint32_t[4]",
        ]

        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000),
            "args": .array(acceptedTypes.enumerated().map { index, type in
                .object(["name": .string("value\(index)"), "type": .string(type)])
            }),
        ]))

        let signature = try XCTUnwrap(store.snapshot.addressOverrides[.primary(0x1000)]?.signature)
        XCTAssertEqual(signature.args.map(\.type), acceptedTypes)
        XCTAssertEqual(signature.args.map(\.provenance), Array(repeating: .script, count: acceptedTypes.count))
        XCTAssertEqual(
            DarwinARM64ParameterBinder.bind(parameterTypes: [acceptedTypes[0]]),
            [.unbound(reason: .unsupportedType(acceptedTypes[0]))]
        )
        XCTAssertEqual(
            DarwinARM64ParameterBinder.bind(parameterTypes: [acceptedTypes[3]]),
            [.unbound(reason: .unsupportedType(acceptedTypes[3]))]
        )
    }

    func testSetSignatureLateMalformedTypePreservesEveryExistingSignatureFieldAtomically() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let original = FunctionSignatureOverride(
            returnType: "ExistingResult",
            parameterList: .authoritative([
                ArgOverride(rowToken: "stable-a", name: "first", type: "int", provenance: .user),
                ArgOverride(rowToken: "stable-b", name: "second", type: "OpaquePayload", provenance: .script),
            ]),
            variadicState: .variadic,
            quarantinedLegacyArgs: [
                LegacyArgOverride(originalIndex: 7, originalOrder: 0, name: "legacy", type: "double"),
            ],
            noReturnState: .noReturn
        )
        store.setSignature(0x1000, original)

        XCTAssertThrowsError(try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000),
            "returnType": .string("MustNotApply"),
            "args": .array([
                .object(["name": .string("valid"), "type": .string("uint64_t")]),
                .object(["name": .string("alsoValid"), "type": .string("OpaqueReplacement")]),
                .object(["name": .string("lateFailure"), "type": .string("int(")]),
            ]),
            "variadicState": .string("fixed"),
            "isNoReturn": .bool(false),
        ]))) { error in
            guard case let ScriptingError.invalidArgument(message) = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
            XCTAssertEqual(message, "args[2].type must be a valid parameter type declaration")
        }

        XCTAssertEqual(
            store.snapshot.addressOverrides[.primary(0x1000)]?.signature,
            original,
            "a late malformed row must preserve return type, active rows/tokens, provenance, variadic state, quarantine, and no-return"
        )
    }

    func testSetSignatureVariadicStateOmissionPreservesAndExplicitValuesRoundTrip() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        store.setSignature(0x1000, FunctionSignatureOverride(
            returnType: "int",
            parameterList: .authoritative([]),
            variadicState: .variadic,
            noReturnState: .returns
        ))

        _ = try api.execute("set-signature", arguments: .object([
            "address": .hex(0x1000),
            "returnType": .string("long"),
        ]))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.signature?.variadicState, .variadic)

        let explicitStates: [FunctionSignatureOverride.VariadicState] = [.unspecified, .fixed, .variadic]
        for expected in explicitStates {
            _ = try api.execute("set-signature", arguments: .object([
                "address": .hex(0x1000),
                "variadicState": .string(expected.rawValue),
            ]))
            XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.signature?.variadicState, expected)
        }

        let beforeInvalid = store.snapshot.addressOverrides[.primary(0x1000)]?.signature
        for invalid in [ScriptValue.string("sometimes"), .null, .bool(true)] {
            XCTAssertThrowsError(try api.execute("set-signature", arguments: .object([
                "address": .hex(0x1000),
                "returnType": .string("must-not-apply"),
                "variadicState": invalid,
            ])))
            XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.signature, beforeInvalid)
        }
    }

    // MARK: - JSON boundary

    func testScriptValueJSONRoundTrip() throws {
        let value = ScriptValue.object([
            "n": .int(42), "f": .double(1.5), "b": .bool(true), "s": .string("hi"),
            "a": .array([.int(1), .string("x")]), "nil": .null,
        ])
        let decoded = try ScriptValue.decode(value.jsonData())
        XCTAssertEqual(decoded["n"]?.intValue, 42)
        XCTAssertEqual(decoded["s"]?.stringValue, "hi")
        XCTAssertEqual(decoded["a"]?.arrayValue?.count, 2)
        XCTAssertEqual(decoded["nil"], .null)
        // Address parsing accepts both a JSON number and a 0x string.
        XCTAssertEqual(ScriptValue.string("0x140001000").addressValue, 0x1_4000_1000)
        XCTAssertEqual(ScriptValue.int(4096).addressValue, 4096)
    }

    // A large/non-finite JSON number must yield nil from `intValue`, NOT trap. The old
    // unchecked `Int64(value)` was a fatal error (uncatchable, bypassing the CLI's
    // do/catch) for any double exceeding Int64 — reachable from a script's `limit`/`count`.
    func testIntValueIsCheckedAndDoesNotTrapOnLargeOrNonFiniteDouble() throws {
        XCTAssertNil(ScriptValue.double(1e19).intValue)            // > Int64.max
        XCTAssertNil(ScriptValue.double(-1e19).intValue)           // < Int64.min
        XCTAssertNil(ScriptValue.double(.infinity).intValue)
        XCTAssertNil(ScriptValue.double(.nan).intValue)
        XCTAssertEqual(ScriptValue.double(2.9).intValue, 2)        // in-range truncates toward zero
        XCTAssertEqual(ScriptValue.double(-2.9).intValue, -2)
        // End-to-end: a `limit` of 1e19 decodes to a double and must degrade to "no
        // limit" (full result set) rather than crashing the process.
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let big = try ScriptValue.decode(Data(#"{"limit": 1e19}"#.utf8))
        let functions = try api.execute("functions", arguments: big).arrayValue
        XCTAssertEqual(functions?.count, store.snapshot.functions.count)
    }

    func testMakeProcedureCommandSetsAndClearsTheOverride() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("make-procedure", arguments: .object(["address": .hex(0x1004)]))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1004)]?.markAsProcedure, true)
        // Clearing makes the override empty -> pruned to nil.
        _ = try api.execute("make-procedure", arguments: .object(["address": .hex(0x1004), "isProcedure": .bool(false)]))
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1004)])
    }

    // MARK: - Data shapes (Make Array / Make Alignment / Make String)

    func testMakeArrayCommandShapesTheAddress() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let result = try api.execute("make-array", arguments: .object([
            "address": .hex(0x1004), "elementType": .string("int32_t"), "count": .int(16),
        ]))
        XCTAssertEqual(result["ok"]?.boolValue, true)
        let shape = try XCTUnwrap(store.snapshot.dataShape(at: 0x1004))
        XCTAssertEqual(shape.kind, .array)
        XCTAssertEqual(shape.elementType, "int32_t")
        XCTAssertEqual(shape.elementCount, 16)
        // A shaped span is data (excluded from code analysis).
        XCTAssertTrue(store.snapshot.isData(at: 0x1004))
        XCTAssertEqual(shape.staticByteSpan(), 64) // 16 * 4 bytes
    }

    func testMakeAlignmentCommandShapesTheAddress() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("make-alignment", arguments: .object(["address": .hex(0x1004), "boundary": .int(8)]))
        let shape = try XCTUnwrap(store.snapshot.dataShape(at: 0x1004))
        XCTAssertEqual(shape.kind, .alignment)
        XCTAssertEqual(shape.alignment, 8)
        // 0x1004 is 4 bytes past an 8-byte boundary -> 4 bytes of padding.
        XCTAssertEqual(shape.paddingSpan(from: 0x1004), 4)
    }

    func testMakeStringCommandShapesTheAddress() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        // NUL-terminated C string (no length).
        _ = try api.execute("make-string", arguments: .object(["address": .hex(0x1004)]))
        let cstr = try XCTUnwrap(store.snapshot.dataShape(at: 0x1004))
        XCTAssertEqual(cstr.kind, .string)
        XCTAssertTrue(cstr.isNullTerminated)
        // Fixed-length buffer.
        _ = try api.execute("make-string", arguments: .object(["address": .hex(0x1008), "length": .int(12)]))
        let fixed = try XCTUnwrap(store.snapshot.dataShape(at: 0x1008))
        XCTAssertFalse(fixed.isNullTerminated)
        XCTAssertEqual(fixed.stringLength, 12)
        XCTAssertEqual(fixed.staticByteSpan(), 12)
    }

    func testMakeArrayRejectsNonPositiveOrHugeCount() {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        XCTAssertThrowsError(try api.execute("make-array", arguments: .object([
            "address": .hex(0x1004), "elementType": .string("int32_t"), "count": .int(0),
        ])))
        XCTAssertThrowsError(try api.execute("make-array", arguments: .object([
            "address": .hex(0x1004), "elementType": .string("int32_t"),
            "count": .int(Int64(DataShapeOverride.maxElementCount) + 1),
        ])))
        XCTAssertNil(store.snapshot.dataShape(at: 0x1004))
    }

    func testDataShapeIsUndoable() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("make-array", arguments: .object([
            "address": .hex(0x1004), "elementType": .string("int32_t"), "count": .int(8),
        ]))
        XCTAssertNotNil(store.snapshot.dataShape(at: 0x1004))
        store.undoManager.undo()
        XCTAssertNil(store.snapshot.dataShape(at: 0x1004))
        XCTAssertFalse(store.snapshot.isData(at: 0x1004))
    }

    // MARK: - v22 authoring: undefined / patch / manual xrefs / bookmarks

    func testMakeUndefinedIsAppliedAndUndoable() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let result = try api.execute("make-undefined", arguments: .object(["address": .hex(0x1004)]))
        XCTAssertEqual(result["isUndefined"]?.boolValue, true)
        XCTAssertTrue(store.snapshot.isUndefined(at: 0x1004))
        store.undoManager.undo()
        XCTAssertFalse(store.snapshot.isUndefined(at: 0x1004))
    }

    func testPatchBytesValidatesAndIsUndoable() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        // A NOP patch.
        let nop = try api.execute("patch-bytes", arguments: .object(["address": .hex(0x1004), "nop": .bool(true)]))
        XCTAssertEqual(nop["bytes"]?.stringValue, "1f 20 03 d5")
        XCTAssertEqual(store.snapshot.patch(at: 0x1004), BytePatch.arm64NOP)
        // An explicit hex patch.
        _ = try api.execute("patch-bytes", arguments: .object(["address": .hex(0x1000), "bytes": .string("aa bb cc dd")]))
        XCTAssertEqual(store.snapshot.patch(at: 0x1000)?.bytes, [0xaa, 0xbb, 0xcc, 0xdd])
        // Invalid hex is rejected, not applied.
        XCTAssertThrowsError(try api.execute("patch-bytes", arguments: .object(["address": .hex(0x1008), "bytes": .string("zz")])))
        XCTAssertNil(store.snapshot.patch(at: 0x1008))
        // Clear restores the original.
        _ = try api.execute("clear-patch", arguments: .object(["address": .hex(0x1004)]))
        XCTAssertNil(store.snapshot.patch(at: 0x1004))
        // Undo brings the cleared patch back.
        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.patch(at: 0x1004), BytePatch.arm64NOP)
    }

    func testScriptedPatchesUsePrimaryArchitectureWithCollidingFocusedSibling() throws {
        let address: UInt64 = 0x5000
        let sibling = ImageSlot(rawValue: 1)
        for (primary, secondary, expected) in [
            ("arm64", "x86_64", BytePatch.arm64NOP),
            ("x86_64", "arm64", BytePatch(bytes: [0x90, 0x90, 0x90, 0x90])),
        ] {
            let store = makeSiblingFocusedSelectorStore(
                address: address, sibling: sibling,
                primaryArchitecture: primary, siblingArchitecture: secondary
            )
            let siblingPatch = BytePatch(bytes: [0xcc])
            XCTAssertTrue(store.setPatch(address, in: sibling, siblingPatch))
            let api = WorkspaceScriptingAPI(store: store)
            _ = try api.execute("patch-bytes", arguments: .object([
                "address": .hex(address), "nop": .bool(true),
            ]))
            XCTAssertEqual(store.snapshot.patches(in: .primary)[address], expected)
            XCTAssertEqual(store.snapshot.patches(in: sibling)[address], siblingPatch)
            _ = try api.execute("patch-bytes", arguments: .object([
                "address": .hex(address), "bytes": .string("11 22 33 44"),
            ]))
            XCTAssertEqual(store.snapshot.patches(in: .primary)[address]?.bytes, [0x11, 0x22, 0x33, 0x44])
            _ = try api.execute("clear-patch", arguments: .object(["address": .hex(address)]))
            XCTAssertNil(store.snapshot.patches(in: .primary)[address])
            XCTAssertEqual(store.snapshot.patches(in: sibling)[address], siblingPatch)
            XCTAssertEqual(store.focusedImageSlot, sibling)
            store.undoManager.undo()
            XCTAssertEqual(store.snapshot.patches(in: .primary)[address]?.bytes, [0x11, 0x22, 0x33, 0x44])
        }
    }

    func testScriptedPrimaryPatchExportsAndClearsWhileSiblingIsFocused() throws {
        let fixture = MachOFixture.makeExecutable()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("primary")
        try fixture.bytes.write(to: source)
        let sibling = ImageSlot(rawValue: 1)
        let store = makeSiblingFocusedSelectorStore(
            address: fixture.baseAddress, sibling: sibling,
            siblingArchitecture: "x86_64", primaryPath: source.path, primaryImageBytes: fixture.bytes
        )
        let siblingPatch = BytePatch(bytes: [0xcc])
        XCTAssertTrue(store.setPatch(fixture.baseAddress, in: sibling, siblingPatch))
        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("patch-bytes", arguments: .object([
            "address": .hex(fixture.baseAddress), "bytes": .string("1f 20 03 d5"),
        ]))
        let exported = try api.execute("save-patched-binary")
        let encoded = try XCTUnwrap(exported["bytesBase64"]?.stringValue)
        let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
        var expected = fixture.bytes
        expected.replaceSubrange(fixture.codeOffset..<(fixture.codeOffset + 4), with: BytePatch.arm64NOP.bytes)
        XCTAssertEqual(bytes, expected)
        _ = try api.execute("clear-patch", arguments: .object(["address": .hex(fixture.baseAddress)]))
        let cleared = try api.execute("save-patched-binary")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(cleared["bytesBase64"]?.stringValue)), fixture.bytes)
        XCTAssertEqual(store.snapshot.patches(in: sibling)[fixture.baseAddress], siblingPatch)
        XCTAssertEqual(store.focusedImageSlot, sibling)
        XCTAssertEqual(try Data(contentsOf: source), fixture.bytes)
    }

    func testManualXRefAddSuppressAndList() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        // Add a missed xref.
        _ = try api.execute("add-xref", arguments: .object([
            "from": .hex(0x1000), "to": .hex(0x1008), "kind": .string("call"),
        ]))
        // The merged set surfaces the added xref from 0x1000.
        let fromAdded = try api.execute("xrefs", arguments: .object(["from": .hex(0x1000)])).arrayValue
        XCTAssertEqual(fromAdded?.count, 1)
        // Suppress the recovered 0x1004 -> 0x1008 call.
        _ = try api.execute("suppress-xref", arguments: .object([
            "from": .hex(0x1004), "to": .hex(0x1008), "kind": .string("call"),
        ]))
        let intoTarget = try api.execute("xrefs", arguments: .object(["to": .hex(0x1008)])).arrayValue
        // The recovered 0x1004 edge is gone; the added 0x1000 edge survives.
        XCTAssertEqual(intoTarget?.count, 1)
        XCTAssertEqual(intoTarget?.first?["from"]?.stringValue, "0x1000")
        XCTAssertEqual(try api.execute("manual-xrefs").arrayValue?.count, 2)
        // Undo the suppression -> the recovered edge returns.
        store.undoManager.undo()
        XCTAssertEqual(try api.execute("xrefs", arguments: .object(["to": .hex(0x1008)])).arrayValue?.count, 2)
    }

    func testBookmarkAddListRemoveAndUndo() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("add-bookmark", arguments: .object(["address": .hex(0x1000), "name": .string("entry")]))
        _ = try api.execute("add-bookmark", arguments: .object(["address": .hex(0x1008), "name": .string("tail")]))
        let list = try api.execute("bookmarks").arrayValue
        XCTAssertEqual(list?.count, 2)
        XCTAssertEqual(list?.first?["name"]?.stringValue, "entry") // address-sorted
        _ = try api.execute("remove-bookmark", arguments: .object(["address": .hex(0x1000)]))
        XCTAssertEqual(try api.execute("bookmarks").arrayValue?.count, 1)
        store.undoManager.undo()
        XCTAssertEqual(try api.execute("bookmarks").arrayValue?.count, 2)
    }

    // A negative `limit` must not trap `Collection.prefix(_:)` (which requires a
    // non-negative length); it is clamped to 0 -> an empty result, never a crash.
    func testNegativeLimitIsClampedAndDoesNotTrap() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())
        for command in ["functions", "symbols", "strings", "imports", "exports"] {
            let rows = try api.execute(command, arguments: .object(["limit": .int(-5)])).arrayValue
            XCTAssertEqual(rows?.count, 0, "\(command) with a negative limit yields empty, not a trap")
        }
    }

    // A present-but-non-object `arguments` is a malformed step and must be rejected,
    // not silently treated as empty (which would run a read command with its defaults).
    func testRunScriptRejectsNonObjectArguments() {
        let api = WorkspaceScriptingAPI(store: makeStore())
        let script = ScriptValue.array([.object(["command": .string("functions"), "arguments": .int(5)])])
        XCTAssertThrowsError(try api.runScript(script)) {
            XCTAssertEqual($0 as? ScriptingError, .invalidArgument("step 'arguments' must be a JSON object"))
        }
        // A null or omitted `arguments` is still fine (treated as empty).
        let ok = ScriptValue.array([.object(["command": .string("info"), "arguments": .null])])
        XCTAssertNoThrow(try api.runScript(ok))
    }
}

/// Holds a detached snapshot read at one exact checkpoint ordinal. The probe blocks only the
/// read's own worker thread; the test observes the hold by polling, never by sleeping for work.
final class SnapshotReadCheckpointGate: @unchecked Sendable {
    private let lock = NSLock()
    private let holdAt: Int
    private let release = DispatchSemaphore(value: 0)
    private var count = 0
    private var held = false

    init(holdAt: Int) { self.holdAt = holdAt }

    var checkpointCount: Int { lock.withLock { count } }
    var isHeld: Bool { lock.withLock { held } }

    func checkpoint() {
        let shouldHold = lock.withLock { () -> Bool in
            count += 1
            guard count == holdAt else { return false }
            held = true
            return true
        }
        if shouldHold { release.wait() }
    }

    func open() { release.signal() }

    /// Bounded admission wait; the bound is a hang guard, not an ordering assumption.
    func waitUntilHeld() async throws {
        for _ in 0..<2_000 {
            if isHeld { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        open()
        XCTFail("Snapshot read never reached checkpoint \(holdAt)")
        throw CancellationError()
    }
}

/// Fixed-outcome native seam: records every request so tests can assert the image binding.
private final class StubScriptingNativeDecompiler: ScriptingNativeDecompiling, @unchecked Sendable {
    private let outcome: ScriptingNativeDecompileOutcome
    private let lock = NSLock()
    private var recorded: [ScriptingNativeDecompileRequest] = []

    init(_ outcome: ScriptingNativeDecompileOutcome) { self.outcome = outcome }

    var requests: [ScriptingNativeDecompileRequest] { lock.withLock { recorded } }

    func decompile(_ request: ScriptingNativeDecompileRequest) async -> ScriptingNativeDecompileOutcome {
        lock.withLock { recorded.append(request) }
        return outcome
    }
}

/// Scripted/MCP `decompile` is native-first: `backend` says which decompiler answered and a
/// MacIR answer carries a machine-readable `fallbackReason`. No XPC service is involved.
@MainActor
final class ScriptingNativeDecompileTests: XCTestCase {
    private let address: UInt64 = 0x5000
    private let sibling = ImageSlot(rawValue: 1)

    /// Two arm64 images with the same function address; the sibling is focused, so a
    /// primary-bound command must still name the primary image's function.
    private func makeSiblingFocusedStore() -> (WorkspaceStore, primaryFunctionID: UUID) {
        let primaryID = UUID()
        func image(_ slot: ImageSlot) -> BinaryImage {
            BinaryImage(
                id: UUID(), name: "image-\(slot.rawValue)", path: "/tmp/native-first-\(slot.rawValue)",
                kind: "Mach-O executable", architecture: "arm64", slot: slot
            )
        }
        func analysis(_ id: UUID, _ name: String) -> ImageAnalysis {
            var result = ImageAnalysis()
            result.functions = [FunctionSummary(
                id: id, name: name, startAddress: address, endAddress: address + 4, confidence: 1
            )]
            result.instructions = [InstructionRow(
                address: address, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
                hasBreakpoint: false, comment: nil
            )]
            return result
        }
        let snapshot = WorkspaceSnapshot(
            binaries: [image(.primary), image(sibling)],
            analysisBySlot: [
                .primary: analysis(primaryID, "primary_fn"),
                sibling: analysis(UUID(), "sibling_fn"),
            ]
        )
        let store = WorkspaceStore(
            workspaceName: "Native First", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
        store.focusImage(sibling)
        return (store, primaryID)
    }

    private func document(_ text: String) -> NativeDecompilerWirePseudocodeDocument {
        NativeDecompilerWirePseudocodeDocument(
            text: text, language: "c", isComplete: true, isTruncated: false
        )
    }

    private func decompile(
        _ outcome: ScriptingNativeDecompileOutcome
    ) async throws -> (ScriptValue, legacy: ScriptValue, StubScriptingNativeDecompiler, UUID) {
        let (store, primaryID) = makeSiblingFocusedStore()
        let stub = StubScriptingNativeDecompiler(outcome)
        let api = WorkspaceScriptingAPI(store: store, nativeDecompiler: stub)
        let arguments = ScriptValue.object(["address": .hex(address)])
        let output = try await api.executeAsync("decompile", arguments: arguments)
        let legacy = try api.execute("decompile", arguments: arguments)
        return (output, legacy, stub, primaryID)
    }

    private func assertMacIRFallback(
        _ outcome: ScriptingNativeDecompileOutcome, reason: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let (output, legacy, stub, _) = try await decompile(outcome)
        XCTAssertEqual(stub.requests.count, 1, file: file, line: line)
        XCTAssertEqual(output["backend"]?.stringValue, "macir", file: file, line: line)
        XCTAssertEqual(output["fallbackReason"]?.stringValue, reason, file: file, line: line)
        XCTAssertEqual(output["function"]?.stringValue, "primary_fn", file: file, line: line)
        XCTAssertEqual(output["address"]?.stringValue, "0x5000", file: file, line: line)
        // The fallback body is exactly the MacIR document the synchronous binding serves.
        XCTAssertEqual(output["pseudocode"], legacy["pseudocode"], file: file, line: line)
        XCTAssertEqual(output["lines"], legacy["lines"], file: file, line: line)
    }

    func testNativeSuccessReportsNativeBackendForThePrimaryImageFunction() async throws {
        let text = "void primary_fn(void)\n{\n  return;\n}"
        let (output, legacy, stub, primaryID) = try await decompile(.completed(document(text)))
        XCTAssertEqual(output["backend"]?.stringValue, "native")
        XCTAssertNil(output["fallbackReason"])
        XCTAssertEqual(output["pseudocode"]?.stringValue, text)
        XCTAssertEqual(output["function"]?.stringValue, "primary_fn")
        XCTAssertEqual(output["address"]?.stringValue, "0x5000")
        XCTAssertEqual(output["language"]?.stringValue, "c")
        XCTAssertEqual(output["complete"]?.boolValue, true)
        XCTAssertEqual(output["truncated"]?.boolValue, false)
        let lines = try XCTUnwrap(output["lines"]?.arrayValue)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0]["n"], .int(1))
        XCTAssertEqual(lines[2]["text"]?.stringValue, "  return;")

        // Primary-image default: the sibling is focused, yet native is asked for the primary
        // image's function, the same binding MacIR uses.
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(request.imageSlot, .primary)
        XCTAssertEqual(request.functionID, primaryID)
        XCTAssertEqual(request.startAddress, address)

        // The synchronous binding has no native runtime and says so.
        XCTAssertEqual(legacy["backend"]?.stringValue, "macir")
        XCTAssertEqual(legacy["fallbackReason"]?.stringValue, "native-unavailable")
        XCTAssertEqual(legacy["function"]?.stringValue, "primary_fn")
    }

    func testNativeFailureFallsBackToMacIRWithFailureCode() async throws {
        try await assertMacIRFallback(.failed(code: "timed-out"), reason: "native-failed: timed-out")
    }

    func testNativeUnavailableFallsBackToMacIR() async throws {
        try await assertMacIRFallback(.unavailable, reason: "native-unavailable")
    }

    func testNativeMissingOrBlankDocumentFallsBackToMacIR() async throws {
        try await assertMacIRFallback(.completed(nil), reason: "native-empty")
        try await assertMacIRFallback(.completed(document(" \n\t")), reason: "native-empty")
    }

    func testNoNativeRuntimeServesMacIRAsUnavailable() async throws {
        let (store, _) = makeSiblingFocusedStore()
        let api = WorkspaceScriptingAPI(store: store)
        let arguments = ScriptValue.object(["function": .string("primary_fn")])
        let output = try await api.executeAsync("decompile", arguments: arguments)
        XCTAssertEqual(output, try api.execute("decompile", arguments: arguments))
        XCTAssertEqual(output["backend"]?.stringValue, "macir")
        XCTAssertEqual(output["fallbackReason"]?.stringValue, "native-unavailable")
        XCTAssertEqual(output["function"]?.stringValue, "primary_fn")
    }

    func testTerminalReasonsMapToThePaneUnavailableClassification() {
        XCTAssertEqual(ScriptingNativeDecompileOutcome.terminal(.provider(.unavailable)), .unavailable)
        XCTAssertEqual(ScriptingNativeDecompileOutcome.terminal(.runtime(.shutDown)), .unavailable)
        XCTAssertEqual(
            ScriptingNativeDecompileOutcome.terminal(.projection(.unsupportedArchitecture)), .unavailable
        )
        XCTAssertEqual(
            ScriptingNativeDecompileOutcome.terminal(.provider(.timedOut)), .failed(code: "timed-out")
        )
        XCTAssertEqual(
            ScriptingNativeDecompileOutcome.terminal(.invalidReply), .failed(code: "invalid-reply")
        )
        XCTAssertEqual(
            ScriptingNativeDecompileOutcome.terminal(.runtime(.staleEpoch)),
            .failed(code: "runtime-staleEpoch")
        )
    }

    func testDecompileToolDescriptionDocumentsBackendAndFallbackReason() throws {
        let info = try XCTUnwrap(WorkspaceScriptingAPI.availableCommands.first { $0.name == "decompile" })
        XCTAssertTrue(info.summary.contains("`backend`"))
        XCTAssertTrue(info.summary.contains("`fallbackReason`"))
        XCTAssertTrue(info.summary.contains("native-failed: <code>"))
    }
}
