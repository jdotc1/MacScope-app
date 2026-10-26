import Foundation
import Darwin

// The image is already loaded in the calling process. Only JSON crosses the
// pipe: metadata pointers allocated by a child never escape into its parent.
func isolatedQuery(identity: [String: Any], _ query: () -> [String: Any]) throws -> [String: Any] {
    func failure(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: operation])
    }
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else { throw failure("pipe") }
    let pid = vwo_fork()
    if pid < 0 {
        let error = failure("fork")
        close(descriptors[0]); close(descriptors[1])
        throw error
    }
    if pid == 0 {
        close(descriptors[0])
        do {
            let data = try JSONSerialization.data(withJSONObject: query(), options: [.sortedKeys])
            let sent = data.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptors[1], bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { return false }
                    offset += count
                }
                return true
            }
            close(descriptors[1])
            _exit(sent ? 0 : 74)
        } catch { _exit(74) }
    }
    close(descriptors[1])
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16384)
    var readError: Error?
    // Drain before waiting: a JSON result may be larger than the pipe capacity.
    while true {
        let count = Darwin.read(descriptors[0], &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        if count < 0 { readError = failure("read"); break }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    close(descriptors[0])
    if readError != nil { kill(pid, SIGKILL) }
    var status: Int32 = 0
    var waited: pid_t
    repeat { waited = waitpid(pid, &status, 0) } while waited < 0 && errno == EINTR
    guard waited == pid else { throw failure("waitpid") }
    if let readError { throw readError }
    // Darwin's WIFSIGNALED/WTERMSIG and WEXITSTATUS definitions.
    let signal = status & 127
    if signal != 0 && signal != 127 {
        return identity.merging(["reason": "host-crash", "signal": signal]) { _, new in new }
    }
    guard status == 0 else {
        throw NSError(domain: "IsolatedQuery", code: Int((status >> 8) & 255),
                      userInfo: [NSLocalizedDescriptionKey: "child failed to transmit query result"])
    }
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "IsolatedQuery", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "child result is not an object"])
    }
    return result
}

func resolveQuery(isolate: Bool, identity: [String: Any], _ query: () -> [String: Any]) throws -> [String: Any] {
    try isolate ? isolatedQuery(identity: identity, query) : query()
}
