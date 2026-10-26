import XCTest
@testable import MacScope

/// Tier 3 — the AppleScript command-translation layer: maps representative AppleScript
/// events (a verb + a parameter record) to the right `WorkspaceScriptingAPI` command +
/// arguments, and rejects unsafe / invalid ones. Pure (no live Apple-event dispatcher),
/// so the whole mapping is asserted directly on the translated command.
final class AppleScriptCommandTranslatorTests: XCTestCase {

    private func translate(_ name: String, _ params: [String: ScriptValue] = [:]) throws -> TranslatedScriptCommand {
        try AppleScriptCommandTranslator.translate(command: name, parameters: params)
    }

    // MARK: - Reads map to the right command

    func testGetInfoMapsToInfo() throws {
        let result = try translate("get info")
        XCTAssertEqual(result, TranslatedScriptCommand(command: "info", arguments: .object([:])))
    }

    func testGetFunctionsPassesLimit() throws {
        let result = try translate("get functions", ["limit": .int(5)])
        XCTAssertEqual(result, TranslatedScriptCommand(command: "functions", arguments: .object(["limit": .int(5)])))
    }

    func testGetFunctionsWithoutLimit() throws {
        let result = try translate("get functions")
        XCTAssertEqual(result, TranslatedScriptCommand(command: "functions", arguments: .object([:])))
    }

    func testGetInstructionsByFunctionName() throws {
        let result = try translate("get instructions", ["function": .string("_main")])
        XCTAssertEqual(result, TranslatedScriptCommand(command: "instructions", arguments: .object(["function": .string("_main")])))
    }

    func testGetInstructionsByAddressWithCount() throws {
        let result = try translate("get instructions", ["at": .int(0x1000), "count": .int(4)])
        XCTAssertEqual(
            result,
            TranslatedScriptCommand(command: "instructions", arguments: .object(["address": .string("0x1000"), "count": .int(4)]))
        )
    }

    func testGetNameAtNormalizesIntegerAddressToHexString() throws {
        let result = try translate("get name at", ["at": .int(0x1004)])
        XCTAssertEqual(result, TranslatedScriptCommand(command: "name-at", arguments: .object(["address": .string("0x1004")])))
    }

    func testGetNameAtAcceptsHexStringAddress() throws {
        let result = try translate("get name at", ["at": .string("0x2000")])
        XCTAssertEqual(result, TranslatedScriptCommand(command: "name-at", arguments: .object(["address": .string("0x2000")])))
    }

    func testGetCommentReadsSingleInstruction() throws {
        let result = try translate("get comment", ["at": .int(0x1000)])
        XCTAssertEqual(
            result,
            TranslatedScriptCommand(command: "instructions", arguments: .object(["address": .string("0x1000"), "count": .int(1)]))
        )
    }

    // MARK: - Undoable authoring maps to the undoable commands

    func testSetNameMapsToRename() throws {
        let result = try translate("set name", ["at": .int(0x1000), "to": .string("entry")])
        XCTAssertEqual(
            result,
            TranslatedScriptCommand(command: "rename", arguments: .object(["address": .string("0x1000"), "name": .string("entry")]))
        )
    }

    func testSetCommentMapsToSetComment() throws {
        let result = try translate("set comment", ["at": .int(0x1000), "to": .string("note")])
        XCTAssertEqual(
            result,
            TranslatedScriptCommand(command: "set-comment", arguments: .object(["address": .string("0x1000"), "comment": .string("note")]))
        )
    }

    func testSetCommentAllowsEmptyToClear() throws {
        // An empty comment is a valid clear, not a rejection.
        let result = try translate("set comment", ["at": .int(0x1000), "to": .string("")])
        XCTAssertEqual(
            result,
            TranslatedScriptCommand(command: "set-comment", arguments: .object(["address": .string("0x1000"), "comment": .string("")]))
        )
    }

    func testSetTagMapsToSetTag() throws {
        let result = try translate("set tag", ["at": .int(0x1000), "to": .string("crypto")])
        XCTAssertEqual(
            result,
            TranslatedScriptCommand(command: "set-tag", arguments: .object(["address": .string("0x1000"), "tag": .string("crypto")]))
        )
    }

    // MARK: - run command (allowlisted escape hatch)

    func testRunCommandPassesAllowlistedCommandThrough() throws {
        let result = try translate("run command", ["command": .string("symbols"), "arguments": .object(["limit": .int(2)])])
        XCTAssertEqual(result, TranslatedScriptCommand(command: "symbols", arguments: .object(["limit": .int(2)])))
    }

    func testRunCommandDefaultsArgumentsToEmptyObject() throws {
        let result = try translate("run command", ["command": .string("info")])
        XCTAssertEqual(result, TranslatedScriptCommand(command: "info", arguments: .object([:])))
    }

