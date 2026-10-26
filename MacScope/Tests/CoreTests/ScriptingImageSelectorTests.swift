import XCTest
@testable import MacScope

/// Fixed-outcome native seam for the MS-19 selector tests; records each request's image binding.
private final class ImageSelectorNativeStub: ScriptingNativeDecompiling, @unchecked Sendable {
    private let outcome: ScriptingNativeDecompileOutcome
    private let lock = NSLock()
    private var recorded: [ScriptingNativeDecompileRequest] = []

    init(_ outcome: ScriptingNativeDecompileOutcome) { self.outcome = outcome }

    var requests: [ScriptingNativeDecompileRequest] { lock.withLock { recorded } }

    func decompile(_ request: ScriptingNativeDecompileRequest) async -> ScriptingNativeDecompileOutcome {
        lock.withLock { recorded.append(request) }
        return outcome
    }
}

/// MS-19: `decompile` and `read-bytes` keep the primary image as their default and accept an
/// explicit `image` (slot index or image-owner ID); every result names the image that answered.
@MainActor
final class ScriptingImageSelectorTests: XCTestCase {
    private let sibling = ImageSlot(rawValue: 1)
    private let primaryOwner = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let siblingOwner = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let primaryFunctionID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1")!
    private let siblingFunctionID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1")!
    /// Both images map a function and a data section at the same addresses.
    private let functionAddress: UInt64 = 0x1_0000_1000
    private let dataAddress: UInt64 = 0x1_0000_4000

    /// Two arm64 images whose function and section addresses collide, with distinct names,
    /// instruction sentinels and bytes. `focus` picks the UI-focused image.
    private func makeStore(focus: ImageSlot = .primary) -> WorkspaceStore {
        func image(_ slot: ImageSlot, owner: UUID) -> BinaryImage {
            BinaryImage(
                id: owner, name: "image\(slot.rawValue)", path: "/tmp/ms19-image\(slot.rawValue)",
                kind: "Mach-O executable", architecture: "arm64", slot: slot
            )
        }
        func analysis(functionID: UUID, name: String, sentinel: String, bytes: [UInt8]) -> ImageAnalysis {
            var result = ImageAnalysis()
            result.functions = [FunctionSummary(
                id: functionID, name: name, startAddress: functionAddress,
                endAddress: functionAddress + 4, confidence: 1
            )]
            result.instructions = [InstructionRow(
                address: functionAddress, bytes: "00 00 00 00", mnemonic: "udf", operands: "#1",
                hasBreakpoint: false, comment: sentinel
            )]
            result.sections = [SectionSummary(
                id: UUID(), name: "__DATA,__const", address: dataAddress, size: UInt64(bytes.count),
                fileOffset: 0, isExecutable: false
            )]
            result.imageBytes = Data(bytes)
            return result
        }
        let snapshot = WorkspaceSnapshot(
            binaries: [image(.primary, owner: primaryOwner), image(sibling, owner: siblingOwner)],
            analysisBySlot: [
                .primary: analysis(
                    functionID: primaryFunctionID, name: "primary_fn", sentinel: "A_SENTINEL",
                    bytes: [0xAA, 0xAA, 0xAA, 0xAA]
                ),
                sibling: analysis(
                    functionID: siblingFunctionID, name: "sibling_fn", sentinel: "B_SENTINEL",
                    bytes: [0xBB, 0xBB, 0xBB, 0xBB]
                ),
            ],
            addressOverrides: [
                ImageAddress(slot: .primary, address: functionAddress): AddressOverride(customName: "AProcedure"),
                ImageAddress(slot: sibling, address: functionAddress): AddressOverride(customName: "BProcedure"),
            ]
        )
        let store = WorkspaceStore(
            workspaceName: "MS-19", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil
        )
        store.focusImage(focus)
        return store
    }

