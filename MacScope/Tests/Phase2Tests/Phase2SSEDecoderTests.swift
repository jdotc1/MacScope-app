import XCTest

@testable import MacScope

final class Phase2SSEDecoderTests: XCTestCase {
    func testEverySplitPointPreservesUTF8AndCRLFFraming() throws {
        let input = Data("event: delta\r\ndata: café 🚀\r\nid: turn-1\r\nretry: 250\r\n\r\n".utf8)
        let expected = Phase2SSERecord(
            event: "delta",
            data: "café 🚀",
            id: "turn-1",
            retryMilliseconds: 250
        )

        for split in 0...input.count {
            var decoder = Phase2SSEDecoder()
            var records = try decoder.append(input.prefix(split))
            records += try decoder.append(input.dropFirst(split))
            XCTAssertEqual(records, [expected], "split at byte \(split)")
            XCTAssertEqual(try decoder.finish(), [])
        }
    }

    func testConfiguredDefaultEventDecodesDataOnlyRecordAtEverySplitPoint() throws {
        let input = Data("data: hello\n\n".utf8)
        let expected = Phase2SSERecord(event: "message", data: "hello")

        for split in 0...input.count {
            var decoder = Phase2SSEDecoder(defaultEvent: "message")
            var records = try decoder.append(input.prefix(split))
            records += try decoder.append(input.dropFirst(split))
            XCTAssertEqual(records, [expected], "split at byte \(split)")
            XCTAssertEqual(try decoder.finish(), [])
        }
    }

    func testExplicitEventOverridesConfiguredDefaultEvent() throws {
        var decoder = Phase2SSEDecoder(defaultEvent: "message")

        XCTAssertEqual(
            try decoder.append(Data("event: completion\ndata: hello\n\n".utf8)),
            [.init(event: "completion", data: "hello")]
        )
    }

    func testOneByteChunksHandleCommentsRepeatedDataAndLF() throws {
        let input = Data(": heartbeat\nevent: message\ndata: first\ndata: second\nid: 42\nretry: 7\n\n".utf8)
        var decoder = Phase2SSEDecoder()
        var records: [Phase2SSERecord] = []

        for byte in input {
            records += try decoder.append(Data([byte]))
        }

        XCTAssertEqual(
            records,
            [.init(event: "message", data: "first\nsecond", id: "42", retryMilliseconds: 7)]
        )
        XCTAssertEqual(try decoder.finish(), [])
    }

    func testMultipleRecordsCanCompleteInOneChunk() throws {
        var decoder = Phase2SSEDecoder()
        let records = try decoder.append(
            Data("event: a\ndata: one\n\nevent: b\ndata: two\n\n".utf8)
        )

        XCTAssertEqual(
            records,
            [
                .init(event: "a", data: "one"),
                .init(event: "b", data: "two")
            ]
        )
    }

    func testCommentsAloneAreHeartbeatRecordsAndEmitNothing() throws {
        var decoder = Phase2SSEDecoder()
        XCTAssertEqual(try decoder.append(Data(": one\r\n:two\r\n\r\n".utf8)), [])
        XCTAssertEqual(try decoder.finish(), [])
    }

    func testMalformedAndUnsupportedFieldsFailClosed() throws {
        try assertError("event delta\n\n", equals: .malformedField)
        try assertError("unknown: value\n\n", equals: .unsupportedField("unknown"))
        try assertError("event: one\nevent: two\ndata: x\n\n", equals: .duplicateField("event"))
        try assertError("event: x\nid: one\nid: two\ndata: x\n\n", equals: .duplicateField("id"))
        try assertError("event: x\nretry: nope\ndata: x\n\n", equals: .invalidRetry)
        try assertError("event: x\rdata: y\n\n", equals: .invalidLineEnding)
    }

    func testRecordSchemaRequiresNonemptyEventAndData() throws {
        try assertError("data: x\n\n", equals: .missingEvent)
        try assertError("event: x\n\n", equals: .missingData)
        try assertError("event:\ndata: x\n\n", equals: .emptyEvent)
        try assertError("event: x\ndata:\n\n", equals: .emptyData)
    }

