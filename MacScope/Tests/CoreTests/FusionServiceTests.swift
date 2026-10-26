import Foundation
import XCTest
@testable import MacScope

private actor FixtureWorker: AppKitNibWorker {
    var calls = 0
    let failure: AppKitWorkerFailure?
    let failAt: Int
    init(failure: AppKitWorkerFailure? = nil, failAt: Int = 1) {
        self.failure = failure; self.failAt = failAt
    }
    func parse(_ lease: AppKitResourceLease, inputLabel: String) async throws -> AppKitWorkerOutput {
        calls += 1
        if calls == failAt, let failure { throw failure }
        let json = """
        {"file":"\(inputLabel)","formatVersion":1,"coderVersion":1,
        "outlets":[],"actions":[{"kind":"action","name":"save:",
        "source":"NSButton","destination":"Controller"}],"runtimeAttrs":[],"classes":[],"navigation":[]}
        """
        return .init(json: Data(json.utf8), exitCode: 0, donorRevision: NibKitRevision.reviewed)
    }
}

final class FusionServiceTests: XCTestCase, @unchecked Sendable {
    private let image = AppKitImageKey(imageID: "selected", imageGeneration: "g1", bundleGeneration: "b1")
    private func lease(_ path: String = "Main.nib") -> AppKitResourceLease {
        .init(resource: .init(bundleID: "fixture", bundleGeneration: "b1", relativePath: path,
            contentSHA256: String(repeating: "a", count: 64)), bytes: Data("NIBArchive".utf8))
    }
    private var method: ObjCMethodFact {
        .init(image: image, ownerClass: "Controller", selector: "save:",
              isClassMethod: false, implementationVMAddress: 4096)
    }

    func testDefaultOffDoesNotInvokeWorker() async {
        let worker = FixtureWorker()
        let result = await AppKitFusionService().analyze(leases: [lease()], methods: [method],
            allowedImages: [image], worker: worker)
        let calls = await worker.calls
        XCTAssertEqual(result.state, .disabled)
        XCTAssertEqual(calls, 0)
    }

    func testSelectedImageCandidateAndEnvelopeRoundtrip() async throws {
        let result = await AppKitFusionService().analyze(enabled: true, leases: [lease()],
            methods: [method], allowedImages: [image], worker: FixtureWorker())
        XCTAssertEqual(result.state, .complete)
        XCTAssertEqual(result.claims.first?.candidateImplementation?.vmAddress, 4096)
        XCTAssertFalse(try XCTUnwrap(result.claims.first).runtimeDispatchProven)
        let restored = try JSONDecoder().decode(AppKitFusionEnvelope.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(restored.schemaVersion, 1)
        XCTAssertEqual(restored.helperExitCodes, [0])
    }

    func testLaterWorkerFailureRemovesEarlierClaims() async {
        let result = await AppKitFusionService().analyze(enabled: true,
            leases: [lease(), lease("Second.nib")], methods: [method], allowedImages: [image],
            worker: FixtureWorker(failure: .timeout, failAt: 2))
        XCTAssertEqual(result.state, .refused)
        XCTAssertEqual(result.workerFailure, .timeout)
        XCTAssertTrue(result.claims.isEmpty)
        XCTAssertEqual(result.helperExitCodes, [0])
    }

    func testStaleScopeRefusesWithoutCallingWorker() async {
        let worker = FixtureWorker()
        let result = await AppKitFusionService().analyze(enabled: true, leases: [lease()],
            methods: [method], allowedImages: [], worker: worker)
        let calls = await worker.calls
        XCTAssertEqual(result.state, .refused)
        XCTAssertEqual(calls, 0)
    }

    func testCancellationRefusesWithoutLeakingPriorClaims() async {
        let result = await AppKitFusionService().analyze(enabled: true, leases: [lease()],
            methods: [], allowedImages: [image], worker: FixtureWorker(failure: .cancelled))
        XCTAssertEqual(result.workerFailure, .cancelled)
        XCTAssertTrue(result.claims.isEmpty)
    }

    func testDirectReconcileRejectsUnreviewedDonor() {
        let doc = NibDecodedDocument(resource: lease().resource, donorRevision: "unknown",
            archiveFormatVersion: 1, coderVersion: 1, outlets: [],
            actions: [.init(kind: "action", name: "save:", source: "NSButton", destination: "Controller")],
            runtimeAttributes: [], customClasses: [], navigation: [])
        XCTAssertTrue(AppKitFusionEngine().reconcile(document: doc, methodFacts: [method],
            allowedImageKeys: [image]).isEmpty)
    }

    func testLeaseCapReturnsTooManyDocuments() async {
        let worker = FixtureWorker()
        let result = await AppKitFusionService().analyze(enabled: true,
            leases: (0..<257).map { lease("Resource-\($0).nib") }, methods: [method],
            allowedImages: [image], worker: worker)
        XCTAssertEqual(result.state, .refused)
        XCTAssertEqual(result.refusals.first?.reason, .tooManyDocuments)
        XCTAssertTrue(result.refusals.first?.detail.contains("256") == true)
        XCTAssertTrue(result.claims.isEmpty)
        let calls = await worker.calls
        XCTAssertEqual(calls, 0)
    }

    func testMethodCapReturnsTooManyRecords() async {
        let worker = FixtureWorker()
        let result = await AppKitFusionService().analyze(enabled: true, leases: [lease()],
            methods: Array(repeating: method, count: 65_537), allowedImages: [image], worker: worker)
        XCTAssertEqual(result.state, .refused)
        XCTAssertEqual(result.refusals.first?.reason, .tooManyRecords)
        XCTAssertTrue(result.refusals.first?.detail.contains("65,536") == true)
        XCTAssertTrue(result.claims.isEmpty)
        let calls = await worker.calls
        XCTAssertEqual(calls, 0)
    }

    func testImageCapReturnsTooManyRecords() async {
        let images = Set((0..<257).map {
            AppKitImageKey(imageID: "slot-\($0)", imageGeneration: "g1", bundleGeneration: "b1")
        })
        let result = await AppKitFusionService().analyze(enabled: true, leases: [lease()],
            methods: [method], allowedImages: images, worker: FixtureWorker())
        XCTAssertEqual(result.state, .refused)
        XCTAssertEqual(result.refusals.first?.reason, .tooManyRecords)
        XCTAssertTrue(result.refusals.first?.detail.contains("256") == true)
        XCTAssertTrue(result.claims.isEmpty)
    }

    func testInvalidIdentityKeepsIdentityRefusal() async {
        let invalid = AppKitResourceLease(resource: .init(bundleID: "", bundleGeneration: "b1",
            relativePath: "Main.nib", contentSHA256: String(repeating: "a", count: 64)), bytes: Data())
        let worker = FixtureWorker()
        let result = await AppKitFusionService().analyze(enabled: true, leases: [invalid],
            methods: [method], allowedImages: [image], worker: worker)
        XCTAssertEqual(result.state, .refused)
        XCTAssertEqual(result.refusals.first?.reason, .invalidResourceIdentity)
        XCTAssertTrue(result.claims.isEmpty)
        let calls = await worker.calls
        XCTAssertEqual(calls, 0)
    }

}
