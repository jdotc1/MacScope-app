import Foundation
import XCTest
@testable import MacScope

final class CTypeHeaderArrayTypedefTests: XCTestCase {
    private typealias Signature = FunctionPointerSignatureV1

    func testArrayPointerAliasesPreserveNominalSignaturesAndLayout() throws {
        let result = CTypeHeaderParser.parse("""
        typedef short JCOEF;
        typedef JCOEF JBLOCK[64];
        typedef JBLOCK *JBLOCKROW;
        typedef JBLOCKROW *JBLOCKARRAY;
        typedef JBLOCKARRAY *JBLOCKIMAGE;
        typedef JCOEF Grid[2][0x3U];
        struct Callbacks { JBLOCKARRAY (*copy)(JBLOCKROW row, JBLOCKARRAY rows); };
        JBLOCKARRAY copy_blocks(JBLOCKROW row, JBLOCKARRAY rows);
        void image(JBLOCKIMAGE blocks, Grid *grid, const JBLOCK *block);
        """)
        XCTAssertTrue(result.diagnostics.isEmpty, result.diagnostics.joined(separator: "\n"))
        let catalog = Dictionary(uniqueKeysWithValues: result.types.map { ($0.name, $0) })
        let expected = Signature(returnType: "JBLOCK * *", parameters: [
            .init(name: "row", type: "JBLOCK *"), .init(name: "rows", type: "JBLOCK * *"),
        ])
        XCTAssertEqual(catalog["Callbacks"]?.fields.first?.functionPointerSignatureV1, expected)
        let prototype = try XCTUnwrap(result.prototypes.first { $0.name == "copy_blocks" })
        XCTAssertEqual(prototype.signature.returnType, expected.returnType)
        XCTAssertEqual(prototype.signature.args.map(\.type), expected.parameters.map(\.type))
        XCTAssertEqual(prototype.signature.args.map(\.name), ["row", "rows"])
        XCTAssertEqual(result.prototypes.last?.signature.args.map(\.type), ["JBLOCK * * *", "Grid *", "const JBLOCK *"])
        XCTAssertEqual(result.skippedPrototypeCount, 0)
        XCTAssertEqual(catalog["JBLOCK"]?.fields.first?.type, "JCOEF[64]")
        XCTAssertEqual(TypeDefinition.size(ofType: "JBLOCK", in: catalog), 128)
        XCTAssertEqual(TypeDefinition.alignment(ofType: "JBLOCK", in: catalog), 2)
        XCTAssertEqual(TypeDefinition.size(ofType: "JBLOCKROW", in: catalog), 8)
        XCTAssertEqual(TypeDefinition.alignment(ofType: "JBLOCKROW", in: catalog), 8)
        XCTAssertEqual(TypeDefinition.size(ofType: "Grid", in: catalog), 12)
        XCTAssertEqual(TypeDefinition.alignment(ofType: "Grid", in: catalog), 2)
    }

    func testBareArrayParametersAndReturnsAreRefusedWithoutDecay() throws {
        let result = CTypeHeaderParser.parse("""
        typedef short JBLOCK[64];
        typedef JBLOCK BlockAlias;
        void named(JBLOCK b);
        void unnamed(JBLOCK);
        void qualified(const BlockAlias b);
        JBLOCK returns_array(void);
        BlockAlias returns_alias(void);
        struct Refused {
            void (*parameter)(JBLOCK b);
            JBLOCK (*result)(void);
            void (*alias)(BlockAlias b);
        };
        void accepted(BlockAlias *b);
        """)
        XCTAssertEqual(result.prototypes.map(\.name), ["accepted"])
        XCTAssertEqual(result.prototypes.first?.signature.args.first?.type, "JBLOCK *")
        XCTAssertEqual(result.skippedPrototypeCount, 5)
        let fields = try XCTUnwrap(result.types.first { $0.name == "Refused" }).fields
        XCTAssertEqual(fields.count, 3)
        for field in fields {
            XCTAssertEqual(field.declaratorSemanticsV1, .functionPointerCarrier)
            XCTAssertNil(field.functionPointerSignatureV1, field.name)
        }
    }

    func testUnresolvedElementsAndNonconstantDimensionsRemainUnsupported() throws {
        for declaration in ["typedef Unknown Block[4];", "typedef short Block[N];",
                            "typedef short Block[];", "typedef short Block[-1];",
                            "typedef short Block[2 + 2];", "typedef Block Block[4];",
                            "typedef Later Block[4]; typedef Block Later;"] {
            let result = CTypeHeaderParser.parse(declaration + " struct S { void (*f)(Block *b); }; void f(Block *b);")
            XCTAssertTrue(result.prototypes.isEmpty, declaration)
            XCTAssertEqual(result.skippedPrototypeCount, 1, declaration)
            let field = try XCTUnwrap(result.types.first { $0.name == "S" }?.fields.first)
            XCTAssertNil(field.functionPointerSignatureV1, declaration)
        }
    }

    func testDuplicateAndConflictingArrayNamesAreUnsupported() throws {
        for declarations in [
            "typedef short Block[4]; typedef short Block[4];",
            "typedef short Block[4]; typedef short Block[8];",
            "typedef short Block[4]; typedef int Block;",
            "typedef int Block; typedef short Block[4];",
            "typedef short Block[4]; typedef int (*Block)(void);",
            "typedef int (*Block)(void); typedef short Block[4];",
            "typedef short Block[4]; typedef Block Block;",
        ] {
            let result = CTypeHeaderParser.parse(declarations + " struct S { void (*f)(Block *b); }; void f(Block *b);")
            XCTAssertTrue(result.prototypes.isEmpty, declarations)
            XCTAssertEqual(result.skippedPrototypeCount, 1, declarations)
            let field = try XCTUnwrap(result.types.first { $0.name == "S" }?.fields.first)
            XCTAssertNil(field.functionPointerSignatureV1, declarations)
        }
    }

