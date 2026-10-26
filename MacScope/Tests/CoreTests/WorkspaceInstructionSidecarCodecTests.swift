import Foundation
import XCTest
@testable import MacScope

final class WorkspaceInstructionSidecarCodecTests: XCTestCase {
    private typealias Codec = WorkspaceInstructionSidecarCodec
    private typealias Descriptor = WorkspaceInstructionSidecarGroupDescriptor

    func testWireFormatUsesSpecifiedLittleEndianLayout() throws {
        let group = legacy([row(address: 0x0102_0304_0506_0708, breakpoint: true)])
        let data = try Codec.encode([group])
        let expected: [UInt8] = [
            0x4D, 0x53, 0x49, 0x4E, 0x53, 0x54, 1, 0, // Magic, version 1.
            1, 0, 0, 0, // One group.
            0, // Legacy owner.
            1, 0, 0, 0, 0, 0, 0, 0, // One row.
            8, 7, 6, 5, 4, 3, 2, 1, // Address.
            1, // Breakpoint.
            0, 0, 0, 0, // Empty bytes.
            0, 0, 0, 0, // Empty mnemonic.
            0, 0, 0, 0, // Empty operands.
            255, 255, 255, 255, // Nil comment.
        ]
        XCTAssertEqual(Array(data), expected)
        let decoded = try Codec.decode(Data(expected), groups: descriptors([group]))
        XCTAssertEqual(decoded[0].instructions, group.instructions)
    }

    func testRoundTripPreservesOrderUnicodeAndNilVersusEmptyComments() throws {
        let group = legacy([
            InstructionRow(
                address: UInt64.max,
                bytes: "00  0A\tff",
                mnemonic: "λdr",
                operands: "x0, [x1, #−16]\n\0",
                hasBreakpoint: true,
                comment: "e\u{301} and é 🧬"
            ),
            row(address: 4, comment: ""),
            row(address: 0, comment: nil),
        ])
        let data = try Codec.encode([group])
        let decoded = try Codec.decode(data, groups: descriptors([group]))
        XCTAssertEqual(decoded[0].instructions, group.instructions)
        XCTAssertEqual(decoded[0].instructions[1].comment, "")
        XCTAssertNil(decoded[0].instructions[2].comment)
        for (actual, original) in zip(decoded[0].instructions, group.instructions) {
            XCTAssertEqual(Array(actual.bytes.utf8), Array(original.bytes.utf8))
            XCTAssertEqual(Array(actual.mnemonic.utf8), Array(original.mnemonic.utf8))
            XCTAssertEqual(Array(actual.operands.utf8), Array(original.operands.utf8))
            XCTAssertEqual(actual.comment.map { Array($0.utf8) }, original.comment.map { Array($0.utf8) })
        }
        XCTAssertEqual(try Codec.encode(decoded), data)
    }

