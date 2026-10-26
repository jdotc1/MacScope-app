import Foundation
import XCTest
@testable import MacScope

/// Track W3-A — dSYM import (Read Debug Symbols). Covers the three layers:
///   1. `DWARFReader` against a hand-built minimal `.debug_info`/`.debug_abbrev` (no toolchain
///      required — deterministic, always runs) — proves the subprogram name+address walk.
///   2. `DSYMImportService` end-to-end against a REAL dSYM built at test time with
///      clang + dsymutil (skips cleanly when the toolchain is absent) — proves the
///      bundle resolution, UUID gate, and modern DWARF-5 indexed-form decoding.
///   3. `WorkspaceStore.importDebugSymbols` — proves the recovered names are injected as
///      `customName` overrides (so the listing shows them), undoably.
final class DSYMImportTests: XCTestCase {

    // MARK: - 1. DWARFReader: synthetic minimal DWARF (no toolchain)

    /// Builds a single-CU DWARF (v4, direct forms) carrying one subprogram named
    /// "synthetic_fn" at low_pc 0x1234, and asserts the reader recovers exactly that.
    /// Direct forms (DW_FORM_addr, DW_FORM_string) keep the fixture self-contained — no
    /// .debug_addr / .debug_str_offsets needed — so this test never depends on a producer.
    func testReaderRecoversSubprogramFromSyntheticDirectFormDWARF() throws {
        let fixture = SyntheticDWARF.singleSubprogram(name: "synthetic_fn", lowPC: 0x1234)
        let reader = DWARFReader(sections: fixture)
        let symbols = try reader.recoverFunctionSymbols()

        XCTAssertEqual(symbols.count, 1)
        XCTAssertEqual(symbols.first?.name, "synthetic_fn")
        XCTAssertEqual(symbols.first?.address, 0x1234)
    }

    /// A subprogram with a NAME but no low_pc (a prototype/declaration) is dropped: we never
    /// inject a name at an address we don't have.
    func testReaderDropsSubprogramWithoutLowPC() throws {
        let fixture = SyntheticDWARF.subprogramWithoutLowPC(name: "decl_only")
        let symbols = try DWARFReader(sections: fixture).recoverFunctionSymbols()
        XCTAssertTrue(symbols.isEmpty)
    }

    /// A missing `.debug_info` is a fail-loud, typed error (not a silent empty result).
    func testReaderThrowsOnMissingDebugInfo() {
        let reader = DWARFReader(sections: DWARFReader.Sections(debugAbbrev: Data([0x00])))
        XCTAssertThrowsError(try reader.recoverFunctionSymbols()) { error in
            XCTAssertEqual(error as? DWARFReaderError, .missingDebugInfo)
        }
    }

    /// A truncated CU header (a length that runs past the section) throws `.malformed`
    /// rather than trapping on an out-of-range read.
    func testReaderThrowsOnTruncatedUnit() {
        // unit_length = 0xFF (claims 255 bytes) but the section is far shorter.
        let info = Data([0xff, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x08])
        let reader = DWARFReader(sections: DWARFReader.Sections(debugInfo: info, debugAbbrev: Data([0x00])))
        XCTAssertThrowsError(try reader.recoverFunctionSymbols()) { error in
            guard case .malformed = (error as? DWARFReaderError) else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    // MARK: - 1b. DWARFReader: adversarial / malformed fuzz (W4-D)

    /// (a) A `DW_FORM_exprloc` whose ULEB128 length is 2^63 (`[0x80*9, 0x01]`) exceeds Int.max.
    /// `Int(length)` would TRAP; the reader must REJECT the unit (drop the function) and never
    /// trap. The malformed unit is non-fatal — `recoverFunctionSymbols()` returns (here, empty)
    /// rather than crashing, which is the memory-safety guarantee under test.
    func testReaderRejectsOversizedExprlocLengthWithoutTrapping() throws {
        // 2^63 = 0x8000000000000000, the smallest value that overflows Int.max.
        let oversized: [UInt8] = Array(repeating: 0x80, count: 9) + [0x01]
        let fixture = SyntheticDWARF.subprogramWithExprlocLength(oversized)

        // Must return (empty), not trap. The function the fixture names is dropped because the
        // CU's DIE walk throws `.malformed` on the rejected length and the per-unit catch keeps
        // it non-fatal. The absence of a trap on `Int(2^63)` is the guarantee under test.
        let symbols = try DWARFReader(sections: fixture).recoverFunctionSymbols()
        XCTAssertTrue(symbols.isEmpty, "expected the malformed unit to be dropped, got \(symbols)")
    }

    /// The oversized-length rejection is observable directly at the DIE-walk layer: a
    /// single-unit walk surfaces `.malformed` (the reader catches it per-unit so the public
    /// API degrades, but the throw is what stops the would-be `Int(2^63)` trap).
    func testReaderExprlocOverflowIsRejectedNotTruncated() throws {
        // A length of exactly Int.max + 1 (2^63) is the boundary the guard must catch. A
        // smaller length (e.g. 2^62) is representable as Int and would instead try to skip
        // that many bytes — which the bounds-checked `skip` then rejects as past-end. Either
        // way the result is a thrown error, never a trap; assert the empty (safe) outcome.
        let twoPow62: [UInt8] = Array(repeating: 0x80, count: 8) + [0x40] // ULEB 2^62
        let fixture = SyntheticDWARF.subprogramWithExprlocLength(twoPow62)
        let symbols = try DWARFReader(sections: fixture).recoverFunctionSymbols()
        XCTAssertTrue(symbols.isEmpty)
    }

    func testExprlocLengthAtIntMaximumIsRejectedByBothReaders() throws {
        // UInt64(Int.max) passes an exact Int conversion but overflows when
        // added to the current nonzero offset. No block payload is present.
        let maximumIntULEB: [UInt8] = Array(repeating: 0xff, count: 8) + [0x7f]
        let fixture = SyntheticDWARF.subprogramWithExprlocLength(maximumIntULEB)

        XCTAssertTrue(try DWARFReader(sections: fixture).recoverFunctionSymbols().isEmpty)
        XCTAssertTrue(DWARFDIETree(sections: fixture).parse().isEmpty)
    }

    func testDeepIndirectFormsRecoverExactValuesThroughBothReaders() throws {
        // Each 0x16 selects DW_FORM_indirect again. Exercise thousands of
        // nested selectors without requiring recursive stack growth, while
        // the final form still carries ordinary name evidence.
        let encodedName: [UInt8] = Array(repeating: 0x16, count: 16_384)
            + [0x08] + Array("deep_function".utf8) + [0x00]
        let fixture = SyntheticDWARF.subprogramWithIndirectName(encodedName)
        let symbols = try DWARFReader(sections: fixture).recoverFunctionSymbols()

        XCTAssertEqual(symbols.count, 1)
        XCTAssertEqual(symbols.first?.name, "deep_function")
        XCTAssertEqual(symbols.first?.address, 0x1234)
        let nodes = DWARFDIETree(sections: fixture).parse()
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes.first?.tag, 0x2e)
        XCTAssertEqual(nodes.first?.attributes[0x03], .string("deep_function"))
        XCTAssertEqual(nodes.first?.attributes[0x11], .address(0x1234))
    }

    func testDeepIndirectFormsWithTruncatedTerminalYieldNoEvidence() throws {
        let indirectForms = Array(repeating: UInt8(0x16), count: 16_384)
        for terminal in [[UInt8](), [0x80]] {
            // Empty: no terminal form. 0x80: an unterminated terminal ULEB.
            // The fixture adds no null DIE that could finish this operand.
            let fixture = SyntheticDWARF.subprogramWithIndirectName(indirectForms + terminal)
            XCTAssertTrue(try DWARFReader(sections: fixture).recoverFunctionSymbols().isEmpty)
            XCTAssertTrue(DWARFDIETree(sections: fixture).parse().isEmpty)
        }
    }

    func testIndirectNameCannotBorrowBytesFromFollowingCompilationUnit() throws {
        // The first CU ends immediately after selecting DW_FORM_string.
        // The following CU's length begins with ASCII "A\0", which must not
        // become a fabricated name at the first CU's otherwise valid low_pc.
        let malformed = SyntheticDWARF.subprogramWithIndirectName([0x08], lowPC: 0x1234)
        let validName = "valid_second_" + String(repeating: "x", count: 34)
        let valid = SyntheticDWARF.subprogramWithIndirectName(
            [0x08] + Array(validName.utf8) + [0x00], lowPC: 0x5678
        )
        XCTAssertEqual(valid.debugInfo.prefix(4), Data([0x41, 0x00, 0x00, 0x00]))
        let fixture = DWARFReader.Sections(
            debugInfo: malformed.debugInfo + valid.debugInfo,
            debugAbbrev: malformed.debugAbbrev
        )

        let symbols = try DWARFReader(sections: fixture).recoverFunctionSymbols()
        XCTAssertEqual(symbols.map(\.name), [validName])
        XCTAssertEqual(symbols.map(\.address), [0x5678])
        let nodes = DWARFDIETree(sections: fixture).parse()
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes.first?.attributes[0x03], .string(validName))
        XCTAssertEqual(nodes.first?.attributes[0x11], .address(0x5678))
    }

