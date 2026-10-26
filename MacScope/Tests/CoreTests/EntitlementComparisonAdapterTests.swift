import Foundation
import XCTest
@testable import MacScope

@MainActor
final class EntitlementComparisonAdapterTests: XCTestCase {
    private let other = ImageSlot(rawValue: 1)

    private func store() throws -> WorkspaceStore {
        let url = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("GoldenFixtures/entitlement-risk/library-validation")
        let bytes = try Data(contentsOf: url)
        let file = try MachOParser().parse(bytes)
        let artifact = try MachOSliceArtifactIdentity(uuid: UUID(), rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0, selectedSliceSHA256: String(repeating: "a", count: 64),
            selectedSliceByteCount: UInt64(bytes.count))
        let images = [ImageSlot.primary, other].map { slot in
            BinaryImage(id: UUID(), name: "Image \(slot.rawValue)", path: "/fixture/\(slot.rawValue)",
                        kind: "Mach-O", architecture: file.architectureName, artifactIdentity: artifact, slot: slot)
        }
        var analysis = ImageAnalysis()
        analysis.imageBytes = bytes
        return WorkspaceStore(workspaceName: "Entitlements", snapshot: WorkspaceSnapshot(
            binaries: images, analysisBySlot: [.primary: analysis, other: analysis]),
            engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    private func selection(_ store: WorkspaceStore) -> EntitlementComparisonSelection {
        .init(previous: .primary, current: other, architecture: store.snapshot.binaries[0].architecture)
    }

    func testCapturesBothSlotsAndExactDeclarationsWithExistingIdentity() throws {
        let store = try store()
        let choice = selection(store)
        let result = store.captureEntitlementComparison(choice)
        let old = try XCTUnwrap(result.previous)
        let new = try XCTUnwrap(result.current)
        XCTAssertEqual(old.source.slot, .primary)
        XCTAssertEqual(new.source.slot, other)
        XCTAssertEqual(old.source.path, "/fixture/0")
        XCTAssertEqual(old.source.imageUUID, store.snapshot.binaries[0].artifactIdentity?.uuid)
        XCTAssertEqual(old.source.sliceDigest, String(repeating: "a", count: 64))
        XCTAssertEqual(old.source.generation, store.phase2ReadLedger.imageIdentity(in: .primary, snapshot: store.snapshot))
        XCTAssertEqual(old.requestedArchitecture, choice.architecture)
        XCTAssertEqual(old.declarations.state, .dictionaryPresent)
        XCTAssertEqual(old.declarations.format, "XML")
        XCTAssertEqual(old.declarations.values, new.declarations.values)
        let rows = try XCTUnwrap(result.rows)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.kind == .unchanged })
        var session = EntitlementComparisonSession()
        XCTAssertTrue(session.publish(result, current: store.entitlementComparisonContext(choice)))
        XCTAssertTrue(session.isCurrent(result.context))
    }

    func testMissingArchitectureOnOneSideIsUnavailable() throws {
        let store = try store()
        let choice = selection(store)
        store.snapshot.binaries[1].artifactIdentity = nil
        store.snapshot.binaries[1].architecture = "x86_64"
        let result = store.captureEntitlementComparison(choice)
        XCTAssertEqual(result.previous?.declarations.state, .dictionaryPresent)
        XCTAssertEqual(result.current?.declarations.state, .unavailable)
        XCTAssertTrue(result.current?.declarations.reason?.contains("selected architecture") == true)
        XCTAssertNil(result.current?.declarations.values)
        XCTAssertNil(result.rows)
    }

    func testArchitectureUsesArtifactInsteadOfDisplayLabel() throws {
        let store = try store()
        let choice = selection(store)
        store.snapshot.binaries[1].architecture = "arm64 (universal slice 2/2 @ 0x4000)"
        XCTAssertEqual(store.entitlementComparisonArchitectures, ["arm64"])
        let result = store.captureEntitlementComparison(choice)
        XCTAssertEqual(result.current?.source.architecture, "arm64")
        XCTAssertEqual(result.current?.declarations.state, .dictionaryPresent)
        XCTAssertNotNil(result.rows)
    }

    func testUnsupportedArchitectureVariantIsUnavailable() throws {
        let store = try store()
        let choice = selection(store)
        let previous = try XCTUnwrap(store.snapshot.binaries[1].artifactIdentity)
        store.snapshot.binaries[1].artifactIdentity = try .init(uuid: previous.uuid,
            rawCPUType: MachOConstants.cpuTypeARM64, rawCPUSubtype: 12,
            selectedSliceSHA256: previous.selectedSliceSHA256,
            selectedSliceByteCount: previous.selectedSliceByteCount)
        XCTAssertEqual(store.entitlementComparisonArchitectures, ["arm64"])
        let result = store.captureEntitlementComparison(choice)
        XCTAssertEqual(result.current?.declarations.state, .unavailable)
        XCTAssertTrue(result.current?.declarations.reason?.contains("selected architecture") == true)
        XCTAssertNil(result.rows)
        store.snapshot.binaries[0].artifactIdentity = store.snapshot.binaries[1].artifactIdentity
        XCTAssertTrue(store.entitlementComparisonArchitectures.isEmpty)
        let unavailablePair = store.captureEntitlementComparison(choice)
        XCTAssertEqual(unavailablePair.previous?.declarations.state, .unavailable)
        XCTAssertEqual(unavailablePair.current?.declarations.state, .unavailable)
    }

