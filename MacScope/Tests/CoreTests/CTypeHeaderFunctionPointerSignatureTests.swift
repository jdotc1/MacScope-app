import Foundation
import XCTest
@testable import MacScope

final class CTypeHeaderFunctionPointerSignatureTests: XCTestCase {
    private typealias Signature = FunctionPointerSignatureV1

    func testFieldsPreserveSignaturesAndLiteralLayout() throws {
        let result = CTypeHeaderParser.parse("""
        struct S { int n; };
        typedef struct S *j_decompress_ptr;
        struct Callbacks {
            char lead;
            void (*on_event)(int, long);
            void (*start_pass)(j_decompress_ptr cinfo);
            int (*empty)(void);
            int (*unknown)();
            void (*log)(const char *format, ...);
            int (*ops[3])(int value);
            char *(*make)(void);
            void (*nested)(void (*callback)(int code, long value), int flag);
        };
        void reference(j_decompress_ptr cinfo);
        """)
        let catalog = Dictionary(uniqueKeysWithValues: result.types.map { ($0.name, $0) })
        let type = try XCTUnwrap(catalog["Callbacks"])
        let fields = Dictionary(uniqueKeysWithValues: type.fields.map { ($0.name, $0) })
        XCTAssertEqual(fields["on_event"]?.functionPointerSignatureV1,
            Signature(returnType: "void", parameters: [.init(type: "int32_t"), .init(type: "int64_t")]))
        let named = try XCTUnwrap(fields["start_pass"]?.functionPointerSignatureV1)
        XCTAssertEqual(named.parameters, [.init(name: "cinfo", type: "struct S *")])
        XCTAssertEqual(named.parameters.first?.type, result.prototypes.first?.signature.args.first?.type)
        XCTAssertEqual(fields["empty"]?.functionPointerSignatureV1,
            Signature(returnType: "int32_t", parameters: []))
        XCTAssertEqual(fields["unknown"]?.functionPointerSignatureV1,
            Signature(returnType: "int32_t", parameters: [], hasUnspecifiedParameters: true))
        XCTAssertEqual(fields["log"]?.functionPointerSignatureV1,
            Signature(returnType: "void", parameters: [.init(name: "format", type: "const char *")], isVariadic: true))
        XCTAssertEqual(fields["ops"]?.functionPointerSignatureV1,
            Signature(returnType: "int32_t", parameters: [.init(name: "value", type: "int32_t")]))
        XCTAssertEqual(fields["ops"]?.type, "int32_t *[3]")
        XCTAssertEqual(fields["ops"]?.declaratorSemanticsV1, .arrayOfFunctionPointerCarrier)
        XCTAssertEqual(fields["make"]?.functionPointerSignatureV1?.returnType, "char *")
        let nested = try XCTUnwrap(fields["nested"]?.functionPointerSignatureV1)
        XCTAssertEqual(nested.parameters.map(\.name), ["callback", "flag"])
        XCTAssertEqual(nested.parameters.first?.functionPointerSignatureV1,
            Signature(returnType: "void", parameters: [.init(name: "code", type: "int32_t"), .init(name: "value", type: "int64_t")]))
        XCTAssertEqual(type.memberLayout(in: catalog).map(\.offset), [0, 8, 16, 24, 32, 40, 48, 72, 80])
        XCTAssertEqual(TypeDefinition.size(ofType: "Callbacks", in: catalog), 88)
        XCTAssertEqual(TypeDefinition.alignment(ofType: "Callbacks", in: catalog), 8)
    }

