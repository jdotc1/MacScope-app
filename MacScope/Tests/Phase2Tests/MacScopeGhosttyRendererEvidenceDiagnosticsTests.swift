import Darwin
import Dispatch
import Foundation

#if MACSCOPE_GHOSTTY_RENDERER_EVIDENCE_FOCUSED_MAIN
@main
private enum MacScopeGhosttyRendererEvidenceFocusedMain {
    static func main() {
        let scenarios: [(String, () throws -> Void)] = [
            ("full surface exact PID evidence", MacScopeGhosttyRendererEvidenceScenarios.fullSurface),
            ("positive PID binding validation", MacScopeGhosttyRendererEvidenceScenarios.invalidProcessIdentifier),
            ("PID mismatch fails closed", MacScopeGhosttyRendererEvidenceScenarios.processIdentifierMismatch),
            ("legacy grid no-generation evidence", MacScopeGhosttyRendererEvidenceScenarios.forcedLegacyGrid),
            ("transcript fallback rejection", MacScopeGhosttyRendererEvidenceScenarios.transcriptFallbackRejection),
            ("stale generation fails closed", MacScopeGhosttyRendererEvidenceScenarios.staleGeneration),
            ("retirement fails closed", MacScopeGhosttyRendererEvidenceScenarios.retirement),
            ("no renderer fails closed", MacScopeGhosttyRendererEvidenceScenarios.noRenderer),
            ("wait wakes on evidence", MacScopeGhosttyRendererEvidenceScenarios.waitWakeup),
            ("wait times out without evidence", MacScopeGhosttyRendererEvidenceScenarios.waitTimeout),
            ("bounded eviction", MacScopeGhosttyRendererEvidenceScenarios.boundedEviction),
            ("renderer lifecycle ordering", MacScopeGhosttyRendererEvidenceScenarios.rendererLifecycleOrdering),
            ("renderer lifecycle callback fencing", MacScopeGhosttyRendererEvidenceScenarios.rendererLifecycleCallbackFencing),
            ("renderer lifecycle same-binding stability", MacScopeGhosttyRendererEvidenceScenarios.rendererLifecycleSameBindingStability),
        ]
        var failureCount = 0
        for (name, scenario) in scenarios {
            do {
                try scenario()
                print("PASS: \(name)")
            } catch {
                failureCount += 1
                FileHandle.standardError.write(Data("FAIL: \(name): \(error)\n".utf8))
            }
        }
        if failureCount > 0 { exit(1) }
    }
}
#else
import XCTest

@testable import MacScope

final class MacScopeGhosttyRendererEvidenceDiagnosticsTests: XCTestCase {
    func testFullSurfaceEvidence() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.fullSurface()
    }

    func testRendererBindingRejectsInvalidProcessIdentifier() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.invalidProcessIdentifier()
    }

    func testProcessIdentifierMismatchFailsClosed() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.processIdentifierMismatch()
    }

    func testForcedLegacyGridEvidence() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.forcedLegacyGrid()
    }

    func testTranscriptFallbackRejectionEvidence() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.transcriptFallbackRejection()
    }

    func testStaleGenerationFailsClosed() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.staleGeneration()
    }

    func testRetirementFailsClosed() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.retirement()
    }

    func testMissingInstantiationFailsClosed() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.noRenderer()
    }

    func testWaitWakesWhenExactEvidenceIsRecorded() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.waitWakeup()
    }

    func testWaitTimesOutWithoutExactEvidence() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.waitTimeout()
    }

    func testEvidenceStorageIsBoundedAndAccountsForEviction() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.boundedEviction()
    }

    func testRendererLifecycleSerializesReplacementEvidence() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.rendererLifecycleOrdering()
    }

    func testRendererLifecycleFencesStaleAndRetiredCallbacks() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.rendererLifecycleCallbackFencing()
    }

    func testRendererLifecycleKeepsOneSameBindingObservation() throws {
        try MacScopeGhosttyRendererEvidenceScenarios.rendererLifecycleSameBindingStability()
    }
}
#endif

private enum MacScopeGhosttyRendererEvidenceScenarioError: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): message
        }
    }
}

private enum MacScopeGhosttyRendererEvidenceScenarios {
    typealias Diagnostics = MacScopeGhosttySurfaceDiagnostics

