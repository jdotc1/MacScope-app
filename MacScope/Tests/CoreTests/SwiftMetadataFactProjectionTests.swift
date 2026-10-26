import XCTest

/// N1: `SwiftMetadataFactProjection` turns parser output into contract v1 facts and frontier items.
final class SwiftMetadataFactProjectionTests: XCTestCase {
    private func project(_ types: [SwiftTypeDescriptor], _ conformances: [SwiftConformance] = [],
                         _ diagnostics: [MetadataParseDiagnostic] = []) -> SwiftMetadataFactProjection.Output {
        SwiftMetadataFactProjection.project(types: types, conformances: conformances, diagnostics: diagnostics,
                                            image: "Fixture", toolchain: "test")
    }

    func testTypesFieldsAndConformancesBecomeValidAuthoritativeFacts() throws {
        let point = SwiftTypeDescriptor(kind: .struct, name: "Point", fields: [
            SwiftField(name: "x", typeName: "Double", mangledTypeName: "Sd", isVar: true),
            SwiftField(name: "tag", typeName: nil, mangledTypeName: "\u{2026}", isVar: false),
        ], descriptorAddress: 0x1000)
        let flag = SwiftTypeDescriptor(kind: .enum, name: "Flag", fields: [SwiftField(name: "on")], descriptorAddress: 0x2000)
        let output = project([point, flag], [SwiftConformance(typeName: "Point", protocolName: "Equatable",
                                                              descriptorAddress: 0x3000, typeDescriptorAddress: 0x1000,
                                                              protocolQualifiedName: "Swift.Equatable")])
        XCTAssertEqual(output.refused, [])
        let byPredicate = Dictionary(grouping: output.facts, by: \.predicate).mapValues(\.count)
        XCTAssertEqual(byPredicate, ["hasName": 2, "nominalKind": 2, "storedField": 2, "enumCase": 1, "conformsTo": 1])
        XCTAssertTrue(output.facts.allSatisfy { $0.status == "authoritative" })
        let conformance = try XCTUnwrap(output.facts.first { $0.predicate == "conformsTo" })
        XCTAssertEqual(conformance.subject, NavigatorSubject(kind: "type", ref: "0x1000", image: "Fixture"))
        // The unnamed field type is a gap, not a guess; the payload-less case is not.
        XCTAssertEqual(output.frontier.map(\.gap), ["unknownType"])
        let state = NavigatorEngineState(toolchain: "test", facts: output.facts, frontier: output.frontier)
        XCTAssertEqual(NavigatorContractValidator.validateState(state.json), [])
    }

    func testEnumIndirectProjectionUsesIndirectCaseBitAndDecodesLegacyFields() throws {
        let data = Data("""
        [
          {"name":"mutable","isVar":true,"isIndirectCase":false},
          {"name":"indirect","isVar":false,"isIndirectCase":true},
          {"name":"legacy","isVar":false}
        ]
        """.utf8)
        let fields = try JSONDecoder().decode([SwiftField].self, from: data)
        XCTAssertThrowsError(
            try JSONDecoder().decode(SwiftField.self, from: Data("{\"name\":\"missing-var\"}".utf8))
        )
        let output = project([
            SwiftTypeDescriptor(kind: .enum, name: "Flags", fields: fields, descriptorAddress: 0x2100),
        ])
        let cases = output.facts.filter { $0.predicate == "enumCase" }.map {
            ($0.value["name"]?.stringValue, $0.value["indirect"]?.boolValue)
        }

        XCTAssertEqual(cases.map(\.0), ["mutable", "indirect", "legacy"])
        XCTAssertEqual(cases.map(\.1), [false, true, false])
    }

    func testUnknownKindsExternalTypesAndDiagnosticsStayOnTheFrontier() {
        let odd = SwiftTypeDescriptor(kind: .unknown, name: "Odd", rawKind: 21, descriptorAddress: 0x10)
        let external = SwiftConformance(typeName: "Elsewhere", protocolName: "Hashable", descriptorAddress: 0x20)
        let diagnostic = MetadataParseDiagnostic(grade: .abandonedList, address: 0x30, message: "unreadable")
        let output = project([odd], [external], [diagnostic])
        XCTAssertFalse(output.facts.contains { $0.subject.ref == "0x10" })
        XCTAssertEqual(Set(output.frontier.map(\.gap)), ["unknownContext", "unresolvedTypeReference", "unresolvedProtocol", "malformedFieldDescriptor"])
        XCTAssertEqual(output.facts.first { $0.predicate == "conformsTo" }?.subject.ref, "name:Elsewhere")
    }

