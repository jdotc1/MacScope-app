import Foundation
import XCTest
@testable import MacScope
@testable import MacScopeAnalysisCore

final class FunctionStartStructuralProofTests: XCTestCase {
    private let toolchain = "arm64/macOS/classic"

    // MARK: - Proven

    func testProvesTheFirstFunctionStartFromLoaderRecords() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let evidence = try ProofFixtures.evidence(fixture.bytes)
        let entry = fixture.baseAddress
        XCTAssertEqual(entry, 0x1_0000_00e0)

        let output = FunctionStartStructuralProof.run(entry: entry, evidence: evidence, toolchain: toolchain, clock: { 0 })
        let certificate = try XCTUnwrap(output.certificate)
        let result = output.result
        XCTAssertEqual(result.outcome, "facts")
        XCTAssertNil(result.refusal)
        XCTAssertTrue(result.frontier.isEmpty)
        XCTAssertEqual(result.primitive, "proof.function-start-structural")
        XCTAssertEqual(result.primitiveVersion, "1")
        XCTAssertEqual(result.budget, ["bytes": 98, "wallMillis": 0])

        let premises = [
            NavigatorProvenance(kind: "loaderRecord", ref: "section[__TEXT,__text]"),
            NavigatorProvenance(kind: "loaderRecord", ref: "lc[1]"),
            NavigatorProvenance(kind: "loaderRecord", ref: "functionStarts[0]@0x1000000e0"),
        ]
        XCTAssertEqual(certificate.premises, premises)
        XCTAssertEqual(certificate.outcome, .proven)
        XCTAssertEqual(certificate.budget, .init(wallMs: 0, bytesRead: 98))
        XCTAssertEqual(certificate.subject, NavigatorSubject(kind: "function", ref: "0x1000000e0"))
        XCTAssertEqual(certificate.predicate, "isFunctionStart")
        XCTAssertEqual(certificate.value, .bool(true))
        XCTAssertEqual(certificate.trustedBase, FunctionStartStructuralProof.trustedBase)
        XCTAssertEqual(certificate.assumptions, FunctionStartStructuralProof.assumptions)
        XCTAssertTrue(certificate.conclusion.contains("listed by functionStarts"))
        XCTAssertTrue(certificate.isIntact)

        let fact = try XCTUnwrap(result.facts.first)
        XCTAssertEqual(result.facts.count, 1)
        XCTAssertEqual(fact.status, "proven")
        XCTAssertEqual(fact.subject, certificate.subject)
        XCTAssertEqual(fact.toolchain, toolchain)
        XCTAssertNil(fact.tier)
        XCTAssertNil(fact.derivedFrom)
        XCTAssertEqual(fact.provenance, [FunctionStartStructuralProof.ruleProvenance, certificate.reference] + premises)
        XCTAssertTrue(certificate.supports(fact))
        XCTAssertNil(NavigatorContractValidator.certificateRefusal(for: fact) { $0 == certificate.hash ? certificate : nil })

