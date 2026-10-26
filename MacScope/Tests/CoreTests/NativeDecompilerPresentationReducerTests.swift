import XCTest
@testable import MacScope

final class NativeDecompilerPresentationReducerTests: XCTestCase {
    func testCompleteLayerCrossProductAcceptsExactlySixtyEightOfSevenHundredTwenty() {
        let identity = makeIdentity("a")
        let contents: [NativeDecompilerPresentedContent?] = [nil] +
            NativeDecompilerContentOrigin.allCases.flatMap { origin in
                NativeDecompilerContentCompleteness.allCases.flatMap { completeness in
                    NativeDecompilerContentMappingState.allCases.map { mapping in
                        NativeDecompilerPresentedContent(
                            identity: identity,
                            origin: origin,
                            completeness: completeness,
                            mappingState: mapping
                        )
                    }
                }
            }
        let notices: [NativeDecompilerPresentationNoticeLayer] = [
            .none,
            .cancelled,
            .failure(NativeDecompilerFailureCatalog.row(2)!),
            .unavailable(NativeDecompilerFailureCatalog.row(4)!),
        ]

        var accepted = 0
        var rejected = 0
        for content in contents {
            for intent in NativeDecompilerPresentationIntent.allCases {
                for attempt in NativeDecompilerPresentationAttempt.allCases {
                    for notice in notices {
                        let witness = content != nil && (notice.isCancelled || notice.isFailure)
                            ? NativeDecompilerRefreshRetentionWitness(identity: identity)
                            : nil
                        do {
                            _ = try NativeDecompilerLayeredPresentationState(
                                content: content,
                                intent: intent,
                                attempt: attempt,
                                notice: notice,
                                refreshRetentionWitness: witness
                            )
                            accepted += 1
                        } catch {
                            rejected += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(contents.count * 4 * 5 * 4, 720)
        XCTAssertEqual(accepted, 68)
        XCTAssertEqual(rejected, 652)
    }

    func testRefreshRetainsOnlyExactPriorContentOnFailureOrCancellation() throws {
        let retained = makeContent("a")
        let mismatched = makeContent("b")
        var reducer = NativeDecompilerPresentationReducer(content: retained)

        XCTAssertTrue(reducer.apply(.begin(intent: .refresh, generation: 1)))
        XCTAssertTrue(reducer.apply(.admission(.running, generation: 1)))
        XCTAssertTrue(reducer.apply(.failure(
            NativeDecompilerFailureCatalog.row(2)!,
            retainedRefreshContent: retained,
            generation: 1
        )))
        XCTAssertEqual(reducer.state.content, retained)
        XCTAssertTrue(reducer.state.refreshRetentionWitness != nil)

        XCTAssertTrue(reducer.apply(.begin(intent: .refresh, generation: 2)))
        XCTAssertTrue(reducer.apply(.failure(
            NativeDecompilerFailureCatalog.row(2)!,
            retainedRefreshContent: mismatched,
            generation: 2
        )))
        XCTAssertNil(reducer.state.content)
        XCTAssertNil(reducer.state.refreshRetentionWitness)
    }

    func testCancellationTransitionsThroughCancellingAndLifecycleSupersessionIsTypedFailure() {
        var reducer = NativeDecompilerPresentationReducer()
        XCTAssertTrue(reducer.apply(.begin(intent: .request, generation: 1)))
        XCTAssertFalse(reducer.apply(.cancelled(retainedRefreshContent: nil, generation: 1)))
        XCTAssertTrue(reducer.apply(.cancelRequested(generation: 1)))
        XCTAssertEqual(reducer.state.attempt, .cancelling)
        XCTAssertTrue(reducer.apply(.cancelled(retainedRefreshContent: nil, generation: 1)))
        XCTAssertTrue(reducer.state.notice.isCancelled)

        XCTAssertTrue(reducer.apply(.begin(intent: .request, generation: 2)))
        XCTAssertTrue(reducer.apply(.runtimeTransitioned(generation: 2)))
        XCTAssertEqual(reducer.state.notice.failure?.rowID, 5)
        XCTAssertFalse(reducer.state.notice.isCancelled)
    }

    func testDuplicateAndLateTerminalPublicationAreRejected() {
        var reducer = NativeDecompilerPresentationReducer()
        let content = makeContent("a")
        XCTAssertTrue(reducer.apply(.begin(intent: .request, generation: 4)))
        XCTAssertTrue(reducer.apply(.ready(content, generation: 4)))
        XCTAssertEqual(reducer.publicationCount, 1)
        XCTAssertFalse(reducer.apply(.ready(content, generation: 4)))
        XCTAssertFalse(reducer.apply(.failure(
            NativeDecompilerFailureCatalog.row(3)!,
            retainedRefreshContent: nil,
            generation: 4
        )))
        XCTAssertEqual(reducer.publicationCount, 1)
    }

    func testNewReadyPublicationClearsThePriorFailureNotice() {
        var reducer = NativeDecompilerPresentationReducer()
        let content = makeContent("a")
        XCTAssertTrue(reducer.apply(.begin(intent: .request, generation: 1)))
        XCTAssertTrue(reducer.apply(.failure(
            NativeDecompilerFailureCatalog.row(3)!,
            retainedRefreshContent: nil,
            generation: 1
        )))
        XCTAssertTrue(reducer.state.notice.isFailure)

        XCTAssertTrue(reducer.apply(.begin(intent: .request, generation: 2)))
        XCTAssertTrue(reducer.apply(.ready(content, generation: 2)))
        XCTAssertEqual(reducer.state.notice, .none)
        XCTAssertEqual(reducer.state.content, content)
    }

    func testCommandAvailabilityMatchesTheFrozenVectors() throws {
        let eligible = NativeDecompilerCommandContext(
            exactTargetEligible: true,
            retryAuthorityEqual: true,
            terminalOwner: false
        )
        XCTAssertEqual(
            NativeDecompilerCommandAvailability.enabledCommands(
                for: try .idle(), context: eligible
            ),
            [.request]
        )

        let running = try NativeDecompilerLayeredPresentationState(
            content: nil, intent: .request, attempt: .running, notice: .none,
            refreshRetentionWitness: nil
        )
        XCTAssertEqual(
            NativeDecompilerCommandAvailability.enabledCommands(for: running, context: eligible),
            [.cancel]
        )

        let failed = try NativeDecompilerLayeredPresentationState(
            content: nil, intent: .none, attempt: .none,
            notice: .failure(NativeDecompilerFailureCatalog.row(2)!),
            refreshRetentionWitness: nil
        )
        XCTAssertEqual(
            NativeDecompilerCommandAvailability.enabledCommands(for: failed, context: eligible),
            [.retry]
        )
        XCTAssertEqual(
            NativeDecompilerCommandAvailability.enabledCommands(
                for: failed,
                context: NativeDecompilerCommandContext(
                    exactTargetEligible: true,
                    retryAuthorityEqual: false,
                    terminalOwner: false
                )
            ),
            []
        )
        XCTAssertEqual(
            NativeDecompilerCommandAvailability.enabledCommands(
                for: failed,
                context: NativeDecompilerCommandContext(
                    exactTargetEligible: true,
                    retryAuthorityEqual: true,
                    terminalOwner: true
                )
            ),
            []
        )

        let ready = try NativeDecompilerLayeredPresentationState(
            content: makeContent("a"), intent: .none, attempt: .none, notice: .none,
            refreshRetentionWitness: nil
        )
        XCTAssertEqual(
            NativeDecompilerCommandAvailability.enabledCommands(for: ready, context: eligible),
            [.refresh]
        )
    }

    func testProductProjectionExposesOnlyTheLegalNativeCommand() {
        let retryFailure = NativePseudocodePresentation(
            status: .failed,
            document: nil,
            provider: nil,
            nativeTerminalReason: .provider(.busy),
            fallbackReason: .terminal(.provider(.busy)),
            usesMacScopeFallback: true
        )
        XCTAssertEqual(
            NativeDecompilerCommandAvailability.enabledCommands(
                for: retryFailure,
                exactTargetEligible: true
            ),
            [.retry]
        )

        let rejected = NativePseudocodePresentation(
            status: .failed,
            document: nil,
            provider: nil,
            nativeTerminalReason: .runtimeValidation(.replyRuntimeIdentityMismatch),
            fallbackReason: .terminal(.runtimeValidation(.replyRuntimeIdentityMismatch)),
            usesMacScopeFallback: true
        )
        XCTAssertEqual(
            NativeDecompilerCommandAvailability.enabledCommands(
                for: rejected,
                exactTargetEligible: true
            ),
            [.refresh]
        )
        XCTAssertEqual(
            NativeDecompilerCommandAvailability.enabledCommands(
                for: retryFailure,
                exactTargetEligible: false
            ),
            []
        )
    }

    private func makeContent(_ scalar: Character) -> NativeDecompilerPresentedContent {
        NativeDecompilerPresentedContent(
            identity: makeIdentity(scalar),
            origin: .live,
            completeness: .complete,
            mappingState: .verified
        )
    }

    private func makeIdentity(_ scalar: Character) -> NativeDecompilerPresentationContentIdentity {
        NativeDecompilerPresentationContentIdentity(
            requestSHA256: String(repeating: scalar, count: 64),
            analysisFingerprintSHA256: String(repeating: scalar, count: 64),
            runtimeIdentitySHA256: String(repeating: scalar, count: 64),
            semanticIdentitySHA256: String(repeating: scalar, count: 64)
        )
    }
}
