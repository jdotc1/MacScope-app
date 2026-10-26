import Foundation
import XCTest
@testable import MacScope

final class EntitlementExactDecodingTests: XCTestCase {
    func testXMLPreservesCanonicalKeysAndExactScalarTypes() throws {
        let result = exactXML("""
        <key>é</key><string>NFC</string><key>e\u{301}</key><string>NFD</string>
        <key>unsigned</key><integer>18446744073709551615</integer>
        <key>bool</key><true/><key>one</key><integer>1</integer>
        <key>negativeZero</key><real>-0.0</real><key>positiveZero</key><real>0.0</real>
        <key>forward</key><array><string>a</string><string>b</string></array>
        <key>reverse</key><array><string>b</string><string>a</string></array>
        """)
        XCTAssertEqual(result.state, .dictionaryPresent)
        XCTAssertEqual(result.format, "XML")
        XCTAssertNil(result.reason)
        let values = try XCTUnwrap(result.values)
        XCTAssertEqual(values.entries.count, 9)
        XCTAssertEqual(values["é"], .string("NFC"))
        XCTAssertEqual(values["e\u{301}"], .string("NFD"))
        XCTAssertEqual(values["unsigned"], .unsignedInteger(.max))
        XCTAssertEqual(values["bool"], .boolean(true))
        XCTAssertEqual(values["one"], .integer(1))
        XCTAssertNotEqual(values["bool"], values["one"])
        XCTAssertEqual(values["negativeZero"], .real(Double(bitPattern: 0x8000_0000_0000_0000)))
        XCTAssertEqual(values["positiveZero"], .real(Double(bitPattern: 0)))
        XCTAssertNotEqual(values["negativeZero"], values["positiveZero"])
        XCTAssertEqual(values["forward"], .array([.string("a"), .string("b")]))
        XCTAssertEqual(values["reverse"], .array([.string("b"), .string("a")]))
        XCTAssertNotEqual(values["forward"], values["reverse"])
    }

    func testFoundationRejectsLossyNumbersAndDates() throws {
        let decoder = FoundationEntitlementDecoder(limits: .init(maxDepth: 16, maxNodes: 4096, maxBytes: 262144))
        XCTAssertThrowsError(try decoder.decode(NSDictionary(object: NSDecimalNumber(string: "1.25"), forKey: "v" as NSString))) {
            XCTAssertEqual($0 as? EntitlementDataError, .unsupportedType("NSDecimalNumber"))
        }
        XCTAssertThrowsError(try decoder.decode(NSDictionary(object: NSNumber(value: Double.infinity), forKey: "v" as NSString))) {
            XCTAssertEqual($0 as? EntitlementDataError, .nonFiniteNumber)
        }
        XCTAssertThrowsError(try decoder.decode(NSDictionary(object: Date(timeIntervalSinceReferenceDate: .infinity), forKey: "v" as NSString))) {
            XCTAssertEqual($0 as? EntitlementDataError, .nonFiniteDate)
        }
        let date = Date(timeIntervalSinceReferenceDate: 123.5)
        XCTAssertEqual(try decoder.decode(NSDictionary(object: date, forKey: "v" as NSString))["v"], .date(date))
    }

    func testDERPreservesSupportedExactValues() throws {
        let payload = derDictionary([
            ("bool", tlv(0x01, [0xff])),
            ("text", tlv(0x0c, Array("é".utf8))),
            ("negative", tlv(0x02, [0xff])),
            ("minimum", tlv(0x02, [0x80] + Array(repeating: 0, count: 7))),
            ("maximum", tlv(0x02, [0x7f] + Array(repeating: 0xff, count: 7))),
            ("unsigned", tlv(0x02, [0] + Array(repeating: 0xff, count: 8))),
            ("list", tlv(0x30, tlv(0x0c, [0x62]) + tlv(0x0c, [0x61])))
        ])
        let result = exact(payload, der: true)
        XCTAssertEqual(result.state, .dictionaryPresent)
        XCTAssertEqual(result.format, "DER")
        XCTAssertNil(result.reason)
        let values = try XCTUnwrap(result.values)
        XCTAssertEqual(values.entries.count, 7)
        XCTAssertEqual(values["bool"], .boolean(true))
        XCTAssertEqual(values["text"], .string("é"))
        XCTAssertEqual(values["negative"], .integer(-1))
        XCTAssertEqual(values["minimum"], .integer(.min))
        XCTAssertEqual(values["maximum"], .integer(.max))
        XCTAssertEqual(values["unsigned"], .unsignedInteger(.max))
        XCTAssertEqual(values["list"], .array([.string("b"), .string("a")]))
    }