    func testCallbackTypedefFieldAndPrototypeAdmission() throws {
        let result = CTypeHeaderParser.parse("""
        typedef int boolean;
        typedef struct jpeg_decompress_struct *j_decompress_ptr;
        typedef boolean (*jpeg_marker_parser_method)(j_decompress_ptr cinfo);
        typedef jpeg_marker_parser_method MarkerAlias;
        struct Reader { char lead; jpeg_marker_parser_method process_COM; MarkerAlias other; };
        void jpeg_set_marker_processor(j_decompress_ptr cinfo, int marker_code, jpeg_marker_parser_method routine);
        """)
        let catalog = Dictionary(uniqueKeysWithValues: result.types.map { ($0.name, $0) })
        let expected = Signature(returnType: "int32_t", parameters: [.init(name: "cinfo", type: "struct jpeg_decompress_struct *")])
        XCTAssertEqual(catalog["jpeg_marker_parser_method"]?.fields.first?.functionPointerSignatureV1, expected)
        let reader = try XCTUnwrap(catalog["Reader"])
        XCTAssertEqual(reader.fields[1].functionPointerSignatureV1, expected)
        XCTAssertEqual(reader.fields[2].functionPointerSignatureV1, expected)
        XCTAssertEqual(result.prototypes.map(\.name), ["jpeg_set_marker_processor"])
        XCTAssertEqual(result.prototypes.first?.signature.args.last?.type, "jpeg_marker_parser_method")
        XCTAssertEqual(result.skippedPrototypeCount, 0)
        XCTAssertEqual(TypeDefinition.size(ofType: "jpeg_marker_parser_method", in: catalog), 8)
        XCTAssertEqual(TypeDefinition.alignment(ofType: "jpeg_marker_parser_method", in: catalog), 8)
        XCTAssertEqual(reader.memberLayout(in: catalog).map(\.offset), [0, 8, 16])
        XCTAssertEqual(TypeDefinition.size(ofType: "Reader", in: catalog), 24)
    }

    func testCallbackParametersKeepNominalAliasTypes() throws {
        let result = CTypeHeaderParser.parse("""
        typedef int (*Leaf)(long value);
        typedef void (*Pair)(Leaf first, Leaf second);
        typedef int (*Visitor)(Pair left, Pair right);
        struct S { Visitor visit; };
        void install(Visitor visitor);
        """)
        let catalog = Dictionary(uniqueKeysWithValues: result.types.map { ($0.name, $0) })
        XCTAssertEqual(catalog["Pair"]?.fields.first?.functionPointerSignatureV1,
            Signature(returnType: "void", parameters: [.init(name: "first", type: "Leaf"), .init(name: "second", type: "Leaf")]))
        XCTAssertEqual(catalog["S"]?.fields.first?.functionPointerSignatureV1,
            Signature(returnType: "int32_t", parameters: [.init(name: "left", type: "Pair"), .init(name: "right", type: "Pair")]))
        XCTAssertEqual(result.prototypes.first?.signature.args.first?.type, "Visitor")
        XCTAssertEqual(result.skippedPrototypeCount, 0)
        XCTAssertEqual(TypeDefinition.size(ofType: "S", in: catalog), 8)
    }

    func testUnsupportedParameterKeepsCarrierWithoutGuessing() throws {
        let result = CTypeHeaderParser.parse("struct S { char lead; void (*bad)(Unknown x); void (*knr)(x, y); int tail; };")
        let type = try XCTUnwrap(result.types.first)
        XCTAssertNil(type.fields[1].functionPointerSignatureV1)
        XCTAssertNil(type.fields[2].functionPointerSignatureV1)
        XCTAssertEqual(type.fields[1].type, "void *")
        XCTAssertEqual(type.fields[1].declaratorSemanticsV1, .functionPointerCarrier)
        XCTAssertEqual(type.memberLayout().map(\.offset), [0, 8, 16, 24])
        XCTAssertEqual(TypeDefinition.size(ofType: "S", in: ["S": type]), 32)
    }

