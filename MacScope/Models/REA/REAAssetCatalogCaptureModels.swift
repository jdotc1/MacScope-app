import CryptoKit
import Darwin
import Foundation

struct REAAssetCatalogCaptureRequest: Codable, Equatable, Sendable {
    let requestID: UUID
    let sessionID: UUID
    let captureID: UUID
    let stageRootPath: String
    let relativePath: String
    let targetSHA256: String
    let snapshotID: String
    let catalogSHA256: String
    let catalogByteCount: UInt64
    let toolSHA256: String
    let runnerSHA256: String
    var isValid: Bool {
        MacScopeWorkRoot.contains(stageRootPath) && stageRootPath.utf8.count <= 3000
        && !snapshotID.isEmpty && snapshotID.utf8.count <= 256
        && !relativePath.isEmpty && relativePath.utf8.count <= 4096 && !relativePath.hasPrefix("/") && !relativePath.contains("\\") && !relativePath.contains("\0")
        && relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        && catalogByteCount > 0 && catalogByteCount <= 67_108_864
        && [targetSHA256,catalogSHA256,toolSHA256,runnerSHA256].allSatisfy(REAAssetCatalogAuthority.isDigest)
    }
}
struct REAAssetCatalogCaptureResponse: Codable, Equatable, Sendable {
    let request: REAAssetCatalogCaptureRequest
    let receiptID: UUID
    let metadata: Data
    let metadataSHA256: String
    let failure: String?
    let terminal: Phase2SourceExecutionTerminal?
    let cleanup: Phase2SourceExecutionCleanup?
    let elapsedSeconds: Double
    var isAccepted: Bool {
        request.isValid && failure == nil && metadata.count <= 8_388_608 && !metadata.isEmpty
        && REAAssetCatalogAuthority.digest(metadata) == metadataSHA256
        && terminal?.kind == .exited && terminal?.status == 0
        && cleanup?.sessionID == request.sessionID && cleanup?.requestID == request.requestID
        && cleanup?.observedProcessAbsent == true && (cleanup?.processIdentifier ?? 0) > 1 && cleanup?.outcome == terminal
        && elapsedSeconds.isFinite && elapsedSeconds >= 0 && elapsedSeconds <= 12
    }
    static func rejected(_ request: REAAssetCatalogCaptureRequest, _ reason: String) -> Self {
        .init(request:request,receiptID:UUID(),metadata:Data(),metadataSHA256:REAAssetCatalogAuthority.digest(Data()),failure:reason,terminal:nil,cleanup:nil,elapsedSeconds:0)
    }
}
enum REAAssetCatalogAuthority {
    enum Failure: Error { case invalidInput, changedIdentity, budget }
    static func isDigest(_ text: String) -> Bool { text.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]; return try encoder.encode(value) }
    static func bytes(_ path: String, maximum: Int, owner: uid_t, readOnly: Bool = true) throws -> Data {
        guard URL(fileURLWithPath:path).resolvingSymlinksInPath().path == path else { throw Failure.invalidInput }
        let fd = open(path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.invalidInput }; defer { close(fd) }
        var before = stat()
        guard fstat(fd,&before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == owner,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= Int64(maximum), !readOnly || before.st_mode & 0o222 == 0 else { throw Failure.invalidInput }
        var data = Data(), buffer = [UInt8](repeating:0,count:65536)
        while true { let n = read(fd,&buffer,buffer.count); guard n >= 0 else { throw Failure.invalidInput }; if n == 0 { break }; guard n <= maximum-data.count else { throw Failure.budget }; data.append(contentsOf:buffer.prefix(n)) }
        var after = stat()
        guard fstat(fd,&after) == 0, after.st_size == before.st_size, data.count == Int(after.st_size),
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw Failure.changedIdentity }
        return data
    }
    static func metadataJSON(_ data: Data) throws -> Any {
        guard !data.isEmpty, data.count <= 8_388_608 else { throw Failure.budget }
        var quoted = false, escaped = false, depth = 0, fields = 0
        for byte in data {
            if quoted {
                if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; fields += 1 }
            else if byte == 125 || byte == 93 { depth -= 1 }
            else if byte == 44 || byte == 58 { fields += 1 }
            guard depth >= 0, depth <= 64, fields <= 100_000 else { throw Failure.budget }
        }
        let value = try JSONSerialization.jsonObject(with:data)
        guard JSONSerialization.isValidJSONObject(value) else { throw Failure.invalidInput }
        return value
    }
    static func verify(_ request: REAAssetCatalogCaptureRequest) throws {
        guard request.isValid, URL(fileURLWithPath:request.stageRootPath).resolvingSymlinksInPath().path == request.stageRootPath else { throw Failure.invalidInput }
        var root = stat(); guard lstat(request.stageRootPath,&root) == 0, root.st_mode & S_IFMT == S_IFDIR, root.st_uid == getuid(), root.st_mode & 0o777 == 0o700 else { throw Failure.invalidInput }
        let catalog = try bytes(request.stageRootPath + "/catalog.car",maximum:67_108_864,owner:getuid())
        guard UInt64(catalog.count) == request.catalogByteCount, digest(catalog) == request.catalogSHA256,
              digest(try bytes("/usr/bin/assetutil",maximum:67_108_864,owner:0,readOnly:false)) == request.toolSHA256 else { throw Failure.changedIdentity }
    }
}
