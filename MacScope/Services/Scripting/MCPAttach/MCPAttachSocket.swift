import CryptoKit
import Darwin
import Foundation

enum MCPAttachSocketError: LocalizedError, Equatable {
    case pathTooLong
    case directoryUnsafe(String)
    case endpointOwnedElsewhere
    case system(String, Int32)
    case notListening
    case handshakeFailed(String)

    var errorDescription: String? {
        switch self {
        case .pathTooLong: "The MCP attach socket path is too long."
        case .directoryUnsafe(let reason): "The MCP attach directory is unsafe (\(reason)); fix or remove it and turn agent attach on again."
        case .endpointOwnedElsewhere: "Another MacScope instance already accepts agent connections."
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))."
        case .notListening: "MacScope isn't accepting agent connections. Open MacScope and turn on Settings ▸ Plugins ▸ Allow agents to attach."
        case .handshakeFailed(let reason): "The attach handshake failed: \(reason)."
        }
    }
}

/// Filesystem side of agent attach: the private directory, the single endpoint owner, the
/// per-launch token, and blocking socket helpers. Trust boundary: same user account. The token
/// file is readable by this user only; another process running as this user can read it too, so
/// attach does not defend against malware already running as the user (documented residual risk).
enum MCPAttachSocket {
    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("MacScope", isDirectory: true)
            .appendingPathComponent("mcp", isDirectory: true)
    }

    static func socketURL(in directory: URL) -> URL { directory.appendingPathComponent("attach.sock") }
    static func tokenURL(in directory: URL) -> URL { directory.appendingPathComponent("token") }
    static func lockURL(in directory: URL) -> URL { directory.appendingPathComponent("owner.lock") }

    /// Creates the directory 0700 when missing; an existing one must be a real directory (not a
    /// link), owned by this uid, with no group/other access. An unsafe one is refused, not repaired.
    static func prepareDirectory(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw MCPAttachSocketError.system("lstat", errno) }
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw MCPAttachSocketError.system("mkdir", errno) }
            guard lstat(directory.path, &info) == 0 else { throw MCPAttachSocketError.system("lstat", errno) }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw MCPAttachSocketError.directoryUnsafe("not a directory") }
        guard info.st_uid == getuid() else { throw MCPAttachSocketError.directoryUnsafe("owned by another user") }
        guard info.st_mode & 0o077 == 0 else { throw MCPAttachSocketError.directoryUnsafe("accessible to other users") }
    }

    private static func address(_ url: URL) throws -> (sockaddr_un, socklen_t) {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw MCPAttachSocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + bytes.count + 1)
        address.sun_len = UInt8(truncatingIfNeeded: length)
        return (address, length)
    }

    // MARK: Endpoint owner

    /// The one per-user owner of the attach endpoint. Holding `owner.lock` (flock) for the app's
    /// lifetime serializes ownership: only the holder may remove a leftover socket and bind, a
    /// second instance is refused, and `release` unlinks only the socket inode it created.
    final class EndpointOwner {
        let directory: URL
        let listener: Int32
        let token: Data
        private let lock: Int32
        private let socketIdentity: (dev_t, ino_t)

        init(directory: URL) throws {
            try MCPAttachSocket.prepareDirectory(directory)
            let lock = open(MCPAttachSocket.lockURL(in: directory).path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw MCPAttachSocketError.system("open lock", errno) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                close(lock)
                throw MCPAttachSocketError.endpointOwnedElsewhere
            }
            let socketURL = MCPAttachSocket.socketURL(in: directory)
            do {
                // Holding the lock, anything at the socket path is a leftover of a dead owner, but
                // only a socket is removed; any other object is refused.
                var existing = stat()
                if lstat(socketURL.path, &existing) == 0 {
                    guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == getuid() else {
                        throw MCPAttachSocketError.directoryUnsafe("unexpected object at the socket path")
                    }
                    unlink(socketURL.path)
                }
                var (address, length) = try MCPAttachSocket.address(socketURL) // before any descriptor
                let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
                guard descriptor >= 0 else { throw MCPAttachSocketError.system("socket", errno) }
                let bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
                }
                guard bound == 0 else {
                    let code = errno
                    close(descriptor)
                    throw MCPAttachSocketError.system("bind", code)
                }
                // The directory is 0700, so nobody else could reach the socket before this chmod.
                var created = stat()
                guard chmod(socketURL.path, 0o600) == 0, lstat(socketURL.path, &created) == 0,
                      Darwin.listen(descriptor, 8) == 0 else {
                    let code = errno
                    close(descriptor)
                    unlink(socketURL.path)
                    throw MCPAttachSocketError.system("listen", code)
                }
                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
                let token: Data
                do {
                    token = try MCPAttachSocket.writeToken(in: directory)
                } catch {
                    // Nothing outlives a failed start: no listening descriptor, no published socket
                    // (DP09-2 N7).
                    close(descriptor)
                    unlink(socketURL.path)
                    throw error
                }
                self.directory = directory
                self.listener = descriptor
                self.token = token
                self.lock = lock
                self.socketIdentity = (created.st_dev, created.st_ino)
            } catch {
                close(lock)
                throw error
            }
        }

        /// Stops accepting and removes what this owner published (only if it is still ours).
        func release() {
            close(listener)
            let socketPath = MCPAttachSocket.socketURL(in: directory).path
            var current = stat()
            if lstat(socketPath, &current) == 0, current.st_dev == socketIdentity.0, current.st_ino == socketIdentity.1 {
                unlink(socketPath)
            }
            unlink(MCPAttachSocket.tokenURL(in: directory).path)
            close(lock)
        }
    }

    /// A fresh 32-byte token per launch, written 0600 with O_EXCL|O_NOFOLLOW (never through a link).
    static func writeToken(in directory: URL) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MCPAttachSocketError.system("SecRandomCopyBytes", EIO)
        }
        let path = tokenURL(in: directory).path
        unlink(path)
        let file = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw MCPAttachSocketError.system("open token", errno) }
        defer { close(file) }
        let token = Data(bytes)
        let hex = Data(token.map { String(format: "%02x", $0) }.joined().utf8)
        guard hex.withUnsafeBytes({ write(file, $0.baseAddress, hex.count) }) == hex.count else {
            throw MCPAttachSocketError.system("write token", errno)
        }
        return token
    }

    /// The relay's read of the token: a regular file owned by this uid, mode 0600, not a link.
    static func readToken(in directory: URL) throws -> Data {
        let file = open(tokenURL(in: directory).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw MCPAttachSocketError.notListening }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { throw MCPAttachSocketError.directoryUnsafe("token file") }
        var buffer = [UInt8](repeating: 0, count: 64)
        guard read(file, &buffer, 64) == 64 else { throw MCPAttachSocketError.handshakeFailed("token unreadable") }
        var token = Data()
        for index in stride(from: 0, to: 64, by: 2) {
            guard let byte = UInt8(String(decoding: buffer[index..<index + 2], as: UTF8.self), radix: 16) else {
                throw MCPAttachSocketError.handshakeFailed("token malformed")
            }
            token.append(byte)
        }
        return token
    }

    // MARK: Sockets

    static func connect(to url: URL) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MCPAttachSocketError.system("socket", errno) }
        var (address, length) = try address(url)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, length) }
        }
        guard connected == 0 else {
            close(descriptor)
            throw MCPAttachSocketError.notListening
        }
        configure(descriptor)
        return descriptor
    }

    /// Blocking accept; nil once the listener is closed.
    static func accept(_ listener: Int32) -> Int32? {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client >= 0 { configure(client); return client }
            if errno == EINTR || errno == ECONNABORTED { continue }
            return nil
        }
    }

    private static func configure(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Bounds blocking reads/writes on a socket (0 clears the bound).
    static func setTimeouts(_ descriptor: Int32, receive: Int, send: Int) {
        var receiveTime = timeval(tv_sec: receive, tv_usec: 0)
        var sendTime = timeval(tv_sec: send, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTime, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTime, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Fails closed: an unreadable credential is not this user.
    static func peerIsCurrentUser(_ descriptor: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 && uid == getuid()
    }

    static let maximumHandshakeBytes = 4_096

    /// Reads one newline-terminated line of at most `limit` bytes (handshake only).
    static func readLine(_ descriptor: Int32, limit: Int = maximumHandshakeBytes) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count <= limit {
            let count = read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { return nil }
            if byte == 0x0A { return line }
            line.append(byte)
        }
        return nil
    }

    static func writeLine(_ data: Data, to descriptor: Int32) -> Bool {
        (try? HeadlessProtocolIO.writeLine(data, to: FileHandle(fileDescriptor: descriptor, closeOnDealloc: false))) != nil
    }
}

/// The mutual-proof attach handshake. Both sides know the per-launch token; neither sends it.
///   relay → app   {"macscope-attach":2,"nonce":cN,"window":name?}
///   app → relay   {"macscope-attach":2,"nonce":sN,"instance":id,"proof":HMAC(token,"server"|cN|sN)}
///   relay → app   {"macscope-attach":2,"proof":HMAC(token,"client"|sN|cN)}
///   app → relay   {"macscope-attach":2,"ok":true,"workspace":label} | {"ok":false,"error":generic}
/// The relay forwards nothing until the app's proof verifies, so a socket planted by something
/// without the token is detected; the app binds nothing until the relay's proof verifies.
enum MCPAttachHandshake {
    static let version = 2
    static let nonceBytes = 16

    static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: nonceBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func proof(token: Data, role: String, first: String, second: String) -> String {
        let key = SymmetricKey(data: token)
        let message = Data("\(role)|\(first)|\(second)".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key)).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison of two hex proofs.
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func encode(_ object: [String: Any]) -> Data {
        var object = object
        object["macscope-attach"] = version
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// The fields of a version-2 handshake line whose keys are all in `allowed`, else nil.
    static func decode(_ line: Data, allowed: Set<String>) -> [String: Any]? {
        guard line.count <= MCPAttachSocket.maximumHandshakeBytes,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["macscope-attach"] as? Int == version,
              Set(object.keys).isSubset(of: allowed.union(["macscope-attach"])) else { return nil }
        return object
    }

    static func isWellFormedNonce(_ value: Any?) -> String? {
        guard let text = value as? String, text.utf8.count == nonceBytes * 2,
              text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        return text
    }

    /// Relay side: runs the handshake on a connected socket. Returns the attached workspace label,
    /// which the app withholds until the user allows the agent (nil).
    @discardableResult
    static func runClient(_ descriptor: Int32, token: Data, window: String?) throws -> String? {
        let clientNonce = nonce()
        var hello: [String: Any] = ["nonce": clientNonce]
        if let window { hello["window"] = window }
        guard MCPAttachSocket.writeLine(encode(hello), to: descriptor),
              let line = MCPAttachSocket.readLine(descriptor),
              let server = decode(line, allowed: ["nonce", "instance", "proof", "ok", "error"]) else {
            throw MCPAttachSocketError.handshakeFailed("MacScope did not answer")
        }
        if server["ok"] as? Bool == false {
            throw MCPAttachSocketError.handshakeFailed(server["error"] as? String ?? "refused")
        }
        guard let serverNonce = isWellFormedNonce(server["nonce"]), let serverProof = server["proof"] as? String,
              matches(serverProof, proof(token: token, role: "server", first: clientNonce, second: serverNonce)) else {
            throw MCPAttachSocketError.handshakeFailed("the endpoint could not prove it is this MacScope")
        }
        guard MCPAttachSocket.writeLine(
                encode(["proof": proof(token: token, role: "client", first: serverNonce, second: clientNonce)]),
                to: descriptor),
              let resultLine = MCPAttachSocket.readLine(descriptor),
              let result = decode(resultLine, allowed: ["ok", "workspace", "error"]) else {
            throw MCPAttachSocketError.handshakeFailed("MacScope closed the connection")
        }
        guard result["ok"] as? Bool == true else {
            throw MCPAttachSocketError.handshakeFailed(result["error"] as? String ?? "refused")
        }
        return result["workspace"] as? String
    }

    /// App side, up to the client's proof. Returns the requested window name (`.some(nil)` for
    /// the default), or nil when the peer failed to authenticate (the caller closes it).
    static func runServer(_ descriptor: Int32, token: Data, instance: String) -> String?? {
        guard let line = MCPAttachSocket.readLine(descriptor),
              let hello = decode(line, allowed: ["nonce", "window"]),
              let clientNonce = isWellFormedNonce(hello["nonce"]) else { return nil }
        let window: String?
        switch hello["window"] {
        case nil: window = nil
        case let name as String where !name.isEmpty && name.utf8.count <= 1_024: window = name
        default: return nil
        }
        let serverNonce = nonce()
        guard MCPAttachSocket.writeLine(encode([
                "nonce": serverNonce, "instance": instance,
                "proof": proof(token: token, role: "server", first: clientNonce, second: serverNonce),
              ]), to: descriptor),
              let reply = MCPAttachSocket.readLine(descriptor),
              let client = decode(reply, allowed: ["proof"]),
              let clientProof = client["proof"] as? String,
              matches(clientProof, proof(token: token, role: "client", first: serverNonce, second: clientNonce)) else {
            return nil
        }
        return .some(window)
    }

    static func result(workspace: String?, error: String?) -> Data {
        var object: [String: Any] = ["ok": error == nil]
        if let workspace { object["workspace"] = workspace }
        if let error { object["error"] = error }
        return encode(object)
    }
}
