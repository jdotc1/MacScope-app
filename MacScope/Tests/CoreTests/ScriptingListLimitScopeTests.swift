import Foundation
import XCTest
@testable import MacScope

/// DP23: attached admission must not silently truncate legacy nonattached list consumers.
/// All fixtures are synthesized in memory; no binary, corpus, LLDB or native service is used.
@MainActor
final class ScriptingListLimitScopeTests: XCTestCase {
    private let listCommands = ["functions", "symbols", "strings", "imports", "exports", "sections", "relocations"]

    func testSynchronousListsWithOmittedOrNullLimitReturnAllRows() throws {
        for command in listCommands {
            let api = WorkspaceScriptingAPI(store: makeListStore(command, count: 5_001))
            for arguments in [ScriptValue.object([:]), .object(["limit": .null])] {
                let result = try api.execute(command, arguments: arguments)
                assertListRows(result, command: command, count: 5_001)
            }
        }
    }

    func testAsynchronousListsWithOmittedOrNullLimitReturnAllRows() async throws {
        for command in listCommands {
            let api = WorkspaceScriptingAPI(store: makeListStore(command, count: 5_001))
            for arguments in [ScriptValue.object([:]), .object(["limit": .null])] {
                let result = try await api.executeAsync(command, arguments: arguments)
                assertListRows(result, command: command, count: 5_001)
            }
        }
    }

    func testSynchronousListsHonorExplicitLimitAboveAttachedCap() throws {
        for command in listCommands {
            let api = WorkspaceScriptingAPI(store: makeListStore(command, count: 5_002))
            let result = try api.execute(command, arguments: .object(["limit": .int(5_001)]))
            assertListRows(result, command: command, count: 5_001)
        }
    }

    func testAsynchronousListsHonorExplicitLimitAboveAttachedCap() async throws {
        for command in listCommands {
            let api = WorkspaceScriptingAPI(store: makeListStore(command, count: 5_002))
            let result = try await api.executeAsync(command, arguments: .object(["limit": .int(5_001)]))
            assertListRows(result, command: command, count: 5_001)
        }
    }

    func testNonattachedListsPreserveSmallZeroAndNegativeLimits() async throws {
        for command in listCommands {
            let api = WorkspaceScriptingAPI(store: makeListStore(command, count: 18))
            for limit in [17, 0, -1] {
                let arguments = ScriptValue.object(["limit": .int(Int64(limit))])
                assertListRows(try api.execute(command, arguments: arguments), command: command, count: max(0, limit))
                let asynchronous = try await api.executeAsync(command, arguments: arguments)
                assertListRows(asynchronous, command: command, count: max(0, limit))
            }
        }
    }

    func testAttachedListsKeepDefaultHardCapAndSmallerLimits() async throws {
        for command in listCommands {
            let store = makeListStore(command, count: 5_001)
            let executor = attachedExecutor(store)
            let cases: [(ScriptValue, Int?)] = [
                (.object([:]), 1_000), (.object(["limit": .null]), nil),
                (.object(["limit": .int(5_001)]), 5_000),
                (.object(["limit": .int(17)]), 17),
                (.object(["limit": .int(0)]), 0), (.object(["limit": .int(-1)]), nil),
            ]
            for (arguments, expectedCount) in cases {
                guard let expectedCount else {
                    await assertAttachedRejectsInvalidCount(executor, command: command, arguments: arguments)
                    continue
                }
                let result = try await executor.execute(command, arguments)
                assertListRows(result, command: command, count: expectedCount)
            }
        }
    }

    func testSynchronousNamedInstructionsRemainUnlimitedAndIgnoreCount() throws {
        let api = WorkspaceScriptingAPI(store: makeInstructionStore(count: 2_001))
        for arguments in namedInstructionArguments {
            assertInstructions(try api.execute("instructions", arguments: arguments), count: 2_001)
        }
    }

    func testAsynchronousNamedInstructionsRemainUnlimitedAndIgnoreCount() async throws {
        let api = WorkspaceScriptingAPI(store: makeInstructionStore(count: 2_001))
        for arguments in namedInstructionArguments {
            let result = try await api.executeAsync("instructions", arguments: arguments)
            assertInstructions(result, count: 2_001)
        }
    }

