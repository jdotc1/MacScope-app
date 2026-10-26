import Foundation
import XCTest
@testable import MacScope
@testable import MacScopeAnalysisCore

final class NavigatorContractValidationTests: XCTestCase {
    private static let toolchain = "arm64/macOS/classic"
    private static let subject = NavigatorSubject(kind: "function", ref: "0x340")
    private static let premise = NavigatorProvenance(kind: "loaderRecord", ref: "functionStarts[0]@0x340")

    private func certificate(outcome: NavigatorProofCertificate.Outcome = .proven,
                             subject: NavigatorSubject = NavigatorContractValidationTests.subject,
                             value: NavigatorJSONValue = .bool(true),
                             rule: String = FunctionStartStructuralProof.rule,
                             ruleVersion: String = FunctionStartStructuralProof.ruleVersion) throws -> NavigatorProofCertificate {
        try NavigatorProofCertificate.make(
            rule: rule, ruleVersion: ruleVersion,
            subject: subject, predicate: "isFunctionStart", value: value, premises: [Self.premise],
            assumptions: FunctionStartStructuralProof.assumptions, conclusion: "0x340 \(outcome.rawValue)",
            trustedBase: FunctionStartStructuralProof.trustedBase, outcome: outcome,
            budget: .init(wallMs: 0, bytesRead: 2))
    }

    /// A `proven` fact citing `refs`, led by `rule` (nil: no rule entry).
    private func provenFact(citing refs: [String],
                            rule: NavigatorProvenance? = FunctionStartStructuralProof.ruleProvenance) throws -> NavigatorFact {
        try NavigatorFact.make(
            subject: Self.subject, predicate: "isFunctionStart", value: .bool(true), status: "proven",
            provenance: (rule.map { [$0] } ?? [])
                + refs.map { NavigatorProvenance(kind: "proofCertificate", ref: $0) } + [Self.premise],
            toolchain: Self.toolchain)
    }

    private static func ruleEntry(_ id: String, version: String) -> NavigatorProvenance {
        NavigatorProvenance(kind: "rule", ref: NavigatorProvenanceRef.rule(id: id, version: version).ref,
                            rule: id, ruleVersion: version)
    }

    /// The JSON of a fact with a correct id for `provenance`, built without `NavigatorFact.make`.
    private func factJSON(status: String, provenance: [NavigatorProvenance], value: NavigatorJSONValue = .bool(true),
                          tier: Int64? = nil, derivedFrom: [[String]]? = nil) throws -> NavigatorJSONValue {
        let id = try NavigatorFact.id(subject: Self.subject, predicate: "isFunctionStart", value: value,
                                      provenance: provenance)
        var fields: [String: NavigatorJSONValue] = [
            "kind": .string("Fact"), "schemaVersion": .int(1), "id": .string(id), "subject": Self.subject.json,
            "predicate": .string("isFunctionStart"), "value": value, "status": .string(status),
            "provenance": .array(provenance.map(\.json)), "toolchain": .string(Self.toolchain),
            "revert": .string("revert:\(id)"),
        ]
        if let tier { fields["tier"] = .int(tier) }
        if let derivedFrom { fields["derivedFrom"] = .array(derivedFrom.map { .array($0.map { .string($0) }) }) }
        return .object(fields)
    }

    // MARK: - validateFact: the proven rule

    func testProvenFactWithoutCertificateIsRefused() {
        XCTAssertThrowsError(try NavigatorFact.make(
            subject: Self.subject, predicate: "isFunctionStart", value: .bool(true), status: "proven",
            provenance: [FunctionStartStructuralProof.ruleProvenance, Self.premise], toolchain: Self.toolchain)) { error in
            XCTAssertEqual((error as? NavigatorContractError)?.reasons,
                           ["fact.provenance: proven fact without a resolvable proof certificate"])
        }
        XCTAssertEqual(NavigatorContractValidator.provenWithoutCertificate,
                       "proven fact without a resolvable proof certificate")
    }

    func testProvenFactWithMalformedCertificateRefIsRefused() throws {
        let malformed = ["sha256:abc", "sha256:" + String(repeating: "A", count: 64), String(repeating: "a", count: 64),
                         "sha512:" + String(repeating: "a", count: 64), "sha256:" + String(repeating: "a", count: 65)]
        for ref in malformed {
            XCTAssertThrowsError(try provenFact(citing: [ref]), ref) { error in
                XCTAssertEqual((error as? NavigatorContractError)?.reasons,
                               ["fact.provenance: proven fact without a resolvable proof certificate"], ref)
            }
        }
        // A well-formed ref under the wrong kind does not count either.
        let hash = try certificate().hash
        XCTAssertThrowsError(try NavigatorFact.make(
            subject: Self.subject, predicate: "isFunctionStart", value: .bool(true), status: "proven",
            provenance: [FunctionStartStructuralProof.ruleProvenance, NavigatorProvenance(kind: "rule", ref: hash)],
            toolchain: Self.toolchain))
    }

