import XCTest
@testable import MacScope

final class NativeDecompilerDocumentProjectionTests: XCTestCase {
    func testProjectsASCIIWhitespaceTabsCombiningScalarsAndEmojiFromOneBasedCoordinates() throws {
        let text = "int\tname = e\u{301};\nreturn 🧭;\n"
        let document = NativeDecompilerWirePseudocodeDocument(
            text: text,
            language: "c",
            isComplete: true,
            isTruncated: false
        )

        let projection = try NativeDecompilerDocumentProjector.project(
            document: document,
            tokens: [
                token("token.int", "int", .keyword, line: 1, column: 1),
                token("token.name", "name", .identifier, line: 1, column: 5),
                token("token.value", "e\u{301}", .literal, line: 1, column: 12),
                token("token.return", "return", .keyword, line: 2, column: 1),
                token("token.compass", "🧭", .literal, line: 2, column: 8),
            ],
            isCancelled: { false }
        )

        XCTAssertEqual(projection.text, text)
        XCTAssertEqual(projection.isComplete, true)
        XCTAssertEqual(projection.isTruncated, false)
        XCTAssertEqual(projection.mappingState, .verified)
        XCTAssertEqual(projection.tokenRuns.map(\.tokenID), [
            "token.int", "token.name", "token.value", "token.return", "token.compass",
        ])
        XCTAssertEqual(projection.tokenRuns.map(\.scalarOffset), [0, 4, 11, 15, 22])
        XCTAssertEqual(projection.tokenRuns.map(\.scalarLength), [3, 4, 2, 6, 1])
        XCTAssertEqual(
            projection.tokenRuns.map(\.kind),
            [.keyword, .identifier, .literal, .keyword, .literal]
        )
    }

    func testPreservesSparseGapsAsUnstyledText() throws {
        let document = completeDocument("alpha + beta\n")
        let sourceRange = NativeDecompilerWireSourceRange(
            imageID: "image.fixture",
            startAddress: .init(0x1000),
            endAddressExclusive: .init(0x1004)
        )
        let entity = NativeDecompilerWireTokenEntityReference(kind: .variable, id: "variable.alpha")
        let tokens = [
            token(
                "token.alpha", "alpha", .identifier, line: 1, column: 1,
                sourceRanges: [sourceRange], entityReferences: [entity]
            ),
            token("token.beta", "beta", .identifier, line: 1, column: 9),
        ]

        let projection = try NativeDecompilerDocumentProjector.project(
            document: document,
            tokens: tokens,
            isCancelled: { false }
        )

        XCTAssertEqual(projection.mappingState, .verified)
        XCTAssertEqual(projection.tokenRuns.map(\.scalarOffset), [0, 8])
        XCTAssertEqual(projection.tokenRuns.map(\.scalarLength), [5, 4])
        XCTAssertEqual(projection.tokenRuns[0].sourceRanges, [sourceRange])
        XCTAssertEqual(projection.tokenRuns[0].entityReferences, [entity])
        XCTAssertEqual(projection.text, document.text)
    }

    func testCompleteDocumentMismatchDegradesWholeOverlayButPreservesExactText() throws {
        try assertDegraded(
            document: completeDocument("alpha\n"),
            tokens: [token("token.bad", "alpHa", .identifier, line: 1, column: 1)],
            reason: .visibleTextMismatch
        )
    }

    func testOverlapDegradesWholeOverlay() throws {
        try assertDegraded(
            document: completeDocument("alpha\n"),
            tokens: [
                token("token.alpha", "alpha", .identifier, line: 1, column: 1),
                token("token.pha", "pha", .identifier, line: 1, column: 3),
            ],
            reason: .overlappingRanges
        )
    }

    func testDuplicateRangeDegradesWholeOverlay() throws {
        try assertDegraded(
            document: completeDocument("alpha\n"),
            tokens: [
                token("token.first", "alpha", .identifier, line: 1, column: 1),
                token("token.second", "alpha", .type, line: 1, column: 1),
            ],
            reason: .duplicateRange
        )
    }

