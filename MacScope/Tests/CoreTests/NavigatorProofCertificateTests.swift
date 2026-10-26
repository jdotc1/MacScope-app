import Foundation
import XCTest
@testable import MacScope
@testable import MacScopeAnalysisCore

final class NavigatorProofCertificateTests: XCTestCase {
    private static let subject = NavigatorSubject(kind: "function", ref: "0x340",
                                                  image: "9f20e834-0ec1-31f0-aa9c-6153bbab70c6/e4957a86d91eb372")
    private static let premises = [
        NavigatorProvenance(kind: "loaderRecord", ref: "section[__TEXT,__text]"),
        NavigatorProvenance(kind: "loaderRecord", ref: "lc[11]"),
        NavigatorProvenance(kind: "loaderRecord", ref: "functionStarts[0]@0x340"),
    ]

    private func make(outcome: NavigatorProofCertificate.Outcome = .proven, conclusion: String = "0x340 is a function start",
                      value: NavigatorJSONValue = .bool(true),
                      premises: [NavigatorProvenance] = NavigatorProofCertificateTests.premises,
                      wallMs: Int64 = 0, bytesRead: Int64 = 98, rule: String = "proof.function-start-structural",
                      ruleVersion: String = "1") throws -> NavigatorProofCertificate {
        try NavigatorProofCertificate.make(
            rule: rule, ruleVersion: ruleVersion, subject: Self.subject, predicate: "isFunctionStart",
            value: value, premises: premises, assumptions: ["macho.slice-identity: the Mach-O load commands describe this slice"],
            conclusion: conclusion, trustedBase: ["MachOParser", "NavigatorProvenanceResolver"], outcome: outcome,
            budget: .init(wallMs: wallMs, bytesRead: bytesRead))
    }

    // MARK: - Hash

    func testHashIsSHA256OfTheCanonicalBodyWithoutHashOrBudget() throws {
        let certificate = try make()
        XCTAssertTrue(certificate.hash.hasPrefix("sha256:"))
        XCTAssertTrue(NavigatorContractValidator.isCertificateRef(certificate.hash))
        XCTAssertNil(certificate.body["hash"])
        XCTAssertEqual(certificate.body["budget"], .object(["bytesRead": .int(98), "wallMs": .int(0)]))
        XCTAssertNil(certificate.hashInput["hash"])
        XCTAssertNil(certificate.hashInput["budget"])
        XCTAssertEqual(certificate.json["hash"], .string(certificate.hash))
        XCTAssertEqual(certificate.json["budget"], certificate.body["budget"])

        let canonical = try NavigatorJSONCanonical.encode(certificate.hashInput)
        XCTAssertEqual(certificate.hash, "sha256:" + AnalysisFingerprintBuilder.sha256Hex(Data(canonical.utf8)))
        XCTAssertEqual(try NavigatorProofCertificate.hash(of: certificate.hashInput), certificate.hash)
        XCTAssertFalse(canonical.contains("\"hash\""))
        XCTAssertFalse(canonical.contains("\"budget\""))
        XCTAssertFalse(canonical.contains("wallMs"))
        XCTAssertFalse(canonical.contains("bytesRead"))
        // Canonical JSON: sorted keys, no whitespace; "budget" would have sorted second.
        XCTAssertTrue(canonical.hasPrefix("{\"assumptions\":[\"macho.slice-identity: the Mach-O load commands describe this slice\"],\"conclusion\":"))
        XCTAssertTrue(certificate.isIntact)

        // The hash input may contain neither the hash nor the budget.
        XCTAssertThrowsError(try NavigatorProofCertificate.hash(of: certificate.json)) { error in
            XCTAssertEqual((error as? NavigatorContractError)?.reasons,
                           ["certificate: hash input must exclude budget", "certificate: hash input must exclude hash"])
        }
        XCTAssertThrowsError(try NavigatorProofCertificate.hash(of: certificate.body)) { error in
            XCTAssertEqual((error as? NavigatorContractError)?.reasons, ["certificate: hash input must exclude budget"])
        }
        XCTAssertEqual(NavigatorProofCertificate.hashInput(of: certificate.json), certificate.hashInput)
    }

