import Foundation
import XCTest
@testable import MacScope

/// D07 signed-file append: a patched or cave-appended signed arm64 executable is re-signed ad hoc
/// in process and runs. Real witness: a clang-built executable (classic dyld info, which the cave
/// writer supports), signed by `codesign` with entitlements as the input.
final class MachOAdHocSignerTests: XCTestCase {
    private func tool(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let drain = CoreTestPipeDrain(pipe)
        process.waitUntilExit()
        return (process.terminationStatus, drain.text())
    }

    private func run(_ url: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = url
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// `int main(void) { return 0; }` built for arm64 and signed with `entitlements`.
    private func signedWitness(entitlements: [String: Any]) throws -> (url: URL, data: Data, main: UInt64) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { throw XCTSkip("xcrun unavailable") }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-adhoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("t.c"), binary = directory.appendingPathComponent("t")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let built = try tool(["clang", "-arch", "arm64", "-O2", "-Wl,-no_fixup_chains", "-Wl,-headerpad,0x4000", "-o", binary.path, source.path])
        guard built.status == 0 else { throw XCTSkip("clang did not build the witness: \(built.output)") }
        let plist = directory.appendingPathComponent("e.plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: plist)
        let signed = try tool(["codesign", "-f", "-s", "-", "--entitlements", plist.path, binary.path])
        XCTAssertEqual(signed.status, 0, signed.output)
        let symbols = try tool(["nm", binary.path])
        let line = try XCTUnwrap(symbols.output.split(separator: "\n").first { $0.hasSuffix(" _main") })
        let main = try XCTUnwrap(UInt64(line.split(separator: " ")[0], radix: 16))
        return (binary, try Data(contentsOf: binary), main)
    }

    private func write(_ data: Data, as name: String, near url: URL) throws -> URL {
        let output = url.deletingLastPathComponent().appendingPathComponent(name)
        try data.write(to: output)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
        return output
    }

    func testPatchedAndCaveAppendedWitnessesAreAdHocSignedAndRun() throws {
        let witness = try signedWitness(entitlements: ["com.apple.security.get-task-allow": true])
        XCTAssertEqual(try run(witness.url), 0)
        // Byte patch: main's `mov w0, #0` becomes `mov w0, #3`.
        let fileOffset = Int(witness.main - 0x1_0000_0000)
        let bytes = [UInt8](witness.data)
        let mov = try XCTUnwrap((fileOffset ..< fileOffset + 16).first { bytes[$0 ..< $0 + 4] == [0x00, 0x00, 0x80, 0x52] })
        let patched = try MachOPatchWriter().makePatchedData(
            originalData: witness.data,
            patches: [UInt64(mov) + 0x1_0000_0000: BytePatch(bytes: [0x60, 0x00, 0x80, 0x52])])
        let outcome = try MachOAdHocSigner.resign(patched)
        XCTAssertTrue(outcome.restrictedEntitlements.isEmpty)
        let patchedURL = try write(outcome.data, as: "patched", near: witness.url)
        let verify = try tool(["codesign", "--verify", "--strict", "--verbose=2", patchedURL.path])
        XCTAssertEqual(verify.status, 0, verify.output)
        let display = try tool(["codesign", "-d", "--entitlements", "-", "--verbose=2", patchedURL.path])
        XCTAssertTrue(display.output.contains("flags=0x2(adhoc)") || display.output.contains("adhoc"), display.output)
        XCTAssertTrue(display.output.contains("get-task-allow"), "entitlements carried over\n\(display.output)")
        XCTAssertEqual(try run(patchedURL), 3, "the patch runs")
        XCTAssertNotEqual(try run(write(patched, as: "unsigned", near: witness.url)), 3,
                          "control: the copied signature is invalid without re-signing")

        // Appended cave: main branches to a cave that returns 5.
        let cave = Data([0xa0, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]) // mov w0, #5; ret
        let appended = try MachOPatchWriter().makePatchedDataWithAppendedExecutableCave(
            originalData: witness.data, patches: [:], caveBytes: cave, branchSourceAddress: witness.main)
        let caveURL = try write(try MachOAdHocSigner.resign(appended.data).data, as: "cave", near: witness.url)
        let caveVerify = try tool(["codesign", "--verify", "--strict", caveURL.path])
        XCTAssertEqual(caveVerify.status, 0, caveVerify.output)
        XCTAssertEqual(try run(caveURL), 5, "the appended cave runs")
    }

    func testRestrictedEntitlementsAreReportedAndUnsignedInputsRefused() throws {
        let witness = try signedWitness(entitlements: [
            "com.apple.security.get-task-allow": true,
            "com.apple.developer.icloud-container-identifiers": ["iCloud.example"],
            "keychain-access-groups": ["TEAM.example"],
        ])
        let outcome = try MachOAdHocSigner.resign(witness.data)
        XCTAssertEqual(outcome.restrictedEntitlements,
                       ["com.apple.developer.icloud-container-identifiers", "keychain-access-groups"])
        XCTAssertEqual(outcome.warnings.count, 1)
        XCTAssertTrue(outcome.warnings[0].contains("may refuse to launch"))
        XCTAssertThrowsError(try MachOAdHocSigner.resign(MachOFixture.makeExecutable().bytes))
    }
}
