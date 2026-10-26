import XCTest
@testable import MacScope

/// The testable core of the live AppleScript runtime: the Cocoa-scripting ⇄ `ScriptValue`
/// bridge and the end-to-end command runner (verb + Apple-event arguments → translate →
/// `WorkspaceScriptingAPI.execute` → result). The `NSScriptCommand` shell that reads a real
/// Apple event and resolves the front document is environment-heavy glue and is verified
/// manually; everything it depends on is exercised here without a running app.
@MainActor
final class AppleScriptRuntimeTests: XCTestCase {

    // MARK: - Argument bridge (Cocoa scripting values -> ScriptValue)

    func testBridgeConvertsScalarCocoaArguments() {
        XCTAssertEqual(AppleScriptArgumentBridge.scriptValue(from: "main"), .string("main"))
        XCTAssertEqual(AppleScriptArgumentBridge.scriptValue(from: NSNumber(value: 4096)), .int(4096))
    }

    func testBridgeConvertsRecordAndListArguments() {
        let record: [String: Any] = ["limit": NSNumber(value: 3)]
        XCTAssertEqual(AppleScriptArgumentBridge.scriptValue(from: record), .object(["limit": .int(3)]))
        let list: [Any] = [NSNumber(value: 1), "x"]
        XCTAssertEqual(AppleScriptArgumentBridge.scriptValue(from: list), .array([.int(1), .string("x")]))
    }

    func testBridgeConvertsScriptValueBackToCocoa() {
        XCTAssertEqual(AppleScriptArgumentBridge.cocoaValue(from: .string("hi")) as? String, "hi")
        XCTAssertEqual(AppleScriptArgumentBridge.cocoaValue(from: .int(7)) as? Int, 7)
        let object = AppleScriptArgumentBridge.cocoaValue(from: .object(["k": .int(1)])) as? [String: Any]
        XCTAssertEqual(object?["k"] as? Int, 1)
    }

    // MARK: - End-to-end runner (translate + execute)

    private func makeAPI() -> WorkspaceScriptingAPI {
        WorkspaceScriptingAPI(store: WorkspaceStore.bootstrapForPreviewFixture())
    }

    func testRunnerExecutesReadVerbEndToEnd() throws {
        let info = try AppleScriptCommandRunner.run(verb: "get info", cocoaArguments: [:], api: makeAPI())
        guard case .object = info else {
            return XCTFail("`get info` should return a record/object, got \(info)")
        }
    }

    func testRunnerConvertsAndForwardsArguments() throws {
        // The NSNumber limit must survive the bridge and bound the returned list.
        let result = try AppleScriptCommandRunner.run(
            verb: "get functions",
            cocoaArguments: ["limit": NSNumber(value: 2)],
            api: makeAPI()
        )
        guard case let .array(items) = result else {
            return XCTFail("`get functions` should return a list, got \(result)")
        }
        XCTAssertLessThanOrEqual(items.count, 2)
    }

    func testRunnerRejectsUnsupportedVerb() {
        XCTAssertThrowsError(try AppleScriptCommandRunner.run(verb: "delete everything", cocoaArguments: [:], api: makeAPI())) {
            XCTAssertEqual($0 as? AppleScriptTranslationError, .unsupportedCommand("delete everything"))
        }
    }

    func testRunnerRejectsNonAllowlistedRunCommand() {
        // The generic `run command` escape hatch must not reach a structural/destructive op.
        XCTAssertThrowsError(try AppleScriptCommandRunner.run(
            verb: "run command",
            cocoaArguments: ["command": "mark-as-data"],
            api: makeAPI()
        ))
    }

    // MARK: - Front-document registry (what the NSScriptCommand shell resolves)

    func testScriptingHostExposesActiveStoreAPI() throws {
        // The host is a shared singleton (the running app may have registered a store), so
        // save/restore rather than assuming an initially-empty registry.
        let previous = ScriptingHost.shared.activeStore
        defer { ScriptingHost.shared.activeStore = previous }

        let store = WorkspaceStore.bootstrapForPreviewFixture()
        ScriptingHost.shared.activeStore = store
        let api = try XCTUnwrap(ScriptingHost.shared.activeAPI, "a registered store must expose an API")
        let info = try AppleScriptCommandRunner.run(verb: "get info", cocoaArguments: [:], api: api)
        guard case .object = info else {
            return XCTFail("the resolved front-document API must execute, got \(info)")
        }

        // Clearing the registration drops the API (the no-front-document case the shell guards).
        ScriptingHost.shared.activeStore = nil
        XCTAssertNil(ScriptingHost.shared.activeAPI)
    }
}