    func testTypeNameCannotBorrowTerminatorFromFollowingCompilationUnit() throws {
        // recoverTypes uses parseDIEUnit rather than the function-symbol walk.
        // A final unterminated name must invalidate its CU, not acquire "A\0"
        // from the following CU's length and become a fabricated base type.
        let malformed = SyntheticDWARF.baseTypeWithEncodedName(
            Array("unterminated_type_".utf8)
        )
        let validName = "valid_type_" + String(repeating: "x", count: 44)
        let valid = SyntheticDWARF.baseTypeWithEncodedName(
            Array(validName.utf8) + [0x00]
        )
        XCTAssertEqual(valid.debugInfo.prefix(4), Data([0x41, 0x00, 0x00, 0x00]))
        let fixture = DWARFReader.Sections(
            debugInfo: malformed.debugInfo + valid.debugInfo,
            debugAbbrev: malformed.debugAbbrev
        )

        XCTAssertEqual(try DWARFReader(sections: fixture).recoverTypes(), [
            DWARFType(name: validName, kind: "base", byteSize: 4),
        ])
    }

    func testLEBScalarDomainBoundariesRemainValidInBothReaders() throws {
        let cases: [(String, UInt8, [UInt8], DWARFAttributeValue)] = [
            ("UInt64.max", 0x0f, Array(repeating: 0xff, count: 9) + [0x01], .uint(UInt64.max)),
            ("unsigned zero extension", 0x0f, Array(repeating: 0x80, count: 10) + [0x00], .uint(0)),
            ("Int64.max", 0x0d, Array(repeating: 0xff, count: 9) + [0x00], .sint(Int64.max)),
            ("Int64.min", 0x0d, Array(repeating: 0x80, count: 9) + [0x7f], .sint(Int64.min)),
            ("short negative sign extension", 0x0d, [0x7f], .sint(-1)),
            ("positive sign disambiguation", 0x0d, [0xff, 0x00], .sint(127)),
        ]
        for (name, form, operand, expected) in cases {
            let fixture = SyntheticDWARF.subprogramWithScalar(form: form, operand: operand)
            let symbols = try DWARFReader(sections: fixture).recoverFunctionSymbols()
            XCTAssertEqual(symbols.map(\.name), ["scalar_fn"], name)
            XCTAssertEqual(symbols.map(\.address), [0x1234], name)
            let nodes = DWARFDIETree(sections: fixture).parse()
            XCTAssertEqual(nodes.count, 1, name)
            XCTAssertEqual(nodes.first?.attributes[0x1c], expected, name)
        }
    }

    func testOutOfDomainLEBScalarsRejectOnlyMalformedCompilationUnit() throws {
        let cases: [(String, UInt8, [UInt8])] = [
            ("unsigned 2^64", 0x0f, Array(repeating: 0x80, count: 9) + [0x02]),
            ("unsigned nonzero eleventh octet", 0x0f, Array(repeating: 0x80, count: 10) + [0x01]),
            ("signed positive overflow", 0x0d, Array(repeating: 0x80, count: 9) + [0x01]),
            ("signed negative overflow", 0x0d, Array(repeating: 0xff, count: 9) + [0x7e]),
            ("signed eleventh octet", 0x0d, Array(repeating: 0xff, count: 10) + [0x7f]),
        ]
        for (name, form, operand) in cases {
            let malformed = SyntheticDWARF.subprogramWithScalar(form: form, operand: operand)
            let valid = SyntheticDWARF.subprogramWithScalar(form: form, operand: [0], lowPC: 0x5678)
            let fixture = DWARFReader.Sections(
                debugInfo: malformed.debugInfo + valid.debugInfo,
                debugAbbrev: malformed.debugAbbrev
            )
            let symbols = try DWARFReader(sections: fixture).recoverFunctionSymbols()
            XCTAssertEqual(symbols.map(\.name), ["scalar_fn"], name)
            XCTAssertEqual(symbols.map(\.address), [0x5678], name)
            let nodes = DWARFDIETree(sections: fixture).parse()
            XCTAssertEqual(nodes.count, 1, name)
            XCTAssertEqual(nodes.first?.attributes[0x11], .address(0x5678), name)
        }
    }

    /// (b) A `DW_FORM_strx` index large enough that `base + index*4` WRAPS UInt64 back into the
    /// (short) `.debug_str_offsets` must be rejected — no out-of-bounds slot read. The name
    /// resolution returns nil, so the subprogram (with no name) is dropped. No trap.
    func testReaderRejectsWrappingStrxIndexWithoutOOBRead() throws {
        // index * 4 ≈ UInt64.max, so base(8) + product wraps to a tiny in-range offset (0x4).
        let wrapIndex = UInt64.max / 4
        let fixture = SyntheticDWARF.subprogramWithStrxIndex(wrapIndex)
        let symbols = try DWARFReader(sections: fixture).recoverFunctionSymbols()
        XCTAssertTrue(symbols.isEmpty, "a wrapping strx index must not resolve to a name, got \(symbols)")
    }

