import XCTest
@testable import MacScope

/// DEF-A03, DEF-A04, DEF-A06 and DEF-A09 on the search/graph MCP surface: typed refusal of an
/// invalid regex and of an over-long query, `imageSlot` on every `search`, `callers`, `callees`
/// and `xrefs` row (and as an optional row filter) on a hermetic two-image workspace, and the
/// attached allowlist additions.
@MainActor
final class MCPSearchHygieneTests: XCTestCase {
    private let sibling = ImageSlot(rawValue: 1)
    private let callerStart: UInt64 = 0x1000
    private let calleeStart: UInt64 = 0x2000

    // MARK: - Fixture

    /// Two arm64 images whose addresses collide. Both hold a `caller` at 0x1000 and a `callee`
    /// at 0x2000 and an instruction at 0x1000 whose mnemonic is `mov`. The primary image has one
    /// call edge 0x1004 -> 0x2000; the sibling has two (0x1004 and 0x1008 -> 0x2000), so the
    /// image that answered is visible in the row count as well as in `imageSlot`.
    private func makeTwoImageStore() -> WorkspaceStore {
        func image(_ slot: ImageSlot) -> BinaryImage {
            BinaryImage(
                id: UUID(), name: "image\(slot.rawValue)", path: "/tmp/p4-hygiene-image\(slot.rawValue)",
                kind: "Mach-O executable", architecture: "arm64", slot: slot
            )
        }
        func analysis(operands: String, callSites: [UInt64]) -> ImageAnalysis {
            var result = ImageAnalysis()
            result.functions = [
                FunctionSummary(id: UUID(), name: "caller", startAddress: callerStart,
                                endAddress: callerStart + 0x10, confidence: 1),
                FunctionSummary(id: UUID(), name: "callee", startAddress: calleeStart,
                                endAddress: calleeStart + 0x10, confidence: 1),
            ]
            result.instructions = [InstructionRow(
                address: callerStart, bytes: "e0 03 01 aa", mnemonic: "mov", operands: operands,
                hasBreakpoint: false, comment: nil
            )]
            result.xrefs = callSites.map {
                XRef(id: UUID(), from: $0, to: calleeStart, kind: XRefKind.call)
            }
            return result
        }
        let snapshot = WorkspaceSnapshot(
            binaries: [image(.primary), image(sibling)],
            analysisBySlot: [
                .primary: analysis(operands: "x0, x1", callSites: [0x1004]),
                sibling: analysis(operands: "x2, x3", callSites: [0x1004, 0x1008]),
            ]
        )
        return WorkspaceStore(
            workspaceName: "P4 hygiene", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil
        )
    }

    private func requestValue(_ name: String, _ arguments: ScriptValue) -> ScriptValue {
        .object([
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
            "params": .object(["name": .string(name), "arguments": arguments]),
        ])
    }

    private func request(_ name: String, _ arguments: ScriptValue) throws -> Data {
        try requestValue(name, arguments).jsonData()
    }

    /// The decoded tool result text of a `tools/call` response, asserting it is not a tool failure.
    private func toolOutput(_ response: Data?, file: StaticString = #filePath, line: UInt = #line) throws -> ScriptValue {
        try toolOutput(envelope: try ScriptValue.decode(try XCTUnwrap(response, file: file, line: line)), file: file, line: line)
    }

