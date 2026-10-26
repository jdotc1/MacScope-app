import Foundation
import XCTest
@testable import MacScope

/// New recovery work, not recovered historical source. Every assertion reaches
/// the shipped AnalysisEngine -> imported Snapshot -> export-render entry.
/// The shared import prerequisite is not itself credited as behavioral red.
@MainActor
final class S1RecoveryProductionProofTests: XCTestCase {
    private let header = """
        struct Ops { struct Ops *child; void (*run)(struct Ops *ops, int flag); };
        void install(struct Ops *ops); void install_other(struct Ops *ops);
        void dispatch(struct Ops *ops, int flag, void *other);
        """
    private let direct: [UInt32] = [0xf9400408, 0xd63f0100, 0xd65f03c0]
    private let copied: [UInt32] = [0xaa0003f3, 0x14000001, 0xf9400668, 0xd63f0100, 0xd65f03c0]

    private func adr(_ register: UInt32, at pc: UInt64, to target: UInt64) -> UInt32 {
        let delta = Int64(target) - Int64(pc)
        precondition((-(Int64(1) << 20)..<(Int64(1) << 20)).contains(delta))
        let immediate = UInt32(truncatingIfNeeded: delta) & 0x1fffff
        return 0x10000000 | ((immediate & 3) << 29) | ((immediate >> 2) << 5) | register
    }
    private func store(_ target: UInt64 = 0x3000, offset: UInt32 = 8, at: UInt64 = 0x1000) -> [UInt32] {
        [adr(9, at: at, to: target), 0xf9000009 | ((offset / 8) << 10), 0xd65f03c0]
    }

    private func make(_ declaration: String? = nil, dispatch: [UInt32]? = nil,
                      install: [UInt32]? = nil, otherInstall: [UInt32]? = nil,
                      exported: Set<String> = ["install", "install_other", "dispatch"],
                      extraExports: Set<String> = []) throws -> RecoveryStore {
        var bodies: [UInt64: (String, [UInt32])] = [
            0x1000: ("install", install ?? store()),
            0x2000: ("dispatch", dispatch ?? direct),
            0x3000: ("handler", [0xd65f03c0]),
            0x3100: ("alternate", [0xd65f03c0])
        ]
        if let otherInstall { bodies[0x1800] = ("install_other", otherInstall) }
        let bytes = S1RecoveryMachOFixture.make(bodies: bodies, exported: exported.union(extraExports))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s1-recovery-\(UUID().uuidString).dylib")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try AnalysisEngine().analyze(url: url)
        let analysis = try XCTUnwrap(snapshot.analysis(in: .primary))
        XCTAssertEqual(analysis.imageBytes, bytes)
        for address in bodies.keys {
            XCTAssertTrue(analysis.functions.contains { $0.startAddress == address }, "missing function \(address)")
        }
        let result = RecoveryStore(snapshot: snapshot)
        result.defineTypesFromCHeader(declaration ?? header)
        return result
    }
    private func render(_ store: RecoveryStore, at address: UInt64 = 0x2000) -> String {
        _ = store.snapshot.imageWideIndirectCalls(in: .primary, compute: true)
        return DocumentExportService().pseudocodeText(
            for: store.snapshot.pseudocodeRenderInput(selectedAddress: address, in: .primary), options: .default)
    }
    private func compact(_ value: String) -> String { value.filter { !$0.isWhitespace } }
    private func typed(_ text: String) -> Bool {
        compact(text).contains("void(*)(structOps*,int32_t)")
    }
    private func positive(file: StaticString = #filePath, line: UInt = #line) throws {
        // No singleton store inventory is necessary for declared slot-call typing.
        let value = try make(install: [0xd65f03c0])
        let text = render(value)
        XCTAssertTrue(typed(text), text, file: file, line: line)
        XCTAssertTrue(value.snapshot.addressOverrides.isEmpty, file: file, line: line)
        let ops = try XCTUnwrap(value.snapshot.typeDefinitions.first { $0.name == "Ops" }, file: file, line: line)
        XCTAssertNotNil(ops.fields.first { $0.name == "run" }?.functionPointerSignatureV1, file: file, line: line)
    }

    func testDeclaredSlotTypesCallWithoutSingletonTarget() throws { try positive() }

    func testTwoLiteralTargetsStillUseOneDeclaredCallContract() throws {
        try positive()
        let value = try make(otherInstall: store(0x3100, at: 0x1800))
        let text = render(value)
        XCTAssertTrue(typed(text), text)
        XCTAssertFalse(text.contains("/* via"), "Two target identities must not become a singleton: \(text)")
    }


    func testPointerChaseFromH1RootTypesCall() throws {
        try positive()
        // child = ops->child; target = child->run; target(ops,flag).
        let value = try make(dispatch: [0xf9400009, 0xf9400528, 0xd63f0100, 0xd65f03c0])
        XCTAssertTrue(typed(render(value)))
    }

