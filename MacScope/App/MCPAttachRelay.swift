import Darwin
import Foundation

/// `MacScope --mcp-attach [--window <workspace name>]`: what an MCP client launches to drive an
/// open MacScope window. It loads nothing itself; it connects to the running app's attach socket,
/// proves both sides know this launch's token (mutual HMAC handshake), then copies stdin → socket and socket → stdout until either side closes.
/// Errors (app not running, setting off, no such window, denied) go to stderr with exit code 1.
enum MCPAttachRelay {
    /// `.some(window)` when argv selects attach mode (`window` nil = frontmost), else nil.
    static func requestedWindow(from arguments: [String]) -> String?? {
        guard arguments.dropFirst().first == "--mcp-attach" else { return nil }
        let rest = Array(arguments.dropFirst(2))
        switch rest.count {
        case 0: return .some(nil)
        case 2 where rest[0] == "--window" && !rest[1].isEmpty: return .some(rest[1])
        default: return nil
        }
    }

    static func run(window: String?, directory: URL = MCPAttachSocket.defaultDirectory()) -> Never {
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("MacScope MCP attach: \(message)\n".utf8))
            exit(1)
        }
        let output: FileHandle
        do { output = try HeadlessProtocolIO.isolateStandardOutput() } catch { fail(error.localizedDescription) }
        let socket: Int32
        let workspace: String?
        do {
            let token = try MCPAttachSocket.readToken(in: directory)
            socket = try MCPAttachSocket.connect(to: MCPAttachSocket.socketURL(in: directory))
            // Bounded handshake; nothing from stdin is forwarded until the app has proved itself.
            MCPAttachSocket.setTimeouts(socket, receive: 5, send: 5)
            workspace = try MCPAttachHandshake.runClient(socket, token: token, window: window)
            MCPAttachSocket.setTimeouts(socket, receive: 0, send: 0)
        } catch {
            fail(error.localizedDescription)
        }
        FileHandle.standardError.write(Data(
            "MacScope MCP attach: connected\(workspace.map { " to \"\($0)\"" } ?? ""); allow the agent in the MacScope window.\n".utf8))

        // stdin → socket; at end of input, half-close so the app finishes and replies.
        Thread.detachNewThread {
            copy(from: STDIN_FILENO, to: socket)
            shutdown(socket, SHUT_WR)
        }
        // socket → stdout; when the app closes the connection, the relay is done. No reconnect.
        copy(from: socket, to: output.fileDescriptor)
        exit(0)
    }

    private static func copy(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + written, count - written) }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { return }
                written += result
            }
        }
    }
}
