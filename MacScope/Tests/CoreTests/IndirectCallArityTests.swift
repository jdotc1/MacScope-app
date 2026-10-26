import Foundation
import XCTest
@testable import MacScope

/// Imported callback contracts through real image analysis, header import and warm export.
@MainActor
final class IndirectCallArityTests: XCTestCase {
    private let start: UInt64 = 0x1000

    func testHeaderFixturePreservesCallbackAuthorityAndLP64Offsets() throws {
        let value = try render("layout_fixture", words: [0xd65f03c0])
        let byName = Dictionary(uniqueKeysWithValues: value.types.map { ($0.name, $0) })
        func field(_ owner: String, _ name: String, at offset: Int) throws -> FieldDef {
            let type = try XCTUnwrap(byName[owner])
            let member = try XCTUnwrap(type.memberLayout(in: byName).first { $0.field.name == name })
            XCTAssertEqual(member.offset, offset, "\(owner).\(name)")
            return member.field
        }
        for owner in ["jpeg_common_struct", "jpeg_compress_struct"] {
            _ = try field(owner, "err", at: 0)
            _ = try field(owner, "mem", at: 8)
        }
        _ = try field("jpeg_compress_struct", "fdct", at: 552)
        _ = try field("jpeg_compress_struct", "entropy", at: 560)
        let error = try XCTUnwrap(try field("jpeg_error_mgr", "error_exit", at: 0).functionPointerSignatureV1)
        XCTAssertEqual(error.returnType, "void")
        XCTAssertEqual(error.parameters.count, 1)
        let alloc = try XCTUnwrap(try field("jpeg_memory_mgr", "alloc_small", at: 0).functionPointerSignatureV1)
        XCTAssertEqual(alloc.returnType, "void *")
        XCTAssertEqual(alloc.parameters.count, 3)
        let encode = try XCTUnwrap(try field("jpeg_entropy_encoder", "encode_mcu", at: 8).functionPointerSignatureV1)
        XCTAssertEqual(encode.returnType, "int32_t")
        XCTAssertEqual(encode.parameters.count, 2)
    }

    func testCreateCompressErrorExitHasOneArgumentAndNoResult() throws {
        let value = try render("jpeg_CreateCompress", words: chain(table: 0, slot: 0),
            arguments: ["struct jpeg_compress_struct *cinfo", "int version", "size_t structsize"])
        try assertTypedCall(value, arity: 1, hasResult: false,
            forbiddenArguments: ["version", "structsize"])
    }

    func testLoadedMemoryManagerAllocSmallHasThreeArgumentsAndResult() throws {
        let value = try render("allocate", words: chain(table: 8, slot: 0),
            arguments: ["struct jpeg_compress_struct *cinfo", "int pool_id", "size_t sizeofobject"])
        try assertTypedCall(value, arity: 3, hasResult: true)
        let frame = try indirectFrame(value)
        XCTAssertEqual(frame.arguments.fixedArgument(at: 1)?.location, .gpr(index: 1, carrierWidth: 32))
        XCTAssertEqual(frame.arguments.fixedArgument(at: 2)?.location, .gpr(index: 2, carrierWidth: 64))
        XCTAssertEqual(frame.typedIndirectSignature?.returnType, "void *")
    }

    func testLoadedEntropyEncoderEncodeMCUHasTwoArgumentsAndResult() throws {
        let value = try render("encode", words: chain(table: 560, slot: 8),
            arguments: ["struct jpeg_compress_struct *cinfo", "JBLOCKROW *MCU_data"])
        try assertTypedCall(value, arity: 2, hasResult: true)
        let frame = try indirectFrame(value)
        XCTAssertEqual(frame.arguments.fixedArgument(at: 1)?.location, .gpr(index: 1, carrierWidth: 64))
        XCTAssertEqual(frame.typedIndirectSignature?.returnType, "int32_t")
    }

    func testConflictingSameNamedLayoutsDoNotAuthorizeCallback() throws {
        let original = "struct Collision { void (*error_exit)(void *); };"
        let shifted = "struct Collision { long non_callback; void (*error_exit)(void *); };"
        let originalTypes = CTypeHeaderParser.parse(original).types
        let shiftedTypes = CTypeHeaderParser.parse(shifted).types
        // Model both catalog orders after real import; the parser itself drops
        // duplicate declarations, so repeating a C definition cannot test this conflict.
        for types in [originalTypes + shiftedTypes, shiftedTypes + originalTypes] {
            let value = try render("conflicting_layouts", words:
                [0xaa0003f3, 0xf9400268, 0xaa1303e0, 0xd63f0100, 0xd65f03c0],
                arguments: ["struct Collision *cinfo"], header: original, conflictingTypes: types)
            try assertUnresolvedCall(value)
        }
    }

