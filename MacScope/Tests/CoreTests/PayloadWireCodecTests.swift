import Foundation
import XCTest
@testable import MacScope

/// Band-2 integration: the CONCRETE `PayloadWireCodec` that unifies P1's payload codec with the
/// P2/P3 wire seams. P2 and P3 were each tested only against their own doubles; this pins the real
/// codec that carries requests and replies across the (future) XPC boundary — request round-trip,
/// success replies via P1's payload, and each worker-failure kind mapping back to the right client
/// error (the reconciliation the two drafts could not test in isolation).
final class PayloadWireCodecTests: XCTestCase {

    private let codec = PayloadWireCodec()

    // MARK: - Request round-trip (client encode → worker decode)

    func testRequestRoundTripsAllFields() throws {
        let requestID = UUID()
        let overrides: [UInt64: AddressOverride] = [
            0x1000: AddressOverride(customName: "start"),
            UInt64.max: AddressOverride(customName: "top"),
        ]
        let data = codec.encodeRequest(
            url: URL(fileURLWithPath: "/tmp/some binary"),
            requestedSliceIndex: 3,
            overrides: overrides,
            requestID: requestID
        )
        let decoded = try codec.decodeRequest(data)

        XCTAssertEqual(decoded.url.path, "/tmp/some binary")
        XCTAssertEqual(decoded.requestedSliceIndex, 3)
        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.overrides, overrides)
    }

    func testDecodeRequestRejectsGarbage() {
        XCTAssertThrowsError(try codec.decodeRequest(Data("not a request".utf8)))
    }

    // MARK: - Success reply (worker encode → client decode via P1 payload)

    func testSuccessReplyRoundTripsThroughThePayload() throws {
        let snapshot = Self.snapshotFixture()
        let data = codec.encodeReply(.success(snapshot))
        let decoded = try codec.decodeReply(data)

        // Round-trips through P1's AnalysisResultPayload → derived fields survive, authoring is dropped.
        XCTAssertEqual(decoded.binaries.map(\.name), snapshot.binaries.map(\.name))
        XCTAssertEqual(decoded.instructions.first?.mnemonic, "ret")
        XCTAssertEqual(decoded.hexBytes, snapshot.hexBytes)
        XCTAssertEqual(decoded.jumpTables, snapshot.jumpTables)
    }

    // MARK: - Failure replies map back to faithful client errors

    func testCancelledReplyDecodesToAnalysisCancelled() {
        let data = codec.encodeReply(.failure(AnalysisWorkerServiceError.cancelled))
        XCTAssertThrowsError(try codec.decodeReply(data)) { error in
            XCTAssertTrue(error is AnalysisCancelled, "cancelled reply must decode to the benign marker, got \(error)")
        }
    }

    func testAnalysisFailedReplyDecodesToRemoteAnalysisFailureWithMessage() {
        let data = codec.encodeReply(.failure(AnalysisWorkerServiceError.analysisFailed("no __text section")))
        XCTAssertThrowsError(try codec.decodeReply(data)) { error in
            guard let failure = error as? RemoteAnalysisFailure else {
                return XCTFail("expected RemoteAnalysisFailure, got \(error)")
            }
            XCTAssertEqual(failure.message, "no __text section")
        }
    }

    func testMalformedRequestReplyDecodesToRemoteAnalysisFailure() {
        let data = codec.encodeReply(.failure(AnalysisWorkerServiceError.malformedRequest))
        XCTAssertThrowsError(try codec.decodeReply(data)) { error in
            XCTAssertTrue(error is RemoteAnalysisFailure, "got \(error)")
        }
    }

    func testUnexpectedWorkerErrorDecodesToRemoteAnalysisFailure() {
        struct Boom: Error {}
        let data = codec.encodeReply(.failure(Boom()))
        XCTAssertThrowsError(try codec.decodeReply(data)) { error in
            XCTAssertTrue(error is RemoteAnalysisFailure, "an unknown worker error still surfaces a message, got \(error)")
        }
    }

    func testMalformedReplyBytesThrowADecodeError() {
        // A structurally corrupt reply is neither cancelled nor a RemoteAnalysisFailure — the
        // provider maps this to `.malformedReply`.
        XCTAssertThrowsError(try codec.decodeReply(Data("garbage".utf8))) { error in
            XCTAssertFalse(error is AnalysisCancelled)
            XCTAssertFalse(error is RemoteAnalysisFailure)
        }
    }

    // MARK: - PERF-C2 pinned image-bytes range

    func testPinnedRangeReplyOmitsBytesAndIsReadBackFromTheClientSourceWithHashCheck() throws {
        let prefix = Data(repeating: 0xEE, count: 37)
        let image = Data((0..<5_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        var snapshot = Self.snapshotFixture()
        snapshot.imageBytes = image
        let source = try Self.handle(on: prefix + image + Data([1, 2, 3]))
        let range = AnalysisPinnedImageByteRange(
            offset: UInt64(prefix.count), byteCount: image.count, sha256: AnalysisPinnedImageBytes.sha256Hex(image)
        )

        let inline = codec.encodeReply(.success(snapshot))
        let pinned = codec.encodeReply(.success(snapshot), pinnedImageBytes: range)
        XCTAssertLessThan(pinned.count + image.count, inline.count, "the pinned reply carries no image bytes")
        XCTAssertEqual(try codec.decodeReply(inline).imageBytes, image)
        XCTAssertEqual(try codec.decodeReply(pinned, pinnedSource: source).imageBytes, image)

        // Without the pinned source the reply cannot be completed: typed, never silently empty.
        XCTAssertThrowsError(try codec.decodeReply(pinned)) {
            XCTAssertEqual($0 as? AnalysisPinnedImageBytesError, .pinnedSourceMissing)
        }
        // The source changed under the same size: the hash check refuses it.
        var changed = prefix + image + Data([1, 2, 3])
        changed[prefix.count + 100] ^= 0xFF
        XCTAssertThrowsError(try codec.decodeReply(pinned, pinnedSource: try Self.handle(on: changed))) {
            XCTAssertEqual($0 as? AnalysisPinnedImageBytesError, .hashMismatch)
        }
        // A range past the end of the source is unreadable.
        XCTAssertThrowsError(try codec.decodeReply(pinned, pinnedSource: try Self.handle(on: prefix))) {
            XCTAssertEqual($0 as? AnalysisPinnedImageBytesError, .unreadable)
        }
        // A range whose length disagrees with the snapshot is ignored: the bytes stay inline.
        var wrongCount = range
        wrongCount.byteCount += 1
        XCTAssertEqual(try codec.decodeReply(codec.encodeReply(.success(snapshot), pinnedImageBytes: wrongCount)).imageBytes,
                       image)
    }

    private static func handle(on bytes: Data) throws -> FileHandle {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-c2-codec-\(UUID().uuidString)")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try FileHandle(forReadingFrom: url)
    }

    // MARK: - Fixture

    private static func snapshotFixture() -> WorkspaceSnapshot {
        let image = BinaryImage(id: UUID(), name: "fixture", path: "/tmp/fixture", kind: "Mach-O", architecture: "arm64")
        let row = InstructionRow(address: 0x1000, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
                                 hasBreakpoint: false, comment: nil)
        var snapshot = WorkspaceSnapshot(
            binaries: [image], functions: [], instructions: [row], xrefs: [],
            hexBytes: Data([0xc0, 0x03, 0x5f, 0xd6])
        )
        snapshot.jumpTables = [0x2000: [0x2100, 0x2200]]
        // Authoring the payload must DROP (so the decoded snapshot has it back to empty).
        snapshot.addressOverrides = [ImageAddress(slot: .primary, address: 0x1000): AddressOverride(customName: "x")]
        return snapshot
    }
}