    func testAuthoredRootCannotSubstituteForImportedH1() throws {
        try positive()
        let value = try make(exported: ["install"])
        value.snapshot.addressOverrides[.primary(0x2000)] = AddressOverride(signature:
            FunctionSignatureOverride(args: [ArgOverride(index: 0, name: "ops", type: "struct Ops *")]))
        XCTAssertNil(value.snapshot.importedPrototypes[.primary(0x2000)])
        XCTAssertFalse(typed(render(value)))
    }

    func testEffectiveAuthoredRootDisagreementRefuses() throws {
        try positive()
        let value = try make()
        value.snapshot.addressOverrides[.primary(0x2000)] = AddressOverride(signature:
            FunctionSignatureOverride(args: [ArgOverride(index: 0, name: "unknown", type: "void *")]))
        XCTAssertFalse(typed(render(value)))
    }

    func testAuthoredAndExportedCalleeContractsWin() throws {
        try positive()
        let authored = try make()
        let signature = FunctionSignatureOverride(returnType: "uint64_t", args: [])
        authored.snapshot.addressOverrides[.primary(0x3000)] = AddressOverride(signature: signature)
        _ = render(authored)
        XCTAssertEqual(authored.snapshot.functionSignatureOverrides(in: .primary)[0x3000], signature)
        XCTAssertFalse(typed(render(authored)), "Incompatible authored writer target cannot lend the slot a safe contract")
        let exported = try make(header + "\nlong handler(void);", extraExports: ["handler"])
        _ = render(exported)
        XCTAssertEqual(exported.snapshot.functionSignatureOverrides(in: .primary)[0x3000]?.returnType, "int64_t")
        XCTAssertTrue(exported.snapshot.functionSignatureOverrides(in: .primary)[0x3000]?.args.isEmpty == true)
        XCTAssertFalse(typed(render(exported)), "Incompatible H1 writer target must be reported/refused")
    }

    func testNewIncompatibleWriterTargetPoisonsDeclaredSlotAdmission() throws {
        try positive()
        let value = try make(header + "\nlong alternate(void);",
            otherInstall: store(0x3100, at: 0x1800), extraExports: ["alternate"])
        XCTAssertFalse(typed(render(value)))
        XCTAssertEqual(value.snapshot.functionSignatureOverrides(in: .primary)[0x3100]?.returnType, "int64_t")
        XCTAssertNil(value.snapshot.addressOverrides[.primary(0x3100)])
    }

    func testUnprovenBaseAndPrivatePrefixCastRefuse() throws {
        try positive()
        let untyped = try make(exported: ["install"])
        XCTAssertFalse(typed(render(untyped)))
        let privateCast = try make("""
            struct Public { long tag; }; struct Ops { struct Public pub; void (*run)(struct Ops *ops, int flag); };
            void dispatch(struct Public *ops, int flag, void *other); void install(struct Ops *ops);
            """)
        XCTAssertFalse(typed(render(privateCast)))
    }

    func testNonliteralWrongOffsetIndexedAndWritebackStoresDoNotBindCallee() throws {
        try positive()
        let invalid: [[UInt32]] = [
            [0xd2860009, 0xf9000409, 0xd65f03c0], // MOVZ x9,#0x3000, not ADR.
            store(offset: 0), // child is a data pointer, not a callable field.
            [adr(9, at: 0x1000, to: 0x3000), 0xf8216809, 0xd65f03c0], // STR x9,[x0,x1].
            [adr(9, at: 0x1000, to: 0x3000), 0xf8008c09, 0xd65f03c0] // STR x9,[x0,#8]!.
        ]
        for body in invalid {
            let value = try make(install: body)
            _ = render(value)
            XCTAssertNil(value.snapshot.functionSignatureOverrides(in: .primary)[0x3000])
        }
    }

    func testConflictingSlotTypesRefuseCallee() throws {
        try positive()
        let value = try make("""
            struct Ops { struct Ops *child; void (*run)(struct Ops *ops, int flag); long (*other)(void); };
            void install(struct Ops *ops); void install_other(struct Ops *ops); void dispatch(struct Ops *ops, int flag, void *other);
            """, otherInstall: store(offset: 16, at: 0x1800))
        _ = render(value)
        XCTAssertNil(value.snapshot.functionSignatureOverrides(in: .primary)[0x3000])
    }


    func testUnspecifiedAndExplicitEmptyPrototypesRemainDistinct() throws {
        try positive()
        let declaration = """
            struct Ops { struct Ops *child; void (*run)(void); void (*unknown)(); };
            void install(struct Ops *ops); void install_other(struct Ops *ops); void dispatch(struct Ops *ops, int flag, void *other);
            """
        let empty = try make(declaration)
        XCTAssertTrue(compact(render(empty)).contains("void(*)(void)"))
        let conflict = try make(declaration, otherInstall: store(offset: 16, at: 0x1800))
        _ = render(conflict)
        XCTAssertNil(conflict.snapshot.functionSignatureOverrides(in: .primary)[0x3000])
        let unknown = try make(declaration, dispatch: [0xf9400808, 0xd63f0100, 0xd65f03c0])
        XCTAssertFalse(compact(render(unknown)).contains("void(*)(void)"))
    }

