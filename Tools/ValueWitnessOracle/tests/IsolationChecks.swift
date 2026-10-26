import Foundation
import Darwin

@main struct IsolationChecks {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let identity: [String: Any] = ["mangled": "4Test5ValueV"]
        var result: [String: Any]
        switch mode {
        case "success":
            let parent = getpid()
            result = try isolatedQuery(identity: identity) {
                ["child": getpid() != parent, "vwt": ["size": 16], "mangled": "4Test5ValueV"]
            }
        case "large":
            result = try isolatedQuery(identity: identity) { ["payload": String(repeating: "x", count: 262144)] }
        case "crash":
            result = try isolatedQuery(identity: identity) {
                signal(SIGSEGV, SIG_DFL)
                raise(SIGSEGV)
                _exit(99)
            }
            result["next"] = try isolatedQuery(identity: ["mangled": "Si"]) { ["vwt": ["size": 8]] }
            var status: Int32 = 0
            result["reaped"] = waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD
        case "exit":
            do {
                _ = try isolatedQuery(identity: identity) { _exit(74) }
                result = ["caught": false]
            } catch { result = ["caught": true, "code": (error as NSError).code] }
        case "direct":
            let parent = getpid()
            result = try resolveQuery(isolate: false, identity: identity) { ["sameProcess": getpid() == parent] }
        default: exit(64)
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
