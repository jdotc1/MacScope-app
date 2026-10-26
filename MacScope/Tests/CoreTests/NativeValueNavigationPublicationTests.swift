import AppKit
import XCTest
@testable import MacScope

@MainActor
final class NativeValueNavigationPublicationTests: XCTestCase {
    func testSameRequestRepublishedUnderNewGenerationRejectsOldNavigation() throws {
        let fixture = NativeValueNavigationFixture()
        let oldScope = try XCTUnwrap(fixture.scope(generation: 1))
        let capture = try makeCapture(oldScope)
        let index = try NativeValueNavigationIndex(result: fixture.result)
        let report = try index.query(seedValueID: "v.merged", direction: .definitions)
        let originalTarget = capture.target(rowID: 0, sourceIndex: 0, report: report, currentScope: oldScope)
        XCTAssertNotNil(originalTarget)
        let republished = try XCTUnwrap(fixture.scope(generation: 2))
        XCTAssertEqual(oldScope.result.requestID, republished.result.requestID)
        XCTAssertFalse(capture.matches(republished))
        XCTAssertNil(capture.target(rowID: 0, sourceIndex: 0, report: report, currentScope: republished))
    }

    func testWorkspaceOwnerImageSlotAndAnalysisFingerprintEachInvalidateCapture() throws {
        let fixture = NativeValueNavigationFixture()
        let scope = try XCTUnwrap(fixture.scope())
        let capture = try makeCapture(scope)
        XCTAssertFalse(capture.matches(fixture.scope(workspaceID: UUID())))
        XCTAssertFalse(capture.matches(fixture.scope(ownerToken: UUID())))
        XCTAssertFalse(capture.matches(fixture.scope(imageSlot: .init(rawValue: 8))))
        XCTAssertFalse(capture.matches(fixture.scope(fingerprint: String(repeating: "f", count: 64))))
        XCTAssertFalse(capture.matches(nil), "Hidden/importing/non-native scope is unavailable.")
    }

    func testUnknownTokenAndForgedRowIndicesCannotNavigate() throws {
        let fixture = NativeValueNavigationFixture()
        let scope = try XCTUnwrap(fixture.scope())
        XCTAssertNil(NativeValueNavigationCapture.capture(
            request: .init(tokenID: "missing", direction: .definitions), scope: scope, captured: scope.identity
        ))
        let capture = try makeCapture(scope)
        let report = try NativeValueNavigationIndex(result: fixture.result)
            .query(seedValueID: "v.merged", direction: .definitions)
        XCTAssertNil(capture.target(rowID: -1, sourceIndex: 0, report: report, currentScope: scope))
        XCTAssertNil(capture.target(rowID: 0, sourceIndex: 100, report: report, currentScope: scope))
    }

    func testRetainedMenuDoesNotRebindToReplacementPublication() throws {
        let fixture = NativeValueNavigationFixture()
        let original = try XCTUnwrap(fixture.scope(generation: 1))
        var current: NativePseudocodeActionScope? = original
        var navigations: [ImageAddress] = []
        let router = NativePseudocodeActionRouter(
            currentScope: { current },
            navigate: { navigations.append($0); return true }
        )
        let textView = NativePseudocodeNSTextView(frame: .zero)
        textView.onValueAction = { request in router.value(request, captured: original.identity) }
        let interaction = try XCTUnwrap(NativePseudocodeInteractionProjection.project(
            document: original.document, scalarOffset: 0,
            isHovered: false, isFocused: true, isSelected: true
        ))
        let menu = textView.actionMenu(for: interaction)
        let command = try XCTUnwrap(menu.items.firstIndex { $0.title == "Show Definitions…" })
        current = try XCTUnwrap(fixture.scope(generation: 2))
        textView.onValueAction = { _ in XCTFail("An old menu must retain its old callback.") }
        menu.performActionForItem(at: command)
        XCTAssertNil(router.sheet)
        XCTAssertTrue(navigations.isEmpty)
    }

    func testSessionInvalidationRejectsLaterRevealAndCandidateChanges() throws {
        let fixture = NativeValueNavigationFixture()
        let original = try XCTUnwrap(fixture.scope())
        var current: NativePseudocodeActionScope? = original
        var navigated = false
        let session = NativeValueNavigationSession(
            capture: try makeCapture(original), direction: .definitions,
            currentScope: { current },
            navigate: { _ in navigated = true; return true }
        )
        current = nil
        session.reconcile()
        session.choose(valueID: "v.merged")
        session.reveal(rowID: 0, sourceIndex: 0, reportID: UUID())
        XCTAssertEqual(session.phase, .invalidated)
        XCTAssertFalse(navigated)
    }