    func testQualifiedNamesFeedHasNameAndConformsToAndUnresolvedProtocolsStaySimpleOnTheFrontier() throws {
        let inner = SwiftTypeDescriptor(kind: .struct, name: "Inner", descriptorAddress: 0x1000, qualifiedName: "Mod.Outer.Inner")
        let bare = SwiftTypeDescriptor(kind: .struct, name: "Bare", descriptorAddress: 0x2000)
        func conformance(_ protocolName: String, _ qualified: String?) -> SwiftConformance {
            SwiftConformance(typeName: "Inner", protocolName: protocolName, descriptorAddress: 0x3000,
                             typeDescriptorAddress: 0x1000, protocolQualifiedName: qualified)
        }
        let output = project([inner, bare], [conformance("Proto", "OtherMod.Proto"), conformance("Equatable", "Swift.Equatable"),
                                             conformance("Orphan", nil)])
        XCTAssertEqual(output.refused, [])
        let names = output.facts.filter { $0.predicate == "hasName" }.map(\.value)
        XCTAssertEqual(names, [.string("Mod.Outer.Inner"), .string("Bare")])
        let conforms = output.facts.filter { $0.predicate == "conformsTo" }.map(\.value)
        XCTAssertEqual(conforms, [.string("OtherMod.Proto"), .string("Swift.Equatable"), .string("Orphan")])
        XCTAssertEqual(output.frontier.map(\.gap), ["unresolvedProtocol"])
        XCTAssertEqual(output.frontier.first?.subject, NavigatorSubject(kind: "protocol", ref: "name:Orphan", image: "Fixture"))
        let state = NavigatorEngineState(toolchain: "test", facts: output.facts, frontier: output.frontier)
        XCTAssertEqual(NavigatorContractValidator.validateState(state.json), [])
    }

