import AppKit
import SwiftUI
import LumenTokens
import LumenUI
import XCTest
@testable import MacScope

final class NativeDecompilerEditorPresentationTests: XCTestCase {
    func testEveryNativeTokenKindMapsToAnAdaptiveSemanticRole() {
        let expected: [NativeDecompilerWireTokenKind: AppNativePseudocodeTokenStyle.Role] = [
            .comment: .comment,
            .identifier: .identifier,
            .keyword: .keyword,
            .literal: .literal,
            .operation: .operation,
            .punctuation: .punctuation,
            .type: .type,
            .whitespace: .whitespace,
        ]

        XCTAssertEqual(Set(expected.keys), Set(NativeDecompilerWireTokenKind.allCases))
        for (kind, role) in expected {
            let standard = AppNativePseudocodeTokenStyle.project(kind, contrast: .standard)
            let increased = AppNativePseudocodeTokenStyle.project(kind, contrast: .increased)
            XCTAssertEqual(standard.role, role)
            XCTAssertEqual(increased.role, role)
            XCTAssertNotNil(standard.font)
            XCTAssertNotNil(increased.font)
            if kind == .whitespace {
                XCTAssertNil(standard.foregroundColor)
                XCTAssertNil(increased.foregroundColor)
            } else {
                XCTAssertNotNil(standard.foregroundColor)
                XCTAssertNotNil(increased.foregroundColor)
            }
        }
    }