    func testPinnedLibjpegArraySignaturesAdmissionAndLayout() throws {
        let result = CTypeHeaderParser.parse(try H2SignatureHeaders.preprocessed())
        let catalog = Dictionary(uniqueKeysWithValues: result.types.map { ($0.name, $0) })
        let compress = Signature.Parameter(name: "cinfo", type: "struct jpeg_compress_struct *")
        let common = Signature.Parameter(name: "cinfo", type: "struct jpeg_common_struct *")
        let dctTail: [Signature.Parameter] = [
            .init(name: "coef_blocks", type: "JBLOCK *"), .init(name: "start_row", type: "uint32_t"),
            .init(name: "start_col", type: "uint32_t"), .init(name: "num_blocks", type: "uint32_t"),
        ]
        let expected: [(String, String, Signature)] = [
            ("jpeg_forward_dct", "forward_DCT", .init(returnType: "void", parameters: [compress,
                .init(name: "compptr", type: "jpeg_component_info *"), .init(name: "sample_data", type: "uint8_t * *")] + dctTail)),
            ("jpeg_forward_dct", "forward_DCT_12", .init(returnType: "void", parameters: [compress,
                .init(name: "compptr", type: "jpeg_component_info *"), .init(name: "sample_data", type: "int16_t * *")] + dctTail)),
            ("jpeg_entropy_encoder", "encode_mcu", .init(returnType: "int32_t", parameters: [compress,
                .init(name: "MCU_data", type: "JBLOCK * *")])),
            ("jpeg_entropy_decoder", "decode_mcu", Self.decodeSignature),
            ("jpeg_memory_mgr", "alloc_barray", .init(returnType: "JBLOCK * *", parameters: [common,
                .init(name: "pool_id", type: "int32_t"), .init(name: "blocksperrow", type: "uint32_t"),
                .init(name: "numrows", type: "uint32_t")])),
            ("jpeg_memory_mgr", "access_virt_barray", .init(returnType: "JBLOCK * *", parameters: [common,
                .init(name: "ptr", type: "struct jvirt_barray_control *"), .init(name: "start_row", type: "uint32_t"),
                .init(name: "num_rows", type: "uint32_t"), .init(name: "writable", type: "int32_t")])),
        ]
        for (owner, name, signature) in expected {
            let actual = catalog[owner]?.fields.first { $0.name == name }?.functionPointerSignatureV1
            XCTAssertEqual(actual, signature, "\(owner).\(name)")
            print("H3 signature \(owner).\(name): \(String(describing: actual))")
        }
        let fields = result.types.filter { $0.kind == .struct || $0.kind == .union }.flatMap(\.fields).filter {
            $0.declaratorSemanticsV1 == .functionPointerCarrier || $0.declaratorSemanticsV1 == .arrayOfFunctionPointerCarrier
        }
        let withSignature = fields.filter { $0.functionPointerSignatureV1 != nil }.count
        print("H3 header: \(withSignature) with / \(fields.count - withSignature) without signature; \(result.prototypes.count) admitted / \(result.skippedPrototypeCount) skipped prototypes")
        result.diagnostics.forEach { print("H3 remaining: \($0)") }
        XCTAssertEqual(withSignature, 114)
        XCTAssertEqual(fields.count - withSignature, 0)
        XCTAssertEqual(result.prototypes.count, 138)
        XCTAssertEqual(result.skippedPrototypeCount, 0)
        let copy = try XCTUnwrap(result.prototypes.first { $0.name == "jcopy_block_row" })
        XCTAssertEqual(copy.signature.returnType, "void")
        XCTAssertEqual(copy.signature.args.map(\.type), ["JBLOCK *", "JBLOCK *", "uint32_t"])
        XCTAssertEqual(copy.signature.args.map(\.name), ["input_row", "output_row", "num_blocks"])
        XCTAssertEqual(TypeDefinition.size(ofType: "JBLOCK", in: catalog), 128)
        XCTAssertEqual(TypeDefinition.alignment(ofType: "JBLOCK", in: catalog), 2)
        XCTAssertEqual(TypeDefinition.size(ofType: "JBLOCKROW", in: catalog), 8)
        XCTAssertEqual(TypeDefinition.alignment(ofType: "JBLOCKROW", in: catalog), 8)
    }

    @MainActor
    func testArrayCallbackReachesWorkspaceSnapshotAndRenderInput() throws {
        let store = WorkspaceStore(workspaceName: "H3 arrays", snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [.primary: ImageAnalysis()]),
            engine: AnalysisEngine(), autosaveScheduler: nil)
        store.defineTypesFromCHeader(try H2SignatureHeaders.preprocessed())
        let type = try XCTUnwrap(store.snapshot.typeDefinitions.first { $0.name == "jpeg_entropy_decoder" })
        let field = try XCTUnwrap(type.fields.first { $0.name == "decode_mcu" })
        XCTAssertEqual(field.functionPointerSignatureV1, Self.decodeSignature)
        let input = store.snapshot.pseudocodeRenderInput(selectedAddress: nil, in: .primary)
        XCTAssertEqual(input.types.first { $0.name == type.name }, type)
    }

    private static var decodeSignature: Signature {
        Signature(returnType: "int32_t", parameters: [
            .init(name: "cinfo", type: "struct jpeg_decompress_struct *"), .init(name: "MCU_data", type: "JBLOCK * *"),
        ])
    }
}
