import CryptoKit
import Darwin
import Foundation

/// Bounded snapshot acquisition. Descriptor-relative traversal never follows tree symlinks.
enum REANativeApplicationCapture {
    struct Limits: Sendable {
        var maximumEntries = 20_000
        var maximumImages = 2048
        var maximumFileBytes = 64 * 1024 * 1024
        var maximumTotalBytes = 256 * 1024 * 1024
        static let `default` = Limits()
    }
    enum Failure: Error { case unsafeRoot, io, changedDuringCapture, budget, selectedIdentityMismatch, selectedMissing }
    static func capture(rootURL: URL, selectedBinary: LoadedBinary, selectedRelativePath: String,
                        selectedFacts: REANativeImageFacts, limits: Limits = .default) throws -> REANativeApplicationInput {
        guard limits.maximumEntries >= 0, limits.maximumEntries <= 20_000, limits.maximumImages >= 0, limits.maximumImages <= 2048,
              limits.maximumFileBytes >= 0, limits.maximumFileBytes <= 128 * 1024 * 1024,
              limits.maximumTotalBytes >= 0, limits.maximumTotalBytes <= 512 * 1024 * 1024 else { throw Failure.budget }
        let root = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw Failure.unsafeRoot }
        defer { close(root) }
        var entries: [REANativeEntry] = []
        var images: [REANativeImage] = []
        var roots: [String] = []
        var total = 0
        var selectedSeen = false
        func walk(_ directory: Int32, _ prefix: String) throws {
            var directoryBefore = stat()
            guard fstat(directory, &directoryBefore) == 0 else { throw Failure.io }
            guard let stream = fdopendir(dup(directory)) else { throw Failure.io }
            defer { closedir(stream) }
            var names: [String] = []
            errno = 0
            while let item = readdir(stream) {
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name != "." && name != ".." { names.append(name) }
                guard names.count + entries.count <= limits.maximumEntries else { throw Failure.budget }
                errno = 0
            }
            guard errno == 0 else { throw Failure.io }
            for name in names.sorted() {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard REANativeApplicationProjection.validPath(path), entries.count < limits.maximumEntries else { throw Failure.budget }
                var before = stat()
                guard fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.io }
                let kind = before.st_mode & mode_t(S_IFMT)
                if kind == mode_t(S_IFLNK) {
                    var bytes = [CChar](repeating: 0, count: 4097)
                    let count = readlinkat(directory, name, &bytes, bytes.count)
                    guard count >= 0, count <= 4096 else { throw Failure.budget }
                    let target = String(decoding: bytes.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    entries.append(.init(path: path, kind: .symlink, target: target))
                } else if kind == mode_t(S_IFDIR) {
                    let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw Failure.changedDuringCapture }
                    defer { close(child) }
                    entries.append(.init(path: path, kind: .directory))
                    try walk(child, path)
                } else if kind == mode_t(S_IFREG) {
                    guard before.st_size >= 0, before.st_size <= Int64(limits.maximumFileBytes),
                          before.st_size <= Int64(limits.maximumTotalBytes - total) else { throw Failure.budget }
                    let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    guard file >= 0 else { throw Failure.changedDuringCapture }
                    defer { close(file) }
                    var opened = stat()
                    guard fstat(file, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
                          opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.changedDuringCapture }
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    while true {
                        let count = read(file, &buffer, buffer.count)
                        guard count >= 0 else { throw Failure.io }
                        if count == 0 { break }
                        guard count <= limits.maximumFileBytes - data.count, count <= limits.maximumTotalBytes - total else { throw Failure.budget }
                        data.append(contentsOf: buffer.prefix(count)); total += count
                    }
                    var after = stat()
                    guard fstat(file, &after) == 0, after.st_size == opened.st_size,
                          after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
                          after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec,
                          data.count == Int(opened.st_size) else { throw Failure.changedDuringCapture }
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    let isMachO = machoMagic(data)
                    entries.append(.init(path: path, kind: .file, component: .init(path: path, artifact_id: "art_" + digest,
                        sha256: digest, format: isMachO ? "mach-o" : "unknown")))
                    if path == selectedRelativePath {
                        guard data == selectedBinary.bytes else { throw Failure.selectedIdentityMismatch }
                        selectedSeen = true; images.append(.init(path: path, facts: selectedFacts)); roots.insert(path, at: 0)
                    } else if isMachO {
                        guard images.count < limits.maximumImages else { throw Failure.budget }
                        do {
                            let parsed = try MachOParser().parse(data, options: .init(recoverStringLiterals: false, recoverObjectiveCMetadata: false, recoverSwiftMetadata: false, parseCodeSignature: false))
                            let image = REANativeApplicationProjection.sliceFacts(path: path, machO: parsed, physicalFileSize: UInt64(data.count), selectedSliceSize: parsed.universalBinary?.selectedSlice?.size)
                            images.append(image)
                            if parsed.header.fileType == 2 { roots.append(path) }
                        } catch MachOParserError.unsupportedMagic {
                            images.append(.init(path: path, facts: .unsupported("Mach-O encoding not supported by the authoritative loader")))
                        } catch { images.append(.init(path: path, facts: .malformed(String(describing: error)))) }
                    }
                } else { throw Failure.io }
                var current = stat()
                guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_dev == before.st_dev, current.st_ino == before.st_ino,
                      current.st_mode == before.st_mode else { throw Failure.changedDuringCapture }
            }
            var directoryAfter = stat()
            guard fstat(directory, &directoryAfter) == 0, directoryBefore.st_mtimespec.tv_sec == directoryAfter.st_mtimespec.tv_sec,
                  directoryBefore.st_mtimespec.tv_nsec == directoryAfter.st_mtimespec.tv_nsec else { throw Failure.changedDuringCapture }
        }
        try walk(root, "")
        guard selectedSeen else { throw Failure.selectedMissing }
        return try REANativeApplicationProjection.project(subject: .init(name: rootURL.lastPathComponent, format: "directory"),
            entries: entries, images: images, roots: roots, architecture: nil, inventoryComplete: true)
    }
    private static func machoMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = Array(data.prefix(4))
        return [[0xcf,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf], [0xce,0xfa,0xed,0xfe],
                [0xfe,0xed,0xfa,0xce], [0xca,0xfe,0xba,0xbe], [0xca,0xfe,0xba,0xbf],
                [0xbe,0xba,0xfe,0xca], [0xbf,0xba,0xfe,0xca]].contains(bytes.map(Int.init))
    }
}