    func testUnknownBaseDoesNotAuthorizeCallback() throws {
        try assertUnresolvedCall(render("unknown_base", words: chain(table: 0, slot: 0),
            arguments: ["void *cinfo"]))
    }

    func testCallOverwrittenBaseDoesNotReuseIncomingPointerType() throws {
        // x19 preserves cinfo, but the table load uses the opaque call's x0 return.
        let value = try render("overwritten_base", words: [
            0xaa0003f3, 0x940003ff, // BL from 0x1004 to helper at 0x2000.
            0xf9400009, 0xf9400128, 0xaa1303e0, 0xd63f0100, 0xd65f03c0
        ], helper: true)
        try assertUnresolvedCall(value, excluding: "_replace_object")
    }

    func testOffsetInsideNonCallbackFieldDoesNotAuthorizeCallback() throws {
        // jpeg_error_mgr.msg_parm starts at 44; +48 lies inside its int array.
        try assertUnresolvedCall(render("non_callback", words: chain(table: 0, slot: 48)))
    }

    func testForwardDCTPrivateConvsampRemainsUntypedWithoutHeaderAuthority() throws {
        try assertPrivateConvsamp(name: "forward_DCT", slot: 32)
    }

    func testForwardDCTFloatPrivateConvsampRemainsUntypedWithoutHeaderAuthority() throws {
        try assertPrivateConvsamp(name: "forward_DCT_float", slot: 96)
    }

    func test3AD1CLiveTypedX1AndUnresolvedTransferRemainUntyped() throws {
        // Reduced 0x3ad1c shape: a backwards layout, live typed x1 at error_exit,
        // and an unresolved tail BR. The later transfer proof is outside this slice.
        let words: [UInt32] = [
            0xaa0003f3, 0x14000005, // Entry root copy, jump to backwards-layout edge.
            0xf9400269, 0xf9400128, 0xaa1303e0, 0xd63f0100,
            0xb4ffff81,             // CBZ x1 back to fresh table/target loads.
            0xd61f0020              // BR x1 must prevent whole-function typing.
        ]
        let value = try render("regression_3ad1c", words: words,
            arguments: ["struct jpeg_compress_struct *cinfo", "struct jpeg_compress_struct *live_context"])
        try assertUnresolvedCall(value)
        XCTAssertTrue(value.report.callContracts.isEmpty)
        XCTAssertTrue(value.report.callProofRows.isEmpty)
        XCTAssertTrue(value.report.refusals.contains { $0.reason == "unsupported_nonforward_or_incomplete_cfg" })
        let frame = try indirectFrame(value)
        let hasX1 = frame.arguments.canonicalPhysicalEntriesForAudit.contains {
            $0.location == .gpr(index: 1, carrierWidth: 64)
        }
        if value.function.ssaEnabled {
            XCTAssertFalse(hasX1, "A call-clobbered loop phi is not argument evidence")
        } else {
            XCTAssertTrue(hasX1, "The refusal fixture must retain the live typed x1 argument")
        }
        // Target authority does not restore a call-clobbered argument value.
        XCTAssertNil(frame.typedIndirectSignature)
    }

    func testFinalLocalCallExitKeepsErrorExitAtOneArgumentWithoutResult() throws {
        let value = try FinalCallCarrierFixture.render(declaration: Self.header +
            "\nvoid dispatch(struct jpeg_compress_struct *cinfo, int flag, void *unrelated);")
        try value.assertTyped(arity: 1)
        XCTAssertEqual(value.report.callContracts[0x1010]?.parameters.count, 1)
    }

    func testFinalLocalCallFallthroughKeepsErrorExitAtOneArgumentWithoutResult() throws {
        var words = FinalCallCarrierFixture.words
        words[7] = 0xd503201f
        let value = try FinalCallCarrierFixture.render(words: words, declaration: Self.header +
            "\nvoid dispatch(struct jpeg_compress_struct *cinfo, int flag, void *unrelated);")
        try value.assertTyped(arity: 1)
    }