    func testIncreasedContrastKeepsEveryTokenRoleDistinguishable() throws {
        let visibleKinds = NativeDecompilerWireTokenKind.allCases.filter { $0 != .whitespace }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var resolvedColors = Set<ResolvedColor>()
            appearance.performAsCurrentDrawingAppearance {
                for kind in visibleKinds {
                    let style = AppNativePseudocodeTokenStyle.project(kind, contrast: .increased)
                    guard let color = style.foregroundColor,
                          let rgb = color.usingColorSpace(.sRGB) else {
                        return XCTFail("Missing increased-contrast color for \(kind)")
                    }
                    resolvedColors.insert(ResolvedColor(rgb))
                }
            }
            XCTAssertEqual(
                resolvedColors.count,
                visibleKinds.count,
                "Every visible token role must remain distinguishable in \(appearanceName.rawValue)"
            )
        }
    }

    @MainActor
    func testBridgeIsNoneditableSelectableAndPreservesProjectedTextAndOneBasedLines() {
        let document = makeEditorDocument(text: "alpha\nbeta\n")
        let textView = NativePseudocodeTextView.makeTextView(
            document: document,
            contrast: .standard
        )

        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertEqual(textView.string, document.text)
        XCTAssertEqual(textView.accessibleLines.map(\.lineNumber), [1, 2])
        XCTAssertEqual(textView.accessibleLines.map(\.text), ["alpha", "beta"])
    }

    func testTokenWithZeroSourceRangesExposesNoNavigationAffordance() {
        let run = makeEditorRun(sourceRanges: [])
        XCTAssertNil(NativePseudocodeInteractionProjection.sourceAction(for: run))
    }

    func testTokenWithOneExactSourceRangeNavigatesThatRange() {
        let range = makeEditorSourceRange(start: 0x1000, end: 0x1004)
        let action = NativePseudocodeInteractionProjection.sourceAction(
            for: makeEditorRun(sourceRanges: [range])
        )
        XCTAssertEqual(action, .navigate(range))
    }

    func testTokenWithMultipleSourceRangesRequiresChooserWithBoundedSummary() throws {
        let ranges = [
            makeEditorSourceRange(start: 0x1000, end: 0x1004),
            makeEditorSourceRange(start: 0x2000, end: 0x2008),
        ]
        let action = try XCTUnwrap(NativePseudocodeInteractionProjection.sourceAction(
            for: makeEditorRun(sourceRanges: ranges)
        ))
        guard case let .choose(chooser) = action else {
            return XCTFail("Multiple ranges must require an explicit chooser")
        }

        XCTAssertEqual(chooser.count, 2)
        XCTAssertNil(chooser.selectedRange)
        XCTAssertLessThanOrEqual(chooser.summary.utf8.count, 256)
        XCTAssertTrue(chooser.summary.contains("0x1000–0x1004"))
        XCTAssertTrue(chooser.summary.contains("0x2000–0x2008"))
        for prohibited in ["/", "token.fixture", "symbol", "alpha"] {
            XCTAssertFalse(chooser.summary.contains(prohibited))
        }
    }

    func testMultipleRangeChooserNeverSilentlySelectsFirstRange() throws {
        let first = makeEditorSourceRange(start: 0x1000, end: 0x1004)
        let second = makeEditorSourceRange(start: 0x2000, end: 0x2004)
        let action = try XCTUnwrap(NativePseudocodeInteractionProjection.sourceAction(
            for: makeEditorRun(sourceRanges: [first, second])
        ))
        guard case let .choose(chooser) = action else {
            return XCTFail("Expected a chooser")
        }
        XCTAssertNil(chooser.selectedRange)
        XCTAssertEqual(chooser.range(at: 1), second)
        XCTAssertNil(chooser.range(at: -1))
        XCTAssertNil(chooser.range(at: 2))
    }

    func testEntityReferencesExposeBoundedReadOnlyDetail() {
        let references = (0..<12).map {
            NativeDecompilerWireTokenEntityReference(
                kind: $0.isMultiple(of: 2) ? .variable : .operation,
                id: "private.entity.\($0)"
            )
        }
        let details = NativePseudocodeInteractionProjection.entityDetails(
            for: makeEditorRun(entityReferences: references)
        )

        XCTAssertEqual(details.count, 8)
        XCTAssertTrue(details.allSatisfy { $0.value.utf8.count <= 128 })
        XCTAssertTrue(details.allSatisfy { !$0.value.contains("private.entity") })
        XCTAssertTrue(details.allSatisfy { $0.isReadOnly })
    }

    func testEntityDetailCannotMutateWorkspaceAuthorityOrPresentationContent() throws {
        let document = makeEditorDocument(
            tokenRuns: [makeEditorRun(entityReferences: [
                .init(kind: .type, id: "private.type.fixture"),
            ])]
        )
        let before = document
        let detail = try XCTUnwrap(
            NativePseudocodeInteractionProjection.entityDetails(for: document.tokenRuns[0]).first
        )

        XCTAssertTrue(detail.isReadOnly)
        XCTAssertEqual(document, before)
        let fieldNames = Mirror(reflecting: detail).children.compactMap(\.label)
        XCTAssertFalse(fieldNames.contains { $0.localizedCaseInsensitiveContains("mutat") })
        XCTAssertFalse(fieldNames.contains { $0.localizedCaseInsensitiveContains("callback") })
    }

    func testKeyboardActivationHoverFocusSelectionAndFocusRingUseStructuredRunOnly() throws {
        let run = makeEditorRun(sourceRanges: [
            makeEditorSourceRange(start: 0x1000, end: 0x1004),
        ])
        let document = makeEditorDocument(text: "alpha + beta", tokenRuns: [run])
        let projected = try XCTUnwrap(NativePseudocodeInteractionProjection.project(
            document: document,
            scalarOffset: 2,
            isHovered: true,
            isFocused: true,
            isSelected: true
        ))

        XCTAssertEqual(projected.tokenID, run.tokenID)
        XCTAssertTrue(projected.isHovered)
        XCTAssertTrue(projected.isFocused)
        XCTAssertTrue(projected.isSelected)
        XCTAssertTrue(projected.showsFocusRing)
        XCTAssertEqual(projected.keyboardAction, .navigate(run.sourceRanges[0]))
        XCTAssertNil(NativePseudocodeInteractionProjection.project(
            document: document,
            scalarOffset: 8,
            isHovered: true,
            isFocused: true,
            isSelected: true
        ))
    }

    func testOneStatusBandAtLumenStripHeightIsSoleStatusAndActionOwner() {
        // U2-pseudocode: the band adopts Lumen's status-strip height (36 pt, was 28).
        XCTAssertEqual(NativeDecompilerEditorComposition.statusBandHeight, 36)
        XCTAssertEqual(NativeDecompilerEditorComposition.persistentStatusAndActionBandCount, 1)
        XCTAssertEqual(NativeDecompilerEditorComposition.visibleCommands.count, 4)
    }

    func testRequestRetryRefreshAndCancelRemainIndividuallyReachable() {
        XCTAssertEqual(
            NativeDecompilerEditorComposition.visibleCommands,
            [.request, .retry, .refresh, .cancel]
        )
        XCTAssertEqual(Set(NativeDecompilerEditorComposition.visibleCommands).count, 4)
    }

    func testStructuralSummaryUsesFourCanonicalRowsAndNeverCountEqualityClaim() throws {
        XCTAssertEqual(
            NativeDecompilerEditorComposition.structuralRows,
            [.instructions, .blocks, .edges, .calls]
        )
        let source = try editorSource("Features/Editor/DecompilerComparisonView.swift")
        XCTAssertTrue(source.contains("Structural summary"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("counts match"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("equal counts"))
        XCTAssertFalse(source.localizedCaseInsensitiveContains("semantic match"))
    }

    func testSegmentedAndMenuSelectorsCarryEqualSourceValue() throws {
        for source in PseudocodeSource.allCases {
            let segmented = FocusedPresentationAccessibility.nativeSourceSelector(
                source: source,
                mode: .segmented
            )
            let menu = FocusedPresentationAccessibility.nativeSourceSelector(
                source: source,
                mode: .compactMenu
            )
            XCTAssertEqual(segmented.label, menu.label)
            XCTAssertEqual(segmented.value, menu.value)
        }
        let source = try editorSource("Features/Editor/PseudocodeSourceSelector.swift")
        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(source.contains("LumenModeSwitcher("))
        XCTAssertTrue(source.contains("Menu"))
    }

    func testLongProviderAndFailureDetailCannotDisplaceActions() {
        let failure = NativeDecompilerFailureCatalog.unknownProtocolFailure
        let projection = NativeDecompilerStatusBandLayout.project(
            availableWidth: 560,
            providerDisplay: String(repeating: "provider", count: 100),
            failure: failure
        )

        XCTAssertEqual(projection.commands, [.request, .retry, .refresh, .cancel])
        XCTAssertEqual(projection.metadataVisibility, .collapsed)
        XCTAssertLessThanOrEqual(projection.providerDisplay?.utf8.count ?? 0, 64)
        XCTAssertEqual(projection.failureTitle, failure.title)
    }

    func testNativeStatusAccessibilityDisclosesProjectedPresentationTruth() {
        let projection = NativeStatusStripAccessibilityProjection.project(
            NativeStatusStripAccessibilityFacts(
                status: "Failed",
                provider: "native-decompiler, engine 12.1.2",
                isTruncated: true,
                isPlainText: true,
                fallbackDescription: "MacScope pseudocode is shown.",
                failureTitle: "Native result rejected"
            )
        )

        XCTAssertEqual(projection.label, "Native pseudocode status")
        for expected in [
            "Failed",
            "native-decompiler, engine 12.1.2",
            "Truncated",
            "Plain text",
            "MacScope fallback: MacScope pseudocode is shown.",
            "Failure: Native result rejected",
        ] {
            XCTAssertTrue(projection.value.contains(expected), "Missing \(expected)")
        }
    }

    func testComparisonAvailabilityAttributesMissingNativeIdentityToNativeSource() {
        XCTAssertEqual(
            EditorDecompilerComparisonAvailability.unavailableReason(
                hasExpectedIdentity: false,
                hasMacScopeInput: true
            ),
            .nativeUnavailable
        )
        XCTAssertEqual(
            EditorDecompilerComparisonAvailability.unavailableReason(
                hasExpectedIdentity: false,
                hasMacScopeInput: false
            ),
            .macScopeUnavailable
        )
        XCTAssertNil(
            EditorDecompilerComparisonAvailability.unavailableReason(
                hasExpectedIdentity: true,
                hasMacScopeInput: true
            )
        )
    }

    func testNoVisibleHelpOrAccessibilityCopyUsesStringDescribing() throws {
        for relativePath in [
            "Features/Editor/NativePseudocodeView.swift",
            "Features/Editor/PseudocodeSourceSelector.swift",
            "Features/Editor/DecompilerComparisonView.swift",
            "Features/Editor/FocusedPresentationAccessibility.swift",
        ] {
            let source = try editorSource(relativePath)
            XCTAssertFalse(
                source.contains("String(describing:"),
                "Visible presentation copy must be closed in \(relativePath)"
            )
        }
    }
}

private struct ResolvedColor: Hashable {
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Int

    init(_ color: NSColor) {
        red = Int((color.redComponent * 65_535).rounded())
        green = Int((color.greenComponent * 65_535).rounded())
        blue = Int((color.blueComponent * 65_535).rounded())
        alpha = Int((color.alphaComponent * 65_535).rounded())
    }
}

private extension NativeDecompilerWireTokenKind {
    static let allCases: [Self] = [
        .comment, .identifier, .keyword, .literal,
        .operation, .punctuation, .type, .whitespace,
    ]
}

private func makeEditorDocument(
    text: String = "alpha",
    tokenRuns: [NativeDecompilerDocumentTokenRun]? = nil
) -> NativeDecompilerDocumentProjection {
    NativeDecompilerDocumentProjection(
        text: text,
        isComplete: true,
        isTruncated: false,
        mappingState: .verified,
        tokenRuns: tokenRuns ?? [makeEditorRun()]
    )
}

private func makeEditorRun(
    sourceRanges: [NativeDecompilerWireSourceRange] = [],
    entityReferences: [NativeDecompilerWireTokenEntityReference] = []
) -> NativeDecompilerDocumentTokenRun {
    NativeDecompilerDocumentTokenRun(
        tokenID: "token.fixture",
        scalarOffset: 0,
        scalarLength: 5,
        kind: .identifier,
        sourceRanges: sourceRanges,
        entityReferences: entityReferences
    )
}

private func makeEditorSourceRange(
    start: UInt64,
    end: UInt64
) -> NativeDecompilerWireSourceRange {
    NativeDecompilerWireSourceRange(
        imageID: "image.fixture",
        startAddress: .init(start),
        endAddressExclusive: .init(end)
    )
}

private func editorSource(_ relativePath: String) throws -> String {
    let root = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: root.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}
