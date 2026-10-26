import Foundation
import XCTest
@testable import MacScope

@MainActor
final class PatternAppSelectionTests: XCTestCase {
    func testRecordBoundsPositive() throws {
        let fixture = PatternAppTestFixture()
        let capture = try fixture.capture()
        XCTAssertEqual(capture.request.bytes, Data((4..<16).map(UInt8.init)))
        XCTAssertEqual(capture.request.key.selectionByteCount, 12)
    }
    func testRecordBoundsNegative() {
        let fixture = PatternAppTestFixture()
        fixture.record = 4..<33
        XCTAssertThrowsError(try fixture.capture())
        XCTAssertEqual(fixture.transport.sends, 0)
    }
    func testWorkspacePositive() throws {
        let fixture = PatternAppTestFixture()
        try fixture.publish()
        XCTAssertEqual(fixture.nodes.count, 1)
        XCTAssertEqual(fixture.reveal(), 6..<8)
    }
    func testImageSlotPositive() throws {
        let fixture = PatternAppTestFixture()
        try fixture.publish()
        XCTAssertEqual(fixture.nodes.count, 1)
        XCTAssertEqual(fixture.reveal(), 6..<8)
    }
    func testOwnerPositive() throws {
        let fixture = PatternAppTestFixture()
        try fixture.publish()
        XCTAssertEqual(fixture.nodes.count, 1)
        XCTAssertEqual(fixture.reveal(), 6..<8)
    }
    func testWindowPositive() throws {
        let fixture = PatternAppTestFixture()
        try fixture.publish()
        XCTAssertEqual(fixture.nodes.count, 1)
        XCTAssertEqual(fixture.reveal(), 6..<8)
    }
    func testBytesPositive() throws {
        let fixture = PatternAppTestFixture()
        try fixture.publish()
        XCTAssertEqual(fixture.nodes.count, 1)
        XCTAssertEqual(fixture.reveal(), 6..<8)
    }
    func testSourcePositive() throws {
        let fixture = PatternAppTestFixture()
        try fixture.publish()
        XCTAssertEqual(fixture.nodes.count, 1)
        XCTAssertEqual(fixture.reveal(), 6..<8)
    }
    func testRecordSelectionPositive() throws {
        let fixture = PatternAppTestFixture()
        try fixture.publish()
        XCTAssertEqual(fixture.nodes.count, 1)
        XCTAssertEqual(fixture.reveal(), 6..<8)
    }
    func testMappingsPositive() throws {
        let fixture = PatternAppTestFixture()
        try fixture.publish()
        XCTAssertEqual(fixture.nodes.count, 1)
        XCTAssertEqual(fixture.reveal(), 6..<8)
    }
    func testWorkspaceNegative() throws {
        assertStoreRevokesForWorkspace()
        for restoreBeforeReply in [false, true] {
            let fixture = PatternAppTestFixture()
            let capture = try fixture.begin()
            let generation = fixture.owner.generation
            let original = fixture.frame
            let originalSource = fixture.source
            let originalRecord = fixture.record
            fixture.workspaceID = UUID()
            fixture.publication = PatternPublicationEpoch()
            if restoreBeforeReply {
                fixture.restore(original)
                fixture.source = originalSource
                fixture.record = originalRecord
            }
            fixture.accept(capture, generation: generation)
            XCTAssertTrue(fixture.nodes.isEmpty)
            XCTAssertNil(fixture.reveal())
        }
    }
    func testImageSlotNegative() throws {
        assertStoreRevokesForImageSlot()
        for restoreBeforeReply in [false, true] {
            let fixture = PatternAppTestFixture()
            let capture = try fixture.begin()
            let generation = fixture.owner.generation
            let original = fixture.frame
            let originalSource = fixture.source
            let originalRecord = fixture.record
            fixture.slot = ImageSlot(rawValue: 1)
            fixture.publication = PatternPublicationEpoch()
            if restoreBeforeReply {
                fixture.restore(original)
                fixture.source = originalSource
                fixture.record = originalRecord
            }
            fixture.accept(capture, generation: generation)
            XCTAssertTrue(fixture.nodes.isEmpty)
            XCTAssertNil(fixture.reveal())
        }
    }
    func testOwnerNegative() throws {
        assertStoreRevokesForOwner()
        for restoreBeforeReply in [false, true] {
            let fixture = PatternAppTestFixture()
            let capture = try fixture.begin()
            let generation = fixture.owner.generation
            let original = fixture.frame
            let originalSource = fixture.source
            let originalRecord = fixture.record
            fixture.binaryID = UUID()
            fixture.publication = PatternPublicationEpoch()
            if restoreBeforeReply {
                fixture.restore(original)
                fixture.source = originalSource
                fixture.record = originalRecord
            }
            fixture.accept(capture, generation: generation)
            XCTAssertTrue(fixture.nodes.isEmpty)
            XCTAssertNil(fixture.reveal())
        }
    }
    func testWindowNegative() throws {
        assertStoreRevokesForWindow()
        for restoreBeforeReply in [false, true] {
            let fixture = PatternAppTestFixture()
            let capture = try fixture.begin()
            let generation = fixture.owner.generation
            let original = fixture.frame
            let originalSource = fixture.source
            let originalRecord = fixture.record
            fixture.window = 16..<48
            fixture.publication = PatternPublicationEpoch()
            if restoreBeforeReply {
                fixture.restore(original)
                fixture.source = originalSource
                fixture.record = originalRecord
            }
            fixture.accept(capture, generation: generation)
            XCTAssertTrue(fixture.nodes.isEmpty)
            XCTAssertNil(fixture.reveal())
        }
    }
    func testBytesNegative() throws {
        assertStoreRevokesForBytes()
        for restoreBeforeReply in [false, true] {
            let fixture = PatternAppTestFixture()
            let capture = try fixture.begin()
            let generation = fixture.owner.generation
            let original = fixture.frame
            let originalSource = fixture.source
            let originalRecord = fixture.record
            fixture.bytes[20] = 255
            fixture.publication = PatternPublicationEpoch()
            if restoreBeforeReply {
                fixture.restore(original)
                fixture.source = originalSource
                fixture.record = originalRecord
            }
            fixture.accept(capture, generation: generation)
            XCTAssertTrue(fixture.nodes.isEmpty)
            XCTAssertNil(fixture.reveal())
        }
    }
    func testSourceNegative() throws {
        for restoreBeforeReply in [false, true] {
            let fixture = PatternAppTestFixture()
            let capture = try fixture.begin()
            let generation = fixture.owner.generation
            let original = fixture.frame
            let originalSource = fixture.source
            let originalRecord = fixture.record
            fixture.source = "u16 changed @ 0;"
            fixture.owner.invalidate()
            if restoreBeforeReply {
                fixture.restore(original)
                fixture.source = originalSource
                fixture.record = originalRecord
            }
            fixture.accept(capture, generation: generation)
            XCTAssertTrue(fixture.nodes.isEmpty)
            XCTAssertNil(fixture.reveal())
        }
    }
    func testRecordSelectionNegative() async throws {
        for restoreBeforeReply in [false, true] {
            let fixture = PatternAppTestFixture()
            let capture = try fixture.begin()
            let generation = fixture.owner.generation
            let original = fixture.frame
            let originalSource = fixture.source
            let originalRecord = fixture.record
            fixture.record = 5..<17
            fixture.owner.invalidate()
            if restoreBeforeReply {
                fixture.restore(original)
                fixture.source = originalSource
                fixture.record = originalRecord
            }
            fixture.accept(capture, generation: generation)
            XCTAssertTrue(fixture.nodes.isEmpty)
            XCTAssertNil(fixture.reveal())
        }
        let immediate = PatternAppTestFixture()
        _ = try immediate.begin()
        immediate.owner.invalidate()
        await Task.yield()
        XCTAssertEqual(immediate.transport.sends, 0)
    }
    func testMappingsNegative() throws {
        assertStoreRevokesForMappings()
        for restoreBeforeReply in [false, true] {
            let fixture = PatternAppTestFixture()
            let capture = try fixture.begin()
            let generation = fixture.owner.generation
            let original = fixture.frame
            let originalSource = fixture.source
            let originalRecord = fixture.record
            fixture.mappings.append(.init(fileOffset: 7, size: 1, virtualAddress: 0x9000))
            fixture.publication = PatternPublicationEpoch()
            if restoreBeforeReply {
                fixture.restore(original)
                fixture.source = originalSource
                fixture.record = originalRecord
            }
            fixture.accept(capture, generation: generation)
            XCTAssertTrue(fixture.nodes.isEmpty)
            XCTAssertNil(fixture.reveal())
        }
        let fixture = PatternAppTestFixture()
        fixture.mappings.append(.init(fileOffset: 7, size: 1, virtualAddress: 0x9000))
        try fixture.publish()
        XCTAssertEqual(fixture.nodes.count, 1)
        XCTAssertNil(fixture.reveal(), "Middle-byte alias rejects the entire two-byte field")
    }
    func testBackingPositive() throws {
        let fixture = PatternAppTestFixture()
        try fixture.publish()
        XCTAssertEqual(fixture.reveal(), 6..<8)
    }
    func testBackingNegative() throws {
        let fixture = PatternAppTestFixture()
        let capture = try fixture.begin()
        var reply = PatternAppTestFixture.reply(capture.request)
        reply.nodes[0].backing = .synthetic
        reply.nodes[0].sectionID = 1
        reply.nodes[0].ranges = []
        fixture.owner.accept(data: try JSONEncoder().encode(reply), requestID: capture.request.requestID,
                             generation: fixture.owner.generation)
        XCTAssertEqual(fixture.nodes.count, 1)
        XCTAssertNil(fixture.reveal())
    }
    private func makeStore() -> WorkspaceStore {
        let bytes = Data(repeating: 7, count: 200_000)
        let snapshot = WorkspaceSnapshot(binaries: [
            .init(id: UUID(), name: "primary", path: "", kind: "fixture", architecture: "arm64"),
            .init(id: UUID(), name: "secondary", path: "", kind: "fixture", architecture: "arm64", slot: ImageSlot(rawValue: 1))
        ], functions: [], instructions: [], xrefs: [], hexBytes: Data(bytes.prefix(4096)),
        sections: [.init(id: UUID(), name: "__data", address: 0x1000, size: UInt64(bytes.count), fileOffset: 0, isExecutable: false)],
        imageBytes: bytes)
        return WorkspaceStore(workspaceName: "pattern epoch", snapshot: snapshot,
                              engine: AnalysisEngine(), autosaveScheduler: nil)
    }
    private func assertStoreRevokesForWorkspace() {
        let store = makeStore()
        let before = PatternPaneFrame.read(store)
        _ = store.forkWorkspaceIdentity()
        XCTAssertNotEqual(before.publication, store.patternPublicationEpoch)
        XCTAssertNotEqual(before.workspaceID, store.workspaceID)
    }
    private func assertStoreRevokesForImageSlot() {
        let store = makeStore()
        let before = PatternPaneFrame.read(store)
        store.focusImage(ImageSlot(rawValue: 1))
        store.focusImage(.primary)
        XCTAssertEqual(store.focusedImageSlot, before.slot)
        XCTAssertNotEqual(before.publication, store.patternPublicationEpoch)
    }
    private func assertStoreRevokesForOwner() {
        let store = makeStore()
        let before = PatternPaneFrame.read(store)
        let original = store.snapshot.binaries[0]
        store.snapshot.binaries[0] = .init(id: UUID(), name: "replacement", path: "", kind: "fixture", architecture: "arm64")
        store.snapshot.binaries[0] = original
        XCTAssertEqual(store.focusedBinary?.id, before.owner)
        XCTAssertNotEqual(before.publication, store.patternPublicationEpoch)
    }
    private func assertStoreRevokesForWindow() {
        let store = makeStore()
        let before = PatternPaneFrame.read(store)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1000 + 150_000)))
        XCTAssertNotEqual(store.hexWindowRange(), before.window)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1000)))
        XCTAssertEqual(store.hexWindowRange(), before.window)
        XCTAssertNotEqual(before.publication, store.patternPublicationEpoch)
    }
    private func assertStoreRevokesForBytes() {
        let store = makeStore()
        let before = PatternPaneFrame.read(store)
        let original = store.snapshot.imageBytes
        store.snapshot.imageBytes[20] = 255
        store.snapshot.imageBytes = original
        XCTAssertEqual(store.patchedHexWindow().bytes, before.bytes)
        XCTAssertNotEqual(before.publication, store.patternPublicationEpoch)
    }
    private func assertStoreRevokesForMappings() {
        let store = makeStore()
        let before = PatternPaneFrame.read(store)
        let original = store.snapshot.sections
        store.snapshot.sections.append(.init(id: UUID(), name: "alias", address: 0x9000, size: 1, fileOffset: 7, isExecutable: false))
        store.snapshot.sections = original
        XCTAssertEqual(store.hexWindowMappings, before.mappings)
        XCTAssertNotEqual(before.publication, store.patternPublicationEpoch)
    }

}