    func testDERRejectsUnsupportedMalformedAndOversizeValues() {
        let malformed: [Data] = [
            derDictionary([("v", tlv(0x04, [1]))]),
            Data([0x31, 0x80, 0, 0]),
            Data([0x31, 0x81, 0]),
            derDictionary([("v", tlv(0x01, [0xff])), ("v", tlv(0x01, [0]))]),
            derDictionary([]) + Data([0]),
            derDictionary([("v", tlv(0x0c, [0xff]))]),
            derDictionary([("v", tlv(0x01, [1]))]),
            derDictionary([("v", tlv(0x02, [0, 1]))]),
            derDictionary([("v", tlv(0x02, [1] + Array(repeating: 0, count: 8)))]),
            derDictionary([("v", tlv(0x02, [0] + Array(repeating: 0xff, count: 9)))]),
            derDictionary([("v", tlv(0x31, tlv(0x01, [0xff])))])
        ]
        for payload in malformed { assertUnavailable(exact(payload, der: true)) }
    }

    func testEveryBoundRejectsWholeDictionary() {
        assertUnavailable(exact(Data(repeating: 0x20, count: 262_145)), reasonContains: "payload")
        let deep = String(repeating: "<array>", count: 16) + "<string>x</string>" + String(repeating: "</array>", count: 16)
        assertUnavailable(exactXML("<key>deep</key>" + deep), reasonContains: "nesting depth")
        let many = String(repeating: "<string>x</string>", count: 4_095)
        assertUnavailable(exactXML("<key>many</key><array>" + many + "</array>"), reasonContains: "node count")
        let keys = (0..<257).map { "<key>k\($0)</key><true/>" }.joined()
        assertUnavailable(exactXML(keys), reasonContains: "top-level key count")
        assertUnavailable(exact(derDictionary((0..<257).map { ("k\($0)", tlv(0x01, [0xff])) }), der: true),
                          reasonContains: "top-level key count")
        let strings = Array(repeating: tlv(0x0c, [0x78]), count: 4_095).flatMap { $0 }
        assertUnavailable(exact(derDictionary([("many", tlv(0x30, strings))]), der: true), reasonContains: "node count")
    }

    func testStatesAndFormatPreferenceRemainDistinct() throws {
        let absent = input([])
        XCTAssertEqual(EntitlementValueReader.readExact(signature: absent.0, sliceBytes: absent.1),
                       .init(state: .notPresent, values: nil, reason: nil, format: nil))
        let empty = exactXML("")
        XCTAssertEqual(empty.state, .dictionaryPresent)
        XCTAssertEqual(empty.values?.entries, [])
        XCTAssertNil(empty.reason)
        XCTAssertEqual(empty.format, "XML")
        assertUnavailable(EntitlementValueReader.readExact(signature: nil, sliceBytes: Data()))
        assertUnavailable(exact(Data("broken".utf8)))
        let der = derDictionary([("derOnly", tlv(0x01, [0xff]))])
        let xml = xmlData("<key>xmlOnly</key><true/>")
        let combined = input([(true, der), (false, xml)])
        let preferred = EntitlementValueReader.readExact(signature: combined.0, sliceBytes: combined.1)
        XCTAssertEqual(preferred.format, "XML")
        XCTAssertEqual(preferred.values, EntitlementDictionary(["xmlOnly": .boolean(true)]))
        let fallback = input([(false, Data("broken".utf8)), (true, der)])
        let recovered = EntitlementValueReader.readExact(signature: fallback.0, sliceBytes: fallback.1)
        XCTAssertEqual(recovered.format, "DER")
        XCTAssertEqual(recovered.values, EntitlementDictionary(["derOnly": .boolean(true)]))
    }