    private static let sessionID = UUID(
        uuidString: "10000000-0000-0000-0000-000000000001"
    )!
    private static let requestID = UUID(
        uuidString: "20000000-0000-0000-0000-000000000001"
    )!
    private static let shellBrokerProcessIdentifier: Int32 = 4_242

    static func fullSurface() throws {
        let diagnostics = Diagnostics(capacity: 4)
        let observation = rendererObservation(
            binding: binding(generation: .exact(7)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        try require(
            diagnostics.recordRendererInstantiation(observation) == .recorded(sequence: 1),
            "full-surface instantiation was not recorded"
        )
        try require(
            diagnostics.waitForRendererEvidence(
                for: observation.binding,
                timeout: 0
            ) == .instantiated(.init(observation: observation, lifecycle: .instantiated)),
            "wait seam did not return exact full-surface evidence"
        )
        try require(
            observation.binding.shellBrokerProcessIdentifier
                == shellBrokerProcessIdentifier,
            "full-surface evidence omitted the exact ShellBroker PID"
        )
    }

    static func invalidProcessIdentifier() throws {
        try require(
            Diagnostics.RendererBinding(
                sessionID: sessionID,
                requestID: requestID,
                shellBrokerProcessIdentifier: 0,
                generation: .exact(1)
            ) == nil,
            "zero PID formed renderer evidence"
        )
        try require(
            Diagnostics.RendererBinding(
                sessionID: sessionID,
                requestID: requestID,
                shellBrokerProcessIdentifier: -1,
                generation: .notAllocated
            ) == nil,
            "negative PID formed renderer evidence"
        )
    }

    static func processIdentifierMismatch() throws {
        let diagnostics = Diagnostics(capacity: 4)
        let current = rendererObservation(
            binding: binding(
                processIdentifier: shellBrokerProcessIdentifier,
                generation: .exact(5)
            ),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        let mismatched = rendererObservation(
            binding: binding(
                processIdentifier: shellBrokerProcessIdentifier + 1,
                generation: .exact(99)
            ),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        _ = diagnostics.recordRendererInstantiation(current)

        let expectedMismatch: Diagnostics.RendererResolution
            = .shellBrokerProcessIdentifierMismatch(
                observed: shellBrokerProcessIdentifier
            )
        try require(
            diagnostics.rendererSnapshot().resolution(for: mismatched.binding)
                == expectedMismatch,
            "wrong-PID resolution borrowed exact renderer evidence"
        )
        try require(
            diagnostics.waitForRendererEvidence(for: mismatched.binding, timeout: 1)
                == expectedMismatch,
            "wrong-PID wait did not fail immediately"
        )
        try require(
            diagnostics.recordRendererInstantiation(mismatched)
                == .shellBrokerProcessIdentifierMismatch(
                    observed: shellBrokerProcessIdentifier
                ),
            "wrong-PID instantiation was admitted"
        )
        try require(
            diagnostics.recordRendererRetirement(mismatched)
                == .shellBrokerProcessIdentifierMismatch(
                    observed: shellBrokerProcessIdentifier
                ),
            "wrong-PID retirement affected the live renderer"
        )
        try require(
            diagnostics.rendererSnapshot().resolution(for: current.binding)
                == .instantiated(.init(observation: current, lifecycle: .instantiated)),
            "wrong-PID operations retired or superseded the live renderer"
        )
    }

    static func forcedLegacyGrid() throws {
        let diagnostics = Diagnostics(capacity: 4)
        let observation = rendererObservation(
            binding: binding(generation: .notAllocated),
            requestedMode: .macScopeGhosttyVTGrid,
            observedMode: .macScopeGhosttyVTGrid,
            fallbackReason: .recoveryOverride
        )
        try require(
            diagnostics.recordRendererInstantiation(observation) == .recorded(sequence: 1),
            "forced legacy-grid instantiation was not recorded"
        )
        try require(
            diagnostics.rendererSnapshot().resolution(for: observation.binding)
                == .instantiated(.init(observation: observation, lifecycle: .instantiated)),
            "forced legacy grid was not distinguishable from transcript fallback"
        )
        try require(
            observation.binding.generation == .notAllocated,
            "legacy-grid evidence invented a native generation"
        )

        let invalidLegacyGeneration = rendererObservation(
            binding: binding(generation: .exact(7)),
            requestedMode: .macScopeGhosttyVTGrid,
            observedMode: .macScopeGhosttyVTGrid,
            fallbackReason: .recoveryOverride
        )
        try require(
            Diagnostics(capacity: 1).recordRendererInstantiation(invalidLegacyGeneration)
                == .invalidObservation,
            "legacy-grid evidence accepted a native generation"
        )
        let invalidNativeGeneration = rendererObservation(
            binding: binding(generation: .notAllocated),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        try require(
            Diagnostics(capacity: 1).recordRendererInstantiation(invalidNativeGeneration)
                == .invalidObservation,
            "full-surface evidence omitted its native generation"
        )
        let zeroNativeGeneration = rendererObservation(
            binding: binding(generation: .exact(0)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        try require(
            Diagnostics(capacity: 1).recordRendererInstantiation(zeroNativeGeneration)
                == .invalidObservation,
            "full-surface evidence accepted generation zero"
        )

        let transitionDiagnostics = Diagnostics(capacity: 4)
        let native = rendererObservation(
            binding: binding(generation: .exact(6)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        _ = transitionDiagnostics.recordRendererInstantiation(native)
        try require(
            transitionDiagnostics.recordRendererInstantiation(observation) == .superseded,
            "legacy grid was admitted while a native renderer remained active"
        )
        _ = transitionDiagnostics.recordRendererRetirement(native)
        try require(
            transitionDiagnostics.recordRendererInstantiation(observation)
                == .recorded(sequence: 3),
            "a real legacy replacement was treated as a stale numeric generation"
        )
        let replacementNative = rendererObservation(
            binding: binding(generation: .exact(7)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        try require(
            transitionDiagnostics.recordRendererInstantiation(replacementNative)
                == .recorded(sequence: 4),
            "a newer native renderer could not supersede the active legacy grid"
        )
        try require(
            transitionDiagnostics.rendererSnapshot().resolution(for: observation.binding)
                == .staleGeneration(observed: .exact(7)),
            "superseded legacy evidence remained positively instantiated"
        )

        let generations = Diagnostics(capacity: 4)
        let first = rendererObservation(
            binding: binding(generation: .exact(1)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        let second = rendererObservation(
            binding: binding(generation: .exact(2)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        _ = generations.recordRendererInstantiation(first)
        _ = generations.recordRendererInstantiation(second)
        _ = generations.recordRendererRetirement(second)
        try require(
            generations.recordRendererInstantiation(observation) == .recorded(sequence: 4),
            "retired replacement generation left an older native renderer active"
        )
    }

    static func transcriptFallbackRejection() throws {
        let diagnostics = Diagnostics(capacity: 4)
        let observation = rendererObservation(
            binding: binding(generation: .exact(8)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .transcriptOnlyFallback,
            fallbackReason: .transcriptRejected
        )
        try require(
            diagnostics.recordRendererInstantiation(observation) == .invalidObservation,
            "transcript-only fallback became positive renderer evidence"
        )
        let snapshot = diagnostics.rendererSnapshot()
        try require(
            snapshot.entries.isEmpty && snapshot.totalRecorded == 0,
            "rejected transcript fallback consumed renderer evidence capacity"
        )
    }

    static func staleGeneration() throws {
        let diagnostics = Diagnostics(capacity: 4)
        let current = rendererObservation(
            binding: binding(generation: .exact(12)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        let stale = rendererObservation(
            binding: binding(generation: .exact(11)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        _ = diagnostics.recordRendererInstantiation(current)
        try require(
            diagnostics.recordRendererInstantiation(stale)
                == .staleGeneration(observed: .exact(12)),
            "a stale generation was admitted"
        )
        try require(
            diagnostics.waitForRendererEvidence(for: stale.binding, timeout: 0)
                == .staleGeneration(observed: .exact(12)),
            "wait seam did not fail closed on a stale generation"
        )
        try require(
            diagnostics.recordRendererRetirement(stale)
                == .staleGeneration(observed: .exact(12)),
            "stale generation retirement affected the current renderer"
        )
    }

    static func retirement() throws {
        let diagnostics = Diagnostics(capacity: 4)
        let observation = rendererObservation(
            binding: binding(generation: .exact(14)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        _ = diagnostics.recordRendererInstantiation(observation)
        try require(
            diagnostics.recordRendererRetirement(observation) == .recorded(sequence: 2),
            "retirement was not recorded"
        )
        try require(
            diagnostics.rendererSnapshot().resolution(for: observation.binding)
                == .retired(.init(observation: observation, lifecycle: .retired)),
            "retired evidence remained positively instantiated"
        )
        try require(
            diagnostics.waitForRendererEvidence(for: observation.binding, timeout: 1)
                == .retired(.init(observation: observation, lifecycle: .retired)),
            "wait did not fail closed immediately on retired evidence"
        )
        try require(
            diagnostics.recordRendererRetirement(observation) == .retired,
            "repeated retirement changed retired lifecycle truth"
        )
        try require(
            diagnostics.recordRendererInstantiation(observation) == .retired,
            "a retired renderer binding was resurrected"
        )

        let supersessionDiagnostics = Diagnostics(capacity: 4)
        let legacy = rendererObservation(
            binding: binding(generation: .notAllocated),
            requestedMode: .macScopeGhosttyVTGrid,
            observedMode: .macScopeGhosttyVTGrid,
            fallbackReason: .recoveryOverride
        )
        let conflictingLegacy = rendererObservation(
            binding: legacy.binding,
            requestedMode: .macScopeGhosttyVTGrid,
            observedMode: .macScopeGhosttyVTGrid,
            fallbackReason: .runtimeFailure
        )
        _ = supersessionDiagnostics.recordRendererInstantiation(legacy)
        try require(
            supersessionDiagnostics.recordRendererInstantiation(conflictingLegacy)
                == .superseded,
            "conflicting lifecycle evidence replaced an active renderer"
        )
        try require(
            supersessionDiagnostics.recordRendererRetirement(conflictingLegacy)
                == .superseded,
            "conflicting retirement replaced active renderer evidence"
        )
        try require(
            supersessionDiagnostics.rendererSnapshot().totalRecorded == 1,
            "superseded renderer evidence consumed ledger capacity"
        )
    }

    static func noRenderer() throws {
        let diagnostics = Diagnostics(capacity: 4)
        let absent = binding(generation: .exact(21))
        try require(
            diagnostics.rendererSnapshot().resolution(for: absent) == .noInstantiatedRenderer,
            "an empty snapshot manufactured renderer evidence"
        )
        try require(
            diagnostics.waitForRendererEvidence(for: absent, timeout: .nan)
                == .noInstantiatedRenderer,
            "an invalid wait duration did not fail closed"
        )
    }

    static func waitWakeup() throws {
        let diagnostics = Diagnostics(capacity: 4)
        let observation = rendererObservation(
            binding: binding(generation: .exact(22)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        let waiterStarted = DispatchSemaphore(value: 0)
        let waiterFinished = DispatchSemaphore(value: 0)
        let result = RendererResolutionBox()
        DispatchQueue.global(qos: .userInitiated).async {
            waiterStarted.signal()
            result.store(diagnostics.waitForRendererEvidence(
                for: observation.binding,
                timeout: 1
            ))
            waiterFinished.signal()
        }
        try require(
            waiterStarted.wait(timeout: .now() + 1) == .success,
            "renderer evidence waiter did not start"
        )
        usleep(20_000)
        _ = diagnostics.recordRendererInstantiation(observation)
        try require(
            waiterFinished.wait(timeout: .now() + 1) == .success,
            "renderer evidence waiter did not wake"
        )
        try require(
            result.load() == .instantiated(.init(
                observation: observation,
                lifecycle: .instantiated
            )),
            "renderer evidence waiter returned the wrong resolution"
        )
    }

    static func waitTimeout() throws {
        let diagnostics = Diagnostics(capacity: 4)
        let absent = binding(generation: .exact(23))
        let startedAt = DispatchTime.now().uptimeNanoseconds
        try require(
            diagnostics.waitForRendererEvidence(for: absent, timeout: 0.05)
                == .noInstantiatedRenderer,
            "missing renderer evidence manufactured a positive wait result"
        )
        try require(
            DispatchTime.now().uptimeNanoseconds - startedAt >= 20_000_000,
            "bounded renderer wait returned before its timeout without terminal evidence"
        )
    }

    static func boundedEviction() throws {
        let diagnostics = Diagnostics(capacity: 2)
        let observations = (1...3).map { ordinal in
            rendererObservation(
                binding: binding(
                    sessionID: UUID(
                        uuidString: "30000000-0000-0000-0000-00000000000\(ordinal)"
                    )!,
                    requestID: UUID(
                        uuidString: "40000000-0000-0000-0000-00000000000\(ordinal)"
                    )!,
                    processIdentifier: Int32(5_000 + ordinal),
                    generation: .notAllocated
                ),
                requestedMode: .macScopeGhosttyVTGrid,
                observedMode: .macScopeGhosttyVTGrid,
                fallbackReason: .recoveryOverride
            )
        }
        observations.forEach { _ = diagnostics.recordRendererInstantiation($0) }

        let snapshot = diagnostics.rendererSnapshot()
        try require(snapshot.entries.count == 2, "renderer evidence exceeded capacity")
        try require(snapshot.totalRecorded == 3, "renderer evidence total was not monotonic")
        try require(snapshot.evictedEntryCount == 1, "renderer evidence eviction was not counted")
        try require(
            snapshot.resolution(for: observations[0].binding) == .noInstantiatedRenderer,
            "evicted evidence was treated as current proof"
        )
        try require(
            diagnostics.waitForRendererEvidence(for: observations[0].binding, timeout: 0)
                == .noInstantiatedRenderer,
            "wait resolved positively from evicted evidence"
        )
        try require(
            diagnostics.recordRendererRetirement(observations[0])
                == .noInstantiatedRenderer,
            "retirement borrowed an evicted renderer entry"
        )
        try require(
            diagnostics.recordRendererInstantiation(observations[0])
                == .noInstantiatedRenderer,
            "eviction allowed an exact renderer binding to resurrect"
        )

        let staleAfterEviction = Diagnostics(capacity: 1)
        let generationTwelve = rendererObservation(
            binding: binding(generation: .exact(12)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        let generationEleven = rendererObservation(
            binding: binding(generation: .exact(11)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        _ = staleAfterEviction.recordRendererInstantiation(generationTwelve)
        _ = staleAfterEviction.recordRendererInstantiation(observations[1])
        try require(
            staleAfterEviction.recordRendererInstantiation(generationEleven)
                == .noInstantiatedRenderer,
            "eviction erased the generation high-water fence"
        )
        try require(
            staleAfterEviction.recordRendererRetirement(generationTwelve)
                == .noInstantiatedRenderer,
            "retirement borrowed an evicted generation lifecycle"
        )

        let sealingDiagnostics = Diagnostics(capacity: 1)
        let sealingObservations = (1...4).map { ordinal in
            rendererObservation(
                binding: binding(
                    sessionID: UUID(
                        uuidString: "70000000-0000-0000-0000-00000000000\(ordinal)"
                    )!,
                    requestID: UUID(
                        uuidString: "80000000-0000-0000-0000-00000000000\(ordinal)"
                    )!,
                    processIdentifier: Int32(7_000 + ordinal),
                    generation: .notAllocated
                ),
                requestedMode: .macScopeGhosttyVTGrid,
                observedMode: .macScopeGhosttyVTGrid,
                fallbackReason: .recoveryOverride
            )
        }
        _ = sealingDiagnostics.recordRendererInstantiation(sealingObservations[0])
        _ = sealingDiagnostics.recordRendererInstantiation(sealingObservations[1])
        _ = sealingDiagnostics.recordRendererInstantiation(sealingObservations[2])
        try require(
            sealingDiagnostics.recordRendererInstantiation(sealingObservations[3])
                == .noInstantiatedRenderer,
            "bounded tombstone exhaustion admitted an unverifiable new coordinate"
        )
        let sealedSnapshot = sealingDiagnostics.rendererSnapshot()
        try require(
            sealedSnapshot.entries.count == 1
                && sealedSnapshot.totalRecorded == 3
                && sealedSnapshot.evictedEntryCount == 2,
            "sealed renderer evidence storage exceeded its bounded history"
        )
    }

    static func rendererLifecycleOrdering() throws {
        let diagnostics = Diagnostics(capacity: 8)
        let lifecycle = Diagnostics.RendererLifecycleCoordinator(diagnostics: diagnostics)
        let full = rendererObservation(
            binding: binding(generation: .exact(31)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        let legacy = rendererObservation(
            binding: binding(generation: .notAllocated),
            requestedMode: .ghosttyFullSurface,
            observedMode: .macScopeGhosttyVTGrid,
            fallbackReason: .runtimeFailure
        )

        try require(lifecycle.rendererDidAppear(full), "full renderer did not acquire evidence")
        try require(
            lifecycle.rendererDidAppear(legacy),
            "legacy replacement did not acquire evidence when it appeared before full retirement"
        )
        lifecycle.rendererDidDisappear(binding: full.binding)

        let snapshot = diagnostics.rendererSnapshot()
        try require(snapshot.totalRecorded == 3, "replacement lifecycle was not serialized")
        try require(
            snapshot.entries.map(\.evidence) == [
                .init(observation: full, lifecycle: .instantiated),
                .init(observation: full, lifecycle: .retired),
                .init(observation: legacy, lifecycle: .instantiated),
            ],
            "replacement evidence did not retire full before admitting legacy"
        )
        try require(
            snapshot.resolution(for: legacy.binding)
                == .instantiated(.init(observation: legacy, lifecycle: .instantiated)),
            "late full disappearance retired or displaced the active legacy renderer"
        )

        let reverseDiagnostics = Diagnostics(capacity: 8)
        let reverse = Diagnostics.RendererLifecycleCoordinator(diagnostics: reverseDiagnostics)
        try require(reverse.rendererDidAppear(full), "reverse-order full renderer was not admitted")
        reverse.rendererDidDisappear(binding: full.binding)
        try require(reverse.rendererDidAppear(legacy), "reverse-order legacy renderer was not admitted")
        try require(
            reverseDiagnostics.rendererSnapshot().resolution(for: legacy.binding)
                == .instantiated(.init(observation: legacy, lifecycle: .instantiated)),
            "reverse callback order changed final renderer evidence"
        )

        let splitDiagnostics = Diagnostics(capacity: 8)
        let oldOwner = Diagnostics.RendererLifecycleCoordinator(diagnostics: splitDiagnostics)
        let replacementOwner = Diagnostics.RendererLifecycleCoordinator(
            diagnostics: splitDiagnostics
        )
        try require(oldOwner.rendererDidAppear(full), "split owner did not admit full renderer")
        try require(
            !replacementOwner.rendererDidAppear(legacy),
            "independent owner bypassed an active full renderer"
        )
        oldOwner.rendererDidDisappear(binding: full.binding)
        try require(
            replacementOwner.rendererDidAppear(legacy),
            "independent replacement could not retry after exact retirement"
        )
    }

    static func rendererLifecycleCallbackFencing() throws {
        let diagnostics = Diagnostics(capacity: 8)
        let lifecycle = Diagnostics.RendererLifecycleCoordinator(diagnostics: diagnostics)
        let first = rendererObservation(
            binding: binding(generation: .exact(41)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        let replacement = rendererObservation(
            binding: binding(generation: .exact(42)),
            requestedMode: .ghosttyFullSurface,
            observedMode: .ghosttyFullSurface,
            fallbackReason: .none
        )
        var acceptedCallbackCount = 0

        try require(lifecycle.rendererDidAppear(first), "first generation was not admitted")
        lifecycle.withAuthorizedCallback(for: first.binding) {
            acceptedCallbackCount += 1
        }
        try require(lifecycle.rendererDidAppear(replacement), "replacement generation was not admitted")
        lifecycle.withAuthorizedCallback(for: first.binding) {
            acceptedCallbackCount += 100
        }
        lifecycle.withAuthorizedCallback(for: replacement.binding) {
            acceptedCallbackCount += 1
        }
        lifecycle.rendererDidDisappear(binding: first.binding)
        lifecycle.withAuthorizedCallback(for: replacement.binding) {
            acceptedCallbackCount += 1
        }
        try require(
            acceptedCallbackCount == 3,
            "stale generation callback passed the exact binding fence"
        )

        lifecycle.withAuthorizedCallback(for: replacement.binding) {
            acceptedCallbackCount += 1
            lifecycle.rendererDidDisappear(binding: replacement.binding)
        }
        lifecycle.withAuthorizedCallback(for: replacement.binding) {
            acceptedCallbackCount += 100
        }
        try require(
            acceptedCallbackCount == 4,
            "callback authorization deadlocked or survived synchronous retirement"
        )

        try require(
            !lifecycle.rendererDidAppear(nil),
            "transcript-only fallback was treated as an evidenced renderer"
        )
        lifecycle.withAuthorizedCallback(for: replacement.binding) {
            acceptedCallbackCount += 100
        }
        try require(
            acceptedCallbackCount == 4,
            "callback remained authorized after transcript fallback retired the renderer"
        )

        let splitDiagnostics = Diagnostics(capacity: 8)
        let staleOwner = Diagnostics.RendererLifecycleCoordinator(diagnostics: splitDiagnostics)
        let currentOwner = Diagnostics.RendererLifecycleCoordinator(diagnostics: splitDiagnostics)
        try require(staleOwner.rendererDidAppear(first), "split callback owner was not admitted")
        try require(
            currentOwner.rendererDidAppear(replacement),
            "split replacement callback owner was not admitted"
        )
        try require(
            !staleOwner.rendererDidAppear(first),
            "stale coordinator reported mounted evidence after ledger replacement"
        )
        staleOwner.withAuthorizedCallback(for: first.binding) {
            acceptedCallbackCount += 100
        }
        currentOwner.withAuthorizedCallback(for: replacement.binding) {
            acceptedCallbackCount += 1
        }
        try require(
            acceptedCallbackCount == 5,
            "shared evidence authority did not reject a stale coordinator callback"
        )
        try require(
            diagnostics.rendererSnapshot().resolution(for: replacement.binding)
                == .retired(.init(observation: replacement, lifecycle: .retired)),
            "transcript fallback did not retire exact replacement evidence"
        )
    }

    static func rendererLifecycleSameBindingStability() throws {
        let diagnostics = Diagnostics(capacity: 8)
        let lifecycle = Diagnostics.RendererLifecycleCoordinator(diagnostics: diagnostics)
        let original = rendererObservation(
            binding: binding(generation: .notAllocated),
            requestedMode: .macScopeGhosttyVTGrid,
            observedMode: .macScopeGhosttyVTGrid,
            fallbackReason: .recoveryOverride
        )
        let metadataUpdate = rendererObservation(
            binding: original.binding,
            requestedMode: .macScopeGhosttyVTGrid,
            observedMode: .macScopeGhosttyVTGrid,
            fallbackReason: .runtimeFailure
        )

        try require(lifecycle.rendererDidAppear(original), "legacy renderer was not admitted")
        try require(
            lifecycle.rendererDidAppear(metadataUpdate),
            "same-binding metadata update displaced the live renderer"
        )
        try require(
            diagnostics.rendererSnapshot().totalRecorded == 1,
            "same-binding appearance created conflicting renderer evidence"
        )
        lifecycle.rendererDidDisappear(binding: original.binding)
        try require(
            diagnostics.rendererSnapshot().resolution(for: original.binding)
                == .retired(.init(observation: original, lifecycle: .retired)),
            "same-binding disappearance did not retire the originally admitted observation"
        )
    }

    private static func binding(
        sessionID candidateSessionID: UUID = sessionID,
        requestID candidateRequestID: UUID = requestID,
        processIdentifier: Int32 = shellBrokerProcessIdentifier,
        generation: Diagnostics.RendererGenerationBinding
    ) -> Diagnostics.RendererBinding {
        Diagnostics.RendererBinding(
            sessionID: candidateSessionID,
            requestID: candidateRequestID,
            shellBrokerProcessIdentifier: processIdentifier,
            generation: generation
        )!
    }

    private static func rendererObservation(
        binding: Diagnostics.RendererBinding,
        requestedMode: Diagnostics.RendererRequestedMode,
        observedMode: Diagnostics.RendererObservedMode,
        fallbackReason: Diagnostics.RendererFallbackReason
    ) -> Diagnostics.RendererObservation {
        Diagnostics.RendererObservation(
            binding: binding,
            requestedMode: requestedMode,
            observedMode: observedMode,
            fallbackReason: fallbackReason
        )
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw MacScopeGhosttyRendererEvidenceScenarioError.assertion(message)
        }
    }
}

private final class RendererResolutionBox: @unchecked Sendable {
    typealias Resolution = MacScopeGhosttySurfaceDiagnostics.RendererResolution

    private let lock = NSLock()
    private var value: Resolution?

    func store(_ value: Resolution) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Resolution? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
