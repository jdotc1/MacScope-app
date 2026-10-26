import Foundation
import XCTest
@testable import MacScope

/// MS-18: package rehydrate runs the format loaders in the analysis worker. These cases drive the
/// real client bridge (`XPCAnalysisProvider`) through a loopback transport into the real worker
/// handler (`AnalysisWorkerService.handleRehydrate`), so the wire codec, the worker's engine and
/// the client's error mapping are all exercised; only the NSXPC hop is replaced.
final class WorkerRehydrateTests: XCTestCase {
    // MARK: Identical restore

    func testMachORehydrateInWorkerMatchesInProcessRestore() throws {
        let url = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw XCTSkip("/bin/ls not readable") }
        try assertIdenticalRestore(fresh: AnalysisEngine().analyze(
            url: url, requestedSliceIndex: nil, overrides: [:], cancellation: .never
        ), expectSections: true)
    }

    func testPERehydrateInWorkerMatchesInProcessRestore() throws {
        try assertIdenticalRestore(fresh: analyzeFixture(Self.importPE(count: 3, name: "printf"), name: "ordinary.exe"),
                                   expectSections: true)
    }

    func testELFRehydrateInWorkerMatchesInProcessRestore() throws {
        try assertIdenticalRestore(fresh: analyzeFixture(Self.miniELF(), name: "prog.elf"), expectSections: true)
    }

    func testRehydrateUsesCapturedBytesWithoutCreatingALoaderFile() throws {
        let bytes = Self.importPE(count: 2, name: "puts")
        let engine = AnalysisEngine(loader: CapturedOnlyRehydrateLoader())
        let service = AnalysisWorkerService(engine: engine, codec: PayloadWireCodec())
        let codec = AnalysisRehydrateWireCodec()
        let source = try AnalysisSealedByteDescriptor.make(bytes)
        defer { try? source.close() }
        let requestID = UUID()
        let persisted = ImageAnalysis(imageBytes: bytes)
        let payload = try codec.encodeRequest(AnalysisRehydrateRequest(
            imageBytes: bytes, requestedSliceIndex: nil,
            persisted: persisted, overrides: [:], requestID: requestID
        ), imageBytesOnDescriptor: true)
        let reply = service.handleRehydrate(requestData: payload, requestID: requestID, imageSource: source)
        let loader = try codec.decodeLoaderReply(reply, requestID: requestID,
            requestImageByteCount: bytes.count, requestedSliceIndex: nil)
        let restored = try RehydrationDerivedProducts.rebuild(persisted: persisted, loader: loader,
            imageBytes: bytes, cancellation: .never)
        XCTAssertEqual(restored.imageBytes, bytes)
        XCTAssertFalse(restored.sections.isEmpty)
    }

    /// Wire v4 sends only loader input and returns only loader products. The caller retains
    /// and recombines its own persisted rows without transmitting them in either direction.
    func testReplyOmitsPreservedProductsAndTheClientRestoresThem() throws {
        let url = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw XCTSkip("/bin/ls not readable") }
        let fresh = try AnalysisEngine().analyze(url: url, requestedSliceIndex: nil, overrides: [:], cancellation: .never)
        var persisted = try XCTUnwrap(fresh.analysis(in: fresh.primarySlot))
        persisted.sections = []
        persisted.machOMetadata = nil
        XCTAssertFalse(persisted.instructions.isEmpty)
        let bytes = persisted.imageBytes

        let codec = AnalysisRehydrateWireCodec()
        let service = AnalysisWorkerService(engine: AnalysisEngine(), codec: PayloadWireCodec())
        let source = try AnalysisSealedByteDescriptor.make(bytes)
        defer { try? source.close() }
        let requestID = UUID()
        let request = try codec.encodeRequest(AnalysisRehydrateRequest(
            imageBytes: bytes, requestedSliceIndex: nil, persisted: persisted, overrides: [:], requestID: requestID
        ), imageBytesOnDescriptor: true)
        let reply = service.handleRehydrate(requestData: request, requestID: requestID, imageSource: source)

        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let wire = try XCTUnwrap(envelope["loader"] as? [String: Any])
        let requestFields = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        for key in ["persisted", "instructions", "xrefs", "functions", "controlFlowEdges", "basicBlocks"] {
            XCTAssertNil(requestFields[key], key)
            XCTAssertNil(wire[key], key)
        }
        let loader = try codec.decodeLoaderReply(reply, requestID: requestID,
            requestImageByteCount: bytes.count, requestedSliceIndex: nil)
        let restored = try RehydrationDerivedProducts.rebuild(persisted: persisted, loader: loader,
            imageBytes: bytes, cancellation: .never)
        XCTAssertEqual(restored.instructions, persisted.instructions)
        XCTAssertEqual(restored.functions, persisted.functions)
        XCTAssertEqual(restored.xrefs, persisted.xrefs)
        XCTAssertEqual(restored.controlFlowEdges, persisted.controlFlowEdges)
        XCTAssertFalse(restored.sections.isEmpty, "the loader-derived products still come back")
        XCTAssertNotNil(restored.machOMetadata)
        XCTAssertThrowsError(try codec.decodeLoaderReply(reply, requestID: UUID(),
            requestImageByteCount: bytes.count, requestedSliceIndex: nil),
            "loader products cannot be accepted under a different request owner")
    }

    func testCapturedLoaderPreservesMachOSliceSelectionAndNeedsNoPath() throws {
        // Two minimal 64-bit Mach-O slices with distinct CPU subtypes.
        func slice(subtype: UInt64) -> Data {
            var bytes = Data(count: 32)
            Self.put(&bytes, 0, 0xFEED_FACF, 4)
            Self.put(&bytes, 4, 0x0100_000C, 4)
            Self.put(&bytes, 8, subtype, 4)
            Self.put(&bytes, 12, 2, 4)
            return bytes
        }
        var bytes = Data(count: 0x2020)
        let header: [UInt32] = [0xCAFE_BABE, 2,
                               0x0100_000C, 0, 0x1000, 32, 12,
                               0x0100_000C, 2, 0x2000, 32, 12]
        bytes.replaceSubrange(0..<(header.count * 4), with: header.flatMap { value in
            (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) }
        })
        bytes.replaceSubrange(0x1000..<0x1020, with: slice(subtype: 0))
        bytes.replaceSubrange(0x2000..<0x2020, with: slice(subtype: 2))
        let nonexistent = URL(fileURLWithPath: "/nonexistent/t10-captured-image")
        let loaded = try XCTUnwrap(BinaryLoaderRouter(requestedMachOSliceIndex: 1)
            .loadCapturedBytes(bytes, sourceURL: nonexistent, cancellation: .never))
        XCTAssertEqual(loaded.sliceOffset, 0x2000)
        XCTAssertEqual(loaded.cpuSubtype, 2)
        XCTAssertEqual(loaded.bytes, bytes)
        XCTAssertEqual(loaded.path, nonexistent.path)
        XCTAssertThrowsError(try BinaryLoaderRouter(requestedMachOSliceIndex: 2)
            .loadCapturedBytes(bytes, sourceURL: nonexistent, cancellation: .never))
    }

    func testCapturedLoaderRefusesMalformedBytesAndHonorsCancellation() throws {
        let router = BinaryLoaderRouter()
        let url = URL(fileURLWithPath: "/nonexistent/t10-captured-image")
        XCTAssertThrowsError(try router.loadCapturedBytes(Data([0x4D, 0x5A]), sourceURL: url,
                                                         cancellation: .never))
        XCTAssertThrowsError(try router.loadCapturedBytes(Self.miniELF(), sourceURL: url,
                                                         cancellation: AnalysisCancellationToken { true })) {
            XCTAssertTrue($0 is AnalysisCancelled)
        }
        XCTAssertNil(try router.loadCapturedBytes(Data("!<arch>\n".utf8), sourceURL: url,
                                                  cancellation: .never))
    }

    // MARK: Hostile input

    func testHostilePEFailsInWorkerWithTypedLoadFailureAndProviderStaysUsable() throws {
        let loopback = LoopbackRehydrateTransport()
        let provider = XPCAnalysisProvider(transport: loopback, codec: PayloadWireCodec())
        // One import name over MS-14's 1 MiB per-string budget.
        let hostile = Self.importPE(count: 1, name: String(repeating: "A", count: 1_048_577))

        XCTAssertThrowsError(try provider.rehydrate(
            imageBytes: hostile, requestedSliceIndex: nil,
            preserving: ImageAnalysis(imageBytes: hostile), cancellation: .never
        )) { error in
            guard let failure = error as? RemoteAnalysisFailure else {
                return XCTFail("expected a typed worker load failure, got \(error)")
            }
            XCTAssertFalse(failure.message.isEmpty)
        }
        XCTAssertEqual(loopback.workerRehydrateCount, 1, "the loader ran in the worker, not in the client")
        XCTAssertEqual(provider.connectionState, .idle)

        let ordinary = Self.importPE(count: 2, name: "puts")
        let restored = try provider.rehydrate(
            imageBytes: ordinary, requestedSliceIndex: nil,
            preserving: ImageAnalysis(imageBytes: ordinary), cancellation: .never
        )
        XCTAssertFalse(restored.sections.isEmpty)
    }

    func testWorkerCrashDuringRehydrateIsTypedAndNextRehydrateSucceeds() throws {
        let loopback = LoopbackRehydrateTransport()
        loopback.crashNext = true
        let provider = XPCAnalysisProvider(transport: loopback, codec: PayloadWireCodec())
        let bytes = Self.importPE(count: 1, name: "puts")

        XCTAssertThrowsError(try provider.rehydrate(
            imageBytes: bytes, requestedSliceIndex: nil,
            preserving: ImageAnalysis(imageBytes: bytes), cancellation: .never
        )) { error in
            guard case AnalysisWorkerError.workerCrashed = error else {
                return XCTFail("expected workerCrashed, got \(error)")
            }
        }
        XCTAssertNoThrow(try provider.rehydrate(
            imageBytes: bytes, requestedSliceIndex: nil,
            preserving: ImageAnalysis(imageBytes: bytes), cancellation: .never
        ))
    }

    func testInvalidatedConnectionRefusesRehydrateUntilReset() throws {
        let provider = XPCAnalysisProvider(transport: MockAnalysisTransport(outcomes: [.invalidate]),
                                           codec: PayloadWireCodec())
        let bytes = Self.importPE(count: 1, name: "puts")
        for _ in 0..<2 {
            XCTAssertThrowsError(try provider.rehydrate(
                imageBytes: bytes, requestedSliceIndex: nil,
                preserving: ImageAnalysis(imageBytes: bytes), cancellation: .never
            )) { error in
                guard case AnalysisWorkerError.workerUnavailable = error else {
                    return XCTFail("expected workerUnavailable, got \(error)")
                }
            }
        }
        XCTAssertEqual(provider.connectionState, .invalidated)
    }

    // MARK: Cancellation

    func testCancelledReopenReturnsPromptlyAndForwardsCancelToWorker() throws {
        let mock = MockAnalysisTransport(outcomes: [.hang])
        let provider = XPCAnalysisProvider(transport: mock, codec: PayloadWireCodec())
        let bytes = Self.importPE(count: 1, name: "puts")
        let flag = CancelFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { flag.set() }

        let started = Date()
        XCTAssertThrowsError(try provider.rehydrate(
            imageBytes: bytes, requestedSliceIndex: nil,
            preserving: ImageAnalysis(imageBytes: bytes),
            cancellation: AnalysisCancellationToken { flag.value }
        )) { error in
            XCTAssertTrue(error is AnalysisCancelled, "got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(mock.calls.count, 1)
        XCTAssertEqual(mock.cancelledRequestIDs, mock.calls.map(\.requestID))
    }

    func testCancellationObservesTheCallingTask() async throws {
        let mock = MockAnalysisTransport(outcomes: [.hang])
        let provider = XPCAnalysisProvider(transport: mock, codec: PayloadWireCodec())
        let bytes = Self.importPE(count: 1, name: "puts")
        // The store's token reads `Task.isCancelled`; the bridge must evaluate it on the caller.
        let task = Task.detached {
            try provider.rehydrate(
                imageBytes: bytes, requestedSliceIndex: nil,
                preserving: ImageAnalysis(imageBytes: bytes),
                cancellation: AnalysisCancellationToken { Task.isCancelled }
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is AnalysisCancelled, "got \(error)")
        }
        XCTAssertEqual(mock.cancelledRequestIDs.count, 1)
    }

    func testWorkerHandlerReportsCancelledWhenTokenTrips() throws {
        let service = AnalysisWorkerService(engine: AnalysisEngine(), codec: PayloadWireCodec())
        let bytes = Self.importPE(count: 1, name: "puts")
        let requestID = UUID()
        let codec = AnalysisRehydrateWireCodec()
        let request = try codec.encodeRequest(AnalysisRehydrateRequest(
            imageBytes: bytes, requestedSliceIndex: nil, persisted: ImageAnalysis(imageBytes: bytes),
            overrides: [:], requestID: requestID
        ))
        // A malformed request is a typed failure, never a crash.
        XCTAssertThrowsError(try codec.decodeReply(
            service.handleRehydrate(requestData: Data("{}".utf8), requestID: requestID), requestImageBytes: bytes
        )) {
            XCTAssertTrue($0 is RemoteAnalysisFailure, "got \($0)")
        }
        XCTAssertNoThrow(try codec.decodeLoaderReply(
            service.handleRehydrate(requestData: request, requestID: requestID), requestID: requestID,
            requestImageByteCount: bytes.count, requestedSliceIndex: nil
        ))
    }

    // MARK: PERF-C transport

    /// A >= 1 MiB image crosses on the sealed descriptor and comes back byte-exact, matching the
    /// in-process restore. Also records bytes-on-wire for the inline (v1-equivalent) form versus
    /// the descriptor form, request and reply.
    func testLargeImageRehydrateRoundTripIsByteExactOverSealedDescriptor() throws {
        var bytes = Self.importPE(count: 2, name: "puts")
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        bytes.append(contentsOf: (0..<(3 << 19)).map { _ -> UInt8 in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 56)
        })
        XCTAssertGreaterThanOrEqual(bytes.count, 1 << 20)
        let fresh = try analyzeFixture(bytes, name: "large.exe")
        let image = try XCTUnwrap(fresh.analysis(in: fresh.primarySlot))
        XCTAssertEqual(image.imageBytes, bytes)
        var persisted = image
        persisted.sections = []
        persisted.machOMetadata = nil
        persisted.diagnostics = []

        let loopback = LoopbackRehydrateTransport()
        let provider = XPCAnalysisProvider(transport: loopback, codec: PayloadWireCodec())
        let remote = try provider.rehydrate(
            imageBytes: bytes, requestedSliceIndex: nil, preserving: persisted, cancellation: .never
        )
        // One measurement per path on the existing PERF-C fixture; no XCTest repeated measure loop.
        let clock = ContinuousClock()
        let directStart = clock.now
        let local = try AnalysisEngine().rehydrate(
            imageBytes: bytes, requestedSliceIndex: nil, preserving: persisted, cancellation: .never
        )
        let directDuration = directStart.duration(to: clock.now)
        let scratchStart = clock.now
        let scratch = try AnalysisEngine(loader: PathOnlyRehydrateLoader()).rehydrate(
            imageBytes: bytes, requestedSliceIndex: nil, preserving: persisted, cancellation: .never
        )
        let scratchDuration = scratchStart.duration(to: clock.now)
        XCTAssertEqual(try normalized(local), try normalized(scratch))
        print("T10 rehydrate single sample: image=\(bytes.count) direct=\(directDuration) scratch=\(scratchDuration)")
        XCTAssertEqual(loopback.pinnedRehydrateCount, 1, "image bytes travelled on the descriptor")
        XCTAssertEqual(loopback.workerReceivedImageBytes, bytes, "worker read the exact bytes")
        XCTAssertEqual(remote.imageBytes, bytes, "client restored the exact bytes")
        XCTAssertEqual(try normalized(remote), try normalized(local))
        XCTAssertFalse(remote.sections.isEmpty)

        // Both v4 request forms omit persisted products; only inline image bytes are base64.
        let codec = AnalysisRehydrateWireCodec()
        let request = AnalysisRehydrateRequest(imageBytes: bytes, requestedSliceIndex: nil,
                                               persisted: persisted, overrides: [:],
                                               resourceBudget: provider.resourceBudget)
        let inlineRequest = try codec.encodeRequest(request)
        let pinnedRequest = try codec.encodeRequest(request, imageBytesOnDescriptor: true)
        XCTAssertEqual(loopback.lastRequestByteCount, pinnedRequest.count)
        XCTAssertLessThan(loopback.lastReplyByteCount, 64 << 10, "provider reply contains only loader evidence")
        XCTAssertGreaterThan(inlineRequest.count, bytes.count * 4 / 3, "inline image bytes use base64")
        XCTAssertLessThan(pinnedRequest.count, 64 << 10, "descriptor-form envelope holds no image bytes")
    }

    func testOversizeImageIsTypedErrorBeforeAnySend() throws {
        let mock = MockAnalysisTransport(outcomes: [.reply(Data())])
        let provider = XPCAnalysisProvider(transport: mock, codec: PayloadWireCodec())
        let bytes = Self.importPE(count: 1, name: "puts")
        var descriptorsMade = 0
        XCTAssertThrowsError(try provider.rehydrate(
            imageBytes: bytes, requestedSliceIndex: nil, preserving: ImageAnalysis(imageBytes: bytes),
            overrides: [:], cancellation: .never,
            transferLimits: AnalysisRehydrateTransferLimits(maximumImageBytes: bytes.count - 1,
                                                            maximumEnvelopeBytes: 512 << 20),
            makeImageSource: { descriptorsMade += 1; return try AnalysisSealedByteDescriptor.make($0) }
        )) { error in
            XCTAssertEqual(error as? AnalysisTransferLimitExceeded, AnalysisTransferLimitExceeded(
                field: .imageBytes, byteCount: bytes.count, limit: bytes.count - 1
            ))
        }
        XCTAssertEqual(descriptorsMade, 0)
        XCTAssertTrue(mock.calls.isEmpty, "nothing was sent")
        XCTAssertEqual(provider.connectionState, .idle)
    }

    func testWorkerRefusesOversizeDescriptorAndEnvelopeWithTypedReplies() throws {
        let service = AnalysisWorkerService(engine: AnalysisEngine(), codec: PayloadWireCodec())
        let bytes = Self.importPE(count: 1, name: "puts")
        let request = AnalysisRehydrateRequest(imageBytes: bytes, requestedSliceIndex: nil,
                                               persisted: ImageAnalysis(imageBytes: bytes), overrides: [:])
        let client = AnalysisRehydrateWireCodec()
        let payload = try client.encodeRequest(request, imageBytesOnDescriptor: true)

        let smallImage = AnalysisRehydrateWireCodec(limits: AnalysisRehydrateTransferLimits(
            maximumImageBytes: bytes.count - 1, maximumEnvelopeBytes: 512 << 20
        ))
        let imageReply = service.handleRehydrate(
            requestData: payload, requestID: UUID(),
            imageSource: try AnalysisSealedByteDescriptor.make(bytes), codec: smallImage
        )
        XCTAssertThrowsError(try client.decodeReply(imageReply, requestImageBytes: bytes)) { error in
            XCTAssertEqual(error as? AnalysisTransferLimitExceeded, AnalysisTransferLimitExceeded(
                field: .imageBytes, byteCount: bytes.count, limit: bytes.count - 1
            ))
        }

        let smallEnvelope = AnalysisRehydrateWireCodec(limits: AnalysisRehydrateTransferLimits(
            maximumImageBytes: 384 << 20, maximumEnvelopeBytes: payload.count - 1
        ))
        let envelopeReply = service.handleRehydrate(
            requestData: payload, requestID: UUID(),
            imageSource: try AnalysisSealedByteDescriptor.make(bytes), codec: smallEnvelope
        )
        XCTAssertThrowsError(try client.decodeReply(envelopeReply, requestImageBytes: bytes)) { error in
            XCTAssertEqual(error as? AnalysisTransferLimitExceeded, AnalysisTransferLimitExceeded(
                field: .requestEnvelope, byteCount: payload.count, limit: payload.count - 1
            ))
        }
    }

    func testDescriptorSizeMismatchOrMissingDescriptorIsMalformed() throws {
        let service = AnalysisWorkerService(engine: AnalysisEngine(), codec: PayloadWireCodec())
        let bytes = Self.importPE(count: 1, name: "puts")
        let codec = AnalysisRehydrateWireCodec()
        let payload = try codec.encodeRequest(AnalysisRehydrateRequest(
            imageBytes: bytes, requestedSliceIndex: nil, persisted: ImageAnalysis(imageBytes: bytes), overrides: [:]
        ), imageBytesOnDescriptor: true)
        for source in [nil, try AnalysisSealedByteDescriptor.make(bytes.dropLast())] {
            let reply = service.handleRehydrate(requestData: payload, requestID: UUID(), imageSource: source)
            XCTAssertThrowsError(try codec.decodeReply(reply, requestImageBytes: bytes)) { error in
                XCTAssertEqual((error as? RemoteAnalysisFailure)?.message,
                               "The rehydrate request was rejected as malformed.")
            }
        }
    }

    func testDescriptorFailureFallsBackToInlineTransfer() throws {
        let loopback = LoopbackRehydrateTransport()
        let provider = XPCAnalysisProvider(transport: loopback, codec: PayloadWireCodec())
        let bytes = Self.importPE(count: 2, name: "puts")
        let restored = try provider.rehydrate(
            imageBytes: bytes, requestedSliceIndex: nil, preserving: ImageAnalysis(imageBytes: bytes),
            overrides: [:], cancellation: .never, transferLimits: .standard,
            makeImageSource: { _ in throw POSIXError(.ENOSPC) }
        )
        XCTAssertEqual(loopback.workerRehydrateCount, 1)
        XCTAssertEqual(loopback.pinnedRehydrateCount, 0)
        XCTAssertEqual(restored.imageBytes, bytes)
        XCTAssertFalse(restored.sections.isEmpty)
    }

    // MARK: DOT-07 coordinated wire v4 (new, unexecuted Mac-only evidence)

    func testRequestOmitsPersistedInstructionStream() throws {
        let codec = AnalysisRehydrateWireCodec()
        let bytes = Data([0x90, 0xC3, 0x00, 0x7F])
        let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000707")!
        var small = ImageAnalysis(imageBytes: bytes)
        small.instructions = [Self.dot07Row(address: 0x4000)]
        var larger = small
        larger.instructions = (0..<257).map { Self.dot07Row(address: 0x4000 + UInt64($0)) }
        larger.xrefs = [.init(id: UUID(), from: 0x4000, to: 0x7000, kind: XRefKind.data)]
        larger.controlFlowEdges = [.init(id: UUID(), from: 0x4000, to: 0x4001, kind: "fallthrough")]
        let budget = AnalysisResourceBudget(maximumParallelism: 2)
        func request(_ persisted: ImageAnalysis) -> AnalysisRehydrateRequest {
            .init(imageBytes: bytes, requestedSliceIndex: nil, persisted: persisted, overrides: [:],
                  resourceBudget: budget, requestID: owner)
        }
        for pinned in [false, true] {
            let first = try codec.encodeRequest(request(small), imageBytesOnDescriptor: pinned)
            let grown = try codec.encodeRequest(request(larger), imageBytesOnDescriptor: pinned)
            XCTAssertEqual(first.count, grown.count, "row count cannot change the loader request size")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: grown) as? [String: Any])
            XCTAssertEqual(object["version"] as? Int, 5)
            XCTAssertTrue(Set(object.keys).isSubset(of: ["version", "requestID", "imageBytes",
                "imageByteCount", "imageBytesOnDescriptor", "requestedSliceIndex", "resourceBudget"]))
            for key in ["persisted", "overrides", "instructions", "functions", "xrefs", "controlFlowEdges"] {
                XCTAssertNil(object[key], key)
            }
        }
        let decoded = try codec.decodeRequest(codec.encodeRequest(request(larger)))
        XCTAssertEqual(decoded.requestID, owner)
        XCTAssertEqual(decoded.imageBytes, bytes)
        XCTAssertEqual(decoded.resourceBudget, budget)
    }

    func testSlimRequestRoundTripPreservesMappingAndDiagnostics() throws {
        let bytes = Self.dot07TinyELF()
        var persisted = ImageAnalysis(imageBytes: bytes)
        persisted.instructions = [Self.dot07Row(address: 0x4000, mnemonic: "unknown"),
                                 Self.dot07Row(address: 0x4001),
                                 Self.dot07Row(address: 0x4002, mnemonic: "ret"),
                                 Self.dot07Row(address: 0x4003)]
        persisted.functions = [.init(id: UUID(), name: "kept", startAddress: 0x4000,
                                     endAddress: 0x4004, confidence: 0.75)]
        persisted.xrefs = [.init(id: UUID(), from: 0x4000, to: 0x9000, kind: XRefKind.data)]
        persisted.controlFlowEdges = [.init(id: UUID(), from: 0x4000, to: 0x4009, kind: "branch")]
        persisted.hexBytes = Data([0xAA, 0xBB])
        persisted.stringLiterals = [.init(id: UUID(), value: "caller", address: 0x7100,
                                         sourceSection: ".rodata", byteLength: 6)]
        persisted.constantStrings = ImageConstantStringProvider.build(stringLiterals: persisted.stringLiterals,
                                                                      cfStrings: [0x7200: "persisted CFString"])
        let requestID = UUID()
        let codec = AnalysisRehydrateWireCodec()
        let engine = AnalysisEngine()
        let request = AnalysisRehydrateRequest(imageBytes: bytes, requestedSliceIndex: nil,
            persisted: persisted, overrides: [:], requestID: requestID)
        let service = AnalysisWorkerService(engine: engine, codec: PayloadWireCodec())
        let source = try AnalysisSealedByteDescriptor.make(bytes)
        defer { try? source.close() }
        let reply = service.handleRehydrate(requestData: try codec.encodeRequest(request,
            imageBytesOnDescriptor: true), requestID: requestID, imageSource: source)
        let loader = try codec.decodeLoaderReply(reply, requestID: requestID,
            requestImageByteCount: bytes.count, requestedSliceIndex: nil)
        // Handwritten ELF layout: .text's four physical bytes begin at offset 0x40, VA 0x4000.
        XCTAssertTrue(loader.mappings.contains(.init(fileOffset: 0x40, size: 4,
                                                     virtualAddress: 0x4000, sectionName: ".text")))
        let rebuilt = try RehydrationDerivedProducts.rebuild(persisted: persisted, loader: loader,
            imageBytes: bytes, cancellation: .never)
        let local = try engine.rehydrate(imageBytes: bytes, requestedSliceIndex: nil,
                                        preserving: persisted, cancellation: .never)
        XCTAssertEqual(try normalized(rebuilt), try normalized(local))
        XCTAssertEqual(rebuilt.instructions, persisted.instructions)
        XCTAssertEqual(rebuilt.functions, persisted.functions)
        XCTAssertEqual(rebuilt.xrefs, persisted.xrefs)
        XCTAssertEqual(rebuilt.controlFlowEdges, persisted.controlFlowEdges)
        XCTAssertEqual(rebuilt.hexBytes, persisted.hexBytes)
        XCTAssertEqual(rebuilt.imageBytes, bytes)
        XCTAssertEqual(rebuilt.constantStrings[0x7100]?.text, "caller")
        XCTAssertEqual(rebuilt.constantStrings[0x7200]?.text, "persisted CFString")
        XCTAssertEqual(rebuilt.diagnostics, local.diagnostics)
        XCTAssertNotNil(rebuilt.typeCatalog)
        let remote = try XPCAnalysisProvider(transport: LoopbackRehydrateTransport(), codec: PayloadWireCodec())
            .rehydrate(imageBytes: bytes, requestedSliceIndex: nil, preserving: persisted, cancellation: .never)
        XCTAssertEqual(try normalized(remote), try normalized(local))
    }

    func testSlimReplyRejectsWrongVersionAndMalformedMapping() throws {
        let codec = AnalysisRehydrateWireCodec()
        let (bytes, loader) = Self.dot07LoaderEvidence()
        let reply = codec.encodeLoaderReply(.success(loader))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        var wrongVersion = original
        wrongVersion["version"] = 3
        XCTAssertThrowsError(try codec.decodeLoaderReply(JSONSerialization.data(withJSONObject: wrongVersion),
            requestID: loader.requestID, requestImageByteCount: bytes.count, requestedSliceIndex: nil)) {
            guard case AnalysisWorkerError.versionMismatch(expected: 5, got: 3) = $0 else {
                return XCTFail("expected explicit protocol mismatch, got \($0)")
            }
        }
        var malformed = original
        var wire = try XCTUnwrap(malformed["loader"] as? [String: Any])
        var mappings = try XCTUnwrap(wire["mappings"] as? [[String: Any]])
        mappings[0]["fileOffset"] = 1 // Contradicts the section-derived exact mapping.
        wire["mappings"] = mappings
        malformed["loader"] = wire
        XCTAssertThrowsError(try codec.decodeLoaderReply(JSONSerialization.data(withJSONObject: malformed),
            requestID: loader.requestID, requestImageByteCount: bytes.count, requestedSliceIndex: nil))
    }

    func testSlimReplyRejectsChangedImageOwnerAndSlice() throws {
        let codec = AnalysisRehydrateWireCodec()
        let (bytes, loader) = Self.dot07LoaderEvidence()
        let reply = codec.encodeLoaderReply(.success(loader))
        XCTAssertThrowsError(try codec.decodeLoaderReply(reply, requestID: UUID(),
            requestImageByteCount: bytes.count, requestedSliceIndex: nil))
        XCTAssertThrowsError(try codec.decodeLoaderReply(reply, requestID: loader.requestID,
            requestImageByteCount: bytes.count + 1, requestedSliceIndex: nil))
        XCTAssertThrowsError(try codec.decodeLoaderReply(reply, requestID: loader.requestID,
            requestImageByteCount: bytes.count, requestedSliceIndex: 0))
        let request = try codec.encodeRequest(.init(imageBytes: bytes, requestedSliceIndex: nil,
            persisted: ImageAnalysis(), overrides: [:], requestID: loader.requestID))
        let service = AnalysisWorkerService(engine: AnalysisEngine(), codec: PayloadWireCodec())
        let mismatched = service.handleRehydrate(requestData: request, requestID: UUID())
        XCTAssertThrowsError(try codec.decodeLoaderReply(mismatched, requestID: loader.requestID,
            requestImageByteCount: bytes.count, requestedSliceIndex: nil)) {
            XCTAssertEqual(($0 as? RemoteAnalysisFailure)?.message,
                           "The rehydrate request was rejected as malformed.")
        }
    }

    func testSlimReplyRejectsContradictoryOutcomesAndRequestPayload() throws {
        let codec = AnalysisRehydrateWireCodec()
        let (bytes, loader) = Self.dot07LoaderEvidence()
        let good = codec.encodeLoaderReply(.success(loader))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        let failure = try XCTUnwrap(JSONSerialization.jsonObject(with:
            codec.encodeLoaderReply(.failure(AnalysisCancelled()))) as? [String: Any])
        object["failure"] = failure["failure"]
        XCTAssertThrowsError(try codec.decodeLoaderReply(JSONSerialization.data(withJSONObject: object),
            requestID: loader.requestID, requestImageByteCount: bytes.count, requestedSliceIndex: nil))
        let request = try codec.encodeRequest(.init(imageBytes: bytes, requestedSliceIndex: nil,
            persisted: ImageAnalysis(), overrides: [:], requestID: loader.requestID))
        var injected = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        injected["persisted"] = ["instructions": []]
        XCTAssertThrowsError(try codec.decodeRequest(JSONSerialization.data(withJSONObject: injected)))
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        var wire = try XCTUnwrap(object["loader"] as? [String: Any])
        wire["instructions"] = []
        object["loader"] = wire
        XCTAssertThrowsError(try codec.decodeLoaderReply(JSONSerialization.data(withJSONObject: object),
            requestID: loader.requestID, requestImageByteCount: bytes.count, requestedSliceIndex: nil))
    }

    func testSlimLoaderEvidenceRoundTripPreservesDiagnosticInputs() throws {
        let codec = AnalysisRehydrateWireCodec()
        var (bytes, loader) = Self.dot07LoaderEvidence()
        loader.loaderTruncations = [.init(address: 0x4000, message: "discarded by collector input")]
        loader.loaderFindings = [.init(category: .unsupportedFixup, code: "dot07Fixture",
                                      address: 0x4000, message: "The loader refused a structure it does not handle.")]
        loader.parserDisagreements = [.init(address: 0x4000, engines: [.lief], facts: [.architecture])]
        loader.constantCFStrings = [0x5000: "loaded"]
        let roundTrip = try codec.decodeLoaderReply(codec.encodeLoaderReply(.success(loader)),
            requestID: loader.requestID, requestImageByteCount: bytes.count, requestedSliceIndex: nil)
        XCTAssertEqual(roundTrip.loaderTruncations, loader.loaderTruncations)
        XCTAssertEqual(roundTrip.loaderFindings, loader.loaderFindings)
        XCTAssertEqual(roundTrip.parserDisagreements, loader.parserDisagreements)
        XCTAssertEqual(roundTrip.mappings, loader.mappings)
        let result = try RehydrationDerivedProducts.rebuild(persisted: ImageAnalysis(), loader: roundTrip,
            imageBytes: bytes, cancellation: .never)
        XCTAssertEqual(result.diagnostics.map(\.kind), [.loaderTruncation, .parserCrossCheckDisagreement,
                                                       .unsupportedLoaderStructure])
        XCTAssertEqual(result.constantStrings[0x5000]?.text, "loaded")
        // A skipped check is an alternative outcome, not mixed with disagreements.
        loader.parserDisagreements = []
        loader.parserCrossCheckSkip = .init(address: 0x4000, reason: .size(byteCount: bytes.count, limit: 1))
        let skipped = try codec.decodeLoaderReply(codec.encodeLoaderReply(.success(loader)),
            requestID: loader.requestID, requestImageByteCount: bytes.count, requestedSliceIndex: nil)
        XCTAssertEqual(skipped.parserCrossCheckSkip, loader.parserCrossCheckSkip)
    }

    func testSlimMetadataCarrierPreservesSelectorsAndRejectsPersistedRows() throws {
        let codec = AnalysisRehydrateWireCodec()
        var (bytes, loader) = Self.dot07LoaderEvidence()
        loader.objcSelectors = [0x6000: "dot07Selector:"]
        let reply = codec.encodeLoaderReply(.success(loader))
        let decoded = try codec.decodeLoaderReply(reply, requestID: loader.requestID,
            requestImageByteCount: bytes.count, requestedSliceIndex: nil)
        XCTAssertEqual(decoded.objcSelectors, loader.objcSelectors)
        var injectedAnalysis = ImageAnalysis()
        injectedAnalysis.instructions = [Self.dot07Row(address: 0x4000)]
        let injectedPayload = AnalysisPayloadCodec.payload(from: WorkspaceSnapshot(binaries: [],
            analysisBySlot: [.primary: injectedAnalysis]))
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        var wire = try XCTUnwrap(envelope["loader"] as? [String: Any])
        wire["metadata"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(injectedPayload))
        envelope["loader"] = wire
        XCTAssertThrowsError(try codec.decodeLoaderReply(JSONSerialization.data(withJSONObject: envelope),
            requestID: loader.requestID, requestImageByteCount: bytes.count, requestedSliceIndex: nil))
    }

    /// Source-review addendum fixture. UNEXECUTED: a general payload's lossy decoder
    /// would discard these invalid records, but the v4 metadata boundary must reject them.
    func testSlimMetadataRejectsUndecodableDiagnosticRecords() throws {
        let codec = AnalysisRehydrateWireCodec()
        var (bytes, loader) = Self.dot07LoaderEvidence()
        loader.objcSelectors = [0x6000: "dot07Admission:"]
        let reply = codec.encodeLoaderReply(.success(loader))
        let decoded = try codec.decodeLoaderReply(reply, requestID: loader.requestID,
            requestImageByteCount: bytes.count, requestedSliceIndex: nil)
        XCTAssertEqual(decoded.objcSelectors, loader.objcSelectors)

        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let malformedRecords: [Any] = [[: ] as [String: Any], NSNull()]
        for record in malformedRecords {
            var envelope = original
            var wire = try XCTUnwrap(envelope["loader"] as? [String: Any])
            var metadata = try XCTUnwrap(wire["metadata"] as? [String: Any])
            metadata["diagnostics"] = [record]
            wire["metadata"] = metadata
            envelope["loader"] = wire
            XCTAssertThrowsError(try codec.decodeLoaderReply(JSONSerialization.data(withJSONObject: envelope),
                requestID: loader.requestID, requestImageByteCount: bytes.count, requestedSliceIndex: nil))
        }
    }

    func testOmittedLiteralReplyRestoresCAndCFMapBeforeRendering() throws {
        let literals = [
            StringLiteralSummary(id: UUID(), value: "%d\n", address: 0x10,
                                 sourceSection: "__TEXT,__cstring", byteLength: 4),
            StringLiteralSummary(id: UUID(), value: "init", address: 0x20,
                                 sourceSection: "__TEXT,__objc_methname", byteLength: 5),
            StringLiteralSummary(id: UUID(), value: "collision", address: 0x30,
                                 sourceSection: "__TEXT,__cstring", byteLength: 10),
            StringLiteralSummary(id: UUID(), value: "object %@", address: 0x40,
                                 sourceSection: "__TEXT,__cstring", byteLength: 10),
        ]
        // Independent oracle, not generated by the provider or a reference implementation.
        let expected: [UInt64: MacIRConstantString] = [
            0x10: .init(text: "%d\n", kind: .cString),
            0x30: .init(text: "object %@\0\n", kind: .cfString),
            0x40: .init(text: "object %@", kind: .cString),
        ]
        let persisted = ImageAnalysis(stringLiterals: literals, constantStrings: expected)
        let codec = AnalysisRehydrateWireCodec()
        let loader = RehydrationLoaderProducts(requestID: UUID(), requestedSliceIndex: nil,
            imageByteCount: 0, sliceOffset: 0, sliceSize: nil, sections: [], mappings: [])
        let reply = codec.encodeLoaderReply(.success(loader))
        let decoded = try codec.decodeLoaderReply(reply, requestID: loader.requestID,
            requestImageByteCount: 0, requestedSliceIndex: nil)
        let restored = try RehydrationDerivedProducts.rebuild(persisted: persisted, loader: decoded,
            imageBytes: Data(), cancellation: .never)
        XCTAssertEqual(restored.stringLiterals, literals)
        XCTAssertEqual(restored.constantStrings, expected)
        // Payload-normalized equality is insufficient: it serializes only the CF subset.
        XCTAssertEqual(Array(try XCTUnwrap(restored.constantStrings[0x30]).text.utf8),
                       Array("object %@\0\n".utf8))
        let snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [.primary: restored])
        XCTAssertEqual(snapshot.pseudocodeRenderInput(selectedAddress: nil, in: .primary).constantStrings,
                       expected)
    }

    private static func dot07Row(address: UInt64, mnemonic: String = "nop") -> InstructionRow {
        .init(address: address, bytes: "90", mnemonic: mnemonic, operands: "",
              hasBreakpoint: true, comment: "caller-owned DOT-07 comment")
    }

    /// Declared DTO evidence only, not a parser-acceptance fixture. Physical four-byte .text.
    private static func dot07LoaderEvidence() -> (Data, RehydrationLoaderProducts) {
        let bytes = Data([0x90, 0x90, 0xC3, 0xCC])
        let section = SectionSummary(id: UUID(), name: ".text", address: 0x4000,
            size: 4, fileOffset: 0, isExecutable: true)
        let loader = RehydrationLoaderProducts(requestID: UUID(), requestedSliceIndex: nil,
            imageByteCount: bytes.count, sliceOffset: 0, sliceSize: nil, sections: [section],
            mappings: [.init(fileOffset: 0, size: 4, virtualAddress: 0x4000, sectionName: ".text")])
        return (bytes, loader)
    }

    /// New independent ELF64 fixture: 0x140 bytes, four .text bytes at 0x40/VA 0x4000,
    /// string table at 0x44, three section headers at 0x80. No filesystem loader dependency.
    private static func dot07TinyELF() -> Data {
        var data = Data(repeating: 0, count: 0x140)
        data.replaceSubrange(0..<8, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0])
        put(&data, 16, 2, 2); put(&data, 18, 62, 2); put(&data, 20, 1, 4)
        put(&data, 24, 0x4000, 8); put(&data, 40, 0x80, 8); put(&data, 52, 64, 2)
        put(&data, 58, 64, 2); put(&data, 60, 3, 2); put(&data, 62, 2, 2)
        data.replaceSubrange(0x40..<0x44, with: [0x90, 0x90, 0xC3, 0xCC])
        let names = Array("\u{0}.text\u{0}.shstrtab\u{0}".utf8)
        data.replaceSubrange(0x44..<(0x44 + names.count), with: names)
        put(&data, 0xC0, 1, 4); put(&data, 0xC4, 1, 4); put(&data, 0xC8, 6, 8)
        put(&data, 0xD0, 0x4000, 8); put(&data, 0xD8, 0x40, 8); put(&data, 0xE0, 4, 8)
        put(&data, 0xF0, 1, 8)
        put(&data, 0x100, 7, 4); put(&data, 0x104, 3, 4); put(&data, 0x118, 0x44, 8)
        put(&data, 0x120, UInt64(names.count), 8); put(&data, 0x130, 1, 8)
        return data
    }

    // MARK: Helpers

    private func analyzeFixture(_ bytes: Data, name: String) throws -> WorkspaceSnapshot {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ms18-\(UUID().uuidString)-\(name)")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try AnalysisEngine().analyze(url: url, requestedSliceIndex: nil, overrides: [:], cancellation: .never)
    }

    private func assertIdenticalRestore(fresh: WorkspaceSnapshot, expectSections: Bool,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(fresh.analysis(in: fresh.primarySlot), file: file, line: line)
        // What a package reload holds: persisted products only; byte-derived products empty.
        var persisted = image
        persisted.sections = []
        persisted.codeDataRanges = []
        persisted.relocations = []
        persisted.identityEffectiveByteRanges = []
        persisted.machOMetadata = nil
        persisted.jumpTables = [:]
        persisted.objcSelectors = [:]
        persisted.objcClasses = []
        persisted.objcCategories = []
        persisted.swiftTypes = []
        persisted.swiftConformances = []
        persisted.diagnostics = []

        // Compare the direct worker path with the pre-T10 file-backed loader for each format.
        let local = try AnalysisEngine(loader: PathOnlyRehydrateLoader()).rehydrate(
            imageBytes: image.imageBytes, requestedSliceIndex: nil, preserving: persisted, cancellation: .never
        )
        let loopback = LoopbackRehydrateTransport()
        let remote = try XPCAnalysisProvider(transport: loopback, codec: PayloadWireCodec()).rehydrate(
            imageBytes: image.imageBytes, requestedSliceIndex: nil, preserving: persisted, cancellation: .never
        )
        XCTAssertEqual(loopback.workerRehydrateCount, 1, file: file, line: line)
        XCTAssertEqual(try normalized(remote), try normalized(local), file: file, line: line)
        if expectSections { XCTAssertFalse(remote.sections.isEmpty, file: file, line: line) }
        XCTAssertEqual(remote.imageBytes, image.imageBytes, file: file, line: line)
    }

    /// Rehydrate stamps fresh row UUIDs (sections, code/data ranges); compare everything else.
    private func normalized(_ analysis: ImageAnalysis) throws -> NSDictionary {
        let payload = AnalysisPayloadCodec.payload(from: WorkspaceSnapshot(binaries: [], analysisBySlot: [.primary: analysis]))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
        func strip(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, inner) in dictionary where key != "id" { out[key] = strip(inner) }
                return out
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        return try XCTUnwrap(strip(object) as? [String: Any]) as NSDictionary
    }

    static func importPE(count: Int, name: String) -> Data {
        let pe = 0x80, coff = pe + 4, optional = coff + 20, sectionTable = optional + 0xF0
        let raw = 0x200, rva: UInt32 = 0x1000, thunk = 64
        let library = thunk + (count + 1) * 8
        let libraryBytes = Array("lib".utf8) + [0]
        let hintName = library + libraryBytes.count
        let text = Array(name.utf8) + [0]
        let rawCount = hintName + 2 + text.count
        var data = Data(repeating: 0, count: raw + rawCount)
        data[0] = 0x4D; data[1] = 0x5A
        put(&data, 0x3C, UInt64(pe), 4)
        data[pe] = 0x50; data[pe + 1] = 0x45
        put(&data, coff, 0x8664, 2)
        put(&data, coff + 2, 1, 2)
        put(&data, coff + 16, 0xF0, 2)
        put(&data, optional, 0x20B, 2)
        put(&data, optional + 24, 0x1_4000_0000, 8)
        put(&data, optional + 108, 16, 4)
        put(&data, optional + 120, UInt64(rva), 4)
        put(&data, optional + 124, 40, 4)
        for (index, byte) in ".idata".utf8.enumerated() { data[sectionTable + index] = byte }
        put(&data, sectionTable + 8, UInt64(rawCount), 4)
        put(&data, sectionTable + 12, UInt64(rva), 4)
        put(&data, sectionTable + 16, UInt64(rawCount), 4)
        put(&data, sectionTable + 20, UInt64(raw), 4)
        put(&data, sectionTable + 36, 0x4000_0040, 4)
        put(&data, raw, UInt64(rva) + UInt64(thunk), 4)
        put(&data, raw + 12, UInt64(rva) + UInt64(library), 4)
        put(&data, raw + 16, UInt64(rva) + UInt64(thunk), 4)
        for index in 0..<count { put(&data, raw + thunk + index * 8, UInt64(rva) + UInt64(hintName), 8) }
        data.replaceSubrange((raw + library)..<(raw + library + libraryBytes.count), with: libraryBytes)
        data.replaceSubrange((raw + hintName + 2)..<(raw + hintName + 2 + text.count), with: text)
        return data
    }

    /// ELF64 x86-64 executable: NULL, .text (ALLOC|EXEC at 0x1000), .shstrtab.
    static func miniELF() -> Data {
        let text: [UInt8] = [0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3]
        let shstr = Array("\u{0}.text\u{0}.shstrtab\u{0}".utf8)
        let textOff = 64, shstrOff = textOff + text.count, shoff = shstrOff + shstr.count
        var d = Data(repeating: 0, count: shoff + 3 * 64)
        d.replaceSubrange(0..<8, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0])
        put(&d, 16, 2, 2)                // ET_EXEC
        put(&d, 18, 62, 2)               // EM_X86_64
        put(&d, 20, 1, 4)
        put(&d, 24, 0x1000, 8)           // e_entry
        put(&d, 40, UInt64(shoff), 8)    // e_shoff
        put(&d, 52, 64, 2)               // e_ehsize
        put(&d, 58, 64, 2)               // e_shentsize
        put(&d, 60, 3, 2)                // e_shnum
        put(&d, 62, 2, 2)                // e_shstrndx
        d.replaceSubrange(textOff..<(textOff + text.count), with: text)
        d.replaceSubrange(shstrOff..<(shstrOff + shstr.count), with: shstr)
        func header(_ index: Int, name: UInt64, type: UInt64, flags: UInt64, addr: UInt64, off: Int, size: Int) {
            let base = shoff + index * 64
            put(&d, base, name, 4)
            put(&d, base + 4, type, 4)
            put(&d, base + 8, flags, 8)
            put(&d, base + 16, addr, 8)
            put(&d, base + 24, UInt64(off), 8)
            put(&d, base + 32, UInt64(size), 8)
            put(&d, base + 48, 1, 8)
        }
        header(1, name: 1, type: 1, flags: 6, addr: 0x1000, off: textOff, size: text.count)
        header(2, name: 7, type: 3, flags: 0, addr: 0, off: shstrOff, size: shstr.count)
        return d
    }

    private static func put(_ data: inout Data, _ offset: Int, _ value: UInt64, _ width: Int) {
        for index in 0..<width { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}

/// Routes `sendRehydrate` / `sendRehydratePinned` into a real worker handler, standing in for the
/// NSXPC hop (the descriptor is handed over as-is; NSXPC would dup it into the worker).
private final class LoopbackRehydrateTransport: AnalysisTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let service = AnalysisWorkerService(engine: AnalysisEngine(), codec: PayloadWireCodec())
    private var count = 0
    private var pinnedCount = 0
    private var receivedImageBytes: Data?
    private var requestBytes = 0
    private var replyBytes = 0
    var crashNext = false

    var workerRehydrateCount: Int { lock.withLock { count } }
    var pinnedRehydrateCount: Int { lock.withLock { pinnedCount } }
    var workerReceivedImageBytes: Data? { lock.withLock { receivedImageBytes } }
    var lastRequestByteCount: Int { lock.withLock { requestBytes } }
    var lastReplyByteCount: Int { lock.withLock { replyBytes } }

    func send(requestID: UUID, payload: Data) async throws -> Data {
        throw AnalysisTransportError.invalidated(reason: "analyze is not routed by this loopback")
    }

    func sendRehydrate(requestID: UUID, payload: Data) async throws -> Data {
        try route(requestID: requestID, payload: payload, imageSource: nil)
    }

    func sendRehydratePinned(requestID: UUID, payload: Data, imageSource: FileHandle) async throws -> Data {
        try route(requestID: requestID, payload: payload, imageSource: imageSource)
    }

    private func route(requestID: UUID, payload: Data, imageSource: FileHandle?) throws -> Data {
        let crash: Bool = lock.withLock { let value = crashNext; crashNext = false; return value }
        if crash { throw AnalysisTransportError.interrupted(reason: "worker exited") }
        if let imageSource, let size = try? imageSource.seekToEnd() {
            let bytes = try? AnalysisSealedByteDescriptor.read(imageSource, expectedCount: Int(size))
            lock.withLock { receivedImageBytes = bytes }
        }
        let reply = service.handleRehydrate(requestData: payload, requestID: requestID, imageSource: imageSource)
        lock.withLock {
            count += 1
            if imageSource != nil { pinnedCount += 1 }
            requestBytes = payload.count
            replyBytes = reply.count
        }
        return reply
    }

    func cancel(requestID: UUID) { service.cancel(requestID: requestID) }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

/// A loader that makes accidental disk materialization observable at the worker's real seam.
private struct CapturedOnlyRehydrateLoader: CapturedByteBinaryLoader {
    func load(at url: URL) throws -> LoadedBinary { throw POSIXError(.EIO) }

    func loadCapturedBytes(_ bytes: Data, sourceURL: URL,
                           cancellation: AnalysisCancellationToken) throws -> LoadedBinary? {
        guard !FileManager.default.fileExists(atPath: sourceURL.path) else { throw POSIXError(.EEXIST) }
        return try BinaryLoaderRouter().loadCapturedBytes(bytes, sourceURL: sourceURL,
                                                         cancellation: cancellation)
    }
}

/// Retains the pre-T10 path for the single fixture comparison and custom-loader compatibility.
private struct PathOnlyRehydrateLoader: BinaryLoader {
    func load(at url: URL) throws -> LoadedBinary { try BinaryLoaderRouter().load(at: url) }
}
