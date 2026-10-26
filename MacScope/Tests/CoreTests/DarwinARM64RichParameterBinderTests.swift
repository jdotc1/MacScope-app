import Foundation
import XCTest
@testable import MacScope

final class DarwinARM64RichParameterBinderTests: XCTestCase {
    private func resolver(_ extra: String = "") -> TypeAtlasDarwinARM64LayoutResolver {
        let source = """
        typedef float V2 __attribute__((vector_size(8)));
        typedef float V4 __attribute__((vector_size(16)));
        typedef int I2 __attribute__((vector_size(8)));
        typedef int I4 __attribute__((vector_size(16)));
        struct H1 { float a; };
        struct H2 { float a; float b; };
        struct H3 { float a; float b; float c; };
        struct H4 { float a; float b; float c; float d; };
        struct HV2 { V4 a; V4 b; };
        struct S3 { char a; char b; char c; };
        struct S8 { long a; };
        struct S16 { long a; long b; };
        struct S24 { long a; long b; long c; };
        """ + extra
        let result = CTypeHeaderParser.parse(source)
        return TypeAtlasDarwinARM64LayoutResolver(catalog: Dictionary(result.types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    private func bind(_ types: [String], extra: String = "", variadic: Bool = false) -> [DarwinARM64RichParameterLocation] {
        DarwinARM64ParameterBinder.bindRich(parameterTypes: types, isVariadic: variadic, resolver: resolver(extra))
    }

    private func piece(_ index: Int, _ offset: Int, _ size: Int) -> DarwinARM64RichParameterPiece {
        .init(register: .gpr(index: index, carrierWidth: 64), valueByteOffset: offset, size: size)
    }

    func testSmallCompositesAndInt128CanStartAtOddGPR() {
        for type in ["S16", "__int128", "unsigned __int128"] {
            XCTAssertEqual(bind(["long", type, "int"]), [
                .gpr(index: 0, carrierWidth: 64), .composite(pieces: [piece(1, 0, 8), piece(2, 8, 8)]),
                .gpr(index: 3, carrierWidth: 32),
            ])
        }
    }

    func testSmallCompositeSpillsWholeAndForbidsGPRBackfill() {
        let bound = bind(Array(repeating: "long", count: 7) + ["S16", "char", "float"])
        XCTAssertEqual(Array(bound.suffix(3)), [
            .entryStack(byteOffset: 0, size: 16, alignment: 8),
            .entryStack(byteOffset: 16, size: 1, alignment: 1), .simd(index: 0, registerWidth: 32),
        ])
        let fits = bind(Array(repeating: "long", count: 6) + ["S16", "char"])
        XCTAssertEqual(fits[6], .composite(pieces: [piece(6, 0, 8), piece(7, 8, 8)]))
        XCTAssertEqual(fits[7], .entryStack(byteOffset: 0, size: 1, alignment: 1))
    }

    func testInt128StackAlignmentAndNarrowNamedSlots() {
        let bound = bind(Array(repeating: "long", count: 8) + ["char", "__int128", "short", "char"])
        XCTAssertEqual(Array(bound.suffix(4)), [
            .entryStack(byteOffset: 0, size: 1, alignment: 1),
            .entryStack(byteOffset: 16, size: 16, alignment: 16),
            .entryStack(byteOffset: 32, size: 2, alignment: 2),
            .entryStack(byteOffset: 34, size: 1, alignment: 1),
        ])
    }

    func testHFASpillsWholeAndForbidsSIMDBackfill() {
        let bound = bind(Array(repeating: "float", count: 7) + ["H2", "float", "long"])
        XCTAssertEqual(Array(bound.suffix(3)), [
            .entryStack(byteOffset: 0, size: 8, alignment: 4),
            .entryStack(byteOffset: 8, size: 4, alignment: 4), .gpr(index: 0, carrierWidth: 64),
        ])
    }

    func testHFAStackSlotsHaveTrueSizeNotEightByteRounding() {
        for (name, size) in [("H1", 4), ("H3", 12)] {
            let bound = bind(Array(repeating: "float", count: 8) + [name, "float"])
            XCTAssertEqual(Array(bound.suffix(2)), [
                .entryStack(byteOffset: 0, size: size, alignment: 4),
                .entryStack(byteOffset: size, size: 4, alignment: 4),
            ])
        }
        let hva = bind(Array(repeating: "float", count: 7) + ["HV2", "float"])
        XCTAssertEqual(Array(hva.suffix(2)), [
            .entryStack(byteOffset: 0, size: 32, alignment: 16),
            .entryStack(byteOffset: 32, size: 4, alignment: 4),
        ])
    }

    func testVectorsUseDOrQAndNaturallyAlignedStackSlots() {
        XCTAssertEqual(bind(["V2", "V4", "long"]), [
            .simd(index: 0, registerWidth: 64), .simd(index: 1, registerWidth: 128), .gpr(index: 0, carrierWidth: 64),
        ])
        XCTAssertEqual(Array(bind(Array(repeating: "float", count: 8) + ["V2", "V4"]).suffix(2)), [
            .entryStack(byteOffset: 0, size: 8, alignment: 8), .entryStack(byteOffset: 16, size: 16, alignment: 16),
        ])
    }

    func testIndirectArgumentsCarryValueSizeAndPointerLocation() {
        XCTAssertEqual(bind(["S24", "float", "long"]), [
            .indirect(pointer: .gpr(index: 0), pointeeSize: 24, pointeeAlignment: 8),
            .simd(index: 0, registerWidth: 32), .gpr(index: 1, carrierWidth: 64),
        ])
        let spilled = bind(Array(repeating: "int", count: 9) + ["S24", "char"])
        XCTAssertEqual(Array(spilled.suffix(3)), [
            .entryStack(byteOffset: 0, size: 4, alignment: 4),
            .indirect(pointer: .entryStack(byteOffset: 8), pointeeSize: 24, pointeeAlignment: 8),
            .entryStack(byteOffset: 16, size: 1, alignment: 1),
        ])
    }

    func testPartialFinalChunkKeepsValueRangeSeparateFromCarrierWidth() {
        XCTAssertEqual(bind(["S3"]), [.composite(pieces: [piece(0, 0, 3)])])
        let spilled = bind(Array(repeating: "long", count: 8) + ["S3", "char"])
        XCTAssertEqual(Array(spilled.suffix(2)), [
            .entryStack(byteOffset: 0, size: 8, alignment: 8), .entryStack(byteOffset: 8, size: 1, alignment: 1),
        ])
    }

    func testArrayAliasNestedAndUnionHFAUseAtlasLayouts() throws {
        let extra = """
        typedef float Pair[2]; typedef Pair PairAlias;
        struct Nested { PairAlias a; struct H2 b; };
        union UnionHFA { float a[2]; struct H2 b; };
        union MixedUnion { float a; int b; };
        """
        let resolver = resolver(extra)
        for (name, count) in [("Nested", 4), ("UnionHFA", 2)] {
            let layout = try XCTUnwrap(resolver.resolveLayout(ofType: name))
            XCTAssertEqual(layout.size, TypeDefinition.size(ofType: name, in: resolver.catalog))
            XCTAssertEqual(layout.alignment, TypeDefinition.alignment(ofType: name, in: resolver.catalog))
            XCTAssertEqual(layout.homogeneous?.count, count)
            XCTAssertEqual(layout.homogeneous?.memberOffsets, (0..<count).map { $0 * 4 })
        }
        XCTAssertNil(resolver.resolveLayout(ofType: "MixedUnion")?.homogeneous)
        XCTAssertEqual(bind(["MixedUnion"], extra: extra), [.composite(pieces: [piece(0, 0, 4)])])
    }

    func testEqualWidthVectorsAreHomogeneousRegardlessOfElementType() throws {
        let extra = "struct MixV8 { V2 a; I2 b; }; struct MixV16 { V4 a; I4 b; };"
        let resolver = resolver(extra)
        for (name, bytes) in [("MixV8", 8), ("MixV16", 16)] {
            let layout = try XCTUnwrap(resolver.resolveLayout(ofType: name))
            XCTAssertEqual(layout.homogeneous?.base, .shortVector(byteSize: bytes))
            XCTAssertEqual(DarwinARM64ParameterBinder.bindRich(parameterTypes: [name], resolver: resolver), [
                .composite(pieces: [
                    .init(register: .simd(index: 0, registerWidth: bytes * 8), valueByteOffset: 0, size: bytes),
                    .init(register: .simd(index: 1, registerWidth: bytes * 8), valueByteOffset: bytes, size: bytes),
                ]),
            ])
        }
    }

    func testUnverifiedOrdinarySixteenByteAlignedCompositeDeclines() {
        let extra = "struct __attribute__((aligned(16))) A16 { long a; long b; };"
        XCTAssertEqual(bind(["A16", "long"], extra: extra), [
            .unbound(reason: .unsupportedType("A16")), .unbound(reason: .dependentOnUnsupportedEarlierParameter),
        ])
        XCTAssertEqual(DarwinARM64ParameterBinder.returnLocation(for: "A16", resolver: resolver(extra)), .unbound(reason: .unsupportedType("A16")))
    }

    func testUnknownAndUnsupportedShapesPoisonOnlyFollowingFormals() {
        for type in ["Missing", "enum H2", "void", "int[2]"] {
            XCTAssertEqual(bind(["float", type, "long"]), [
                .simd(index: 0, registerWidth: 32), .unbound(reason: .unsupportedType(type)),
                .unbound(reason: .dependentOnUnsupportedEarlierParameter),
            ])
        }
        let extra = "struct Bits { unsigned a:3; }; struct Flex { int n; char data[]; }; struct Pad { _Alignas(8) float a; float b; };"
        for type in ["Bits", "Flex", "Pad"] {
            XCTAssertEqual(bind([type], extra: extra), [.unbound(reason: .unsupportedType(type))])
        }
    }

    func testLegacyAPIStillDeclinesAllRichShapes() {
        for type in ["H1", "S16", "S24", "__int128", "V2", "V4"] {
            XCTAssertEqual(DarwinARM64ParameterBinder.bind(parameterTypes: ["long", type, "double"]), [
                .gpr(index: 0, carrierWidth: 64), .unbound(reason: .unsupportedType(type)),
                .unbound(reason: .dependentOnUnsupportedEarlierParameter),
            ])
        }
    }

    func testVariadicFlagDoesNotPromoteNamedFormals() {
        let types = Array(repeating: "int", count: 8) + ["char", "float", "short"]
        XCTAssertEqual(bind(types, variadic: true), bind(types, variadic: false))
        XCTAssertEqual(bind(types, variadic: true)[8], .entryStack(byteOffset: 0, size: 1, alignment: 1))
    }

    func testReturnLocationModelsVoidScalarCompositeAndIndirectStorage() {
        let resolver = resolver()
        XCTAssertEqual(DarwinARM64ParameterBinder.returnLocation(for: "void", resolver: resolver), .void)
        XCTAssertEqual(DarwinARM64ParameterBinder.returnLocation(for: "char", resolver: resolver), .single(.gpr(index: 0, carrierWidth: 32)))
        XCTAssertEqual(DarwinARM64ParameterBinder.returnLocation(for: "V4", resolver: resolver), .single(.simd(index: 0, registerWidth: 128)))
        XCTAssertEqual(DarwinARM64ParameterBinder.returnLocation(for: "__int128", resolver: resolver), .composite(pieces: [piece(0, 0, 8), piece(1, 8, 8)]))
        XCTAssertEqual(DarwinARM64ParameterBinder.returnLocation(for: "S24", resolver: resolver), .indirect(resultPointerRegister: 8, pointeeSize: 24, pointeeAlignment: 8))
    }

    func testMalformedResolverResultsFailClosed() {
        struct FixedResolver: DarwinARM64TypeLayoutResolving {
            let value: DarwinARM64TypeLayout
            func resolveLayout(ofType type: String) -> DarwinARM64TypeLayout? { value }
        }
        let malformed: [DarwinARM64TypeLayout] = [
            .init(kind: .aggregate, size: 0, alignment: 1),
            .init(kind: .aggregate, size: 8, alignment: 3),
            .init(kind: .aggregate, size: 3, alignment: 2),
            .init(kind: .integer, size: 3, alignment: 1),
            .init(kind: .floating, size: 16, alignment: 16),
            .init(kind: .shortVector, size: 32, alignment: 32),
            .init(kind: .aggregate, size: 8, alignment: 4, homogeneous: .init(base: .floating(byteSize: 4), memberOffsets: [4, 0])),
            .init(kind: .aggregate, size: 20, alignment: 4, homogeneous: .init(base: .floating(byteSize: 4), memberOffsets: [0, 4, 8, 12, 16])),
            .init(kind: .aggregate, size: 16, alignment: 8, homogeneous: .init(base: .floating(byteSize: 16), memberOffsets: [0])),
        ]
        for value in malformed {
            XCTAssertEqual(DarwinARM64ParameterBinder.bindRich(parameterTypes: ["Custom", "int"], resolver: FixedResolver(value: value)), [
                .unbound(reason: .unsupportedType("Custom")), .unbound(reason: .dependentOnUnsupportedEarlierParameter),
            ])
        }
    }
    func testAnonymousUnionGroupingSurvivesPromotedMemberView() throws {
        let extra = """
        struct Anonymous { union { float a; float b; float c; float d; float e; }; };
        struct AnonymousTail { union { float a; float b; float c; float d; float e; }; float tail; };
        """
        let resolver = resolver(extra)
        XCTAssertEqual(resolver.catalog["Anonymous"]?.memberLayout(in: resolver.catalog).count, 5)
        XCTAssertEqual(resolver.resolveLayout(ofType: "Anonymous")?.homogeneous?.count, 1)
        XCTAssertEqual(resolver.resolveLayout(ofType: "AnonymousTail")?.homogeneous?.memberOffsets, [0, 4])
        XCTAssertEqual(DarwinARM64ParameterBinder.bindRich(parameterTypes: ["AnonymousTail"], resolver: resolver), [
            .composite(pieces: [
                .init(register: .simd(index: 0, registerWidth: 32), valueByteOffset: 0, size: 4),
                .init(register: .simd(index: 1, registerWidth: 32), valueByteOffset: 4, size: 4),
            ]),
        ])
    }

    func testPackedHomogeneousSpillsUseBaseAlignment() {
        let extra = "struct __attribute__((packed)) PH { float a; float b; }; struct __attribute__((packed)) PV { V4 a; V4 b; };"
        for (name, offset, size, alignment, tail) in [("PH", 4, 8, 4, 12), ("PV", 16, 32, 16, 48)] {
            let types = Array(repeating: "long", count: 8) + Array(repeating: "float", count: 7) + ["char", name, "char"]
            XCTAssertEqual(Array(bind(types, extra: extra).suffix(3)), [
                .entryStack(byteOffset: 0, size: 1, alignment: 1),
                .entryStack(byteOffset: offset, size: size, alignment: alignment),
                .entryStack(byteOffset: tail, size: 1, alignment: 1),
            ])
        }
    }

    func testAtomicABIQualificationSurvivesPersistenceAndExport() throws {
        let extra = "typedef _Atomic float AF; struct Atomic { _Atomic float a; }; struct AliasAtomic { AF a; };"
        let resolver = resolver(extra)
        XCTAssertEqual(resolver.catalog["Atomic"]?.fields.first?.isAtomic, true)
        XCTAssertEqual(resolver.catalog["AF"]?.fields.first?.isAtomic, true)
        for name in ["Atomic", "AliasAtomic"] {
            XCTAssertNil(resolver.resolveLayout(ofType: name))
            XCTAssertEqual(TypeDefinition.size(ofType: name, in: resolver.catalog), 4)
        }
        let definitions = [try XCTUnwrap(resolver.catalog["AF"]), try XCTUnwrap(resolver.catalog["Atomic"]), try XCTUnwrap(resolver.catalog["AliasAtomic"])]
        let restored = try JSONDecoder().decode([TypeDefinition].self, from: JSONEncoder().encode(definitions))
        XCTAssertEqual(restored, definitions)
        let exported = CTypeHeaderParser.parse(CTypeHeaderRenderer.render(types: restored))
        XCTAssertTrue(exported.diagnostics.isEmpty)
        let second = TypeAtlasDarwinARM64LayoutResolver(catalog: Dictionary(exported.types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }))
        for name in ["Atomic", "AliasAtomic"] { XCTAssertNil(second.resolveLayout(ofType: name)) }
        XCTAssertEqual(DarwinARM64ParameterBinder.bindRich(parameterTypes: ["_Atomic float", "_Atomic double"], resolver: resolver), [
            .simd(index: 0, registerWidth: 32), .simd(index: 1, registerWidth: 64),
        ])
        for name in ["restrict float", "float restrict", "restrict int", "_Atomic Atomic"] {
            XCTAssertEqual(DarwinARM64ParameterBinder.bindRich(parameterTypes: [name], resolver: resolver), [.unbound(reason: .unsupportedType(name))])
        }
    }

    func testSmallCompositeReturnsUseW0ButParametersUseX0() {
        XCTAssertEqual(bind(["S3"]), [.composite(pieces: [piece(0, 0, 3)])])
        XCTAssertEqual(DarwinARM64ParameterBinder.returnLocation(for: "S3", resolver: resolver()), .composite(pieces: [
            .init(register: .gpr(index: 0, carrierWidth: 32), valueByteOffset: 0, size: 3),
        ]))
    }

    func testAtomicAggregateLayoutsAreConservativelyUnknown() {
        let types = CTypeHeaderParser.parse("struct Base { char a; char b; char c; }; typedef _Atomic Base AtomicBase; struct S { char head; _Atomic Base value; char tail; };").types
        let catalog = Dictionary(types.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertNil(TypeDefinition.size(ofType: "AtomicBase", in: catalog))
        XCTAssertNil(TypeDefinition.alignment(ofType: "AtomicBase", in: catalog))
        XCTAssertNil(TypeDefinition.size(ofType: "S", in: catalog))
        XCTAssertEqual(catalog["S"]?.memberLayout(in: catalog).map(\.field.name), ["head"])
    }

    func testAuthoredRawAtomicTypesCannotMasqueradeAsHomogeneousFields() {
        let type = TypeDefinition(kind: .struct, name: "Raw", fields: [FieldDef(name: "a", type: "_Atomic float")])
        let alias = TypeDefinition(kind: .typedef, name: "AF", fields: [FieldDef(name: "AF", type: "_Atomic float")])
        let aliased = TypeDefinition(kind: .struct, name: "Aliased", fields: [FieldDef(name: "a", type: "AF")])
        let resolver = TypeAtlasDarwinARM64LayoutResolver(catalog: ["Raw": type, "AF": alias, "Aliased": aliased])
        XCTAssertNil(resolver.resolveLayout(ofType: "Raw"))
        XCTAssertNil(resolver.resolveLayout(ofType: "Aliased"))
    }

    func testMalformedCatalogNamesCannotOverrideUnsupportedTypeGrammar() {
        for name in ["int[2]", "void", "function()", "Foo Bar"] {
            let type = TypeDefinition(kind: .struct, name: name, fields: [FieldDef(name: "a", type: "long")])
            let resolver = TypeAtlasDarwinARM64LayoutResolver(catalog: [name: type])
            XCTAssertNil(resolver.resolveLayout(ofType: name))
            XCTAssertEqual(DarwinARM64ParameterBinder.bindRich(parameterTypes: [name], resolver: resolver), [.unbound(reason: .unsupportedType(name))])
        }
    }

}