    func testProvenFactWithWellFormedCertificateRefIsAccepted() throws {
        let certificate = try certificate()
        let fact = try provenFact(citing: [certificate.hash])
        XCTAssertEqual(fact.status, "proven")
        XCTAssertTrue(NavigatorContractValidator.validateFact(fact.json).isEmpty)
        XCTAssertTrue(NavigatorContractValidator.validateRecord(fact.json).isEmpty)
        // The pure validator checks the form only: an unknown but well-formed hash passes here and is
        // caught by certificateRefusal.
        let unknown = try provenFact(citing: ["sha256:" + String(repeating: "0", count: 64)])
        XCTAssertTrue(NavigatorContractValidator.validateFact(unknown.json).isEmpty)
        XCTAssertNotNil(NavigatorContractValidator.certificateRefusal(for: unknown) { _ in nil })
    }

    func testOtherStatusesAreUnaffected() throws {
        let authoritative = try NavigatorFact.make(
            subject: Self.subject, predicate: "isFunctionStart", value: .bool(true), status: "authoritative",
            provenance: [Self.premise], toolchain: Self.toolchain)
        XCTAssertTrue(NavigatorContractValidator.validateFact(authoritative.json).isEmpty)

        let derived = try NavigatorFact.make(
            subject: Self.subject, predicate: "isFunctionStart", value: .bool(true), status: "derived",
            provenance: [FunctionStartCallTargetDerivation.ruleProvenance,
                         NavigatorProvenance(kind: "decodedInstruction", ref: "0x33c")],
            toolchain: Self.toolchain, tier: 2, derivedFrom: [[authoritative.id]])
        XCTAssertTrue(NavigatorContractValidator.validateFact(derived.json).isEmpty)

        let candidate = try NavigatorFact.make(
            subject: Self.subject, predicate: "hasName", value: .object(["alternatives": .array([.string("a"), .string("b")])]),
            status: "candidate", provenance: [Self.premise], toolchain: Self.toolchain, tier: 3)
        XCTAssertTrue(NavigatorContractValidator.validateFact(candidate.json).isEmpty)

        let unknown = try NavigatorFact.make(
            subject: Self.subject, predicate: "isFunctionStart", value: .null, status: "unknown",
            provenance: [Self.premise], toolchain: Self.toolchain)
        XCTAssertTrue(NavigatorContractValidator.validateFact(unknown.json).isEmpty)

        for fact in [authoritative, derived, candidate, unknown] {
            XCTAssertNil(NavigatorContractValidator.certificateRefusal(for: fact) { _ in nil }, fact.status)
        }
    }

    func testRuleIsReportedAtEachRecordPath() throws {
        let json = try factJSON(status: "proven", provenance: [FunctionStartStructuralProof.ruleProvenance, Self.premise])
        let reason = "provenance: proven fact without a resolvable proof certificate"

        XCTAssertEqual(NavigatorContractValidator.validateFact(json), ["fact.\(reason)"])
        XCTAssertEqual(NavigatorContractValidator.validateRecord(json), ["$.\(reason)"])
        XCTAssertThrowsError(try NavigatorFact(json: json))

        let result = NavigatorJSONValue.object([
            "kind": .string("PrimitiveResult"), "schemaVersion": .int(1),
            "primitive": .string(FunctionStartStructuralProof.rule), "primitiveVersion": .string("1"),
            "subject": Self.subject.json, "budget": .object(["bytes": .int(2)]), "outcome": .string("facts"),
            "facts": .array([json]), "frontier": .array([]),
        ])
        XCTAssertEqual(NavigatorContractValidator.validateResult(result), ["result.facts[0].\(reason)"])
        XCTAssertEqual(NavigatorContractValidator.validateRecord(result), ["$.facts[0].\(reason)"])

        let state = NavigatorJSONValue.object([
            "kind": .string("NavigatorEngineState"), "schemaVersion": .int(1), "toolchain": .string(Self.toolchain),
            "facts": .array([json]), "reverted": .array([]), "frontier": .array([]), "annotations": .array([]),
        ])
        XCTAssertEqual(NavigatorContractValidator.validateState(state), ["state.facts[0].\(reason)"])
        XCTAssertEqual(NavigatorContractValidator.validateRecord(state), ["state.facts[0].\(reason)"])

        // The same record with a well-formed certificate ref (and its own id) is valid everywhere.
        let hash = try certificate().hash
        let cited = try factJSON(status: "proven", provenance: [FunctionStartStructuralProof.ruleProvenance,
                                                                NavigatorProvenance(kind: "proofCertificate", ref: hash),
                                                                Self.premise])
        XCTAssertTrue(NavigatorContractValidator.validateFact(cited).isEmpty)
        XCTAssertTrue(NavigatorContractValidator.validateRecord(cited).isEmpty)
    }

