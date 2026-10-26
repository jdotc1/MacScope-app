import Foundation
import XCTest
@testable import MacScope

/// Canonical subject-ref grammar (contract v1.1 proposal): every builder round-trips through
/// `parse(_:kind:)`, non-canonical spellings parse to nil, and the opt-in validator reports them.
final class NavigatorSubjectRefTests: XCTestCase {
    private static let sliceSHA256 = "0123456789abcdef" + String(repeating: "e", count: 48)

    private static func identity(uuid: UUID?) throws -> MachOSliceArtifactIdentity {
        try MachOSliceArtifactIdentity(
            uuid: uuid,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: sliceSHA256,
            selectedSliceByteCount: 4096
        )
    }

    func testImageRefDerivesFromHandBuiltIdentity() throws {
        let identity = try Self.identity(uuid: UUID(uuidString: "11111111-2222-3333-4444-55555555AAAA"))
        let ref = NavigatorSubjectRef.imageRef(identity)

        XCTAssertEqual(ref, "11111111-2222-3333-4444-55555555aaaa/0123456789abcdef")
        XCTAssertEqual(
            NavigatorSubjectRef.parse(ref, kind: "image"),
            .image(uuid: "11111111-2222-3333-4444-55555555aaaa", slicePrefix: "0123456789abcdef")
        )
        XCTAssertTrue(NavigatorSubjectRef.isCanonical(ref, kind: "image"))

        let subject = NavigatorSubjectRef.subject(kind: "function", ref: NavigatorSubjectRef.function(entry: 0x1_0000_3f20), identity: identity)
        XCTAssertEqual(subject, NavigatorSubject(kind: "function", ref: "0x100003f20", image: ref))
        XCTAssertEqual(NavigatorSubjectRef.imageSubject(identity), NavigatorSubject(kind: "image", ref: ref))
        XCTAssertNil(NavigatorSubjectRef.subject(kind: "address", ref: "0x10", identity: nil).image)
    }

    func testImageRefWithoutUUIDUsesPlaceholder() throws {
        let identity = try Self.identity(uuid: nil)
        let ref = NavigatorSubjectRef.imageRef(identity)

        XCTAssertEqual(ref, "nouuid/0123456789abcdef")
        XCTAssertEqual(NavigatorSubjectRef.parse(ref, kind: "image"), .image(uuid: nil, slicePrefix: "0123456789abcdef"))
        XCTAssertEqual(NavigatorSubjectRef.parse(ref, kind: "image")?.ref, ref)
    }

    func testAddressIsLowercaseHexWithoutLeadingZeros() {
        XCTAssertEqual(NavigatorSubjectRef.address(0), "0x0")
        XCTAssertEqual(NavigatorSubjectRef.address(0x1000), "0x1000")
        XCTAssertEqual(NavigatorSubjectRef.address(0xABCD_EF01), "0xabcdef01")
        XCTAssertEqual(NavigatorSubjectRef.address(UInt64.max), "0xffffffffffffffff")

        XCTAssertEqual(NavigatorSubjectRef.parseAddress("0x0"), 0)
        XCTAssertEqual(NavigatorSubjectRef.parseAddress("0xffffffffffffffff"), UInt64.max)
        for invalid in ["", "0x", "1000", "0X1000", "0x01000", "0x00", "0x1000A", "0x1g", "0x10000000000000000", " 0x10"] {
            XCTAssertNil(NavigatorSubjectRef.parseAddress(invalid), invalid)
        }
    }