    func testVariadicAndAggregateABIRefuseWithoutGuessing() throws {
        try positive()
        for type in ["void (*run)(int n, ...);", "void (*run)(struct Value value);"] {
            let value = try make("struct Value { long a; long b; }; struct Ops { void *child; \(type) }; void dispatch(struct Ops *ops, int flag, void *other);")
            let text = compact(render(value))
            XCTAssertFalse(text.contains("void(*)("), text)
        }
    }

    func testDominatingPhysicalRootCopySurvivesForwardBlockAndCall() throws {
        try positive()
        XCTAssertTrue(typed(render(try make(dispatch: copied))))
        // x19 survives the external call, but w1 does not. Preserve that original
        // sequence as an ABI refusal instead of inventing a caller-saved argument.
        let incomplete = try make(dispatch: [0xaa0003f3, 0x9407f7ff, 0xf9400668, 0xd63f0100, 0xd65f03c0])
        XCTAssertFalse(typed(render(incomplete)))
        XCTAssertNotNil(incomplete.snapshot.slotTypedPrototypeReport(in: .primary, compute: false)?.callContracts[0x200c],
            "The saved x19 root still proves the slot contract despite incomplete argument capture")
        // Restore x0 from x19 and explicitly define w1 after the clobbering call.
        let restored = try make(dispatch: [0xaa0003f3, 0x9407f7ff, 0xaa1303e0, 0x528000e1,
                                          0xf9400668, 0xd63f0100, 0xd65f03c0])
        XCTAssertTrue(typed(render(restored)))
    }

    func testJoinRedefinitionNarrowCopyAndStackReloadRefuse() throws {
        try positive()
        let cases: [[UInt32]] = [
            [0xb4000061, 0xaa0003f3, 0x14000002, 0xaa0203f3, 0xf9400668, 0xd63f0100, 0xd65f03c0],
            [0xaa0003f3, 0xaa0203f3, 0x14000001, 0xf9400668, 0xd63f0100, 0xd65f03c0],
            [0x2a0003f3, 0x14000001, 0xf9400668, 0xd63f0100, 0xd65f03c0],
            [0xf90003e0, 0xf94003f3, 0x14000001, 0xf9400668, 0xd63f0100, 0xd65f03c0]
        ]
        for body in cases { XCTAssertFalse(typed(render(try make(dispatch: body)))) }
    }

    func testEntryLoopAndAcyclicBackwardPhysicalOverwritesRefuse() throws {
        try positive()
        let cases: [[UInt32]] = [
            [0xf9400408, 0xd63f0100, 0xaa0203e0, 0xb5ffffa1, 0xd65f03c0],
            [0xaa0003f3, 0xf9400668, 0xd63f0100, 0xaa0203f3, 0xb5ffffa1, 0xd65f03c0],
            [0xaa0003f3, 0x14000004, 0xf9400668, 0xd63f0100, 0xd65f03c0, 0xaa0203f3, 0x17fffffc]
        ]
        for body in cases { XCTAssertFalse(typed(render(try make(dispatch: body)))) }
    }

    func testFieldChaseDoesNotPersistAcrossCallsOrBlocks() throws {
        try positive()
        for boundary: UInt32 in [0x14000001, 0x9407f7ff] {
            let value = try make(dispatch: [0xf9400013, boundary, 0xf9400668, 0xd63f0100, 0xd65f03c0])
            XCTAssertFalse(typed(render(value)))
        }
    }