    func testCertificateRefDoesNotChangeTheFactID() throws {
        let first = try certificate()
        let second = try certificate(outcome: .proven, value: .bool(true))
        XCTAssertEqual(first.hash, second.hash)
        let cited = try provenFact(citing: [first.hash])
        let other = try provenFact(citing: ["sha256:" + String(repeating: "f", count: 64)])
        // The id covers subject, predicate, value and rule@ruleVersion only.
        XCTAssertEqual(cited.id, other.id)
    }

    // MARK: - certificateRefusal

    func testCertificateRefusalAcceptsAResolvingProvenCertificate() throws {
        let certificate = try certificate()
        let fact = try provenFact(citing: [certificate.hash])
        XCTAssertNil(NavigatorContractValidator.certificateRefusal(for: fact) { $0 == certificate.hash ? certificate : nil })

        // One qualifying certificate among several is enough.
        let stray = "sha256:" + String(repeating: "1", count: 64)
        let both = try provenFact(citing: [stray, certificate.hash])
        XCTAssertNil(NavigatorContractValidator.certificateRefusal(for: both) { $0 == certificate.hash ? certificate : nil })
    }

    func testCertificateRefusalForAMissingCertificate() throws {
        let certificate = try certificate()
        let fact = try provenFact(citing: [certificate.hash])
        XCTAssertEqual(NavigatorContractValidator.certificateRefusal(for: fact) { _ in nil },
                       NavigatorRefusal("malformedInput", "proven fact without a resolvable proof certificate"))
    }

    func testCertificateRefusalForANonProvenOutcome() throws {
        for outcome in NavigatorProofCertificate.Outcome.allCases where outcome != .proven {
            let certificate = try certificate(outcome: outcome)
            let fact = try provenFact(citing: [certificate.hash])
            let refusal = NavigatorContractValidator.certificateRefusal(for: fact) { $0 == certificate.hash ? certificate : nil }
            XCTAssertEqual(refusal, NavigatorRefusal("malformedInput",
                                                     "proven fact whose proof certificate outcome is \(outcome.rawValue)"))
            XCTAssertEqual(refusal?.retryable, false)
        }
    }

    func testCertificateRefusalForAMismatchedClaim() throws {
        let otherSubject = try certificate(subject: NavigatorSubject(kind: "function", ref: "0x344"))
        let otherValue = try certificate(value: .bool(false))
        for certificate in [otherSubject, otherValue] {
            let fact = try provenFact(citing: [certificate.hash])
            XCTAssertEqual(NavigatorContractValidator.certificateRefusal(for: fact) { $0 == certificate.hash ? certificate : nil },
                           NavigatorRefusal("malformedInput", NavigatorContractValidator.provenWithoutCertificate))
        }
    }

    func testCertificateRefusalForAWrongHashKey() throws {
        // The store returns an intact certificate, but under a ref that is not its hash.
        let certificate = try certificate()
        let wrongRef = "sha256:" + String(repeating: "2", count: 64)
        let fact = try provenFact(citing: [wrongRef])
        XCTAssertEqual(NavigatorContractValidator.certificateRefusal(for: fact) { _ in certificate },
                       NavigatorRefusal("malformedInput", NavigatorContractValidator.provenWithoutCertificate))
    }

    func testCertificateRefusalAcceptsACertificateFromTheFactsRule() throws {
        // The certificate's rule@ruleVersion equals the fact's rule entry, version included.
        let second = try certificate(ruleVersion: "2")
        let fact = try provenFact(citing: [second.hash],
                                  rule: Self.ruleEntry(FunctionStartStructuralProof.rule, version: "2"))
        XCTAssertEqual(NavigatorContractValidator.ruleKey(of: fact), "proof.function-start-structural@2")
        XCTAssertEqual(second.ruleKey, "proof.function-start-structural@2")
        XCTAssertNil(NavigatorContractValidator.certificateRefusal(for: fact) { $0 == second.hash ? second : nil })
        XCTAssertTrue(second.supports(fact))

        // A fact that names no rule accepts a certificate from any rule.
        let unruled = try provenFact(citing: [second.hash], rule: nil)
        XCTAssertNil(NavigatorContractValidator.ruleKey(of: unruled))
        XCTAssertNil(NavigatorContractValidator.certificateRefusal(for: unruled) { $0 == second.hash ? second : nil })
        XCTAssertTrue(second.supports(unruled))
    }