    func testSynchronousAddressInstructionsHonorCountAboveAttachedCap() throws {
        let api = WorkspaceScriptingAPI(store: makeInstructionStore(count: 2_002))
        // A null function is an address selector, not a named-function request.
        let result = try api.execute("instructions", arguments: .object([
            "function": .null, "address": .hex(0x1000), "count": .int(2_001),
        ]))
        assertInstructions(result, count: 2_001)
    }

    func testAsynchronousAddressInstructionsHonorCountAboveAttachedCap() async throws {
        let api = WorkspaceScriptingAPI(store: makeInstructionStore(count: 2_002))
        let result = try await api.executeAsync("instructions", arguments: .object([
            "function": .null, "address": .hex(0x1000), "count": .int(2_001),
        ]))
        assertInstructions(result, count: 2_001)
    }

    func testNonattachedAddressInstructionsKeepDefaultAndSmallCounts() async throws {
        let api = WorkspaceScriptingAPI(store: makeInstructionStore(count: 18))
        for (arguments, expectedCount) in smallAddressInstructionCases {
            assertInstructions(try api.execute("instructions", arguments: arguments), count: expectedCount)
            let asynchronous = try await api.executeAsync("instructions", arguments: arguments)
            assertInstructions(asynchronous, count: expectedCount)
        }
    }

    func testAttachedInstructionsKeepNamedAndAddressCaps() async throws {
        let store = makeInstructionStore(count: 2_001)
        let executor = attachedExecutor(store)
        for arguments in namedInstructionArguments {
            if arguments["count"] == .null || (arguments["count"]?.intValue ?? 0) < 0 {
                await assertAttachedRejectsInvalidCount(executor, command: "instructions", arguments: arguments)
                continue
            }
            let result = try await executor.execute("instructions", arguments)
            assertInstructions(result, count: 2_000)
        }
        let aboveCap = try await executor.execute("instructions", .object([
            "function": .null, "address": .hex(0x1000), "count": .int(2_001),
        ]))
        assertInstructions(aboveCap, count: 2_000)
        for (arguments, expectedCount) in smallAddressInstructionCases {
            if arguments["count"] == .null || (arguments["count"]?.intValue ?? 0) < 0 {
                await assertAttachedRejectsInvalidCount(executor, command: "instructions", arguments: arguments)
                continue
            }
            let result = try await executor.execute("instructions", arguments)
            assertInstructions(result, count: expectedCount)
        }
    }

    func testNonattachedInstructionSelectionDoesNotInheritAttachedWorkBudget() throws {
        let store = makeInstructionStore(count: 8)
        var checkpoints = 0
        let result = try WorkspaceScriptingAPI.snapshotListRead("instructions", arguments: .object([
            "address": .hex(0x101c), "count": .int(1),
        ]), snapshot: store.snapshot, selectionWorkLimit: 2) { checkpoints += 1 }
        XCTAssertEqual(result.arrayValue?.count, 1)
        XCTAssertEqual(result.arrayValue?.first?["address"], .hex(0x101c))
        XCTAssertGreaterThan(checkpoints, 0, "unlimited selection must remain cancellable")
    }

    private var namedInstructionArguments: [ScriptValue] {
        [
            .object(["function": .string("f")]),
            .object(["function": .string("f"), "count": .null]),
            .object(["function": .string("f"), "count": .int(1)]),
            .object(["function": .string("f"), "count": .int(2_001)]),
            .object(["function": .string("f"), "count": .int(0)]),
            .object(["function": .string("f"), "count": .int(-1)]),
        ]
    }

    private var smallAddressInstructionCases: [(ScriptValue, Int)] {
        [
            (.object(["address": .hex(0x1000)]), 16),
            (.object(["function": .null, "address": .hex(0x1000), "count": .null]), 16),
            (.object(["function": .null, "address": .hex(0x1000), "count": .int(1)]), 1),
            (.object(["address": .hex(0x1000), "count": .int(0)]), 0),
            (.object(["address": .hex(0x1000), "count": .int(-1)]), 0),
        ]
    }

    private func attachedExecutor(_ store: WorkspaceStore) -> MCPAttachExecutor {
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        executor.setConsent(.allowed)
        return executor
    }

