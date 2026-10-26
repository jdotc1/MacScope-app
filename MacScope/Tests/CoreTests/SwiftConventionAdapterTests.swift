import XCTest
@testable import MacScope

/// Schema-2 witnesses and bounded evidence invariants.
final class SwiftConventionAdapterTests: XCTestCase {
    typealias R = SwiftConventionReason

    struct Expected: Decodable {
        var convention: String
        var storage: String
        var contextIn: [String]
        var errorOut: String?
        var asyncContextIn: String?
        var abstentions: [String]
    }

    static func witnessURL() -> URL {
        TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SwiftConvention/witnesses.json")
    }

    func testEveryWitnessMatchesExpected() throws {
        let data = try Data(contentsOf: Self.witnessURL())
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(doc["schemaVersion"] as? Int, 2)
        let cases = try XCTUnwrap(doc["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 180)
        XCTAssertGreaterThanOrEqual(cases.filter { ($0["id"] as? String ?? "").hasPrefix("symbol:") }.count, 24)
        var failures: [String] = []
        var conventions = Set<String>()
        var codes = Set<String>()
        for c in cases {
            let id = c["id"] as? String ?? "?"
            let evObj = try XCTUnwrap(c["evidence"] as? [String: Any], id)
            let expData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["expected"], id))
            let exp = try JSONDecoder().decode(Expected.self, from: expData)
            let d = SwiftConventionAdapter.decide(try SwiftConventionCodec.evidence(from: evObj))
            conventions.insert(d.convention.rawValue)
            codes.formUnion(d.reasons); codes.formUnion(d.abstentions)
            if d.convention.rawValue != exp.convention { failures.append("\(id): convention \(exp.convention) != \(d.convention.rawValue)") }
            if d.storage.rawValue != exp.storage { failures.append("\(id): storage \(exp.storage) != \(d.storage.rawValue)") }
            if d.contextIn != exp.contextIn { failures.append("\(id): contextIn \(exp.contextIn) != \(d.contextIn)") }
            if d.errorOut != exp.errorOut { failures.append("\(id): errorOut") }
            if d.asyncContextIn != exp.asyncContextIn { failures.append("\(id): asyncContextIn") }
            if Set(d.abstentions) != Set(exp.abstentions) { failures.append("\(id): abstentions \(exp.abstentions) != \(d.abstentions)") }
        }
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
        XCTAssertEqual(conventions, ["cdecl", "swiftcall", "swiftasynccall", "abstain"])
        for code in [R.selfClassReference, R.selfArchetypeOrIndirect, R.selfInoutAddress, R.selfMetatypeThick,
                     R.selfMetatypeThin, R.selfStorageValueType, R.selfMutatingUnknown, R.selfKindUnknown,
                     R.errorFromThrows, R.typedThrowsErrorStorage, R.asyncErrorInResumeSwiftSelf,
                     R.contextSlotReservedForThrows, R.contextFromMetadataMethod] {
            XCTAssertTrue(codes.contains(code), code)
        }
    }

    func testObservationsAloneNeverSelect() {
        for bits in 0..<64 {
            var ev = SwiftBoundaryEvidence()
            ev.observations = SwiftBodyObservations(readsX20BeforeWrite: bits & 1 != 0, writesX21: bits & 2 != 0,
                                                    readsX22BeforeWrite: bits & 4 != 0)
            ev.callerEvidence = SwiftCallerEvidence(testsX21AfterCall: bits & 8 != 0, passesX22: bits & 16 != 0,
                                                    passesX20: bits & 32 != 0)
            let d = SwiftConventionAdapter.decide(ev)
            XCTAssertEqual(d.convention, .abstain)
            XCTAssertTrue(d.abstentions.contains(R.noHeaderFacts))
            XCTAssertEqual(d.tier, bits == 0 ? .header : .derived)
        }
    }

