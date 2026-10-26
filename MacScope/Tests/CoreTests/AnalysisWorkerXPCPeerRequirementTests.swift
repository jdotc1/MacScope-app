import Foundation
import Security
import XCTest

@testable import MacScope

final class AnalysisWorkerXPCPeerRequirementTests: XCTestCase {
    func testPeerRequirementsCompileAndBindFrozenIdentifiers() throws {
        XCTAssertEqual(
            AnalysisWorkerXPCPeerRequirement.app,
            "identifier \"org.macscope.app\" and "
                + "anchor apple generic and certificate leaf[subject.CN] = "
                + "\"Apple Development: MacScope Developer (CERT000000)\" and "
                + "certificate leaf[subject.OU] = \"TEAM000000\" and "
                + "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"
        )
        XCTAssertEqual(
            AnalysisWorkerXPCPeerRequirement.worker,
            "identifier \"org.macscope.app.AnalysisWorker\" and "
                + "anchor apple generic and certificate leaf[subject.CN] = "
                + "\"Apple Development: MacScope Developer (CERT000000)\" and "
                + "certificate leaf[subject.OU] = \"TEAM000000\" and "
                + "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"
        )

        try assertCompiles(AnalysisWorkerXPCPeerRequirement.app)
        try assertCompiles(AnalysisWorkerXPCPeerRequirement.worker)
    }

    func testListenerAdmissionInstallsAppRequirementBeforeExportsAndResume() {
        var events: [String] = []

        AnalysisWorkerXPCListenerAdmission.accept(
            installRequirement: { events.append("requirement:\($0)") },
            exportInterface: { events.append("interface") },
            exportObject: { events.append("object") },
            resume: { events.append("resume") }
        )

        XCTAssertEqual(
            events,
            [
                "requirement:\(AnalysisWorkerXPCPeerRequirement.app)",
                "interface",
                "object",
                "resume",
            ]
        )
    }

    /// Live mutual-authentication acceptance against the embedded, signed analysis
    /// worker: CoreTests runs inside the signed MacScope.app TEST_HOST, so this
    /// connection exercises the worker-side app requirement (the service must
    /// accept its legitimate host) and the client-side worker requirement (the
    /// host must accept the legitimately signed service). The worker's contract
    /// is exactly one reply per analyze call, even for a garbage payload.
    func testLiveAnalysisWorkerAcceptsMutuallyAuthenticatedConnection() {
        let connection = NSXPCConnection(serviceName: NSXPCConnectionTransport.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: AnalysisWorkerXPCProtocol.self)
        connection.setCodeSigningRequirement(AnalysisWorkerXPCPeerRequirement.worker)
        connection.resume()
        defer { connection.invalidate() }

        let replied = expectation(description: "the signed worker replies over the gated connection")
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("mutually authenticated connection must not fail delivery: \(error)")
        }
        guard let worker = proxy as? AnalysisWorkerXPCProtocol else {
            return XCTFail("analysis worker proxy unavailable")
        }
        worker.analyze(requestData: Data("not a real envelope".utf8), requestID: UUID()) { _ in
            replied.fulfill()
        }