    private func assertSecondaryPseudocode(
        _ output: ScriptValue, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let text = try XCTUnwrap(output["pseudocode"]?.stringValue, file: file, line: line)
        XCTAssertEqual(output["function"]?.stringValue, "sibling_fn", file: file, line: line)
        XCTAssertEqual(output["address"]?.stringValue, "0x100001000", file: file, line: line)
        XCTAssertTrue(text.contains("BProcedure"), text, file: file, line: line)
        XCTAssertTrue(text.contains("B_SENTINEL"), text, file: file, line: line)
        XCTAssertFalse(text.contains("AProcedure"), text, file: file, line: line)
        XCTAssertFalse(text.contains("A_SENTINEL"), text, file: file, line: line)
        XCTAssertEqual(output["imageSlot"], .int(1), file: file, line: line)
        XCTAssertEqual(output["imageOwner"]?.stringValue, siblingOwner.uuidString, file: file, line: line)
    }

    // MARK: - decompile

    func testDefaultDecompileStaysPrimaryAndIsLabelled() throws {
        // The sibling is focused; with no `image` the MS-06 primary default still holds.
        let api = WorkspaceScriptingAPI(store: makeStore(focus: sibling))
        let selector = ScriptValue.object(["address": .hex(functionAddress)])
        let output = try api.execute("decompile", arguments: selector)
        let text = try XCTUnwrap(output["pseudocode"]?.stringValue)
        XCTAssertEqual(output["function"]?.stringValue, "primary_fn")
        XCTAssertTrue(text.contains("AProcedure"), text)
        XCTAssertFalse(text.contains("B_SENTINEL"), text)
        XCTAssertEqual(output["imageSlot"], .int(0))
        XCTAssertEqual(output["imageOwner"]?.stringValue, primaryOwner.uuidString)
        XCTAssertEqual(output["backend"]?.stringValue, "macir")
        XCTAssertEqual(output["fallbackReason"]?.stringValue, "native-unavailable")

        // Naming the primary explicitly (slot or owner) is the default, byte for byte.
        XCTAssertEqual(
            try api.execute("decompile", arguments: .object([
                "address": .hex(functionAddress), "image": .int(0),
            ])),
            output
        )
        XCTAssertEqual(
            try api.execute("decompile", arguments: .object([
                "address": .hex(functionAddress), "image": .string(primaryOwner.uuidString),
            ])),
            output
        )
    }

