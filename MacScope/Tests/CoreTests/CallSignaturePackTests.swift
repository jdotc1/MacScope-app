import XCTest
@testable import MacScope

/// HOP-5 step 1: the generated-pack format loads strictly and joins the catalog at the lowest
/// precedence (adds signatures, never shadows a hand-verified one).
final class CallSignaturePackTests: XCTestCase {
    private func pack(_ entries: String, version: Int = 1) -> Data {
        Data("""
        {"format":"macscope.call-signature-pack","formatVersion":\(version),
         "generator":{"tool":"sdk-signature-extractor","sdk":"MacOSX27.2.sdk"},
         "entries":[\(entries)]}
        """.utf8)
    }

    func testPackLoadsStrictlyAndAddsWithoutShadowing() throws {
        let loaded = try CallSignaturePack.load(pack("""
            {"name":"macscope_pack_probe","returns":"int","params":[{"type":"int","name":"fd"},
              {"type":"double","name":"scale"}],"variadic":false,"noReturn":false},
            {"name":"malloc","returns":"int","params":[],"variadic":false,"noReturn":false},
            {"name":"_exit","returns":"void","params":[{"type":"int","name":"status"}],"variadic":false,"noReturn":true}
            """))
        XCTAssertEqual(loaded.generator.sdk, "MacOSX27.2.sdk")
        XCTAssertEqual(loaded.noReturnNames, ["_exit"])

        let catalog = CallSignatureCatalog.standard(adding: loaded)
        let probe = try XCTUnwrap(catalog.signature(for: "_macscope_pack_probe"))
        XCTAssertEqual(probe.returnType, "int")
        XCTAssertEqual(probe.parameters.map(\.register), ["w0", "d0"])
        // The hand-verified seed wins over the pack's conflicting `malloc`.
        XCTAssertEqual(catalog.signature(for: "_malloc")?.returnType,
                       CallSignatureCatalog.standard.signature(for: "_malloc")?.returnType)
        XCTAssertNil(CallSignatureCatalog.standard.signature(for: "_macscope_pack_probe"))

        let entry = #"{"name":"dup","returns":"void","params":[],"variadic":false,"noReturn":false}"#
        XCTAssertThrowsError(try CallSignaturePack.load(pack(entry + "," + entry))) {
            XCTAssertEqual($0 as? CallSignaturePack.LoadError, .duplicateEntry("dup"))
        }
        XCTAssertThrowsError(try CallSignaturePack.load(pack(entry, version: 2))) {
            XCTAssertEqual($0 as? CallSignaturePack.LoadError,
                           .unsupportedFormat("macscope.call-signature-pack", version: 2))
        }
        XCTAssertThrowsError(try CallSignaturePack.load(pack(
            #"{"name":"bad name","returns":"void","params":[],"variadic":false,"noReturn":false}"#))) {
            XCTAssertEqual($0 as? CallSignaturePack.LoadError, .invalidEntry(index: 0))
        }
        XCTAssertThrowsError(try CallSignaturePack.load(Data("{}".utf8))) {
            XCTAssertEqual($0 as? CallSignaturePack.LoadError, .malformed)
        }
    }

    // HOP-5 step 2: the shipped, offline-generated SDK pack.
    func testBundledSDKPackLoadsWithHeaderAndKnownEntries() throws {
        let pack = try XCTUnwrap(CallSignaturePack.bundled, "SDKCallSignaturePack.json must ship and load")
        XCTAssertEqual(pack.generator.tool, "Scripts/signatures/generate_sdk_signature_pack.py")
        XCTAssertTrue(pack.generator.sdk.hasPrefix("MacOSX"), pack.generator.sdk)
        XCTAssertNotNil(pack.generator.sdkVersion)
        XCTAssertGreaterThan(pack.entries.count, 4_000)
        XCTAssertEqual(pack.entries.map(\.name), pack.entries.map(\.name).sorted(), "deterministic order")
        let byName = Dictionary(uniqueKeysWithValues: pack.entries.map { ($0.name, $0) })

        for name in ["exit", "abort", "__assert_rtn", "_exit", "pthread_exit"] {
            XCTAssertEqual(byName[name]?.noReturn, true, name)
        }
        XCTAssertEqual(byName["exit"]?.params.map(\.type), ["int"])
        XCTAssertEqual(byName["strlen"]?.noReturn, false)

        let printf = try XCTUnwrap(byName["printf"])
        XCTAssertTrue(printf.variadic)
        XCTAssertEqual(printf.params.map(\.type), ["const char *"])
        XCTAssertEqual(printf.format, .init(kind: "printf", formatIndex: 1, firstArgIndex: 2))
        XCTAssertEqual(printf.callingConvention, "c-variadic-stack")
        XCTAssertEqual(printf.family, "libc")
        XCTAssertEqual(byName["fprintf"]?.format?.formatIndex, 2)
        XCTAssertEqual(byName["NSLog"]?.format?.kind, "NSString")
        XCTAssertEqual(byName["CFStringCreateWithFormat"]?.format?.formatIndex, 3)

        let msgSend = try XCTUnwrap(byName["objc_msgSend"])
        XCTAssertEqual(msgSend.returns, "id")
        XCTAssertEqual(msgSend.params.map(\.type), ["id", "SEL"])
        XCTAssertTrue(msgSend.variadic)
        XCTAssertEqual(msgSend.callingConvention, "objc-dispatch")

        // Floating typedefs are emitted as their scalar so AAPCS64 assigns the FP file;
        // by-value aggregates (CFRange) are left out rather than mis-assigned.
        XCTAssertEqual(byName["CFAbsoluteTimeGetCurrent"]?.returns, "double")
        XCTAssertNil(byName["CFStringGetCharacters"])
    }

    func testStandardCatalogGetsPackSignaturesBelowHandWrittenOnes() throws {
        let pack = try XCTUnwrap(CallSignaturePack.bundled)
        let handWritten = Set(CallSignatureCatalog.handWritten.map(\.canonicalName))
        // Hand-written seeds keep precedence over the pack's header spelling.
        XCTAssertEqual(CallSignatureCatalog.standard.signature(for: "_printf")?.returnType, "int32_t")
        XCTAssertEqual(CallSignatureCatalog.standard.signature(for: "_malloc")?.returnType, "void *")

        let packOnly = pack.entries.filter { !handWritten.contains($0.name) }
        XCTAssertFalse(packOnly.isEmpty)
        let write = try XCTUnwrap(pack.entries.first { $0.name == "CFAbsoluteTimeGetCurrent" })
        XCTAssertFalse(handWritten.contains(write.name))
        let signature = try XCTUnwrap(CallSignatureCatalog.standard.signature(for: "_CFAbsoluteTimeGetCurrent"))
        XCTAssertEqual(signature.returnType, "double")
        XCTAssertEqual(signature.source, "known-import")
        for entry in packOnly.prefix(50) {
            XCTAssertEqual(CallSignatureCatalog.standard.signature(for: "_" + entry.name)?.returnType,
                           entry.spec.returnType, entry.name)
        }
    }

    func testPackRejectsMalformedABIOverrides() {
        for fields in [#""abiReturns":"","params":[]"#,
                       #""abiReturns":"int","params":[{"name":"x","type":"int","abiType":""}]"#] {
            XCTAssertThrowsError(try CallSignaturePack.load(pack(
                "{\"name\":\"probe\",\"returns\":\"int\",\"variadic\":false,\"noReturn\":false," + fields + "}"
            ))) {
                XCTAssertEqual($0 as? CallSignaturePack.LoadError, .invalidEntry(index: 0))
            }
        }
    }

    func testExpandedSDKMetadataAndABIWidths() throws {
        let pack = try XCTUnwrap(CallSignaturePack.bundled)
        XCTAssertEqual(pack.generator.provenanceManifest, "Scripts/signatures/sdk_signature_manifest.json")
        let byName = Dictionary(uniqueKeysWithValues: pack.entries.map { ($0.name, $0) })
        let release = try XCTUnwrap(byName["IOObjectRelease"])
        XCTAssertEqual(release.params.first?.sourceType, "io_object_t")
        XCTAssertEqual(release.params.first?.abiType, "unsigned int")
        let catalog = CallSignatureCatalog(pack.specs)
        XCTAssertEqual(catalog.signature(for: "_IOObjectRelease")?.parameters.map(\.register), ["w0"])
        XCTAssertEqual(catalog.signature(for: "_CGContextSetLineWidth")?.parameters.map(\.register), ["x0", "d0"])
        XCTAssertEqual(byName["IOCFSerialize"]?.ownership, ["CFReturnsRetained"])
        XCTAssertEqual(byName["os_log_type_enabled"]?.params.last?.abiType, "uint8_t")
        XCTAssertTrue(byName["SecRandomCopyBytes"]?.availability?.contains(where: { $0.hasPrefix("macos 10.7 ") }) == true)
        XCTAssertEqual(byName["CGContextSetLineWidth"]?.params.last?.sourceType, "CGFloat")
        XCTAssertTrue(byName["SecRandomCopyBytes"]?.headers?.first?.hasSuffix("Security.framework/Headers/SecRandom.h") == true)
        XCTAssertNotNil(byName["MTLIOCreateCompressionContext"])
        XCTAssertNil(byName["CGContextAddRect"], "by-value CGRect has unsupported multi-register ABI")
    }

    func testSecurityPackCallGoldenRecoversThreeArguments() throws {
        let function = sdkForwarder("_SecRandomCopyBytes")
        let frame = try sdkCallFrame(function)
        XCTAssertEqual(frame.knownSignature?.parameters.map(\.register), ["x0", "x1", "x2"])
        XCTAssertEqual(frame.denseFixedRenderValues(), [
            .argument(bindingID: .gpr(0)), .argument(bindingID: .gpr(1)), .argument(bindingID: .gpr(2))
        ])
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("_SecRandomCopyBytes(arg0, arg1, arg2)"), text)
    }

    func testCoreGraphicsPackCallGoldenRecoversIndependentRegisterBanks() throws {
        let function = sdkForwarder("_CGContextSetLineWidth")
        let frame = try sdkCallFrame(function)
        XCTAssertEqual(frame.knownSignature?.parameters.map(\.type), ["CGContextRef", "double"])
        XCTAssertEqual(frame.denseFixedRenderValues(), [
            .argument(bindingID: .gpr(0)), .argument(bindingID: .simd(0))
        ])
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("_CGContextSetLineWidth(in_x0, in_d0)"), text)
    }

    private func sdkForwarder(_ target: String) -> MacIRFunction {
        MacIRBuilder().buildFunction(name: "sdk_forwarder", instructions: [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "bl", operands: target,
                           hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "ret", operands: "",
                           hasBreakpoint: false, comment: nil)
        ])
    }

    private func sdkCallFrame(_ function: MacIRFunction) throws -> MacIRCallFrame {
        try XCTUnwrap(function.instructions.compactMap { instruction -> MacIRCallFrame? in
            guard case let .call(frame, _) = instruction.operation else { return nil }
            return frame
        }.first)
    }

}