    func testCertificateRefusalForACertificateFromAnotherRule() throws {
        // Same claim, intact, proven, but from another version of the fact's rule, or from another rule.
        let otherVersion = try certificate(ruleVersion: "2")
        let otherRule = try certificate(rule: FunctionStartCallTargetDerivation.rule,
                                        ruleVersion: FunctionStartCallTargetDerivation.ruleVersion)
        for (certificate, key) in [(otherVersion, "proof.function-start-structural@2"),
                                   (otherRule, "derive.function-start-call-target@1")] {
            let fact = try provenFact(citing: [certificate.hash])
            let refusal = NavigatorContractValidator.certificateRefusal(for: fact) { $0 == certificate.hash ? certificate : nil }
            XCTAssertEqual(refusal, NavigatorRefusal(
                "malformedInput", "proven fact whose proof certificate is from \(key), not proof.function-start-structural@1"))
            XCTAssertEqual(refusal?.retryable, false)
            XCTAssertFalse(certificate.supports(fact))
        }
        XCTAssertEqual(NavigatorContractValidator.provenFromOtherRule(certificate: "a@1", fact: "b@2"),
                       "proven fact whose proof certificate is from a@1, not b@2")

        // Beside a certificate from another rule, one from the fact's rule decides: its other outcome is
        // reported first; its proven outcome is accepted.
        let refuted = try certificate(outcome: .refuted)
        let proven = try certificate()
        let byHash = [otherVersion.hash: otherVersion, refuted.hash: refuted, proven.hash: proven]
        let withRefuted = try provenFact(citing: [otherVersion.hash, refuted.hash])
        XCTAssertEqual(NavigatorContractValidator.certificateRefusal(for: withRefuted) { byHash[$0] },
                       NavigatorRefusal("malformedInput", "proven fact whose proof certificate outcome is refuted"))
        let withProven = try provenFact(citing: [otherVersion.hash, proven.hash])
        XCTAssertNil(NavigatorContractValidator.certificateRefusal(for: withProven) { byHash[$0] })
    }

    func testCertificateRefusalIsNilForNonProvenFacts() throws {
        let fact = try NavigatorFact.make(
            subject: Self.subject, predicate: "isFunctionStart", value: .bool(true), status: "authoritative",
            provenance: [Self.premise], toolchain: Self.toolchain)
        var lookups = 0
        XCTAssertNil(NavigatorContractValidator.certificateRefusal(for: fact) { _ in lookups += 1; return nil })
        XCTAssertEqual(lookups, 0)
    }

    // MARK: - Helpers

    func testIsCertificateRef() {
        XCTAssertTrue(NavigatorContractValidator.isCertificateRef("sha256:" + String(repeating: "0123456789abcdef", count: 4)))
        XCTAssertFalse(NavigatorContractValidator.isCertificateRef("sha256:" + String(repeating: "0123456789ABCDEF", count: 4)))
        XCTAssertFalse(NavigatorContractValidator.isCertificateRef("sha256:" + String(repeating: "g", count: 64)))
        XCTAssertFalse(NavigatorContractValidator.isCertificateRef("sha256:" + String(repeating: "a", count: 63)))
        XCTAssertFalse(NavigatorContractValidator.isCertificateRef("sha256:" + String(repeating: "a", count: 65)))
        XCTAssertFalse(NavigatorContractValidator.isCertificateRef("SHA256:" + String(repeating: "a", count: 64)))
        XCTAssertFalse(NavigatorContractValidator.isCertificateRef(" sha256:" + String(repeating: "a", count: 63)))
        XCTAssertFalse(NavigatorContractValidator.isCertificateRef(""))
        // Fullwidth digits are not ASCII hex.
        XCTAssertFalse(NavigatorContractValidator.isCertificateRef("sha256:" + String(repeating: "\u{FF10}", count: 64)))
    }

    func testPredicateValueReasons() {
        XCTAssertTrue(NavigatorContractValidator.predicateValueReasons("isFunctionStart", .bool(true), "c").isEmpty)
        XCTAssertEqual(NavigatorContractValidator.predicateValueReasons("isFunctionStart", .string("true"), "c"),
                       ["c.value: isFunctionStart expects boolean"])
        XCTAssertEqual(NavigatorContractValidator.predicateValueReasons("isFunctionStart", .null, "c"),
                       ["c.value: isFunctionStart expects boolean"])
        XCTAssertTrue(NavigatorContractValidator.predicateValueReasons("nominalKind", .string("struct"), "c").isEmpty)
        XCTAssertEqual(NavigatorContractValidator.predicateValueReasons("nominalKind", .string("union"), "c"),
                       ["c.value: not allowed for nominalKind"])
        XCTAssertEqual(NavigatorContractValidator.predicateValueReasons("isEntryPoint", .bool(true), "c"),
                       ["c.predicate: not in vocabulary"])
        // A settled claim never takes the candidate `alternatives` form.
        XCTAssertEqual(NavigatorContractValidator.predicateValueReasons(
            "hasName", .object(["alternatives": .array([.string("a"), .string("b")])]), "c"),
                       ["c.value: hasName expects string"])
    }
}
