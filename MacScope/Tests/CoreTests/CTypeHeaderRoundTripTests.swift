import XCTest
@testable import MacScope

/// Round-trip tests for the C type-catalog interop seam: `CTypeHeaderParser`
/// (import) ⇄ `CTypeHeaderRenderer` (export). The contract is that for any
/// catalog the parser produced, rendering it and re-parsing the text yields the
/// *equivalent* catalog — same kind, name, and ordered fields. Ids are freshly
/// minted on every parse, so equivalence is compared by value modulo id.
///
/// "Green ≠ correct": the import path is itself the oracle here. A representative
/// header is parsed once, the result is exported, the export is parsed again, and
/// the two type lists must match field-for-field. That catches an asymmetric
/// renderer (e.g. a dropped pointer star, a mis-split array suffix, or an enum
/// case that loses its non-zero base) that a one-directional unit test would miss.
final class CTypeHeaderRoundTripTests: XCTestCase {

    /// Parses with a DISTINCT-per-type deterministic id. A single fixed UUID for every
    /// type would make all `TypeDefinition.id`s collide, so the equivalence check could
    /// not tell types apart by identity — a renderer that reordered or dropped a type
    /// could still pass. An incrementing provider gives the Nth parsed type the Nth id
    /// in BOTH the import and the re-import, so when the round-trip is order-preserving
    /// the per-ordinal ids line up and the check becomes a real identity comparison
    /// (id included), while a mismatch in count/order now surfaces as an id mismatch.
    private func parse(_ source: String) -> CTypeHeaderParser.Result {
        var counter: UInt32 = 0
        return CTypeHeaderParser.parse(source, idProvider: {
            counter += 1
            return Self.sequentialID(counter)
        })
    }

    /// A deterministic UUID seeded by an ordinal so the same position yields the same id
    /// across independent parses (here: import N ↔ re-import N).
    private static func sequentialID(_ ordinal: UInt32) -> UUID {
        let hex = String(format: "%08x", ordinal)
        return UUID(uuidString: "\(hex)-0000-0000-0000-000000000000")!
    }

    /// Compares two catalogs for value equivalence. Because the id provider assigns the
    /// same per-ordinal id to both sides, a faithful order-preserving round-trip yields
    /// fully-equal `TypeDefinition`s (id included) — so the assertion can now detect an
    /// id/identity mismatch (reorder, drop, or insert), not just kind/name/fields drift.
    private func assertEquivalent(
        _ lhs: [TypeDefinition], _ rhs: [TypeDefinition],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(lhs.count, rhs.count, "type count", file: file, line: line)
        for (a, b) in zip(lhs, rhs) {
            XCTAssertEqual(a.kind, b.kind, "kind of \(a.name)", file: file, line: line)
            XCTAssertEqual(a.name, b.name, "name", file: file, line: line)
            XCTAssertEqual(a.fields, b.fields, "fields of \(a.name)", file: file, line: line)
            XCTAssertEqual(a.id, b.id, "id (ordinal identity) of \(a.name)", file: file, line: line)
        }
    }

    // MARK: - Full representative round-trip (import → export → re-import)

    func testRepresentativeHeaderRoundTrips() {
        // Hits every supported form + every declarator shape the renderer must
        // reconstruct: mixed-width struct fields, multi-word primitives, a pointer
        // and array field, a user-type field reference, a union, an enum with
        // explicit + implicit (auto-incremented) values, a negative-based enum, a
        // primitive typedef, and a pointer typedef.
        let source = """
        struct Header {
            uint32_t magic;
            int16_t  version;
            char     flags;
            uint64_t offset;
        };

        struct Node {
            struct Node * next;
            char          name[16];
            int32_t       values[4];
            void *        context;
            Point         origin;
        };

        union Variant {
            int32_t i;
            float   f;
            void *  p;
        };

        enum Color {
            Red,
            Green = 5,
            Blue,
            Black = 0x10,
            White
        };

        enum Signed { A = -3, B, C };

        typedef unsigned long size_type;
        typedef char * c_string;
        """

        let imported = parse(source)
        XCTAssertTrue(imported.diagnostics.isEmpty, "import diagnostics: \(imported.diagnostics)")
        XCTAssertEqual(imported.types.count, 7)
        let importedFields = imported.types.flatMap(\.fields)
        XCTAssertEqual(importedFields.count, 22)
        XCTAssertEqual(
            importedFields.map(\.declaratorSemanticsV1),
            Array(repeating: .ordinary, count: 22),
            "every newly imported ordinary field, enum case, and typedef target must persist ordinary provenance"
        )

        // Export the imported catalog, then re-import the rendered text.
        let exported = CTypeHeaderRenderer.render(types: imported.types)
        let reimported = parse(exported)

        XCTAssertTrue(reimported.diagnostics.isEmpty,
                      "re-import diagnostics: \(reimported.diagnostics)\n---\n\(exported)")
        assertEquivalent(reimported.types, imported.types)
    }

    // MARK: - Renderer unit shapes (the exact emitted declarator syntax)

