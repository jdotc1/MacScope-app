import Foundation
import XCTest
@testable import MacScope

final class SourceCandidateIndexTests: XCTestCase {
    private let uuid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let revision = SourceRevisionIdentity("refs/tags/v1.2.3")!

    func testExactDebugLinkRetainsPrimaryImageSliceRevisionAndLineEvidence() throws {
        let checkout = try makeCheckout()
        let binary = image(slot: .primary, architecture: "arm64e", slice: 1)
        let index = SourceCandidateIndex(
            binary: binary,
            sourceRevision: revision,
            debugContext: .init(architecture: "arm64e", sourceRevision: revision),
            sourceLines: [lineRow(path: "/build/project/Sources/main.c")],
            acceptedCheckouts: [checkout]
        )

        let link = try XCTUnwrap(index.links(functionAddress: 0x1014).first)
        XCTAssertEqual(link.qualification, .exactDebugSymbols)
        XCTAssertEqual(link.image?.slot, .primary)
        XCTAssertEqual(link.image?.binaryID, binary.id)
        XCTAssertEqual(link.image?.imageUUID, uuid)
        XCTAssertEqual(link.image?.architecture, "arm64e")
        XCTAssertEqual(link.image?.selectedSliceIndex, 1)
        XCTAssertEqual(link.image?.sourceRevision, revision)
        XCTAssertEqual(link.checkoutID, checkout.id)
        XCTAssertEqual(link.line, 42)
        XCTAssertEqual(link.localPath, checkout.localRootPath + "/Sources/main.c")
        XCTAssertTrue(link.isOpenable)
    }

    func testDifferentUUIDArchitectureAndRevisionRemainExplicitlyUnresolved() throws {
        let checkout = try makeCheckout()
        let wrongUUID = SourceCandidateIndex(
            binary: image(slot: .primary), sourceRevision: revision,
            debugContext: .init(architecture: "arm64", sourceRevision: revision),
            sourceLines: [lineRow(path: "/build/project/Sources/main.c", artifactUUID: UUID())],
            acceptedCheckouts: [checkout]
        ).links(functionAddress: 0x1000)[0]
        XCTAssertEqual(wrongUUID.unresolvedReason, .debugArtifactUUIDMismatch)

        let wrongArchitecture = SourceCandidateIndex(
            binary: image(slot: .primary), sourceRevision: revision,
            debugContext: .init(architecture: "x86_64", sourceRevision: revision),
            sourceLines: [lineRow(path: "/build/project/Sources/main.c")],
            acceptedCheckouts: [checkout]
        ).links(functionAddress: 0x1000)[0]
        XCTAssertEqual(wrongArchitecture.unresolvedReason, .architectureMismatch)

        let otherRevision = SourceRevisionIdentity("refs/tags/v2")!
        let wrongRevision = SourceCandidateIndex(
            binary: image(slot: .primary), sourceRevision: revision,
            debugContext: .init(architecture: "arm64", sourceRevision: otherRevision),
            sourceLines: [lineRow(path: "/build/project/Sources/main.c")],
            acceptedCheckouts: [checkout]
        ).links(functionAddress: 0x1000)[0]
        XCTAssertEqual(wrongRevision.unresolvedReason, .sourceRevisionMismatch)
        XCTAssertFalse(wrongRevision.isOpenable)

        let checkoutRevisionMismatch = SourceCandidateIndex(
            binary: image(slot: .primary), sourceRevision: revision,
            debugContext: .init(architecture: "arm64", sourceRevision: revision),
            sourceLines: [lineRow(path: "/build/project/Sources/main.c")],
            acceptedCheckouts: [try XCTUnwrap(AcceptedLocalSourceCheckout(
                localRootPath: checkout.localRootPath,
                recordedSourceRoot: checkout.recordedSourceRoot,
                revision: otherRevision
            ))]
        ).links(functionAddress: 0x1000)[0]
        XCTAssertEqual(checkoutRevisionMismatch.unresolvedReason, .sourceRevisionMismatch)
    }