        // Every premise resolves to bytes inside the fixture.
        for premise in certificate.premises {
            XCTAssertTrue(NavigatorProvenanceResolver.resolve(premise, in: evidence).isResolved, premise.ref)
        }
        XCTAssertTrue(NavigatorContractValidator.validateResult(result.json).isEmpty)
    }

    func testProvesTheSecondFunctionStart() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let evidence = try ProofFixtures.evidence(fixture.bytes)
        let entry = fixture.baseAddress + 0x1c
        let output = FunctionStartStructuralProof.run(entry: entry, evidence: evidence, toolchain: toolchain, clock: { 0 })
        let certificate = try XCTUnwrap(output.certificate)
        XCTAssertEqual(output.result.outcome, "facts")
        XCTAssertEqual(certificate.premises.map(\.ref),
                       ["section[__TEXT,__text]", "lc[1]", "functionStarts[1]@0x1000000fc"])
        XCTAssertEqual(output.result.budget["bytes"], 80 + 16 + 1)
        XCTAssertTrue(NavigatorContractValidator.validateResult(output.result.json).isEmpty)
    }

    func testCertificateIsDeterministicForAFixedClock() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let evidence = try ProofFixtures.evidence(fixture.bytes)
        let first = FunctionStartStructuralProof.run(entry: fixture.baseAddress, evidence: evidence, toolchain: toolchain,
                                                     clock: { 0 })
        let second = FunctionStartStructuralProof.run(entry: fixture.baseAddress, evidence: evidence, toolchain: toolchain,
                                                      clock: { 0 })
        XCTAssertEqual(first, second)
        let hash = try XCTUnwrap(first.certificate?.hash)
        XCTAssertTrue(NavigatorContractValidator.isCertificateRef(hash))
        // The fact id carries rule@ruleVersion, not the certificate hash.
        let fact = try XCTUnwrap(first.result.facts.first)
        XCTAssertEqual(fact.id, try NavigatorFact.id(subject: fact.subject, predicate: "isFunctionStart", value: .bool(true),
                                                     provenance: [FunctionStartStructuralProof.ruleProvenance]))

        // A slower run (no limit, so the clock is read only at start and end: 0 then 1) measures a
        // different budget but certifies the same claim from the same premises: same hash, same fact.
        var tick: Int64 = 0
        let slower = FunctionStartStructuralProof.run(entry: fixture.baseAddress, evidence: evidence, toolchain: toolchain,
                                                      clock: { defer { tick += 1 }; return tick })
        let slowerCertificate = try XCTUnwrap(slower.certificate)
        XCTAssertEqual(slowerCertificate.outcome, .proven)
        XCTAssertEqual(slowerCertificate.budget.wallMs, 1)
        XCTAssertEqual(first.certificate?.budget.wallMs, 0)
        XCTAssertEqual(slowerCertificate.hash, hash)
        XCTAssertNotEqual(slower.certificate, first.certificate)
        XCTAssertEqual(slower.result.facts, first.result.facts)
        XCTAssertEqual(slower.result.budget["wallMillis"], 1)
    }

    func testProvesUnwindLoopZeroFromEveryTable() throws {
        let binary = try ProofFixtures.unwindLoops()
        let evidence = try XCTUnwrap(NavigatorImageEvidence(binary: binary))
        let output = FunctionStartStructuralProof.run(entry: 0x340, evidence: evidence, toolchain: toolchain, clock: { 0 })
        let certificate = try XCTUnwrap(output.certificate)
        XCTAssertEqual(output.result.outcome, "facts")
        XCTAssertEqual(certificate.outcome, .proven)
        XCTAssertEqual(certificate.subject,
                       NavigatorSubject(kind: "function", ref: "0x340", image: ProofFixtures.unwindImageRef))
        XCTAssertEqual(output.result.subject.image, ProofFixtures.unwindImageRef)

        let export = try XCTUnwrap(evidence.file.exports.firstIndex { $0.name == "_loop_zero" })
        let refs = certificate.premises.map(\.ref)
        XCTAssertEqual(refs.first, "section[__TEXT,__text]")
        for expected in ["lc[11]", "functionStarts[0]@0x340", "lc[4]", "exports[\(export)]@0x340", "lc[5]",
                         "nlist[14]@0x340", "section[__TEXT,__unwind_info]", "unwind[0]@0x340"] {
            XCTAssertTrue(refs.contains(expected), expected)
        }
        // Tables appear in search order, each preceded by its container record.
        let order = ["lc[11]", "functionStarts[0]@0x340", "lc[4]", "exports[\(export)]@0x340", "lc[5]", "nlist[14]@0x340",
                     "section[__TEXT,__unwind_info]", "unwind[0]@0x340"].compactMap { refs.firstIndex(of: $0) }
        XCTAssertEqual(order, order.sorted())
        XCTAssertTrue(certificate.conclusion.hasSuffix("listed by functionStarts, exports, nlist, unwind; isFunctionStart = true"))

        var expectedBytes: Int64 = 0
        for premise in certificate.premises {
            let range = try XCTUnwrap(NavigatorProvenanceResolver.resolve(premise, in: evidence).range, premise.ref)
            expectedBytes += Int64(range.count)
        }
        XCTAssertEqual(certificate.budget.bytesRead, expectedBytes)
        XCTAssertEqual(output.result.budget["bytes"], expectedBytes)
        XCTAssertTrue(NavigatorContractValidator.validateResult(output.result.json).isEmpty)
    }

    // MARK: - Insufficient evidence

    func testUnlistedAlignedAddressIsInsufficientEvidence() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let evidence = try ProofFixtures.evidence(fixture.bytes)
        let entry = fixture.baseAddress + 8
        let output = FunctionStartStructuralProof.run(entry: entry, evidence: evidence, toolchain: toolchain, clock: { 0 })
        let certificate = try XCTUnwrap(output.certificate)
        XCTAssertEqual(certificate.outcome, .insufficientEvidence)
        XCTAssertEqual(certificate.premises.map(\.ref), ["section[__TEXT,__text]"])
        XCTAssertEqual(output.result.outcome, "narrowed")
        XCTAssertTrue(output.result.facts.isEmpty)
        XCTAssertEqual(output.result.budget, ["bytes": 80, "wallMillis": 0])

        let item = try XCTUnwrap(output.result.frontier.first)
        XCTAssertEqual(output.result.frontier.count, 1)
        XCTAssertEqual(item.gap, "boundaryUncertain")
        XCTAssertEqual(item.missingEvidence, ["functionStarts", "exports", "nlist", "unwind"])
        XCTAssertEqual(item.primitives.first?.name, "derive.function-start-call-target")
        XCTAssertEqual(item.detail,
                       "0x1000000e8: no loader table lists the address (searched functionStarts, exports, nlist, unwind)")
        XCTAssertTrue(NavigatorContractValidator.validateResult(output.result.json).isEmpty)
    }

    func testUnalignedAddressIsInsufficientEvidence() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let evidence = try ProofFixtures.evidence(fixture.bytes)
        let output = FunctionStartStructuralProof.run(entry: fixture.baseAddress + 2, evidence: evidence,
                                                      toolchain: toolchain, clock: { 0 })
        XCTAssertEqual(output.certificate?.outcome, .insufficientEvidence)
        XCTAssertEqual(output.result.frontier.first?.missingEvidence,
                       ["alignment", "functionStarts", "exports", "nlist", "unwind"])
        XCTAssertTrue(output.certificate?.conclusion.contains("not 4-byte aligned") ?? false)
        XCTAssertTrue(NavigatorContractValidator.validateResult(output.result.json).isEmpty)
    }

    func testAddressOutsideEverySectionIsInsufficientEvidence() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let evidence = try ProofFixtures.evidence(fixture.bytes)
        let output = FunctionStartStructuralProof.run(entry: 0x2000, evidence: evidence, toolchain: toolchain, clock: { 0 })
        let certificate = try XCTUnwrap(output.certificate)
        XCTAssertEqual(certificate.outcome, .insufficientEvidence)
        XCTAssertTrue(certificate.premises.isEmpty)
        XCTAssertEqual(certificate.budget.bytesRead, 0)
        XCTAssertEqual(output.result.frontier.first?.missingEvidence,
                       ["executableSection", "functionStarts", "exports", "nlist", "unwind"])
        XCTAssertTrue(NavigatorContractValidator.validateResult(output.result.json).isEmpty)
    }

    func testAddressInANonExecutableSectionIsInsufficientEvidence() throws {
        // Unwind fixture __unwind_info holds no instructions, and no loader table lists its first byte.
        let binary = try ProofFixtures.unwindLoops()
        let evidence = try XCTUnwrap(NavigatorImageEvidence(binary: binary))
        let output = FunctionStartStructuralProof.run(entry: 0x4e8, evidence: evidence, toolchain: toolchain, clock: { 0 })
        XCTAssertEqual(output.certificate?.outcome, .insufficientEvidence)
        XCTAssertEqual(output.result.frontier.first?.missingEvidence.first, "executableSection")
        XCTAssertTrue(NavigatorContractValidator.validateResult(output.result.json).isEmpty)
    }

    // MARK: - Budget and cancellation

    func testWallClockBudgetStopsBetweenTables() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let evidence = try ProofFixtures.evidence(fixture.bytes)
        // Each clock read advances one millisecond: start 0, first check 1, functionStarts 2, exports 3 > 2.
        var tick: Int64 = 0
        let output = FunctionStartStructuralProof.run(
            entry: fixture.baseAddress, evidence: evidence, toolchain: toolchain, wallMillisLimit: 2,
            clock: { defer { tick += 1 }; return tick })
        let certificate = try XCTUnwrap(output.certificate)
        XCTAssertEqual(certificate.outcome, .timeout)
        XCTAssertEqual(certificate.premises.map(\.ref), ["section[__TEXT,__text]", "lc[1]", "functionStarts[0]@0x1000000e0"])
        XCTAssertTrue(certificate.conclusion.contains("run stopped (timeout)"))
        XCTAssertEqual(output.result.outcome, "refusal")
        XCTAssertTrue(output.result.facts.isEmpty)
        let refusal = try XCTUnwrap(output.result.refusal)
        XCTAssertEqual(refusal.code, "budgetExceeded")
        XCTAssertTrue(refusal.retryable)
        XCTAssertEqual(refusal.detail, "proof.function-start-structural@1 exceeded wallMillis 2")
        XCTAssertEqual(output.result.budget, ["bytes": 98, "wallMillis": 4])
        XCTAssertTrue(NavigatorContractValidator.validateResult(output.result.json).isEmpty)
    }

    func testCancellationBeforeTheFirstStep() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let evidence = try ProofFixtures.evidence(fixture.bytes)
        let output = FunctionStartStructuralProof.run(entry: fixture.baseAddress, evidence: evidence, toolchain: toolchain,
                                                      clock: { 0 }, isCancelled: { true })
        let certificate = try XCTUnwrap(output.certificate)
        XCTAssertEqual(certificate.outcome, .cancelled)
        XCTAssertTrue(certificate.premises.isEmpty)
        let refusal = try XCTUnwrap(output.result.refusal)
        XCTAssertEqual(refusal.code, "cancelled")
        XCTAssertTrue(refusal.retryable)
        XCTAssertEqual(output.result.budget, ["bytes": 0, "wallMillis": 0])
        XCTAssertTrue(NavigatorContractValidator.validateResult(output.result.json).isEmpty)
    }

    func testCancellationBetweenTables() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let evidence = try ProofFixtures.evidence(fixture.bytes)
        // Polls: first check, functionStarts, exports -> cancelled on the third poll.
        var polls = 0
        let output = FunctionStartStructuralProof.run(
            entry: fixture.baseAddress, evidence: evidence, toolchain: toolchain, clock: { 0 },
            isCancelled: { polls += 1; return polls >= 3 })
        XCTAssertEqual(output.certificate?.outcome, .cancelled)
        XCTAssertEqual(output.certificate?.premises.map(\.ref),
                       ["section[__TEXT,__text]", "lc[1]", "functionStarts[0]@0x1000000e0"])
        XCTAssertEqual(output.result.refusal?.code, "cancelled")
    }

    // MARK: - Derived rule

    func testDerivesTheTargetOfADirectCallFromAProvenStart() throws {
        let fixture = ProofFixtures.functionStartsWithoutSecondEntry()
        let evidence = try ProofFixtures.evidence(fixture.bytes)
        let caller = fixture.baseAddress
        let target = caller + 0x1c
        XCTAssertEqual(evidence.functionStartEntries.map(\.address), [caller])

        let proof = FunctionStartStructuralProof.run(entry: caller, evidence: evidence, toolchain: toolchain, clock: { 0 })
        let provenFact = try XCTUnwrap(proof.result.facts.first)
        // The target alone is not provable from loader records.
        let unlisted = FunctionStartStructuralProof.run(entry: target, evidence: evidence, toolchain: toolchain, clock: { 0 })
        XCTAssertEqual(unlisted.certificate?.outcome, .insufficientEvidence)

        let function = FunctionSummary(id: UUID(), name: "entry", startAddress: caller, endAddress: target, confidence: 1)
        let result = FunctionStartCallTargetDerivation.run(target: target, evidence: evidence, provenFacts: [provenFact],
                                                           functions: [function], toolchain: toolchain)
        XCTAssertEqual(result.outcome, "facts")
        XCTAssertEqual(result.primitive, "derive.function-start-call-target")
        XCTAssertEqual(result.primitiveVersion, "1")
        XCTAssertEqual(result.budget, ["instructions": 7, "bytes": 28])
        let fact = try XCTUnwrap(result.facts.first)
        XCTAssertEqual(fact.status, "derived")
        XCTAssertNotEqual(fact.status, "proven")
        XCTAssertEqual(fact.tier, 2)
        XCTAssertEqual(fact.derivedFrom, [[provenFact.id]])
        XCTAssertEqual(fact.subject, NavigatorSubject(kind: "function", ref: "0x1000000fc"))
        XCTAssertEqual(fact.predicate, "isFunctionStart")
        XCTAssertEqual(fact.value, .bool(true))
        XCTAssertEqual(fact.provenance, [
            FunctionStartCallTargetDerivation.ruleProvenance,
            NavigatorProvenance(kind: "decodedInstruction", ref: "0x1000000f8"),
        ])
        XCTAssertFalse(fact.provenance.contains { $0.kind == "proofCertificate" })
        XCTAssertTrue(NavigatorProvenanceResolver.resolve(fact.provenance[1], in: evidence).isResolved)
        XCTAssertNil(NavigatorContractValidator.certificateRefusal(for: fact) { _ in nil })
        XCTAssertTrue(NavigatorContractValidator.validateResult(result.json).isEmpty)

        // A state holding the proven caller and the derived callee is valid.
        let state = NavigatorEngineState(toolchain: toolchain, facts: [provenFact, fact])
        XCTAssertTrue(NavigatorContractValidator.validateState(state.json).isEmpty)
    }

    func testDerivationRefusesListedAndUnalignedTargets() throws {
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let evidence = try ProofFixtures.evidence(fixture.bytes)
        let listed = FunctionStartCallTargetDerivation.run(target: fixture.baseAddress + 0x1c, evidence: evidence,
                                                           provenFacts: [], functions: [], toolchain: toolchain)
        XCTAssertEqual(listed.refusal?.code, "preconditionFailed")
        XCTAssertEqual(listed.refusal?.retryable, false)
        XCTAssertTrue(listed.refusal?.detail.contains("proof.function-start-structural applies") ?? false)
        XCTAssertTrue(NavigatorContractValidator.validateResult(listed.json).isEmpty)

        let unaligned = FunctionStartCallTargetDerivation.run(target: fixture.baseAddress + 0x1a, evidence: evidence,
                                                              provenFacts: [], functions: [], toolchain: toolchain)
        XCTAssertEqual(unaligned.refusal?.code, "preconditionFailed")
        XCTAssertEqual(unaligned.budget, [:])

        let outside = FunctionStartCallTargetDerivation.run(target: 0x2000, evidence: evidence,
                                                            provenFacts: [], functions: [], toolchain: toolchain)
        XCTAssertEqual(outside.refusal?.code, "preconditionFailed")
        XCTAssertTrue(NavigatorContractValidator.validateResult(outside.json).isEmpty)
    }

    func testDerivationWithoutAProvenCallerNarrows() throws {
        let fixture = ProofFixtures.functionStartsWithoutSecondEntry()
        let evidence = try ProofFixtures.evidence(fixture.bytes)
        let caller = fixture.baseAddress
        let target = caller + 0x1c
        let function = FunctionSummary(id: UUID(), name: "entry", startAddress: caller, endAddress: target, confidence: 1)

        let result = FunctionStartCallTargetDerivation.run(target: target, evidence: evidence, provenFacts: [],
                                                           functions: [function], toolchain: toolchain)
        XCTAssertEqual(result.outcome, "narrowed")
        XCTAssertEqual(result.budget, ["instructions": 0, "bytes": 0])
        let item = try XCTUnwrap(result.frontier.first)
        XCTAssertEqual(item.gap, "boundaryUncertain")
        XCTAssertEqual(item.missingEvidence, ["functionStarts", "exports", "nlist", "unwind", "directCallFromProvenStart"])
        XCTAssertTrue(NavigatorContractValidator.validateResult(result.json).isEmpty)

        // A derived (not proven) caller does not qualify either.
        let derivedCaller = try NavigatorFact.make(
            subject: NavigatorSubject(kind: "function", ref: NavigatorSubjectRef.address(caller)),
            predicate: "isFunctionStart", value: .bool(true), status: "derived",
            provenance: [FunctionStartCallTargetDerivation.ruleProvenance], toolchain: toolchain, tier: 2,
            derivedFrom: [["f-0123456789abcdef0123456789abcdef"]])
        XCTAssertNil(FunctionStartCallTargetDerivation.provenEntry(derivedCaller, image: nil))
        let stillNarrowed = FunctionStartCallTargetDerivation.run(target: target, evidence: evidence,
                                                                  provenFacts: [derivedCaller], functions: [function],
                                                                  toolchain: toolchain)
        XCTAssertEqual(stillNarrowed.outcome, "narrowed")

        // A proven caller whose function summary is missing contributes no call sites.
        let proof = FunctionStartStructuralProof.run(entry: caller, evidence: evidence, toolchain: toolchain, clock: { 0 })
        let provenFact = try XCTUnwrap(proof.result.facts.first)
        XCTAssertEqual(FunctionStartCallTargetDerivation.provenEntry(provenFact, image: nil), caller)
        XCTAssertNil(FunctionStartCallTargetDerivation.provenEntry(provenFact, image: "other/0123456789abcdef"))
        let noSummary = FunctionStartCallTargetDerivation.run(target: target, evidence: evidence,
                                                              provenFacts: [provenFact], functions: [], toolchain: toolchain)
        XCTAssertEqual(noSummary.outcome, "narrowed")
    }

    func testDirectCallTargetDecoding() {
        XCTAssertEqual(FunctionStartCallTargetDerivation.directCallTarget(word: 0x9400_0001, at: 0x1000), 0x1004)
        XCTAssertEqual(FunctionStartCallTargetDerivation.directCallTarget(word: 0x97ff_ffff, at: 0x1000), 0xffc)
        XCTAssertEqual(FunctionStartCallTargetDerivation.directCallTarget(word: 0x9600_0000, at: 0x1000_0000),
                       0x800_0000)
        XCTAssertEqual(FunctionStartCallTargetDerivation.directCallTarget(word: 0x95ff_ffff, at: 0),
                       0x7ff_fffc)
        // ret, b (not a call) and blr (indirect) are not direct calls.
        XCTAssertNil(FunctionStartCallTargetDerivation.directCallTarget(word: 0xd65f_03c0, at: 0x1000))
        XCTAssertNil(FunctionStartCallTargetDerivation.directCallTarget(word: 0x1400_0001, at: 0x1000))
        XCTAssertNil(FunctionStartCallTargetDerivation.directCallTarget(word: 0xd63f_0100, at: 0x1000))
    }

    // MARK: - Registry descriptors

    func testRegistryDescriptors() {
        let proof = NavigatorPrimitiveDescriptor.functionStartStructuralProof
        XCTAssertEqual(proof.id, FunctionStartStructuralProof.rule)
        XCTAssertEqual(proof.version, FunctionStartStructuralProof.ruleVersion)
        XCTAssertEqual(proof.producesStatus, "proven")
        XCTAssertEqual(proof.costClass, "cheap")
        XCTAssertEqual(proof.inputs, [])
        XCTAssertEqual(proof.outputs, ["isFunctionStart", "boundaryUncertain"])
        XCTAssertEqual(proof.onOutOfRange, "abstain")
        XCTAssertTrue(proof.isImplemented)
        XCTAssertEqual(proof.applicability.archs, ["arm64", "arm64e"])

        let derived = NavigatorPrimitiveDescriptor.functionStartCallTargetDerivation
        XCTAssertEqual(derived.id, FunctionStartCallTargetDerivation.rule)
        XCTAssertEqual(derived.version, FunctionStartCallTargetDerivation.ruleVersion)
        XCTAssertEqual(derived.producesStatus, "derived")
        XCTAssertEqual(derived.costClass, "bounded")
        XCTAssertEqual(derived.inputs, ["isFunctionStart"])
        XCTAssertEqual(derived.outputs, ["isFunctionStart", "boundaryUncertain"])
        XCTAssertTrue(derived.isImplemented)

        XCTAssertTrue(NavigatorPrimitiveRegistry.costClasses.contains(proof.costClass))
        XCTAssertTrue(NavigatorPrimitiveRegistry.costClasses.contains(derived.costClass))
        XCTAssertTrue(NavigatorPrimitiveRegistry.outOfRangePolicies.contains(proof.onOutOfRange))
        XCTAssertTrue(NavigatorPrimitiveRegistry.producibleStatuses.contains(proof.producesStatus))
        XCTAssertTrue(NavigatorPrimitiveRegistry.producibleStatuses.contains(derived.producesStatus))
        for name in proof.outputs + derived.outputs + derived.inputs {
            XCTAssertTrue(NavigatorContractVocabulary.predicate(named: name) != nil
                || NavigatorContractVocabulary.gaps.containsExactly(name), name)
        }
    }
}

