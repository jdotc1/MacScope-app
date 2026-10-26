import CryptoKit
import Foundation

/// Owned temporary text spool shared by the whole-image pseudocode exports. Writes go straight to
/// disk; nothing retains complete texts.
protocol PseudocodeExportSink: AnyObject, Sendable {
    var textURL: URL { get }
    func append(_ data: Data) throws
    /// Closes the file and returns the SHA-256 (lowercase hex) of everything appended.
    func finish() throws -> String
    /// Removes every byte this sink owns. Safe to call more than once.
    func remove()
}

final class PseudocodeExportSpool: PseudocodeExportSink, @unchecked Sendable {
    let directory: URL
    let textURL: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private var hasher = SHA256()

    init(parent: URL = FileManager.default.temporaryDirectory, prefix: String = "MacScope-export") throws {
        directory = parent.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        textURL = directory.appendingPathComponent("pseudocode.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: textURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: textURL)
    }

    func append(_ data: Data) throws {
        try lock.withLock {
            guard let handle else { throw CocoaError(.fileWriteUnknown) }
            try handle.write(contentsOf: data)
            hasher.update(data: data)
        }
    }

    func finish() throws -> String {
        try lock.withLock {
            guard let handle else { throw CocoaError(.fileWriteUnknown) }
            try handle.synchronize()
            try handle.close()
            self.handle = nil
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    func remove() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { remove() }
}

/// Atomic publication of finished spools: stage on the destination's volume, then replace.
enum PseudocodeExportPublication {
    /// Runs `body` with a fresh replacement directory on `destination`'s volume and removes it after.
    static func withStaging<T>(for destination: URL, fileManager: FileManager,
                               _ body: (URL) throws -> T) throws -> T {
        let staging = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: destination, create: true)
        defer { try? fileManager.removeItem(at: staging) }
        return try body(staging)
    }

    /// Moves `staged` to `destination`, atomically replacing any file there. With `backupName`, a
    /// prior file is kept under that name beside `destination`. Returns whether a prior file existed.
    @discardableResult
    static func commit(_ staged: URL, to destination: URL, backupName: String? = nil,
                       fileManager: FileManager) throws -> Bool {
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.moveItem(at: staged, to: destination)
            return false
        }
        if let backupName {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged, backupItemName: backupName,
                                              options: .withoutDeletingBackupItem)
        } else {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        }
        return true
    }
}