    func testEveryKindRoundTrips() throws {
        let identity = try Self.identity(uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let cases: [(kind: String, ref: String?, parsed: NavigatorSubjectRef.Parsed)] = [
            ("image", NavigatorSubjectRef.imageRef(identity),
             .image(uuid: "11111111-2222-3333-4444-555555555555", slicePrefix: "0123456789abcdef")),
            ("address", NavigatorSubjectRef.address(0x4000), .address(0x4000)),
            ("range", NavigatorSubjectRef.range(0x4000, 0x4040), .range(lower: 0x4000, upper: 0x4040)),
            ("range", NavigatorSubjectRef.range(0x10, 0x10), .range(lower: 0x10, upper: 0x10)),
            ("function", NavigatorSubjectRef.function(entry: 0x1_0000_3f20), .function(entry: 0x1_0000_3f20)),
            ("type", NavigatorSubjectRef.type(descriptor: 0x8010), .type(descriptor: 0x8010)),
            ("protocol", NavigatorSubjectRef.`protocol`(descriptor: 0x8020), .protocolDescriptor(0x8020)),
            ("metadataRecord", NavigatorSubjectRef.metadataRecord(section: "__swift5_types", address: 0x8000),
             .metadataRecord(section: "__swift5_types", address: 0x8000)),
            ("metadataRecord", NavigatorSubjectRef.metadataRecord(section: "__TEXT,__swift5_fieldmd", address: 0x0),
             .metadataRecord(section: "__TEXT,__swift5_fieldmd", address: 0x0)),
            ("selector", NavigatorSubjectRef.selector("initWithFrame:style:"), .selector("initWithFrame:style:")),
            ("viewBody", NavigatorSubjectRef.viewBody(getter: 0x5a00), .viewBody(getter: 0x5a00)),
            ("field", NavigatorSubjectRef.field(typeRef: "0x8010", index: 0), .fieldIndex(typeRef: "0x8010", index: 0)),
            ("field", NavigatorSubjectRef.field(typeRef: "0x8010", index: 12), .fieldIndex(typeRef: "0x8010", index: 12)),
            ("field", NavigatorSubjectRef.field(typeRef: "name:Mod.Point", index: 1),
             .fieldIndex(typeRef: "name:Mod.Point", index: 1)),
        ]

        for (kind, maybeRef, expected) in cases {
            let ref = try XCTUnwrap(maybeRef, "builder for \(kind) returned nil")
            let parsed = try XCTUnwrap(NavigatorSubjectRef.parse(ref, kind: kind), "\(kind) \(ref)")
            XCTAssertEqual(parsed, expected, ref)
            XCTAssertEqual(parsed.ref, ref)
            XCTAssertEqual(parsed.kind, kind)
            XCTAssertTrue(NavigatorSubjectRef.isCanonical(ref, kind: kind), ref)
        }
    }

    func testLegacyFormsRoundTrip() throws {
        let namedType = try XCTUnwrap(NavigatorSubjectRef.named(kind: "type", qualifiedName: "Mod.Outer.Inner"))
        XCTAssertEqual(namedType, "name:Mod.Outer.Inner")
        XCTAssertEqual(NavigatorSubjectRef.parse(namedType, kind: "type"), .named(kind: "type", qualifiedName: "Mod.Outer.Inner"))
        XCTAssertEqual(NavigatorSubjectRef.parse(namedType, kind: "type")?.ref, namedType)

        let namedProtocol = try XCTUnwrap(NavigatorSubjectRef.named(kind: "protocol", qualifiedName: "Equatable"))
        XCTAssertEqual(namedProtocol, "name:Equatable")
        let parsedProtocol = try XCTUnwrap(NavigatorSubjectRef.parse(namedProtocol, kind: "protocol"))
        XCTAssertEqual(parsedProtocol, .named(kind: "protocol", qualifiedName: "Equatable"))
        XCTAssertEqual(parsedProtocol.kind, "protocol")

        // `"\(ref).\(field.name)"` as the Swift metadata projection writes it, for both type-ref forms.
        let addressField = try XCTUnwrap(NavigatorSubjectRef.field(typeRef: NavigatorSubjectRef.type(descriptor: 0x8010), name: "count"))
        XCTAssertEqual(addressField, "0x8010.count")
        XCTAssertEqual(NavigatorSubjectRef.parse(addressField, kind: "field"), .fieldName(typeRef: "0x8010", name: "count"))
        XCTAssertEqual(NavigatorSubjectRef.parse(addressField, kind: "field")?.ref, addressField)

        let namedField = try XCTUnwrap(NavigatorSubjectRef.field(typeRef: "name:Mod.Point", name: "x"))
        XCTAssertEqual(namedField, "name:Mod.Point.x")
        XCTAssertEqual(NavigatorSubjectRef.parse(namedField, kind: "field"), .fieldName(typeRef: "name:Mod.Point", name: "x"))
        XCTAssertEqual(NavigatorSubjectRef.parse(namedField, kind: "field")?.ref, namedField)
    }

    func testBuildersRefuseValuesOutsideTheGrammar() {
        XCTAssertNil(NavigatorSubjectRef.range(0x20, 0x10))
        XCTAssertNil(NavigatorSubjectRef.named(kind: "function", qualifiedName: "main"))
        XCTAssertNil(NavigatorSubjectRef.named(kind: "type", qualifiedName: ""))
        XCTAssertNil(NavigatorSubjectRef.named(kind: "type", qualifiedName: "Bad\nName"))
        XCTAssertNil(NavigatorSubjectRef.field(typeRef: "Point", name: "x"))
        XCTAssertNil(NavigatorSubjectRef.field(typeRef: "0x8010", name: "a.b"))
        XCTAssertNil(NavigatorSubjectRef.field(typeRef: "0x8010", name: "a#1"))
        XCTAssertNil(NavigatorSubjectRef.field(typeRef: "0x8010", name: ""))
        XCTAssertNil(NavigatorSubjectRef.field(typeRef: "0x8010", index: -1))
        XCTAssertNil(NavigatorSubjectRef.field(typeRef: "0x08010", index: 0))
        XCTAssertNil(NavigatorSubjectRef.metadataRecord(section: "", address: 0x10))
        XCTAssertNil(NavigatorSubjectRef.metadataRecord(section: "__swift5@types", address: 0x10))
        XCTAssertNil(NavigatorSubjectRef.metadataRecord(section: "__swift5 types", address: 0x10))
        XCTAssertNil(NavigatorSubjectRef.selector(""))
        XCTAssertNil(NavigatorSubjectRef.selector("init with:"))
    }

    func testBuildersPreserveUnicodeDelimiterBoundaries() throws {
        XCTAssertNil(NavigatorSubjectRef.field(typeRef: "0x8010", name: "\u{0301}x"))
        XCTAssertNil(NavigatorSubjectRef.named(kind: "type", qualifiedName: "\u{0301}x"))
        let ref = try XCTUnwrap(NavigatorSubjectRef.field(typeRef: "0x8010", name: "café"))
        XCTAssertEqual(NavigatorSubjectRef.parse(ref, kind: "field"), .fieldName(typeRef: "0x8010", name: "café"))
        XCTAssertEqual(NavigatorSubjectRef.parse(ref, kind: "field")?.ref, ref)
    }

    func testNonCanonicalRefsParseToNil() {
        let invalid: [(kind: String, ref: String)] = [
            ("image", "nouuid/0123"),
            ("image", "11111111-2222-3333-4444-555555555555"),
            ("image", "11111111-2222-3333-4444-55555555AAAA/0123456789abcdef"),
            ("image", "not-a-uuid/0123456789abcdef"),
            ("image", "nouuid/0123456789ABCDEF"),
            ("image", "nouuid/0123456789abcdef/extra"),
            ("address", "0x0010"),
            ("range", "0x20..<0x10"),
            ("range", "0x10..0x20"),
            ("range", "0x10..<"),
            ("function", "name:main"),
            ("function", "main"),
            ("type", "Point"),
            ("type", "name:"),
            ("protocol", "0X10"),
            ("metadataRecord", "0x8000"),
            ("metadataRecord", "@0x8000"),
            ("metadataRecord", "__swift5_types@8000"),
            ("selector", ""),
            ("selector", "a b"),
            ("viewBody", "name:body"),
            ("field", "0x8010"),
            ("field", "0x8010#01"),
            ("field", "0x8010#"),
            ("field", "0x8010."),
            ("field", "Point.x"),
            ("bogus", "0x10"),
        ]
        for (kind, ref) in invalid {
            XCTAssertNil(NavigatorSubjectRef.parse(ref, kind: kind), "\(kind) \(ref)")
            XCTAssertFalse(NavigatorSubjectRef.isCanonical(ref, kind: kind), "\(kind) \(ref)")
        }
    }

    func testSelectorMayLookLikeTheNamedForm() {
        // A selector ref is the raw selector string; `name:` is an ordinary one-argument selector.
        XCTAssertEqual(NavigatorSubjectRef.selector("name:"), "name:")
        XCTAssertEqual(NavigatorSubjectRef.parse("name:", kind: "selector"), .selector("name:"))
    }

    func testValidateCanonicalRefsReportsOnlyNonCanonicalSubjects() throws {
        typealias JSON = NavigatorJSONValue
        let image = NavigatorSubjectRef.imageRef(try Self.identity(uuid: nil))
        func record(_ kind: String, subjectKind: String, ref: String, image: String? = nil) -> JSON {
            var subject: [String: JSON] = ["kind": .string(subjectKind), "ref": .string(ref)]
            if let image { subject["image"] = .string(image) }
            return .object(["kind": .string(kind), "subject": .object(subject)])
        }

        XCTAssertEqual(NavigatorContractValidator.validateCanonicalRefs(record("Fact", subjectKind: "type", ref: "0x8010", image: image)), [])
        XCTAssertEqual(NavigatorContractValidator.validateCanonicalRefs(record("Fact", subjectKind: "type", ref: "name:Mod.Point")), [])
        XCTAssertEqual(
            NavigatorContractValidator.validateCanonicalRefs(record("Fact", subjectKind: "type", ref: "0x08010")),
            ["$.subject.ref: not canonical for kind type"]
        )
        XCTAssertEqual(
            NavigatorContractValidator.validateCanonicalRefs(record("FrontierItem", subjectKind: "metadataRecord", ref: "0x8000", image: "Fixture")),
            ["$.subject.ref: not canonical for kind metadataRecord", "$.subject.image: not a canonical image ref"]
        )

        let state: JSON = .object([
            "kind": .string("NavigatorEngineState"),
            "facts": .array([record("Fact", subjectKind: "field", ref: "0x8010.count", image: image)]),
            "frontier": .array([record("FrontierItem", subjectKind: "protocol", ref: "Equatable")]),
            "annotations": .array([record("Annotation", subjectKind: "function", ref: "0x100003f20")]),
        ])
        XCTAssertEqual(
            NavigatorContractValidator.validateCanonicalRefs(state),
            ["state.frontier[0].subject.ref: not canonical for kind protocol"]
        )

        let result: JSON = .object([
            "kind": .string("PrimitiveResult"),
            "subject": .object(["kind": .string("function"), "ref": .string("0x4000")]),
            "facts": .array([record("Fact", subjectKind: "selector", ref: "a b")]),
            "frontier": .array([]),
        ])
        XCTAssertEqual(
            NavigatorContractValidator.validateCanonicalRefs(result),
            ["$.facts[0].subject.ref: not canonical for kind selector"]
        )
        XCTAssertEqual(NavigatorContractValidator.validateCanonicalRefs(.object(["kind": .string("Other")])), ["$: unknown record kind"])
    }
}
