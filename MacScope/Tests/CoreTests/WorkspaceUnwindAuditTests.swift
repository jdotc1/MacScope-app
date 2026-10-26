import Foundation
import XCTest
@testable import MacScope

@MainActor
final class WorkspaceUnwindAuditTests: XCTestCase {
    private func retainedInput() throws -> (Data, MachOSliceArtifactIdentity, MachOPreferredSegmentLayout) {
        let bytes = MachOFixture.makeExecutableWithFunctionStarts().bytes
        let file = try MachOParser().parse(bytes)
        // Deliberately supplied admission evidence, not a digest of these authored bytes.
        let identity = try MachOSliceArtifactIdentity(uuid: nil, rawCPUType: file.header.cpuType,
            rawCPUSubtype: file.header.cpuSubtype, selectedSliceSHA256: String(repeating: "a", count: 64),
            selectedSliceByteCount: UInt64(bytes.count))
        let layout = try MachOPreferredSegmentLayout(records: file.segments.map {
            .init(name: $0.name, preferredVMStart: $0.vmAddress, preferredVMSize: $0.vmSize,
                  sliceRelativeFileOffset: $0.fileOffset, fileSize: $0.fileSize,
                  initialProtections: $0.initialProtection)
        }, selectedSliceByteCount: UInt64(bytes.count))
        return (bytes, identity, layout)
    }

