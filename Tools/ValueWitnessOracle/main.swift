import Foundation
import MachO
import Darwin

@main struct Oracle {
    static func write(_ object: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if args.contains("--self-test") {
            guard let type = _typeByName("SSSg") else { fatalError("SSSg unavailable") }
            let p = metadataPointer(type), v = witness(p)
            guard v["size"] as? UInt == 16, v["stride"] as? UInt == 16,
                  v["flags"] as? UInt32 == 0x2210007,
                  v["extraInhabitants"] as? UInt32 == 2147483646,
                  p.load(as: UInt.self) == 0x202 else { fatalError("self-test ABI mismatch; STOP") }
            print("PASS SSSg size=16 stride=16 flags=0x2210007 extraInhabitants=2147483646 kind=0x202")
            return
        }
        guard let path = args.first, !path.hasPrefix("--"), let output = option("--out") else {
            fputs("usage: vwo <image> [--names FILE] [--fields] [--isolate] [--timeout 120] --out FILE.json\n", stderr)
            exit(64)
        }
        if args.contains("--child") {
            // Include forked query children in the supervisor's timeout cleanup.
            guard setpgid(0, 0) == 0 else { throw POSIXError(.EPERM) }
            let names = try option("--names").map { try String(contentsOfFile: $0, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init) } ?? []
            let result = try queryImage(path, names: names, fields: args.contains("--fields"), isolate: args.contains("--isolate"))
            try write(result, to: output)
            exit(result["status"] as? String == "ok" ? 0 : 1)
        }
        let timeout = Double(option("--timeout") ?? "120") ?? 120
        guard timeout > 0 else { exit(64) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = args + ["--child"]
        try child.run()
        let deadline = Date().addingTimeInterval(timeout)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if child.isRunning {
            kill(-child.processIdentifier, SIGTERM)
            child.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            kill(-child.processIdentifier, SIGKILL)
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            try write(["status": "failed", "image": path, "types": [], "unanswered": [["reason": "timeout"]], "summary": ["answered": 0, "askable": 0, "rate": 0]], to: output)
            exit(124)
        }
        child.waitUntilExit()
        if child.terminationReason == .uncaughtSignal {
            try write(["status": "failed", "image": path, "types": [], "unanswered": [["reason": "nil-from-runtime", "detail": "child crashed", "signal": child.terminationStatus]], "summary": ["answered": 0, "askable": 0, "rate": 0]], to: output)
            exit(1)
        }
        exit(child.terminationStatus)
    }
}
