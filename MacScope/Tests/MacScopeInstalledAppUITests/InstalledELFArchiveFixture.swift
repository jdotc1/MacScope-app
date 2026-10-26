import CryptoKit
import Foundation

/// Deterministic installed-product input for the archive member picker. The fixture is generated
/// inside the opted-in XCUITest runner, never inside the app, and its complete outer bytes are
/// pinned before use so the test cannot silently drift with a helper change.
struct InstalledELFArchiveFixture {
    static let firstMemberName = "first.o"
    static let selectedMemberName = "second.o"
    static let selectedEntryPointAddress = "0x1000"
    static let selectedEntryPointMnemonic = "nop"
    static let unselectedEntryPointMnemonic = "ret"
    static let expectedArchiveSHA256 =
        "5a282f033a1a149866689aa39f09128a2e6a57fa0c1051d30dff6fc410770347"

    let directoryURL: URL
    let archiveURL: URL

    static func create() throws -> Self {
        let bytes = try makeArchive()
        let observedSHA256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard observedSHA256 == expectedArchiveSHA256 else {
            throw NSError(
                domain: "MacScopeInstalledAppUITests.InstalledELFArchiveFixture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Installed ELF archive fixture identity drifted: \(observedSHA256)"]
            )
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-Installed-ELF-Archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let archiveURL = directoryURL.appendingPathComponent("installed-two-member.a")
        try bytes.write(to: archiveURL, options: [.atomic])
        return Self(directoryURL: directoryURL, archiveURL: archiveURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private static func makeArchive() throws -> Data {
        let members = [
            ("\(firstMemberName)/", makeMinimalELF(marker: 0xc3)), // x86_64 `ret`
            ("\(selectedMemberName)/", makeMinimalELF(marker: 0x90)), // x86_64 `nop`
        ]
        var result = Data("!<arch>\n".utf8)
        for (name, payload) in members {
            let header = archiveHeader(name: name, byteCount: payload.count)
            guard header.utf8.count == 60 else {
                throw NSError(
                    domain: "MacScopeInstalledAppUITests.InstalledELFArchiveFixture",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Archive fixture header is not 60 bytes."]
                )
            }
            result.append(contentsOf: header.utf8)
            result.append(payload)
            if !payload.count.isMultiple(of: 2) { result.append(0x0a) }
        }
        return result
    }

    private static func archiveHeader(name: String, byteCount: Int) -> String {
        name.padding(toLength: 16, withPad: " ", startingAt: 0)
            + "0".padding(toLength: 12, withPad: " ", startingAt: 0)
            + "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            + "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            + "100644".padding(toLength: 8, withPad: " ", startingAt: 0)
            + String(byteCount).padding(toLength: 10, withPad: " ", startingAt: 0)
            + "`\n"
    }

    /// Sectionless ELF64 ET_EXEC with one executable PT_LOAD. The two members differ in their
    /// entry bytes, so selecting by display name cannot accidentally alias identical input.
    private static func makeMinimalELF(marker: UInt8) -> Data {
        var data = Data(repeating: 0, count: 0x1004)
        data.replaceSubrange(
            0..<16,
            with: [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0] + [UInt8](repeating: 0, count: 8)
        )
        data.writeLittleEndian(UInt16(2), at: 16)
        data.writeLittleEndian(UInt16(62), at: 18)
        data.writeLittleEndian(UInt32(1), at: 20)
        data.writeLittleEndian(UInt64(0x1000), at: 24)
        data.writeLittleEndian(UInt64(64), at: 32)
        data.writeLittleEndian(UInt64(0), at: 40)
        data.writeLittleEndian(UInt16(64), at: 52)
        data.writeLittleEndian(UInt16(56), at: 54)
        data.writeLittleEndian(UInt16(1), at: 56)
        data.writeLittleEndian(UInt32(1), at: 64)
        data.writeLittleEndian(UInt32(5), at: 68)
        data.writeLittleEndian(UInt64(0x1000), at: 72)
        data.writeLittleEndian(UInt64(0x1000), at: 80)
        data.writeLittleEndian(UInt64(0x1000), at: 88)
        data.writeLittleEndian(UInt64(4), at: 96)
        data.writeLittleEndian(UInt64(4), at: 104)
        data.writeLittleEndian(UInt64(0x1000), at: 112)
        data.replaceSubrange(0x1000..<0x1004, with: [marker, 0, 0, 0])
        return data
    }
}

private extension Data {
    mutating func writeLittleEndian<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        let bytes = (0..<MemoryLayout<T>.size).map {
            UInt8(truncatingIfNeeded: value >> T($0 * 8))
        }
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
