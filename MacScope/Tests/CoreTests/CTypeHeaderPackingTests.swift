import XCTest
@testable import MacScope

final class CTypeHeaderPackingTests: XCTestCase {
    private func parse(_ source: String) -> CTypeHeaderParser.Result {
        CTypeHeaderParser.parse(source, idProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000000")! })
    }

    private func catalog(from result: CTypeHeaderParser.Result) -> [String: TypeDefinition] {
        Dictionary(uniqueKeysWithValues: result.types.map { ($0.name, $0) })
    }

    private func offsets(for type: TypeDefinition, in catalog: [String: TypeDefinition]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: type.memberLayout(in: catalog).compactMap { item in
            item.field.name.isEmpty ? nil : (item.field.name, item.offset)
        })
    }

    func testPackedStructParsesBothAttributePositionsAndCombo() throws {
        let result = parse("""
        struct __attribute__((packed)) P1 { char a; int b; };
        struct P2 { char a; int b; } __attribute__((packed));
        struct __attribute__((packed, aligned(4))) PA { char a; int b; char c; };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = catalog(from: result)
        let p1 = try XCTUnwrap(types["P1"])
        let p2 = try XCTUnwrap(types["P2"])
        let pa = try XCTUnwrap(types["PA"])

        XCTAssertEqual(TypeDefinition.size(ofType: "P1", in: types), 5)
        XCTAssertEqual(TypeDefinition.size(ofType: "P2", in: types), 5)
        XCTAssertEqual(offsets(for: p1, in: types), ["a": 0, "b": 1])
        XCTAssertEqual(offsets(for: p2, in: types), ["a": 0, "b": 1])

        XCTAssertEqual(TypeDefinition.size(ofType: "PA", in: types), 8)
        XCTAssertEqual(offsets(for: pa, in: types), ["a": 0, "b": 1, "c": 5])
    }

    func testAlignedStructRoundsFinalSize() throws {
        let result = parse("struct __attribute__((aligned(16))) A1 { char a; int b; };")

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = catalog(from: result)
        let a1 = try XCTUnwrap(types["A1"])
        XCTAssertEqual(TypeDefinition.size(ofType: "A1", in: types), 16)
        XCTAssertEqual(offsets(for: a1, in: types), ["a": 0, "b": 4])
    }

    func testPragmaPackPushPopScopesLayout() throws {
        let result = parse("""
        #pragma pack(push, 1)
        struct PackedScope { char a; long b; };
        #pragma pack(pop)
        struct Restored { char a; long b; };
        #pragma pack(1)
        struct DirectPacked { char a; int b; };
        #pragma pack(0)
        struct ZeroReset { char a; int b; };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = catalog(from: result)
        let packed = try XCTUnwrap(types["PackedScope"])
        let restored = try XCTUnwrap(types["Restored"])
        let directPacked = try XCTUnwrap(types["DirectPacked"])
        let zeroReset = try XCTUnwrap(types["ZeroReset"])
        XCTAssertEqual(TypeDefinition.size(ofType: "PackedScope", in: types), 9)
        XCTAssertEqual(TypeDefinition.size(ofType: "Restored", in: types), 16)
        XCTAssertEqual(TypeDefinition.size(ofType: "DirectPacked", in: types), 5)
        XCTAssertEqual(TypeDefinition.size(ofType: "ZeroReset", in: types), 8)
        XCTAssertEqual(offsets(for: packed, in: types), ["a": 0, "b": 1])
        XCTAssertEqual(offsets(for: restored, in: types), ["a": 0, "b": 8])
        XCTAssertEqual(offsets(for: directPacked, in: types), ["a": 0, "b": 1])
        XCTAssertEqual(offsets(for: zeroReset, in: types), ["a": 0, "b": 4])
    }

    func testAlignasMemberRaisesMemberAndStructAlignment() throws {
        let result = parse("""
        struct AL { char a; _Alignas(8) int b; };
        struct ALT { char a; _Alignas(double) int b; };
        """)

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = catalog(from: result)
        let al = try XCTUnwrap(types["AL"])
        let alt = try XCTUnwrap(types["ALT"])
        XCTAssertEqual(TypeDefinition.size(ofType: "AL", in: types), 16)
        XCTAssertEqual(TypeDefinition.size(ofType: "ALT", in: types), 16)
        XCTAssertEqual(offsets(for: al, in: types), ["a": 0, "b": 8])
        XCTAssertEqual(offsets(for: alt, in: types), ["a": 0, "b": 8])
    }

    func testFlexibleArrayContributesZeroSizeButHasOffset() throws {
        let result = parse("struct Flex { int n; char data[]; };")

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = catalog(from: result)
        let flex = try XCTUnwrap(types["Flex"])
        XCTAssertEqual(TypeDefinition.size(ofType: "Flex", in: types), 4)
        XCTAssertEqual(offsets(for: flex, in: types), ["n": 0, "data": 4])
    }

    func testPlainStructRegressionKeepsNaturalLayout() throws {
        let result = parse("struct Plain { int a; char b; double c; };")

        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let types = catalog(from: result)
        let plain = try XCTUnwrap(types["Plain"])
        XCTAssertEqual(TypeDefinition.size(ofType: "Plain", in: types), 16)
        XCTAssertEqual(offsets(for: plain, in: types), ["a": 0, "b": 4, "c": 8])
    }
}