    func testOptionalSignatureCodableAndDatabaseRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacy = #"{"declaratorSemanticsV1":"functionPointerCarrier","name":"callback","type":"void *"}"#
        let field = FieldDef(name: "callback", type: "void *", declaratorSemanticsV1: .functionPointerCarrier)
        XCTAssertEqual(String(decoding: try encoder.encode(field), as: UTF8.self), legacy)
        XCTAssertEqual(try JSONDecoder().decode(FieldDef.self, from: Data(legacy.utf8)), field)
        var signed = field
        signed.functionPointerSignatureV1 = Signature(returnType: "void", parameters: [.init(name: "n", type: "int32_t")])
        XCTAssertEqual(try JSONDecoder().decode(FieldDef.self, from: encoder.encode(signed)), signed)
        let persisted = try WorkspaceTypeDefinitionDatabaseCodec.encodeFields([signed, field])
        XCTAssertEqual(try WorkspaceTypeDefinitionDatabaseCodec.decodeFields(persisted), [signed, field])
    }

    func testPinnedLibjpegInternalConfigurationLayoutAndSignatures() throws {
        let result = CTypeHeaderParser.parse(try H2SignatureHeaders.preprocessed())
        let catalog = Dictionary(uniqueKeysWithValues: result.types.map { ($0.name, $0) })
        // LP64 enabled configuration from libjpeg-turbo 3.2.0 jpegint.h;
        // WITH_PROFILE is off. Offsets match the retained enabled-layout model.
        let expected: [(String, String, Int, Int)] = [
            ("jpeg_downsampler", "downsample_16", 24, 5),
            ("jpeg_downsampler", "h2v1_downsample_simd", 32, 6),
            ("jpeg_downsampler", "h2v2_downsample_simd", 40, 6),
            ("jpeg_c_main_controller", "process_data_16", 24, 4),
            ("jpeg_error_mgr", "error_exit", 0, 1),
            ("jpeg_memory_mgr", "alloc_small", 0, 3),
        ]
        for (owner, name, offset, arity) in expected {
            let type = try XCTUnwrap(catalog[owner])
            let index = try XCTUnwrap(type.fields.firstIndex { $0.name == name })
            let signature = try XCTUnwrap(type.fields[index].functionPointerSignatureV1)
            XCTAssertEqual(type.memberLayout(in: catalog)[index].offset, offset, "\(owner).\(name)")
            XCTAssertEqual(signature.parameters.count, arity, "\(owner).\(name)")
            XCTAssertFalse(signature.isVariadic, "\(owner).\(name)")
            XCTAssertFalse(signature.hasUnspecifiedParameters, "\(owner).\(name)")
        }
        XCTAssertEqual(TypeDefinition.size(ofType: "jpeg_downsampler", in: catalog), 56)
        XCTAssertEqual(TypeDefinition.size(ofType: "jpeg_c_main_controller", in: catalog), 32)
        let downsample = try XCTUnwrap(catalog["jpeg_downsampler"]?.fields.first { $0.name == "downsample_16" })
        XCTAssertEqual(downsample.functionPointerSignatureV1, Signature(returnType: "void", parameters: [
            .init(name: "cinfo", type: "struct jpeg_compress_struct *"),
            .init(name: "input_buf", type: "uint16_t * * *"),
            .init(name: "in_row_index", type: "uint32_t"),
            .init(name: "output_buf", type: "uint16_t * * *"),
            .init(name: "out_row_group_index", type: "uint32_t"),
        ]))
    }

    func testPinnedLibjpegHeaderSignaturesAndAdmission() throws {
        let result = CTypeHeaderParser.parse(try H2SignatureHeaders.preprocessed())
        let types = Dictionary(uniqueKeysWithValues: result.types.map { ($0.name, $0) })
        let unary = Signature(returnType: "void", parameters: [.init(name: "cinfo", type: "struct jpeg_decompress_struct *")])
        for (owner, field) in [("jpeg_decomp_master", "prepare_for_output_pass"),
                               ("jpeg_decomp_master", "finish_output_pass"),
                               ("jpeg_entropy_decoder", "start_pass")] {
            XCTAssertEqual(types[owner]?.fields.first { $0.name == field }?.functionPointerSignatureV1, unary, "\(owner).\(field)")
        }
        XCTAssertEqual(types["jpeg_d_main_controller"]?.fields.first { $0.name == "start_pass" }?.functionPointerSignatureV1,
            Signature(returnType: "void", parameters: unary.parameters + [.init(name: "pass_mode", type: "J_BUF_MODE")]))
        XCTAssertEqual(types["jpeg_marker_reader"]?.fields.first { $0.name == "read_markers" }?.functionPointerSignatureV1,
            Signature(returnType: "int32_t", parameters: unary.parameters))
        let fields = result.types.filter { $0.kind == .struct || $0.kind == .union }.flatMap(\.fields).filter {
            $0.declaratorSemanticsV1 == .functionPointerCarrier || $0.declaratorSemanticsV1 == .arrayOfFunctionPointerCarrier
        }
        let withSignature = fields.filter { $0.functionPointerSignatureV1 != nil }.count
        print("H2 header function-pointer fields: \(withSignature) with / \(fields.count - withSignature) without signature")
        print("H2 header prototypes: \(result.skippedPrototypeCount) skipped / \(result.prototypes.count) admitted")
        result.diagnostics.filter { $0.hasPrefix("Skipped function prototype") }.forEach { print("H2 remaining: \($0)") }
        // H3: jcopy_block_row now imports through the nominal JBLOCK array typedef.
        XCTAssertEqual(result.skippedPrototypeCount, 0)
        // H3: admitting jcopy_block_row adds one prototype.
        XCTAssertEqual(result.prototypes.count, 138)
    }
}