    private func store(twoImages: Bool = false) throws -> WorkspaceStore {
        let (bytes, identity, layout) = try retainedInput()
        let parsed = try MachOParser().parse(bytes)
        let slots: [ImageSlot] = twoImages ? [.primary, .init(rawValue: 1)] : [.primary]
        let binaries = slots.map { slot in
            BinaryImage(id: UUID(), name: "authored-\(slot.rawValue)", path: "/not-opened/authored",
                kind: "Mach-O", architecture: "arm64", artifactIdentity: identity,
                preferredSegmentLayout: layout, artifactIntegrityState: .verified, slot: slot)
        }
        var analysis = ImageAnalysis()
        analysis.imageBytes = bytes
        analysis.sections = parsed.sections.map {
            .init(id: UUID(), name: $0.qualifiedName, address: $0.address, size: $0.size,
                  fileOffset: UInt64($0.fileOffset), isExecutable: $0.isExecutableInstructions,
                  isZeroFill: $0.isZeroFill)
        }
        return WorkspaceStore(workspaceName: "Authored audit", snapshot: .init(binaries: binaries,
            analysisBySlot: Dictionary(uniqueKeysWithValues: slots.map { ($0, analysis) })),
            engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    func testRetainedLoaderPreservesSuppliedIdentityAndOmitsNewAttestations() throws {
        let (bytes, identity, layout) = try retainedInput()
        let loaded = try MachOBinaryLoader().load(retainedBytes: bytes,
            sourceURL: URL(fileURLWithPath: "/not-opened/authored"), verifiedIdentity: identity,
            layout: layout, integrity: .verified)
        XCTAssertEqual(loaded.artifactIdentity, identity)
        XCTAssertEqual(loaded.preferredSegmentLayout, layout)
        XCTAssertEqual(loaded.artifactIntegrityState, .verified)
        XCTAssertEqual(loaded.bytes, bytes)
        XCTAssertTrue(loaded.identityEffectiveByteRanges.isEmpty)
        XCTAssertFalse(loaded.functionStarts.isEmpty)
    }

    func testRetainedLoaderRefusesLayoutCPUAndExtentMismatch() throws {
        let (bytes, identity, layout) = try retainedInput()
        let url = URL(fileURLWithPath: "/not-opened/authored")
        let emptyLayout = try MachOPreferredSegmentLayout(records: [], selectedSliceByteCount: UInt64(bytes.count))
        XCTAssertThrowsError(try MachOBinaryLoader().load(retainedBytes: bytes, sourceURL: url,
            verifiedIdentity: identity, layout: emptyLayout, integrity: .verified)) {
            XCTAssertEqual($0 as? MachOBinaryLoader.RetainedInputError, .layoutMismatch)
        }
        let wrongCPU = try MachOSliceArtifactIdentity(uuid: nil, rawCPUType: 0x01000007,
            rawCPUSubtype: 0, selectedSliceSHA256: identity.selectedSliceSHA256,
            selectedSliceByteCount: UInt64(bytes.count))
        XCTAssertThrowsError(try MachOBinaryLoader().load(retainedBytes: bytes, sourceURL: url,
            verifiedIdentity: wrongCPU, layout: layout, integrity: .verified)) {
            XCTAssertEqual($0 as? MachOBinaryLoader.RetainedInputError, .cpuMismatch)
        }
        let wrongSubtype = try MachOSliceArtifactIdentity(uuid: nil, rawCPUType: identity.rawCPUType,
            rawCPUSubtype: 2, selectedSliceSHA256: identity.selectedSliceSHA256,
            selectedSliceByteCount: UInt64(bytes.count))
        XCTAssertThrowsError(try MachOBinaryLoader().load(retainedBytes: bytes, sourceURL: url,
            verifiedIdentity: wrongSubtype, layout: layout, integrity: .verified)) {
            XCTAssertEqual($0 as? MachOBinaryLoader.RetainedInputError, .cpuMismatch)
        }
        XCTAssertThrowsError(try MachOBinaryLoader().load(retainedBytes: Data(bytes.dropLast()), sourceURL: url,
            verifiedIdentity: identity, layout: layout, integrity: .verified)) {
            XCTAssertEqual($0 as? MachOBinaryLoader.RetainedInputError, .sliceExtentMismatch)
        }
        XCTAssertThrowsError(try MachOBinaryLoader().load(retainedBytes: bytes, sourceURL: url,
            verifiedIdentity: identity, layout: layout, integrity: .unavailable)) {
            XCTAssertEqual($0 as? MachOBinaryLoader.RetainedInputError, .unverifiedIdentity)
        }
    }

    func testMissingAuthorityOrBytesCannotStartAudit() throws {
        let store = try store()
        store.snapshot.binaries[0].artifactIntegrityState = .unavailable
        XCTAssertNil(store.unwindAuditKey(in: .primary))
        XCTAssertNil(store.startUnwindAudit(in: .primary))
        store.snapshot.binaries[0].artifactIntegrityState = .verified
        store.snapshot.analysisBySlot[.primary]?.imageBytes = Data()
        XCTAssertNil(store.unwindAuditKey(in: .primary))
        XCTAssertNil(store.startUnwindAudit(in: .primary))
    }

    func testSnapshotGenerationRetiresCompletedReportAndNavigation() async throws {
        let store = try store()
        let task = try XCTUnwrap(store.startUnwindAudit(in: .primary))
        await task.value
        XCTAssertEqual(store.unwindAuditCoordinator.state.phase, .completed)
        let finding = try XCTUnwrap(store.unwindAuditCoordinator.state.report?.findings.first)
        let target = try XCTUnwrap(store.unwindAuditCoordinator.state.navigationTarget(for: finding))
        var changed = store.snapshot
        changed.binaries[0].name = "new snapshot generation"
        store.snapshot = changed
        XCTAssertNil(store.unwindAuditCoordinator.state.report)
        XCTAssertNotEqual(store.unwindAuditKey(in: .primary), target.key)
        XCTAssertFalse(store.navigateFromUnwindAudit(target))
    }

    func testCollidingImageAddressCannotNavigateAfterFocusChanges() async throws {
        let store = try store(twoImages: true)
        let task = try XCTUnwrap(store.startUnwindAudit(in: .primary))
        await task.value
        let finding = try XCTUnwrap(store.unwindAuditCoordinator.state.report?.findings.first)
        let target = try XCTUnwrap(store.unwindAuditCoordinator.state.navigationTarget(for: finding))
        store.focusImage(.init(rawValue: 1))
        let selection = store.selectedImageAddress
        XCTAssertFalse(store.navigateFromUnwindAudit(target))
        XCTAssertEqual(store.selectedImageAddress, selection)
        XCTAssertEqual(store.focusedImageSlot, .init(rawValue: 1))
    }

    func testCurrentQualifiedFindingNavigatesAndDismissesMetadata() async throws {
        let store = try store()
        store.showMachOMetadata = true
        let task = try XCTUnwrap(store.startUnwindAudit(in: .primary))
        await task.value
        let finding = try XCTUnwrap(store.unwindAuditCoordinator.state.report?.findings.first)
        let target = try XCTUnwrap(store.unwindAuditCoordinator.state.navigationTarget(for: finding))
        XCTAssertTrue(store.navigateFromUnwindAudit(target))
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: .primary, address: target.address))
        XCTAssertFalse(store.showMachOMetadata)
    }
}
