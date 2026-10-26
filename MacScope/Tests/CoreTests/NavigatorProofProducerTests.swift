import Foundation
import XCTest
@testable import MacScope

/// The proof producer of the navigator bridge: one run over the function-starts fixture with its
/// second loader entry removed (the entry is proven from `LC_FUNCTION_STARTS`; the `bl` target is
/// derived from the proven caller), and the landing guards on a workspace. Hermetic: the workspace
/// binary carries no bytes, so no producer task is scheduled; outcomes are landed by hand.
@MainActor
final class NavigatorProofProducerTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    private func identity() throws -> MachOSliceArtifactIdentity {
        try MachOSliceArtifactIdentity(uuid: nil, rawCPUType: MachOConstants.cpuTypeARM64, rawCPUSubtype: 0,
                                       selectedSliceSHA256: digest, selectedSliceByteCount: 256)
    }

    private func makeStore() throws -> WorkspaceStore {
        let binary = BinaryImage(id: UUID(), name: "fixture", path: "/not-opened/fixture", kind: "raw fixture",
                                 architecture: "arm64", artifactIdentity: try identity())
        return WorkspaceStore(workspaceName: "Navigator proof producer fixture",
                              snapshot: .init(binaries: [binary], analysisBySlot: [.primary: ImageAnalysis()]),
                              engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    /// The fixture with only the entry listed: the callee at `base + 0x1c` is reachable only through
    /// the `bl` at `base + 0x18`.
    private func fixtureBytes() -> (bytes: Data, base: UInt64) {
        var fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let startsOffset = (fixture.codeOffset + fixture.code.count + 7) & ~7
        precondition(fixture.bytes[fixture.bytes.startIndex + startsOffset + 2] == 0x1c)
        fixture.bytes[fixture.bytes.startIndex + startsOffset + 2] = 0
        return (fixture.bytes, fixture.baseAddress)
    }

    private func functions(base: UInt64) -> [FunctionSummary] {
        [FunctionSummary(id: UUID(), name: "entry", startAddress: base, endAddress: base + 0x1c, confidence: 1),
         FunctionSummary(id: UUID(), name: "callee", startAddress: base + 0x1c, endAddress: base + 0x20, confidence: 1)]
    }

    private func generation() -> NavigatorGeneration {
        NavigatorGeneration(imageIdentity: "fixture", inputKey: "input", knowledgeVersion: "knowledge")
    }

    private func input(fence: NavigatorLandingFence, runID: UUID = UUID()) -> NavigatorProofProducerInput {
        let (bytes, base) = fixtureBytes()
        return NavigatorProofProducerInput(runID: runID, slot: .primary, imageBytes: bytes, identity: nil,
                                           generation: generation(), fence: fence, functions: functions(base: base))
    }

    private func fence(_ store: WorkspaceStore) -> NavigatorLandingFence {
        store.navigatorLandingFence(for: .primary)
    }

    private func liveFacts(_ store: WorkspaceStore) -> [NavigatorFact] {
        (store.navigatorState(for: .primary)?.liveFacts() ?? [:]).values.sorted { $0.id < $1.id }
    }

    // MARK: - The run

    func testRunProvesListedStartAndDerivesCallTarget() throws {
        let fence = NavigatorLandingFence(documentInstallationID: UUID(), workspaceEpoch: 0, landingEpoch: 0, binaryID: nil)
        let input = input(fence: fence)
        let base = input.functions[0].startAddress
        let outcome = NavigatorStateBridge.runProofProducer(input)
        guard case .landed(let results, let certificates, let toolchain, let refusals) = outcome else {
            return XCTFail("expected a landed outcome, got \(outcome)")
        }
        XCTAssertTrue(refusals.isEmpty, "\(refusals)")
        XCTAssertFalse(toolchain.isEmpty)
        XCTAssertEqual(results.map(\.primitive), [FunctionStartStructuralProof.rule, FunctionStartCallTargetDerivation.rule])
        XCTAssertEqual(results.map(\.primitiveVersion), ["1", "1"])

        let proof = results[0]
        XCTAssertEqual(proof.outcome, "facts")
        XCTAssertEqual(proof.subject.kind, "image")
        let proven = try XCTUnwrap(proof.facts.first)
        XCTAssertEqual(proof.facts.count, 1)
        XCTAssertEqual(proven.status, "proven")
        XCTAssertEqual(proven.predicate, "isFunctionStart")
        XCTAssertEqual(proven.subject.ref, NavigatorSubjectRef.function(entry: base))
        XCTAssertEqual(proven.generation, input.generation)
        XCTAssertEqual(proven.dependsOn, NavigatorStateBridge.proofDependsOn.uniqueSortedByScalars())
        // The derivation resolved the callee, so the proof result carries no boundaryUncertain item.
        XCTAssertTrue(proof.frontier.isEmpty, "\(proof.frontier.map(\.detail))")

        let derivation = results[1]
        XCTAssertEqual(derivation.outcome, "facts")
        let derived = try XCTUnwrap(derivation.facts.first)
        XCTAssertEqual(derivation.facts.count, 1)
        XCTAssertEqual(derived.status, "derived")
        XCTAssertEqual(derived.subject.ref, NavigatorSubjectRef.function(entry: base + 0x1c))
        XCTAssertEqual(derived.derivedFrom, [[proven.id]])
        XCTAssertEqual(derived.generation, input.generation)
        XCTAssertEqual(derived.dependsOn, NavigatorStateBridge.derivationDependsOn.uniqueSortedByScalars())
        XCTAssertTrue(derivation.frontier.isEmpty)

        // The proven fact's certificate is the one retained, and it resolves the fact.
        XCTAssertEqual(certificates.count, 1)
        let certificate = try XCTUnwrap(certificates.first)
        XCTAssertEqual(certificate.outcome, .proven)
        XCTAssertTrue(certificate.supports(proven))
        XCTAssertNil(NavigatorContractValidator.certificateRefusal(for: proven) { $0 == certificate.hash ? certificate : nil })
        XCTAssertNotNil(NavigatorContractValidator.certificateRefusal(for: proven) { _ in nil })
    }

    func testRunSkipsWithoutFunctionsOrParseableSlice() {
        let fence = NavigatorLandingFence(documentInstallationID: UUID(), workspaceEpoch: 0, landingEpoch: 0, binaryID: nil)
        var empty = input(fence: fence)
        empty.functions = []
        guard case .skipped(let reason) = NavigatorStateBridge.runProofProducer(empty) else {
            return XCTFail("expected skipped without functions")
        }
        XCTAssertNil(reason)

        var garbage = input(fence: fence)
        garbage.imageBytes = Data(repeating: 0xff, count: 64)
        guard case .skipped(let parseReason) = NavigatorStateBridge.runProofProducer(garbage) else {
            return XCTFail("expected skipped for an unparseable slice")
        }
        XCTAssertEqual(parseReason, "slice does not parse as a thin Mach-O image")
    }

    // MARK: - Landing

    func testLandingAddsBothResultsAndRetainsCertificates() throws {
        let store = try makeStore()
        let input = input(fence: fence(store))
        let outcome = NavigatorStateBridge.runProofProducer(input)
        store.navigatorProducerRunsBySlot[.primary] = NavigatorProducerRun(id: input.runID, task: Task {})
        store.landNavigatorProofOutcome(outcome, input: input)

        XCTAssertNil(store.navigatorProducerRunsBySlot[.primary])
        let facts = liveFacts(store)
        XCTAssertEqual(Set(facts.map(\.status)), ["proven", "derived"])
        XCTAssertEqual(facts.count, 2)
        let certificates = store.navigatorCertificates(in: .primary)
        XCTAssertEqual(certificates.count, 1)
        let proven = try XCTUnwrap(facts.first { $0.status == "proven" })
        XCTAssertTrue(certificates[0].supports(proven))
        XCTAssertTrue(proven.provenance.contains { $0.kind == "proofCertificate" && $0.ref == certificates[0].hash })
        guard case .landed(_, _, let toolchain, _) = outcome else { return XCTFail("expected landed") }
        XCTAssertEqual(store.navigatorState(for: .primary)?.toolchain, toolchain)
        XCTAssertNotEqual(store.navigatorState(for: .primary)?.toolchain, NavigatorStateBridge.pendingToolchain)

        // Dropping the slot's state drops its certificates too.
        store.dropNavigatorState(in: .primary)
        XCTAssertTrue(store.navigatorCertificates(in: .primary).isEmpty)
        XCTAssertNil(store.navigatorState(for: .primary))
    }

    func testLandingDropsProvenFactsWithoutARetainedCertificate() throws {
        let store = try makeStore()
        let input = input(fence: fence(store))
        guard case .landed(let results, _, let toolchain, _) = NavigatorStateBridge.runProofProducer(input) else {
            return XCTFail("expected landed")
        }
        store.navigatorProducerRunsBySlot[.primary] = NavigatorProducerRun(id: input.runID, task: Task {})
        store.landNavigatorProofOutcome(.landed(results: results, certificates: [], toolchain: toolchain, refusals: []),
                                        input: input)
        // The proven fact cannot be resolved, so it is not landed; the derived fact rests on it and is
        // refused by the store (unknown premise). Nothing proven reaches the store.
        XCTAssertTrue(liveFacts(store).isEmpty, "\(liveFacts(store).map(\.status))")
        XCTAssertTrue(store.navigatorCertificates(in: .primary).isEmpty)
        XCTAssertNil(store.navigatorProducerRunsBySlot[.primary])
    }

    func testLandingIsDroppedWhenTheFenceOrRunChanged() throws {
        let store = try makeStore()
        var stale = fence(store)
        stale.workspaceEpoch += 1
        let input = input(fence: stale)
        let outcome = NavigatorStateBridge.runProofProducer(input)
        store.navigatorProducerRunsBySlot[.primary] = NavigatorProducerRun(id: input.runID, task: Task {})
        store.landNavigatorProofOutcome(outcome, input: input)
        XCTAssertNil(store.navigatorState(for: .primary))
        XCTAssertTrue(store.navigatorCertificates(in: .primary).isEmpty)
        XCTAssertNil(store.navigatorProducerRunsBySlot[.primary], "a fenced-out run is still retired")

        // A run that is no longer the slot's current run lands nothing and leaves the current run alone.
        let current = self.input(fence: fence(store))
        let superseded = NavigatorProducerRun(id: UUID(), task: Task {})
        store.navigatorProducerRunsBySlot[.primary] = superseded
        store.landNavigatorProofOutcome(NavigatorStateBridge.runProofProducer(current), input: current)
        XCTAssertNil(store.navigatorState(for: .primary))
        XCTAssertEqual(store.navigatorProducerRunsBySlot[.primary]?.id, superseded.id)
    }

    func testCancelledAndSkippedOutcomesLandNothing() throws {
        let store = try makeStore()
        let input = input(fence: fence(store))
        store.navigatorProducerRunsBySlot[.primary] = NavigatorProducerRun(id: input.runID, task: Task {})
        store.landNavigatorProofOutcome(.cancelled, input: input)
        XCTAssertNil(store.navigatorState(for: .primary))
        XCTAssertNil(store.navigatorProducerRunsBySlot[.primary])

        store.navigatorProducerRunsBySlot[.primary] = NavigatorProducerRun(id: input.runID, task: Task {})
        store.landNavigatorProofOutcome(.skipped(reason: "no functions"), input: input)
        XCTAssertNil(store.navigatorState(for: .primary))
        XCTAssertNil(store.navigatorProducerRunsBySlot[.primary])
    }

    func testRemapAndResetMoveAndDropCertificatesWithTheState() throws {
        let store = try makeStore()
        let input = input(fence: fence(store))
        store.navigatorProducerRunsBySlot[.primary] = NavigatorProducerRun(id: input.runID, task: Task {})
        store.landNavigatorProofOutcome(NavigatorStateBridge.runProofProducer(input), input: input)
        XCTAssertEqual(store.navigatorCertificates(in: .primary).count, 1)

        // Renumbering moves the certificates with the store (no binary in the new slot, so no run starts).
        let other = ImageSlot(rawValue: 7)
        store.remapNavigatorState(from: .primary, to: other)
        XCTAssertTrue(store.navigatorCertificates(in: .primary).isEmpty)
        XCTAssertEqual(store.navigatorCertificates(in: other).count, 1)
        XCTAssertNotNil(store.navigatorState(for: other))
        XCTAssertNil(store.navigatorProducerRunsBySlot[other])

        store.resetNavigatorStates()
        XCTAssertTrue(store.navigatorCertificates(in: other).isEmpty)
        XCTAssertNil(store.navigatorState(for: other))
        XCTAssertTrue(store.navigatorCertificates(in: .primary).isEmpty)
        XCTAssertNil(store.navigatorState(for: .primary))
    }
}