    func testCapturedTargetIsNotReloadedAndIntegerArgumentUsesWCarrier() throws {
        try positive()
        // Capture run in x8, replace the slot itself with null, then call
        // captured x8. Re-evaluating ops->run would now call null.
        let value = try make(dispatch:
            [0xf9400408, 0xf900041f, 0x528000e1, 0xd63f0100, 0xd65f03c0], install: [0xd65f03c0])
        let text = compact(render(value))
        XCTAssertTrue(text.contains("void(*)(structOps*,int32_t)"), text)
        let expression = try NSRegularExpression(pattern: #"\(\(void\(\*\)\(structOps\*,int32_t\)\)([A-Za-z_][A-Za-z_0-9]*)\)\("#)
        let match = try XCTUnwrap(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            "Typed call must use a captured scalar identifier, not a reloaded field: \(text)")
        let targetRange = try XCTUnwrap(Range(match.range(at: 1), in: text))
        let captured = String(text[targetRange])
        let callRange = try XCTUnwrap(Range(match.range, in: text))
        let prefix = String(text[..<callRange.lowerBound])
        let captureRange = try XCTUnwrap(prefix.range(of: captured + "="),
            "Captured value must be assigned before the typed call: \(text)")
        let mutationRange = try XCTUnwrap(prefix.range(of: "=0x0;"),
            "Fixture must overwrite the slot before the call: \(text)")
        XCTAssertLessThan(captureRange.lowerBound, mutationRange.lowerBound,
            "The called capture must precede the slot overwrite: \(text)")
        let input = value.snapshot.pseudocodeRenderInput(selectedAddress: 0x2000, in: .primary)
        let function = PseudocodePrinter().buildFunction(functionName: input.functionName,
            startAddress: input.startAddress, jumpTables: input.jumpTables,
            signatureOverrides: input.signatureOverrides, slotCallContracts: input.slotCallContracts,
            types: input.types, instructions: input.instructions)
        let load = try XCTUnwrap(function.instructions.first { $0.source.address == 0x2000 })
        let write = try XCTUnwrap(function.instructions.first { $0.source.address == 0x2008 })
        let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x200c })
        guard case let .load(capture, _) = load.operation,
              case let .assign(argumentValue, _) = write.operation,
              case let .call(frame, _) = call.operation else {
            return XCTFail("Expected actual load, W1 assignment and call operations")
        }
        XCTAssertEqual(frame.controlInputs.indirectTarget?.value, capture,
            "Typed frame must retain the original load, not read the mutated slot")
        let argument = try XCTUnwrap(frame.arguments.fixedArgument(at: 1))
        XCTAssertEqual(argument.location, .gpr(index: 1, carrierWidth: 32))
        XCTAssertEqual(argument.value, argumentValue, "The call must consume the reaching W1 assignment")
    }

    func testMixedTypedAndGenericNilCallsKeepUntypedFootprint() throws {
        try positive()
        let declaration = """
            struct Ops { void *child; void (*run)(struct Ops *ops, int flag); void (*missing)(Unknown value); };
            void dispatch(struct Ops *ops, int flag, void *other);
            """
        let value = try make(declaration, dispatch: [0xaa0003f3, 0xf9400668, 0xd63f0100,
            0xf9400a68, 0xd63f0100, 0xd65f03c0], install: [0xd65f03c0])
        let owner = try XCTUnwrap(value.snapshot.typeDefinitions.first { $0.name == "Ops" })
        XCTAssertNil(owner.fields.first { $0.name == "missing" }?.functionPointerSignatureV1)
        XCTAssertFalse(typed(render(value)), "No dependency-isolation proof may be guessed for a mixed typed/nil body")
    }

    /// The six witness callback fields carry real header declarations, so each one
    /// must resolve to its exact declared signature and source provenance.
    func testSixHeaderDeclaredWitnessSignaturesHaveExactProvenance() throws {
        try positive()
        let source = try witnessHeaders()
        let parsed = CTypeHeaderParser.parse(source)
        let directory = TestSourceRoot.url.appendingPathComponent("MacScope/Tests/CoreTests/Fixtures/libjpeg-turbo-3.2.0")
        let expected: [(owner: String, field: String, file: String, first: Int, last: Int,
                        offset: Int, declaration: String, signature: FunctionPointerSignatureV1)] = [
            ("jpeg_forward_dct", "forward_DCT", "jpegint.h", 218, 221, 8, "  void (*forward_DCT) (j_compress_ptr cinfo, jpeg_component_info *compptr,\n                       JSAMPARRAY sample_data, JBLOCKROW coef_blocks,\n                       JDIMENSION start_row, JDIMENSION start_col,\n                       JDIMENSION num_blocks);", .init(returnType: "void", parameters: [.init(name: "cinfo", type: "struct jpeg_compress_struct *"), .init(name: "compptr", type: "jpeg_component_info *"), .init(name: "sample_data", type: "uint8_t * *"), .init(name: "coef_blocks", type: "JBLOCK *"), .init(name: "start_row", type: "uint32_t"), .init(name: "start_col", type: "uint32_t"), .init(name: "num_blocks", type: "uint32_t")])),
            ("jpeg_forward_dct", "forward_DCT_12", "jpegint.h", 222, 225, 16, "  void (*forward_DCT_12) (j_compress_ptr cinfo, jpeg_component_info *compptr,\n                          J12SAMPARRAY sample_data, JBLOCKROW coef_blocks,\n                          JDIMENSION start_row, JDIMENSION start_col,\n                          JDIMENSION num_blocks);", .init(returnType: "void", parameters: [.init(name: "cinfo", type: "struct jpeg_compress_struct *"), .init(name: "compptr", type: "jpeg_component_info *"), .init(name: "sample_data", type: "int16_t * *"), .init(name: "coef_blocks", type: "JBLOCK *"), .init(name: "start_row", type: "uint32_t"), .init(name: "start_col", type: "uint32_t"), .init(name: "num_blocks", type: "uint32_t")])),
            ("jpeg_entropy_encoder", "encode_mcu", "jpegint.h", 233, 233, 8, "  boolean (*encode_mcu) (j_compress_ptr cinfo, JBLOCKROW *MCU_data);", .init(returnType: "int32_t", parameters: [.init(name: "cinfo", type: "struct jpeg_compress_struct *"), .init(name: "MCU_data", type: "JBLOCK * *")])),
            ("jpeg_entropy_decoder", "decode_mcu", "jpegint.h", 403, 403, 8, "  boolean (*decode_mcu) (j_decompress_ptr cinfo, JBLOCKROW *MCU_data);", .init(returnType: "int32_t", parameters: [.init(name: "cinfo", type: "struct jpeg_decompress_struct *"), .init(name: "MCU_data", type: "JBLOCK * *")])),
            ("jpeg_memory_mgr", "alloc_barray", "jpeglib.h", 908, 909, 24, "  JBLOCKARRAY (*alloc_barray) (j_common_ptr cinfo, int pool_id,\n                               JDIMENSION blocksperrow, JDIMENSION numrows);", .init(returnType: "JBLOCK * *", parameters: [.init(name: "cinfo", type: "struct jpeg_common_struct *"), .init(name: "pool_id", type: "int32_t"), .init(name: "blocksperrow", type: "uint32_t"), .init(name: "numrows", type: "uint32_t")])),
            ("jpeg_memory_mgr", "access_virt_barray", "jpeglib.h", 924, 926, 64, "  JBLOCKARRAY (*access_virt_barray) (j_common_ptr cinfo, jvirt_barray_ptr ptr,\n                                     JDIMENSION start_row, JDIMENSION num_rows,\n                                     boolean writable);", .init(returnType: "JBLOCK * *", parameters: [.init(name: "cinfo", type: "struct jpeg_common_struct *"), .init(name: "ptr", type: "struct jvirt_barray_control *"), .init(name: "start_row", type: "uint32_t"), .init(name: "num_rows", type: "uint32_t"), .init(name: "writable", type: "int32_t")]))
        ]
        for item in expected {
            let raw = try String(contentsOf: directory.appendingPathComponent(item.file), encoding: .utf8)
            let lines = raw.components(separatedBy: "\n")
            XCTAssertGreaterThanOrEqual(lines.count, item.last)
            guard lines.count >= item.last else { continue }
            XCTAssertEqual(lines[(item.first - 1)..<item.last].joined(separator: "\n"), item.declaration,
                           "Real declaration provenance: \(item.file):\(item.first)-\(item.last)")
            let parsedOwner = try XCTUnwrap(parsed.types.first { $0.name == item.owner })
            let parsedField = try XCTUnwrap(parsedOwner.fields.first { $0.name == item.field })
            XCTAssertEqual(parsedField.functionPointerSignatureV1, item.signature)
            let declaration = source + "\nvoid dispatch(struct \(item.owner) *ops, int flag, void *other);"
            let load = UInt32(0xf9400008) | (UInt32(item.offset / 8) << 10)
            let value = try make(declaration, dispatch: [load, 0xd63f0100, 0xd65f03c0], install: [0xd65f03c0])
            let catalog = Dictionary(uniqueKeysWithValues: value.snapshot.typeDefinitions.map { ($0.name, $0) })
            let importedOwner = try XCTUnwrap(catalog[item.owner])
            var comparable = parsedOwner
            comparable.id = importedOwner.id
            XCTAssertEqual(importedOwner, comparable, "Complete imported layout, not a name match")
            let member = try XCTUnwrap(importedOwner.memberLayout(in: catalog).first { $0.field.name == item.field })
            XCTAssertEqual(member.offset, item.offset)
            XCTAssertEqual(member.field, parsedField)
            XCTAssertEqual(member.field.functionPointerSignatureV1, item.signature)
            let warmed = render(value)
            XCTAssertEqual(render(value), warmed, "Stable admitted or conservatively refused warm result")

            // Same owner/field spelling without a callback declaration supplies no signature.
            let nameOnly = "struct \(item.owner) { void *\(item.field); }; "
                + "void dispatch(struct \(item.owner) *ops, int flag, void *other);"
            let negative = try make(nameOnly, dispatch: [0xf9400008, 0xd63f0100, 0xd65f03c0], install: [0xd65f03c0])
            let negativeField = try XCTUnwrap(negative.snapshot.typeDefinitions.first { $0.name == item.owner }?.fields.first)
            XCTAssertNil(negativeField.functionPointerSignatureV1, "Names cannot manufacture callback authority")
            let cold = DocumentExportService().pseudocodeText(for: negative.snapshot.pseudocodeRenderInput(selectedAddress: 0x2000, in: .primary), options: .default)
            XCTAssertEqual(render(negative), cold)
            XCTAssertFalse(compact(render(negative)).contains("(*)("))
        }
    }

    func testInferredRootAndIntermediateLayoutsCannotProvideHeaderAuthority() throws {
        try positive()
        for chased in [false, true] {
            let declaration = chased ? """
                struct Ops { struct Ops *child; void (*run)(struct Ops *ops, int flag); };
                struct Root { struct Ops *child; };
                void dispatch(struct Root *root, int flag, void *other);
                """ : header
            let value = try make(declaration, dispatch: chased
                ? [0xf9400013, 0xf9400668, 0xd63f0100, 0xd65f03c0] : direct,
                install: [0xd65f03c0])
            let index = try XCTUnwrap(value.snapshot.typeDefinitions.firstIndex { $0.name == "Ops" })
            value.snapshot.typeDefinitions[index].inferenceProvenance = TypeInferenceProvenance(
                source: "usage-candidate-v1", candidateID: "test-candidate", root: "param:x0",
                functionStart: 0x2000, observationCount: 2, fieldCount: 2, conflictCount: 0,
                extentLowerBound: 16, incompleteness: [])
            XCTAssertFalse(typed(render(value)), "An H1 parameter must not promote an inferred layout to header authority")
        }
    }

    func testAtomicCallableAndPointerChaseStorageRefuse() throws {
        try positive()
        for chased in [false, true] {
            let value = try make(dispatch: chased
                ? [0xf9400013, 0xf9400668, 0xd63f0100, 0xd65f03c0] : direct,
                install: [0xd65f03c0])
            let owner = try XCTUnwrap(value.snapshot.typeDefinitions.firstIndex { $0.name == "Ops" })
            let field = try XCTUnwrap(value.snapshot.typeDefinitions[owner].fields.firstIndex {
                $0.name == (chased ? "child" : "run")
            })
            value.snapshot.typeDefinitions[owner].fields[field].isAtomic = true
            XCTAssertFalse(typed(render(value)), "Unsupported atomic storage must not become ordinary pointer-load authority")
        }
    }

    func testPrototypeOnlyImportCannotAuthorizeAnExistingAuthoredLayout() throws {
        try positive()
        let value = try make(install: [0xd65f03c0])
        let authoredCatalog = value.snapshot.typeDefinitions
        value.snapshot.typeDefinitions = authoredCatalog
        value.snapshot.importedPrototypes = [:]
        value.defineTypesFromCHeader("void dispatch(struct Ops *ops, int flag, void *other);")
        XCTAssertNotNil(value.snapshot.importedPrototypes[ImageAddress(slot: .primary, address: 0x2000)],
            "Fixture must retain the prototype-only H1 root")
        XCTAssertFalse(typed(render(value)), "A prototype token cannot prove the origin of an existing struct layout")
    }

    func testTransitiveConflictingRetainedLayoutCannotAuthorizePointerChase() throws {
        try positive()
        let declaration = """
            struct Ops { struct Ops *child; void (*run)(struct Ops *ops, int flag); };
            struct Root { struct Ops *child; };
            void dispatch(struct Root *root, int flag, void *other);
            """
        let value = try make(declaration,
            dispatch: [0xf9400013, 0xf9400668, 0xd63f0100, 0xd65f03c0], install: [0xd65f03c0])
        let owner = try XCTUnwrap(value.snapshot.typeDefinitions.firstIndex { $0.name == "Ops" })
        value.snapshot.typeDefinitions[owner].fields[0].name = "authored_child"
        value.snapshot.importedPrototypes = [:]
        value.defineTypesFromCHeader(declaration)
        XCTAssertNotNil(value.snapshot.importedPrototypes[ImageAddress(slot: .primary, address: 0x2000)],
            "Direct Root binding remains valid while its chased Ops layout conflicts")
        XCTAssertFalse(typed(render(value)), "Every chased layout must match actual imported header evidence")
    }

    func testCancelledAndDistinctSnapshotsDoNotPublishOrReuseProof() throws {
        try positive()
        let cancelled = try make()
        XCTAssertNil(cancelled.snapshot.imageWideIndirectCalls(in: .primary, compute: true, checkpoint: { false }))
        XCTAssertFalse(typed(render(cancelled)), "A cancelled proof attempt cannot be retried implicitly")
        let distinct = try make(exported: ["install"])
        XCTAssertFalse(typed(render(distinct)), "Equal addresses in a different analyzed snapshot are not authority")
    }

    func testImportedPrototypeMutationInvalidatesProof() throws {
        try positive()
        let value = try make()
        XCTAssertTrue(typed(render(value)))
        value.snapshot.importedPrototypes = [:]
        XCTAssertFalse(typed(render(value)), "Removing imported authority must discard the cached proof")
    }

    private func witnessHeaders() throws -> String {
        let directory = TestSourceRoot.url.appendingPathComponent("MacScope/Tests/CoreTests/Fixtures/libjpeg-turbo-3.2.0")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PORTABLE_CLANG"] ?? "/usr/bin/clang")
        process.arguments = ["-E", "-P", "-x", "c", "-DJPEG_INTERNAL_OPTIONS", "-I", directory.path, "-"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("#include \"public-layout.c\"\n#include \"jpegint.h\"\n".utf8))
        try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "S1RecoveryHeaderPreprocess", code: Int(process.terminationStatus)) }
        return String(decoding: result, as: UTF8.self)
    }
}