    func testUnresolvedSymbolicFieldReportsItsReasonAndResolvedOnesLeaveNoGap() throws {
        let host = SwiftTypeDescriptor(kind: .struct, name: "Host", fields: [
            SwiftField(name: "resolved", typeName: "Target", mangledTypeName: "\u{2026}", isVar: false),
            SwiftField(name: "pending", typeName: nil, mangledTypeName: "\u{2026}", isVar: false, unresolvedReason: "needsFixup"),
        ], descriptorAddress: 0x1000)
        let output = project([host])
        XCTAssertEqual(output.refused, [])
        let gaps = output.frontier.filter { $0.gap == "unknownType" }
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.subject.ref, "0x1000.pending")
        XCTAssertTrue(try XCTUnwrap(gaps.first).detail.contains("reason needsFixup"))
    }

    func testUnresolvedSuperclassIsUnknownWithReasonWhileResolvedSuperclassIsAuthoritative() throws {
        let resolved = SwiftTypeDescriptor(kind: .class, name: "Resolved", descriptorAddress: 0x100, superclass: "Base")
        let pending = SwiftTypeDescriptor(kind: .class, name: "Pending", descriptorAddress: 0x200, superclass: "…",
                                          superclassUnresolvedReason: "needsFixup")
        let output = project([resolved, pending])
        XCTAssertEqual(output.refused, [])
        let facts = output.facts.filter { $0.predicate == "superclass" }
        XCTAssertEqual(facts.map(\.value), [.string("Base"), .null])
        XCTAssertEqual(facts.map(\.status), ["authoritative", "unknown"])
        XCTAssertEqual(facts.filter { $0.status == "authoritative" }.map(\.subject.ref), ["0x100"])
        XCTAssertEqual(output.frontier.map(\.gap), ["unknownType"])
        XCTAssertEqual(output.frontier.map(\.subject.ref), ["0x200"])
        XCTAssertEqual(output.frontier.map(\.detail), ["superclass; mangled …; reason needsFixup"])
        let state = NavigatorEngineState(toolchain: "test", facts: output.facts, frontier: output.frontier)
        XCTAssertEqual(NavigatorContractValidator.validateState(state.json), [])
        let decoded = try JSONDecoder().decode(SwiftTypeDescriptor.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(decoded.superclassUnresolvedReason, "needsFixup")
    }

    func testNewFactsProjectAsAuthoritativeValidBooleansAndStrings() throws {
        let child = SwiftTypeDescriptor(kind: .class, name: "Child", descriptorAddress: 0x100, superclass: "Base",
                                        isGeneric: true, isPrivateOrLocal: true, isImportedCType: true)
        let plain = SwiftTypeDescriptor(kind: .struct, name: "Plain", descriptorAddress: 0x200, isGeneric: false,
                                        isPrivateOrLocal: false, isImportedCType: false)
        let handBuilt = SwiftTypeDescriptor(kind: .struct, name: "Old", descriptorAddress: 0x300)
        let output = SwiftMetadataFactProjection.project(
            types: [child, plain, handBuilt], conformances: [], diagnostics: [],
            protocols: [SwiftProtocolDescriptor(name: "Speaker", descriptorAddress: 0x400)], image: "Fixture", toolchain: "test")
        XCTAssertEqual(output.refused, [])
        func values(_ predicate: String) -> [String: NavigatorJSONValue] {
            Dictionary(uniqueKeysWithValues: output.facts.filter { $0.predicate == predicate }.map { ($0.subject.ref, $0.value) })
        }
        XCTAssertEqual(values("superclass"), ["0x100": .string("Base")])
        XCTAssertEqual(values("isGeneric"), ["0x100": .bool(true), "0x200": .bool(false)])
        XCTAssertEqual(values("isPrivateOrLocal"), ["0x100": .bool(true)], "positive-only; nil and false record nothing")
        XCTAssertEqual(values("isImportedCType"), ["0x100": .bool(true)])
        XCTAssertEqual(values("isProtocol"), ["0x400": .bool(true)])
        XCTAssertEqual(output.facts.first { $0.predicate == "isProtocol" }?.subject.kind, "protocol")
        XCTAssertTrue(output.facts.allSatisfy { $0.status == "authoritative" })
        let state = NavigatorEngineState(toolchain: "test", facts: output.facts, frontier: output.frontier)
        XCTAssertEqual(NavigatorContractValidator.validateState(state.json), [])
    }

    /// Rule version 2 changes every projected fact id (the id digests `rule@ruleVersion`). The
    /// preimage is spelled out so the digest can be recomputed outside Swift.
    func testRuleVersionTwoFactIdIsPinned() throws {
        XCTAssertEqual(SwiftMetadataFactProjection.ruleVersion, "2")
        let point = SwiftTypeDescriptor(kind: .struct, name: "Point", descriptorAddress: 0x1000)
        let output = project([point])
        let fact = try XCTUnwrap(output.facts.first { $0.predicate == "hasName" })
        XCTAssertEqual(fact.provenance.first?.ruleVersion, "2")
        let preimage = #"[{"image":"Fixture","kind":"type","ref":"0x1000"},"hasName","Point","macscope.swift-metadata-parser@2"]"#
        let payload: NavigatorJSONValue = .array([fact.subject.json, .string("hasName"), .string("Point"),
                                                  .string("macscope.swift-metadata-parser@2")])
        XCTAssertEqual(try NavigatorJSONCanonical.encode(payload), preimage)
        XCTAssertEqual(fact.id, try NavigatorJSONCanonical.digest("f", payload))
        let versionOne = try NavigatorFact.id(
            subject: fact.subject, predicate: "hasName", value: .string("Point"),
            provenance: [NavigatorProvenance(kind: "metadataRecord", ref: "__swift5_types descriptor 0x1000",
                                             rule: SwiftMetadataFactProjection.rule, ruleVersion: "1")])
        XCTAssertNotEqual(fact.id, versionOne)
        // printf '%s' "$preimage" | shasum -a 256 | cut -c1-32, prefixed "f-".
        XCTAssertEqual(fact.id, "f-5d6bb593d906b30391eb4fd703844e6c")
    }

    func testGenerationAndDependsOnAreStampedOnEveryRecordAndSubjectRefsAreCanonical() throws {
        let generation = NavigatorGeneration(imageIdentity: "nouuid/0123456789abcdef",
                                             inputKey: String(repeating: "a", count: 64),
                                             knowledgeVersion: String(repeating: "b", count: 64))
        let host = SwiftTypeDescriptor(kind: .struct, name: "Host", fields: [
            SwiftField(name: "pending", typeName: nil, mangledTypeName: "\u{2026}", isVar: false),
        ], descriptorAddress: 0x1000)
        let output = SwiftMetadataFactProjection.project(
            types: [host], conformances: [SwiftConformance(typeName: "Elsewhere", protocolName: "Hashable", descriptorAddress: 0x20)],
            diagnostics: [], protocols: [SwiftProtocolDescriptor(name: "Speaker", descriptorAddress: 0x400)],
            image: "nouuid/0123456789abcdef", toolchain: "test", generation: generation,
            dependsOn: ["relocations", "machOLoadMetadata"])
        XCTAssertEqual(output.refused, [])
        XCTAssertFalse(output.facts.isEmpty)
        XCTAssertFalse(output.frontier.isEmpty)
        for fact in output.facts {
            XCTAssertEqual(fact.generation, generation)
            XCTAssertEqual(fact.dependsOn, ["machOLoadMetadata", "relocations"])
            XCTAssertEqual(NavigatorContractValidator.validate(fact.json).warnings, [], fact.subject.ref)
        }
        for item in output.frontier {
            XCTAssertEqual(item.generation, generation)
            XCTAssertEqual(item.dependsOn, ["machOLoadMetadata", "relocations"])
            XCTAssertEqual(NavigatorContractValidator.validate(item.json).warnings, [], item.subject.ref)
        }
        XCTAssertEqual(Set(output.frontier.map(\.subject.ref)), ["0x1000.pending", "name:Elsewhere", "name:Hashable"])
        let state = NavigatorEngineState(toolchain: "test", facts: output.facts, frontier: output.frontier)
        XCTAssertEqual(NavigatorContractValidator.validateState(state.json), [])
    }
}
