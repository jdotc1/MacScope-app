import XCTest
@testable import MacScope
@testable import MacScopeAnalysisCore

/// The navigator MCP surface (`MCPServer+Navigator.swift`): the nine `navigator-*` commands, typed
/// absence, cursors bound to the analysis generation, the 4 KiB hex bound, the closed command
/// authority, the attached allowlist, and the `list-image-types` Swift fields.
///
/// Command semantics are driven through `NavigatorSurface` over an in-memory `NavigatorContractStore`
/// (the same type the workspace holds), so every expectation below follows from the store rules in
/// `NavigatorContractStore` and the handlers as written. The transport tests drive `MCPServer` the
/// way `MCPServerTests` does, on a hermetic one-image workspace.
@MainActor
final class MCPNavigatorCommandTests: XCTestCase {
    // MARK: - Fixtures

    private let slotKey = NavigatorMCPCommands.imageSlotKey

    /// An in-memory navigator state behind a `NavigatorSurface`. Primary image only.
    ///
    /// Facts (toolchain `arm64-test`):
    /// - `a`  authoritative isFunctionStart true on function 0x1000
    /// - `b`  authoritative hasName "_main" on function 0x1000
    /// - `d1` derived isFunctionStart true on function 0x2000, from `a`
    /// - `d2` derived hasName "sub_2000" on function 0x2000, from `d1`
    /// - `d3` derived isFunctionStart true on function 0x5000, from the premise of `note`
    /// Annotation `note`: navigator setFact hasType "int" on 0x1000, session s1 seq 1, citing `a`.
    /// Frontier: f1 (leverage 5, cheap), f2 (9, bounded), f3 (9, cheap), f4 (1, unrated).
    @MainActor
    private final class Harness {
        var store: NavigatorContractStore?
        var generation = "gen-1"
        var input: NavigatorImageInput?
        var certificates: [NavigatorProofCertificate] = []
        private(set) var acceptCalls: [String] = []
        private(set) var revertCalls: [(handle: String, session: String)] = []

        let a: NavigatorFact
        let b: NavigatorFact
        let d1: NavigatorFact
        let d2: NavigatorFact
        let d3: NavigatorFact
        let note: NavigatorAnnotation
        let f1: NavigatorFrontierItem
        let f2: NavigatorFrontierItem
        let f3: NavigatorFrontierItem
        let f4: NavigatorFrontierItem

        static let toolchain = "arm64-test"

        static func function(_ address: String) -> NavigatorSubject { NavigatorSubject(kind: "function", ref: address) }
        static func rule(_ id: String = "macho.slice-identity") -> NavigatorProvenance {
            NavigatorProvenance(kind: "rule", ref: "\(id)@1", rule: id, ruleVersion: "1")
        }

        init() throws {
            let toolchain = Self.toolchain
            a = try NavigatorFact.make(
                subject: Self.function("0x1000"), predicate: "isFunctionStart", value: .bool(true),
                status: "authoritative", provenance: [NavigatorProvenance(kind: "loaderRecord", ref: "lc[0]")],
                toolchain: toolchain)
            b = try NavigatorFact.make(
                subject: Self.function("0x1000"), predicate: "hasName", value: .string("_main"),
                status: "authoritative", provenance: [NavigatorProvenance(kind: "loaderRecord", ref: "lc[1]")],
                toolchain: toolchain)
            d1 = try NavigatorFact.make(
                subject: Self.function("0x2000"), predicate: "isFunctionStart", value: .bool(true),
                status: "derived", provenance: [Self.rule()], toolchain: toolchain, tier: 1, derivedFrom: [[a.id]])
            d2 = try NavigatorFact.make(
                subject: Self.function("0x2000"), predicate: "hasName", value: .string("sub_2000"),
                status: "derived", provenance: [Self.rule()], toolchain: toolchain, tier: 2, derivedFrom: [[d1.id]])
            note = try NavigatorAnnotation.make(
                session: "s1", seq: 1, author: "navigator", action: "setFact", subject: Self.function("0x1000"),
                predicate: "hasType", value: .string("int"), cites: [a.id], rationale: "because")
            d3 = try NavigatorFact.make(
                subject: Self.function("0x5000"), predicate: "isFunctionStart", value: .bool(true),
                status: "derived", provenance: [Self.rule()], toolchain: toolchain, tier: 1,
                derivedFrom: [[note.premise]])
            f1 = try NavigatorFrontierItem.make(
                subject: Self.function("0x3000"), gap: "unnamedFunction", detail: "f1", toolchain: toolchain,
                primitives: [NavigatorPrimitiveRef(name: "macho.slice-identity", preconditions: [])], leverage: 5)
            f2 = try NavigatorFrontierItem.make(
                subject: NavigatorSubject(kind: "type", ref: "name:Foo"), gap: "unknownType", detail: "f2",
                toolchain: toolchain,
                primitives: [NavigatorPrimitiveRef(name: "objc.class-parser", preconditions: [])], leverage: 9)
            f3 = try NavigatorFrontierItem.make(
                subject: Self.function("0x4000"), gap: "unnamedFunction", detail: "f3", toolchain: toolchain,
                primitives: [NavigatorPrimitiveRef(name: "macho.slice-identity", preconditions: [])], leverage: 9)
            f4 = try NavigatorFrontierItem.make(
                subject: Self.function("0x6000"), gap: "boundaryUncertain", detail: "f4", toolchain: toolchain,
                primitives: [NavigatorPrimitiveRef(name: "no.such.primitive", preconditions: [])], leverage: 1)

            var seeded = NavigatorContractStore(
                toolchain: toolchain, baseFacts: [a, b, d1, d2, d3], baseFrontier: [f1, f2, f3, f4])
            guard seeded.accept(note) == nil else { throw SeedError.annotationRefused }
            store = seeded
        }

        enum SeedError: Error { case annotationRefused }

        var liveIDs: [String] { [a, b, d1, d2, d3].map(\.id).sorted() }

        func surface() -> NavigatorSurface {
            NavigatorSurface(
                resolveImage: { raw in
                    switch raw {
                    case .int(0), .string("0"): return .primary
                    default: return nil
                    }
                },
                state: { [unowned self] slot in slot == .primary ? self.store : nil },
                generationKey: { [unowned self] _ in self.generation },
                image: { [unowned self] slot in slot == .primary ? self.input : nil },
                certificates: { [unowned self] _ in self.certificates },
                accept: { [unowned self] annotation, _ in
                    self.acceptCalls.append(annotation.id)
                    guard var copy = self.store else { return nil }
                    let refusal = copy.accept(annotation)
                    self.store = copy
                    return refusal
                },
                revert: { [unowned self] handle, session, _ in
                    self.revertCalls.append((handle, session))
                    guard var copy = self.store else { return nil }
                    let refusal = copy.revert(handle, session: session)
                    self.store = copy
                    return refusal
                })
        }
    }

    private func run(_ command: String, _ harness: Harness, _ arguments: [String: ScriptValue] = [:]) throws -> ScriptValue {
        var fields = arguments
        if fields[slotKey] == nil { fields[slotKey] = .int(0) }
        return try NavigatorMCPCommands.execute(command: command, arguments: .object(fields), surface: harness.surface())
    }

    private func runAsync(_ command: String, _ harness: Harness, _ arguments: [String: ScriptValue] = [:]) async throws -> ScriptValue {
        var fields = arguments
        if fields[slotKey] == nil { fields[slotKey] = .int(0) }
        return try await NavigatorMCPCommands.executeAsync(
            command: command, arguments: .object(fields), surface: harness.surface())
    }

    private func ids(_ rows: ScriptValue?) -> [String] { (rows?.arrayValue ?? []).compactMap { $0["id"]?.stringValue } }
    private func strings(_ rows: ScriptValue?) -> [String] { (rows?.arrayValue ?? []).compactMap(\.stringValue) }
    private func absence(_ value: ScriptValue) -> String? { value["absent"]?["reason"]?.stringValue }

    private func refusalCode(_ value: ScriptValue) -> String? {
        guard value["error"] == .string("refused") else { return nil }
        return value["refusal"]?["code"]?.stringValue
    }