    func testRegisterInvariantsOverTheGrid() {
        let x20Reasons = Set(R.selfPositive + [R.closureContext, R.contextFromMetadataMethod])
        let selfAbstentions = Set(R.selfAbstentions)
        for bits in 0..<128 {
            var f = SwiftSymbolFacts()
            f.isFunction = bits & 1 != 0; f.isAsync = bits & 2 != 0; f.isThrowing = bits & 4 != 0
            f.isPartialApplyForwarder = bits & 8 != 0; f.isAsyncFunctionPointer = bits & 16 != 0
            f.isGeneric = bits & 32 != 0; f.hasNonScalarParameter = bits & 64 != 0
            for selfKind in [SwiftSelfKind.none, .instance, .static, .allocatingInit, .initializingInit, .deallocatingDeinit, .destroyingDeinit] {
                for nominal in [SwiftSelfNominalKind.none, .class, .struct, .enum, .protocol, .archetype, .unknown] {
                    for mutating in [Bool?.none, .some(false), .some(true)] {
                        f.selfKind = selfKind; f.selfNominalKind = nominal; f.isMutating = mutating
                        var ev = SwiftBoundaryEvidence(); ev.symbolFacts = f
                        let d = SwiftConventionAdapter.decide(ev)
                        if f.isAsyncFunctionPointer {
                            XCTAssertEqual(d.abstentions, [R.asyncFunctionPointerIsData])
                        }
                        if d.convention == .abstain {
                            XCTAssertEqual(d.contextIn, []); XCTAssertNil(d.errorOut); XCTAssertNil(d.asyncContextIn)
                            XCTAssertEqual(d.storage, .notClaimed)
                            continue
                        }
                        XCTAssertEqual(d.asyncContextIn == "x22", d.convention == .swiftasynccall)
                        XCTAssertEqual(d.errorOut == "x21", f.isThrowing && !f.isAsync)
                        XCTAssertEqual(d.reasons.contains(R.asyncErrorInResumeSwiftSelf), f.isThrowing && f.isAsync)
                        let hasX20 = d.contextIn == ["x20"]
                        XCTAssertEqual(hasX20, !x20Reasons.isDisjoint(with: d.reasons), "\(f) \(d)")
                        XCTAssertFalse(hasX20 && !selfAbstentions.isDisjoint(with: d.abstentions))
                        if f.isPartialApplyForwarder { XCTAssertTrue(hasX20) }
                        else if selfKind == .none { XCTAssertFalse(hasX20) }
                        else if selfKind == .instance && nominal == .class { XCTAssertTrue(hasX20) }
                        else if selfKind == .instance && (nominal == .struct || nominal == .enum) {
                            XCTAssertEqual(hasX20, mutating == true)
                        } else if (selfKind == .static || selfKind == .allocatingInit) && (nominal == .struct || nominal == .enum) {
                            XCTAssertFalse(hasX20); XCTAssertTrue(d.reasons.contains(R.selfMetatypeThin))
                        }
                        if f.isGeneric { XCTAssertEqual(d.storage, .abstainH07) }
                        // Metadata always yields a context pointer.
                        if !f.isPartialApplyForwarder {
                            ev.metadataMethod = SwiftMetadataMethodFacts(source: .witness, isInstance: true)
                            let m = SwiftConventionAdapter.decide(ev)
                            if m.convention != .abstain { XCTAssertEqual(m.contextIn, ["x20"]) }
                        }
                    }
                }
            }
        }
    }

    func testTypedThrowsAbstainsOnErrorStorage() throws {
        var f = SwiftSymbolFacts(); f.isFunction = true; f.isThrowing = true; f.thrownType = "M.E"
        var ev = SwiftBoundaryEvidence(); ev.symbolFacts = f
        let d = SwiftConventionAdapter.decide(ev)
        XCTAssertEqual(d.convention, .swiftcall)
        XCTAssertNil(d.errorOut)
        XCTAssertTrue(d.abstentions.contains(R.typedThrowsErrorStorage))
        XCTAssertEqual(d.storage, .abstainH03)
    }

    func testCodecRejectsUnknownKeysAndValues() {
        XCTAssertThrowsError(try SwiftConventionCodec.evidence(from: ["bogus": 1]))
        XCTAssertThrowsError(try SwiftConventionCodec.evidence(from: ["symbolFacts": ["isFunction": true, "callingConvention": "swift"]]))
        XCTAssertThrowsError(try SwiftConventionCodec.evidence(from: ["symbolFacts": ["selfKind": "self"]]))
        XCTAssertThrowsError(try SwiftConventionCodec.evidence(from: ["symbolFacts": ["selfKind": "staticOrClass"]]))
        XCTAssertThrowsError(try SwiftConventionCodec.evidence(from: ["symbolFacts": ["selfNominalKind": "actor"]]))
        XCTAssertThrowsError(try SwiftConventionCodec.evidence(from: ["symbolFacts": ["thrownTypeIsScalar": true]]))
        XCTAssertThrowsError(try SwiftConventionCodec.evidence(from: ["metadataMethod": ["source": "table"]]))
    }

