import Foundation
import LumenTokens

/// lumen-theme: validate theme files and export Lumen's reference artifacts, without an app.
///
///   lumen-theme validate <file.json>...   exit 1 if any file has errors (warnings are printed)
///   lumen-theme export <directory>        write builtin-themes.json, theme.schema.json, token-reference.md
///
/// Checks use Lumen's core registry. An app's own roles are validated by that app's tests, which
/// build its registry; here they are reported as unknown keys (warnings), never as errors.

let arguments = Array(CommandLine.arguments.dropFirst())
let registry = LumenRegistry.core

func usage() -> Never {
    printError("usage: lumen-theme validate <file.json>... | lumen-theme export <directory>")
    exit(2)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// The decoder's own reason and where in the file, not Foundation's generic "isn't in the correct format".
func describe(_ error: any Error) -> String {
    guard let error = error as? DecodingError else { return error.localizedDescription }
    func path(_ context: DecodingError.Context) -> String {
        let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
        return keys.isEmpty ? "" : " at \(keys.joined(separator: "."))"
    }
    switch error {
    case .dataCorrupted(let context): return context.debugDescription + path(context)
    case .keyNotFound(let key, let context): return "missing “\(key.stringValue)”" + path(context)
    case .typeMismatch(_, let context), .valueNotFound(_, let context): return context.debugDescription + path(context)
    @unknown default: return error.localizedDescription
    }
}

switch arguments.first {
case "validate" where arguments.count > 1:
    var failed = false
    for path in arguments.dropFirst() {
        let url = URL(fileURLWithPath: path)
        do {
            let data = try Data(contentsOf: url)
            let theme = try JSONDecoder().decode(LumenTheme.self, from: data)
            guard theme.schemaVersion <= LumenTheme.currentSchemaVersion else {
                printError("✗ \(url.lastPathComponent): needs a newer Lumen (theme format \(theme.schemaVersion))"); failed = true; continue
            }
            let flat = try theme.flattened { registry.theme(id: $0) }
            var issues = LumenValidator.issues(for: flat, in: registry)
            for key in LumenTheme.unknownTopLevelKeys(in: data) {
                issues.insert(LumenIssue(.warning, .light, token: nil, "“\(key)” is not a theme field; it is ignored"), at: 0)
            }
            if registry.theme(id: theme.id) != nil {
                issues.insert(LumenIssue(.warning, .light, token: nil, "id “\(theme.id)” is a built-in theme's; apps will rename it on import"), at: 0)
            }
            let errors = issues.filter { $0.severity == .error }
            print("\(errors.isEmpty ? "✓" : "✗") \(url.lastPathComponent): \(theme.name), \(errors.count) errors, \(issues.count - errors.count) warnings")
            for issue in issues { print("    \(issue.severity == .error ? "error" : "warning") [\(issue.appearance)] \(issue.message)") }
            failed = failed || !errors.isEmpty
        } catch let error as LumenTheme.InheritanceError {
            printError("✗ \(url.lastPathComponent): it \(error)"); failed = true
        } catch {
            printError("✗ \(url.lastPathComponent): \(describe(error))"); failed = true
        }
    }
    exit(failed ? 1 : 0)
case "export" where arguments.count == 2:
    do {
        try LumenExport.write(registry, to: URL(fileURLWithPath: arguments[1], isDirectory: true))
        print("wrote \(LumenExport.fileNames.themes), \(LumenExport.fileNames.schema), \(LumenExport.fileNames.reference) to \(arguments[1])")
    } catch {
        printError("export failed: \(describe(error))"); exit(1)
    }
default:
    usage()
}