    func testDelayedWorkerCannotPublishAfterSameRequestRepublication() async throws {
        let fixture = NativeValueNavigationFixture()
        let original = try XCTUnwrap(fixture.scope(generation: 1))
        var current: NativePseudocodeActionScope? = original
        let entered = expectation(description: "Index builder captured original publication")
        let gate = ValueNavigationBuildGate()
        let session = NativeValueNavigationSession(
            capture: try makeCapture(original), direction: .definitions,
            currentScope: { current }, navigate: { _ in XCTFail("Stale navigation"); return false },
            buildIndex: { result, limits in
                entered.fulfill()
                await gate.wait()
                return try NativeValueNavigationIndex(result: result, limits: limits)
            }
        )
        session.start()
        let oldWork = try XCTUnwrap(session.task)
        await fulfillment(of: [entered], timeout: 5)
        current = try XCTUnwrap(fixture.scope(generation: 2))
        session.reconcile()
        XCTAssertEqual(session.phase, .invalidated)
        let router = NativePseudocodeActionRouter(currentScope: { current }, navigate: { _ in true })
        let replacement = try XCTUnwrap(current)
        router.value(.init(tokenID: "token.merged", direction: .uses), captured: replacement.identity)
        let sheetID = try XCTUnwrap(router.sheet?.id)
        guard let sheet = router.sheet, case let .values(replacementSession) = sheet.content else {
            await gate.release()
            await oldWork.value
            return XCTFail("Expected the replacement value session")
        }
        let replacementWork = try XCTUnwrap(replacementSession.task)
        await gate.release()
        await oldWork.value
        XCTAssertEqual(session.phase, .invalidated)
        XCTAssertEqual(router.sheet?.id, sheetID)
        await replacementWork.value
        guard case .report = replacementSession.phase else {
            XCTFail("Current publication must still complete its own query")
            router.dismiss()
            return
        }
        router.dismiss()
    }

    func testRetainedRowCannotRebindAfterDirectionChanges() async throws {
        let fixture = NativeValueNavigationFixture()
        let scope = try XCTUnwrap(fixture.scope())
        var navigations: [ImageAddress] = []
        let session = NativeValueNavigationSession(
            capture: try makeCapture(scope), direction: .definitions,
            currentScope: { scope }, navigate: { navigations.append($0); return true }
        )
        session.start()
        await session.task?.value
        guard case let .report(_, definitions) = session.phase else {
            return XCTFail("Expected definition report")
        }
        let definitionsID = try XCTUnwrap(session.reportID)
        session.changeDirection(.uses)
        await session.task?.value
        guard case let .report(_, uses) = session.phase else {
            return XCTFail("Expected use report")
        }
        XCTAssertNotEqual(definitions, uses)
        let usesID = try XCTUnwrap(session.reportID)
        XCTAssertNotEqual(definitionsID, usesID)
        session.reveal(rowID: 0, sourceIndex: 0, reportID: definitionsID)
        XCTAssertTrue(navigations.isEmpty)
        session.reveal(rowID: 0, sourceIndex: 0, reportID: usesID)
        XCTAssertEqual(navigations.count, 1)
        XCTAssertEqual(session.phase, .invalidated)
    }

    func testInvalidationBeforeStartIsTerminalEvenWhenScopeStillMatches() throws {
        let scope = try XCTUnwrap(NativeValueNavigationFixture().scope())
        let session = NativeValueNavigationSession(
            capture: try makeCapture(scope), direction: .definitions,
            currentScope: { scope }, navigate: { _ in false }
        )
        session.invalidate()
        session.start()
        XCTAssertEqual(session.phase, .invalidated)
        XCTAssertNil(session.task)
    }

    private func makeCapture(_ scope: NativePseudocodeActionScope) throws -> NativeValueNavigationCapture {
        try XCTUnwrap(NativeValueNavigationCapture.capture(
            request: .init(tokenID: "token.merged", direction: .definitions),
            scope: scope, captured: scope.identity
        ))
    }
}

private actor ValueNavigationBuildGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