    func testMutatingIsTriState() throws {
        XCTAssertNil(try SwiftConventionCodec.evidence(from: ["symbolFacts": [:] as [String: Any]]).symbolFacts?.isMutating)
        XCTAssertNil(try SwiftConventionCodec.evidence(from: ["symbolFacts": ["isMutating": NSNull()]]).symbolFacts?.isMutating)
        XCTAssertEqual(try SwiftConventionCodec.evidence(from: ["symbolFacts": ["isMutating": true]]).symbolFacts?.isMutating, true)
        XCTAssertEqual(try SwiftConventionCodec.evidence(from: ["symbolFacts": ["isMutating": false]]).symbolFacts?.isMutating, false)
    }
    func testDecisionCodecEmitsSchemaTwoAndExplicitNulls() throws {
        let object = SwiftConventionCodec.json(SwiftConventionDecision())
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "convention", "contextIn", "errorOut",
                                          "asyncContextIn", "indirectResult", "storage", "tier",
                                          "reasons", "abstentions"])
        XCTAssertTrue(object["errorOut"] is NSNull)
        XCTAssertTrue(object["asyncContextIn"] is NSNull)
        XCTAssertTrue(object["indirectResult"] is NSNull)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
    }


    func testCodecRejectsNonStringSelfKindInsteadOfClaimingNoSelf() {
        XCTAssertThrowsError(try SwiftConventionCodec.evidence(from: [
            "symbolFacts": ["isFunction": true, "selfKind": 17]
        ])) { error in
            XCTAssertEqual(error as? SwiftConventionCodecError,
                           .badValue(where: "selfKind", value: "must be a string or null"))
        }
    }

    func testCodecRejectsNonStringThrownTypeInsteadOfUntypedThrows() {
        XCTAssertThrowsError(try SwiftConventionCodec.evidence(from: [
            "symbolFacts": ["isFunction": true, "isThrowing": true, "thrownType": [] as [Any]]
        ])) { error in
            XCTAssertEqual(error as? SwiftConventionCodecError,
                           .badValue(where: "thrownType", value: "must be a string or null"))
        }
    }

    func testCodecPreservesAbsentOptionalStringEvidence() throws {
        let evidence = try SwiftConventionCodec.evidence(from: [
            "symbolFacts": ["isFunction": true, "isThrowing": true]
        ])
        let facts = try XCTUnwrap(evidence.symbolFacts)
        XCTAssertEqual(facts.selfKind, SwiftSelfKind.none)
        XCTAssertEqual(facts.selfNominalKind, SwiftSelfNominalKind.none)
        XCTAssertNil(facts.thrownType)
        let decision = SwiftConventionAdapter.decide(evidence)
        XCTAssertEqual(decision.convention, .swiftcall)
        XCTAssertEqual(decision.errorOut, "x21")
    }

    func testCodecPreservesNullOptionalStringEvidence() throws {
        let evidence = try SwiftConventionCodec.evidence(from: [
            "symbolFacts": ["isFunction": true, "isThrowing": true,
                            "selfKind": NSNull(), "selfNominalKind": NSNull(), "thrownType": NSNull()]
        ])
        let facts = try XCTUnwrap(evidence.symbolFacts)
        XCTAssertEqual(facts.selfKind, SwiftSelfKind.none)
        XCTAssertEqual(facts.selfNominalKind, SwiftSelfNominalKind.none)
        XCTAssertNil(facts.thrownType)
        let decision = SwiftConventionAdapter.decide(evidence)
        XCTAssertEqual(decision.convention, .swiftcall)
        XCTAssertEqual(decision.errorOut, "x21")
    }

    func testCodecPreservesValidStringEvidenceAndTypedThrowsAbstention() throws {
        let evidence = try SwiftConventionCodec.evidence(from: [
            "symbolFacts": ["isFunction": true, "isThrowing": true,
                            "selfKind": "instance", "selfNominalKind": "class", "thrownType": "M.E"]
        ])
        let facts = try XCTUnwrap(evidence.symbolFacts)
        XCTAssertEqual(facts.selfKind, .instance)
        XCTAssertEqual(facts.selfNominalKind, .class)
        XCTAssertEqual(facts.thrownType, "M.E")
        let decision = SwiftConventionAdapter.decide(evidence)
        XCTAssertEqual(decision.convention, .swiftcall)
        XCTAssertEqual(decision.contextIn, ["x20"])
        XCTAssertNil(decision.errorOut)
        XCTAssertTrue(decision.abstentions.contains(R.typedThrowsErrorStorage))
        XCTAssertEqual(decision.storage, .abstainH03)
    }

}
