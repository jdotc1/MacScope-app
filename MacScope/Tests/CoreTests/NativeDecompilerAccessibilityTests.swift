import XCTest
@testable import MacScope

final class NativeDecompilerAccessibilityTests: XCTestCase {
    func testStableDCP05CAccessibilityIdentifiersAreUniqueAndComplete() {
        let expected = [
            "native.status",
            "native.status.value",
            "native.action.request",
            "native.action.retry",
            "native.action.refresh",
            "native.action.cancel",
            "native.source.segmented",
            "native.source.menu",
            "native.document",
            "native.document.line.1",
            "native.token.sourceAction",
            "native.token.sourceChooser",
            "native.token.entityDetail",
            "native.comparison",
            "native.comparison.instructions",
            "native.comparison.blocks",
            "native.comparison.edges",
            "native.comparison.calls",
        ]
        XCTAssertEqual(NativeDecompilerAccessibilityIdentifiers.all, expected)
        XCTAssertEqual(Set(NativeDecompilerAccessibilityIdentifiers.all).count, expected.count)
        XCTAssertEqual(
            NativeDecompilerAccessibilityIdentifiers.documentLine(2),
            "native.document.line.2"
        )
    }

    func testStatusValueContainsIntentAttemptOriginCompletenessMappingFallbackAndNotice() throws {
        let content = makeAccessibilityContent(
            origin: .cache,
            isComplete: false,
            isTruncated: true,
            mappingState: .degraded(.visibleTextMismatch)
        )
        let state = try NativeDecompilerLayeredPresentationState(
            content: content,
            intent: .refresh,
            attempt: .running,
            notice: .none,
            refreshRetentionWitness: nil
        )

        let projection = FocusedPresentationAccessibility.nativeStatus(
            state: state,
            usesMacScopeFallback: true
        )

        for component in [
            "Refresh", "Running", "Cached", "Truncated", "Plain text",
            "Fallback disclosed", "No notice",
        ] {
            XCTAssertTrue(projection.value.contains(component), "Missing status component: \(component)")
        }
    }

    func testAnnouncementsContainOnlyMeaningfulDeduplicatedTransitions() throws {
        var reducer = NativeDecompilerPresentationReducer()
        let empty = reducer.state
        XCTAssertTrue(reducer.apply(.begin(intent: .request, generation: 1)))
        let preparing = reducer.state
        XCTAssertTrue(reducer.apply(.admission(.queued, generation: 1)))
        let queued = reducer.state
        XCTAssertTrue(reducer.apply(.admission(.running, generation: 1)))
        let running = reducer.state
        XCTAssertTrue(reducer.apply(.ready(makeAccessibilityContent(), generation: 1)))
        let ready = reducer.state

        XCTAssertNil(FocusedPresentationAccessibility.nativeAnnouncement(
            from: empty,
            to: preparing,
            usesMacScopeFallback: false
        ))
        XCTAssertEqual(FocusedPresentationAccessibility.nativeAnnouncement(
            from: preparing,
            to: queued,
            usesMacScopeFallback: false
        ), "Native decompilation queued")
        XCTAssertNil(FocusedPresentationAccessibility.nativeAnnouncement(
            from: queued,
            to: queued,
            usesMacScopeFallback: false
        ))
        XCTAssertEqual(FocusedPresentationAccessibility.nativeAnnouncement(
            from: queued,
            to: running,
            usesMacScopeFallback: false
        ), "Native decompilation running")
        XCTAssertEqual(FocusedPresentationAccessibility.nativeAnnouncement(
            from: running,
            to: ready,
            usesMacScopeFallback: false
        ), "Native decompilation ready")
    }

    func testSegmentedAndCompactSelectorsShareLabelValueAndModeSpecificHint() {
        let segmented = FocusedPresentationAccessibility.nativeSourceSelector(
            source: .native,
            mode: .segmented
        )
        let menu = FocusedPresentationAccessibility.nativeSourceSelector(
            source: .native,
            mode: .compactMenu
        )

        XCTAssertEqual(segmented.label, "Pseudocode source")
        XCTAssertEqual(menu.label, segmented.label)
        XCTAssertEqual(segmented.value, "Native")
        XCTAssertEqual(menu.value, segmented.value)
        XCTAssertNotEqual(segmented.hint, menu.hint)
    }