    func testCertificatesDifferingOnlyInBudgetHashEqual() throws {
        let base = try make()
        let budgets: [(Int64, Int64)] = [(1, 98), (0, 97), (250, 0), (Int64(Int32.max), 1 << 40)]
        for (wallMs, bytesRead) in budgets {
            let other = try make(wallMs: wallMs, bytesRead: bytesRead)
            XCTAssertEqual(other.hash, base.hash, "wallMs \(wallMs) bytesRead \(bytesRead)")
            XCTAssertEqual(other.reference, base.reference)
            XCTAssertEqual(other.hashInput, base.hashInput)
            XCTAssertNotEqual(other.body, base.body)
            XCTAssertNotEqual(other, base)
            XCTAssertEqual(other.budget, .init(wallMs: wallMs, bytesRead: bytesRead))
            XCTAssertTrue(other.isIntact)
        }

        // A certificate whose budget is edited after the fact still parses, keeps its hash and reports
        // the edited budget: the budget is a run measurement, not part of what the hash attests.
        guard case .object(var fields) = base.json else { return XCTFail("expected object") }
        fields["budget"] = .object(["bytesRead": .int(5), "wallMs": .int(7)])
        let parsed = try NavigatorProofCertificate(json: .object(fields))
        XCTAssertEqual(parsed.hash, base.hash)
        XCTAssertEqual(parsed.budget, .init(wallMs: 7, bytesRead: 5))
        XCTAssertEqual(parsed, try make(wallMs: 7, bytesRead: 5))
    }

    func testHashIsStableAndSensitiveToEveryHashedField() throws {
        let base = try make()
        XCTAssertEqual(try make().hash, base.hash)
        XCTAssertEqual(try make(), base)

        let variants: [NavigatorProofCertificate] = [
            try make(outcome: .insufficientEvidence),
            try make(conclusion: "0x340 is a function start."),
            try make(value: .bool(false)),
            try make(premises: Array(Self.premises.dropLast())),
            try make(premises: Self.premises.reversed()),
            try NavigatorProofCertificate.make(
                rule: "proof.function-start-structural", ruleVersion: "2", subject: Self.subject, predicate: "isFunctionStart",
                value: .bool(true), premises: Self.premises,
                assumptions: ["macho.slice-identity: the Mach-O load commands describe this slice"],
                conclusion: "0x340 is a function start", trustedBase: ["MachOParser", "NavigatorProvenanceResolver"],
                outcome: .proven, budget: .init(wallMs: 0, bytesRead: 98)),
            try NavigatorProofCertificate.make(
                rule: "proof.function-start-structural", ruleVersion: "1",
                subject: NavigatorSubject(kind: "function", ref: "0x340"), predicate: "isFunctionStart",
                value: .bool(true), premises: Self.premises,
                assumptions: ["macho.slice-identity: the Mach-O load commands describe this slice"],
                conclusion: "0x340 is a function start", trustedBase: ["MachOParser", "NavigatorProvenanceResolver"],
                outcome: .proven, budget: .init(wallMs: 0, bytesRead: 98)),
            try NavigatorProofCertificate.make(
                rule: "proof.function-start-structural", ruleVersion: "1", subject: Self.subject, predicate: "isFunctionStart",
                value: .bool(true), premises: Self.premises, assumptions: [],
                conclusion: "0x340 is a function start", trustedBase: ["MachOParser", "NavigatorProvenanceResolver"],
                outcome: .proven, budget: .init(wallMs: 0, bytesRead: 98)),
            try NavigatorProofCertificate.make(
                rule: "proof.function-start-structural", ruleVersion: "1", subject: Self.subject, predicate: "isFunctionStart",
                value: .bool(true), premises: Self.premises,
                assumptions: ["macho.slice-identity: the Mach-O load commands describe this slice"],
                conclusion: "0x340 is a function start", trustedBase: ["MachOParser"],
                outcome: .proven, budget: .init(wallMs: 0, bytesRead: 98)),
        ]
        var hashes = Set([base.hash])
        for variant in variants {
            XCTAssertTrue(variant.isIntact)
            XCTAssertTrue(hashes.insert(variant.hash).inserted, "duplicate hash for \(variant.conclusion)")
        }
        XCTAssertEqual(hashes.count, variants.count + 1)
    }