private enum ProofFixtures {
    static let unwindImageRef = "9f20e834-0ec1-31f0-aa9c-6153bbab70c6/e4957a86d91eb372"

    static func binary(_ bytes: Data, identity: MachOSliceArtifactIdentity? = nil) -> LoadedBinary {
        LoadedBinary(
            name: "proof-fixture", path: "/tmp/proof-fixture", isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64,
            fileTypeName: "fixture", architectureDisplayName: "arm64",
            metadata: .empty,
            artifactIdentity: identity,
            bytes: bytes,
            sliceOffset: 0,
            sliceSize: UInt64(bytes.count),
            sections: [], executableTextSection: nil, entryPointAddress: nil,
            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            functionStarts: [], objcSelectors: [:]
        )
    }

    static func evidence(_ bytes: Data) throws -> NavigatorImageEvidence {
        try XCTUnwrap(NavigatorImageEvidence(binary: binary(bytes)))
    }

    /// `UnwindLoops.dylib` with the identity its existing oracle test records (no re-hash).
    static func unwindLoops() throws -> LoadedBinary {
        let url = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent("UnwindLoops.dylib")
        let bytes = try Data(contentsOf: url)
        let identity = try MachOSliceArtifactIdentity(
            uuid: UUID(uuidString: "9f20e834-0ec1-31f0-aa9c-6153bbab70c6"), rawCPUType: 0x0100000c, rawCPUSubtype: 0,
            selectedSliceSHA256: "e4957a86d91eb3722f975b48aee12bace61211e7a737a56a9249dad9b598d8d1",
            selectedSliceByteCount: 17480)
        return binary(bytes, identity: identity)
    }

    /// The function-starts fixture with its second delta (0x1c, the `bl` target) zeroed, so
    /// `LC_FUNCTION_STARTS` lists only the entry and the callee is reachable only through the `bl`.
    static func functionStartsWithoutSecondEntry() -> MachOFixture {
        var fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let startsOffset = (fixture.codeOffset + fixture.code.count + 7) & ~7
        precondition(fixture.bytes[fixture.bytes.startIndex + startsOffset + 2] == 0x1c)
        fixture.bytes[fixture.bytes.startIndex + startsOffset + 2] = 0
        return fixture
    }
}