    func testComparisonRowIsOneCoherentAccessibilityElement() throws {
        let result = NativeDecompilerComparisonCategoryResult(
            category: .instructions,
            counts: try NativeDecompilerComparisonCounts(
                matchedCount: 2,
                nativeOnlyCount: 1,
                macScopeOnlyCount: 3,
                uncomparableNativeCount: 4,
                uncomparableMacScopeCount: 5
            ),
            coverage: .partial,
            correspondence: .divergent,
            samples: .init(
                nativeOnly: [], macScopeOnly: [],
                uncomparableNative: [], uncomparableMacScope: []
            )
        )

        let projection = FocusedPresentationAccessibility.nativeComparisonRow(result)
        XCTAssertEqual(projection.label, "Instructions structural summary")
        XCTAssertTrue(projection.value.contains("2 matched"))
        XCTAssertTrue(projection.value.contains("1 native only"))
        XCTAssertTrue(projection.value.contains("3 MacScope only"))
        XCTAssertTrue(projection.value.contains("9 uncomparable"))
        XCTAssertTrue(projection.value.contains("Partial coverage"))
        XCTAssertTrue(projection.value.contains("Divergent correspondence"))
        XCTAssertTrue(projection.combinesChildren)
    }

    func testCachedTruncatedPlainTextAndFallbackStatesHaveTextLabels() throws {
        let content = makeAccessibilityContent(
            origin: .cache,
            isComplete: false,
            isTruncated: true,
            mappingState: .degraded(.ambiguousRange)
        )
        let ready = try NativeDecompilerLayeredPresentationState(
            content: content,
            intent: .none,
            attempt: .none,
            notice: .none,
            refreshRetentionWitness: nil
        )
        let projection = FocusedPresentationAccessibility.nativeStatus(
            state: ready,
            usesMacScopeFallback: true
        )

        XCTAssertTrue(projection.value.contains("Cached"))
        XCTAssertTrue(projection.value.contains("Truncated"))
        XCTAssertTrue(projection.value.contains("Plain text"))
        XCTAssertTrue(projection.value.contains("Fallback disclosed"))
    }

    func testFailureActionsUseCatalogCopyAndNeverRawDetail() {
        let failure = NativeDecompilerFailureCatalog.presentation(
            for: NativeDecompilerRuntimeValidationError.replyRuntimeIdentityMismatch
        )
        let projection = FocusedPresentationAccessibility.nativeFailure(failure)

        XCTAssertEqual(projection.label, failure.accessibilityLabel)
        XCTAssertEqual(projection.hint, failure.accessibilityHint)
        for prohibited in ["/Users/private", String(repeating: "a", count: 64), "provider::detail"] {
            XCTAssertFalse(projection.label.contains(prohibited))
            XCTAssertFalse(projection.hint.contains(prohibited))
        }
        XCTAssertEqual(projection.primaryAction, failure.primaryAction)
        XCTAssertEqual(projection.secondaryAction, failure.secondaryAction)
    }
}

private func emptyAccessibilityState() -> NativeDecompilerLayeredPresentationState {
    try! NativeDecompilerLayeredPresentationState(
        content: nil,
        intent: .none,
        attempt: .none,
        notice: .none,
        refreshRetentionWitness: nil
    )
}

private func makeAccessibilityContent(
    origin: NativeDecompilerContentOrigin = .live,
    isComplete: Bool = true,
    isTruncated: Bool = false,
    mappingState: NativeDecompilerDocumentMappingState = .verified
) -> NativeDecompilerPresentedContent {
    _ = isComplete
    return NativeDecompilerPresentedContent(
        identity: NativeDecompilerPresentationContentIdentity(
            requestSHA256: String(repeating: "a", count: 64),
            analysisFingerprintSHA256: String(repeating: "b", count: 64),
            runtimeIdentitySHA256: String(repeating: "c", count: 64),
            semanticIdentitySHA256: String(repeating: "d", count: 64)
        ),
        origin: origin,
        completeness: isTruncated ? .truncated : .complete,
        mappingState: mappingState == .verified ? .verified : .degraded
    )
}
