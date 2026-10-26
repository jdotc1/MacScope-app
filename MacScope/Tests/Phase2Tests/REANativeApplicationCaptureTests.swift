import Foundation
import XCTest
@testable import MacScope

final class REANativeApplicationCaptureTests: XCTestCase {
    private func executable() -> Data {
        var data = Data()
        for word: UInt32 in [0xfeedfacf,0x0100000c,0,2,0,0,0,0] {
            var value = word.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
    private func binary(_ bytes: Data) -> LoadedBinary {
        LoadedBinary(name: "Main", path: "Main", isBundle: false, cpuType: 0x0100000c,
            fileTypeName: "Mach-O executable", architectureDisplayName: "arm64",
            metadata: .init(uuid: nil, platformName: nil, minimumOSVersion: nil, sdkVersion: nil, buildTools: []),
            bytes: bytes, sliceOffset: 0, sections: [], executableTextSection: nil, entryPointAddress: nil,
            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [], functionStarts: [], objcSelectors: [:])
    }
    private func fixture(_ body: (URL, Data) throws -> Void) throws {
        let root = TestWorkRoot.authority.appendingPathComponent("rea-capture-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = executable(); try bytes.write(to: root.appendingPathComponent("Main"))
        try body(root, bytes)
    }
    func testCapturedHelpersAndOutsideSymlinksAreIndependent() throws {
        try fixture { root, bytes in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
            try bytes.write(to: root.appendingPathComponent("Helpers/Worker"))
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Outside").path, withDestinationPath: "/does-not-exist-outside-tree")
            let parsed = try MachOParser().parse(bytes)
            let facts = REANativeApplicationProjection.sliceFacts(path: "Main", machO: parsed, physicalFileSize: UInt64(bytes.count), selectedSliceSize: nil).facts
            let capture = try REANativeApplicationCapture.capture(rootURL: root, selectedBinary: binary(bytes), selectedRelativePath: "Main", selectedFacts: facts)
            XCTAssertEqual(capture.roots, ["Main", "Helpers/Worker"])
            XCTAssertEqual(capture.entries.first { $0.path == "Outside" }?.target, "/does-not-exist-outside-tree")
            XCTAssertEqual(capture.images.count, 2)
            XCTAssertTrue(capture.entries.first { $0.path == "Main" }?.component?.artifact_id.hasPrefix("art_") == true)
        }
    }
    func testChangedSelectedBytesAndIncompleteBudgetReject() throws {
        try fixture { root, bytes in
            XCTAssertThrowsError(try REANativeApplicationCapture.capture(rootURL: root, selectedBinary: binary(Data()), selectedRelativePath: "Main", selectedFacts: .unsupported("test")))
            var limits = REANativeApplicationCapture.Limits(); limits.maximumEntries = 0
            XCTAssertThrowsError(try REANativeApplicationCapture.capture(rootURL: root, selectedBinary: binary(bytes), selectedRelativePath: "Main", selectedFacts: .unsupported("test"), limits: limits))
        }
    }
}