    /// The mul-overflow leg of the same guard: an index whose `index*4` itself overflows UInt64
    /// (before the base is even added) is rejected the same way.
    func testReaderRejectsStrxIndexWhoseProductOverflows() throws {
        let mulOverflowIndex = (UInt64.max / 4) + 1 // index*4 overflows
        let fixture = SyntheticDWARF.subprogramWithStrxIndex(mulOverflowIndex)
        let symbols = try DWARFReader(sections: fixture).recoverFunctionSymbols()
        XCTAssertTrue(symbols.isEmpty)
    }

    /// (b, addr leg) A `DW_FORM_addrx` index large enough that `base + index*8` WRAPS UInt64 must
    /// be rejected — no OOB read of `.debug_addr`. low_pc stays nil, so the subprogram is dropped.
    func testReaderRejectsWrappingAddrxIndexWithoutOOBRead() throws {
        let wrapIndex = UInt64.max / 8 // index*8 ≈ UInt64.max; +base wraps to 0x0
        let fixture = SyntheticDWARF.subprogramWithAddrxIndex(wrapIndex)
        let symbols = try DWARFReader(sections: fixture).recoverFunctionSymbols()
        XCTAssertTrue(symbols.isEmpty, "a wrapping addrx index must not resolve to an address, got \(symbols)")
    }

    func testReaderRejectsAddrxIndexWhoseProductOverflows() throws {
        let mulOverflowIndex = (UInt64.max / 8) + 1
        let fixture = SyntheticDWARF.subprogramWithAddrxIndex(mulOverflowIndex)
        let symbols = try DWARFReader(sections: fixture).recoverFunctionSymbols()
        XCTAssertTrue(symbols.isEmpty)
    }

    // MARK: - 2. DSYMImportService: real dSYM (clang + dsymutil)

    func testServiceRecoversNamesFromRealDSYMWhenUUIDMatches() throws {
        let built = try RealDSYM.build()

        let service = DSYMImportService()
        let result = try service.importDebugSymbols(at: built.dsymURL, expectedUUID: built.uuid)

        // The recovered set must contain the three named functions we wrote, each at the
        // address otool/dwarfdump reports (the service maps DW_FORM_addrx through .debug_addr).
        let byName = Dictionary(uniqueKeysWithValues: result.functions.map { ($0.name, $0.address) })
        XCTAssertNotNil(byName["helper_alpha"], "helper_alpha not recovered; got \(byName.keys.sorted())")
        XCTAssertNotNil(byName["helper_beta"])
        XCTAssertNotNil(byName["main"])
        XCTAssertEqual(result.matchedUUID.lowercased(), built.uuid.lowercased())

        // Addresses must be the real low_pcs, not the abstract indices: they are distinct,
        // monotonically increasing function starts inside __TEXT.
        let alpha = try XCTUnwrap(byName["helper_alpha"])
        let beta = try XCTUnwrap(byName["helper_beta"])
        XCTAssertNotEqual(alpha, beta)
        XCTAssertGreaterThan(alpha, 0x1000) // a real VA, not a DW_FORM_addrx index (0,1,2,…)
    }

    func testServiceRecoversTypesFromRealDSYMWhenUUIDMatches() throws {
        let built = try RealDSYM.build()

        let result = try DSYMImportService().importDebugSymbols(at: built.dsymURL, expectedUUID: built.uuid)

        let point = try XCTUnwrap(result.types.first { $0.name == "Point" && $0.kind == "struct" })
        XCTAssertEqual(point.members, [
            DWARFTypeMember(name: "x", typeName: "int", byteOffset: 0),
            DWARFTypeMember(name: "y", typeName: "int", byteOffset: 4),
        ])

        let value = try XCTUnwrap(result.types.first { $0.name == "Value" && $0.kind == "union" })
        XCTAssertEqual(value.members, [
            DWARFTypeMember(name: "as_int", typeName: "int", byteOffset: 0),
            DWARFTypeMember(name: "as_double", typeName: "double", byteOffset: 0),
        ])

        let color = try XCTUnwrap(result.types.first { $0.name == "Color" && $0.kind == "enum" })
        XCTAssertEqual(color.enumerators, [
            DWARFEnumerator(name: "RED", value: 0),
            DWARFEnumerator(name: "GREEN", value: 5),
            DWARFEnumerator(name: "BLUE", value: 6),
        ])
    }

    func testServiceRejectsMismatchedUUID() throws {
        let built = try RealDSYM.build()
        let service = DSYMImportService()
        let wrongUUID = "00000000-0000-0000-0000-000000000000"
        XCTAssertThrowsError(try service.importDebugSymbols(at: built.dsymURL, expectedUUID: wrongUUID)) { error in
            guard case let .uuidMismatch(expected, candidates) = (error as? DSYMImportError) else {
                return XCTFail("expected .uuidMismatch, got \(error)")
            }
            XCTAssertEqual(expected, wrongUUID)
            XCTAssertEqual(candidates.count, 1)
            XCTAssertNil(candidates.first?.sliceIndex)
            XCTAssertEqual(candidates.first?.uuid?.lowercased(), built.uuid.lowercased())
        }
    }

    func testServiceRejectsMissingExpectedUUID() throws {
        let built = try RealDSYM.build()
        XCTAssertThrowsError(try DSYMImportService().importDebugSymbols(at: built.dsymURL, expectedUUID: nil)) { error in
            XCTAssertEqual(error as? DSYMImportError, .missingBinaryUUID)
        }
    }

    // MARK: - 3. WorkspaceStore: name injection