    func testRenderStructDeclarators() {
        let type = TypeDefinition(kind: .struct, name: "Node", fields: [
            FieldDef(name: "next", type: "Node *"),
            FieldDef(name: "name", type: "char[16]"),
            FieldDef(name: "values", type: "int32_t[4]"),
            FieldDef(name: "context", type: "void *"),
            FieldDef(name: "tag", type: "int32_t"),
        ])
        XCTAssertEqual(CTypeHeaderRenderer.renderType(type), """
        struct Node {
            Node *next;
            char name[16];
            int32_t values[4];
            void *context;
            int32_t tag;
        };
        """)
    }

    func testRenderEnumEmitsExplicitValues() {
        let type = TypeDefinition(kind: .enum, name: "Color", fields: [
            FieldDef(name: "Red", type: "0"),
            FieldDef(name: "Green", type: "5"),
            FieldDef(name: "Blue", type: "6"),
        ])
        XCTAssertEqual(CTypeHeaderRenderer.renderType(type), """
        enum Color {
            Red = 0,
            Green = 5,
            Blue = 6
        };
        """)
    }

    func testRenderTypedefPrimitiveAndPointer() {
        let primitive = TypeDefinition(kind: .typedef, name: "size_type",
                                       fields: [FieldDef(name: "size_type", type: "uint64_t")])
        XCTAssertEqual(CTypeHeaderRenderer.renderType(primitive), "typedef uint64_t size_type;")

        let pointer = TypeDefinition(kind: .typedef, name: "c_string",
                                     fields: [FieldDef(name: "c_string", type: "char *")])
        XCTAssertEqual(CTypeHeaderRenderer.renderType(pointer), "typedef char *c_string;")
    }

    // MARK: - Faithfulness on a catalog the import auto-increment can't reproduce

    /// A non-zero-based enum only round-trips because the renderer emits an explicit
    /// `= value` on EVERY case. A bare-name emit would re-import as 0,1,2 and lose the
    /// authored base — this is the regression the explicit-value rule guards against.
    func testNonZeroBasedEnumRoundTripsViaExplicitValues() {
        // Built with the id the parser assigns the first type, so the round-trip's
        // ordinal-identity check (a parsed re-import vs this catalog) is meaningful.
        let catalog = [TypeDefinition(id: Self.sequentialID(1), kind: .enum, name: "Priority", fields: [
            FieldDef(name: "Low", type: "10", declaratorSemanticsV1: .ordinary),
            FieldDef(name: "Medium", type: "11", declaratorSemanticsV1: .ordinary),
            FieldDef(name: "High", type: "20", declaratorSemanticsV1: .ordinary),
        ])]
        let exported = CTypeHeaderRenderer.render(types: catalog)
        let reimported = parse(exported)
        XCTAssertTrue(reimported.diagnostics.isEmpty, "\(reimported.diagnostics)")
        assertEquivalent(reimported.types, catalog)
    }

    // MARK: - Zero-field typedef is skipped, not synthesized into a phantom field

    /// A typedef authored with no fields (reachable via TypeEditorSheet) has no aliased
    /// base. The renderer must NOT emit `typedef void Name;`, which would re-import as a
    /// single-field typedef and break the by-value round-trip (0 fields vs 1). Instead it
    /// emits a skip diagnostic comment that re-imports to nothing.
    func testZeroFieldTypedefIsSkippedWithDiagnostic() {
        let empty = TypeDefinition(kind: .typedef, name: "Opaque", fields: [])
        let rendered = CTypeHeaderRenderer.renderType(empty)
        XCTAssertTrue(rendered.hasPrefix("//"), "zero-field typedef must render as a comment, got: \(rendered)")
        XCTAssertTrue(rendered.contains("Opaque"))
        XCTAssertFalse(rendered.contains("typedef void Opaque"),
                       "must not synthesize a phantom `void` base that round-trips to a 1-field typedef")

        // The whole-catalog render of just this type re-imports to an empty catalog.
        let reimported = parse(CTypeHeaderRenderer.render(types: [empty]))
        XCTAssertTrue(reimported.types.isEmpty,
                      "skipped typedef must not re-import as any type, got: \(reimported.types)")
    }

    // MARK: - splitType (the suffix-folding inverse) in isolation

    func testSplitTypeUndoesSuffixFolding() {
        XCTAssertTrue(CTypeHeaderRenderer.splitType("int32_t") == ("int32_t", "", ""))
        XCTAssertTrue(CTypeHeaderRenderer.splitType("void *") == ("void", "*", ""))
        XCTAssertTrue(CTypeHeaderRenderer.splitType("Node *") == ("Node", "*", ""))
        XCTAssertTrue(CTypeHeaderRenderer.splitType("char[16]") == ("char", "", "[16]"))
        XCTAssertTrue(CTypeHeaderRenderer.splitType("int8_t **") == ("int8_t", "**", ""))
    }

    // MARK: - Empty catalog renders a self-describing banner, not an empty file

    func testEmptyCatalogRendersBannerNote() {
        let text = CTypeHeaderRenderer.render(types: [])
        XCTAssertTrue(text.contains("No user-defined types"))
        // The note must itself be a comment so the file stays valid C.
        XCTAssertTrue(text.contains("//"))
    }
}
