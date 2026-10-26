import Foundation
import Darwin

/// Immutable stage input attestation shared by admission and post-execution verification.
/// No capture capability is inferred from the fixed C reconstruction harness.
enum REAScenarioCapture {
    enum Failure: Error { case invalidInput, identityChanged, budgetExceeded }
    struct InputFile: Codable, Equatable, Sendable { let kind: String; let path: String; let sha256: String; let byteCount: UInt64 }
    static func nulBytes(_ values: [String]) -> Data { Data(values.flatMap { Array($0.utf8) + [0] }) }
    static func environmentBytes(_ values: [String: String]) -> Data {
        nulBytes(values.keys.sorted().compactMap { key in values[key].map { key + "=" + $0 } })
    }
    static func fileBytes(_ path: String, maximum: Int, executable: Bool = false, readOnly: Bool = true) throws -> Data {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.invalidInput }; defer { close(fd) }
        var before = stat(), after = stat(), current = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_mode & (readOnly ? 0o222 : 0o022) == 0,
              !executable || before.st_mode & 0o100 != 0,
              before.st_size >= 0, before.st_size <= maximum else { throw Failure.invalidInput }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw Failure.invalidInput }; if n == 0 { break }
            guard data.count + n <= maximum else { throw Failure.budgetExceeded }
            data.append(contentsOf: buffer.prefix(n))
        }
        guard fstat(fd, &after) == 0, lstat(path, &current) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              after.st_dev == current.st_dev, after.st_ino == current.st_ino,
              before.st_size == data.count, after.st_size == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.identityChanged }
        return data
    }
    static func verify(_ request: REAScenarioCaptureRequest) throws -> String {
        guard request.isValid else { throw Failure.invalidInput }
        let root = URL(fileURLWithPath: request.stageRootPath, isDirectory: true)
        guard root.standardizedFileURL.path == root.path, root.resolvingSymlinksInPath().path == root.path else { throw Failure.invalidInput }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw Failure.invalidInput }
        let executable = try fileBytes(root.appendingPathComponent("executable").path, maximum: 16_777_216, executable: true)
        guard executable.count == request.executableByteCount, REACaptureCommitment.digest(executable) == request.executableSHA256,
              try fileBytes(root.appendingPathComponent("arguments.bin").path, maximum: 65536) == nulBytes(request.scenario.arguments),
              try fileBytes(root.appendingPathComponent("environment.bin").path, maximum: 65536) == environmentBytes(request.scenario.environment),
              try fileBytes(root.appendingPathComponent("working-directory.bin").path, maximum: 4096) == Data(request.scenario.workingDirectory.utf8) else { throw Failure.invalidInput }
        let input = root.appendingPathComponent("input", isDirectory: true)
        let files = try inputTree(input)
        let tree = try REACaptureCommitment.sha256(files)
        guard tree == request.scenario.inputTreeSHA256 else { throw Failure.invalidInput }
        let working = input.appendingPathComponent(request.scenario.workingDirectory, isDirectory: true)
        guard working.resolvingSymlinksInPath().path == working.standardizedFileURL.path,
              lstat(working.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalidInput }
        return tree
    }
    static func inputTree(_ root: URL) throws -> [InputFile] {
        var result: [InputFile] = [], total = 0
        func visit(_ url: URL, _ relative: String, _ depth: Int) throws {
            guard depth <= 16, result.count <= 1024 else { throw Failure.budgetExceeded }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o222 == 0 else { throw Failure.invalidInput }
            if info.st_mode & S_IFMT == S_IFDIR {
                if !relative.isEmpty {
                    guard result.count < 1024 else { throw Failure.budgetExceeded }
                    result.append(.init(kind: "directory", path: relative, sha256: REACaptureCommitment.digest(Data()), byteCount: 0))
                }
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                    try visit(url.appendingPathComponent(name), relative.isEmpty ? name : relative + "/" + name, depth + 1)
                }
            } else {
                guard info.st_mode & S_IFMT == S_IFREG, REAProcessScenario.safeRelative(relative), result.count < 1024 else { throw Failure.invalidInput }
                let bytes = try fileBytes(url.path, maximum: 1_048_576)
                total += bytes.count; guard total <= 16_777_216 else { throw Failure.budgetExceeded }
                result.append(.init(kind: "file", path: relative, sha256: REACaptureCommitment.digest(bytes), byteCount: UInt64(bytes.count)))
            }
        }
        try visit(root, "", 0); return result.sorted { $0.path < $1.path }
    }
}