    func testAmbiguousRangeDegradesWholeOverlay() throws {
        try assertDegraded(
            document: completeDocument("alpha\n"),
            tokens: [
                token("token.short", "a", .identifier, line: 1, column: 1),
                token("token.long", "alpha", .identifier, line: 1, column: 1),
            ],
            reason: .ambiguousRange
        )
    }

    func testInvalidCoordinatesAndOutOfBoundsRangesDegrade() throws {
        let document = completeDocument("alpha\n")
        for invalid in [
            token("token.zero-line", "alpha", .identifier, line: 0, column: 1),
            token("token.zero-column", "alpha", .identifier, line: 1, column: 0),
            token("token.missing-line", "alpha", .identifier, line: 3, column: 1),
            token("token.past-line", "alpha", .identifier, line: 1, column: 8),
            token("token.crosses-end", "alpha", .identifier, line: 1, column: 4),
        ] {
            try assertDegraded(document: document, tokens: [invalid], reason: .invalidCoordinate)
        }
    }

    func testCompleteDocumentTokenCannotCrossItsCoordinateLine() throws {
        try assertDegraded(
            document: completeDocument("ab\ncd\n"),
            tokens: [token("token.cross-line", "b\nc", .identifier, line: 1, column: 2)],
            reason: .invalidCoordinate
        )
    }

    func testCompleteDocumentTokenCannotCrossCRLFCoordinateLine() throws {
        try assertDegraded(
            document: completeDocument("ab\r\ncd\r\n"),
            tokens: [token("token.cross-crlf", "b\r\nc", .identifier, line: 1, column: 2)],
            reason: .invalidCoordinate
        )
    }

    func testTruncatedDocumentOmitsTokensWhollyBeyondVisiblePrefix() throws {
        let document = truncatedDocument("return visible;\npart")
        let projection = try NativeDecompilerDocumentProjector.project(
            document: document,
            tokens: [
                token("token.return", "return", .keyword, line: 1, column: 1),
                token("token.omitted", "future", .identifier, line: 3, column: 1),
            ],
            isCancelled: { false }
        )

        XCTAssertEqual(projection.mappingState, .verified)
        XCTAssertEqual(projection.tokenRuns.map(\.tokenID), ["token.return"])
        XCTAssertEqual(projection.text, document.text)
    }

    func testTruncatedDocumentOmitsBoundaryCrossingToken() throws {
        let document = truncatedDocument("return val")
        let projection = try NativeDecompilerDocumentProjector.project(
            document: document,
            tokens: [
                token("token.return", "return", .keyword, line: 1, column: 1),
                token("token.boundary", "value", .identifier, line: 1, column: 8),
            ],
            isCancelled: { false }
        )

        XCTAssertEqual(projection.mappingState, .verified)
        XCTAssertEqual(projection.tokenRuns.map(\.tokenID), ["token.return"])
        XCTAssertEqual(projection.text, document.text)
    }

    func testTruncatedDocumentStillDegradesForWhollyVisibleMismatch() throws {
        try assertDegraded(
            document: truncatedDocument("return val"),
            tokens: [token("token.bad", "retXrn", .keyword, line: 1, column: 1)],
            reason: .visibleTextMismatch
        )
    }