enum H2SignatureHeaders {
    static func preprocessed() throws -> String {
        let fixture = TestSourceRoot.url.appendingPathComponent("MacScope/Tests/CoreTests/Fixtures/libjpeg-turbo-3.2.0")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        process.arguments = ["-E", "-P", "-x", "c", "-DJPEG_INTERNAL_OPTIONS", "-I", fixture.path, "-"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("#include \"public-layout.c\"\n#include \"jpegint.h\"\n".utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "H2SignatureHeaders", code: Int(process.terminationStatus))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class CTypeHeaderSignatureWorkspaceStoreTests: XCTestCase {
    func testWitnessHeadersReachMacIRWorkspaceTypeStore() throws {
        let store = WorkspaceStore(workspaceName: "H2 signatures", snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [.primary: ImageAnalysis()]),
            engine: AnalysisEngine(), autosaveScheduler: nil)
        store.defineTypesFromCHeader(try H2SignatureHeaders.preprocessed())
        // Production store: WorkspaceStore.snapshot.typeDefinitions (WorkspaceSnapshot).
        // WorkspaceSnapshot.pseudocodeRenderInput(selectedAddress:in:) forwards this catalog
        // as input.types to DocumentExportService.pseudocodeText. The renderer builds
        // PseudocodeNameContext.typesByName; structField(forBase:offset:) returns the full
        // FieldDef via memberLayout(in:), including functionPointerSignatureV1.
        // RULING-1: jpeg_decomp_master has no start_pass; use prepare_for_output_pass.
        let input = store.snapshot.pseudocodeRenderInput(selectedAddress: nil, in: .primary)
        func storedField(_ owner: String, _ name: String) throws -> FieldDef {
            let type = try XCTUnwrap(store.snapshot.typeDefinitions.first { $0.name == owner })
            let field = try XCTUnwrap(type.fields.first { $0.name == name })
            let renderType = try XCTUnwrap(input.types.first { $0.name == owner })
            XCTAssertEqual(renderType, type, "MacIR render catalog must retain \(owner)")
            return field
        }
        let parameters: [FunctionPointerSignatureV1.Parameter] = [.init(name: "cinfo", type: "struct jpeg_decompress_struct *")]
        for (owner, name) in [("jpeg_decomp_master", "prepare_for_output_pass"),
                              ("jpeg_decomp_master", "finish_output_pass"),
                              ("jpeg_entropy_decoder", "start_pass")] {
            XCTAssertEqual(try storedField(owner, name).functionPointerSignatureV1,
                .init(returnType: "void", parameters: parameters), "\(owner).\(name)")
        }
        XCTAssertEqual(try storedField("jpeg_d_main_controller", "start_pass").functionPointerSignatureV1,
            .init(returnType: "void", parameters: parameters + [.init(name: "pass_mode", type: "J_BUF_MODE")]))
        XCTAssertEqual(try storedField("jpeg_marker_reader", "read_markers").functionPointerSignatureV1,
            .init(returnType: "int32_t", parameters: parameters))
        // This field uses the callback typedef, whereas read_markers is a direct declarator.
        let callback = try storedField("jpeg_marker_reader", "read_restart_marker")
        XCTAssertEqual(callback.type, "jpeg_marker_parser_method")
        XCTAssertEqual(callback.functionPointerSignatureV1, .init(returnType: "int32_t", parameters: parameters))
        XCTAssertEqual(try storedField("jpeg_marker_parser_method", "jpeg_marker_parser_method").functionPointerSignatureV1,
            callback.functionPointerSignatureV1)
    }
}