    func testInvalidUTF8FailsBeforeRecordDecoding() throws {
        var decoder = Phase2SSEDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0x65, 0x76, 0x65, 0x6e, 0x74, 0x3a, 0x20, 0xff, 0x0a]))) {
            XCTAssertEqual($0 as? Phase2SSEDecoderError, .invalidUTF8)
        }
    }

    func testFinishRejectsIncompleteLineAndRecordAndCannotBeReused() throws {
        var partialScalar = Phase2SSEDecoder()
        _ = try partialScalar.append(Data([0xf0, 0x9f]))
        XCTAssertThrowsError(try partialScalar.finish()) {
            XCTAssertEqual($0 as? Phase2SSEDecoderError, .invalidUTF8)
        }

        var partialLine = Phase2SSEDecoder()
        _ = try partialLine.append(Data("event: x".utf8))
        XCTAssertThrowsError(try partialLine.finish()) {
            XCTAssertEqual($0 as? Phase2SSEDecoderError, .incompleteLine)
        }

        var partialRecord = Phase2SSEDecoder()
        _ = try partialRecord.append(Data("event: x\ndata: y\n".utf8))
        XCTAssertThrowsError(try partialRecord.finish()) {
            XCTAssertEqual($0 as? Phase2SSEDecoderError, .incompleteRecord)
        }

        var complete = Phase2SSEDecoder()
        XCTAssertEqual(try complete.finish(), [])
        XCTAssertThrowsError(try complete.append(Data())) {
            XCTAssertEqual($0 as? Phase2SSEDecoderError, .alreadyFinished)
        }
    }

    func testPendingLineRecordAndCumulativeByteLimitsAcceptMaximumRejectMaximumPlusOne() throws {
        var pendingAtMaximum = Phase2SSEDecoder(limits: .init(
            maximumPendingBytes: 3,
            maximumLineBytes: 100,
            maximumRecordBytes: 100,
            maximumCumulativeBytes: 100,
            maximumRecordCount: 10
        ))
        _ = try pendingAtMaximum.append(Data("abc".utf8))
        var pendingOver = pendingAtMaximum
        XCTAssertThrowsError(try pendingOver.append(Data("d".utf8))) {
            XCTAssertEqual($0 as? Phase2SSEDecoderError, .pendingByteLimitExceeded)
        }

        try assertLimit(
            exact: "event: a\ndata: b\n\n",
            over: "event: aa\ndata: b\n\n",
            limits: .init(maximumPendingBytes: 100, maximumLineBytes: 8, maximumRecordBytes: 100, maximumCumulativeBytes: 100, maximumRecordCount: 10),
            error: .lineByteLimitExceeded
        )
        try assertLimit(
            exact: "event: a\ndata: b\n\n",
            over: "event: a\ndata: bb\n\n",
            limits: .init(maximumPendingBytes: 100, maximumLineBytes: 100, maximumRecordBytes: 18, maximumCumulativeBytes: 100, maximumRecordCount: 10),
            error: .recordByteLimitExceeded
        )
        try assertLimit(
            exact: "event: a\r\ndata: b\r\n\r\n",
            over: "event: a\r\ndata: bb\r\n\r\n",
            limits: .init(maximumPendingBytes: 100, maximumLineBytes: 100, maximumRecordBytes: 21, maximumCumulativeBytes: 100, maximumRecordCount: 10),
            error: .recordByteLimitExceeded
        )

        var cumulativeAtMaximum = Phase2SSEDecoder(limits: .init(
            maximumPendingBytes: 100,
            maximumLineBytes: 100,
            maximumRecordBytes: 100,
            maximumCumulativeBytes: 4,
            maximumRecordCount: 10
        ))
        _ = try cumulativeAtMaximum.append(Data("1234".utf8))
        var cumulativeOver = cumulativeAtMaximum
        XCTAssertThrowsError(try cumulativeOver.append(Data("5".utf8))) {
            XCTAssertEqual($0 as? Phase2SSEDecoderError, .cumulativeByteLimitExceeded)
        }

        var oversizedSingleChunk = Phase2SSEDecoder(limits: .init(
            maximumPendingBytes: 100,
            maximumLineBytes: 100,
            maximumRecordBytes: 100,
            maximumCumulativeBytes: 4,
            maximumRecordCount: 10
        ))
        XCTAssertThrowsError(try oversizedSingleChunk.append(Data(repeating: 0x61, count: 5))) {
            XCTAssertEqual($0 as? Phase2SSEDecoderError, .cumulativeByteLimitExceeded)
        }
    }

    func testRecordCountAcceptsMaximumRejectsMaximumPlusOne() throws {
        let one = "event: a\ndata: b\n\n"
        var atMaximum = Phase2SSEDecoder(limits: .init(maximumRecordCount: 1))
        XCTAssertEqual(try atMaximum.append(Data(one.utf8)).count, 1)

        var over = Phase2SSEDecoder(limits: .init(maximumRecordCount: 1))
        XCTAssertThrowsError(try over.append(Data((one + one).utf8))) {
            XCTAssertEqual($0 as? Phase2SSEDecoderError, .recordCountLimitExceeded)
        }
    }

    private func assertError(
        _ input: String,
        equals expected: Phase2SSEDecoderError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var decoder = Phase2SSEDecoder()
        XCTAssertThrowsError(try decoder.append(Data(input.utf8)), file: file, line: line) {
            XCTAssertEqual($0 as? Phase2SSEDecoderError, expected, file: file, line: line)
        }
    }

    private func assertLimit(
        exact: String,
        over: String,
        limits: Phase2SSEDecoderLimits,
        error: Phase2SSEDecoderError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var exactDecoder = Phase2SSEDecoder(limits: limits)
        XCTAssertEqual(try exactDecoder.append(Data(exact.utf8)).count, 1, file: file, line: line)

        var overDecoder = Phase2SSEDecoder(limits: limits)
        XCTAssertThrowsError(try overDecoder.append(Data(over.utf8)), file: file, line: line) {
            XCTAssertEqual($0 as? Phase2SSEDecoderError, error, file: file, line: line)
        }
    }
}