    private func toolOutput(envelope: ScriptValue?, file: StaticString = #filePath, line: UInt = #line) throws -> ScriptValue {
        let envelope = try XCTUnwrap(envelope, file: file, line: line)
        XCTAssertNil(envelope["error"], file: file, line: line)
        XCTAssertEqual(envelope["result"]?["isError"], .bool(false), file: file, line: line)
        let text = try XCTUnwrap(
            envelope["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, file: file, line: line)
        return try ScriptValue.decode(Data(text.utf8))
    }

    private func slots(_ rows: ScriptValue?) -> [Int64] {
        (rows?.arrayValue ?? []).compactMap { $0["imageSlot"]?.intValue }
    }

    // MARK: - DEF-A09 / DEF-A03: typed refusals

    func testQueryCapIs256BytesAndDocumentedInTheSchema() throws {
        XCTAssertEqual(HeadlessAutomationAuthority.maximumSearchQueryBytes, 256)
        let search = try XCTUnwrap(HeadlessAutomationAuthority.availableCommands.first { $0.name == "search" })
        let schema = HeadlessAutomationAuthority.inputSchema(for: search)
        let description = try XCTUnwrap(schema["properties"]?["query"]?["description"]?.stringValue)
        XCTAssertTrue(description.contains("256"), description)
        XCTAssertNotNil(schema["properties"]?["imageSlot"])
    }

    func testOverLongQueryIsRefusedWithTypedTooLongOnEveryTransport() async throws {
        let store = makeTwoImageStore()
        let api = WorkspaceScriptingAPI(store: store)
        let expected = ScriptValue.object(["error": .string("invalidPattern"), "detail": .string("tooLong")])
        let queries = [
            String(repeating: "a", count: 300),
            String(repeating: "\u{e9}", count: 150), // 150 characters, 300 UTF-8 bytes
            String(repeating: "a", count: 257),
        ]
        for query in queries {
            let arguments = ScriptValue.object(["query": .string(query)])
            // validate no longer throws: the refusal is a typed result, not a -32602.
            XCTAssertNoThrow(try HeadlessAutomationAuthority.validate(command: "search", arguments: arguments))
            XCTAssertEqual(try HeadlessAutomationAuthority.execute(
                command: "search", arguments: arguments, api: api), expected)
            let asyncResult = try await HeadlessAutomationAuthority.executeAsync(
                command: "search", arguments: arguments, api: api)
            XCTAssertEqual(asyncResult, expected)
        }
        let server = MCPServer(api: api)
        let arguments = ScriptValue.object(["query": .string(String(repeating: "a", count: 300))])
        XCTAssertEqual(try toolOutput(envelope: server.handle(requestValue("search", arguments))), expected)
        let response = await server.handleMessageAsync(try request("search", arguments))
        XCTAssertEqual(try toolOutput(response), expected)
    }

    func testQueryAtTheCapAndTrimmedQueriesAreNotRefused() throws {
        let api = WorkspaceScriptingAPI(store: makeTwoImageStore())
        let atCap = String(repeating: "a", count: 256)
        for query in [atCap, "   " + atCap + "\n\n  "] {
            let output = try HeadlessAutomationAuthority.execute(
                command: "search", arguments: .object(["query": .string(query)]), api: api)
            XCTAssertNil(output["error"], query)
            XCTAssertEqual(output["total"], .int(0))
            XCTAssertEqual(output["results"], .array([]))
        }
    }

    func testInvalidRegexIsATypedRefusalNotAnEmptyResult() async throws {
        let api = WorkspaceScriptingAPI(store: makeTwoImageStore())
        let arguments = ScriptValue.object(["query": .string("(unclosed"), "mode": .string("regex")])
        let inline = try HeadlessAutomationAuthority.execute(command: "search", arguments: arguments, api: api)
        let detached = try await HeadlessAutomationAuthority.executeAsync(
            command: "search", arguments: arguments, api: api)
        XCTAssertEqual(inline["error"], .string("invalidPattern"))
        XCTAssertEqual(inline["detail"], .string("Invalid regular expression."))
        XCTAssertNil(inline["results"])
        XCTAssertEqual(detached, inline)

        let server = MCPServer(api: api)
        let response = await server.handleMessageAsync(try request("search", arguments))
        XCTAssertEqual(try toolOutput(response), inline)

        // The same text in text mode is a literal search, and a valid regex still searches.
        let literal = try HeadlessAutomationAuthority.execute(
            command: "search", arguments: .object(["query": .string("(unclosed")]), api: api)
        XCTAssertNil(literal["error"])
        XCTAssertEqual(literal["results"], .array([]))
        let valid = try HeadlessAutomationAuthority.execute(
            command: "search", arguments: .object(["query": .string("^mov\\b"), "mode": .string("regex")]), api: api)
        XCTAssertNil(valid["error"])
        XCTAssertEqual(slots(valid["results"]), [0, 1])
    }

    // MARK: - DEF-A04: imageSlot on rows, and as a filter

    func testSearchOnTwoImagesTagsEveryRowWithItsImage() async throws {
        let store = makeTwoImageStore()
        let api = WorkspaceScriptingAPI(store: store)
        let arguments = ScriptValue.object(["query": .string("mov")])
        let inline = try api.execute("search", arguments: arguments)
        XCTAssertEqual(inline["results"]?.arrayValue?.count, 2)
        XCTAssertEqual(slots(inline["results"]), [0, 1])
        XCTAssertEqual(inline["results"]?.arrayValue?.map { $0["preview"]?.stringValue },
                       ["mov x0, x1", "mov x2, x3"])
        XCTAssertEqual(inline["results"]?.arrayValue?.first, .object([
            "address": .hex(callerStart), "kind": .string("instruction"),
            "preview": .string("mov x0, x1"), "imageSlot": .int(0),
        ]))

        // The detached (MCP default) handler emits the same rows as the inline handler.
        let detached = try await api.executeAsync("search", arguments: arguments)
        XCTAssertEqual(detached["results"], inline["results"])
        let server = MCPServer(api: api)
        let viaServer = try toolOutput(await server.handleMessageAsync(try request("search", arguments)))
        XCTAssertEqual(viaServer["results"], inline["results"])
    }

    func testSearchImageSlotFilterRestrictsToOneImageAndRejectsUnknownSlots() async throws {
        let store = makeTwoImageStore()
        let api = WorkspaceScriptingAPI(store: store)
        for slot in [0, 1] {
            let arguments = ScriptValue.object(["query": .string("mov"), "imageSlot": .int(Int64(slot))])
            let inline = try api.execute("search", arguments: arguments)
            let detached = try await api.executeAsync("search", arguments: arguments)
            XCTAssertEqual(slots(inline["results"]), [Int64(slot)])
            XCTAssertEqual(inline["total"], .int(1))
            XCTAssertEqual(detached["results"], inline["results"])
        }
        // A decimal-string selector names the same image.
        let byString = try api.execute("search", arguments: .object([
            "query": .string("mov"), "imageSlot": .string("1"),
        ]))
        XCTAssertEqual(slots(byString["results"]), [1])
        // The filter is a row filter: the focused image does not change what an unfiltered search sees.
        store.focusImage(sibling)
        XCTAssertEqual(slots(try api.execute("search", arguments: .object(["query": .string("mov")]))["results"]), [0, 1])

        let unknown = ScriptValue.object(["query": .string("mov"), "imageSlot": .int(7)])
        XCTAssertThrowsError(try api.execute("search", arguments: unknown)) { error in
            XCTAssertEqual(error as? ScriptingError, .unknownImage(selector: "7", validSlots: [0, 1]))
        }
        do {
            _ = try await api.executeAsync("search", arguments: unknown)
            XCTFail("an unknown imageSlot returned rows")
        } catch {
            XCTAssertEqual(error as? ScriptingError, .unknownImage(selector: "7", validSlots: [0, 1]))
        }
    }

    func testImageSlotShapeIsValidatedAtTheAuthority() {
        for bad in [ScriptValue.bool(true), .double(1.5), .array([]), .string(String(repeating: "7", count: 65)), .int(-1)] {
            XCTAssertThrowsError(try HeadlessAutomationAuthority.validate(
                command: "callers", arguments: .object(["address": .hex(calleeStart), "imageSlot": bad])), "\(bad)")
        }
        XCTAssertNoThrow(try HeadlessAutomationAuthority.validate(
            command: "callers", arguments: .object(["address": .hex(calleeStart), "imageSlot": .int(1)])))
    }

    func testCallersCalleesAndXRefsCarryAndHonourImageSlot() async throws {
        let api = WorkspaceScriptingAPI(store: makeTwoImageStore())
        // (command, arguments without a filter, rows in the primary image, rows in the sibling)
        let cases: [(String, [String: ScriptValue], Int, Int)] = [
            ("callers", ["address": .hex(calleeStart)], 1, 2),
            ("callees", ["function": .string("caller")], 1, 2),
            ("xrefs", ["to": .hex(calleeStart)], 1, 2),
        ]
        for (command, base, primaryCount, siblingCount) in cases {
            let unfiltered = try api.execute(command, arguments: .object(base))
            XCTAssertEqual(unfiltered.arrayValue?.count, primaryCount, command)
            XCTAssertEqual(slots(unfiltered), Array(repeating: 0, count: primaryCount), command)

            var filtered = base
            filtered["imageSlot"] = .int(1)
            let inline = try api.execute(command, arguments: .object(filtered))
            XCTAssertEqual(inline.arrayValue?.count, siblingCount, command)
            XCTAssertEqual(slots(inline), Array(repeating: 1, count: siblingCount), command)

            filtered["imageSlot"] = .int(0)
            XCTAssertEqual(try api.execute(command, arguments: .object(filtered)), unfiltered, command)

            // The detached/attached row builders emit the same JSON as the inline handlers.
            for arguments in [base, base.merging(["imageSlot": ScriptValue.int(1)]) { $1 }] {
                let detached = try await api.executeAsync(command, arguments: .object(arguments))
                let expected = try api.execute(command, arguments: .object(arguments))
                XCTAssertEqual(try detached.jsonData(), try expected.jsonData(), command)
            }
        }
        let edge = try api.execute("callers", arguments: .object(["address": .hex(calleeStart), "imageSlot": .int(1)]))
        XCTAssertEqual(edge.arrayValue?.first, .object([
            "from": .hex(0x1004), "to": .hex(calleeStart), "imageSlot": .int(1),
        ]))
        let ref = try api.execute("xrefs", arguments: .object(["to": .hex(calleeStart)]))
        XCTAssertEqual(ref.arrayValue?.first?["kind"], .string(XRefKind.call))
    }

    // MARK: - DEF-A06: attached allowlist

    func testAttachedAllowlistAdmitsMaterialisedReadsAndExcludesFreshAnalysis() throws {
        let added: Set<String> = ["read-evidence", "reconstruction-jobs"]
        XCTAssertTrue(added.isSubset(of: MCPAttachExecutor.attachCommands))
        let infos = WorkspaceScriptingAPI.availableCommands.filter { added.contains($0.name) }
        XCTAssertEqual(Set(infos.map(\.name)), added)
        XCTAssertTrue(infos.allSatisfy { !$0.mutates }, "an admitted read must not mutate")
        let headless = Set(HeadlessAutomationAuthority.availableCommands.map(\.name))
        XCTAssertTrue(MCPAttachExecutor.attachCommands.isSubset(of: headless))
        // Commands with a stated exclusion reason stay excluded.
        for excluded in ["neon-hitrate", "call-argument-audit", "define-types-from-c", "goto", "open-workspace",
                         "save-workspace", "make-procedure", "rebase-segment"] {
            XCTAssertFalse(MCPAttachExecutor.attachCommands.contains(excluded), excluded)
        }
        // The attached catalogue lists them.
        let catalogue = MCPAttachExecutor.attachCatalog(.array(infos.map {
            .object(["name": .string($0.name)])
        }))
        XCTAssertEqual(catalogue.arrayValue?.count, added.count)
    }

    func testAttachedExecutorServesTheAdditionsAndTheTypedSearchRefusal() async throws {
        let store = makeTwoImageStore()
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        executor.setConsent(.allowed)
        let jobs = try await executor.execute("reconstruction-jobs", .object([:]))
        XCTAssertEqual(jobs, .array([]))
        let evidence = try await executor.execute("read-evidence", .object(["operation": .string("workspace.summary")]))
        XCTAssertEqual(evidence["proposingPrincipal"], .string("mcp"))
        XCTAssertEqual(evidence["authorizingPrincipal"], .string("app"))
        let refusal = try await executor.execute("search", .object(["query": .string(String(repeating: "a", count: 300))]))
        XCTAssertEqual(refusal, .object(["error": .string("invalidPattern"), "detail": .string("tooLong")]))
        let rows = try await executor.execute("search", .object(["query": .string("mov"), "imageSlot": .int(1)]))
        XCTAssertEqual(slots(rows["results"]), [1])
        let callers = try await executor.execute("callers", .object(["address": .hex(calleeStart), "imageSlot": .int(1)]))
        XCTAssertEqual(slots(callers), [1, 1])
    }
}
