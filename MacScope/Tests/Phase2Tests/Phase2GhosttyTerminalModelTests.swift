import XCTest

@testable import MacScope

@MainActor
final class Phase2GhosttyTerminalModelTests: XCTestCase {
    func testIngestsOrderedOutputOnceAndCopiesStyledGridAndCursor() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let model = Phase2GhosttyTerminalModel(
            sessionID: sessionID,
            terminalSize: Phase2HumanPTYTerminalSize(columns: 16, rows: 3)
        )
        let events = [
            event(sessionID, 1, .output(stream: .standardOutput, bytes: Array("plain ".utf8))),
            event(sessionID, 2, .output(stream: .standardOutput, bytes: Array("\u{1B}[1;32mgreen\u{1B}[0m".utf8))),
            event(sessionID, 3, .output(stream: .standardOutput, bytes: Array("\r\nwide:界".utf8))),
        ]

        let first = model.ingest(events)
        let duplicate = model.ingest(events)
        let snapshot = try XCTUnwrap(model.snapshot())

        XCTAssertEqual(first.appliedSequences, [1, 2, 3])
        XCTAssertEqual(duplicate.ignoredDuplicateSequences, [1, 2, 3])
        XCTAssertEqual(snapshot.lastAppliedSequence, 3)
        XCTAssertTrue(snapshot.plainText.contains("plain green"))
        XCTAssertTrue(snapshot.plainText.contains("wide:界"))
        XCTAssertEqual(snapshot.gridRows.count, 3)
        XCTAssertEqual(snapshot.gridRows.flatMap(\.cells).filter { $0.width == .spacerTail }.count, 1)
        let green = try XCTUnwrap(snapshot.gridRows.flatMap(\.cells).first { $0.grapheme == "g" })
        XCTAssertTrue(green.style.bold)
        XCTAssertGreaterThan(green.style.foreground.green, green.style.foreground.red)
        XCTAssertNotNil(snapshot.cursor)
    }

    func testRecordsSequenceGapAndIgnoresForeignSession() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let foreignID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        let model = Phase2GhosttyTerminalModel(sessionID: sessionID)

        _ = model.ingest((1...4).map {
            event(sessionID, UInt64($0), .output(stream: .standardOutput, bytes: [65]))
        })
        let result = model.ingest([
            event(foreignID, 5, .output(stream: .standardOutput, bytes: [66])),
            event(sessionID, 7, .output(stream: .standardOutput, bytes: [67])),
        ])

        XCTAssertEqual(result.ignoredForeignSessionSequences, [5])
        XCTAssertEqual(result.missingSequenceRanges, [5...6])
        XCTAssertEqual(model.integrity, .sequenceGap(5...6))
        XCTAssertNil(model.snapshot())
        XCTAssertNil(model.encodeInput(key(126)))
        XCTAssertNil(model.encodePaste("untrusted"))
    }

    func testRejectsContiguousTranscriptThatDoesNotBeginAtSequenceOne() {
        let sessionID = UUID()
        let model = Phase2GhosttyTerminalModel(sessionID: sessionID)

        let result = model.ingest([
            event(sessionID, 2, .output(stream: .standardOutput, bytes: [65])),
            event(sessionID, 3, .output(stream: .standardOutput, bytes: [66])),
        ])

        XCTAssertEqual(result.missingSequenceRanges, [1...1])
        XCTAssertEqual(model.integrity, .sequenceGap(1...1))
        XCTAssertNil(model.snapshot())
    }

    func testMaximumSequenceDoesNotOverflowAdjacencyCheck() {
        XCTAssertNil(
            Phase2GhosttyTerminalModel.missingSequenceRange(
                after: UInt64.max,
                before: UInt64.max
            )
        )
    }

    func testResizePersistsUntilSessionIdentityChanges() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
        let model = Phase2GhosttyTerminalModel(sessionID: firstID)

        _ = model.ingest([
            event(firstID, 1, .output(stream: .standardOutput, bytes: Array("first".utf8))),
            event(firstID, 2, .resize(columns: 40, rows: 6)),
        ])
        let resized = try XCTUnwrap(model.snapshot())
        XCTAssertEqual(resized.columns, 40)
        XCTAssertEqual(resized.rows, 6)
        XCTAssertTrue(resized.plainText.contains("first"))

        model.replaceSession(secondID, terminalSize: Phase2HumanPTYTerminalSize(columns: 20, rows: 4))
        let replaced = try XCTUnwrap(model.snapshot())
        XCTAssertEqual(replaced.sessionID, secondID)
        XCTAssertEqual(replaced.columns, 20)
        XCTAssertEqual(replaced.rows, 4)
        XCTAssertNil(replaced.lastAppliedSequence)
        XCTAssertFalse(replaced.plainText.contains("first"))
    }

    func testTranscriptGapDestroysGridAndRejectsLaterPlausibleOutput() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000106")!
        let model = Phase2GhosttyTerminalModel(sessionID: sessionID)

        _ = model.ingest([
            event(sessionID, 1, .output(stream: .standardOutput, bytes: Array("trusted".utf8))),
        ])
        XCTAssertTrue(try XCTUnwrap(model.snapshot()).plainText.contains("trusted"))

        let ingestion = model.ingest([
            event(sessionID, 2, .gap(reason: .spoolLimitExceeded, lostByteCount: 4_096)),
            event(sessionID, 3, .output(stream: .standardOutput, bytes: Array("plausible".utf8))),
        ])

        XCTAssertEqual(ingestion.appliedSequences, [2])
        XCTAssertEqual(
            model.integrity,
            .transcriptGap(reason: .spoolLimitExceeded, lostByteCount: 4_096)
        )
        XCTAssertNil(model.snapshot())
        XCTAssertEqual(model.lastAppliedSequence, 2)

        _ = model.ingest([
            event(sessionID, 3, .output(stream: .standardOutput, bytes: Array("still-untrusted".utf8))),
        ])
        XCTAssertNil(model.snapshot())
    }

    func testInputEncodingTracksLiveGhosttyCursorKeypadAndPasteModes() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000107")!
        let model = Phase2GhosttyTerminalModel(sessionID: sessionID)

        XCTAssertEqual(text(model.encodeInput(key(126))), "\u{1B}[A")
        _ = model.ingest([
            event(sessionID, 1, .output(
                stream: .standardOutput,
                bytes: Array("\u{1B}[?1h\u{1B}=\u{1B}[?2004h".utf8)
            )),
        ])

        XCTAssertEqual(text(model.encodeInput(key(126))), "\u{1B}OA")
        XCTAssertEqual(model.terminalMode(value: 66), true)
        XCTAssertEqual(text(model.encodePaste("hello")), "\u{1B}[200~hello\u{1B}[201~")
    }

    func testInputEncodingFailsClosedAfterTranscriptIntegrityLoss() {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000108")!
        let model = Phase2GhosttyTerminalModel(sessionID: sessionID)
        _ = model.ingest([
            event(sessionID, 1, .gap(reason: .brokerRestart, lostByteCount: 1)),
        ])
        XCTAssertNil(model.encodeInput(key(126)))
        XCTAssertNil(model.encodePaste("hello"))
    }

    func testScrollbackViewportAndSelectionCopyRemainGhosttyAuthoritative() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000109")!
        let model = Phase2GhosttyTerminalModel(
            sessionID: sessionID,
            terminalSize: Phase2HumanPTYTerminalSize(columns: 12, rows: 2)
        )
        _ = model.ingest([
            event(sessionID, 1, .output(
                stream: .standardOutput,
                bytes: Array("first\r\nsecond\r\nthird\r\nfourth".utf8)
            )),
        ])

        let bottom = try XCTUnwrap(model.snapshot())
        XCTAssertGreaterThan(bottom.viewport.scrollbackRows, 0)
        XCTAssertTrue(bottom.viewport.isAtBottom)

        model.scrollViewport(rows: -1)
        let scrolled = try XCTUnwrap(model.snapshot())
        XCTAssertLessThan(scrolled.viewport.offset, bottom.viewport.offset)
        XCTAssertFalse(scrolled.viewport.isAtBottom)

        XCTAssertTrue(model.select(from: .init(column: 0, row: 0), through: .init(column: 4, row: 0)))
        XCTAssertFalse(try XCTUnwrap(model.selectedText()).isEmpty)

        model.scrollViewportToBottom()
        XCTAssertTrue(try XCTUnwrap(model.snapshot()).viewport.isAtBottom)
    }

    func testViewportSelectionCopyAndMouseFailClosedAfterTranscriptGap() {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000110")!
        let model = Phase2GhosttyTerminalModel(sessionID: sessionID)
        _ = model.ingest([
            event(sessionID, 1, .gap(reason: .brokerRestart, lostByteCount: 2)),
        ])

        XCTAssertFalse(model.select(from: .init(column: 0, row: 0), through: .init(column: 1, row: 0)))
        XCTAssertFalse(model.selectAll())
        XCTAssertNil(model.selectedText())
        XCTAssertFalse(model.isMouseTrackingEnabled)
    }

    func testSelectionAnchorSurvivesViewportAutoscrollInScreenCoordinates() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        let model = Phase2GhosttyTerminalModel(
            sessionID: sessionID,
            terminalSize: Phase2HumanPTYTerminalSize(columns: 12, rows: 2)
        )
        _ = model.ingest([
            event(sessionID, 1, .output(
                stream: .standardOutput,
                bytes: Array("one\r\ntwo\r\nthree\r\nfour".utf8)
            )),
        ])

        XCTAssertTrue(model.beginSelection(at: .init(column: 0, row: 1)))
        let initial = try XCTUnwrap(model.selectedText())
        model.scrollViewport(rows: -1)
        XCTAssertTrue(model.extendSelection(to: .init(column: 0, row: 0)))
        let extended = try XCTUnwrap(model.selectedText())
        XCTAssertNotEqual(extended, initial)
        XCTAssertGreaterThan(extended.count, initial.count)
        model.endSelection()

        model.scrollViewport(to: 0)
        XCTAssertEqual(try XCTUnwrap(model.snapshot()).viewport.offset, 0)
    }

    func testSelectionCopyReturnsExactGhosttyPayload() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000112")!
        let model = Phase2GhosttyTerminalModel(
            sessionID: sessionID,
            terminalSize: Phase2HumanPTYTerminalSize(columns: 12, rows: 2)
        )
        _ = model.ingest([
            event(sessionID, 1, .output(stream: .standardOutput, bytes: Array("hello world".utf8))),
        ])
        XCTAssertTrue(model.select(from: .init(column: 0, row: 0), through: .init(column: 4, row: 0)))
        XCTAssertEqual(model.selectedText(), "hello")
    }

    func testMouseEncoderReturnsConcreteSGRPressReleaseAndDragBytesForEveryPrimaryButton() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000113")!
        let model = Phase2GhosttyTerminalModel(sessionID: sessionID)
        _ = model.ingest([
            event(sessionID, 1, .output(
                stream: .standardOutput,
                bytes: Array("\u{1B}[?1003h\u{1B}[?1006h".utf8)
            )),
        ])
        let geometry = Phase2TerminalPixelGeometry(
            screenWidth: 640,
            screenHeight: 384,
            cellWidth: 8,
            cellHeight: 16
        )
        let position = Phase2TerminalMousePosition(x: 0, y: 0)
        let press = model.encodeMouse(
            .init(action: .press, button: .left, modifiers: 0, position: position),
            geometry: geometry
        )
        let release = model.encodeMouse(
            .init(action: .release, button: .left, modifiers: 0, position: position),
            geometry: geometry
        )
        let motion = model.encodeMouse(
            .init(action: .motion, button: nil, modifiers: 0, position: position),
            geometry: geometry
        )
        let rightDrag = model.encodeMouse(
            .init(action: .motion, button: .right, modifiers: 0, position: position),
            geometry: geometry
        )
        let middleDrag = model.encodeMouse(
            .init(action: .motion, button: .middle, modifiers: 0, position: position),
            geometry: geometry
        )
        XCTAssertEqual(text(press), "\u{1B}[<0;1;1M")
        XCTAssertEqual(text(release), "\u{1B}[<0;1;1m")
        XCTAssertEqual(text(motion), "\u{1B}[<35;1;1M")
        XCTAssertEqual(text(rightDrag), "\u{1B}[<34;1;1M")
        XCTAssertEqual(text(middleDrag), "\u{1B}[<33;1;1M")
    }

    private func key(_ keyCode: UInt16) -> Phase2TerminalInputEncoder.KeyEvent {
        Phase2TerminalInputEncoder.KeyEvent(
            keyCode: keyCode,
            characters: keyCode == 82 ? "0" : nil,
            charactersIgnoringModifiers: keyCode == 82 ? "0" : nil,
            modifiers: []
        )
    }

    private func text(_ bytes: [UInt8]?) -> String? {
        bytes.map { String(decoding: $0, as: UTF8.self) }
    }

    private func event(
        _ sessionID: UUID,
        _ sequence: UInt64,
        _ payload: Phase2HumanPTYEventPayload
    ) -> Phase2HumanPTYTranscriptEvent {
        Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: sequence,
            source: .broker,
            payload: payload
        )
    }
}