    func testExplicitSecondaryImageWithOverlappingAddressDecompilesTheSecondary() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())
        for image: ScriptValue in [
            .int(1), .string("1"), .string(siblingOwner.uuidString),
            .string(siblingOwner.uuidString.lowercased()),
        ] {
            try assertSecondaryPseudocode(api.execute("decompile", arguments: .object([
                "address": .hex(functionAddress), "image": image,
            ])))
        }

        // Name selectors resolve in the selected image only.
        try assertSecondaryPseudocode(api.execute("decompile", arguments: .object([
            "function": .string("BProcedure"), "image": .int(1),
        ])))
        try assertSecondaryPseudocode(api.execute("decompile", arguments: .object([
            "function": .string("sibling_fn"), "image": .int(1),
        ])))
        XCTAssertThrowsError(try api.execute("decompile", arguments: .object([
            "function": .string("primary_fn"), "image": .int(1),
        ]))) { error in
            XCTAssertEqual(error as? ScriptingError, .invalidArgument("no function named 'primary_fn'"))
        }
    }

    func testAsyncNativeFirstDecompileBindsTheSelectedImage() async throws {
        let text = "void BProcedure(void)\n{\n}"
        let stub = ImageSelectorNativeStub(.completed(NativeDecompilerWirePseudocodeDocument(
            text: text, language: "c", isComplete: true, isTruncated: false
        )))
        let api = WorkspaceScriptingAPI(store: makeStore(), nativeDecompiler: stub)
        let output = try await api.executeAsync("decompile", arguments: .object([
            "address": .hex(functionAddress), "image": .string(siblingOwner.uuidString),
        ]))
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(request.imageSlot, sibling)
        XCTAssertEqual(request.functionID, siblingFunctionID)
        XCTAssertEqual(request.startAddress, functionAddress)
        XCTAssertEqual(output["backend"]?.stringValue, "native")
        XCTAssertNil(output["fallbackReason"])
        XCTAssertEqual(output["pseudocode"]?.stringValue, text)
        XCTAssertEqual(output["function"]?.stringValue, "sibling_fn")
        XCTAssertEqual(output["imageSlot"], .int(1))
        XCTAssertEqual(output["imageOwner"]?.stringValue, siblingOwner.uuidString)

        // Default async binding: the primary image, labelled.
        let primary = try await api.executeAsync("decompile", arguments: .object([
            "address": .hex(functionAddress),
        ]))
        XCTAssertEqual(stub.requests.last?.imageSlot, .primary)
        XCTAssertEqual(stub.requests.last?.functionID, primaryFunctionID)
        XCTAssertEqual(primary["imageSlot"], .int(0))
        XCTAssertEqual(primary["imageOwner"]?.stringValue, primaryOwner.uuidString)
    }

    func testAsyncFallbackForTheSelectedImageIsLabelledWithBackendAndReason() async throws {
        let stub = ImageSelectorNativeStub(.failed(code: "timed-out"))
        let api = WorkspaceScriptingAPI(store: makeStore(), nativeDecompiler: stub)
        let arguments = ScriptValue.object(["address": .hex(functionAddress), "image": .int(1)])
        let output = try await api.executeAsync("decompile", arguments: arguments)
        XCTAssertEqual(stub.requests.first?.imageSlot, sibling)
        XCTAssertEqual(output["backend"]?.stringValue, "macir")
        XCTAssertEqual(output["fallbackReason"]?.stringValue, "native-failed: timed-out")
        try assertSecondaryPseudocode(output)
        // The fallback body is the synchronous binding's MacIR document for the same image.
        let legacy = try api.execute("decompile", arguments: arguments)
        XCTAssertEqual(output["pseudocode"], legacy["pseudocode"])
        XCTAssertEqual(legacy["imageSlot"], .int(1))
    }

    // MARK: - read-bytes

    func testReadBytesDefaultsToPrimaryAndReadsTheSelectedImageAtOverlappingAddresses() throws {
        let api = WorkspaceScriptingAPI(store: makeStore(focus: sibling))
        let primary = try api.execute("read-bytes", arguments: .object([
            "address": .hex(dataAddress), "count": .int(4),
        ]))
        XCTAssertEqual(primary["hex"]?.stringValue, "aaaaaaaa")
        XCTAssertEqual(primary["length"]?.intValue, 4)
        XCTAssertEqual(primary["imageSlot"], .int(0))
        XCTAssertEqual(primary["imageOwner"]?.stringValue, primaryOwner.uuidString)

        for image: ScriptValue in [.int(1), .string(siblingOwner.uuidString)] {
            let secondary = try api.execute("read-bytes", arguments: .object([
                "address": .hex(dataAddress), "count": .int(4), "image": image,
            ]))
            XCTAssertEqual(secondary["hex"]?.stringValue, "bbbbbbbb")
            XCTAssertEqual(secondary["address"]?.stringValue, "0x100004000")
            XCTAssertEqual(secondary["imageSlot"], .int(1))
            XCTAssertEqual(secondary["imageOwner"]?.stringValue, siblingOwner.uuidString)
        }
    }

    // MARK: - Invalid selectors

    func testInvalidImageSelectorThrowsTypedErrorNamingValidSlots() throws {
        let api = WorkspaceScriptingAPI(store: makeStore())
        let cases: [(ScriptValue, String)] = [
            (.int(7), "7"),
            (.int(-1), "-1"),
            (.string("nope"), "nope"),
            (.string("2"), "2"),
            (.string("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"), "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"),
            (.bool(true), "true"),
        ]
        for (image, described) in cases {
            for (command, arguments) in [
                ("decompile", ["address": ScriptValue.hex(functionAddress), "image": image]),
                ("read-bytes", ["address": ScriptValue.hex(dataAddress), "image": image]),
            ] {
                XCTAssertThrowsError(try api.execute(command, arguments: .object(arguments))) { error in
                    XCTAssertEqual(
                        error as? ScriptingError,
                        .unknownImage(selector: described, validSlots: [0, 1]),
                        "\(command) \(described)"
                    )
                    XCTAssertTrue(
                        error.localizedDescription.contains("valid image slots are 0, 1"),
                        error.localizedDescription
                    )
                }
            }
        }
    }

    // MARK: - Help text and the focused-image exception

    func testHelpTextSaysPrimaryByDefaultAndSetSignatureStaysFocused() throws {
        let commands = WorkspaceScriptingAPI.availableCommands
        let decompile = try XCTUnwrap(commands.first { $0.name == "decompile" })
        XCTAssertTrue(decompile.summary.contains("primary image by default"), decompile.summary)
        XCTAssertTrue(decompile.summary.contains("`imageSlot`"), decompile.summary)
        XCTAssertTrue(decompile.summary.contains("`imageOwner`"), decompile.summary)
        XCTAssertEqual(decompile.arguments, ["function", "address", "image"])
        let readBytes = try XCTUnwrap(commands.first { $0.name == "read-bytes" })
        XCTAssertTrue(readBytes.summary.contains("primary image by default"), readBytes.summary)
        XCTAssertEqual(readBytes.arguments, ["address", "count", "image"])

        // MS-06-scope2: set-signature stays bound to the focused image and takes no selector.
        let signature = try XCTUnwrap(commands.first { $0.name == "set-signature" })
        XCTAssertFalse(signature.arguments.contains("image"))
        XCTAssertTrue(signature.summary.contains("focused image"), signature.summary)
    }

    // MARK: - MCP

    private func mcpRequest(_ method: String, params: ScriptValue? = nil) -> ScriptValue {
        var object: [String: ScriptValue] = [
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string(method),
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    func testMCPSchemasExposeOptionalImageAndKeepDefaults() throws {
        let server = MCPServer(api: WorkspaceScriptingAPI(store: makeStore()))
        let tools = server.handle(mcpRequest("tools/list"))?["result"]?["tools"]?.arrayValue ?? []
        func schema(_ name: String) throws -> ScriptValue {
            try XCTUnwrap(tools.first { $0["name"]?.stringValue == name }?["inputSchema"])
        }
        for name in ["decompile", "read-bytes"] {
            let image = try XCTUnwrap(try schema(name)["properties"]?["image"], name)
            XCTAssertNotNil(image["anyOf"], name)
            XCTAssertTrue(image["description"]?.stringValue?.contains("primary image") ?? false, name)
        }
        // Defaults unchanged: image is never required, selectors keep their shape.
        XCTAssertEqual(try schema("decompile")["anyOf"], .array([
            .object(["required": .array([.string("function")])]),
            .object(["required": .array([.string("address")])]),
        ]))
        XCTAssertNil(try schema("decompile")["required"])
        XCTAssertEqual(try schema("read-bytes")["required"], .array([.string("address")]))
        XCTAssertNil(try schema("set-signature")["properties"]?["image"])
    }

    func testMCPCallSelectsTheSecondaryImageAndRejectsBadSelectors() throws {
        let server = MCPServer(api: WorkspaceScriptingAPI(store: makeStore()))
        func call(_ name: String, _ arguments: [String: ScriptValue]) -> ScriptValue? {
            server.handle(mcpRequest("tools/call", params: .object([
                "name": .string(name), "arguments": .object(arguments),
            ])))
        }
        let response = call("read-bytes", [
            "address": .string("0x100004000"), "count": .int(4), "image": .int(1),
        ])
        XCTAssertEqual(response?["result"]?["isError"], .bool(false))
        let payload = try ScriptValue.decode(Data(try XCTUnwrap(
            response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        ).utf8))
        XCTAssertEqual(payload["hex"]?.stringValue, "bbbbbbbb")
        XCTAssertEqual(payload["imageSlot"], .int(1))
        XCTAssertEqual(payload["imageOwner"]?.stringValue, siblingOwner.uuidString)

        // Wrong shape: rejected at the schema boundary.
        XCTAssertEqual(
            call("read-bytes", ["address": .string("0x100004000"), "image": .bool(true)])?["error"]?["code"],
            .int(-32602)
        )
        // Well-formed but absent from the workspace: the typed error names the valid slots.
        let unknown = call("read-bytes", ["address": .string("0x100004000"), "image": .int(9)])
        XCTAssertEqual(unknown?["result"]?["isError"], .bool(true))
        let message = unknown?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(message.contains("valid image slots are 0, 1"), message)
    }
}