    func testMultipleImagesPermitSameAddressAndPreserveOwnerBytes() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let secondID = try XCTUnwrap(UUID(uuidString: "FFEEDDCC-BBAA-9988-7766-554433221100"))
        let groups = [
            Codec.Group(binaryID: firstID, imageSlot: .primary, instructions: [row(address: 4)]),
            Codec.Group(binaryID: secondID, imageSlot: ImageSlot(rawValue: 0x0102), instructions: [row(address: 4)]),
        ]
        let data = try Codec.encode(groups)
        XCTAssertEqual(Array(data[13..<29]), [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        ])
        let decoded = try Codec.decode(data, groups: descriptors(groups))
        XCTAssertEqual(decoded.map(\.binaryID), groups.map(\.binaryID))
        XCTAssertEqual(decoded.map(\.imageSlot), groups.map(\.imageSlot))
        XCTAssertEqual(decoded.map(\.instructions), groups.map(\.instructions))
    }

    func testEmptySidecarAndEmptyLegacyGroupRoundTrip() throws {
        let empty = try Codec.encode([])
        XCTAssertEqual(empty.count, 12)
        XCTAssertTrue(try Codec.decode(empty, groups: []).isEmpty)
        let group = legacy([])
        let decoded = try Codec.decode(Codec.encode([group]), groups: descriptors([group]))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].binaryID)
        XCTAssertNil(decoded[0].imageSlot)
        XCTAssertTrue(decoded[0].instructions.isEmpty)
    }

    func testEncodingRejectsDuplicateAddressesWithinOneImage() {
        let group = legacy([row(address: 8), row(address: 8, comment: "different row")])
        XCTAssertThrowsError(try Codec.encode([group])) { error in
            XCTAssertEqual(error as? Codec.Failure, .duplicateAddress(8))
        }
    }

    func testEncodingRejectsDuplicateOrIncompleteOwners() throws {
        let firstID = UUID()
        let secondID = UUID()
        let primary = Codec.Group(binaryID: firstID, imageSlot: .primary, instructions: [])
        let duplicates = [
            [legacy([]), legacy([])],
            [primary, Codec.Group(binaryID: firstID, imageSlot: ImageSlot(rawValue: 1), instructions: [])],
            [primary, Codec.Group(binaryID: secondID, imageSlot: .primary, instructions: [])],
        ]
        for groups in duplicates {
            XCTAssertThrowsError(try Codec.encode(groups)) { error in
                XCTAssertEqual(error as? Codec.Failure, .duplicateOwner)
            }
        }
        let invalid = [
            Codec.Group(binaryID: firstID, imageSlot: nil, instructions: []),
            Codec.Group(binaryID: nil, imageSlot: .primary, instructions: []),
            Codec.Group(binaryID: firstID, imageSlot: ImageSlot(rawValue: -1), instructions: []),
        ]
        for group in invalid {
            XCTAssertThrowsError(try Codec.encode([group])) { error in
                XCTAssertEqual(error as? Codec.Failure, .invalidOwner)
            }
        }
    }

    func testDecodingChecksEveryOwnerAndRowCountAgainstManifest() throws {
        let group = Codec.Group(binaryID: UUID(), imageSlot: .primary, instructions: [row(address: 0)])
        let data = try Codec.encode([group])
        assertFailure(.groupCountMismatch, data: data, descriptors: [])
        var expected = descriptors([group])
        expected[0].binaryID = UUID()
        assertFailure(.ownerMismatch, data: data, descriptors: expected)
        expected = descriptors([group])
        expected[0].imageSlot = ImageSlot(rawValue: 1)
        assertFailure(.ownerMismatch, data: data, descriptors: expected)
        expected = descriptors([group])
        expected[0].rowCount = 2
        assertFailure(.rowCountMismatch, data: data, descriptors: expected)
        expected = descriptors([group])
        expected[0].binaryID = nil
        assertFailure(.invalidOwner, data: data, descriptors: expected)
    }

    func testDecodingRejectsRepeatedOwnersInBytesAndManifest() throws {
        let groups = [
            Codec.Group(binaryID: UUID(), imageSlot: .primary, instructions: []),
            Codec.Group(binaryID: UUID(), imageSlot: ImageSlot(rawValue: 1), instructions: []),
        ]
        let data = try Codec.encode(groups)
        var repeated = data
        repeated.replaceSubrange(46..<70, with: data[13..<37])
        assertFailure(.duplicateOwner, data: repeated, descriptors: descriptors(groups))
        let descriptor = descriptors(groups)[0]
        assertFailure(.duplicateOwner, data: data, descriptors: [descriptor, descriptor])
    }

    func testDecodingRejectsDuplicateInstructionAddress() throws {
        let group = legacy([row(address: 1), row(address: 2)])
        var data = try Codec.encode([group])
        let firstAddress = Array(data[21..<29])
        data.replaceSubrange(46..<54, with: firstAddress)
        assertFailure(.duplicateAddress(1), data: data, descriptors: descriptors([group]))
    }

    func testTruncationAtEveryBoundaryIsRejected() throws {
        let group = legacy([InstructionRow(
            address: 0,
            bytes: "01",
            mnemonic: "ret",
            operands: "x30",
            hasBreakpoint: false,
            comment: "return"
        )])
        let data = try Codec.encode([group])
        for count in 0..<data.count {
            XCTAssertThrowsError(try Codec.decode(Data(data.prefix(count)), groups: descriptors([group])), "prefix \(count)")
        }
    }

    func testUnknownVersionOwnerAndBreakpointFlagsAreRejected() throws {
        let group = legacy([row(address: 0)])
        let valid = try Codec.encode([group])
        for (offset, value, failure) in [
            (0, UInt8(0), Codec.Failure.invalidHeader),
            (6, UInt8(2), .invalidHeader),
            (12, UInt8(2), .invalidOwner),
            (29, UInt8(2), .invalidBreakpointFlag),
        ] {
            var data = valid
            data[offset] = value
            assertFailure(failure, data: data, descriptors: descriptors([group]))
        }
    }

    func testUTF8AndStringLengthsAreValidatedWithoutReplacement() throws {
        let group = legacy([InstructionRow(
            address: 0, bytes: "a", mnemonic: "", operands: "", hasBreakpoint: false, comment: nil
        )])
        let valid = try Codec.encode([group])
        var data = valid
        data[34] = 0xFF
        assertFailure(.invalidUTF8, data: data, descriptors: descriptors([group]))
        data = valid
        data.replaceSubrange(30..<34, with: [255, 255, 255, 255])
        assertFailure(.invalidStringLength, data: data, descriptors: descriptors([group]))
        data = valid
        data.replaceSubrange(30..<34, with: [254, 255, 255, 255])
        assertFailure(.truncated, data: data, descriptors: descriptors([group]))
    }

    func testOverflowingCountsAndSlotsFailBeforeAllocatingRows() throws {
        let group = legacy([])
        var data = try Codec.encode([group])
        data.replaceSubrange(13..<21, with: repeatElement(UInt8.max, count: 8))
        assertFailure(.rowCountMismatch, data: data, descriptors: [
            Descriptor(binaryID: nil, imageSlot: nil, rowCount: UInt64.max),
        ])
        let image = Codec.Group(binaryID: UUID(), imageSlot: .primary, instructions: [])
        data = try Codec.encode([image])
        data.replaceSubrange(29..<37, with: repeatElement(UInt8.max, count: 8))
        assertFailure(.invalidOwner, data: data, descriptors: descriptors([image]))
    }

    func testTrailingBytesAndReorderedDescriptorsAreRejected() throws {
        let groups = [
            Codec.Group(binaryID: UUID(), imageSlot: .primary, instructions: []),
            Codec.Group(binaryID: UUID(), imageSlot: ImageSlot(rawValue: 1), instructions: []),
        ]
        let data = try Codec.encode(groups)
        var trailing = data
        trailing.append(0)
        assertFailure(.trailingBytes, data: trailing, descriptors: descriptors(groups))
        assertFailure(.ownerMismatch, data: data, descriptors: Array(descriptors(groups).reversed()))
    }

    func testLargeCommentAndNonzeroDataStartIndexRoundTrip() throws {
        let group = legacy([row(address: 0, comment: String(repeating: "é", count: 40_000))])
        let data = try Codec.encode([group])
        var wrapped = Data([1, 2, 3])
        wrapped.append(data)
        let decoded = try Codec.decode(wrapped.dropFirst(3), groups: descriptors([group]))
        XCTAssertEqual(decoded[0].instructions, group.instructions)
    }

    func testCancelledOperationsThrowCancellationError() async throws {
        let data = try Codec.encode([])
        let result = await Task.detached { () -> [Bool] in
            withUnsafeCurrentTask { $0?.cancel() }
            var cancelled: [Bool] = []
            do {
                _ = try Codec.encode([])
                cancelled.append(false)
            } catch {
                cancelled.append(error is CancellationError)
            }
            do {
                _ = try Codec.decode(data, groups: [])
                cancelled.append(false)
            } catch {
                cancelled.append(error is CancellationError)
            }
            return cancelled
        }.value
        XCTAssertEqual(result, [true, true])
    }

    private func row(address: UInt64, breakpoint: Bool = false, comment: String? = nil) -> InstructionRow {
        InstructionRow(address: address, bytes: "", mnemonic: "", operands: "", hasBreakpoint: breakpoint, comment: comment)
    }

    private func legacy(_ instructions: [InstructionRow]) -> Codec.Group {
        Codec.Group(binaryID: nil, imageSlot: nil, instructions: instructions)
    }

    private func descriptors(_ groups: [Codec.Group]) -> [Descriptor] {
        groups.map { Descriptor(binaryID: $0.binaryID, imageSlot: $0.imageSlot, rowCount: UInt64($0.instructions.count)) }
    }

    private func assertFailure(
        _ failure: Codec.Failure,
        data: Data,
        descriptors: [Descriptor],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try Codec.decode(data, groups: descriptors), file: file, line: line) { error in
            XCTAssertEqual(error as? Codec.Failure, failure, file: file, line: line)
        }
    }
}