    private func assertPrivateConvsamp(name: String, slot: Int,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        // Public jpeg_forward_dct ends at +24; private convsamp has no imported authority.
        let value = try render(name, words: [
            0xaa0003f3, load(9, base: 19, offset: 552), load(25, base: 9, offset: slot),
            0xaa0203e0, 0xaa0503e1, 0xaa0303e2, 0xd63f0320, 0xd65f03c0
        ])
        try assertUnresolvedCall(value, file: file, line: line)
    }

    private func load(_ destination: UInt32, base: UInt32, offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset % 8 == 0 && offset / 8 < 4096)
        return 0xf9400000 | (UInt32(offset / 8) << 10) | (base << 5) | destination
    }

    private func chain(table: Int, slot: Int) -> [UInt32] {
        [0xaa0003f3, load(9, base: 19, offset: table), load(8, base: 9, offset: slot),
         0xaa1303e0, 0xd63f0100, 0xd65f03c0]
    }

    private struct Rendered {
        let text: String
        let generic: MacIRFunction
        let function: MacIRFunction
        let report: SlotTypedPrototypeBinding.Report
        let types: [TypeDefinition]
    }

    private func render(_ name: String, words: [UInt32],
                        arguments: [String] = ["struct jpeg_compress_struct *cinfo"],
                        header: String? = nil, conflictingTypes: [TypeDefinition]? = nil,
                        helper: Bool = false) throws -> Rendered {
        var bodies: [UInt64: (String, [UInt32])] = [start: (name, words)]
        if helper { bodies[0x2000] = ("replace_object", [0xd65f03c0]) }
        let image = S1RecoveryMachOFixture.make(bodies: bodies, exported: [name])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("indirect-arity-\(UUID().uuidString).dylib")
        try image.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var snapshot = try AnalysisEngine().analyze(url: url)
        let analysis = try XCTUnwrap(snapshot.analysis(in: .primary))
        XCTAssertEqual(analysis.imageBytes, image)
        XCTAssertTrue(analysis.functions.contains { $0.startAddress == start })
        let expectedBytes = words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } }
        let decoded = ARM64Decoder().decode(Data(expectedBytes), baseAddress: start, maxInstructionCount: words.count)
        XCTAssertEqual(decoded.count, words.count)
        for instruction in decoded {
            let row = try XCTUnwrap(analysis.instructions.first { $0.address == instruction.address })
            XCTAssertEqual(row.bytes, instruction.byteText)
            XCTAssertEqual(row.mnemonic, instruction.mnemonic)
            XCTAssertEqual(row.operands, instruction.operands)
        }
        let parameters = arguments + (arguments.count..<7).map { "unsigned long unrelated\($0)" }
        let declaration = (header ?? Self.header) + "\nvoid \(name)(\(parameters.joined(separator: ", ")));"
#if os(Linux)
        let imported = HeaderImportCore.prepare(source: declaration, typeDefinitions: snapshot.typeDefinitions,
            exports: analysis.exports, functions: analysis.functions, importedPrototypes: snapshot.importedPrototypes, slot: .primary)
        snapshot.typeDefinitions = imported.types
        snapshot.importedPrototypes = imported.prototypes
        snapshot.recordHeaderImportEvidence(imported.headerLayoutDefinitions)
#else
        let store = WorkspaceStore(workspaceName: "Indirect call arity proofs", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil)
        store.defineTypesFromCHeader(declaration)
        snapshot = store.snapshot