    func testLegacyReaderConcreteOutputsRemainUnchanged() throws {
        let payload = xmlData("""
        <key>bool</key><true/><key>one</key><integer>1</integer>
        <key>unsigned</key><integer>18446744073709551615</integer>
        <key>zero</key><real>-0.0</real>
        <key>array</key><array><string>b</string><string>a</string></array>
        """)
        let source = input([(false, payload)])
        let before = EntitlementValueReader.read(signature: source.0, sliceBytes: source.1)
        XCTAssertEqual(before, .init(state: .parsed, format: "XML", values: [
            "bool": .boolean(true), "one": .integer(1), "unsigned": .integer(-1),
            "zero": .real(-0.0), "array": .array([.string("b"), .string("a")])
        ], reason: nil))
        XCTAssertEqual(EntitlementValueReader.readExact(signature: source.0, sliceBytes: source.1).values?["unsigned"],
                       .unsignedInteger(.max))
        let after = EntitlementValueReader.read(signature: source.0, sliceBytes: source.1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(before), try encoder.encode(after))
        let empty = input([(false, xmlData(""))])
        XCTAssertEqual(EntitlementValueReader.read(signature: empty.0, sliceBytes: empty.1),
                       .init(state: .parsed, format: "XML", values: [:], reason: nil))
        let absent = input([])
        XCTAssertEqual(EntitlementValueReader.read(signature: absent.0, sliceBytes: absent.1),
                       .init(state: .absent, format: nil, values: [:], reason: nil))
        let malformed = input([(false, Data("broken".utf8))])
        XCTAssertEqual(EntitlementValueReader.read(signature: malformed.0, sliceBytes: malformed.1),
                       .init(state: .unparsed, format: "XML", values: [:], reason: "XML values could not be decoded completely"))
    }

    // The adjacent fixture README records the exact codesign generation commands.
    // Decode producer bytes through both public readers; no constructed TLV replaces this witness.
    func testCodesignFixtureDecodesExactlyInBothReaders() throws {
        let payload = try codesignFixture()
        let source = input([(true, payload)])
        let expected: [String: DeclaredEntitlementValue] = [
            "bool-true": .boolean(true), "bool-false": .boolean(false), "integer": .integer(42),
            "string": .string("fixture é"), "array": .array([.string("second"), .string("first")]),
            "nested": .dictionary(["count": .integer(-7), "enabled": .boolean(true), "label": .string("child")])
        ]
        XCTAssertEqual(EntitlementValueReader.read(signature: source.0, sliceBytes: source.1),
                       .init(state: .parsed, format: "DER", values: expected, reason: nil))
        let exact = EntitlementValueReader.readExact(signature: source.0, sliceBytes: source.1)
        XCTAssertEqual(exact.state, .dictionaryPresent)
        XCTAssertEqual(exact.format, "DER")
        XCTAssertNil(exact.reason)
        XCTAssertEqual(exact.values, EntitlementDictionary([
            "bool-true": .boolean(true), "bool-false": .boolean(false), "integer": .integer(42),
            "string": .string("fixture é"), "array": .array([.string("second"), .string("first")]),
            "nested": .dictionary(EntitlementDictionary([
                "count": .integer(-7), "enabled": .boolean(true), "label": .string("child")]))
        ]))

        // The model points at the header at a nonzero slice offset. Strip exactly once.
        var shifted = source.0
        shifted.superBlob?.blobs[0].fileOffset = 13
        let bytes = Data(repeating: 0xa5, count: 13) + source.1
        XCTAssertEqual(EntitlementValueReader.read(signature: shifted, sliceBytes: bytes).values, expected)
        XCTAssertEqual(EntitlementValueReader.readExact(signature: shifted, sliceBytes: bytes).values, exact.values)
        assertBothRefuse(source.1) // A second CS header must not be silently stripped by DER.
    }