@MainActor
private final class RecoveryStore {
#if os(Linux)
    var snapshot: WorkspaceSnapshot
    init(snapshot: WorkspaceSnapshot) { self.snapshot = snapshot }
    func defineTypesFromCHeader(_ source: String) {
        let result = HeaderImportCore.prepare(source: source, typeDefinitions: snapshot.typeDefinitions,
            exports: snapshot.analysis(in: .primary)?.exports ?? [], functions: snapshot.analysis(in: .primary)?.functions ?? [],
            importedPrototypes: snapshot.importedPrototypes, slot: .primary)
        snapshot.typeDefinitions = result.types
        snapshot.importedPrototypes = result.prototypes
        snapshot.recordHeaderImportEvidence(result.headerLayoutDefinitions)
    }
#else
    private let store: WorkspaceStore
    var snapshot: WorkspaceSnapshot {
        get { store.snapshot }
        set { store.snapshot = newValue }
    }
    init(snapshot: WorkspaceSnapshot) {
        store = WorkspaceStore(workspaceName: "S1 recovery proofs", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil)
    }
    func defineTypesFromCHeader(_ source: String) { store.defineTypesFromCHeader(source) }
#endif
}

/// Test-only real Mach-O writer. No production parser/decoder result is invented.
enum S1RecoveryMachOFixture {
    struct Section {
        var segmentName: String
        var sectionName: String
        var address: UInt64
        var bytes: Data
        var flags: UInt32 = 0
    }
    struct DataInCode {
        var offset: UInt32
        var length: UInt16
        var kind: UInt16
    }
    static func make(bodies: [UInt64: (String, [UInt32])], exported: Set<String>,
                     extraSections: [Section] = [], dataInCode: [DataInCode] = []) -> Data {
        let textStart: UInt64 = 0x1000
        let textEnd = bodies.map { $0.key + UInt64($0.value.1.count * 4) }.max()!
        let linkOffset = Int((textEnd + 0xfff) & ~UInt64(0xfff))
        var bytes = Data(repeating: 0, count: linkOffset)
        func put(_ value: UInt64, at offset: Int, width: Int = 4) {
            for index in 0..<width { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        func name(_ text: String, at offset: Int) {
            for (index, byte) in text.utf8.prefix(16).enumerated() { bytes[offset + index] = byte }
        }
        put(0xfeedfacf, at: 0); put(0x0100000c, at: 4); put(6, at: 12)
        put(6, at: 16); put(296, at: 20); put(4, at: 24)
        put(0x19, at: 32); put(152, at: 36); name("__TEXT", at: 40)
        put(UInt64(linkOffset), at: 64, width: 8); put(UInt64(linkOffset), at: 80, width: 8)
        put(5, at: 88); put(5, at: 92); put(1, at: 96)
        name("__text", at: 104); name("__TEXT", at: 120)
        put(textStart, at: 136, width: 8); put(textEnd - textStart, at: 144, width: 8)
        put(textStart, at: 152); put(2, at: 156); put(0x80000400, at: 168)
        put(0x19, at: 184); put(72, at: 188); name("__LINKEDIT", at: 192)
        put(UInt64(linkOffset), at: 208, width: 8); put(UInt64(linkOffset), at: 224, width: 8)
        put(1, at: 240); put(1, at: 244)
        for address in stride(from: Int(textStart), to: Int(textEnd), by: 4) { put(0xd503201f, at: address) }
        for (address, body) in bodies {
            for (index, word) in body.1.enumerated() { put(UInt64(word), at: Int(address) + index * 4) }
        }
        let ordered = bodies.sorted { $0.key < $1.key }
        var strings = Data([0]), symbols = Data()
        for (address, body) in ordered {
            append(UInt64(strings.count), width: 4, to: &symbols)
            symbols.append(exported.contains(body.0) ? 0x0f : 0x0e); symbols.append(1)
            append(0, width: 2, to: &symbols); append(address, width: 8, to: &symbols)
            strings.append(Data(("_" + body.0).utf8)); strings.append(0)
        }
        let symOffset = bytes.count; bytes.append(symbols)
        let strOffset = bytes.count; bytes.append(strings)
        var starts = Data(), previous: UInt64 = 0
        for (address, _) in ordered { starts.append(contentsOf: uleb(address - previous)); previous = address }
        starts.append(0)
        let startsOffset = bytes.count; bytes.append(starts)
        let exports = ordered.filter { exported.contains($0.value.0) }.map { ("_" + $0.value.0, $0.key) }
        var offsets = Array(repeating: 0, count: exports.count), root = Data(), leaves = Data()
        for _ in 0..<8 {
            root = Data([0, UInt8(exports.count)])
            for (index, item) in exports.enumerated() {
                root.append(Data(item.0.utf8)); root.append(0); root.append(contentsOf: uleb(UInt64(offsets[index])))
            }
            leaves = Data()
            var updated: [Int] = []
            for item in exports {
                updated.append(root.count + leaves.count)
                let terminal = [UInt8(0)] + uleb(item.1)
                leaves.append(contentsOf: uleb(UInt64(terminal.count))); leaves.append(contentsOf: terminal); leaves.append(0)
            }
            if updated == offsets { break }; offsets = updated
        }
        let exportOffset = bytes.count; bytes.append(root); bytes.append(leaves)
        let exportSize = root.count + leaves.count
        let fixupOffset = bytes.count
        var fixups = Data(repeating: 0, count: 40 + extraSections.count * 4)
        fixups[4] = 28; fixups[20] = 1
        for index in 0..<4 {
            fixups[8 + index] = UInt8(truncatingIfNeeded: UInt32(fixups.count) >> (index * 8))
            fixups[12 + index] = UInt8(truncatingIfNeeded: UInt32(fixups.count) >> (index * 8))
            fixups[28 + index] = UInt8(truncatingIfNeeded: UInt32(2 + extraSections.count) >> (index * 8))
        }
        bytes.append(fixups)
        put(2, at: 256); put(24, at: 260); put(UInt64(symOffset), at: 264)
        put(UInt64(ordered.count), at: 268); put(UInt64(strOffset), at: 272); put(UInt64(strings.count), at: 276)
        for (offset, command, payload, size) in [(280, UInt64(0x26), startsOffset, starts.count),
                                                (296, UInt64(0x80000033), exportOffset, exportSize),
                                                (312, UInt64(0x80000034), fixupOffset, fixups.count)] {
            put(command, at: offset); put(16, at: offset + 4); put(UInt64(payload), at: offset + 8); put(UInt64(size), at: offset + 12)
        }
        var commandOffset = 328
        var commandCount = 6
        if !dataInCode.isEmpty {
            let payloadOffset = bytes.count
            for entry in dataInCode {
                append(UInt64(entry.offset), width: 4, to: &bytes)
                append(UInt64(entry.length), width: 2, to: &bytes)
                append(UInt64(entry.kind), width: 2, to: &bytes)
            }
            put(0x29, at: commandOffset); put(16, at: commandOffset + 4)
            put(UInt64(payloadOffset), at: commandOffset + 8)
            put(UInt64(dataInCode.count * 8), at: commandOffset + 12)
            commandOffset += 16; commandCount += 1
        }
        put(UInt64(bytes.count - linkOffset), at: 216, width: 8)
        put(UInt64(bytes.count - linkOffset), at: 232, width: 8)
        for section in extraSections {
            precondition(commandOffset + 152 <= Int(textStart))
            let payloadOffset = (bytes.count + 0xfff) & ~0xfff
            bytes.append(Data(repeating: 0, count: payloadOffset - bytes.count))
            bytes.append(section.bytes)
            let at = commandOffset
            put(0x19, at: at); put(152, at: at + 4); name(section.segmentName, at: at + 8)
            put(section.address, at: at + 24, width: 8)
            put(UInt64(section.bytes.count), at: at + 32, width: 8)
            put(UInt64(payloadOffset), at: at + 40, width: 8)
            put(UInt64(section.bytes.count), at: at + 48, width: 8)
            put(1, at: at + 56); put(1, at: at + 60); put(1, at: at + 64)
            name(section.sectionName, at: at + 72); name(section.segmentName, at: at + 88)
            put(section.address, at: at + 104, width: 8)
            put(UInt64(section.bytes.count), at: at + 112, width: 8)
            put(UInt64(payloadOffset), at: at + 120); put(2, at: at + 124)
            put(UInt64(section.flags), at: at + 136)
            commandOffset += 152; commandCount += 1
        }
        put(UInt64(commandCount), at: 16); put(UInt64(commandOffset - 32), at: 20)
        return bytes
    }
    private static func append(_ value: UInt64, width: Int, to bytes: inout Data) {
        for index in 0..<width { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
    }
    private static func uleb(_ value: UInt64) -> [UInt8] {
        var value = value, result: [UInt8] = []
        repeat { var byte = UInt8(value & 0x7f); value >>= 7; if value != 0 { byte |= 0x80 }; result.append(byte) } while value != 0
        return result
    }
}
