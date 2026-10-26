import CryptoKit
import Darwin
import Foundation

extension REAUIResourceCapture {
    struct Limits: Sendable {
        var maximumEntries = 20_000
        var maximumDocuments = 64
        var maximumArchiveBytes = 4 * 1024 * 1024
        var maximumTotalBytes = 8 * 1024 * 1024
        static let `default` = Limits()
    }
    struct Batch: Sendable {
        let documents: [REAUIResourceCapture]
        let omittedDocuments: Int
        /// Original file identities survive normalization to keyedArchiveJSON.
        let originalArchiveSHA256ByPath: [String: String]
        let catalogMetadataAvailable = false
    }
    enum CaptureFailure: Error { case unsafeRoot, io, changedDuringCapture, inventoryBudget, invalidBinding }
    static func acquire(rootURL: URL, selectedImage: LoadedBinary, snapshotID: String, limits: Limits = .default) throws -> Batch {
        guard !snapshotID.isEmpty, snapshotID.utf8.count <= 256,
              limits.maximumEntries >= 0, limits.maximumEntries <= 20_000,
              limits.maximumDocuments >= 0, limits.maximumDocuments <= 64,
              limits.maximumArchiveBytes >= 0, limits.maximumArchiveBytes <= 4 * 1024 * 1024,
              limits.maximumTotalBytes >= 0, limits.maximumTotalBytes <= 8 * 1024 * 1024 else { throw CaptureFailure.invalidBinding }
        let target = try REAUIResourceProjection.selectedSliceSHA256(selectedImage)
        let root = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw CaptureFailure.unsafeRoot }
        defer { close(root) }
        var documents: [REAUIResourceCapture] = [], omitted = 0, entries = 0, total = 0, projectedTotal = 0
        var originalHashes: [String: String] = [:]
        func walk(_ directory: Int32, _ prefix: String) throws {
            var beforeDirectory = stat()
            guard fstat(directory, &beforeDirectory) == 0, let stream = fdopendir(dup(directory)) else { throw CaptureFailure.io }
            defer { closedir(stream) }
            var names: [String] = []
            errno = 0
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name != "." && name != ".." { names.append(name) }
                guard entries + names.count <= limits.maximumEntries else { throw CaptureFailure.inventoryBudget }
                errno = 0
            }
            guard errno == 0 else { throw CaptureFailure.io }
            for name in names.sorted() {
                entries += 1
                guard entries <= limits.maximumEntries else { throw CaptureFailure.inventoryBudget }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard REANativeApplicationProjection.validPath(path) else { throw CaptureFailure.io }
                var before = stat()
                guard fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw CaptureFailure.io }
                let kind = before.st_mode & mode_t(S_IFMT)
                let candidate = name.lowercased().hasSuffix(".nib") || name.lowercased().hasSuffix(".storyboardc")
                if kind == mode_t(S_IFDIR) {
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw CaptureFailure.changedDuringCapture }
                    defer { close(child) }
                    let examinedBefore = documents.count + omitted
                    try walk(child, path)
                    if candidate && documents.count + omitted == examinedBefore { omitted += 1 }
                } else if kind == mode_t(S_IFLNK) {
                    if candidate { omitted += 1 }
                } else if kind == mode_t(S_IFREG), candidate {
                    guard documents.count < limits.maximumDocuments, before.st_size >= 0,
                          before.st_size <= Int64(limits.maximumArchiveBytes), before.st_size <= Int64(limits.maximumTotalBytes - total) else { omitted += 1; continue }
                    let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    guard file >= 0 else { throw CaptureFailure.changedDuringCapture }
                    defer { close(file) }
                    var opened = stat()
                    guard fstat(file, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
                          opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw CaptureFailure.changedDuringCapture }
                    var data = Data(); var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    while true {
                        let count = read(file, &buffer, buffer.count)
                        guard count >= 0 else { throw CaptureFailure.io }
                        if count == 0 { break }
                        guard count <= limits.maximumArchiveBytes - data.count, count <= limits.maximumTotalBytes - total else { throw CaptureFailure.inventoryBudget }
                        data.append(contentsOf: buffer.prefix(count)); total += count
                    }
                    var after = stat()
                    guard fstat(file, &after) == 0, opened.st_size == after.st_size, data.count == Int(after.st_size),
                          opened.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, opened.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw CaptureFailure.changedDuringCapture }
                    originalHashes[path] = captureDigest(data)
                    if let decoded = try? decodedArchive(data), decoded.bytes.count <= limits.maximumArchiveBytes,
                       decoded.bytes.count <= limits.maximumTotalBytes - projectedTotal {
                        projectedTotal += decoded.bytes.count
                        let documentKind: REAUIResourceDocument.Kind = path.split(separator: "/").contains { $0.lowercased().hasSuffix(".storyboardc") } ? .storyboard_scene : .nib
                        documents.append(.init(targetSHA256: target, snapshotID: snapshotID, relativePath: path,
                            archiveSHA256: captureDigest(decoded.bytes), kind: documentKind, format: decoded.format, bytes: decoded.bytes))
                    } else { omitted += 1 }
                }
                var current = stat()
                guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_dev == before.st_dev, current.st_ino == before.st_ino, current.st_mode == before.st_mode else { throw CaptureFailure.changedDuringCapture }
            }
            var afterDirectory = stat()
            guard fstat(directory, &afterDirectory) == 0,
                  beforeDirectory.st_mtimespec.tv_sec == afterDirectory.st_mtimespec.tv_sec,
                  beforeDirectory.st_mtimespec.tv_nsec == afterDirectory.st_mtimespec.tv_nsec else { throw CaptureFailure.changedDuringCapture }
        }
        try walk(root, "")
        return Batch(documents: documents, omittedDocuments: omitted, originalArchiveSHA256ByPath: originalHashes)
    }
    private static func captureDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// Foundation parses property-list containers only; archived classes are never instantiated.
    static func decodedArchive(_ data: Data) throws -> (bytes: Data, format: REAUIResourceDocument.Format) {
        if data.starts(with: Data("NIBArchive".utf8)) { return (data, .nibArchive) }
        if data.starts(with: Data("bplist".utf8)), data.count >= 32 {
            let countBytes = data.suffix(24).prefix(8)
            let objects = countBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard objects <= 20_000 else { throw CaptureFailure.inventoryBudget }
        }
        var value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        if !JSONSerialization.isValidJSONObject(value) {
            // Public plist XML representation exposes supported UID records as CF$UID dictionaries.
            let xml = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            value = try PropertyListSerialization.propertyList(from: xml, options: [], format: nil)
        }
        guard let archive = value as? [String: Any], archive["$archiver"] as? String == "NSKeyedArchiver",
              archive["$objects"] is [Any], let top = archive["$top"] as? [String: Any], !top.isEmpty,
              JSONSerialization.isValidJSONObject(archive) else { throw CaptureFailure.io }
        let json = try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys, .withoutEscapingSlashes])
        return (json, .keyedArchiveJSON)
    }
}
