import Foundation
import XCTest
@testable import MacScope

final class AppendedExecutableCaveAuthoringTests: XCTestCase {
    func testCaveAuthoringSurvivesDatabaseAndPackageRoundTrip() throws {
        let owner = UUID()
        let function = UUID()
        let cave = AppendedExecutableCaveAuthoring(
            ownerBinaryID: owner, functionID: function,
            selectedSliceSHA256: String(repeating: "a", count: 64),
            branchSourceAddress: 0x1000_00000,
            codeBytes: Data([0x20, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6])
        )
        XCTAssertTrue(cave.isWellFormed)
        var snapshot = WorkspaceSnapshot(
            binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()
        )
        let key = ImageAddress(slot: .primary, address: 0x1000_00000)
        snapshot.addressOverrides[key] = AddressOverride(appendedExecutableCave: cave)
        let source = try WorkspaceDatabase.inMemory()
        try source.applySchema()
        let saved = try source.saveSnapshot(
            workspaceUUID: UUID(), workspaceName: "Appended cave", snapshot: snapshot, now: Date()
        )
        let workspaceID = try XCTUnwrap(saved.id)
        XCTAssertEqual(try source.loadSnapshot(workspaceID: workspaceID)?.addressOverrides[key]?.appendedExecutableCave, cave)

        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("appended-cave-\(UUID().uuidString).mscope")
        defer { try? FileManager.default.removeItem(at: packageURL) }
        let manifest = try source.writePackage(workspaceID: workspaceID, documentID: UUID(), to: packageURL)
        XCTAssertTrue(manifest.requiredReaderFeatures.contains(
            WorkspacePackageManifest.appendedExecutableCaveReaderFeature
        ))
        let destination = try WorkspaceDatabase.inMemory()
        try destination.applySchema()
        let imported = try destination.importPackage(from: packageURL)
        XCTAssertEqual(imported.snapshot.addressOverrides[key]?.appendedExecutableCave, cave)
    }
}