    @MainActor
    func testStoreInjectsRecoveredNamesAsCustomNameOverrides() throws {
        let built = try RealDSYM.build()

        // The dSYM's functions sit at known addresses; we build a snapshot whose binary
        // carries the matching UUID and whose functions/section cover those addresses so the
        // names are addressable.
        let service = DSYMImportService()
        let recovered = try service.importDebugSymbols(at: built.dsymURL, expectedUUID: built.uuid).functions
        let target = try XCTUnwrap(recovered.first)

        let snapshot = Self.snapshot(uuid: built.uuid, functionAddress: target.address)
        let store = WorkspaceStore(workspaceName: "dsym", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)

        store.importDebugSymbols(at: built.dsymURL)

        // The injected name shows at the function's address via the same displayName seam a
        // manual rename uses.
        XCTAssertEqual(store.snapshot.displayName(at: target.address, default: "placeholder"), target.name)
        XCTAssertNotNil(store.debugSymbolsResultMessage)
        XCTAssertNil(store.debugSymbolsImportError)

        // The whole import is ONE undoable step: undo reverts every injected name at once.
        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.displayName(at: target.address, default: "placeholder"), "placeholder")
    }

    @MainActor
    func testStoreInjectsRecoveredTypesIntoCatalog() throws {
        let address: UInt64 = 0x100000400
        let snapshot = Self.snapshot(uuid: "88888888-8888-8888-8888-888888888888", functionAddress: address)
        let store = WorkspaceStore(workspaceName: "dsym-types", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)

        let result = DSYMImportResult(
            functions: [DWARFFunctionSymbol(address: address, name: "typed_entry")],
            types: Self.recoveredCatalogTypes(),
            matchedUUID: "88888888-8888-8888-8888-888888888888",
            dwarfURL: URL(fileURLWithPath: "/tmp/x.dSYM/Contents/Resources/DWARF/x")
        )

        store.injectDebugSymbols(result)

        let point = try XCTUnwrap(store.snapshot.typeDefinitions.first { $0.name == "Point" })
        XCTAssertEqual(point.kind, .struct)
        XCTAssertEqual(point.fields, [
            FieldDef(name: "x", type: "int", byteOffset: 0, layoutSource: .dwarf), // RX-02a: the DWARF offset is kept
            FieldDef(name: "y", type: "int", byteOffset: 4, layoutSource: .dwarf),
        ])

        let value = try XCTUnwrap(store.snapshot.typeDefinitions.first { $0.name == "Value" })
        XCTAssertEqual(value.kind, .union)
        XCTAssertEqual(value.fields, [
            FieldDef(name: "as_int", type: "int", byteOffset: 0, layoutSource: .dwarf),
            FieldDef(name: "as_double", type: "double", byteOffset: 0, layoutSource: .dwarf),
        ])

        let color = try XCTUnwrap(store.snapshot.typeDefinitions.first { $0.name == "Color" })
        XCTAssertEqual(color.kind, .enum)
        XCTAssertEqual(color.fields, [
            FieldDef(name: "RED", type: "0"),
            FieldDef(name: "GREEN", type: "5"),
            FieldDef(name: "BLUE", type: "6"),
        ])
        XCTAssertFalse(store.snapshot.typeDefinitions.contains { $0.name == "PointAlias" })
        XCTAssertTrue(store.debugSymbolsResultMessage?.contains("Imported 3 type definitions") == true)
    }

    /// Actual DWARF -> import conversion -> database -> Atlas, including padding and unions.
    @MainActor
    func testRealDWARFLayoutSurvivesDatabaseRoundTrip() throws {
        let built = try RealDSYM.build()
        defer { try? FileManager.default.removeItem(at: built.binaryURL.deletingLastPathComponent()) }
        let recovered = try DSYMImportService().importDebugSymbols(at: built.dsymURL, expectedUUID: built.uuid)
        let imported = WorkspaceStore.typeDefinitions(from: recovered.types, existingTypeNames: [])
        XCTAssertTrue(imported.contains { $0.name == "Node" })
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.typeDefinitions = imported
        let saved = try database.saveSnapshot(workspaceName: "DWARF layout", snapshot: snapshot, now: Date())
        let restored = try XCTUnwrap(database.loadWorkspaceState(workspaceID: try XCTUnwrap(saved.id)))
        XCTAssertEqual(restored.snapshot.typeDefinitions, imported.sorted { $0.name < $1.name })
        let catalog = restored.snapshot.typeCatalog(in: .primary)
        for name in ["Point", "Node", "Value"] {
            let original = try XCTUnwrap(recovered.types.first {
                $0.name == name && $0.kind == (name == "Value" ? "union" : "struct")
            })
            let entry = try XCTUnwrap(catalog.entries(named: name).first)
            XCTAssertFalse(original.members.isEmpty)
            XCTAssertEqual(entry.members.map(\.name), original.members.map(\.name))
            XCTAssertEqual(entry.members.map(\.offset), original.members.map(\.byteOffset))
            XCTAssertTrue(entry.members.allSatisfy { $0.offset != nil && $0.evidence == .descriptor })
        }
        let node = try XCTUnwrap(catalog.entries(named: "Node").first)
        XCTAssertEqual(node.members.map(\.offset), [0, 8, 16, 24])
    }

    @MainActor
    func testStoreKeepsUserAuthoredTypeWhenDWARFNameClashes() throws {
        let address: UInt64 = 0x100000410
        let userPoint = TypeDefinition(kind: .struct, name: "Point", fields: [
            FieldDef(name: "user_field", type: "int64_t"),
        ])
        var snapshot = Self.snapshot(uuid: "99999999-9999-9999-9999-999999999999", functionAddress: address)
        snapshot.typeDefinitions = [userPoint]
        let store = WorkspaceStore(workspaceName: "dsym-types", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)

        let result = DSYMImportResult(
            functions: [DWARFFunctionSymbol(address: address, name: "typed_entry")],
            types: Self.recoveredCatalogTypes(),
            matchedUUID: "99999999-9999-9999-9999-999999999999",
            dwarfURL: URL(fileURLWithPath: "/tmp/x.dSYM/Contents/Resources/DWARF/x")
        )

        store.injectDebugSymbols(result)

        let points = store.snapshot.typeDefinitions.filter { $0.name == "Point" }
        XCTAssertEqual(points, [userPoint])
        XCTAssertTrue(store.snapshot.typeDefinitions.contains { $0.name == "Value" && $0.kind == .union })
    }

    @MainActor
    func testImportedTypesSurviveReanalysis() async throws {
        let fixture = TinyMachO.make(code: Self.branchIntoPrologue)
        let url = try fixture.write()
        let engine = AnalysisEngine()
        let snapshot = try engine.analyze(url: url)
        let address = try XCTUnwrap(snapshot.functions.first?.startAddress)
        let boundary = fixture.baseAddress + 0x0c
        let store = WorkspaceStore(workspaceName: "dsym-types-reanalysis", snapshot: snapshot, engine: engine, autosaveScheduler: nil)

        let result = DSYMImportResult(
            functions: [DWARFFunctionSymbol(address: address, name: "typed_entry")],
            types: Self.recoveredCatalogTypes(),
            matchedUUID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            dwarfURL: URL(fileURLWithPath: "/tmp/x.dSYM/Contents/Resources/DWARF/x")
        )
        store.injectDebugSymbols(result)
        await store.awaitPendingReanalysis()
        XCTAssertNotNil(store.snapshot.typeDefinitions.first { $0.name == "Point" && $0.kind == .struct })

        store.setMarkAsProcedure(boundary, true)
        await store.awaitPendingReanalysis()

        let point = try XCTUnwrap(store.snapshot.typeDefinitions.first { $0.name == "Point" })
        XCTAssertEqual(point.kind, .struct)
        XCTAssertEqual(point.fields, [
            FieldDef(name: "x", type: "int", byteOffset: 0, layoutSource: .dwarf), // RX-02a: the DWARF offset is kept
            FieldDef(name: "y", type: "int", byteOffset: 4, layoutSource: .dwarf),
        ])
    }

    @MainActor
    func testStoreReportsMismatchWithoutMutating() throws {
        let built = try RealDSYM.build()
        // Snapshot binary carries a DIFFERENT UUID, so the import must be rejected and nothing
        // injected.
        let snapshot = Self.snapshot(uuid: "11111111-1111-1111-1111-111111111111", functionAddress: 0x100000328)
        let store = WorkspaceStore(workspaceName: "dsym", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)

        store.importDebugSymbols(at: built.dsymURL)

        XCTAssertNotNil(store.debugSymbolsImportError)
        XCTAssertNil(store.debugSymbolsResultMessage)
        XCTAssertTrue(store.snapshot.addressOverrides.isEmpty)
    }

    @MainActor
    func testRetainedDebugMetadataIsDirtyWithoutMappedNamesAndAfterNameUndo() async throws {
        for includesLines in [false, true] {
            for mappedName in [false, true] {
                // Persistence requires a genuine image byte authority, unlike the name-only
                // synthetic fixture whose /tmp/x path and empty bytes cannot seal a package.
                let fixture = TinyMachO.make(code: Self.branchIntoPrologue)
                let binaryURL = try fixture.write()
                defer { try? FileManager.default.removeItem(at: binaryURL) }
                let engine = AnalysisEngine()
                let snapshot = try engine.analyze(url: binaryURL)
                let address = try XCTUnwrap(snapshot.functions.first?.startAddress)
                let store = WorkspaceStore(workspaceName: "retained-dsym", snapshot: snapshot,
                                           engine: engine, autosaveScheduler: nil)
                let lines: [SourceLineEntry] = includesLines
                    ? [.init(address: address, file: "fixture.c", line: 7, column: 1, endSequence: false)] : []
                let result = DSYMImportResult(
                    functions: mappedName ? [.init(address: address, name: "renamed_entry")] : [],
                    sourceLines: lines,
                    types: includesLines ? [] : Self.recoveredCatalogTypes(),
                    matchedUUID: "88888888-8888-8888-8888-888888888888",
                    dwarfURL: URL(fileURLWithPath: "/tmp/retained.dSYM/Contents/Resources/DWARF/x")
                )
                store.injectDebugSymbols(result)
                await store.awaitPendingReanalysis()
                XCTAssertTrue(store.isDirty)
                if mappedName {
                    store.undoManager.undo()
                    await store.awaitPendingReanalysis()
                    XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])
                    XCTAssertTrue(store.isDirty, "Undo names cannot erase retained metadata's dirty state")
                }
                XCTAssertEqual(store.snapshot.sourceLines, lines)
                if !includesLines { XCTAssertTrue(store.snapshot.typeDefinitions.contains { $0.name == "Point" }) }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("RetainedDSYM-\(UUID()).mscope")
                defer { try? FileManager.default.removeItem(at: url) }
                XCTAssertTrue(store.writeDocumentPackage(to: url), store.saveError ?? "Save failed")
                let reopened = WorkspaceStore(workspaceName: "reopened-dsym", snapshot: snapshot,
                                              engine: AnalysisEngine(), autosaveScheduler: nil)
                XCTAssertTrue(reopened.openDocumentPackage(at: url), reopened.lastIssue ?? "Open failed")
                XCTAssertEqual(reopened.snapshot.sourceLines, lines)
                if !includesLines { XCTAssertTrue(reopened.snapshot.typeDefinitions.contains { $0.name == "Point" }) }

            }
        }
    }

    // MARK: - 3b. Demangling of recovered names (W4-D)

    /// A dSYM that injects a MANGLED C++ name must show the DEMANGLED form in the listing.
    /// Uses a known mangled→demangled pair from the demangler corpus (`_Z3fooi` → `foo(int)`),
    /// driven through the store's real injection seam — so this proves the wired demangle call,
    /// not just the demangler in isolation.
    @MainActor
    func testStoreDemanglesRecoveredCxxNameOnInjection() {
        let address: UInt64 = 0x100000400
        let snapshot = Self.snapshot(uuid: "22222222-2222-2222-2222-222222222222", functionAddress: address)
        let store = WorkspaceStore(workspaceName: "dsym", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)

        // Sanity-tie the expectation to the FROZEN demangler's actual output (not a hard-coded
        // string that could drift): the corpus pair the manifest references.
        XCTAssertEqual(Demangler.mangledToReadable("_Z3fooi"), "foo(int)")

        let result = DSYMImportResult(
            functions: [DWARFFunctionSymbol(address: address, name: "_Z3fooi")],
            matchedUUID: "22222222-2222-2222-2222-222222222222",
            dwarfURL: URL(fileURLWithPath: "/tmp/x.dSYM/Contents/Resources/DWARF/x")
        )
        store.injectDebugSymbols(result)

        XCTAssertEqual(store.snapshot.displayName(at: address, default: "raw"), "foo(int)",
                       "the mangled dSYM name should be shown demangled")
        XCTAssertNil(store.debugSymbolsImportError)
    }

    /// A non-mangled (plain C) name is injected VERBATIM — `displayName(for:)` returns the raw
    /// name unchanged when there is nothing to demangle, so the importer never mangles a name it
    /// shouldn't (no false demangling).
    @MainActor
    func testStoreLeavesPlainNameUnchangedOnInjection() {
        let address: UInt64 = 0x100000500
        let snapshot = Self.snapshot(uuid: "33333333-3333-3333-3333-333333333333", functionAddress: address)
        let store = WorkspaceStore(workspaceName: "dsym", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)

        XCTAssertNil(Demangler.mangledToReadable("helper_alpha")) // not a mangled name

        let result = DSYMImportResult(
            functions: [DWARFFunctionSymbol(address: address, name: "helper_alpha")],
            matchedUUID: "33333333-3333-3333-3333-333333333333",
            dwarfURL: URL(fileURLWithPath: "/tmp/x.dSYM/Contents/Resources/DWARF/x")
        )
        store.injectDebugSymbols(result)

        XCTAssertEqual(store.snapshot.displayName(at: address, default: "raw"), "helper_alpha")
    }

    // MARK: - 4. Scripting: read-debug-symbols command (W4-D)

    @MainActor
    func testScriptingReadDebugSymbolsInjectsDemangledNames() throws {
        let built = try RealDSYM.build()
        let service = DSYMImportService()
        let recovered = try service.importDebugSymbols(at: built.dsymURL, expectedUUID: built.uuid).functions
        let target = try XCTUnwrap(recovered.first)

        let snapshot = Self.snapshot(uuid: built.uuid, functionAddress: target.address)
        let store = WorkspaceStore(workspaceName: "dsym", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        let api = WorkspaceScriptingAPI(store: store)

        let result = try api.execute("read-debug-symbols", arguments: .object(["path": .string(built.dsymURL.path)]))
        XCTAssertEqual(result["ok"]?.boolValue, true)
        XCTAssertEqual(result["matchedUUID"]?.stringValue?.lowercased(), built.uuid.lowercased())
        XCTAssertEqual(store.snapshot.displayName(at: target.address, default: "raw"), target.name)
    }

    /// A wrong expected-UUID surfaces the importer's TYPED `uuidMismatch` failure as a thrown
    /// `ScriptingError` (the GUI path would only set an alert string).
    @MainActor
    func testScriptingReadDebugSymbolsSurfacesUUIDMismatchAsError() throws {
        let built = try RealDSYM.build()
        // Snapshot binary carries a UUID that does NOT match the dSYM.
        let snapshot = Self.snapshot(uuid: "44444444-4444-4444-4444-444444444444", functionAddress: 0x100000400)
        let store = WorkspaceStore(workspaceName: "dsym", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        let api = WorkspaceScriptingAPI(store: store)

        XCTAssertThrowsError(try api.execute("read-debug-symbols", arguments: .object(["path": .string(built.dsymURL.path)]))) { error in
            guard case let ScriptingError.invalidArgument(message) = error else {
                return XCTFail("expected ScriptingError.invalidArgument, got \(error)")
            }
            XCTAssertTrue(message.lowercased().contains("does not match") || message.lowercased().contains("uuid"),
                          "the uuidMismatch detail should surface; got: \(message)")
        }
        // Nothing was injected.
        XCTAssertTrue(store.snapshot.addressOverrides.isEmpty)
    }

    /// A missing path is a typed argument error, not a crash.
    @MainActor
    func testScriptingReadDebugSymbolsRequiresPath() throws {
        let snapshot = Self.snapshot(uuid: "55555555-5555-5555-5555-555555555555", functionAddress: 0x100000400)
        let store = WorkspaceStore(workspaceName: "dsym", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        let api = WorkspaceScriptingAPI(store: store)
        XCTAssertThrowsError(try api.execute("read-debug-symbols", arguments: .object([:]))) { error in
            XCTAssertEqual(error as? ScriptingError, .missingArgument("path"))
        }
    }

    /// A non-existent dSYM path surfaces the importer's `dwarfBinaryNotFound` as a thrown error.
    @MainActor
    func testScriptingReadDebugSymbolsSurfacesNotFoundAsError() throws {
        let snapshot = Self.snapshot(uuid: "66666666-6666-6666-6666-666666666666", functionAddress: 0x100000400)
        let store = WorkspaceStore(workspaceName: "dsym", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        let api = WorkspaceScriptingAPI(store: store)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).dSYM").path
        XCTAssertThrowsError(try api.execute("read-debug-symbols", arguments: .object(["path": .string(missing)]))) { error in
            guard case ScriptingError.invalidArgument = error else {
                return XCTFail("expected ScriptingError.invalidArgument, got \(error)")
            }
        }
    }

    /// The command is registered and advertised through the introspection surface.
    @MainActor
    func testScriptingReadDebugSymbolsIsRegistered() {
        XCTAssertTrue(WorkspaceScriptingAPI.availableCommands.contains { $0.name == "read-debug-symbols" && $0.mutates })
    }

    // MARK: - Snapshot helper

    private static func snapshot(uuid: String, functionAddress: UInt64) -> WorkspaceSnapshot {
        var metadata = BinaryMetadataSummary.empty
        metadata.uuid = uuid
        return WorkspaceSnapshot(
            binaries: [BinaryImage(
                id: UUID(),
                name: "x",
                path: "/tmp/x",
                kind: "Mach-O executable",
                architecture: "arm64",
                metadata: metadata
            )],
            functions: [FunctionSummary(id: UUID(), name: "sub_\(String(functionAddress, radix: 16))", startAddress: functionAddress, endAddress: functionAddress + 4, confidence: 1)],
            instructions: [],
            xrefs: [],
            hexBytes: Data(),
            // A wide __TEXT covers every dSYM function address so addressability never gates the test.
            sections: [SectionSummary(id: UUID(), name: "__TEXT,__text", address: 0x100000000, size: 0x10000, fileOffset: 0, isExecutable: true)]
        )
    }

    private static func recoveredCatalogTypes() -> [DWARFType] {
        [
            DWARFType(
                name: "Point",
                kind: "struct",
                byteSize: 8,
                members: [
                    DWARFTypeMember(name: "x", typeName: "int", byteOffset: 0),
                    DWARFTypeMember(name: "y", typeName: "int", byteOffset: 4),
                ]
            ),
            DWARFType(
                name: "Value",
                kind: "union",
                byteSize: 8,
                members: [
                    DWARFTypeMember(name: "as_int", typeName: "int", byteOffset: 0),
                    DWARFTypeMember(name: "as_double", typeName: "double", byteOffset: 0),
                ]
            ),
            DWARFType(
                name: "Color",
                kind: "enum",
                byteSize: 4,
                enumerators: [
                    DWARFEnumerator(name: "RED", value: 0),
                    DWARFEnumerator(name: "GREEN", value: 5),
                    DWARFEnumerator(name: "BLUE", value: 6),
                ]
            ),
            DWARFType(name: "PointAlias", kind: "typedef", byteSize: 8),
        ]
    }

    /// mov ; b .+8 (-> 0x0c) ; ret ; 0x0c: sub sp,sp,#0x10 ; ret.
    private static let branchIntoPrologue = Data([
        0x00, 0x00, 0x80, 0x52,
        0x02, 0x00, 0x00, 0x14,
        0xc0, 0x03, 0x5f, 0xd6,
        0xff, 0x43, 0x00, 0xd1,
        0xc0, 0x03, 0x5f, 0xd6,
    ])
}

// MARK: - Real dSYM builder (clang + dsymutil)

/// Builds a tiny, real `.dSYM` at test time so the importer is exercised against the EXACT
/// DWARF a modern Apple toolchain emits (DWARF 5, DW_FORM_addrx / DW_FORM_strx). Skips the
/// test cleanly when clang or dsymutil is unavailable, or when the build does not produce a
/// dSYM with debug info on this host.
private enum RealDSYM {
    struct Built {
        var dsymURL: URL
        var binaryURL: URL
        var uuid: String
    }

    static func build() throws -> Built {
        let clang = URL(fileURLWithPath: "/usr/bin/clang")
        let dsymutil = URL(fileURLWithPath: "/usr/bin/dsymutil")
        guard FileManager.default.isExecutableFile(atPath: clang.path),
              FileManager.default.isExecutableFile(atPath: dsymutil.path) else {
            throw XCTSkip("clang/dsymutil unavailable on this host")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-dsym-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sourceURL = dir.appendingPathComponent("x.c")
        try """
        typedef struct Point {
            int x;
            int y;
        } Point;

        enum Color {
            RED = 0,
            GREEN = 5,
            BLUE = 6
        };

        union Value {
            int as_int;
            double as_double;
        };

        struct Node {
            struct Node *next;
            Point origin;
            enum Color color;
            union Value value;
        };

        int helper_alpha(int a) { return a + 1; }
        int helper_beta(int a, int b) {
            union Value value;
            value.as_int = a * b;
            struct Node node = { 0, { a, b }, GREEN, value };
            return node.origin.x + node.origin.y + node.color + node.value.as_int;
        }
        int main(void) { return helper_alpha(2) + helper_beta(3, 4); }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let objectURL = dir.appendingPathComponent("x.o")
        let binaryURL = dir.appendingPathComponent("x")

        // Compile to an object file FIRST, then link: dsymutil needs the .o to survive, and the
        // single-step `clang -g -o x x.c` cleans it up before dsymutil runs (empty debug info).
        try run(clang, ["-g", "-O0", "-c", "-o", objectURL.path, sourceURL.path])
        try run(clang, ["-g", "-O0", "-o", binaryURL.path, objectURL.path])
        try run(dsymutil, [binaryURL.path])

        let dsymURL = dir.appendingPathComponent("x.dSYM", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dsymURL.path) else {
            throw XCTSkip("dsymutil did not produce a dSYM on this host")
        }

        // Read the produced binary's UUID through our own parser (the same value the loader
        // records into BinaryImage.metadata.uuid).
        let bytes = try Data(contentsOf: binaryURL)
        let machO = try MachOParser().parse(bytes, options: MachOParseOptions(
            recoverStringLiterals: false,
            recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: false,
            parseCodeSignature: false
        ))
        guard let uuid = machO.uuid?.stringValue else {
            throw XCTSkip("the test binary has no LC_UUID on this host")
        }

        return Built(dsymURL: dsymURL, binaryURL: binaryURL, uuid: uuid)
    }

    private static func run(_ tool: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain while the child is running so verbose diagnostics cannot fill
        // the pipe and deadlock both the compiler and the test runner.
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(decoding: outputData, as: UTF8.self)
            throw XCTSkip("\(tool.lastPathComponent) failed (\(process.terminationStatus)): \(output)")
        }
    }
}

// MARK: - Synthetic minimal-DWARF byte fixtures

/// Hand-assembles the few bytes of `.debug_abbrev` + `.debug_info` the reader needs, using
/// the simplest DWARF forms so no external section (.debug_addr/.debug_str_offsets) is
/// required. This keeps the reader unit-tested deterministically even with no toolchain.
private enum SyntheticDWARF {

    static func baseTypeWithEncodedName(_ encodedName: [UInt8]) -> DWARFReader.Sections {
        let abbrev: [UInt8] = [
            0x01, 0x24, 0x00,       // base type, no children
            0x0b, 0x0b,             // DW_AT_byte_size, DW_FORM_data1
            0x03, 0x08,             // DW_AT_name, DW_FORM_string (last attribute)
            0x00, 0x00, 0x00,
        ]
        return assembleInfo(
            abbrev: abbrev,
            die: [0x01, 0x04] + encodedName,
            version: 4,
            includeNullDIE: false
        )
    }

    static func subprogramWithScalar(
        form: UInt8,
        operand: [UInt8],
        lowPC: UInt64 = 0x1234
    ) -> DWARFReader.Sections {
        let abbrev: [UInt8] = [
            0x01, 0x2e, 0x00,       // subprogram, no children
            0x03, 0x08,             // DW_AT_name, DW_FORM_string
            0x11, 0x01,             // DW_AT_low_pc, DW_FORM_addr
            0x1c, form,             // DW_AT_const_value, caller-selected scalar form
            0x00, 0x00, 0x00,
        ]
        var die: [UInt8] = [0x01] + Array("scalar_fn".utf8) + [0x00]
        for shift in 0..<8 { die.append(UInt8((lowPC >> (8 * shift)) & 0xff)) }
        die.append(contentsOf: operand)
        return assembleInfo(abbrev: abbrev, die: die, version: 4, includeNullDIE: false)
    }

    static func subprogramWithIndirectName(
        _ encodedName: [UInt8],
        lowPC: UInt64 = 0x1234
    ) -> DWARFReader.Sections {
        // Put DW_AT_name last so malformed indirect forms end exactly at the
        // unit boundary, rather than borrowing bytes from another attribute.
        let abbrev: [UInt8] = [
            0x01, 0x2e, 0x00,       // subprogram, no children
            0x11, 0x01,             // DW_AT_low_pc, DW_FORM_addr
            0x03, 0x16,             // DW_AT_name, DW_FORM_indirect
            0x00, 0x00, 0x00,
        ]
        var die: [UInt8] = [0x01]
        for shift in 0..<8 { die.append(UInt8((lowPC >> (8 * shift)) & 0xff)) }
        die.append(contentsOf: encodedName)
        return assembleInfo(abbrev: abbrev, die: die, version: 4, includeNullDIE: false)
    }

    /// One CU (DWARF v4) → one DW_TAG_subprogram with DW_AT_name (DW_FORM_string, inline) and
    /// DW_AT_low_pc (DW_FORM_addr, 8 bytes).
    static func singleSubprogram(name: String, lowPC: UInt64) -> DWARFReader.Sections {
        // --- abbrev table ---
        // [1] DW_TAG_subprogram, no children, { DW_AT_name DW_FORM_string, DW_AT_low_pc DW_FORM_addr }, (0,0)
        var abbrev: [UInt8] = []
        abbrev.append(0x01)                 // abbrev code 1
        abbrev.append(0x2e)                 // DW_TAG_subprogram
        abbrev.append(0x00)                 // DW_CHILDREN_no
        abbrev.append(contentsOf: [0x03, 0x08]) // DW_AT_name, DW_FORM_string
        abbrev.append(contentsOf: [0x11, 0x01]) // DW_AT_low_pc, DW_FORM_addr
        abbrev.append(contentsOf: [0x00, 0x00]) // end of attributes
        abbrev.append(0x00)                 // end of table

        // --- the single DIE: abbrev code 1, then name string + 8-byte address ---
        var die: [UInt8] = []
        die.append(0x01)                    // abbrev code 1
        die.append(contentsOf: Array(name.utf8))
        die.append(0x00)                    // NUL terminator for DW_FORM_string
        for i in 0..<8 { die.append(UInt8((lowPC >> (8 * i)) & 0xff)) } // DW_FORM_addr, LE

        return assembleInfo(abbrev: abbrev, die: die)
    }

    /// One subprogram with only DW_AT_name (no DW_AT_low_pc) — must be dropped.
    static func subprogramWithoutLowPC(name: String) -> DWARFReader.Sections {
        var abbrev: [UInt8] = []
        abbrev.append(0x01)
        abbrev.append(0x2e)                 // DW_TAG_subprogram
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x03, 0x08]) // DW_AT_name, DW_FORM_string
        abbrev.append(contentsOf: [0x00, 0x00])
        abbrev.append(0x00)

        var die: [UInt8] = []
        die.append(0x01)
        die.append(contentsOf: Array(name.utf8))
        die.append(0x00)

        return assembleInfo(abbrev: abbrev, die: die)
    }

    // MARK: - Adversarial / malformed fixtures (W4-D fuzz)

    /// A DWARF-5 CU whose subprogram carries a `DW_FORM_exprloc` attribute (DW_AT_frame_base,
    /// 0x40) whose ULEB128 length is `bytes` — used to drive a crafted, oversized length
    /// (e.g. 2^63) into the reader. A NAME and a DW_FORM_addr low_pc precede it so, absent the
    /// overflow, the reader WOULD recover a function — the test asserts it does not trap instead.
    static func subprogramWithExprlocLength(_ lengthULEB: [UInt8]) -> DWARFReader.Sections {
        // abbrev: DW_TAG_subprogram, no children,
        //   { DW_AT_name DW_FORM_string, DW_AT_low_pc DW_FORM_addr, DW_AT_frame_base DW_FORM_exprloc }
        var abbrev: [UInt8] = []
        abbrev.append(0x01)                      // abbrev code 1
        abbrev.append(0x2e)                      // DW_TAG_subprogram
        abbrev.append(0x00)                      // DW_CHILDREN_no
        abbrev.append(contentsOf: [0x03, 0x08])  // DW_AT_name, DW_FORM_string
        abbrev.append(contentsOf: [0x11, 0x01])  // DW_AT_low_pc, DW_FORM_addr
        abbrev.append(contentsOf: [0x40, 0x18])  // DW_AT_frame_base, DW_FORM_exprloc
        abbrev.append(contentsOf: [0x00, 0x00])  // end of attributes
        abbrev.append(0x00)                      // end of table

        var die: [UInt8] = []
        die.append(0x01)                         // abbrev code 1
        die.append(contentsOf: Array("fuzz_fn".utf8))
        die.append(0x00)                         // DW_FORM_string NUL
        for _ in 0..<8 { die.append(0x11) }      // DW_FORM_addr low_pc = 0x1111111111111111
        die.append(contentsOf: lengthULEB)       // DW_FORM_exprloc length (crafted)
        // NOTE: deliberately NO block payload after the length — a non-trapping reader must
        // reject the length BEFORE attempting to skip that many bytes.

        return assembleInfo(abbrev: abbrev, die: die)
    }

    /// A DWARF-5 CU whose subprogram names itself through `DW_FORM_strx` with a crafted index,
    /// against a SHORT `.debug_str_offsets`. The index is chosen so `base + index*4` would wrap
    /// UInt64 back into range — a non-overflow-checked reader would read an attacker-chosen slot
    /// out of bounds. A valid reader rejects it (name stays nil → subprogram dropped).
    static func subprogramWithStrxIndex(_ index: UInt64) -> DWARFReader.Sections {
        // v5 abbrev: DW_TAG_subprogram, { DW_AT_name DW_FORM_strx, DW_AT_low_pc DW_FORM_addr }
        var abbrev: [UInt8] = []
        abbrev.append(0x01)
        abbrev.append(0x2e)                      // DW_TAG_subprogram
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x03, 0x1a])  // DW_AT_name, DW_FORM_strx
        abbrev.append(contentsOf: [0x11, 0x01])  // DW_AT_low_pc, DW_FORM_addr
        abbrev.append(contentsOf: [0x00, 0x00])
        abbrev.append(0x00)

        var die: [UInt8] = []
        die.append(0x01)
        die.append(contentsOf: uleb128(index))   // DW_FORM_strx index (crafted, may wrap)
        for _ in 0..<8 { die.append(0x22) }       // DW_FORM_addr low_pc

        // A non-empty (but short) str_offsets so the reader's emptiness guard passes and it
        // reaches the overflow arithmetic; far too short to hold the wrapped slot legitimately.
        let strOffsets = Data([0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00])
        var sections = assembleInfo(abbrev: abbrev, die: die, version: 5)
        sections.debugStrOffsets = strOffsets
        sections.debugStr = Data("legit\u{00}".utf8)
        return sections
    }

    /// A DWARF-5 CU whose subprogram addresses itself through `DW_FORM_addrx` with a crafted
    /// index against a SHORT `.debug_addr`, chosen so `base + index*8` would wrap UInt64. A valid
    /// reader rejects it (low_pc stays nil → subprogram dropped); a buggy one reads OOB.
    static func subprogramWithAddrxIndex(_ index: UInt64) -> DWARFReader.Sections {
        // v5 abbrev: DW_TAG_subprogram, { DW_AT_name DW_FORM_string, DW_AT_low_pc DW_FORM_addrx }
        var abbrev: [UInt8] = []
        abbrev.append(0x01)
        abbrev.append(0x2e)                      // DW_TAG_subprogram
        abbrev.append(0x00)
        abbrev.append(contentsOf: [0x03, 0x08])  // DW_AT_name, DW_FORM_string
        abbrev.append(contentsOf: [0x11, 0x1b])  // DW_AT_low_pc, DW_FORM_addrx
        abbrev.append(contentsOf: [0x00, 0x00])
        abbrev.append(0x00)

        var die: [UInt8] = []
        die.append(0x01)
        die.append(contentsOf: Array("addrx_fn".utf8))
        die.append(0x00)
        die.append(contentsOf: uleb128(index))   // DW_FORM_addrx index (crafted, may wrap)

        var sections = assembleInfo(abbrev: abbrev, die: die, version: 5)
        // Non-empty but short .debug_addr (one 8-byte slot) so the emptiness guard passes.
        sections.debugAddr = Data([0xde, 0xad, 0xbe, 0xef, 0x00, 0x00, 0x00, 0x00])
        return sections
    }

    /// Encodes `value` as an unsigned LEB128 byte sequence.
    static func uleb128(_ value: UInt64) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// Wraps a DIE + abbrev into a complete `.debug_info` CU with a correct unit_length.
    /// `version` selects the v4 (default) or v5 header layout — the reader's `parseCompilationUnit`
    /// reorders unit_type/address_size for v5, so an indexed-form fixture must announce v5.
    private static func assembleInfo(
        abbrev: [UInt8],
        die: [UInt8],
        version: UInt16,
        includeNullDIE: Bool = true
    ) -> DWARFReader.Sections {
        var body: [UInt8] = []
        body.append(UInt8(version & 0xff))
        body.append(UInt8((version >> 8) & 0xff))
        if version >= 5 {
            body.append(0x01)                                  // unit_type = DW_UT_compile
            body.append(0x08)                                  // address_size = 8
            body.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // debug_abbrev_offset = 0
        } else {
            body.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // debug_abbrev_offset = 0
            body.append(0x08)                                  // address_size = 8
        }
        body.append(contentsOf: die)
        if includeNullDIE { body.append(0x00) }                // end-of-children null DIE

        var info: [UInt8] = []
        let unitLength = UInt32(body.count)
        for i in 0..<4 { info.append(UInt8((unitLength >> (8 * i)) & 0xff)) }
        info.append(contentsOf: body)

        return DWARFReader.Sections(debugInfo: Data(info), debugAbbrev: Data(abbrev))
    }

    /// Wraps a DIE + abbrev into a complete `.debug_info` CU (v4) with a correct unit_length.
    private static func assembleInfo(abbrev: [UInt8], die: [UInt8]) -> DWARFReader.Sections {
        assembleInfo(abbrev: abbrev, die: die, version: 4)
    }
}