@MainActor
final class PatternAppTestTransport: PatternAppTransport {
    var available = true
    var sends = 0
    var cancelled: [UUID] = []
    func send(requestID: UUID, payload: Data) async throws -> Data {
        sends += 1
        let request = try JSONDecoder().decode(PatternInterpretationRequest.self, from: payload)
        return try JSONEncoder().encode(PatternAppTestFixture.reply(request))
    }
    func cancel(requestID: UUID) { cancelled.append(requestID) }
}

@MainActor
final class PatternAppTestFixture {
    var publication = PatternPublicationEpoch()
    var workspaceID = UUID()
    var slot = ImageSlot.primary
    var binaryID = UUID()
    var window = 0..<32
    var bytes = Data((0..<32).map(UInt8.init))
    var patchedOffsets: Set<Int> = []
    var mappings = [FileAddressMapping(fileOffset: 0, size: 32, virtualAddress: 0x1000)]
    var record = 4..<16
    var source = "u16 field @ 2;"
    var sourceIdentity = "user-text"
    let transport = PatternAppTestTransport()
    lazy var owner = PatternInterpretationOwner(transport: transport, live: { [unowned self] in
        (self.frame, self.record, self.source, self.sourceIdentity)
    })
    var frame: PatternPaneFrame {
        .init(publication: publication, workspaceID: workspaceID, slot: slot, owner: binaryID,
              window: window, bytes: bytes, patchedOffsets: patchedOffsets, mappings: mappings)
    }
    func restore(_ value: PatternPaneFrame) {
        workspaceID = value.workspaceID; slot = value.slot
        if let owner = value.owner { binaryID = owner }
        window = value.window; bytes = value.bytes
        patchedOffsets = value.patchedOffsets; mappings = value.mappings
    }
    func capture() throws -> PatternAppCapture {
        try .init(frame: frame, record: record, source: source, sourceIdentity: sourceIdentity)
    }
    func begin() throws -> PatternAppCapture {
        let value = try capture(); owner.start(capture: value); return value
    }
    func accept(_ capture: PatternAppCapture, generation: UUID) {
        do {
            owner.accept(data: try JSONEncoder().encode(Self.reply(capture.request)),
                         requestID: capture.request.requestID, generation: generation)
        } catch { XCTFail("Fixture encoding failed: \(error)") }
    }
    func publish() throws {
        let capture = try begin(); accept(capture, generation: owner.generation)
    }
    var nodes: [PatternField] {
        owner.nodesIfCurrent(frame: frame, record: record, source: source, sourceIdentity: sourceIdentity)
    }
    func reveal() -> Range<Int>? { owner.reveal(fieldID: 1, generation: owner.generation) }
    static func reply(_ request: PatternInterpretationRequest) -> PatternInterpretationReply {
        .init(schemaVersion: 1, engineCommit: "300d7388475dd7ffd04239dfc889b72fe08bae18",
              requestID: request.requestID.uuidString, imageIdentity: request.key.imageIdentity,
              patternIdentity: request.key.patternIdentity, byteSnapshotID: request.key.byteSnapshotID,
              selectionImageOffset: request.key.selectionImageOffset,
              selectionByteCount: request.key.selectionByteCount, status: .completed,
              nodes: [.init(id: 1, parentID: nil, depth: 0, kind: .unsigned, name: "field", typeName: "u16",
                sectionID: 0, patternOffset: 2, declaredSize: 2, backing: .file,
                ranges: [.init(selectionOffset: 2, length: 2)], bits: nil, value: "7", flags: [],
                childCount: 0, childrenTruncated: false)], diagnostics: [])
    }
}
