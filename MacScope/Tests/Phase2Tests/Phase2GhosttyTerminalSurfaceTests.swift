import AppKit
import XCTest

@testable import MacScope

@MainActor
final class Phase2GhosttyTerminalSurfaceTests: XCTestCase {
    func testLegacyGridCompilationTruthRequiresTheConcreteGhosttyModule() {
        XCTAssertTrue(Phase2GhosttyLegacyGridCompilation.isAvailable)
    }

    func testCoordinatorFeedsSplitRawUTF8BytesWithoutLossyRoundTrip() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000210")!
        let size = Phase2HumanPTYTerminalSize(columns: 8, rows: 2)
        let coordinator = Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: sessionID,
            terminalSize: size
        )

        coordinator.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [
                event(sessionID, 1, bytes: [0xF0, 0x9F]),
                event(sessionID, 2, bytes: [0x99, 0x82]),
            ]
        )

        let snapshot = try XCTUnwrap(coordinator.snapshot)
        XCTAssertEqual(snapshot.plainText, "🙂")
        XCTAssertEqual(coordinator.acceptedByteCount, 4)
        XCTAssertEqual(coordinator.lastUpdateDisposition, .applied(eventCount: 2, byteCount: 4))
    }

    func testCoordinatorRejectsForeignReorderedAndReplayedEvidenceAtomically() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000211")!
        let foreignID = UUID(uuidString: "00000000-0000-0000-0000-000000000212")!
        let size = Phase2HumanPTYTerminalSize(columns: 8, rows: 2)

        let foreign = Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: sessionID,
            terminalSize: size
        )
        foreign.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [event(sessionID, 1, "A"), event(foreignID, 2, "B")]
        )
        XCTAssertEqual(foreign.lastUpdateDisposition, .rejected(.wrongSession(sequence: 2)))
        XCTAssertNil(foreign.snapshot)
        XCTAssertNil(foreign.model)

        let reordered = Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: sessionID,
            terminalSize: size
        )
        reordered.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [event(sessionID, 2, "B"), event(sessionID, 1, "A")]
        )
        XCTAssertEqual(
            reordered.lastUpdateDisposition,
            .rejected(.sequenceGap(expected: 1, actual: 2))
        )
        XCTAssertNil(reordered.snapshot)

        let replayed = Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: sessionID,
            terminalSize: size
        )
        let complete = [event(sessionID, 1, "A"), event(sessionID, 2, "B")]
        replayed.update(sessionID: sessionID, terminalSize: size, transcriptEvents: complete)
        XCTAssertEqual(try XCTUnwrap(replayed.snapshot).plainText, "AB")
        replayed.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [complete[0]]
        )
        XCTAssertEqual(
            replayed.lastUpdateDisposition,
            .rejected(.replayedSnapshot(acceptedCount: 2, candidateCount: 1))
        )
        XCTAssertNil(replayed.snapshot)
        XCTAssertNil(replayed.model)

        replayed.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [complete[0]]
        )
        XCTAssertEqual(
            replayed.lastUpdateDisposition,
            .rejected(.replayedSnapshot(acceptedCount: 2, candidateCount: 1))
        )
        XCTAssertEqual(replayed.acceptedEventCount, 2)
        XCTAssertEqual(replayed.acceptedByteCount, 2)

        replayed.update(sessionID: sessionID, terminalSize: size, transcriptEvents: complete)
        XCTAssertEqual(try XCTUnwrap(replayed.snapshot).plainText, "AB")
        XCTAssertEqual(replayed.lastUpdateDisposition, .applied(eventCount: 0, byteCount: 0))
    }

    func testRejectedMutatedPrefixCannotBeResurrectedAndValidExtensionRebuilds() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000221")!
        let size = Phase2HumanPTYTerminalSize(columns: 8, rows: 2)
        let coordinator = Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: sessionID,
            terminalSize: size
        )
        let accepted = [event(sessionID, 1, "A"), event(sessionID, 2, "B")]
        let mutated = [event(sessionID, 1, "X"), event(sessionID, 2, "B")]

        coordinator.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: accepted
        )
        for _ in 0..<2 {
            coordinator.update(
                sessionID: sessionID,
                terminalSize: size,
                transcriptEvents: mutated
            )
            XCTAssertEqual(
                coordinator.lastUpdateDisposition,
                .rejected(.mutatedAcceptedPrefix(sequence: 1))
            )
            XCTAssertNil(coordinator.snapshot)
            XCTAssertEqual(coordinator.acceptedEventCount, 2)
        }

        let extensionTranscript = accepted + [event(sessionID, 3, "C")]
        coordinator.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: extensionTranscript
        )
        XCTAssertEqual(try XCTUnwrap(coordinator.snapshot).plainText, "ABC")
        XCTAssertEqual(coordinator.acceptedEventCount, 3)
        XCTAssertEqual(coordinator.lastUpdateDisposition, .applied(eventCount: 1, byteCount: 1))
    }

    func testCoordinatorAcceptsExactBudgetsAndRejectsEverySaturationBoundary() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000213")!
        let size = Phase2HumanPTYTerminalSize(columns: 4, rows: 2)
        let limits = Phase2GhosttyTerminalSurface.Coordinator.Limits(
            maximumEvents: 2,
            maximumEventBytes: 2,
            maximumCumulativeBytes: 3,
            maximumColumns: 4,
            maximumRows: 3,
            maximumCells: 8
        )

        let boundary = Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: sessionID,
            terminalSize: size,
            limits: limits
        )
        boundary.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [
                event(sessionID, 1, bytes: [65, 66]),
                event(sessionID, 2, bytes: [67]),
            ]
        )
        XCTAssertNotNil(boundary.snapshot)
        XCTAssertEqual(boundary.acceptedEventCount, 2)
        XCTAssertEqual(boundary.acceptedByteCount, 3)

        let excessiveEvents = coordinator(sessionID, size: size, limits: limits)
        excessiveEvents.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [
                event(sessionID, 1, "A"),
                event(sessionID, 2, "B"),
                event(sessionID, 3, "C"),
            ]
        )
        XCTAssertEqual(
            excessiveEvents.lastUpdateDisposition,
            .rejected(.eventCountExceeded(count: 3, limit: 2))
        )

        let excessiveEventBytes = coordinator(sessionID, size: size, limits: limits)
        excessiveEventBytes.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [event(sessionID, 1, bytes: [65, 66, 67])]
        )
        XCTAssertEqual(
            excessiveEventBytes.lastUpdateDisposition,
            .rejected(.eventByteBudgetExceeded(sequence: 1, count: 3, limit: 2))
        )

        let excessiveCumulativeBytes = coordinator(sessionID, size: size, limits: limits)
        excessiveCumulativeBytes.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [
                event(sessionID, 1, bytes: [65, 66]),
                event(sessionID, 2, bytes: [67, 68]),
            ]
        )
        XCTAssertEqual(
            excessiveCumulativeBytes.lastUpdateDisposition,
            .rejected(.cumulativeByteBudgetExceeded(count: 4, limit: 3))
        )

        let excessiveColumns = coordinator(sessionID, size: size, limits: limits)
        excessiveColumns.update(
            sessionID: sessionID,
            terminalSize: .init(columns: 5, rows: 1),
            transcriptEvents: [event(sessionID, 1, "A")]
        )
        XCTAssertEqual(
            excessiveColumns.lastUpdateDisposition,
            .rejected(.columnBudgetExceeded(count: 5, limit: 4))
        )

        let excessiveCells = coordinator(sessionID, size: size, limits: limits)
        excessiveCells.update(
            sessionID: sessionID,
            terminalSize: .init(columns: 4, rows: 3),
            transcriptEvents: [event(sessionID, 1, "A")]
        )
        XCTAssertEqual(
            excessiveCells.lastUpdateDisposition,
            .rejected(.cellBudgetExceeded(count: 12, limit: 8))
        )
    }

    func testCoordinatorCoalescesRepeatedCumulativeUpdatesWithoutRefedingGhostty() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000214")!
        let size = Phase2HumanPTYTerminalSize(columns: 8, rows: 2)
        let coordinator = Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: sessionID,
            terminalSize: size
        )
        let transcript = [event(sessionID, 1, "bounded")]

        coordinator.update(sessionID: sessionID, terminalSize: size, transcriptEvents: transcript)
        for _ in 0..<1_000 {
            coordinator.update(sessionID: sessionID, terminalSize: size, transcriptEvents: transcript)
        }

        XCTAssertEqual(try XCTUnwrap(coordinator.snapshot).plainText, "bounded")
        XCTAssertEqual(coordinator.appliedBatchCount, 1)
        XCTAssertEqual(coordinator.appliedEventCount, 1)
        XCTAssertEqual(coordinator.coalescedUpdateCount, 1_000)
        XCTAssertEqual(coordinator.acceptedEventCount, 1)
    }

    func testSessionReplacementAndViewDismantleReleaseRendererStateDeterministically() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000215")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000216")!
        let size = Phase2HumanPTYTerminalSize(columns: 8, rows: 2)
        let coordinator = Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: firstID,
            terminalSize: size
        )
        coordinator.update(
            sessionID: firstID,
            terminalSize: size,
            transcriptEvents: [event(firstID, 1, "first")]
        )
        weak let replacedModel = coordinator.model

        coordinator.update(
            sessionID: secondID,
            terminalSize: size,
            transcriptEvents: [event(secondID, 1, "second")]
        )

        XCTAssertNil(replacedModel)
        XCTAssertEqual(try XCTUnwrap(coordinator.snapshot).sessionID, secondID)
        let view = Phase2GhosttyTerminalGridView()
        view.snapshot = coordinator.snapshot
        view.keyEventHandler = { _ in }
        view.geometryHandler = { _, _ in }
        weak let dismantledModel = coordinator.model

        Phase2GhosttyTerminalSurface.dismantleNSView(view, coordinator: coordinator)

        XCTAssertNil(dismantledModel)
        XCTAssertTrue(coordinator.isRetired)
        XCTAssertNil(coordinator.model)
        XCTAssertNil(coordinator.snapshot)
        XCTAssertEqual(coordinator.acceptedEventCount, 0)
        XCTAssertNil(view.snapshot)
        XCTAssertNil(view.keyEventHandler)
        XCTAssertNil(view.geometryHandler)
        coordinator.update(
            sessionID: secondID,
            terminalSize: size,
            transcriptEvents: [event(secondID, 1, "second")]
        )
        XCTAssertEqual(coordinator.lastUpdateDisposition, .retired)
        XCTAssertNil(coordinator.model)
    }

    func testMarkedTextPreservesSelectedUTF16RangeUntilCommit() {
        let view = Phase2GhosttyTerminalGridView()
        view.setMarkedText(
            "候補",
            selectedRange: NSRange(location: 1, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 2))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 1))
        XCTAssertEqual(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 2), actualRange: nil)?.string, "候補")
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
    }
    func testCoordinatorReplaysTranscriptWhenLaterUpdateBackfillsGap() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let size = Phase2HumanPTYTerminalSize(columns: 16, rows: 2)
        let coordinator = Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: sessionID,
            terminalSize: size
        )

        coordinator.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [
                event(sessionID, 1, "A"),
                event(sessionID, 3, "C"),
            ]
        )
        XCTAssertNil(coordinator.snapshot)

        coordinator.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [
                event(sessionID, 1, "A"),
                event(sessionID, 2, "B"),
                event(sessionID, 3, "C"),
            ]
        )

        let replayed = try XCTUnwrap(coordinator.snapshot)
        XCTAssertEqual(replayed.plainText, "ABC")
        XCTAssertEqual(replayed.lastAppliedSequence, 3)
        XCTAssertTrue(replayed.missingSequenceRanges.isEmpty)
    }

    func testCoordinatorRejectsCumulativeTranscriptWhoseFirstSequenceIsTwo() {
        let sessionID = UUID()
        let size = Phase2HumanPTYTerminalSize(columns: 16, rows: 2)
        let coordinator = Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: sessionID,
            terminalSize: size
        )

        coordinator.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [event(sessionID, 2, "A"), event(sessionID, 3, "B")]
        )

        XCTAssertNil(coordinator.snapshot)
    }

    func testOnlyProtocolAndDeliberateTerminalModifiersBypassTextInput() {
        XCTAssertFalse(Phase2GhosttyTerminalGridView.shouldEncodeDirectly(keyCode: 0, modifierFlags: []))
        XCTAssertFalse(Phase2GhosttyTerminalGridView.shouldEncodeDirectly(keyCode: 0, modifierFlags: [.shift]))
        XCTAssertTrue(Phase2GhosttyTerminalGridView.shouldEncodeDirectly(keyCode: 7, modifierFlags: [.option]))
        XCTAssertTrue(Phase2GhosttyTerminalGridView.shouldEncodeDirectly(keyCode: 8, modifierFlags: [.control]))
        XCTAssertTrue(Phase2GhosttyTerminalGridView.shouldEncodeDirectly(keyCode: 126, modifierFlags: []))
    }

    func testCoordinatorRefusesSnapshotAfterBrokerTranscriptGap() {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
        let size = Phase2HumanPTYTerminalSize(columns: 16, rows: 2)
        let coordinator = Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: sessionID,
            terminalSize: size
        )

        coordinator.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [
                event(sessionID, 1, "trusted"),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .gap(reason: .spoolLimitExceeded, lostByteCount: 512)
                ),
                event(sessionID, 3, "plausible"),
            ]
        )

        XCTAssertNil(coordinator.snapshot)
    }

    func testCursorDecisionSpansWideLeadAndRedrawsBlockGraphemeWithInvertedColors() throws {
        let snapshot = gridSnapshot(cells: [cell("界", width: .wide), cell("", width: .spacerTail)])
        let cursor = Phase2TerminalGridCursor(
            column: 0,
            row: 0,
            style: .block,
            isVisible: true,
            shouldBlink: false
        )

        let decision = try XCTUnwrap(
            Phase2GhosttyTerminalGridView.cursorRenderDecision(cursor: cursor, snapshot: snapshot)
        )

        XCTAssertEqual(decision.originColumn, 0)
        XCTAssertEqual(decision.columnSpan, 2)
        XCTAssertTrue(decision.redrawsGrapheme)
        XCTAssertEqual(decision.cursorBackground, snapshot.gridRows[0].cells[0].style.foreground)
        XCTAssertEqual(decision.cursorForeground, snapshot.gridRows[0].cells[0].style.background)
    }

    func testCursorDecisionMapsWideSpacerTailBackToLeadCell() throws {
        let snapshot = gridSnapshot(cells: [cell("界", width: .wide), cell("", width: .spacerTail)])
        let cursor = Phase2TerminalGridCursor(
            column: 1,
            row: 0,
            style: .hollowBlock,
            isVisible: true,
            shouldBlink: false
        )

        let decision = try XCTUnwrap(
            Phase2GhosttyTerminalGridView.cursorRenderDecision(cursor: cursor, snapshot: snapshot)
        )

        XCTAssertEqual(decision.originColumn, 0)
        XCTAssertEqual(decision.columnSpan, 2)
        XCTAssertFalse(decision.redrawsGrapheme)
    }

    func testCursorDecisionKeepsOrphanSpacerInsideGrid() throws {
        let snapshot = gridSnapshot(cells: [cell("", width: .spacerHead)])
        let cursor = Phase2TerminalGridCursor(
            column: 0,
            row: 0,
            style: .block,
            isVisible: true,
            shouldBlink: false
        )

        let decision = try XCTUnwrap(
            Phase2GhosttyTerminalGridView.cursorRenderDecision(cursor: cursor, snapshot: snapshot)
        )

        XCTAssertEqual(decision.originColumn, 0)
        XCTAssertEqual(decision.columnSpan, 1)
        XCTAssertFalse(decision.redrawsGrapheme)
    }

    func testGeometryDerivesCellsAndPhysicalPixelsFromLiveBounds() throws {
        let metrics = Phase2GhosttyTerminalGridView.CellMetrics(width: 8, height: 16, baseline: 12)
        let geometry = try XCTUnwrap(
            Phase2GhosttyTerminalGridView.terminalGeometry(
                bounds: CGRect(x: 0, y: 0, width: 803, height: 401),
                cellMetrics: metrics,
                backingScale: 2
            )
        )
        XCTAssertEqual(geometry.size, Phase2HumanPTYTerminalSize(columns: 100, rows: 25))
        XCTAssertEqual(geometry.pixels.screenWidth, 1_606)
        XCTAssertEqual(geometry.pixels.screenHeight, 802)
        XCTAssertEqual(geometry.pixels.cellWidth, 16)
        XCTAssertEqual(geometry.pixels.cellHeight, 32)
    }

    func testGridHitTestingAndWheelDirectionUseViewportCoordinates() {
        let snapshot = gridSnapshot(cells: [cell("a", width: .narrow), cell("b", width: .narrow)])
        let metrics = Phase2GhosttyTerminalGridView.CellMetrics(width: 8, height: 16, baseline: 12)
        XCTAssertEqual(
            Phase2GhosttyTerminalGridView.gridPoint(
                localPoint: CGPoint(x: 9, y: 3),
                snapshot: snapshot,
                cellMetrics: metrics
            ),
            Phase2TerminalGridPoint(column: 1, row: 0)
        )
        XCTAssertEqual(
            Phase2GhosttyTerminalGridView.scrollRows(deltaY: 32, hasPreciseDeltas: true, cellHeight: 16),
            -2
        )
        XCTAssertEqual(
            Phase2GhosttyTerminalGridView.scrollRows(deltaY: -1, hasPreciseDeltas: false, cellHeight: 16),
            1
        )
    }

    func testSelectionAutoscrollClampsPointerAndAcceleratesOutsideViewport() {
        XCTAssertEqual(
            Phase2GhosttyTerminalGridView.selectionAutoscroll(
                localY: -33,
                viewportHeight: 160,
                cellHeight: 16
            ),
            .init(rows: -3, clampedY: 0)
        )
        XCTAssertEqual(
            Phase2GhosttyTerminalGridView.selectionAutoscroll(
                localY: 193,
                viewportHeight: 160,
                cellHeight: 16
            ),
            .init(rows: 3, clampedY: 159)
        )
    }

    func testScrollerReflectsGhosttyViewportAndTrackingAreaRequestsMouseMotion() {
        let view = Phase2GhosttyTerminalGridView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        view.snapshot = gridSnapshot(
            cells: [cell("a", width: .narrow)],
            viewport: Phase2TerminalViewportState(totalRows: 10, offset: 4, visibleRows: 2)
        )
        let scroller = view.subviews.compactMap { $0 as? NSScroller }.first
        XCTAssertNotNil(scroller)
        XCTAssertFalse(scroller?.isHidden ?? true)
        XCTAssertEqual(scroller?.doubleValue ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(scroller?.knobProportion ?? -1, 0.2, accuracy: 0.001)

        view.updateTrackingAreas()
        XCTAssertTrue(view.trackingAreas.contains { $0.options.contains(.mouseMoved) })
    }

    func testRightAndMiddleDragEventsRetainTheirPressedButtonIdentity() throws {
        let view = Phase2GhosttyTerminalGridView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        var forwardedEvents: [Phase2TerminalMouseEvent] = []
        view.mouseEventHandler = { event, _ in
            forwardedEvents.append(event)
            return true
        }
        let rightDrag = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDragged,
            location: NSPoint(x: 8, y: 8),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let middleDrag = try XCTUnwrap(NSEvent.mouseEvent(
            with: .otherMouseDragged,
            location: NSPoint(x: 16, y: 16),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))

        view.rightMouseDragged(with: rightDrag)
        view.otherMouseDragged(with: middleDrag)

        XCTAssertEqual(forwardedEvents.map(\.action), [.motion, .motion])
        XCTAssertEqual(forwardedEvents.map(\.button), [.right, .middle])
    }

    func testBackingPropertyLifecycleReportsGeometryAtTheNewScale() {
        let view = Phase2GhosttyTerminalGridView()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 160)
        var reports: [Phase2TerminalPixelGeometry] = []
        view.geometryHandler = { _, pixels in reports.append(pixels) }
        view.reportGeometryIfNeeded(backingScale: 1)
        view.viewDidChangeBackingProperties()
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[1].screenWidth, reports[0].screenWidth * 2)
        XCTAssertEqual(reports[1].screenHeight, reports[0].screenHeight * 2)
        XCTAssertEqual(reports[1].cellWidth, reports[0].cellWidth * 2)
        XCTAssertEqual(reports[1].cellHeight, reports[0].cellHeight * 2)
    }

    func testCopyCommandUsesTheConcreteGhosttySelectionPayload() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000205")!
        let model = Phase2GhosttyTerminalModel(
            sessionID: sessionID,
            terminalSize: Phase2HumanPTYTerminalSize(columns: 12, rows: 2)
        )
        _ = model.ingest([
            Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: 1,
                source: .broker,
                payload: .output(stream: .standardOutput, bytes: Array("hello world".utf8))
            ),
        ])
        XCTAssertTrue(model.select(
            from: .init(column: 0, row: 0),
            through: .init(column: 4, row: 0)
        ))

        let view = Phase2GhosttyTerminalGridView()
        view.selectedTextHandler = { model.selectedText() }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        XCTAssertTrue(view.copySelection(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
    }

    func testMeasuredGeometryProposesBrokerResizeBeforeGhosttyAcceptsIt() {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000204")!
        let initial = Phase2HumanPTYTerminalSize(columns: 80, rows: 24)
        let proposed = Phase2HumanPTYTerminalSize(columns: 100, rows: 30)
        let coordinator = Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: sessionID,
            terminalSize: initial
        )
        var dispatched: [Phase2HumanPTYTerminalSize] = []
        coordinator.proposeGeometry(
            size: proposed,
            pixels: .init(
                screenWidth: .max,
                screenHeight: 480,
                cellWidth: 8,
                cellHeight: 16
            ),
            resizeHandler: { dispatched.append($0) }
        )
        XCTAssertTrue(dispatched.isEmpty)
        coordinator.proposeGeometry(
            size: proposed,
            pixels: .init(screenWidth: 800, screenHeight: 480, cellWidth: 8, cellHeight: 16),
            resizeHandler: { dispatched.append($0) }
        )
        coordinator.proposeGeometry(
            size: proposed,
            pixels: .init(screenWidth: 800, screenHeight: 480, cellWidth: 8, cellHeight: 16),
            resizeHandler: { dispatched.append($0) }
        )
        XCTAssertEqual(dispatched, [proposed])
        XCTAssertEqual(coordinator.authoritativeTerminalSize, initial)

        coordinator.update(
            sessionID: sessionID,
            terminalSize: proposed,
            transcriptEvents: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .resize(columns: proposed.columns, rows: proposed.rows)
                ),
            ]
        )
        XCTAssertEqual(coordinator.authoritativeTerminalSize, proposed)

        coordinator.proposeGeometry(
            size: proposed,
            pixels: .init(screenWidth: 1_600, screenHeight: 960, cellWidth: 16, cellHeight: 32),
            resizeHandler: { dispatched.append($0) }
        )
        XCTAssertEqual(dispatched, [proposed], "backing-scale-only changes stay inside Ghostty")
    }

    private func event(
        _ sessionID: UUID,
        _ sequence: UInt64,
        _ output: String
    ) -> Phase2HumanPTYTranscriptEvent {
        event(sessionID, sequence, bytes: Array(output.utf8))
    }

    private func event(
        _ sessionID: UUID,
        _ sequence: UInt64,
        bytes: [UInt8]
    ) -> Phase2HumanPTYTranscriptEvent {
        Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: sequence,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: bytes)
        )
    }

    private func coordinator(
        _ sessionID: UUID,
        size: Phase2HumanPTYTerminalSize,
        limits: Phase2GhosttyTerminalSurface.Coordinator.Limits
    ) -> Phase2GhosttyTerminalSurface.Coordinator {
        Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: sessionID,
            terminalSize: size,
            limits: limits
        )
    }

    private func gridSnapshot(
        cells: [Phase2TerminalGridCell],
        viewport: Phase2TerminalViewportState = .init(totalRows: 1, offset: 0, visibleRows: 1)
    ) -> Phase2TerminalGridSnapshot {
        Phase2TerminalGridSnapshot(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            columns: cells.count,
            rows: 1,
            defaultForeground: color(230),
            defaultBackground: color(20),
            gridRows: [Phase2TerminalGridRow(cells: cells, isDirty: true)],
            cursor: nil,
            lastAppliedSequence: nil,
            missingSequenceRanges: [],
            viewport: viewport
        )
    }

    private func cell(
        _ grapheme: String,
        width: Phase2TerminalGridCellWidth
    ) -> Phase2TerminalGridCell {
        Phase2TerminalGridCell(
            grapheme: grapheme,
            width: width,
            style: Phase2TerminalGridCellStyle(
                foreground: color(230),
                background: color(20),
                bold: false,
                italic: false,
                faint: false,
                inverse: false,
                invisible: false,
                strikethrough: false,
                overline: false,
                underline: 0
            ),
            isSelected: false
        )
    }

    private func color(_ component: UInt8) -> Phase2TerminalGridColor {
        Phase2TerminalGridColor(red: component, green: component, blue: component)
    }
}