    func testMarkerOnlyLinkIsTentativeAndNeverPromotedToExactEvidence() throws {
        let checkout = try makeCheckout()
        let marker = try XCTUnwrap(CompilerSourceMarker(
            recordedPath: "/build/project/Sources/main.c", line: 42,
            functionAddress: 0x1000, sourceRevision: revision,
            description: "compiler-recorded source path"
        ))
        let links = SourceCandidateIndex(
            binary: image(slot: .primary), sourceRevision: revision,
            debugContext: nil, sourceLines: [], compilerMarkers: [marker],
            acceptedCheckouts: [checkout]
        ).links(functionAddress: 0x1000)

        XCTAssertEqual(links[0].unresolvedReason, .noLineForAddress)
        XCTAssertEqual(links[1].qualification, .versionQualifiedCandidate)
        XCTAssertTrue(links[1].isOpenable)
        guard case .some(.compilerMarker) = links[1].evidence else {
            return XCTFail("marker evidence must remain a marker")
        }
    }

    func testCompareImagesOpenerAcceptsMatchingSideAndRefusesStaleSideOrRevision() throws {
        let checkout = try makeCheckout(createSource: true)
        let comparisonSlot = ImageSlot(rawValue: 7)
        let binary = image(slot: comparisonSlot, architecture: "arm64", slice: 0)
        let index = SourceCandidateIndex(
            binary: binary, sourceRevision: revision,
            debugContext: .init(architecture: "arm64", sourceRevision: revision),
            sourceLines: [lineRow(path: "/build/project/Sources/main.c")],
            acceptedCheckouts: [checkout]
        )
        let link = try XCTUnwrap(index.links(functionAddress: 0x1000).first)
        let imageIdentity = try XCTUnwrap(link.image)
        let target = try SourceLinkOpener().target(
            for: link, origin: .compareImagesNew(slot: comparisonSlot),
            currentImage: imageIdentity, checkout: checkout
        )
        XCTAssertEqual(target.line, 42)
        XCTAssertEqual(target.fileURL.lastPathComponent, "main.c")

        XCTAssertThrowsError(try SourceLinkOpener().target(
            for: link, origin: .compareImagesOld(slot: .primary),
            currentImage: imageIdentity, checkout: checkout
        )) { XCTAssertEqual($0 as? SourceLinkOpenError, .staleImage) }

        let staleCheckout = try XCTUnwrap(AcceptedLocalSourceCheckout(
            localRootPath: checkout.localRootPath,
            recordedSourceRoot: checkout.recordedSourceRoot,
            revision: SourceRevisionIdentity("refs/tags/v9")!
        ))
        XCTAssertThrowsError(try SourceLinkOpener().target(
            for: link, origin: .compareImagesNew(slot: comparisonSlot),
            currentImage: imageIdentity, checkout: staleCheckout
        )) { XCTAssertEqual($0 as? SourceLinkOpenError, .staleSourceRevision) }
    }

    private func image(
        slot: ImageSlot,
        architecture: String = "arm64",
        slice: Int? = nil
    ) -> BinaryImage {
        BinaryImage(
            id: UUID(), name: "sample", path: "/tmp/sample", kind: "Mach-O",
            architecture: architecture,
            metadata: BinaryMetadataSummary(uuid: uuid.uuidString.lowercased()),
            selectedSliceIndex: slice, slot: slot
        )
    }

    private func lineRow(
        path: String,
        artifactUUID: UUID? = nil
    ) -> SourceLineEntry {
        SourceLineEntry(
            address: 0x1000, file: path, line: 42, column: 7, endSequence: false,
            debugArtifactUUID: artifactUUID ?? uuid,
            debugArtifactMachOSHA256: String(repeating: "a", count: 64),
            debugArtifactMachOByteCount: 4_096,
            lineProgramUnitOffset: 24, fileTableIndex: 3,
            tablePath: .absoluteUTF8(path)
        )
    }

    private func makeCheckout(createSource: Bool = false) throws -> AcceptedLocalSourceCheckout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-source-link-\(UUID().uuidString)", isDirectory: true)
        if createSource {
            let sources = root.appendingPathComponent("Sources", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try "int main(void) { return 0; }\n".write(
                to: sources.appendingPathComponent("main.c"), atomically: true, encoding: .utf8
            )
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        }
        return try XCTUnwrap(AcceptedLocalSourceCheckout(
            localRootPath: root.path,
            recordedSourceRoot: "/build/project",
            revision: revision
        ))
    }
}