    func testEveryOutcomeBuilds() throws {
        XCTAssertEqual(NavigatorProofCertificate.Outcome.allCases.map(\.rawValue),
                       ["proven", "refuted", "insufficientEvidence", "cancelled", "timeout"])
        for outcome in NavigatorProofCertificate.Outcome.allCases {
            let certificate = try make(outcome: outcome)
            XCTAssertEqual(certificate.outcome, outcome)
            XCTAssertEqual(certificate.body["outcome"], .string(outcome.rawValue))
        }
    }

    // MARK: - JSON round trip

    func testRoundTripsThroughCanonicalJSON() throws {
        let certificate = try make()
        let text = try NavigatorJSONCanonical.encode(certificate.json)
        let parsed = try NavigatorProofCertificate(json: try NavigatorJSONParser.parse(text))
        XCTAssertEqual(parsed, certificate)
        XCTAssertEqual(parsed.hash, certificate.hash)
        XCTAssertEqual(parsed.premises, Self.premises)
        XCTAssertEqual(parsed.subject, Self.subject)
        XCTAssertEqual(parsed.budget, .init(wallMs: 0, bytesRead: 98))
        XCTAssertEqual(try NavigatorJSONCanonical.encode(parsed.json), text)
    }

    func testRoundTripsAProducedCertificate() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let binary = CertificateFixtures.binary(fixture.bytes)
        let evidence = try XCTUnwrap(NavigatorImageEvidence(binary: binary))
        let output = FunctionStartStructuralProof.run(entry: fixture.baseAddress, evidence: evidence,
                                                      toolchain: "arm64/macOS/classic", clock: { 0 })
        let certificate = try XCTUnwrap(output.certificate)
        let parsed = try NavigatorProofCertificate(json: certificate.json)
        XCTAssertEqual(parsed, certificate)
    }

    // MARK: - Refusals

    func testTamperedHashIsRefused() throws {
        let certificate = try make()
        guard case .object(var fields) = certificate.json else { return XCTFail("expected object") }
        let flipped = certificate.hash.last == "0" ? "1" : "0"
        fields["hash"] = .string(String(certificate.hash.dropLast()) + flipped)
        XCTAssertThrowsError(try NavigatorProofCertificate(json: .object(fields))) { error in
            let reasons = (error as? NavigatorContractError)?.reasons ?? []
            XCTAssertEqual(reasons, ["certificate.hash: does not match recomputed \(certificate.hash)"])
        }
    }

    func testTamperedBodyIsRefused() throws {
        let certificate = try make()
        guard case .object(var fields) = certificate.json else { return XCTFail("expected object") }
        fields["outcome"] = .string("refuted")
        XCTAssertThrowsError(try NavigatorProofCertificate(json: .object(fields))) { error in
            let reasons = (error as? NavigatorContractError)?.reasons ?? []
            XCTAssertEqual(reasons.count, 1)
            XCTAssertTrue(reasons.first?.hasPrefix("certificate.hash: does not match recomputed sha256:") ?? false)
        }
        fields["outcome"] = .string("proven")
        fields["premises"] = .array(Self.premises.dropLast().map(\.json))
        XCTAssertThrowsError(try NavigatorProofCertificate(json: .object(fields)))
    }

    func testMalformedHashFormIsRefused() throws {
        let certificate = try make()
        guard case .object(var fields) = certificate.json else { return XCTFail("expected object") }
        for bad in [String(certificate.hash.dropFirst("sha256:".count)), certificate.hash.uppercased(),
                    "sha256:" + String(repeating: "0", count: 63), "sha1:" + String(repeating: "0", count: 64)] {
            fields["hash"] = .string(bad)
            XCTAssertThrowsError(try NavigatorProofCertificate(json: .object(fields)), bad) { error in
                let reasons = (error as? NavigatorContractError)?.reasons ?? []
                XCTAssertEqual(reasons, ["certificate.hash: expected sha256:<64 lowercase hex>"], bad)
            }
        }
        fields["hash"] = .int(1)
        XCTAssertThrowsError(try NavigatorProofCertificate(json: .object(fields))) { error in
            XCTAssertEqual((error as? NavigatorContractError)?.reasons, ["certificate.hash: expected string"])
        }
        XCTAssertThrowsError(try NavigatorProofCertificate(json: .array([]))) { error in
            XCTAssertEqual((error as? NavigatorContractError)?.reasons, ["certificate: expected object"])
        }
    }

    func testMissingAndUnexpectedFieldsAreRefused() throws {
        let certificate = try make()
        guard case .object(let original) = certificate.json else { return XCTFail("expected object") }

        var missing = original
        missing["trustedBase"] = nil
        XCTAssertThrowsError(try NavigatorProofCertificate(json: .object(missing))) { error in
            XCTAssertEqual((error as? NavigatorContractError)?.reasons, ["certificate: missing trustedBase"])
        }

        var extra = original
        extra["status"] = .string("proven")
        XCTAssertThrowsError(try NavigatorProofCertificate(json: .object(extra))) { error in
            XCTAssertEqual((error as? NavigatorContractError)?.reasons, ["certificate: unexpected status"])
        }

        var budget = original
        budget["budget"] = .object(["wallMs": .int(0), "bytesRead": .int(98), "solverSteps": .int(1)])
        XCTAssertThrowsError(try NavigatorProofCertificate(json: .object(budget))) { error in
            XCTAssertEqual((error as? NavigatorContractError)?.reasons, ["certificate.budget: unexpected solverSteps"])
        }
    }

    func testOutOfContractFieldsAreRefusedByMake() {
        func reasons(_ body: () throws -> NavigatorProofCertificate) -> [String] {
            do {
                _ = try body()
                return []
            } catch {
                return (error as? NavigatorContractError)?.reasons ?? ["unexpected error"]
            }
        }
        let assumptions = ["a"]
        let trustedBase = ["MachOParser"]

        XCTAssertEqual(reasons {
            try NavigatorProofCertificate.make(rule: "", ruleVersion: "1", subject: Self.subject, predicate: "isFunctionStart",
                                               value: .bool(true), premises: Self.premises, assumptions: assumptions,
                                               conclusion: "c", trustedBase: trustedBase, outcome: .proven,
                                               budget: .init(wallMs: 0, bytesRead: 0))
        }, ["certificate.rule: expected non-empty string"])

        XCTAssertEqual(reasons {
            try NavigatorProofCertificate.make(rule: "r", ruleVersion: "1", subject: Self.subject, predicate: "isFunctionStart",
                                               value: .bool(true), premises: Self.premises, assumptions: assumptions,
                                               conclusion: "", trustedBase: trustedBase, outcome: .proven,
                                               budget: .init(wallMs: 0, bytesRead: 0))
        }, ["certificate.conclusion: expected non-empty string"])

        XCTAssertEqual(reasons {
            try NavigatorProofCertificate.make(rule: "r", ruleVersion: "1", subject: Self.subject, predicate: "isFunctionStart",
                                               value: .string("yes"), premises: Self.premises, assumptions: assumptions,
                                               conclusion: "c", trustedBase: trustedBase, outcome: .proven,
                                               budget: .init(wallMs: 0, bytesRead: 0))
        }, ["certificate.value: isFunctionStart expects boolean"])

        XCTAssertEqual(reasons {
            try NavigatorProofCertificate.make(rule: "r", ruleVersion: "1", subject: Self.subject, predicate: "isEntryPoint",
                                               value: .bool(true), premises: Self.premises, assumptions: assumptions,
                                               conclusion: "c", trustedBase: trustedBase, outcome: .proven,
                                               budget: .init(wallMs: 0, bytesRead: 0))
        }, ["certificate.predicate: not in vocabulary"])

        XCTAssertEqual(reasons {
            try NavigatorProofCertificate.make(rule: "r", ruleVersion: "1",
                                               subject: NavigatorSubject(kind: "routine", ref: "0x340"),
                                               predicate: "isFunctionStart", value: .bool(true), premises: Self.premises,
                                               assumptions: assumptions, conclusion: "c", trustedBase: trustedBase,
                                               outcome: .proven, budget: .init(wallMs: 0, bytesRead: 0))
        }, ["certificate.subject.kind: not in vocabulary"])

        XCTAssertEqual(reasons {
            try NavigatorProofCertificate.make(rule: "r", ruleVersion: "1", subject: Self.subject, predicate: "isFunctionStart",
                                               value: .bool(true),
                                               premises: [NavigatorProvenance(kind: "hunch", ref: "lc[0]")],
                                               assumptions: assumptions, conclusion: "c", trustedBase: trustedBase,
                                               outcome: .proven, budget: .init(wallMs: 0, bytesRead: 0))
        }, ["certificate.premises[0].kind: not in vocabulary"])

        XCTAssertEqual(reasons {
            try NavigatorProofCertificate.make(rule: "r", ruleVersion: "1", subject: Self.subject, predicate: "isFunctionStart",
                                               value: .bool(true), premises: Self.premises, assumptions: assumptions,
                                               conclusion: "c", trustedBase: trustedBase, outcome: .proven,
                                               budget: .init(wallMs: -1, bytesRead: 0))
        }, ["certificate.budget.wallMs: expected integer >= 0"])
    }

    func testOutOfContractFieldsAreRefusedByParse() throws {
        let certificate = try make()
        guard case .object(var fields) = certificate.json else { return XCTFail("expected object") }
        fields["outcome"] = .string("maybe")
        XCTAssertThrowsError(try NavigatorProofCertificate(json: .object(fields))) { error in
            XCTAssertEqual((error as? NavigatorContractError)?.reasons,
                           ["certificate.outcome: expected proven|refuted|insufficientEvidence|cancelled|timeout"])
        }
        fields["outcome"] = .string("proven")
        fields["assumptions"] = .array([.int(1)])
        XCTAssertThrowsError(try NavigatorProofCertificate(json: .object(fields))) { error in
            XCTAssertEqual((error as? NavigatorContractError)?.reasons, ["certificate.assumptions: expected array of strings"])
        }
    }

    // MARK: - supports

    func testSupportsOnlyTheExactProvenClaim() throws {
        let certificate = try make()
        let fact = try NavigatorFact.make(
            subject: Self.subject, predicate: "isFunctionStart", value: .bool(true), status: "proven",
            provenance: [FunctionStartStructuralProof.ruleProvenance, certificate.reference] + Self.premises,
            toolchain: "arm64/macOS/classic")
        XCTAssertTrue(certificate.supports(fact))
        XCTAssertEqual(certificate.reference, NavigatorProvenance(kind: "proofCertificate", ref: certificate.hash))

        XCTAssertFalse(try make(outcome: .insufficientEvidence).supports(fact))
        XCTAssertFalse(try make(value: .bool(false)).supports(fact))
        XCTAssertEqual(certificate.ruleKey, "proof.function-start-structural@1")
        XCTAssertFalse(try make(ruleVersion: "2").supports(fact))
        XCTAssertFalse(try make(rule: "derive.function-start-call-target").supports(fact))

        var otherSubject = fact
        otherSubject.subject = NavigatorSubject(kind: "function", ref: "0x344", image: Self.subject.image)
        XCTAssertFalse(certificate.supports(otherSubject))

        var otherImage = fact
        otherImage.subject = NavigatorSubject(kind: "function", ref: "0x340")
        XCTAssertFalse(certificate.supports(otherImage))

        var otherPredicate = fact
        otherPredicate.predicate = "isGeneric"
        XCTAssertFalse(certificate.supports(otherPredicate))

        // A fact with no rule entry is supported by a certificate from any rule.
        var noRule = fact
        noRule.provenance = [certificate.reference] + Self.premises
        XCTAssertTrue(certificate.supports(noRule))
        XCTAssertTrue(try make(ruleVersion: "2").supports(noRule))
    }
}

private enum CertificateFixtures {
    static func binary(_ bytes: Data) -> LoadedBinary {
        LoadedBinary(
            name: "certificate-fixture", path: "/tmp/certificate-fixture", isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64,
            fileTypeName: "fixture", architectureDisplayName: "arm64",
            metadata: .empty,
            artifactIdentity: nil,
            bytes: bytes,
            sliceOffset: 0,
            sliceSize: UInt64(bytes.count),
            sections: [], executableTextSection: nil, entryPointAddress: nil,
            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            functionStarts: [], objcSelectors: [:]
        )
    }
}