    func testDEREnvelopeAndNestedMalformedValuesFailClosedInBothReaders() throws {
        let fixture = try codesignFixture()
        var wrongVersion = fixture
        wrongVersion[5] = 2
        var wrongDictionary = fixture
        wrongDictionary[6] = 0x31
        let pair = tlv(0x30, tlv(0x0c, [0x76]) + tlv(0x01, [0xff]))
        let malformed: [Data] = [
            wrongVersion, wrongDictionary, Data(fixture.dropLast()), fixture + Data([0]),
            Data(tlv(0x70, tlv(0x02, [0, 1]) + dictionary([]))),
            Data(tlv(0x70, tlv(0x02, [1]) + dictionary([]) + [0])),
            Data(tlv(0x70, tlv(0x02, [1]) + tlv(0x30, []))),
            Data(tlv(0x70, tlv(0x02, [1]) + tlv(0xb0, pair + [0]))),
            Data(tlv(0x70, tlv(0x02, [1]) + tlv(0xb0, tlv(0x30, tlv(0x0c, [0x76]) + tlv(0x01, [0xff]) + [0])))),
            Data([0x70, 0x80, 0, 0]), Data([0x70, 0x81, 5, 2, 1, 1, 0xb0, 0]),
            Data([0x70, 0x82, 0, 5, 2, 1, 1, 0xb0, 0]),
            Data(tlv(0x70, tlv(0x02, [1]) + [0xb0, 0x80, 0, 0])),
            derDictionary([("", tlv(0x01, [0xff]))]),
            Data(tlv(0x70, tlv(0x02, [1]) + tlv(0xb0, tlv(0x30, tlv(0x0c, [0xff]) + tlv(0x01, [0xff]))))),
            derDictionary([("v", tlv(0x0c, [0xff]))]),
            derDictionary([("v", tlv(0x01, [1]))]),
            derDictionary([("v", tlv(0x02, [0xff, 0xff]))]),
            derDictionary([("v", tlv(0x0c, [0x61])), ("v", tlv(0x01, [0]))]),
            derDictionary([("v", dictionary([("x", tlv(0x01, [0])), ("x", tlv(0x01, [0xff]))]))]),
            derDictionary([("v", dictionary([("", tlv(0x01, [0xff]))]))]),
            derDictionary([("v", tlv(0x31, []))]),
            derDictionary([("v", tlv(0x04, [0]))]),
            derDictionary([("v", [0x0c, 0x81, 1, 0x61])]),
            Data(tlv(0x31, tlv(0x30, tlv(0x0c, [0x76]) + tlv(0x31, tlv(0x0c, [0x61])))))
        ]
        for (index, payload) in malformed.enumerated() {
            assertBothRefuse(payload, context: "malformed case \(index)")
        }
    }