    func testReplaceInvalidatesPublication() throws {
        let store = try store()
        let choice = selection(store)
        let candidate = store.captureEntitlementComparison(choice)
        store.snapshot.binaries[1] = BinaryImage(id: UUID(), name: "Replacement", path: "/replacement",
            kind: "Mach-O", architecture: choice.architecture, slot: other)
        assertRefused(candidate, store.entitlementComparisonContext(choice))
    }

    func testSwapInvalidatesPublication() throws {
        let store = try store()
        var choice = selection(store)
        let candidate = store.captureEntitlementComparison(choice)
        choice.previous = other
        choice.current = .primary
        assertRefused(candidate, store.entitlementComparisonContext(choice))
    }

    func testReloadOfUnchangedSourceInvalidatesPublication() throws {
        let store = try store()
        let choice = selection(store)
        let candidate = store.captureEntitlementComparison(choice)
        store.isImporting = true
        assertRefused(candidate, store.entitlementComparisonContext(choice))
        let oldAnalysis = try XCTUnwrap(store.snapshot.analysis(in: other))
        store.snapshot.replaceAnalysis(oldAnalysis, in: other)
        store.isImporting = false
        let current = store.entitlementComparisonContext(choice)
        XCTAssertNotEqual(candidate.context.current?.generation, current.current?.generation)
        assertRefused(candidate, current)
    }

    func testClearInvalidatesPublication() throws {
        let store = try store()
        var choice = selection(store)
        let candidate = store.captureEntitlementComparison(choice)
        choice.current = nil
        assertRefused(candidate, store.entitlementComparisonContext(choice))
        XCTAssertNil(store.captureEntitlementComparison(choice).rows)
        var session = EntitlementComparisonSession()
        XCTAssertTrue(session.publish(candidate, current: candidate.context))
        session.invalidate()
        XCTAssertNil(session.capture)
        XCTAssertTrue(session.browser.visibleRows.isEmpty)
    }

    func testArchitectureChangeInvalidatesPublication() throws {
        let store = try store()
        var choice = selection(store)
        let candidate = store.captureEntitlementComparison(choice)
        choice.architecture = "x86_64"
        assertRefused(candidate, store.entitlementComparisonContext(choice))
        XCTAssertNil(store.captureEntitlementComparison(choice).rows)
    }

    func testRetainedContainerNeverSelectsAnotherSlice() throws {
        let store = try store()
        let choice = selection(store)
        var analysis = ImageAnalysis()
        analysis.imageBytes = Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 0])
        store.snapshot.replaceAnalysis(analysis, in: other)
        let result = store.captureEntitlementComparison(choice)
        XCTAssertEqual(result.current?.declarations.state, .unavailable)
        XCTAssertTrue(result.current?.declarations.reason?.contains("thin Mach-O") == true)
        XCTAssertNil(result.rows)
    }

    func testBrowserUsesExactKeysAndSameVisibleProjectionForSelection() throws {
        let old = try EntitlementDictionary(entries: [.init(key: "é", value: .integer(1)),
                                                     .init(key: "e\u{301}", value: .integer(2))])
        let new = try EntitlementDictionary(entries: [.init(key: "é", value: .integer(3)),
                                                     .init(key: "e\u{301}", value: .integer(2)),
                                                     .init(key: "added", value: .boolean(true))])
        var browser = ComparisonBrowser()
        browser.replaceRows(EntitlementComparison(previous: old, current: new).rows)
        browser.filter = .allKeys
        XCTAssertEqual(browser.count(.changed), 1)
        XCTAssertEqual(browser.count(.added), 1)
        XCTAssertEqual(browser.count(.removed), 0)
        XCTAssertEqual(browser.count(.unchanged), 1)
        XCTAssertEqual(Set(browser.visibleRows.map(\.id)).count, 3)
        let selected = try XCTUnwrap(browser.visibleRows.first { $0.key.utf8.elementsEqual("é".utf8) })
        browser.selection = selected.id
        browser.sortOrder = [BrowserSort(column: .key, order: .reverse)]
        XCTAssertEqual(browser.selection, selected.id)
        XCTAssertEqual(browser.selectedRow?.id, selected.id)
        XCTAssertEqual(browser.visibleRows.map(\.key), ["é", "e\u{301}", "added"])
        browser.filter = .unchanged
        XCTAssertEqual(browser.visibleRows.count, 1)
        XCTAssertNil(browser.selection)
        XCTAssertNil(browser.selectedRow)
        browser.query = "no-match"
        XCTAssertTrue(browser.visibleRows.isEmpty)
        XCTAssertEqual(browser.count(.unchanged), 1)
    }

    private func assertRefused(_ candidate: EntitlementComparisonCapture, _ current: EntitlementComparisonContext,
                               file: StaticString = #filePath, line: UInt = #line) {
        var session = EntitlementComparisonSession()
        XCTAssertFalse(session.publish(candidate, current: current), file: file, line: line)
        XCTAssertNil(session.capture, file: file, line: line)
        XCTAssertTrue(session.browser.visibleRows.isEmpty, file: file, line: line)
    }
}