        wait(for: [replied], timeout: 30)
    }

    /// Live supplemental-lane acceptance through the real signed embedded worker. Production
    /// composes this principal with `MachOKitDyldCacheAnalysisProvider`; a valid bounded request
    /// naming a guaranteed-missing local file must therefore cross the selector and return the
    /// provider's redacted typed rejection. A test/default unavailable provider, malformed reply,
    /// primary-analysis reply, delivery error, or silent selector omission all fail this test.
    func testLiveAnalysisWorkerDyldCacheSelectorReturnsTypedProviderRejection() throws {
        let connection = makeMutuallyAuthenticatedConnection()
        defer { connection.invalidate() }

        let request = makeMissingDyldCacheRequest()
        let requestData = try DyldCacheAnalysisWireCodec().encodeRequest(request)
        let replied = expectation(description: "the signed worker returns a typed dyld-cache reply")
        replied.assertForOverFulfill = true
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("dyld-cache delivery over the authenticated connection must succeed: \(error)")
        }
        guard let worker = proxy as? AnalysisWorkerXPCProtocol else {
            return XCTFail("analysis worker proxy unavailable")
        }

        worker.inspectDyldCache(
            requestData: requestData,
            requestID: request.requestID
        ) { data in
            do {
                _ = try DyldCacheAnalysisWireCodec().decodeReply(data)
                XCTFail("the signed worker must return a typed provider rejection")
            } catch {
                XCTAssertEqual(
                    error as? RemoteDyldCacheAnalysisFailure,
                    RemoteDyldCacheAnalysisFailure(code: .providerRejectedInput)
                )
            }
            replied.fulfill()
        }

        wait(for: [replied], timeout: 30)
    }

    /// Live success through the signed worker and its production MachOKit adapter. The fixture is
    /// a complete, bounded single-image cache admitted independently by MacScope's cache parser;
    /// its projected Mach-O digest supplies the exact subject binding instead of a test constant.
    /// This keeps the success proof deterministic and small while still exercising the real
    /// embedded provider rather than a test/default implementation.
    func testLiveAnalysisWorkerDyldCacheSelectorReturnsBoundProviderSuccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-signed-xpc-valid-dyld-cache-\(UUID())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var fixture = DyldCacheFixture.makeSingleImageCache(cpuSubtype: 2)
        // The shared loader fixture deliberately exercises MacScope's supported legacy image
        // table fallback at offsets 0x18/0x1c. The production MachOKit lane is stricter: its
        // pinned provider always reads the modern image fields, and preflight therefore admits a
        // request only when 0x1c0/0x1c4 name the same bounded table. Make this live-XPC fixture a
        // valid modern cache instead of asking the production boundary to accept the fallback.
        replaceUInt32LE(
            in: &fixture.bytes,
            at: 0x1c0,
            with: UInt32(fixture.imagesOffset)
        )
        replaceUInt32LE(in: &fixture.bytes, at: 0x1c4, with: 1)
        let sourceURL = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        try fixture.bytes.write(to: sourceURL, options: .atomic)
        let request = try makeValidDyldCacheRequest(
            sourceURL: sourceURL,
            fixture: fixture
        )
        let requestData = try DyldCacheAnalysisWireCodec().encodeRequest(request)

        let connection = makeMutuallyAuthenticatedConnection()
        defer { connection.invalidate() }
        let replied = expectation(description: "the signed worker returns a bound MachOKit result")
        replied.assertForOverFulfill = true
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("valid dyld-cache delivery over the authenticated connection must succeed: \(error)")
        }
        guard let worker = proxy as? AnalysisWorkerXPCProtocol else {
            return XCTFail("analysis worker proxy unavailable")
        }

        worker.inspectDyldCache(
            requestData: requestData,
            requestID: request.requestID
        ) { data in
            do {
                let decoded = try DyldCacheAnalysisWireCodec().decodeReply(data)
                let result = try request.validate(result: decoded)
                XCTAssertEqual(result.provider, .machOKit0522)
                XCTAssertEqual(result.requestID, request.requestID)
                XCTAssertEqual(result.sourceIdentity, request.expectedSourceIdentity)
                XCTAssertEqual(result.subject, request.subject)
                XCTAssertEqual(result.files.first?.identity, request.expectedSourceIdentity)
                XCTAssertTrue(result.images.contains { $0.identity == request.subject.imageIdentity })
                XCTAssertEqual(
                    result.coverage.first(where: { $0.category == .mappings })?.returnedRecordCount,
                    result.mappings.count
                )
                XCTAssertLessThanOrEqual(result.images.count, request.limits.maximumImages)
                XCTAssertLessThanOrEqual(result.mappings.count, request.limits.maximumMappings)
            } catch {
                XCTFail("the admitted cache must return one structurally valid bound result: \(error)")
            }
            replied.fulfill()
        }

        wait(for: [replied], timeout: 30)
    }

    /// The cancellation selector is independently live across the same signed boundary. The
    /// worker registry intentionally retains cancellation arriving before registration; the
    /// subsequent matching request must consume that tombstone, produce one typed cancelled
    /// reply, and never fall through to the production provider.
    func testLiveAnalysisWorkerDyldCachePreRegistrationCancellationIsTypedAndExactlyOnce() throws {
        let connection = makeMutuallyAuthenticatedConnection()
        defer { connection.invalidate() }

        let request = makeMissingDyldCacheRequest()
        let requestData = try DyldCacheAnalysisWireCodec().encodeRequest(request)
        let replied = expectation(description: "the pre-cancelled dyld-cache request replies once")
        replied.assertForOverFulfill = true
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail("dyld-cache cancellation delivery over the authenticated connection must succeed: \(error)")
        }
        guard let worker = proxy as? AnalysisWorkerXPCProtocol else {
            return XCTFail("analysis worker proxy unavailable")
        }

        worker.cancelDyldCacheInspection(requestID: request.requestID)
        worker.inspectDyldCache(
            requestData: requestData,
            requestID: request.requestID
        ) { data in
            do {
                _ = try DyldCacheAnalysisWireCodec().decodeReply(data)
                XCTFail("the pre-cancelled request must return a typed cancellation")
            } catch {
                XCTAssertTrue(error is AnalysisCancelled)
            }
            replied.fulfill()
        }

        wait(for: [replied], timeout: 30)
    }

    /// Live rejection: a client requirement naming the wrong service identifier
    /// must fail delivery instead of accepting the peer. The reply block must
    /// never run — a reply would mean the requirement gate admitted a peer that
    /// does not satisfy the installed requirement.
    func testLiveAnalysisWorkerConnectionRejectsWrongServiceRequirement() {
        let wrongRequirement =
            "identifier \"org.macscope.app.WrongService\" and "
            + "anchor apple generic and certificate leaf[subject.CN] = "
            + "\"Apple Development: MacScope Developer (CERT000000)\" and "
            + "certificate leaf[subject.OU] = \"TEAM000000\" and "
            + "certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"
        let connection = NSXPCConnection(serviceName: NSXPCConnectionTransport.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: AnalysisWorkerXPCProtocol.self)
        connection.setCodeSigningRequirement(wrongRequirement)
        connection.resume()
        defer { connection.invalidate() }

        let rejected = expectation(description: "delivery fails against the wrong-identifier requirement")
        rejected.assertForOverFulfill = false
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            rejected.fulfill()
        }
        guard let worker = proxy as? AnalysisWorkerXPCProtocol else {
            return XCTFail("analysis worker proxy unavailable")
        }
        worker.analyze(requestData: Data("not a real envelope".utf8), requestID: UUID()) { _ in
            XCTFail("a reply must never arrive through a connection whose peer requirement is unsatisfied")
        }

        wait(for: [rejected], timeout: 30)
    }

    private func assertCompiles(_ expression: String) throws {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(expression as CFString, [], &requirement)
        XCTAssertEqual(status, errSecSuccess, "requirement must compile: \(expression)")
        XCTAssertNotNil(requirement)
    }

    private func makeMutuallyAuthenticatedConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: NSXPCConnectionTransport.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: AnalysisWorkerXPCProtocol.self)
        connection.setCodeSigningRequirement(AnalysisWorkerXPCPeerRequirement.worker)
        connection.resume()
        return connection
    }

    private func makeMissingDyldCacheRequest() -> DyldCacheAnalysisRequest {
        let fixture = DyldCacheAnalysisTestFixtures.request()
        return DyldCacheAnalysisRequest(
            url: URL(
                fileURLWithPath: "/private/tmp/MacScope-signed-xpc-missing-dyld-cache-\(UUID())"
            ),
            expectedSourceIdentity: fixture.expectedSourceIdentity,
            subject: fixture.subject,
            categories: fixture.categories,
            limits: fixture.limits,
            requestID: fixture.requestID
        )
    }

    private func makeValidDyldCacheRequest(
        sourceURL: URL,
        fixture: DyldCacheFixture
    ) throws -> DyldCacheAnalysisRequest {
        let loaded = try DyldSharedCacheBinaryLoader(
            targetImagePath: "/usr/lib/libFixture.dylib"
        ).load(at: sourceURL)
        let artifactIdentity = try XCTUnwrap(loaded.artifactIdentity)
        let header = try DyldSharedCacheParser().parseHeader(fixture.bytes)
        let selectedImage = try XCTUnwrap(header.images.first)
        let subject = DyldCacheAnalysisSubjectIdentity(
            artifactIdentity: artifactIdentity,
            imageIdentity: DyldCacheImageIdentity(
                path: selectedImage.path,
                loadAddress: selectedImage.address
            ),
            analysisGeneration: 1
        )
        let sourceIdentity = try DyldCacheSourceIdentityReader.identity(for: sourceURL)
        let limits = DyldCacheAnalysisLimits(
            maximumImages: 4,
            maximumMappings: 4,
            maximumLocalSymbols: 0,
            maximumTrieEntries: 0,
            maximumWarnings: 8,
            maximumOutputBytes: 1024 * 1024,
            maximumSourceBytes: UInt64(fixture.bytes.count),
            maximumDurationMilliseconds: 10_000
        )
        return try DyldCacheAnalysisRequest(
            url: sourceURL,
            expectedSourceIdentity: sourceIdentity,
            subject: subject,
            categories: [.catalog, .mappings],
            limits: limits,
            requestID: UUID()
        ).validated()
    }

    private func replaceUInt32LE(in data: inout Data, at offset: Int, with value: UInt32) {
        precondition(offset >= 0 && offset <= data.count - MemoryLayout<UInt32>.size)
        let base = data.startIndex + offset
        data[base] = UInt8(value & 0xff)
        data[base + 1] = UInt8((value >> 8) & 0xff)
        data[base + 2] = UInt8((value >> 16) & 0xff)
        data[base + 3] = UInt8((value >> 24) & 0xff)
    }
}