    func testDERDepthEntryNodeAndByteLimitsInBothReaders() {
        let text = tlv(0x0c, [0x78])
        var deep = text
        for _ in 0..<15 { deep = tlv(0x30, deep) }
        let acceptedDepth = input([(true, derDictionary([("deep", deep)]))])
        XCTAssertEqual(EntitlementValueReader.read(signature: acceptedDepth.0, sliceBytes: acceptedDepth.1).state, .parsed)
        XCTAssertEqual(EntitlementValueReader.readExact(signature: acceptedDepth.0, sliceBytes: acceptedDepth.1).state, .dictionaryPresent)
        assertBothRefuse(derDictionary([("deep", tlv(0x30, deep))]), reasonContains: "nesting depth")
        var nested = text
        for _ in 0..<16 { nested = dictionary([("child", nested)]) }
        assertBothRefuse(derDictionary([("deep", nested)]), reasonContains: "nesting depth")
        let keys = (0..<256).map { ("k\($0)", tlv(0x01, [0xff])) }
        let acceptedKeys = input([(true, derDictionary(keys))])
        XCTAssertEqual(EntitlementValueReader.read(signature: acceptedKeys.0, sliceBytes: acceptedKeys.1).values.count, 256)
        XCTAssertEqual(EntitlementValueReader.readExact(signature: acceptedKeys.0, sliceBytes: acceptedKeys.1).values?.entries.count, 256)
        assertBothRefuse(derDictionary(keys + [("overflow", tlv(0x01, [0xff]))]), reasonContains: "top-level key count")
        let nodes = Array(repeating: text, count: 4_094).flatMap { $0 }
        let acceptedNodes = input([(true, derDictionary([("many", tlv(0x30, nodes))]))])
        XCTAssertEqual(EntitlementValueReader.read(signature: acceptedNodes.0, sliceBytes: acceptedNodes.1).state, .parsed)
        XCTAssertEqual(EntitlementValueReader.readExact(signature: acceptedNodes.0, sliceBytes: acceptedNodes.1).state, .dictionaryPresent)
        assertBothRefuse(derDictionary([("many", tlv(0x30, nodes + text))]), reasonContains: "node count")
        // One global budget across sibling containers, not a fresh budget per array.
        let half = Array(repeating: text, count: 2_047).flatMap { $0 }
        assertBothRefuse(derDictionary([("a", tlv(0x30, half)), ("b", tlv(0x30, half))]), reasonContains: "node count")
        assertBothRefuse(Data(repeating: 0, count: 262_145), reasonContains: "payload")
    }

    func testHistoricalSecurityDictionaryCompatibilityAndModelLimits() throws {
        // Real historical signer format documented beside the current codesign fixture.
        let legacy = Data(dictionary([
            ("a", tlv(0x30, tlv(0x0c, [0x62]) + tlv(0x0c, [0x61]))),
            ("b", dictionary([("v", tlv(0x01, [0xff]))], tag: 0x31))
        ], tag: 0x31))
        let source = input([(true, legacy)])
        XCTAssertEqual(EntitlementValueReader.read(signature: source.0, sliceBytes: source.1).values,
                       ["a": .array([.string("b"), .string("a")]), "b": .dictionary(["v": .boolean(true)])])
        XCTAssertEqual(EntitlementValueReader.readExact(signature: source.0, sliceBytes: source.1).values,
                       EntitlementDictionary(["a": .array([.string("b"), .string("a")]),
                                              "b": .dictionary(EntitlementDictionary(["v": .boolean(true)]))]))
        let unicode = input([(true, derDictionary([("é", tlv(0x01, [0])), ("e\u{301}", tlv(0x01, [0xff]))]))])
        let exactKeys = EntitlementValueReader.readExact(signature: unicode.0, sliceBytes: unicode.1)
        XCTAssertEqual(exactKeys.values?.entries.count, 2)
        XCTAssertEqual(exactKeys.values?["é"], .boolean(false))
        XCTAssertEqual(exactKeys.values?["e\u{301}"], .boolean(true))
        let legacyKeys = EntitlementValueReader.read(signature: unicode.0, sliceBytes: unicode.1)
        XCTAssertEqual(legacyKeys.state, .unparsed)
        XCTAssertTrue(legacyKeys.values.isEmpty)
        let unsigned = input([(true, derDictionary([("v", tlv(0x02, [0] + Array(repeating: 0xff, count: 8)))]))])
        XCTAssertEqual(EntitlementValueReader.readExact(signature: unsigned.0, sliceBytes: unsigned.1).values?["v"], .unsignedInteger(.max))
        let legacyUnsigned = EntitlementValueReader.read(signature: unsigned.0, sliceBytes: unsigned.1)
        XCTAssertEqual(legacyUnsigned.state, .unparsed)
        XCTAssertTrue(legacyUnsigned.values.isEmpty)
    }

