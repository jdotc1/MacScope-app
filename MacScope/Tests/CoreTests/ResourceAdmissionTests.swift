import Foundation
import XCTest
@testable import MacScope

final class ResourceAdmissionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = TestWorkRoot.scratchURL(".admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func read(_ root: URL, _ paths: [String]) throws -> [AppKitResourceLease] {
        try AppKitResourceAdmission().read(bundleRoot: root, bundleID: "fixture",
            bundleGeneration: "g1", relativePaths: paths)
    }

    func testLeasePreservesExactBytesAndStableDigest() throws {
        let root = try directory()
        let data = Data("NIBArchive-test".utf8)
        try data.write(to: root.appendingPathComponent("Main.nib"))
        let lease = try XCTUnwrap(read(root, ["Main.nib"]).first)
        XCTAssertEqual(lease.bytes, data)
        XCTAssertTrue(lease.resource.hasValidIdentity)
        XCTAssertEqual(lease.resource.contentSHA256,
            "f20bbe1da8993ed4ea9e6461eac1ddfece797c701d056b63aca010a1dc3879a2")
    }

    func testTraversalRefusedBeforeOpen() throws {
        let root = try directory()
        XCTAssertThrowsError(try read(root, ["../Main.nib"])) {
            XCTAssertEqual($0 as? AppKitAdmissionError, .invalidPath)
        }
    }

    func testSymlinkFileAndIntermediateDirectoryRefused() throws {
        let root = try directory()
        let outside = try directory()
        try Data("NIBArchive-test".utf8).write(to: outside.appendingPathComponent("Main.nib"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias.nib"),
            withDestinationURL: outside.appendingPathComponent("Main.nib"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked"),
            withDestinationURL: outside)
        XCTAssertThrowsError(try read(root, ["Alias.nib"]))
        XCTAssertThrowsError(try read(root, ["Linked/Main.nib"]))
    }

    func testOversizeUnsupportedAndDirectoryInputsRefused() throws {
        let root = try directory()
        let big = root.appendingPathComponent("Big.nib")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 8 * 1024 * 1024 + 1)
        try handle.close()
        XCTAssertThrowsError(try read(root, ["Big.nib"])) {
            XCTAssertEqual($0 as? AppKitAdmissionError, .byteLimit)
        }
        try Data("plain text".utf8).write(to: root.appendingPathComponent("Bad.nib"))
        XCTAssertThrowsError(try read(root, ["Bad.nib"])) {
            XCTAssertEqual($0 as? AppKitAdmissionError, .unsupportedFormat)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Dir.nib"),
            withIntermediateDirectories: false)
        XCTAssertThrowsError(try read(root, ["Dir.nib"])) {
            XCTAssertEqual($0 as? AppKitAdmissionError, .notRegular)
        }
    }

    func testResourceAndCaseCollisionBudgets() throws {
        let root = try directory()
        XCTAssertThrowsError(try read(root, (0...256).map { "\($0).nib" })) {
            XCTAssertEqual($0 as? AppKitAdmissionError, .resourceLimit)
        }
        XCTAssertThrowsError(try read(root, ["Main.nib", "MAIN.nib"])) {
            XCTAssertEqual($0 as? AppKitAdmissionError, .duplicatePath)
        }
    }
}