    func testRunCommandRejectsNonAllowlistedCommand() {
        // A structural/destructive command must NOT be reachable via AppleScript even
        // through the generic escape hatch.
        XCTAssertThrowsError(try translate("run command", ["command": .string("make-data")])) { error in
            XCTAssertEqual(error as? AppleScriptTranslationError,
                           .invalidParameter("command 'make-data' is not allowed via AppleScript"))
        }
    }

    func testRunCommandRejectsDefineType() {
        XCTAssertThrowsError(try translate("run command", ["command": .string("define-type")])) { error in
            guard case .invalidParameter = (error as? AppleScriptTranslationError) else {
                return XCTFail("expected invalidParameter")
            }
        }
    }

    func testRunCommandRejectsNonObjectArguments() {
        XCTAssertThrowsError(try translate("run command", ["command": .string("info"), "arguments": .int(5)])) { error in
            XCTAssertEqual(error as? AppleScriptTranslationError,
                           .invalidParameter("'arguments' must be a record/object"))
        }
    }

    // MARK: - Rejections: unknown verbs and invalid params

    func testUnknownVerbIsRejected() {
        XCTAssertThrowsError(try translate("delete everything")) { error in
            XCTAssertEqual(error as? AppleScriptTranslationError, .unsupportedCommand("delete everything"))
        }
    }

    func testSetNameMissingAddressIsRejected() {
        XCTAssertThrowsError(try translate("set name", ["to": .string("x")])) { error in
            XCTAssertEqual(error as? AppleScriptTranslationError, .missingParameter("at"))
        }
    }

    func testSetNameMissingNewNameIsRejected() {
        XCTAssertThrowsError(try translate("set name", ["at": .int(0x1000)])) { error in
            XCTAssertEqual(error as? AppleScriptTranslationError, .missingParameter("to"))
        }
    }

    func testSetNameEmptyNameIsRejected() {
        XCTAssertThrowsError(try translate("set name", ["at": .int(0x1000), "to": .string("")])) { error in
            guard case .invalidParameter = (error as? AppleScriptTranslationError) else {
                return XCTFail("expected invalidParameter for empty name")
            }
        }
    }

    func testInvalidAddressIsRejected() {
        XCTAssertThrowsError(try translate("get name at", ["at": .string("not-an-address")])) { error in
            guard case .invalidParameter = (error as? AppleScriptTranslationError) else {
                return XCTFail("expected invalidParameter for bad address")
            }
        }
    }

    func testGetInstructionsWithoutFunctionOrAddressIsRejected() {
        XCTAssertThrowsError(try translate("get instructions")) { error in
            XCTAssertEqual(error as? AppleScriptTranslationError, .missingParameter("function or at"))
        }
    }

    func testNegativeLimitIsRejected() {
        XCTAssertThrowsError(try translate("get functions", ["limit": .int(-1)])) { error in
            guard case .invalidParameter = (error as? AppleScriptTranslationError) else {
                return XCTFail("expected invalidParameter for negative limit")
            }
        }
    }

    // MARK: - The translated command actually dispatches through the real API

    @MainActor
    func testTranslatedCommandDispatchesThroughScriptingAPI() throws {
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "t.bin", path: "/tmp/t.bin", kind: "Mach-O executable", architecture: "arm64")],
            functions: [FunctionSummary(id: UUID(), name: "_main", startAddress: 0x1000, endAddress: 0x1008, confidence: 0.9)],
            instructions: [
                InstructionRow(address: 0x1000, bytes: "e0 03 01 aa", mnemonic: "mov", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            ],
            xrefs: [],
            hexBytes: Data()
        )
        let store = WorkspaceStore(workspaceName: "AS", snapshot: snapshot, engine: AnalysisEngine())
        let api = WorkspaceScriptingAPI(store: store)

        // set name (undoable) round-trips through the real store + API.
        let setName = try translate("set name", ["at": .int(0x1000), "to": .string("entry")])
        _ = try api.execute(setName.command, arguments: setName.arguments)

        let nameAt = try translate("get name at", ["at": .int(0x1000)])
        let result = try api.execute(nameAt.command, arguments: nameAt.arguments)
        XCTAssertEqual(result.stringValue, "entry")
    }

    /// Every command id reachable via `run command` must be a real registered command;
    /// this guards against the allowlist drifting away from the registry.
    @MainActor
    func testAllowlistedCommandsAllExistInRegistry() {
        let registered = Set(WorkspaceScriptingAPI.availableCommands.map(\.name))
        for id in AppleScriptCommandTranslator.allowlistedCommandIDs {
            XCTAssertTrue(registered.contains(id), "allowlisted '\(id)' is not a registered scripting command")
        }
    }
}
