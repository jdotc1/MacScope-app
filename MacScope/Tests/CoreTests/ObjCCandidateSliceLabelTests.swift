import Foundation
import XCTest
@testable import MacScope

@MainActor
final class ObjCCandidateSliceLabelTests: XCTestCase {
    private let address: UInt64 = 0x1_0000_1000

    func testExplicitIndexWithUniqueOwner() throws {
        let store = try makeStore(index: 1)
        assertUniqueOwner(in: store)
        XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "arm64 · slice unknown")
    }

    func testExplicitIndexWithAmbiguousOwner() throws {
        let store = try makeStore(index: 1, owners: ["First", "Second"])
        assertAmbiguousOwners(in: store)
        XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "arm64 · slice unknown")
    }

    func testAutomaticSliceWithUniqueOwner() throws {
        let store = try makeStore(index: nil)
        assertUniqueOwner(in: store)
        XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "arm64 · slice unknown")
    }

    func testAutomaticSliceWithAmbiguousOwner() throws {
        let store = try makeStore(index: nil, owners: ["First", "Second"])
        assertAmbiguousOwners(in: store)
        XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "arm64 · slice unknown")
    }

    func testNoOwnerKeepsSliceFacts() throws {
        let store = try makeStore(index: 1, owners: [])
        XCTAssertEqual(store.objcMethod(at: address, in: .primary), .none)
        XCTAssertTrue(store.objcSignatureCandidates(at: address, in: .primary).isEmpty)
        XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "arm64 · slice unknown")
        store.snapshot.binaries[0].selectedSliceIndex = nil
        XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "arm64 · slice unknown")
    }

    func testEmptySlotIsUnavailable() throws {
        let store = try makeStore(index: 1)
        XCTAssertEqual(store.objcCandidateSliceLabel(in: ImageSlot(rawValue: 1)), "unavailable")
    }

    func testDisplayArchitectureIsNotParsed() throws {
        let store = try makeStore(index: 1)
        store.snapshot.binaries[0].artifactIdentity = nil
        XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "slice unknown")
        store.snapshot.binaries[0].selectedSliceIndex = nil
        XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "slice unknown")
    }

    func testNonPrimarySlotUsesItsOwnBinary() throws {
        let store = try makeStore(index: 1)
        let slot = ImageSlot(rawValue: 1)
        var second = try XCTUnwrap(store.snapshot.binary(in: .primary))
        second.slot = slot
        second.selectedSliceIndex = 3
        second.artifactIdentity = try identity(cpu: MachOConstants.cpuTypeX86_64, subtype: 3)
        store.snapshot.binaries.append(second)
        XCTAssertEqual(store.objcCandidateSliceLabel(in: slot), "x86_64 · slice unknown")
        XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "arm64 · slice unknown")
    }

    func testTypedArchitectureVariants() throws {
        let store = try makeStore(index: 1)
        let variants: [(Int32, Int32, String)] = [
            (MachOConstants.cpuTypeARM64, 0, "arm64"),
            (MachOConstants.cpuTypeARM64, 2, "arm64e"),
            (MachOConstants.cpuTypeX86_64, 3, "x86_64"),
            (MachOConstants.cpuTypeX86_64, 8, "x86_64h"),
            (0, 0, "other"),
        ]
        for (cpu, subtype, label) in variants {
            store.snapshot.binaries[0].artifactIdentity = try identity(cpu: cpu, subtype: subtype)
            XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "\(label) · slice unknown")
        }
    }

    func testActualUniversalFactDoesNotDependOnRequestOrOwner() throws {
        let store = try makeStore(index: nil, owners: [])
        store.snapshot.binaries[0].machOSelectedSliceFact = try fact(index: 1)
        XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "arm64 · universal slice 1 of 2")
        store.snapshot.binaries[0].selectedSliceIndex = 99
        XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "arm64 · universal slice 1 of 2")
    }

    func testThinFactIsExplicitAndLegacyAbsenceStaysUnknown() throws {
        let store = try makeStore(index: nil)
        store.snapshot.binaries[0].machOSelectedSliceFact = try MachOSelectedSliceFact(
            containerKind: .thin, sliceCount: 1, selectedSliceIndex: 0,
            cpuType: MachOConstants.cpuTypeARM64, cpuSubtype: 0)
        XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "arm64 · thin slice 0")
        store.snapshot.binaries[0].machOSelectedSliceFact = nil
        XCTAssertEqual(store.objcCandidateSliceLabel(in: .primary), "arm64 · slice unknown")
    }

    func testActualFactChangeInvalidatesCandidateEvenWithUnchangedLegacyIndex() throws {
        let store = try makeStore(index: nil)
        store.snapshot.binaries[0].machOSelectedSliceFact = try fact(index: 1)
        let candidate = try XCTUnwrap(store.objcSignatureCandidates(at: address, in: .primary).first)
        let initial = try XCTUnwrap(store.objcSignatureCandidateContext(at: address, in: .primary))
        XCTAssertNil(ObjCSignatureCandidateService.validateCurrentContext(candidate, current: initial))
        let replacements: [MachOSelectedSliceFact?] = [
            try fact(index: 0),
            try MachOSelectedSliceFact(containerKind: .universal, sliceCount: 3, selectedSliceIndex: 1,
                      cpuType: MachOConstants.cpuTypeARM64, cpuSubtype: 0),
            try MachOSelectedSliceFact(containerKind: .universal, sliceCount: 2, selectedSliceIndex: 1,
                      cpuType: MachOConstants.cpuTypeARM64, cpuSubtype: 2),
            nil,
        ]
        for replacement in replacements {
            store.snapshot.binaries[0].machOSelectedSliceFact = replacement
            let current = try XCTUnwrap(store.objcSignatureCandidateContext(at: address, in: .primary))
            XCTAssertEqual(current.selectedSliceIndex, initial.selectedSliceIndex)
            XCTAssertEqual(ObjCSignatureCandidateService.validateCurrentContext(candidate, current: current)?.code,
                           "stale-context")
        }
    }

    private func fact(index: Int) throws -> MachOSelectedSliceFact {
        try .init(containerKind: .universal, sliceCount: 2, selectedSliceIndex: index,
                  cpuType: MachOConstants.cpuTypeARM64, cpuSubtype: 0)
    }

    private func assertUniqueOwner(in store: WorkspaceStore, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unique = store.objcMethod(at: address, in: .primary) else {
            return XCTFail("Expected a unique owner", file: file, line: line)
        }
        XCTAssertEqual(store.objcSignatureCandidates(at: address, in: .primary).count, 1, file: file, line: line)
    }

    private func assertAmbiguousOwners(in store: WorkspaceStore, file: StaticString = #filePath, line: UInt = #line) {
        guard case .ambiguous(let matches) = store.objcMethod(at: address, in: .primary) else {
            return XCTFail("Expected ambiguous owners", file: file, line: line)
        }
        XCTAssertEqual(matches.count, 2, file: file, line: line)
        XCTAssertNil(store.objcSignatureCandidateContext(at: address, in: .primary), file: file, line: line)
        XCTAssertTrue(store.objcSignatureCandidates(at: address, in: .primary).isEmpty, file: file, line: line)
    }

    private func identity(cpu: Int32 = MachOConstants.cpuTypeARM64, subtype: Int32 = 0) throws -> MachOSliceArtifactIdentity {
        try .init(uuid: nil, rawCPUType: cpu, rawCPUSubtype: subtype,
                  selectedSliceSHA256: String(repeating: "a", count: 64), selectedSliceByteCount: 128)
    }

    private func makeStore(index: Int?, owners: [String] = ["Widget"]) throws -> WorkspaceStore {
        var analysis = ImageAnalysis()
        analysis.objcClasses = owners.map { name in
            .init(name: name, superclassName: "NSObject", adoptedProtocols: [], classMethods: [],
                  instanceMethods: [.init(selector: "setObject:", typeEncoding: "v24@0:8@16",
                                          isClassMethod: false, implementation: address)],
                  ivars: [], properties: [])
        }
        let binary = BinaryImage(id: UUID(), name: "Widget", path: "/tmp/Widget", kind: "Mach-O",
                                 architecture: "arm64 (formatted display)", selectedSliceIndex: index,
                                 artifactIdentity: try identity())
        return WorkspaceStore(workspaceName: "Slice labels",
                              snapshot: .init(binaries: [binary], analysisBySlot: [.primary: analysis]),
                              engine: AnalysisEngine(), autosaveScheduler: nil)
    }
}