    func testEveryOutcomePreservesByteIdenticalBaseDocument() throws {
        let text = "e\u{301}\t🧭\n"
        let verifiedDocument = completeDocument(text)
        let degradedDocument = completeDocument(text)
        let truncated = truncatedDocument(text)

        let verified = try NativeDecompilerDocumentProjector.project(
            document: verifiedDocument,
            tokens: [token("token.combining", "e\u{301}", .literal, line: 1, column: 1)],
            isCancelled: { false }
        )
        let degraded = try NativeDecompilerDocumentProjector.project(
            document: degradedDocument,
            tokens: [token("token.bad", "x", .literal, line: 1, column: 1)],
            isCancelled: { false }
        )
        let truncatedProjection = try NativeDecompilerDocumentProjector.project(
            document: truncated,
            tokens: [token("token.future", "future", .identifier, line: 3, column: 1)],
            isCancelled: { false }
        )

        XCTAssertEqual(Array(verified.text.utf8), Array(text.utf8))
        XCTAssertEqual(Array(degraded.text.utf8), Array(text.utf8))
        XCTAssertEqual(Array(truncatedProjection.text.utf8), Array(text.utf8))
    }

    func testCancellationStopsBoundedProjection() throws {
        let document = completeDocument("alpha beta gamma\n")
        let cancellation = CancellationProbe(cancelOnPoll: 4)

        XCTAssertThrowsError(try NativeDecompilerDocumentProjector.project(
            document: document,
            tokens: [
                token("token.alpha", "alpha", .identifier, line: 1, column: 1),
                token("token.beta", "beta", .identifier, line: 1, column: 7),
                token("token.gamma", "gamma", .identifier, line: 1, column: 12),
            ],
            isCancelled: { cancellation.poll() }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellation.pollCount, 4)
    }

    func testCancellationWinsBeforeDegradedProjectionPublication() throws {
        let cancellation = CancellationProbe(cancelOnPoll: 4)

        XCTAssertThrowsError(try NativeDecompilerDocumentProjector.project(
            document: completeDocument("alpha\n"),
            tokens: [token("token.bad", "alpHa", .identifier, line: 1, column: 1)],
            isCancelled: { cancellation.poll() }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellation.pollCount, 4)
    }

    private func completeDocument(_ text: String) -> NativeDecompilerWirePseudocodeDocument {
        NativeDecompilerWirePseudocodeDocument(
            text: text, language: "c", isComplete: true, isTruncated: false
        )
    }

    private func truncatedDocument(_ text: String) -> NativeDecompilerWirePseudocodeDocument {
        NativeDecompilerWirePseudocodeDocument(
            text: text, language: "c", isComplete: false, isTruncated: true
        )
    }

    private func assertDegraded(
        document: NativeDecompilerWirePseudocodeDocument,
        tokens: [NativeDecompilerWirePseudocodeTokenRecord],
        reason: NativeDecompilerDocumentMappingDegradation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let projection = try NativeDecompilerDocumentProjector.project(
            document: document,
            tokens: tokens,
            isCancelled: { false }
        )
        XCTAssertEqual(projection.text, document.text, file: file, line: line)
        XCTAssertEqual(projection.isComplete, document.isComplete, file: file, line: line)
        XCTAssertEqual(projection.isTruncated, document.isTruncated, file: file, line: line)
        XCTAssertEqual(projection.mappingState, .degraded(reason), file: file, line: line)
        XCTAssertTrue(projection.tokenRuns.isEmpty, file: file, line: line)
    }

    private func token(
        _ id: String,
        _ text: String,
        _ kind: NativeDecompilerWireTokenKind,
        line: UInt32,
        column: UInt32,
        sourceRanges: [NativeDecompilerWireSourceRange] = [],
        entityReferences: [NativeDecompilerWireTokenEntityReference] = []
    ) -> NativeDecompilerWirePseudocodeTokenRecord {
        NativeDecompilerWirePseudocodeTokenRecord(
            id: id,
            text: text,
            kind: kind,
            line: line,
            column: column,
            sourceRanges: sourceRanges,
            entityReferences: entityReferences
        )
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelOnPoll: Int
    private var count = 0

    init(cancelOnPoll: Int) {
        self.cancelOnPoll = cancelOnPoll
    }

    var pollCount: Int {
        lock.withLock { count }
    }

    func poll() -> Bool {
        lock.withLock {
            count += 1
            return count == cancelOnPoll
        }
    }
}
