import Darwin
import Foundation

/// Shared wire/bootstrap only when compiled by the native-decompiler executable.
/// No child mode initializes a native engine in this tranche: execute is explicitly unavailable.
enum PosixOwnedChildMode {
    static let flag = "--macscope-owned-native-child-v1"
    static let environment = ["LANG": "C", "LC_ALL": "C", "TZ": "UTC"]
    enum Selection: Equatable { case notRequested, rejected, child(String) }

    static func select(arguments: [String], environment: [String: String],
                       allowedChannels: Set<String>) -> Selection {
        guard arguments.dropFirst().contains(where: { $0.hasPrefix("--macscope-owned-native-child") })
        else { return .notRequested }
        guard arguments.count == 4, arguments[1] == flag, arguments[2] == "--channel",
              allowedChannels.contains(arguments[3]), environment == Self.environment
        else { return .rejected }
        return .child(arguments[3])
    }

    static func runIfRequested(arguments: [String], environment: [String: String],
                               allowedChannels: Set<String>) -> Int32? {
        switch select(arguments: arguments, environment: environment, allowedChannels: allowedChannels) {
        case .notRequested: return nil
        case .rejected: return 64
        case .child(let channel): return runUnavailableChild(channel: channel)
        }
    }

    private static func runUnavailableChild(channel: String) -> Int32 {
        guard let line = readLine(maximum: 1024),
              var message = try? OwnedChildWire.decode(line, maximum: 1024),
              message.kind == "initialize", message.channel == channel,
              message.processID == Darwin.getpid(), message.payload == nil,
              message.reason == nil else { return 64 }
        // Preserve protocol output independently of anything later written to standard stdout.
        let output = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 4)
        guard output >= 0 else { return 69 }
        defer { close(output) }
        guard fcntl(output, F_SETNOSIGPIPE, 1) == 0,
              dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { return 69 }
        message.kind = "ready"
        guard let ready = try? message.encoded(), writeAll(output, ready + Data([10])) else { return 69 }
        while let frame = readFrame(maximum: OwnedChildWire.bootstrapMaximumFrameBytes),
              var command = try? OwnedChildWire.decode(frame, maximum: OwnedChildWire.bootstrapMaximumFrameBytes),
              command.sameIdentity(as: message), command.reason == nil {
            switch command.kind {
            case "execute":
                guard command.payload != nil else { return 64 }
                // No native adapter or job factory is enabled. A handshake is IPC readiness only.
                command.kind = "rejectedBeforeNative"; command.payload = nil; command.reason = "unavailable"
                guard let refusal = try? command.framed() else { return 69 }
                _ = writeAll(output, refusal)
                return 69
            case "abort":
                guard command.payload == nil else { return 64 }
                command.kind = "abortAcknowledged"
                guard let advisory = try? command.framed(), writeAll(output, advisory) else { return 69 }
            case "shutdown": return command.payload == nil ? 0 : 64
            default: return 64
            }
        }
        return 64 // EOF is a child control failure, never a native result.
    }

    private static func readLine(maximum: Int) -> Data? {
        var data = Data()
        while data.count < maximum {
            guard let next = readExact(1) else { return nil }
            if next.first == 10 { return data }
            data.append(next)
        }
        return nil
    }
    private static func readFrame(maximum: Int) -> Data? {
        guard let header = readExact(4) else { return nil }
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= UInt32(maximum) else { return nil }
        return readExact(Int(size))
    }
    private static func readExact(_ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let size = data.withUnsafeMutableBytes { bytes in
                Darwin.read(STDIN_FILENO, bytes.baseAddress?.advanced(by: offset), count - offset)
            }
            if size < 0, errno == EINTR { continue }
            guard size > 0 else { return nil }
            offset += size
        }
        return data
    }
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress?.advanced(by: offset), data.count - offset) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
}

/// Canonical JSON makes unknown/duplicate keys and noncanonical variants a refusal. This is
/// a deliberately closed wire grammar, not a general JSON parser. No native payload is inferred.
struct OwnedChildWire: Codable, Equatable, Sendable {
    // This is a bootstrap refusal cap, NOT native-channel acceptance or activation policy.
    static let bootstrapMaximumFrameBytes = 8 * 1024 * 1024
    var schemaVersion = 1
    var kind: String
    var parentStartupNonce: UUID
    var spawnNonce: UUID
    var processID: Int32
    var channel: String
    var requestID: UUID
    var connectionGeneration: UUID
    var payload: Data?
    var reason: String?

    func sameIdentity(as other: Self) -> Bool {
        schemaVersion == 1 && other.schemaVersion == 1 && parentStartupNonce == other.parentStartupNonce &&
        spawnNonce == other.spawnNonce && processID == other.processID && channel == other.channel &&
        requestID == other.requestID && connectionGeneration == other.connectionGeneration
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    func framed() throws -> Data {
        let body = try encoded()
        guard body.count <= Int(UInt32.max) else { throw WireFailure.invalid }
        var size = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: &size) { Data($0) } + body
    }
    static func decode(_ data: Data, maximum: Int) throws -> Self {
        guard data.count <= maximum else { throw WireFailure.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, value.processID > 1, try value.encoded() == data
        else { throw WireFailure.invalid }
        return value
    }
    enum WireFailure: Error { case invalid }
}