    private func codesignFixture() throws -> Data {
        try Data(contentsOf: TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("GoldenFixtures/entitlement-der/codesign-entitlements.der"))
    }

    private func dictionary(_ entries: [(String, [UInt8])], tag: UInt8 = 0xb0) -> [UInt8] {
        tlv(tag, entries.flatMap { tlv(0x30, tlv(0x0c, Array($0.0.utf8)) + $0.1) })
    }

    private func assertBothRefuse(_ payload: Data, reasonContains: String? = nil, context: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
        let source = input([(true, payload)])
        let main = EntitlementValueReader.read(signature: source.0, sliceBytes: source.1)
        XCTAssertEqual(main.state, .unparsed, context, file: file, line: line)
        XCTAssertTrue(main.values.isEmpty, context, file: file, line: line)
        XCTAssertFalse(main.reason?.isEmpty ?? true, context, file: file, line: line)
        assertUnavailable(EntitlementValueReader.readExact(signature: source.0, sliceBytes: source.1),
                          reasonContains: reasonContains, file: file, line: line)
    }

    private func assertUnavailable(_ result: ExactDeclaredEntitlements, reasonContains: String? = nil,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.state, .unavailable, file: file, line: line)
        XCTAssertNil(result.values, file: file, line: line)
        XCTAssertFalse(result.reason?.isEmpty ?? true, file: file, line: line)
        if let reasonContains { XCTAssertTrue(result.reason?.contains(reasonContains) == true, file: file, line: line) }
    }

    private func exactXML(_ contents: String) -> ExactDeclaredEntitlements { exact(xmlData(contents)) }
    private func xmlData(_ contents: String) -> Data {
        Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>" + contents + "</dict></plist>").utf8)
    }
    private func exact(_ payload: Data, der: Bool = false) -> ExactDeclaredEntitlements {
        let source = input([(der, payload)])
        return EntitlementValueReader.readExact(signature: source.0, sliceBytes: source.1)
    }
    private func input(_ forms: [(Bool, Data)]) -> (MachOCodeSignature, Data) {
        var bytes = Data()
        var blobs: [MachOCodeSignatureBlob] = []
        for (der, payload) in forms {
            let offset = bytes.count
            for word in [der ? MachOConstants.codeSignatureDerEntitlementsMagic : MachOConstants.codeSignatureEmbeddedEntitlementsMagic,
                         UInt32(payload.count + 8)] {
                var big = word.bigEndian
                withUnsafeBytes(of: &big) { bytes.append(contentsOf: $0) }
            }
            bytes.append(payload)
            blobs.append(.init(type: der ? MachOConstants.codeSignatureSlotDerEntitlements : MachOConstants.codeSignatureSlotEntitlements,
                relativeOffset: UInt32(offset), fileOffset: UInt64(offset),
                magic: der ? MachOConstants.codeSignatureDerEntitlementsMagic : MachOConstants.codeSignatureEmbeddedEntitlementsMagic,
                length: UInt32(payload.count + 8), codeDirectory: nil, entitlements: nil))
        }
        return (.init(dataOffset: 0, dataSize: UInt32(bytes.count), superBlob: .init(
            magic: MachOConstants.codeSignatureEmbeddedSignatureMagic, length: UInt32(bytes.count),
            blobCount: UInt32(blobs.count), blobs: blobs)), bytes)
    }
    private func derDictionary(_ entries: [(String, [UInt8])]) -> Data {
        Data(tlv(0x70, tlv(0x02, [1]) + dictionary(entries)))
    }
    private func tlv(_ tag: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        let length: [UInt8]
        if bytes.count < 128 { length = [UInt8(bytes.count)] }
        else if bytes.count <= 255 { length = [0x81, UInt8(bytes.count)] }
        else { length = [0x82, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)] }
        return [tag] + length + bytes
    }
}