    private func subjectValue(_ ref: String, kind: String = "function") -> ScriptValue {
        .object(["kind": .string(kind), "ref": .string(ref)])
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func sha256(_ data: Data, _ range: Range<Int>) -> String {
        AnalysisFingerprintBuilder.sha256Hex(Data(data[(data.startIndex + range.lowerBound) ..< (data.startIndex + range.upperBound)]))
    }

    private var missingFactID: String { "f-" + String(repeating: "0", count: 32) }

    // MARK: - Catalog and schemas

    func testCatalogHasAllNineCommandsAndOnlyAcceptAndRevertMutate() {
        XCTAssertEqual(NavigatorMCPCommands.names.count, 9)
        XCTAssertEqual(Set(NavigatorMCPCommands.catalog.map(\.name)), Set(NavigatorMCPCommands.names))
        XCTAssertEqual(
            NavigatorMCPCommands.catalog.filter(\.mutates).map(\.name).sorted(),
            [NavigatorMCPCommands.nameAccept, NavigatorMCPCommands.nameRevert].sorted())
        let authority = Set(HeadlessAutomationAuthority.availableCommands.map(\.name))
        XCTAssertTrue(Set(NavigatorMCPCommands.names).isSubset(of: authority))
        for command in NavigatorMCPCommands.catalog {
            XCTAssertTrue(command.arguments.contains(slotKey), command.name)
            XCTAssertFalse(command.summary.isEmpty, command.name)
        }
    }

    func testAttachableSetIsEveryReadAndAcceptButNotRevert() {
        XCTAssertEqual(NavigatorMCPCommands.attachable.count, 8)
        XCTAssertTrue(NavigatorMCPCommands.attachable.contains(NavigatorMCPCommands.nameAccept))
        XCTAssertFalse(NavigatorMCPCommands.attachable.contains(NavigatorMCPCommands.nameRevert))
        XCTAssertTrue(NavigatorMCPCommands.attachable.isSubset(of: MCPAttachExecutor.attachCommands))
        XCTAssertFalse(MCPAttachExecutor.attachCommands.contains(NavigatorMCPCommands.nameRevert))
        XCTAssertFalse(AppleScriptCommandTranslator.allowlistedCommandIDs.contains(NavigatorMCPCommands.nameRevert))
        XCTAssertFalse(AppleScriptCommandTranslator.allowlistedCommandIDs.contains(NavigatorMCPCommands.nameAccept))
    }

    func testRequiredArgumentsAndInputSchemasOnToolsList() throws {
        let server = MCPServer(api: WorkspaceScriptingAPI(store: makeSingleImageStore()))
        let response = try XCTUnwrap(server.handle(.object([
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/list"),
        ])))
        let tools = try XCTUnwrap(response["result"]?["tools"]?.arrayValue)
        var byName: [String: ScriptValue] = [:]
        for tool in tools { if let name = tool["name"]?.stringValue { byName[name] = tool } }

        let expectedRequired: [String: [String]] = [
            NavigatorMCPCommands.nameFacts: [slotKey],
            NavigatorMCPCommands.nameFrontier: [slotKey],
            NavigatorMCPCommands.nameDependents: [slotKey, "id"],
            NavigatorMCPCommands.namePrimitives: [slotKey],
            NavigatorMCPCommands.namePreviewRevert: [slotKey, "id"],
            NavigatorMCPCommands.nameRevert: [slotKey, "id", "session"],
            NavigatorMCPCommands.nameAccept: [slotKey, "annotation"],
            NavigatorMCPCommands.nameToolchain: [slotKey],
            NavigatorMCPCommands.nameResolveProvenance: [slotKey, "provenance"],
        ]
        XCTAssertEqual(Set(expectedRequired.keys), Set(NavigatorMCPCommands.names))
        for (name, required) in expectedRequired {
            let tool = try XCTUnwrap(byName[name], "tools/list lacks \(name)")
            let schema = try XCTUnwrap(tool["inputSchema"])
            XCTAssertEqual(strings(schema["required"]), required, name)
            XCTAssertEqual(schema["additionalProperties"], .bool(false), name)
            let info = try XCTUnwrap(NavigatorMCPCommands.info(name))
            XCTAssertEqual(Set(schema["properties"]?.objectKeys ?? []), Set(info.arguments), name)
            XCTAssertNotNil(schema["properties"]?[slotKey]?["type"], name)
            let mutates = info.mutates
            let description = try XCTUnwrap(tool["description"]?.stringValue)
            XCTAssertEqual(description.contains("mutates the workspace"), mutates, name)
            XCTAssertEqual(tool["annotations"]?["readOnlyHint"], .bool(!mutates), name)
        }
        XCTAssertEqual(byName[NavigatorMCPCommands.nameFacts]?["inputSchema"]?["properties"]?["limit"]?["maximum"], .int(256))
        XCTAssertEqual(
            strings(byName[NavigatorMCPCommands.nameFrontier]?["inputSchema"]?["properties"]?["kind"]?["enum"]),
            NavigatorContractVocabulary.gaps)
    }

    // MARK: - Argument validation (-32602 on the transport)

    func testShapeErrorsAreInvalidArgumentsAndPageBoundsAreEnforced() {
        func valid(_ command: String, _ extra: [String: ScriptValue]) throws {
            var fields = extra
            if fields[slotKey] == nil { fields[slotKey] = .int(0) }
            try NavigatorMCPCommands.validate(command: command, fields: fields)
        }
        XCTAssertNoThrow(try valid(NavigatorMCPCommands.nameFacts, [:]))
        XCTAssertNoThrow(try valid(NavigatorMCPCommands.nameFacts, ["limit": .int(256)]))
        XCTAssertNoThrow(try valid(NavigatorMCPCommands.nameFacts, ["limit": .int(1)]))
        XCTAssertThrowsError(try valid(NavigatorMCPCommands.nameFacts, ["limit": .int(0)]))
        XCTAssertThrowsError(try valid(NavigatorMCPCommands.nameFacts, ["limit": .int(257)]))
        XCTAssertThrowsError(try valid(NavigatorMCPCommands.nameFacts, ["limit": .string("5")]))
        XCTAssertThrowsError(try valid(NavigatorMCPCommands.nameFrontier, ["limit": .int(-1)]))
        XCTAssertThrowsError(try valid(NavigatorMCPCommands.nameFacts, ["subject": .string("function")]))
        XCTAssertThrowsError(try valid(NavigatorMCPCommands.nameFacts, ["includeStale": .string("yes")]))
        XCTAssertThrowsError(try valid(NavigatorMCPCommands.nameDependents, [:]), "id is required")
        XCTAssertThrowsError(try valid(NavigatorMCPCommands.nameDependents, ["id": .string("")]))
        XCTAssertThrowsError(try valid(
            NavigatorMCPCommands.nameDependents, ["id": .string(String(repeating: "f", count: 513))]))
        XCTAssertThrowsError(try valid(NavigatorMCPCommands.nameAccept, [:]), "annotation is required")
        XCTAssertThrowsError(try valid(NavigatorMCPCommands.nameAccept, ["annotation": .string("{}")]))
        XCTAssertThrowsError(try valid(NavigatorMCPCommands.nameResolveProvenance, [:]), "provenance is required")
        XCTAssertThrowsError(try NavigatorMCPCommands.validate(command: NavigatorMCPCommands.nameFacts, fields: [:]),
                             "imageSlot is required")
    }

    func testRevertNeedsANonEmptySessionWithoutControlCharacters() {
        func valid(_ session: ScriptValue?) throws {
            var fields: [String: ScriptValue] = [slotKey: .int(0), "id": .string(missingFactID)]
            if let session { fields["session"] = session }
            try NavigatorMCPCommands.validate(command: NavigatorMCPCommands.nameRevert, fields: fields)
        }
        XCTAssertNoThrow(try valid(.string("s-agent")))
        XCTAssertThrowsError(try valid(nil))
        XCTAssertThrowsError(try valid(.string("")))
        XCTAssertThrowsError(try valid(.string("a\nb")))
        XCTAssertThrowsError(try valid(.string("a\u{7f}b")))
        XCTAssertThrowsError(try valid(.string(String(repeating: "s", count: 129))))
        XCTAssertThrowsError(try valid(.int(3)))
    }

    // MARK: - navigator-facts

    func testFactsPageWithOpaqueCursorsBoundToTheGeneration() throws {
        let harness = try Harness()
        XCTAssertEqual(harness.liveIDs.count, 5)
        XCTAssertEqual(harness.store?.liveFacts().keys.sorted(), harness.liveIDs)

        var collected: [String] = []
        var firstCursor: String?
        var cursor: String?
        var pages = 0
        repeat {
            var arguments: [String: ScriptValue] = ["limit": .int(2)]
            if let cursor { arguments["cursor"] = .string(cursor) }
            let page = try run(NavigatorMCPCommands.nameFacts, harness, arguments)
            let rows = ids(page["facts"])
            XCTAssertFalse(rows.isEmpty)
            XCTAssertLessThanOrEqual(rows.count, 2)
            collected += rows
            pages += 1
            cursor = page["next"]?.stringValue
            if let cursor {
                XCTAssertEqual(cursor, NavigatorMCPCommands.encodeCursor(offset: collected.count, generation: "gen-1"))
                if firstCursor == nil { firstCursor = cursor }
            } else {
                XCTAssertEqual(rows.count, 1, "the last page holds the remainder")
            }
        } while cursor != nil && pages < 10
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(collected, harness.liveIDs, "pages concatenate to every live fact, sorted by id, once each")

        // The cursor is opaque base64 of (offset, generation key).
        let first = try XCTUnwrap(firstCursor)
        XCTAssertEqual(first, Data("v1|2|gen-1".utf8).base64EncodedString())

        // The same cursor under another generation is exactly {error: "staleCursor"}.
        harness.generation = "gen-2"
        let stale = try run(NavigatorMCPCommands.nameFacts, harness, ["limit": .int(2), "cursor": .string(first)])
        XCTAssertEqual(stale, .object(["error": .string("staleCursor")]))
        // Restarting without a cursor works, and mints cursors for the new generation.
        let restart = try run(NavigatorMCPCommands.nameFacts, harness, ["limit": .int(2)])
        XCTAssertEqual(restart["next"]?.stringValue, NavigatorMCPCommands.encodeCursor(offset: 2, generation: "gen-2"))
        // Frontier cursors carry the same fence.
        let frontierPage = try run(NavigatorMCPCommands.nameFrontier, harness, ["limit": .int(1)])
        let frontierCursor = try XCTUnwrap(frontierPage["next"]?.stringValue)
        harness.generation = "gen-3"
        XCTAssertEqual(
            try run(NavigatorMCPCommands.nameFrontier, harness, ["limit": .int(1), "cursor": .string(frontierCursor)]),
            .object(["error": .string("staleCursor")]))
    }

    func testCursorEncodingRoundTripsAndMalformedCursorsAreRefusedByValidation() throws {
        for (offset, generation) in [(0, "g"), (7, "a|b|c"), (255, "sha256:" + String(repeating: "ab", count: 32)), (12, "")] {
            let text = NavigatorMCPCommands.encodeCursor(offset: offset, generation: generation)
            let decoded = try XCTUnwrap(NavigatorMCPCommands.decodeCursor(text), generation)
            XCTAssertEqual(decoded.offset, offset)
            XCTAssertEqual(decoded.generation, generation)
        }
        let garbage = [
            "!!!not base64!!!",
            Data("x|1|g".utf8).base64EncodedString(),
            Data("v1|abc|g".utf8).base64EncodedString(),
            Data("v1||g".utf8).base64EncodedString(),
            Data("v1|1234567890|g".utf8).base64EncodedString(),
            Data("v1|5".utf8).base64EncodedString(),
            "",
        ]
        for text in garbage {
            XCTAssertNil(NavigatorMCPCommands.decodeCursor(text), text)
            XCTAssertThrowsError(try NavigatorMCPCommands.validate(
                command: NavigatorMCPCommands.nameFacts, fields: [slotKey: .int(0), "cursor": .string(text)]), text)
        }
        let good = NavigatorMCPCommands.encodeCursor(offset: 1, generation: "g")
        XCTAssertNoThrow(try NavigatorMCPCommands.validate(
            command: NavigatorMCPCommands.nameFacts, fields: [slotKey: .int(0), "cursor": .string(good)]))
    }

    func testFactsRowsAreContractFactsAndFiltersCompose() throws {
        let harness = try Harness()
        let all = try run(NavigatorMCPCommands.nameFacts, harness)
        XCTAssertNil(all["next"], "a single page has no cursor")
        XCTAssertEqual(ids(all["facts"]), harness.liveIDs)
        let rowA = try XCTUnwrap(all["facts"]?.arrayValue?.first { $0["id"]?.stringValue == harness.a.id })
        XCTAssertEqual(rowA, NavigatorMCPCommands.script(harness.a.json))
        XCTAssertEqual(rowA["kind"], .string("Fact"))

        let atSubject = try run(NavigatorMCPCommands.nameFacts, harness, ["subject": subjectValue("0x1000")])
        XCTAssertEqual(ids(atSubject["facts"]), [harness.a.id, harness.b.id].sorted())
        let byPredicate = try run(NavigatorMCPCommands.nameFacts, harness, ["predicate": .string("isFunctionStart")])
        XCTAssertEqual(ids(byPredicate["facts"]), [harness.a.id, harness.d1.id, harness.d3.id].sorted())
        let byStatus = try run(NavigatorMCPCommands.nameFacts, harness, ["status": .string("derived")])
        XCTAssertEqual(ids(byStatus["facts"]), [harness.d1.id, harness.d2.id, harness.d3.id].sorted())
        let combined = try run(NavigatorMCPCommands.nameFacts, harness, [
            "subject": subjectValue("0x2000"), "predicate": .string("hasName"), "status": .string("derived"),
        ])
        XCTAssertEqual(ids(combined["facts"]), [harness.d2.id])
    }

    func testStaleFactsAreLeftOutUnlessIncludeStaleAndAbsenceNamesThem() throws {
        let harness = try Harness()
        _ = harness.store?.markStale([harness.a.id])
        // `a` is stale; `d1`/`d2` rest on it and `d3` rests on the annotation citing it, so only `b` is live.
        XCTAssertEqual(harness.store?.liveFacts().keys.sorted(), [harness.b.id])
        let live = try run(NavigatorMCPCommands.nameFacts, harness)
        XCTAssertEqual(ids(live["facts"]), [harness.b.id])
        let withStale = try run(NavigatorMCPCommands.nameFacts, harness, ["includeStale": .bool(true)])
        XCTAssertEqual(ids(withStale["facts"]), [harness.a.id, harness.b.id].sorted())

        let onlyStale = try run(NavigatorMCPCommands.nameFacts, harness, [
            "subject": subjectValue("0x1000"), "predicate": .string("isFunctionStart"),
        ])
        XCTAssertEqual(absence(onlyStale), "stale")
        XCTAssertEqual(onlyStale["absent"]?["subject"]?["imageSlot"], .int(0))
        let included = try run(NavigatorMCPCommands.nameFacts, harness, [
            "subject": subjectValue("0x1000"), "predicate": .string("isFunctionStart"), "includeStale": .bool(true),
        ])
        XCTAssertEqual(ids(included["facts"]), [harness.a.id])
    }

    func testFactsMissesAreTypedAbsenceWithAReason() throws {
        let harness = try Harness()
        let unknownSubject = try run(NavigatorMCPCommands.nameFacts, harness, ["subject": subjectValue("0x9999")])
        XCTAssertEqual(absence(unknownSubject), "noSuchSubject")
        XCTAssertEqual(unknownSubject["absent"]?["subject"]?["subject"], subjectValue("0x9999"))
        XCTAssertNil(unknownSubject["facts"])

        let knownSubjectNoMatch = try run(NavigatorMCPCommands.nameFacts, harness, [
            "subject": subjectValue("0x2000"), "predicate": .string("hasType"),
        ])
        XCTAssertEqual(absence(knownSubjectNoMatch), "noFacts")

        let noMatchStatus = try run(NavigatorMCPCommands.nameFacts, harness, ["status": .string("candidate")])
        XCTAssertEqual(absence(noMatchStatus), "noFacts")

        harness.store = nil
        XCTAssertEqual(absence(try run(NavigatorMCPCommands.nameFacts, harness)), "noFacts")

        harness.store = NavigatorContractStore(toolchain: Harness.toolchain)
        XCTAssertEqual(absence(try run(NavigatorMCPCommands.nameFacts, harness)), "noFacts")
    }

    func testUnknownImageIsNoSuchImageForEveryCommand() throws {
        let harness = try Harness()
        for command in NavigatorMCPCommands.names {
            let result = try run(command, harness, nonsenseArguments(command, slot: .int(7)))
            XCTAssertEqual(result, .object(["absent": .object([
                "subject": .object([slotKey: .int(7)]), "reason": .string("noSuchImage"),
            ])]), command)
        }
        XCTAssertTrue(harness.revertCalls.isEmpty)
        XCTAssertTrue(harness.acceptCalls.isEmpty)
    }

    func testOutOfVocabularyFilterValuesAreMalformedInputRefusals() throws {
        let harness = try Harness()
        let badPredicate = try run(NavigatorMCPCommands.nameFacts, harness, ["predicate": .string("noSuchPredicate")])
        XCTAssertEqual(refusalCode(badPredicate), "malformedInput")
        XCTAssertEqual(badPredicate["refusal"]?["retryable"], .bool(false))
        XCTAssertEqual(refusalCode(try run(NavigatorMCPCommands.nameFacts, harness, ["status": .string("bogus")])), "malformedInput")
        XCTAssertEqual(
            refusalCode(try run(NavigatorMCPCommands.nameFacts, harness, ["subject": subjectValue("x", kind: "bogus")])),
            "malformedInput")
        XCTAssertEqual(
            refusalCode(try run(NavigatorMCPCommands.nameFacts, harness, [
                "subject": .object(["kind": .string("function")]),
            ])), "malformedInput")
        XCTAssertEqual(
            refusalCode(try run(NavigatorMCPCommands.nameFrontier, harness, ["kind": .string("notAGap")])), "malformedInput")
    }

    // MARK: - navigator-frontier

    func testFrontierIsSortedByLeverageThenCostWithTheProducerCostClass() throws {
        let harness = try Harness()
        let result = try run(NavigatorMCPCommands.nameFrontier, harness)
        XCTAssertEqual(ids(result["items"]), [harness.f3.id, harness.f2.id, harness.f1.id, harness.f4.id])
        let classes = (result["items"]?.arrayValue ?? []).map { $0["costClass"]?.stringValue }
        XCTAssertEqual(classes, ["cheap", "bounded", "cheap", "unrated"])
        let leverage = (result["items"]?.arrayValue ?? []).compactMap { $0["leverage"]?.intValue }
        XCTAssertEqual(leverage, [9, 9, 5, 1])
        let row = try XCTUnwrap(result["items"]?.arrayValue?.first)
        XCTAssertEqual(row["kind"], .string("FrontierItem"))
        XCTAssertEqual(row["gap"], .string("unnamedFunction"))
        XCTAssertNil(result["next"])

        let cost = NavigatorMCPCommands.costRank(of: harness.f2, registry: .standard)
        XCTAssertEqual(cost.label, "bounded")
        let unrated = NavigatorMCPCommands.costRank(of: harness.f4, registry: .standard)
        XCTAssertEqual(unrated.label, "unrated")
        XCTAssertGreaterThan(unrated.rank, cost.rank)
    }

    func testFrontierKindFilterPagingAndAbsence() throws {
        let harness = try Harness()
        let unnamed = try run(NavigatorMCPCommands.nameFrontier, harness, ["kind": .string("unnamedFunction")])
        XCTAssertEqual(ids(unnamed["items"]), [harness.f3.id, harness.f1.id])

        let firstPage = try run(NavigatorMCPCommands.nameFrontier, harness, ["limit": .int(2)])
        XCTAssertEqual(ids(firstPage["items"]), [harness.f3.id, harness.f2.id])
        let cursor = try XCTUnwrap(firstPage["next"]?.stringValue)
        XCTAssertEqual(cursor, NavigatorMCPCommands.encodeCursor(offset: 2, generation: "gen-1"))
        let secondPage = try run(NavigatorMCPCommands.nameFrontier, harness, ["limit": .int(2), "cursor": .string(cursor)])
        XCTAssertEqual(ids(secondPage["items"]), [harness.f1.id, harness.f4.id])
        XCTAssertNil(secondPage["next"])

        let none = try run(NavigatorMCPCommands.nameFrontier, harness, ["kind": .string("unresolvedProtocol")])
        XCTAssertEqual(absence(none), "noFacts")
        XCTAssertEqual(none["absent"]?["subject"]?["kind"], .string("unresolvedProtocol"))

        harness.store = nil
        XCTAssertEqual(absence(try run(NavigatorMCPCommands.nameFrontier, harness)), "noFacts")
    }

    // MARK: - navigator-dependents


    func testDependentsRetainsRowTruncationAtDepthLimitWithLeafFrontier() throws {
        let harness = try Harness()
        var facts = [harness.a]
        var parent = harness.a.id
        for depth in 1...31 {
            let node = try NavigatorFact.make(subject: Harness.function("0x\(String(0x10000 + depth * 4, radix: 16))"),
                predicate: "isFunctionStart", value: .bool(true), status: "derived",
                provenance: [Harness.rule()], toolchain: Harness.toolchain, tier: 1, derivedFrom: [[parent]])
            facts.append(node)
            parent = node.id
        }
        for leaf in 0..<226 {
            facts.append(try NavigatorFact.make(subject: Harness.function("0x\(String(0x20000 + leaf * 4, radix: 16))"),
                predicate: "isFunctionStart", value: .bool(true), status: "derived",
                provenance: [Harness.rule()], toolchain: Harness.toolchain, tier: 1, derivedFrom: [[parent]]))
        }
        harness.store = NavigatorContractStore(toolchain: Harness.toolchain, baseFacts: facts)
        let result = try run(NavigatorMCPCommands.nameDependents, harness, ["id": .string(harness.a.id)])
        let rows = try XCTUnwrap(result["dependents"]?.arrayValue)
        XCTAssertEqual(rows.count, 256)
        XCTAssertEqual(rows.filter { $0["depth"]?.intValue == 32 }.count, 225)
        XCTAssertEqual(result["truncated"], .bool(true))
    }

    func testDependentsWalkFactsAndAnnotationsTransitively() throws {
        let harness = try Harness()
        let result = try run(NavigatorMCPCommands.nameDependents, harness, ["id": .string(harness.a.id)])
        XCTAssertEqual(result["id"], .string(harness.a.id))
        XCTAssertEqual(result["truncated"], .bool(false))
        let rows = try XCTUnwrap(result["dependents"]?.arrayValue)
        func depth(_ id: String) -> Int64? { rows.first { $0["id"]?.stringValue == id }?["depth"]?.intValue }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(depth(harness.d1.id), 1)
        XCTAssertEqual(depth(harness.note.id), 1)
        XCTAssertEqual(depth(harness.d2.id), 2)
        XCTAssertEqual(depth(harness.d3.id), 2)
        XCTAssertEqual(rows.compactMap { $0["depth"]?.intValue }, [1, 1, 2, 2], "sorted by depth, then id")
        let noteRow = try XCTUnwrap(rows.first { $0["id"]?.stringValue == harness.note.id })
        XCTAssertEqual(noteRow["kind"], .string("annotation"))
        XCTAssertEqual(noteRow["record"], NavigatorMCPCommands.script(harness.note.json))
        let factRow = try XCTUnwrap(rows.first { $0["id"]?.stringValue == harness.d2.id })
        XCTAssertEqual(factRow["kind"], .string("fact"))
        XCTAssertEqual(factRow["record"], NavigatorMCPCommands.script(harness.d2.json))
        XCTAssertTrue(rows.allSatisfy { $0["live"] == .bool(true) })
    }

    func testDependentsOfAnAnnotationByPremiseOrIDAndTheirMisses() throws {
        let harness = try Harness()
        for handle in [harness.note.premise, harness.note.id] {
            let result = try run(NavigatorMCPCommands.nameDependents, harness, ["id": .string(handle)])
            XCTAssertEqual(ids(result["dependents"]), [harness.d3.id], handle)
        }
        // A leaf fact has nothing resting on it: a reasoned absence, not an empty array.
        let leaf = try run(NavigatorMCPCommands.nameDependents, harness, ["id": .string(harness.d2.id)])
        XCTAssertEqual(absence(leaf), "noFacts")
        XCTAssertEqual(leaf["absent"]?["subject"]?["id"], .string(harness.d2.id))
        XCTAssertNil(leaf["dependents"])

        XCTAssertEqual(absence(try run(NavigatorMCPCommands.nameDependents, harness, ["id": .string(missingFactID)])),
                       "noSuchSubject")
        XCTAssertEqual(refusalCode(try run(NavigatorMCPCommands.nameDependents, harness, ["id": .string("nonsense")])),
                       "malformedInput")

        _ = harness.store?.markStale([harness.a.id])
        XCTAssertEqual(absence(try run(NavigatorMCPCommands.nameDependents, harness, ["id": .string(harness.a.id)])), "stale")
        harness.store = nil
        XCTAssertEqual(absence(try run(NavigatorMCPCommands.nameDependents, harness, ["id": .string(harness.a.id)])), "noFacts")
    }

    // MARK: - navigator-preview-revert / navigator-revert

    func testPreviewRevertReportsTheEffectAndChangesNothing() throws {
        let harness = try Harness()
        let before = harness.store?.liveFacts().keys.sorted()

        let preview = try run(NavigatorMCPCommands.namePreviewRevert, harness, ["id": .string(harness.d1.id)])
        XCTAssertEqual(preview["id"], .string(harness.d1.id))
        XCTAssertEqual(strings(preview["factsLost"]), [harness.d1.id, harness.d2.id].sorted())
        XCTAssertEqual(strings(preview["annotationsAffected"]), [])
        XCTAssertEqual(strings(preview["frontierRaised"]), [])
        XCTAssertNil(preview["reverted"])

        let byHandle = try run(NavigatorMCPCommands.namePreviewRevert, harness, ["id": .string(harness.d1.revert)])
        XCTAssertEqual(byHandle, preview, "a revert:<id> handle is the same request")

        let annotation = try run(NavigatorMCPCommands.namePreviewRevert, harness, ["id": .string(harness.note.id)])
        XCTAssertEqual(strings(annotation["annotationsAffected"]), [harness.note.id])
        XCTAssertEqual(strings(annotation["factsLost"]), [harness.d3.id])

        let authoritative = try run(NavigatorMCPCommands.namePreviewRevert, harness, ["id": .string(harness.a.id)])
        XCTAssertEqual(refusalCode(authoritative), "notReversible")

        XCTAssertEqual(absence(try run(NavigatorMCPCommands.namePreviewRevert, harness, ["id": .string(missingFactID)])),
                       "noSuchSubject")
        XCTAssertEqual(refusalCode(try run(NavigatorMCPCommands.namePreviewRevert, harness, ["id": .string("bogus")])),
                       "malformedInput")
        XCTAssertEqual(harness.store?.liveFacts().keys.sorted(), before)
        XCTAssertTrue(harness.revertCalls.isEmpty, "a preview never reaches the revert bridge")
    }

    func testRevertGoesThroughTheBridgeUnderTheSessionAndReportsTheEffect() throws {
        let harness = try Harness()
        let result = try run(NavigatorMCPCommands.nameRevert, harness, [
            "id": .string(harness.d1.id), "session": .string("s-agent"),
        ])
        XCTAssertEqual(result["reverted"], .bool(true))
        XCTAssertEqual(result["session"], .string("s-agent"))
        XCTAssertEqual(result["id"], .string(harness.d1.id))
        XCTAssertEqual(strings(result["factsLost"]), [harness.d1.id, harness.d2.id].sorted())
        XCTAssertEqual(harness.revertCalls.count, 1)
        XCTAssertEqual(harness.revertCalls.first?.handle, harness.d1.revert)
        XCTAssertEqual(harness.revertCalls.first?.session, "s-agent")
        XCTAssertNil(harness.store?.liveFacts()[harness.d1.id])
        XCTAssertNil(harness.store?.liveFacts()[harness.d2.id])
        XCTAssertNotNil(harness.store?.liveFacts()[harness.a.id])

        // Reverting it again: the fact is reverted, so it no longer exists as a subject.
        let again = try run(NavigatorMCPCommands.nameRevert, harness, [
            "id": .string(harness.d1.id), "session": .string("s-agent"),
        ])
        XCTAssertNil(again["reverted"])
        XCTAssertEqual(harness.revertCalls.count, 1, "no second revert reaches the bridge")
    }

    func testRevertRefusalsAndMissesNeverReachTheBridgeWithAChange() throws {
        let harness = try Harness()
        let authoritative = try run(NavigatorMCPCommands.nameRevert, harness, [
            "id": .string(harness.a.id), "session": .string("s-agent"),
        ])
        XCTAssertEqual(refusalCode(authoritative), "notReversible")
        XCTAssertNil(authoritative["reverted"])
        XCTAssertEqual(absence(try run(NavigatorMCPCommands.nameRevert, harness, [
            "id": .string(missingFactID), "session": .string("s"),
        ])), "noSuchSubject")
        XCTAssertEqual(refusalCode(try run(NavigatorMCPCommands.nameRevert, harness, [
            "id": .string("zzz"), "session": .string("s"),
        ])), "malformedInput")
        XCTAssertTrue(harness.revertCalls.isEmpty)
        XCTAssertEqual(harness.store?.liveFacts().keys.sorted(), harness.liveIDs)
    }

    // MARK: - navigator-accept

    private func draft(session: String = "s2", seq: ScriptValue = .int(1), author: String? = "navigator",
                       subject: ScriptValue? = nil, predicate: String = "hasType", value: ScriptValue = .string("int"),
                       cites: [String], rationale: String = "seen") -> [String: ScriptValue] {
        var fields: [String: ScriptValue] = [
            "session": .string(session), "seq": seq, "action": .string("setFact"),
            "subject": subject ?? subjectValue("0x2000"), "predicate": .string(predicate), "value": value,
            "cites": .array(cites.map(ScriptValue.string)), "rationale": .string(rationale),
        ]
        if let author { fields["author"] = .string(author) }
        return fields
    }

    func testAcceptTakesADraftAndReturnsPremiseAndRevertHandle() throws {
        let harness = try Harness()
        let result = try run(NavigatorMCPCommands.nameAccept, harness, [
            "annotation": .object(draft(cites: [harness.d1.id])),
        ])
        let expected = try NavigatorAnnotation.make(
            session: "s2", seq: 1, author: "navigator", action: "setFact", subject: Harness.function("0x2000"),
            predicate: "hasType", value: .string("int"), cites: [harness.d1.id], rationale: "seen")
        let accepted = try XCTUnwrap(result["accepted"])
        XCTAssertEqual(accepted["annotation"]?["id"], .string(expected.id))
        XCTAssertEqual(accepted["annotation"], NavigatorMCPCommands.script(expected.json))
        XCTAssertEqual(accepted["premise"], .string("ann:s2/1"))
        XCTAssertEqual(accepted["revert"], .string("revert:" + expected.id))
        XCTAssertEqual(harness.acceptCalls, [expected.id])
        XCTAssertNotNil(harness.store?.annotations()[expected.id])

        // Accepting the same draft twice is refused, and the bridge sees the second attempt only once.
        let duplicate = try run(NavigatorMCPCommands.nameAccept, harness, [
            "annotation": .object(draft(cites: [harness.d1.id])),
        ])
        XCTAssertEqual(refusalCode(duplicate), "preconditionFailed")

        // The accepted annotation is a premise: reverting it previews as an annotation effect.
        let preview = try run(NavigatorMCPCommands.namePreviewRevert, harness, ["id": .string(expected.id)])
        XCTAssertEqual(strings(preview["annotationsAffected"]), [expected.id])
    }

    func testAcceptTakesAFullRecordWithItsID() throws {
        let harness = try Harness()
        let record = try NavigatorAnnotation.make(
            session: "s3", seq: 4, author: "navigator", action: "setFact", subject: Harness.function("0x2000"),
            predicate: "hasType", value: .string("long"), cites: [harness.d1.id], rationale: "full record")
        let result = try run(NavigatorMCPCommands.nameAccept, harness, [
            "annotation": NavigatorMCPCommands.script(record.json),
        ])
        XCTAssertEqual(result["accepted"]?["annotation"], NavigatorMCPCommands.script(record.json))
        XCTAssertEqual(result["accepted"]?["premise"], .string("ann:s3/4"))

        // A tampered record fails the recomputed-id check.
        var tampered = try XCTUnwrap(NavigatorMCPCommands.script(record.json).objectFieldsForTest)
        tampered["rationale"] = .string("changed after the id was computed")
        tampered["seq"] = .int(5)
        let refused = try run(NavigatorMCPCommands.nameAccept, harness, ["annotation": .object(tampered)])
        XCTAssertEqual(refusalCode(refused), "malformedInput")
    }

    func testAcceptRefusalsAreTypedAndNothingIsAccepted() throws {
        let harness = try Harness()
        let before = harness.store?.annotations().keys.sorted()

        let analyst = try run(NavigatorMCPCommands.nameAccept, harness, [
            "annotation": .object(draft(author: "analyst", cites: [harness.d1.id])),
        ])
        XCTAssertEqual(refusalCode(analyst), "preconditionFailed")

        let missingAuthor = try run(NavigatorMCPCommands.nameAccept, harness, [
            "annotation": .object(draft(author: nil, cites: [harness.d1.id])),
        ])
        XCTAssertEqual(refusalCode(missingAuthor), "malformedInput")

        let noCites = try run(NavigatorMCPCommands.nameAccept, harness, ["annotation": .object(draft(cites: []))])
        XCTAssertEqual(refusalCode(noCites), "malformedInput")

        let noRationale = try run(NavigatorMCPCommands.nameAccept, harness, [
            "annotation": .object(draft(cites: [harness.d1.id], rationale: "")),
        ])
        XCTAssertEqual(refusalCode(noRationale), "malformedInput")

        let bogusPredicate = try run(NavigatorMCPCommands.nameAccept, harness, [
            "annotation": .object(draft(predicate: "noSuchPredicate", cites: [harness.d1.id])),
        ])
        XCTAssertEqual(refusalCode(bogusPredicate), "malformedInput")

        var withExtra = draft(cites: [harness.d1.id])
        withExtra["surprise"] = .bool(true)
        XCTAssertEqual(refusalCode(try run(NavigatorMCPCommands.nameAccept, harness, ["annotation": .object(withExtra)])),
                       "malformedInput")

        let fractionalSeq = try run(NavigatorMCPCommands.nameAccept, harness, [
            "annotation": .object(draft(seq: .double(1.5), cites: [harness.d1.id])),
        ])
        XCTAssertEqual(refusalCode(fractionalSeq), "malformedInput")

        let badSubject = try run(NavigatorMCPCommands.nameAccept, harness, [
            "annotation": .object(draft(subject: subjectValue("x", kind: "bogus"), cites: [harness.d1.id])),
        ])
        XCTAssertEqual(refusalCode(badSubject), "malformedInput")

        let deadCite = try run(NavigatorMCPCommands.nameAccept, harness, [
            "annotation": .object(draft(cites: [missingFactID])),
        ])
        XCTAssertEqual(refusalCode(deadCite), "unknownFact")

        let conflicting = try run(NavigatorMCPCommands.nameAccept, harness, [
            "annotation": .object(draft(
                subject: subjectValue("0x1000"), predicate: "hasName", value: .string("_other"), cites: [harness.a.id])),
        ])
        XCTAssertEqual(refusalCode(conflicting), "conflictsWithAuthority")

        XCTAssertEqual(harness.store?.annotations().keys.sorted(), before)
        // Only the attempts that reached the store were handed to the bridge: dead cite and conflict.
        XCTAssertEqual(harness.acceptCalls.count, 2)

        harness.store = nil
        let withoutState = try run(NavigatorMCPCommands.nameAccept, harness, [
            "annotation": .object(draft(cites: [harness.d1.id])),
        ])
        XCTAssertEqual(absence(withoutState), "noFacts")
    }

    // MARK: - navigator-toolchain / navigator-primitives

    private func fixtureInput() throws -> NavigatorImageInput {
        let bytes = MachOFixture.makeExecutableWithFunctionStarts().bytes
        let identity = try MachOSliceArtifactIdentity(
            uuid: nil, rawCPUType: MachOConstants.cpuTypeARM64, rawCPUSubtype: 0,
            selectedSliceSHA256: AnalysisFingerprintBuilder.sha256Hex(bytes), selectedSliceByteCount: UInt64(bytes.count))
        return NavigatorImageInput(slice: bytes, identity: identity)
    }

    func testToolchainReportsTheDetectedKeyAndTheStateToolchain() async throws {
        let harness = try Harness()
        harness.input = try fixtureInput()
        let inline = try run(NavigatorMCPCommands.nameToolchain, harness)
        let detached = try await runAsync(NavigatorMCPCommands.nameToolchain, harness)
        XCTAssertEqual(inline, detached, "the detached path answers exactly what the inline path does")

        let key = try XCTUnwrap(inline["toolchain"])
        XCTAssertEqual(key["arch"], .string("arm64"))
        XCTAssertFalse(try XCTUnwrap(key["canonical"]?.stringValue).isEmpty)
        let confidence = try XCTUnwrap(key["confidence"]?.stringValue)
        XCTAssertTrue(NavigatorToolchainKey.Confidence(rawValue: confidence) != nil, confidence)
        XCTAssertNotNil(key["platforms"]?.arrayValue)
        XCTAssertNotNil(key["tools"]?.arrayValue)
        XCTAssertNotNil(key["linkerFlavor"]?.stringValue)
        XCTAssertNotNil(key["derivedFrom"]?.stringValue)
        XCTAssertEqual(inline["stateToolchain"], .string(Harness.toolchain))

        harness.store = nil
        XCTAssertEqual(try run(NavigatorMCPCommands.nameToolchain, harness)["stateToolchain"], .null)
    }

    func testToolchainAndPrimitivesWithoutParsableBytesAreUnsupportedToolchain() async throws {
        let harness = try Harness()
        for input in [nil, NavigatorImageInput(slice: Data(count: 64), identity: nil)] as [NavigatorImageInput?] {
            harness.input = input
            for command in [NavigatorMCPCommands.nameToolchain, NavigatorMCPCommands.namePrimitives] {
                let inline = try run(command, harness)
                XCTAssertEqual(absence(inline), "unsupportedToolchain", command)
                XCTAssertEqual(inline["absent"]?["subject"]?[slotKey], .int(0), command)
                let asyncResult = try await runAsync(command, harness)
                XCTAssertEqual(asyncResult, inline, command)
            }
        }
        // Bytes that parse but carry no identity cannot be keyed either.
        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        harness.input = NavigatorImageInput(slice: fixture.bytes, identity: nil)
        XCTAssertEqual(absence(try run(NavigatorMCPCommands.nameToolchain, harness)), "unsupportedToolchain")
    }

    func testPrimitivesListTheRegistryEntriesThatApplyWithTheirContract() async throws {
        let harness = try Harness()
        harness.input = try fixtureInput()
        let inline = try run(NavigatorMCPCommands.namePrimitives, harness)
        let detached = try await runAsync(NavigatorMCPCommands.namePrimitives, harness)
        XCTAssertEqual(inline, detached)

        let rows = try XCTUnwrap(inline["primitives"]?.arrayValue)
        XCTAssertFalse(rows.isEmpty)
        let names = rows.compactMap { $0["id"]?.stringValue }
        // Unconstrained applicability (`.any`) admits every key.
        XCTAssertTrue(names.contains("macho.slice-identity"), names.joined(separator: ","))
        XCTAssertTrue(names.contains("macho.build-version"))
        XCTAssertTrue(names.contains("objc.class-parser"))
        // The structural proof is limited to macOS platforms; the fixture has no build version, so
        // its platform is undetermined and the primitive is not listed.
        XCTAssertFalse(names.contains("proof.function-start-structural"))
        let applicableIDs = NavigatorPrimitiveRegistry.standard.primitives.map(\.id)
        XCTAssertTrue(Set(names).isSubset(of: Set(applicableIDs)))
        for row in rows {
            let id = try XCTUnwrap(row["id"]?.stringValue)
            let descriptor = try XCTUnwrap(NavigatorPrimitiveRegistry.standard.lookup(id: id), id)
            XCTAssertEqual(row["producesStatus"], .string(descriptor.producesStatus), id)
            XCTAssertEqual(row["onOutOfRange"], .string(descriptor.onOutOfRange), id)
            XCTAssertEqual(row["costClass"], .string(descriptor.costClass), id)
            XCTAssertEqual(row["version"], .string(descriptor.version), id)
            XCTAssertEqual(row["isImplemented"], .bool(descriptor.isImplemented), id)
            XCTAssertEqual(row["disposition"], .string("proceed"), id)
            XCTAssertEqual(row["applicability"]?["archs"], .array(descriptor.applicability.archs.map(ScriptValue.string)), id)
            XCTAssertNotNil(row["applicability"]?["platforms"]?.arrayValue, id)
            XCTAssertNotNil(row["applicability"]?["linkerFlavors"]?.arrayValue, id)
        }
        XCTAssertEqual(inline["toolchain"]?["canonical"]?.stringValue,
                       try XCTUnwrap(run(NavigatorMCPCommands.nameToolchain, harness)["toolchain"]?["canonical"]?.stringValue))
    }

    // MARK: - navigator-resolve-provenance

    private func provenance(_ kind: String, _ ref: String, rule: String? = nil, ruleVersion: String? = nil) -> ScriptValue {
        var fields: [String: ScriptValue] = ["kind": .string(kind), "ref": .string(ref)]
        if let rule { fields["rule"] = .string(rule) }
        if let ruleVersion { fields["ruleVersion"] = .string(ruleVersion) }
        return .object(fields)
    }

    func testResolveProvenanceReturnsBoundedHexOfTheCitedBytes() async throws {
        let harness = try Harness()
        let input = try fixtureInput()
        harness.input = input
        let bytes = input.slice

        let loadCommand = try run(NavigatorMCPCommands.nameResolveProvenance, harness, [
            "provenance": provenance("loaderRecord", "lc[0]"),
        ])
        let resolved = try XCTUnwrap(loadCommand["resolved"])
        XCTAssertTrue(["bytes", "record"].contains(resolved["type"]?.stringValue ?? ""), "\(resolved)")
        XCTAssertEqual(resolved["range"]?["offset"], .int(32))
        XCTAssertEqual(resolved["range"]?["length"], .int(152))
        XCTAssertEqual(resolved["byteCount"], .int(152))
        XCTAssertEqual(resolved["sha256"], .string(sha256(bytes, 32 ..< 184)))
        XCTAssertEqual(resolved["hex"], .string(hex(bytes.subdata(in: 32 ..< 184))))
        XCTAssertEqual(resolved["truncated"], .bool(false))
        let detached = try await runAsync(NavigatorMCPCommands.nameResolveProvenance, harness, [
            "provenance": provenance("loaderRecord", "lc[0]"),
        ])
        XCTAssertEqual(detached, loadCommand)

        let section = try run(NavigatorMCPCommands.nameResolveProvenance, harness, [
            "provenance": provenance("loaderRecord", "section[__TEXT,__text]"),
        ])
        XCTAssertEqual(section["resolved"]?["range"]?["offset"], .int(104))
        XCTAssertEqual(section["resolved"]?["range"]?["length"], .int(80))
        XCTAssertEqual(section["resolved"]?["sha256"], .string(sha256(bytes, 104 ..< 184)))

        let fixture = MachOFixture.makeExecutableWithFunctionStarts()
        let entry = try run(NavigatorMCPCommands.nameResolveProvenance, harness, [
            "provenance": provenance("loaderRecord", "functionStarts[0]@" + NavigatorSubjectRef.address(fixture.baseAddress)),
        ])
        XCTAssertEqual(entry["resolved"]?["range"]?["offset"], .int(256))
        XCTAssertEqual(entry["resolved"]?["range"]?["length"], .int(2))
        XCTAssertEqual(entry["resolved"]?["hex"], .string(hex(bytes.subdata(in: 256 ..< 258))))
    }

    func testResolveProvenanceMissesAreTypedUnresolvableWithAReason() throws {
        let harness = try Harness()
        harness.input = try fixtureInput()
        func reason(_ value: ScriptValue) -> String? {
            value["resolved"]?["type"] == .string("unresolvable") ? value["resolved"]?["reason"]?.stringValue : nil
        }
        XCTAssertEqual(reason(try run(NavigatorMCPCommands.nameResolveProvenance, harness, [
            "provenance": provenance("loaderRecord", "lc[99]"),
        ])), "outOfBounds")
        XCTAssertEqual(reason(try run(NavigatorMCPCommands.nameResolveProvenance, harness, [
            "provenance": provenance("loaderRecord", "section[__DATA,__data]"),
        ])), "noSuchRecord")
        XCTAssertEqual(reason(try run(NavigatorMCPCommands.nameResolveProvenance, harness, [
            "provenance": provenance("proofCertificate", "sha256:" + String(repeating: "0", count: 64)),
        ])), "noSuchRecord")
        XCTAssertEqual(reason(try run(NavigatorMCPCommands.nameResolveProvenance, harness, [
            "provenance": provenance("rule", "macho.slice-identity@9", rule: "macho.slice-identity", ruleVersion: "9"),
        ])), "noSuchRecord")

        harness.input = nil
        XCTAssertEqual(reason(try run(NavigatorMCPCommands.nameResolveProvenance, harness, [
            "provenance": provenance("loaderRecord", "lc[0]"),
        ])), "noSuchRecord", "an image kind without image bytes cannot resolve")

        // A kind outside the vocabulary is a typed refusal, not a resolution result.
        let bogus = try run(NavigatorMCPCommands.nameResolveProvenance, harness, ["provenance": provenance("bogus", "x")])
        XCTAssertEqual(refusalCode(bogus), "malformedInput")
        let halfRule = try run(NavigatorMCPCommands.nameResolveProvenance, harness, [
            "provenance": provenance("rule", "macho.slice-identity@1", rule: "macho.slice-identity"),
        ])
        XCTAssertEqual(refusalCode(halfRule), "malformedInput")
    }

    func testResolveProvenanceNamesRulesAndAnnotationsWithoutImageBytes() throws {
        let harness = try Harness()
        harness.input = nil
        let rule = try run(NavigatorMCPCommands.nameResolveProvenance, harness, [
            "provenance": provenance("rule", "macho.slice-identity@1", rule: "macho.slice-identity", ruleVersion: "1"),
        ])
        XCTAssertEqual(rule["resolved"]?["type"], .string("rule"))
        XCTAssertEqual(rule["resolved"]?["rule"]?["id"], .string("macho.slice-identity"))
        XCTAssertEqual(rule["resolved"]?["rule"]?["version"], .string("1"))
        XCTAssertEqual(rule["resolved"]?["rule"]?["producesStatus"], .string("authoritative"))

        let annotation = try run(NavigatorMCPCommands.nameResolveProvenance, harness, [
            "provenance": provenance("analystAction", harness.note.premise),
        ])
        XCTAssertEqual(annotation["resolved"], .object(["type": .string("annotation"), "id": .string(harness.note.id)]))
        let unknownAnnotation = try run(NavigatorMCPCommands.nameResolveProvenance, harness, [
            "provenance": provenance("analystAction", "ann:s9/9"),
        ])
        XCTAssertEqual(unknownAnnotation["resolved"]?["reason"], .string("noSuchRecord"))
    }

    func testBoundedHexCutsAtFourKiBAndFlagsIt() {
        let big = Data((0 ..< 6_000).map { UInt8(truncatingIfNeeded: $0) })
        let cut = NavigatorMCPCommands.boundedHex(big, 0 ..< 5_000)
        XCTAssertEqual(cut?.hex.count, 8_192, "4,096 bytes are 8,192 hex digits")
        XCTAssertEqual(cut?.truncated, true)
        XCTAssertEqual(cut?.hex, hex(big.subdata(in: 0 ..< 4_096)))

        let exact = NavigatorMCPCommands.boundedHex(big, 0 ..< 4_096)
        XCTAssertEqual(exact?.hex.count, 8_192)
        XCTAssertEqual(exact?.truncated, false)

        let middle = NavigatorMCPCommands.boundedHex(big, 100 ..< 108)
        XCTAssertEqual(middle?.hex, hex(big.subdata(in: 100 ..< 108)))
        XCTAssertEqual(middle?.truncated, false)

        XCTAssertNil(NavigatorMCPCommands.boundedHex(big, 5_990 ..< 6_001))
        XCTAssertNil(NavigatorMCPCommands.boundedHex(big, -1 ..< 4))
        XCTAssertEqual(NavigatorMCPCommands.boundedHex(big, 6_000 ..< 6_000)?.hex, "")

        // A Data slice does not start at index 0.
        let tail = big[1_000...]
        XCTAssertNotEqual(tail.startIndex, 0)
        XCTAssertEqual(NavigatorMCPCommands.boundedHex(tail, 0 ..< 4)?.hex, hex(big.subdata(in: 1_000 ..< 1_004)))
    }

    func testResolvedValueBoundsTheHexOfAnOversizedRange() {
        let slice = Data(repeating: 0xab, count: 6_000)
        let value = NavigatorMCPCommands.resolvedValue(.bytes(range: 0 ..< 5_000, sha256: "digest"), slice: slice)
        XCTAssertEqual(value["type"], .string("bytes"))
        XCTAssertEqual(value["byteCount"], .int(5_000))
        XCTAssertEqual(value["range"]?["length"], .int(5_000))
        XCTAssertEqual(value["sha256"], .string("digest"))
        XCTAssertEqual(value["hex"]?.stringValue?.count, 8_192)
        XCTAssertEqual(value["truncated"], .bool(true))

        // Without the slice the digest and range are still reported, the hex is null.
        let bare = NavigatorMCPCommands.resolvedValue(.bytes(range: 4 ..< 8, sha256: "digest"), slice: nil)
        XCTAssertEqual(bare["hex"], .null)
        XCTAssertEqual(bare["truncated"], .bool(false))
        XCTAssertEqual(bare["range"]?["offset"], .int(4))

        let record = NavigatorMCPCommands.resolvedValue(
            .record(description: "LC_SEGMENT_64", range: 0 ..< 4, sha256: "d"), slice: slice)
        XCTAssertEqual(record["type"], .string("record"))
        XCTAssertEqual(record["description"], .string("LC_SEGMENT_64"))
        XCTAssertEqual(record["hex"], .string("abababab"))
        let external = NavigatorMCPCommands.resolvedValue(.record(description: "corpus", range: nil, sha256: "d"), slice: slice)
        XCTAssertNil(external["range"])
        XCTAssertEqual(external["sha256"], .string("d"))
        XCTAssertEqual(NavigatorMCPCommands.resolvedValue(.annotation(id: "a-1"), slice: nil),
                       .object(["type": .string("annotation"), "id": .string("a-1")]))
        XCTAssertEqual(NavigatorMCPCommands.resolvedValue(.unresolvable(.hashMismatch), slice: nil),
                       .object(["type": .string("unresolvable"), "reason": .string("hashMismatch")]))
    }

    // MARK: - The acceptance sweep: no command answers a miss with an empty array

    private func nonsenseArguments(_ command: String, slot: ScriptValue) -> [String: ScriptValue] {
        var fields: [String: ScriptValue] = [slotKey: slot]
        switch command {
        case NavigatorMCPCommands.nameFacts:
            fields["subject"] = subjectValue("nonsense")
        case NavigatorMCPCommands.nameFrontier:
            fields["kind"] = .string("unresolvedProtocol")
        case NavigatorMCPCommands.nameDependents, NavigatorMCPCommands.namePreviewRevert:
            fields["id"] = .string(missingFactID)
        case NavigatorMCPCommands.nameRevert:
            fields["id"] = .string(missingFactID)
            fields["session"] = .string("nonsense-session")
        case NavigatorMCPCommands.nameAccept:
            fields["annotation"] = .object(draft(
                subject: subjectValue("nonsense"), cites: [missingFactID]))
        case NavigatorMCPCommands.nameResolveProvenance:
            fields["provenance"] = provenance("loaderRecord", "lc[999]")
        default:
            break
        }
        return fields
    }

    /// A result is typed when it is an object with a reasoned absence, a typed error or refusal, or
    /// a non-empty result body. It is never an array and never an empty object, and no list field
    /// is an empty array.
    private func assertTyped(_ value: ScriptValue, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .object(let fields) = value, !fields.isEmpty else {
            return XCTFail("\(label): an object with content is required, got \(value)", file: file, line: line)
        }
        if let absent = fields["absent"] {
            let reason = absent["reason"]?.stringValue
            XCTAssertTrue(NavigatorMCPCommands.absenceReasons.contains(reason ?? ""), "\(label): reason \(String(describing: reason))", file: file, line: line)
            XCTAssertNotNil(absent["subject"], "\(label): absence names its subject", file: file, line: line)
            XCTAssertEqual(fields.count, 1, label, file: file, line: line)
            return
        }
        if let error = fields["error"] {
            XCTAssertFalse((error.stringValue ?? "").isEmpty, label, file: file, line: line)
            return
        }
        let typedKeys = ["resolved", "toolchain", "primitives", "facts", "items", "dependents", "accepted", "reverted", "factsLost"]
        XCTAssertTrue(typedKeys.contains { fields[$0] != nil }, "\(label): \(fields.keys.sorted())", file: file, line: line)
        for key in ["primitives", "facts", "items", "dependents"] {
            if let rows = fields[key]?.arrayValue {
                XCTAssertFalse(rows.isEmpty, "\(label): \(key) is an empty array without a reason", file: file, line: line)
            }
        }
        if let resolved = fields["resolved"], resolved["type"] == .string("unresolvable") {
            XCTAssertNotNil(resolved["reason"]?.stringValue, label, file: file, line: line)
        }
    }

    func testEveryCommandAnswersANonsenseSubjectWithATypedResultOnTheSeededSurface() async throws {
        let harness = try Harness()
        for input in [Optional(try fixtureInput()), NavigatorImageInput(slice: Data(count: 64), identity: nil), nil] {
            harness.input = input
            for command in NavigatorMCPCommands.names {
                let arguments = ScriptValue.object(nonsenseArguments(command, slot: .int(0)))
                let inline = try NavigatorMCPCommands.execute(command: command, arguments: arguments, surface: harness.surface())
                assertTyped(inline, command)
                let detached = try await NavigatorMCPCommands.executeAsync(
                    command: command, arguments: arguments, surface: harness.surface())
                XCTAssertEqual(detached, inline, command)
            }
        }
        XCTAssertTrue(harness.revertCalls.isEmpty, "a nonsense revert changes nothing")
        XCTAssertEqual(harness.store?.liveFacts().keys.sorted(), harness.liveIDs)
        // With no navigator state at all every state-backed command still says why.
        harness.store = nil
        for command in NavigatorMCPCommands.names {
            let result = try run(command, harness, nonsenseArguments(command, slot: .int(0)))
            assertTyped(result, command + " (no state)")
        }
    }

    // MARK: - Through the closed authority and the MCP transport (live surface, hermetic store)

    private func makeSingleImageStore() -> WorkspaceStore {
        let image = BinaryImage(
            id: UUID(), name: "image0", path: "/tmp/p4-navigator-image0", kind: "Mach-O executable",
            architecture: "arm64", slot: .primary)
        let snapshot = WorkspaceSnapshot(binaries: [image], analysisBySlot: [.primary: ImageAnalysis()])
        return WorkspaceStore(workspaceName: "navigator surface", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    private func requestValue(_ name: String, _ arguments: ScriptValue) -> ScriptValue {
        .object([
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("tools/call"),
            "params": .object(["name": .string(name), "arguments": arguments]),
        ])
    }

    private func toolOutput(envelope: ScriptValue?, file: StaticString = #filePath, line: UInt = #line) throws -> ScriptValue {
        let envelope = try XCTUnwrap(envelope, file: file, line: line)
        XCTAssertNil(envelope["error"], "\(envelope)", file: file, line: line)
        XCTAssertEqual(envelope["result"]?["isError"], .bool(false), file: file, line: line)
        let text = try XCTUnwrap(
            envelope["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, file: file, line: line)
        return try ScriptValue.decode(Data(text.utf8))
    }

    func testEveryCommandAnswersANonsenseSubjectThroughTheAuthorityOnAWorkspaceWithoutNavigatorState() async throws {
        let api = WorkspaceScriptingAPI(store: makeSingleImageStore())
        for command in NavigatorMCPCommands.names {
            let arguments = ScriptValue.object(nonsenseArguments(command, slot: .int(0)))
            XCTAssertNoThrow(try HeadlessAutomationAuthority.validate(command: command, arguments: arguments), command)
            let inline = try HeadlessAutomationAuthority.execute(command: command, arguments: arguments, api: api)
            // For an image whose navigator state is not yet built the bridge's `navigatorState(for:)`
            // returns nil (no producer has landed), so every command answers with a typed absence;
            // that typedness is what is asserted here, not the reason string.
            assertTyped(inline, command)
            let detached = try await HeadlessAutomationAuthority.executeAsync(command: command, arguments: arguments, api: api)
            assertTyped(detached, command + " (async)")
            XCTAssertEqual(detached, inline, command)
        }
    }

    func testUnknownImageThroughTheAuthorityAndBothServerPathsIsNoSuchImage() async throws {
        let api = WorkspaceScriptingAPI(store: makeSingleImageStore())
        let server = MCPServer(api: api)
        for command in NavigatorMCPCommands.names {
            let arguments = ScriptValue.object(nonsenseArguments(command, slot: .int(4242)))
            let expected = ScriptValue.object(["absent": .object([
                "subject": .object([slotKey: .int(4242)]), "reason": .string("noSuchImage"),
            ])])
            XCTAssertEqual(try HeadlessAutomationAuthority.execute(command: command, arguments: arguments, api: api),
                           expected, command)
            let asyncOutput = try await HeadlessAutomationAuthority.executeAsync(command: command, arguments: arguments, api: api)
            XCTAssertEqual(asyncOutput, expected, command)
            XCTAssertEqual(try toolOutput(envelope: server.handle(requestValue(command, arguments))), expected, command)
            let data = try requestValue(command, arguments).jsonData()
            let maybeResponse = await server.handleMessageAsync(data)
            let response = try XCTUnwrap(maybeResponse)
            XCTAssertEqual(try toolOutput(envelope: try ScriptValue.decode(response)), expected, command)
        }
    }

    func testTransportRefusesShapeErrorsAsInvalidParamsAndNamesNoUnknownArguments() throws {
        let server = MCPServer(api: WorkspaceScriptingAPI(store: makeSingleImageStore()))
        func code(_ command: String, _ arguments: ScriptValue) throws -> ScriptValue? {
            try XCTUnwrap(server.handle(requestValue(command, arguments)))["error"]?["code"]
        }
        XCTAssertEqual(try code(NavigatorMCPCommands.nameFacts, .object([:])), .int(-32602), "imageSlot is required")
        XCTAssertEqual(try code(NavigatorMCPCommands.nameFacts, .object([slotKey: .int(0), "limit": .int(257)])), .int(-32602))
        XCTAssertEqual(try code(NavigatorMCPCommands.nameFacts, .object([slotKey: .int(0), "bogus": .int(1)])), .int(-32602))
        XCTAssertEqual(try code(NavigatorMCPCommands.nameDependents, .object([slotKey: .int(0)])), .int(-32602))
        XCTAssertEqual(try code(NavigatorMCPCommands.nameRevert, .object([slotKey: .int(0), "id": .string(missingFactID)])), .int(-32602))
        XCTAssertEqual(try code(NavigatorMCPCommands.nameAccept, .object([slotKey: .int(0), "annotation": .string("x")])), .int(-32602))
        XCTAssertEqual(try code(NavigatorMCPCommands.nameFacts, .object([slotKey: .object([:])])), .int(-32602))
    }

    // MARK: - Attached transport

    func testAttachedExecutorServesNavigatorReadsAndAcceptButNotRevert() async throws {
        let store = makeSingleImageStore()
        defer { withExtendedLifetime(store) {} }
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        executor.setConsent(.allowed)
        let noSuchImage = ScriptValue.object(["absent": .object([
            "subject": .object([slotKey: .int(4242)]), "reason": .string("noSuchImage"),
        ])])
        for command in NavigatorMCPCommands.attachable.sorted() {
            let arguments = ScriptValue.object(nonsenseArguments(command, slot: .int(4242)))
            let result = try await executor.execute(command, arguments)
            XCTAssertEqual(result, noSuchImage, command)
        }
        // A read on the primary image is typed too (the exact reason is the bridge's).
        let facts = try await executor.execute(NavigatorMCPCommands.nameFacts, .object([slotKey: .int(0)]))
        assertTyped(facts, "attached navigator-facts")

        do {
            _ = try await executor.execute(
                NavigatorMCPCommands.nameRevert,
                .object([slotKey: .int(0), "id": .string(missingFactID), "session": .string("s")]))
            XCTFail("navigator-revert is not available while attached")
        } catch let failure as MCPAttachExecutor.Failure {
            XCTAssertEqual(failure, .unavailableWhenAttached)
        }
    }

    func testAttachedCatalogListsTheEightNavigatorCommandsOnly() async throws {
        let store = makeSingleImageStore()
        defer { withExtendedLifetime(store) {} }
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        executor.setConsent(.allowed)
        let output = try await executor.execute("commands", .object([:]))
        let names = Set((output.arrayValue ?? []).compactMap { $0["name"]?.stringValue })
        XCTAssertTrue(NavigatorMCPCommands.attachable.isSubset(of: names), "\(names.sorted())")
        XCTAssertFalse(names.contains(NavigatorMCPCommands.nameRevert))
    }

    // MARK: - list-image-types Swift fields

    func testTypeAtlasRowsCarryImageSlotAndTheSwiftFields() {
        let slot = ImageSlot(rawValue: 1)
        let swiftClass = TypeAtlasEntry(
            id: TypeAtlasEntryID(slot: slot, kind: .swiftClass, key: .name("App.Model")), kind: .swiftClass,
            name: "Model", superclass: nil, members: [], conformances: [], methods: [], users: [],
            evidence: .descriptor, qualifiedName: "App.Model", swiftSuperclass: "$s3App4BaseCD",
            isGeneric: false, isPrivateOrLocal: nil, isImportedCType: false)
        let row = WorkspaceScriptingAPI.typeAtlasEntryValue(swiftClass)
        XCTAssertEqual(row["imageSlot"], .int(1))
        XCTAssertEqual(row["id"]?["slot"], .int(1))
        XCTAssertEqual(row["kind"], .string("swiftClass"))
        XCTAssertEqual(row["qualifiedName"], .string("App.Model"))
        XCTAssertEqual(row["isGeneric"], .bool(false))
        XCTAssertEqual(row["isPrivateOrLocal"], .null, "not recorded is null, never a guess")
        XCTAssertEqual(row["isImportedCType"], .bool(false))
        XCTAssertEqual(row["superclass"], .null, "superclass stays the catalogue link")
        XCTAssertEqual(row["swiftSuperclass"], .string("$s3App4BaseCD"))

        let both = TypeAtlasEntry(
            id: TypeAtlasEntryID(slot: slot, kind: .swiftClass, key: .name("App.Derived")), kind: .swiftClass,
            name: "Derived", superclass: "Base", members: [], conformances: [], methods: [], users: [],
            evidence: .descriptor, swiftSuperclass: "$s3App4BaseCD")
        let bothRow = WorkspaceScriptingAPI.typeAtlasEntryValue(both)
        XCTAssertEqual(bothRow["superclass"], .string("Base"), "the catalogue link keeps its meaning")
        XCTAssertEqual(bothRow["swiftSuperclass"], .string("$s3App4BaseCD"))
        XCTAssertEqual(bothRow["qualifiedName"], .null)
        XCTAssertEqual(bothRow["isGeneric"], .null)

        let objc = TypeAtlasEntry(
            id: TypeAtlasEntryID(slot: .primary, kind: .objcClass, key: .address(0x1000)), kind: .objcClass,
            name: "Thing", superclass: "NSObject", members: [], conformances: [], methods: [], users: [],
            evidence: .descriptor)
        let objcRow = WorkspaceScriptingAPI.typeAtlasEntryValue(objc)
        XCTAssertEqual(objcRow["imageSlot"], .int(0))
        XCTAssertEqual(objcRow["superclass"], .string("NSObject"))
        XCTAssertNil(objcRow["swiftSuperclass"])
        for key in ["qualifiedName", "isGeneric", "isPrivateOrLocal", "isImportedCType"] {
            XCTAssertNil(objcRow[key], "\(key) is a Swift-row field")
        }
    }
}

private extension ScriptValue {
    /// The keys of an object value, empty for anything else.
    var objectKeys: [String] {
        if case .object(let fields) = self { return Array(fields.keys) }
        return []
    }

    /// The fields of an object value, nil for anything else.
    var objectFieldsForTest: [String: ScriptValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}