#endif
        XCTAssertNotNil(snapshot.importedPrototypes[.primary(start)])
        XCTAssertTrue(snapshot.addressOverrides.isEmpty)
        if let conflictingTypes { snapshot.typeDefinitions = conflictingTypes }
        _ = snapshot.imageWideIndirectCalls(in: .primary, compute: true)
        let report = try XCTUnwrap(snapshot.slotTypedPrototypeReport(in: .primary, compute: false))
        let input = snapshot.pseudocodeRenderInput(selectedAddress: start, in: .primary)
        let function = PseudocodePrinter().buildFunction(functionName: input.functionName,
            startAddress: input.startAddress, jumpTables: input.jumpTables,
            signatureOverrides: input.signatureOverrides, slotCallContracts: input.slotCallContracts,
            types: input.types, instructions: input.instructions)
        let generic = PseudocodePrinter().buildFunction(functionName: input.functionName,
            startAddress: input.startAddress, jumpTables: input.jumpTables,
            signatureOverrides: input.signatureOverrides, types: input.types, instructions: input.instructions)
        return Rendered(text: DocumentExportService().pseudocodeText(for: input, options: .default),
            generic: generic, function: function, report: report, types: input.types)
    }

    private func indirectFrame(_ value: Rendered,
                               file: StaticString = #filePath, line: UInt = #line) throws -> MacIRCallFrame {
        let calls = value.function.instructions.filter { $0.source.mnemonic == "blr" }
        XCTAssertEqual(calls.count, 1, file: file, line: line)
        let call = try XCTUnwrap(calls.first, file: file, line: line)
        guard case let .call(frame, _) = call.operation else {
            XCTFail("Expected actual indirect call operation", file: file, line: line)
            throw NSError(domain: "IndirectCallArityTests", code: 1)
        }
        return frame
    }

    private struct Call {
        let callee: String
        let arguments: [String]
        let hasResult: Bool
        let identity: String
        let line: String
    }

    /// Parse balanced argument lists, retaining nested casts and commas in them.
    /// No whole-line equality, fixed temporary names, or required call comments.
    private func calls(in text: String) -> [Call] {
        text.components(separatedBy: .newlines).compactMap { line in
            guard let semicolon = line.firstIndex(of: ";") else { return nil }
            var statement = String(line[..<semicolon]).trimmingCharacters(in: .whitespaces)
            if let annotation = statement.range(of: " /* unproven args: "), statement.hasSuffix(" */") {
                statement = String(statement[..<annotation.lowerBound])
            }
            guard statement.last == ")" else { return nil }
            let characters = Array(statement)
            var depth = 0
            var open: Int?
            for index in characters.indices.reversed() {
                if characters[index] == ")" { depth += 1 }
                if characters[index] == "(" {
                    depth -= 1
                    if depth == 0 { open = index; break }
                }
            }
            guard let open else { return nil }
            let prefix = String(characters[..<open])
            let assignment = prefix.firstIndex(of: "=")
            let callee = (assignment.map { String(prefix[prefix.index(after: $0)...]) } ?? prefix)
                .trimmingCharacters(in: .whitespaces)
            guard (callee.hasPrefix("(") && callee.contains("*") && callee.hasSuffix(")"))
                    || callee.contains("->") || callee.contains(".") || callee.hasPrefix("_replace_object")
            else { return nil }
            let body = characters[(open + 1)..<(characters.count - 1)]
            var arguments: [String] = []
            var current = ""
            depth = 0
            for character in body {
                if character == "," && depth == 0 {
                    arguments.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(character)
                    if "([{".contains(character) { depth += 1 }
                    if ")]}".contains(character) { depth -= 1 }
                }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                arguments.append(current.trimmingCharacters(in: .whitespaces))
            }
            return Call(callee: callee, arguments: arguments, hasResult: assignment != nil,
                        identity: callee + String(line[semicolon...]), line: line)
        }
    }

    private func assertTypedCall(_ value: Rendered, arity: Int, hasResult: Bool,
                                 forbiddenArguments: [String] = [],
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let text = value.text
        let found = calls(in: text)
        XCTAssertEqual(found.count, 1, text, file: file, line: line)
        let rendered = try XCTUnwrap(found.first, text, file: file, line: line)
        XCTAssertEqual(rendered.arguments.count, arity, rendered.line, file: file, line: line)
        XCTAssertEqual(rendered.hasResult, hasResult, rendered.line, file: file, line: line)
        XCTAssertFalse(rendered.arguments.contains { $0.contains("unrelated") }, rendered.line, file: file, line: line)
        for forbidden in forbiddenArguments {
            XCTAssertFalse(rendered.arguments.contains { $0.contains(forbidden) }, rendered.line, file: file, line: line)
        }
        let proof = try XCTUnwrap(value.report.callProofRows.first, file: file, line: line)
        XCTAssertEqual(value.report.callProofRows.count, 1, file: file, line: line)
        XCTAssertEqual(proof.functionStart, start, file: file, line: line)
        XCTAssertEqual(proof.rootFunctionStart, start, file: file, line: line)
        XCTAssertEqual(proof.rootParameterIndex, 0, file: file, line: line)
        XCTAssertEqual(proof.rootRegister, "x0", file: file, line: line)
        XCTAssertEqual(proof.rootCopyAddresses, [start], file: file, line: line)
        XCTAssertEqual(proof.pointerChase.count, 2, file: file, line: line)
        XCTAssertTrue(proof.physicalProof.contains("captured target retained"), file: file, line: line)
        XCTAssertFalse(proof.canonicalContract.isEmpty, file: file, line: line)
        let contract = try XCTUnwrap(value.report.callContracts[proof.callAddress], file: file, line: line)
        XCTAssertEqual(contract.parameters.count, arity, file: file, line: line)
        XCTAssertEqual(contract.returnType == "void", !hasResult, file: file, line: line)
        let load = try XCTUnwrap(value.function.instructions.first { $0.source.address == proof.loadAddress }, file: file, line: line)
        let call = try XCTUnwrap(value.function.instructions.first { $0.source.address == proof.callAddress }, file: file, line: line)
        guard case let .load(capture, _) = load.operation,
              case let .call(frame, result) = call.operation else {
            return XCTFail("Expected captured load and typed call operations", file: file, line: line)
        }
        XCTAssertEqual(frame.controlInputs.indirectTarget?.value, capture, file: file, line: line)
        XCTAssertEqual(frame.arguments.canonicalPhysicalEntriesForAudit.count, arity, file: file, line: line)
        XCTAssertEqual(frame.typedIndirectSignature?.parameters.count, arity, file: file, line: line)
        XCTAssertEqual(result != nil, hasResult, file: file, line: line)
        XCTAssertEqual(frame.arguments.fixedArgument(at: 0)?.location, .gpr(index: 0, carrierWidth: 64), file: file, line: line)
        // The final cast must call a captured scalar, not re-evaluate a field path.
        XCTAssertTrue(rendered.callee.filter { !$0.isWhitespace }.contains("(*)("), rendered.line, file: file, line: line)
        XCTAssertFalse(rendered.callee.contains("->"), rendered.line, file: file, line: line)
        XCTAssertEqual(value.function.instructions.filter { $0.source.address < proof.callAddress },
                       value.generic.instructions.filter { $0.source.address < proof.callAddress },
                       "Contract application must preserve all pre-call generic operations", file: file, line: line)
    }

    private func assertUnresolvedCall(_ value: Rendered, excluding: String? = nil,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let found = calls(in: value.text).filter { $0.callee != excluding }
        XCTAssertEqual(found.count, 1, value.text, file: file, line: line)
        let call = try XCTUnwrap(found.first, value.text, file: file, line: line)
        XCTAssertTrue(call.callee.hasPrefix("(*"), "Call must remain unresolved: \(call.line)", file: file, line: line)
        XCTAssertTrue(value.report.callContracts.isEmpty, file: file, line: line)
        XCTAssertTrue(value.report.callProofRows.isEmpty, file: file, line: line)
        let frame = try indirectFrame(value, file: file, line: line)
        XCTAssertNil(frame.typedIndirectSignature, file: file, line: line)
        XCTAssertEqual(call.arguments.count, frame.unknownRenderValues().count,
                       "Only the proven positional prefix belongs in the call", file: file, line: line)
        let unproven = frame.unprovenArgumentRegisters
        if unproven.isEmpty {
            XCTAssertFalse(call.line.contains("unproven args:"), call.line, file: file, line: line)
        } else {
            XCTAssertTrue(call.line.contains(" /* unproven args: \(unproven.joined(separator: ", ")) */;"),
                          call.line, file: file, line: line)
        }
        XCTAssertEqual(value.function.instructions, value.generic.instructions,
                       "Refusal must preserve the generic argument/result footprint", file: file, line: line)
        for field in ["error_exit", "alloc_small", "encode_mcu", "convsamp", "forward_DCT", "start_pass"] {
            XCTAssertFalse(call.identity.contains(field), "Fabricated callback identity: \(call.line)", file: file, line: line)
        }
    }

    // Minimal complete prefixes through the fields used above. LP64 offsets are
    // independently pinned in the fixture test against the supplied header-layout CSV
    // (arm64-apple-macos11, JPEG_LIB_VERSION=80). Unused pointees stay opaque.
    private static let header = """
    typedef int boolean;
    typedef unsigned int JDIMENSION;
    typedef unsigned long size_t;
    typedef unsigned char UINT8;
    typedef unsigned short UINT16;
    typedef int J_COLOR_SPACE;
    typedef int J_DCT_METHOD;
    typedef short JBLOCK[64];
    typedef JBLOCK *JBLOCKROW;
    typedef struct jpeg_common_struct *j_common_ptr;
    typedef struct jpeg_compress_struct *j_compress_ptr;
    union jpeg_message_parameters { int i[8]; char s[80]; };
    struct jpeg_error_mgr {
        void (*error_exit)(j_common_ptr cinfo);
        void (*emit_message)(j_common_ptr cinfo, int msg_level);
        void (*output_message)(j_common_ptr cinfo);
        void (*format_message)(j_common_ptr cinfo, char *buffer);
        void (*reset_error_mgr)(j_common_ptr cinfo);
        int msg_code;
        union jpeg_message_parameters msg_parm;
    };
    struct jpeg_memory_mgr {
        void *(*alloc_small)(j_common_ptr cinfo, int pool_id, size_t sizeofobject);
    };
    struct jpeg_entropy_encoder {
        void (*start_pass)(j_compress_ptr cinfo, boolean gather_statistics);
        boolean (*encode_mcu)(j_compress_ptr cinfo, JBLOCKROW *MCU_data);
    };
    struct jpeg_forward_dct {
        void (*start_pass)(j_compress_ptr cinfo);
        void (*forward_DCT)(j_compress_ptr cinfo, struct jpeg_component_info *compptr,
            unsigned char **sample_data, JBLOCKROW coef_blocks, JDIMENSION start_row,
            JDIMENSION start_col, JDIMENSION num_blocks);
        void (*forward_DCT_12)(j_compress_ptr cinfo, struct jpeg_component_info *compptr,
            short **sample_data, JBLOCKROW coef_blocks, JDIMENSION start_row,
            JDIMENSION start_col, JDIMENSION num_blocks);
    };
    struct jpeg_common_struct {
        struct jpeg_error_mgr *err;
        struct jpeg_memory_mgr *mem;
        struct jpeg_progress_mgr *progress;
        void *client_data;
        boolean is_decompressor;
        int global_state;
    };
    struct jpeg_compress_struct {
        struct jpeg_error_mgr *err;
        struct jpeg_memory_mgr *mem;
        struct jpeg_progress_mgr *progress;
        void *client_data;
        boolean is_decompressor;
        int global_state;
        struct jpeg_destination_mgr *dest;
        JDIMENSION image_width;
        JDIMENSION image_height;
        int input_components;
        J_COLOR_SPACE in_color_space;
        double input_gamma;
        unsigned int scale_num;
        unsigned int scale_denom;
        JDIMENSION jpeg_width;
        JDIMENSION jpeg_height;
        int data_precision;
        int num_components;
        J_COLOR_SPACE jpeg_color_space;
        struct jpeg_component_info *comp_info;
        struct JQUANT_TBL *quant_tbl_ptrs[4];
        int q_scale_factor[4];
        struct JHUFF_TBL *dc_huff_tbl_ptrs[4];
        struct JHUFF_TBL *ac_huff_tbl_ptrs[4];
        UINT8 arith_dc_L[16];
        UINT8 arith_dc_U[16];
        UINT8 arith_ac_K[16];
        int num_scans;
        const struct jpeg_scan_info *scan_info;
        boolean raw_data_in;
        boolean arith_code;
        boolean optimize_coding;
        boolean CCIR601_sampling;
        boolean do_fancy_downsampling;
        int smoothing_factor;
        J_DCT_METHOD dct_method;
        unsigned int restart_interval;
        int restart_in_rows;
        boolean write_JFIF_header;
        UINT8 JFIF_major_version;
        UINT8 JFIF_minor_version;
        UINT8 density_unit;
        UINT16 X_density;
        UINT16 Y_density;
        boolean write_Adobe_marker;
        JDIMENSION next_scanline;
        boolean progressive_mode;
        int max_h_samp_factor;
        int max_v_samp_factor;
        int min_DCT_h_scaled_size;
        int min_DCT_v_scaled_size;
        JDIMENSION total_iMCU_rows;
        int comps_in_scan;
        struct jpeg_component_info *cur_comp_info[4];
        JDIMENSION MCUs_per_row;
        JDIMENSION MCU_rows_in_scan;
        int blocks_in_MCU;
        int MCU_membership[10];
        int Ss;
        int Se;
        int Ah;
        int Al;
        int block_size;
        const int *natural_order;
        int lim_Se;
        struct jpeg_comp_master *master;
        struct jpeg_c_main_controller *main;
        struct jpeg_c_prep_controller *prep;
        struct jpeg_c_coef_controller *coef;
        struct jpeg_marker_writer *marker;
        struct jpeg_color_converter *cconvert;
        struct jpeg_downsampler *downsample;
        struct jpeg_forward_dct *fdct;
        struct jpeg_entropy_encoder *entropy;
    };
    """
}
