import Foundation
import XCTest
@testable import MacScope

final class UnwindAuditResultStateTests: XCTestCase {
    private func key() throws -> UnwindAuditResultKey {
        .init(imageID: UUID(), slot: .primary, generation: UUID(),
              identity: try MachOSliceArtifactIdentity(uuid: nil, rawCPUType: 0x0100000c,
                  rawCPUSubtype: 0, selectedSliceSHA256: String(repeating: "a", count: 64),
                  selectedSliceByteCount: 64),
              modelID: UnwindAuditResultKey.currentModelID, configuration: .init())
    }

    private func report(_ key: UnwindAuditResultKey) -> UnwindAuditReport {
        let rows = [("agreement", UInt64(0x1000)), ("unresolved", 0x1040), ("inconsistency", 0x1080)]
        return .init(identity: key.identity, configuration: key.configuration, findings: rows.map { verdict, address in
            .init(identity: key.identity,
                  function: .init(id: String(address), address: address, symbolName: nil, size: 0x40),
                  endAddress: address + 0x40, verdict: verdict, coverage: "compact", mode: "frame",
                  scope: "metadata_only", reasonCodes: ["authored_test"], limitations: ["Bounded test model."])
        })
    }

    func testUnresolvedFindingsSortFirstWithoutLosingEvidence() throws {
        let key = try key(), report = report(key)
        var state = UnwindAuditResultState()
        let request = state.begin(key)
        XCTAssertTrue(state.publish(report, for: request))
        XCTAssertEqual(state.sortedFindings.map(\.verdict), ["unresolved", "inconsistency", "agreement"])
        XCTAssertEqual(state.report, report)
        XCTAssertEqual(state.sortedFindings.first?.limitations, ["Bounded test model."])
    }

    func testChangedImageGenerationModelAndLimitsRejectOldPublication() throws {
        let original = try key()
        let alternatives: [UnwindAuditResultKey] = [
            .init(imageID: UUID(), slot: original.slot, generation: original.generation,
                  identity: original.identity, modelID: original.modelID, configuration: original.configuration),
            .init(imageID: original.imageID, slot: original.slot, generation: UUID(),
                  identity: original.identity, modelID: original.modelID, configuration: original.configuration),
            .init(imageID: original.imageID, slot: original.slot, generation: original.generation,
                  identity: original.identity, modelID: "future-model", configuration: original.configuration),
            .init(imageID: original.imageID, slot: original.slot, generation: original.generation,
                  identity: original.identity, modelID: original.modelID, configuration: .init(maxPaths: 1))
        ]
        for changed in alternatives {
            var state = UnwindAuditResultState()
            let request = state.begin(original)
            state.activate(changed)
            XCTAssertFalse(state.publish(report(original), for: request))
            XCTAssertEqual(state.discardedPublicationCount, 1)
            XCTAssertNil(state.report)
            XCTAssertEqual(state.phase, .idle)
        }
    }

    func testRestartCancellationAndRemovalRetireRequests() throws {
        let key = try key()
        var state = UnwindAuditResultState()
        let first = state.begin(key)
        let second = state.begin(key)
        XCTAssertFalse(state.publish(report(key), for: first))
        XCTAssertEqual(state.request, second)
        state.cancel()
        XCTAssertFalse(state.publish(report(key), for: second))
        XCTAssertEqual(state.phase, .cancelled)
        state.activate(nil)
        state.fail("late error", for: second)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.discardedPublicationCount, 3)
    }

    func testMismatchedAndInvalidReportsNeverBecomeNavigable() throws {
        let key = try key()
        var state = UnwindAuditResultState()
        var invalid = report(key)
        invalid.analysisModelVersion = "different-model"
        let first = state.begin(key)
        XCTAssertFalse(state.publish(invalid, for: first))
        XCTAssertNil(state.report)
        invalid = report(key)
        invalid.findings[0].endAddress = 0
        let second = state.begin(key)
        XCTAssertFalse(state.publish(invalid, for: second))
        XCTAssertNil(state.report)
        XCTAssertNil(state.navigationTarget(for: invalid.findings[0]))
    }

    func testNavigationKeepsExactImageAndRejectsOutOfRangeOrStaleRows() throws {
        let key = try key(), report = report(key)
        var state = UnwindAuditResultState()
        let request = state.begin(key)
        XCTAssertTrue(state.publish(report, for: request))
        let finding = try XCTUnwrap(report.findings.first)
        XCTAssertEqual(state.navigationTarget(for: finding)?.key, key)
        XCTAssertEqual(state.navigationTarget(for: finding)?.address, finding.function.address)
        XCTAssertNil(state.navigationTarget(for: finding, address: finding.endAddress))
        state.activate(nil)
        XCTAssertNil(state.navigationTarget(for: finding))
    }
}