    /// Attached admission rejects null/negative integers before applying list caps.
    /// Nonattached API callers retain their separate null/negative compatibility contract.
    private func assertAttachedRejectsInvalidCount(
        _ executor: MCPAttachExecutor, command: String, arguments: ScriptValue,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await executor.execute(command, arguments)
            XCTFail("Attached admission must reject null or negative counts", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? HeadlessAutomationAuthorityError, .invalidArguments, file: file, line: line)
        }
    }

    private func assertListRows(_ value: ScriptValue, command: String, count: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let rows = value.arrayValue else { return XCTFail("expected \(command) array", file: file, line: line) }
        XCTAssertEqual(rows.count, count, command, file: file, line: line)
        let key = command == "strings" ? "value" : (command == "relocations" ? "address" : "name")
        let identities: [ScriptValue?] = (0..<count).map { index in
            command == "relocations" ? .hex(0x1000 + UInt64(index * 4)) : .string("row\(index)")
        }
        XCTAssertEqual(rows.map { $0[key] }, identities, "\(command) must retain the requested prefix in source order", file: file, line: line)
    }

    private func assertInstructions(_ value: ScriptValue, count: Int,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let rows = value.arrayValue else { return XCTFail("expected instruction array", file: file, line: line) }
        XCTAssertEqual(rows.count, count, file: file, line: line)
        let addresses: [ScriptValue?] = (0..<count).map { .hex(0x1000 + UInt64($0 * 4)) }
        XCTAssertEqual(rows.map { $0["address"] }, addresses, "must preserve instruction order and include the tail", file: file, line: line)
    }

    private func makeInstructionStore(count: Int) -> WorkspaceStore {
        let snapshot = WorkspaceSnapshot(binaries: [], functions: [
            FunctionSummary(id: UUID(), name: "f", startAddress: 0x1000,
                            endAddress: 0x1000 + UInt64(count * 4), confidence: 1),
        ], instructions: (0..<count).map {
            InstructionRow(address: 0x1000 + UInt64($0 * 4), bytes: "1f 20 03 d5",
                           mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil)
        }, xrefs: [], hexBytes: Data())
        return makeStore(snapshot)
    }

    private func makeListStore(_ command: String, count: Int) -> WorkspaceStore {
        var analysis = ImageAnalysis()
        for index in 0..<count {
            let name = "row\(index)"
            let address = UInt64(0x1000 + index * 4)
            switch command {
            case "functions":
                analysis.functions.append(FunctionSummary(id: UUID(), name: name, startAddress: address,
                                                           endAddress: address + 4, confidence: 1))
            case "symbols":
                analysis.symbols.append(SymbolSummary(id: UUID(), name: name, address: address,
                                                       kind: "local", libraryName: nil))
            case "strings":
                analysis.stringLiterals.append(StringLiteralSummary(id: UUID(), value: name, address: address,
                                                                     sourceSection: "__cstring", byteLength: name.utf8.count))
            case "imports":
                analysis.imports.append(ImportSummary(id: UUID(), name: name, libraryName: "synthetic", libraryOrdinal: 1))
            case "exports":
                analysis.exports.append(ExportSummary(id: UUID(), name: name, address: address, source: "synthetic"))
            case "sections":
                analysis.sections.append(SectionSummary(id: UUID(), name: name, address: address,
                                                         size: 4, fileOffset: UInt64(index * 4), isExecutable: false))
            case "relocations":
                analysis.relocations.append(RelocationSummary(id: UUID(), address: address, sectionName: "synthetic",
                                                               typeCode: 0, typeName: nil, symbolName: nil,
                                                               symbolIndex: nil, addend: nil))
            default:
                XCTFail("unsupported synthetic list command: \(command)")
            }
        }
        return makeStore(WorkspaceSnapshot(binaries: [], analysisBySlot: [.primary: analysis]))
    }

    private func makeStore(_ snapshot: WorkspaceSnapshot) -> WorkspaceStore {
        WorkspaceStore(workspaceName: "DP23 list limits", snapshot: snapshot,
                       engine: AnalysisEngine(), autosaveScheduler: nil)
    }
}
