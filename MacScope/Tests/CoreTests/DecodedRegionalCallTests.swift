import Foundation
import XCTest
@testable import MacScope

/// Full real source, not synthetic instructions or extracted function bodies.
/// Capture: rejoining-multicall-input-diagnostic/metadata.json.document-metadata.json.
/// Retained receipt SHA-256: b2a43154a98e3e2de09d2ddf9f6062427d84eaff73f510536dc61d2a518ec2dd.
/// The three seeds retain their different authored/inferred contexts and PCs.
/// Helpers are internal so the separate emitted-text oracle consumes the same
/// actual production document without relying on an unimplemented plan API.
enum RegionalCallSeed: CaseIterable {
    case jinit, j12init, j16init

    var name: String {
        switch self {
        case .jinit: return "_jinit_upsampler"
        case .j12init: return "_j12init_upsampler"
        case .j16init: return "_j16init_upsampler"
        }
    }
    var start: UInt64 {
        switch self {
        case .jinit: return 0x3ae18
        case .j12init: return 0x3b774
        case .j16init: return 0x3c038
        }
    }
    var rowCount: Int { self == .jinit ? 216 : 188 }
    var suffixStart: Int { self == .jinit ? 209 : 181 }
    var blockCount: Int { self == .jinit ? 49 : 43 }
    var callRows: [Int] {
        self == .jinit ? [21, 35, 51, 102, 122, 129, 149, 159, 168, 187, 192]
            : [21, 35, 52, 131, 136, 159]
    }
    var baselineRaw: Int { self == .jinit ? 21 : 18 }
    var baselineTotal: Int { baselineRaw }
    var flatText: String {
        switch self {
        case .jinit: return JinitCapturedData.flatText
        case .j12init: return J12InitCapturedData.flatText
        case .j16init: return J16InitCapturedData.baselineText
        }
    }
    var returnText: String { self == .j16init ? "return x0_13; // return" : "return; // return" }
    var signature: FunctionSignatureOverride? {
        guard self != .j16init else { return nil }
        let row = ArgOverride(rowToken: "compat-e86ab5708c5cb867bfc6396a", name: "cinfo",
                              type: "struct jpeg_decompress_struct *", provenance: .user)
        return FunctionSignatureOverride(returnType: "void", parameterList: .authoritative([row]),
                                         variadicState: .fixed, noReturnState: .unspecified)
    }

    struct CapturedRow {
        let address: UInt64
        let bytes: String
        let mnemonic: String
        let operands: String
        let comment: String?
        let operandWitness: UInt64
        let instructionWitness: UInt64
    }

    func capturedRows() throws -> [CapturedRow] {
        try sourceRecord.split(separator: "\n").map { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(fields.count, 7, "invalid retained row, not a decoder refusal")
            guard fields.count == 7 else { throw RegionalCallFixture.Failure.invalidCapture }
            return CapturedRow(address: try XCTUnwrap(UInt64(fields[0], radix: 16)),
                               bytes: fields[1], mnemonic: fields[2], operands: fields[3],
                               comment: fields[4].isEmpty ? nil : fields[4],
                               operandWitness: try XCTUnwrap(UInt64(fields[5], radix: 16)),
                               instructionWitness: try XCTUnwrap(UInt64(fields[6], radix: 16)))
        }
    }
}

extension RegionalCallSeed {
    var returnRow: Int {
        let matches = sourceRecord.split(separator: "\n").enumerated().compactMap { index, line in
            line.split(separator: "|", omittingEmptySubsequences: false)[2] == "ret" ? index : nil
        }
        XCTAssertEqual(matches.count, 1, "captured decoded input must contain exactly one ret row; found \(matches)")
        return matches.first ?? -1
    }

    var protectedRows: Set<Int> {
        Set(callRows + [returnRow] + (self == .j16init ? [21, 52, 181] : []))
    }
}

struct RegionalCallFixture {
    enum Failure: Error { case invalidCapture, missingHeaders(String), preprocessingFailed(Int32) }
    let seed: RegionalCallSeed
    let rows: [InstructionRow]
    let function: MacIRFunction
    let document: PseudocodeDocument
    /// Same-context legacy structure() path. Frozen actual DEFAULT text defines goto credit.
    let legacy: PseudocodeDocument
    let types: [TypeDefinition]
    /// Actual input for the explicit one-callee opaque derivative; historical negatives are nil.
    /// The original full schema2 capture remains available through OrdinaryCRecordedCallFixture.upsampler.
    let capturedInput: PseudocodeRenderInput?

    struct CallPayloadComparison {
        let row: Int
        let address: UInt64
        let baseline: String
        let after: [String]
        var changedBeyondIndentation: Bool { after != [baseline] }
    }

    /// Frozen call-contract comparison. Only enclosing indentation is normalized;
    /// the existing target, inputs, result assignment and comment are untouched.
    var callPayloads: [CallPayloadComparison] {
        let baseline = seed.baselineText.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { $0.hasSuffix("// call") }
        precondition(baseline.count == seed.callRows.count)
        return seed.callRows.enumerated().map { ordinal, row in
            let address = rows[row].address
            let after = document.lines(sourcedAt: address).map {
                $0.text.trimmingCharacters(in: .whitespaces)
            }.filter { $0.hasSuffix("// call") }
            return CallPayloadComparison(row: row, address: address,
                                         baseline: baseline[ordinal], after: after)
        }
    }

    /// Replays the exact baseline header/configuration route. The public fixture sets
    /// LP64/JPEG_LIB_VERSION=80 and then includes jpeglib.h; jpegint.h follows.
    /// Native CoreTests locate their checked-in adjacent Fixtures. Portable
    /// staged tests use the existing PORTABLE_HEADERS and PORTABLE_CLANG paths.
    /// No handwritten reduced struct catalog or default-context re-lift is used.
    static func loadTypes() throws -> [TypeDefinition] {
        let environment = ProcessInfo.processInfo.environment
        let headers = environment["PORTABLE_HEADERS"].map { URL(fileURLWithPath: $0) }
            ?? TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/libjpeg-turbo-3.2.0")
        for file in ["public-layout.c", "jpeglib.h", "jmorecfg.h", "jpegint.h"] {
            let path = headers.appendingPathComponent(file).path
            guard FileManager.default.isReadableFile(atPath: path) else { throw Failure.missingHeaders(path) }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment["PORTABLE_CLANG"] ?? "/usr/bin/clang")
        process.arguments = ["-E", "-P", "-x", "c", "-I", headers.path, "-"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("#include \"public-layout.c\"\n#include \"jpegint.h\"\n".utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.preprocessingFailed(process.terminationStatus) }
        // The analyzed binary's initial catalog is empty. Exports/functions only
        // affect prototype binding, not parsed type layouts. The exact captured
        // function signature is replayed separately rather than rediscovered.
        let prepared = HeaderImportCore.prepare(source: String(decoding: data, as: UTF8.self),
            typeDefinitions: [], exports: [], functions: [], importedPrototypes: [:], slot: .primary)
        XCTAssertTrue(prepared.types.contains { $0.name == "jpeg_decompress_struct" })
        return prepared.types
    }

    /// One catalog per multi-seed selector invocation, with no global mutable cache.
    static func makeAll() throws -> [Self] {
        let types = try loadTypes()
        return try RegionalCallSeed.allCases.map { try make($0, types: types) }
    }

    static func make(_ seed: RegionalCallSeed, types suppliedTypes: [TypeDefinition]? = nil) throws -> Self {
        if seed != .j16init {
            // Keep own-function/captured context authority, but deliberately leave
            // jround_up opaque for the regional unknown-call contract below.
            let full = try OrdinaryCRecordedCallFixture.opaqueUpsampler(seed)
            let input = full.input, function = full.function, actual = full.document
            guard suppliedTypes == nil || suppliedTypes == input.types else {
                throw Failure.invalidCapture
            }
            XCTAssertEqual(actual.text, DocumentExportService().pseudocodeText(for: input, options: .default),
                           "the real default export must exercise the same full-context production route")
            var legacyOptions = DecompilerOptions.default
            legacyOptions.structureControlFlow = false
            let legacy = PseudocodePrinter(options: legacyOptions).print(function: function, types: input.types,
                nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
                stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
            return Self(seed: seed, rows: full.rows, function: function, document: actual,
                legacy: legacy, types: input.types, capturedInput: input)
        }
        return try makeHistorical(seed, types: suppliedTypes)
    }

    /// Outside current capture coverage: deliberately historical construction, never relabelled.
    private static func makeHistorical(_ seed: RegionalCallSeed, types suppliedTypes: [TypeDefinition]?) throws -> Self {
        let captures = try seed.capturedRows()
        XCTAssertEqual(captures.count, seed.rowCount)
        guard captures.count == seed.rowCount else { throw Failure.invalidCapture }
        let bytes = try captures.flatMap { captured in
            try captured.bytes.split(separator: " ").map { try XCTUnwrap(UInt8($0, radix: 16)) }
        }
        XCTAssertEqual(bytes.count, seed.rowCount * 4)
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: seed.start)
        XCTAssertEqual(decoded.count, captures.count)
        guard decoded.count == captures.count else { throw Failure.invalidCapture }
        let rows = try zip(captures, decoded).enumerated().map { index, pair in
            let (captured, instruction) = pair
            XCTAssertEqual(captured.address, seed.start + UInt64(index * 4))
            XCTAssertEqual(instruction.address, captured.address)
            XCTAssertEqual(instruction.byteText, captured.bytes)
            XCTAssertEqual(instruction.mnemonic, captured.mnemonic)
            XCTAssertEqual(instruction.comment, captured.comment)
            let envelope = try XCTUnwrap(instruction.structuredOperands)
            XCTAssertEqual(fingerprint(instruction.structuredOperands), captured.operandWitness,
                           "complete independently retained operand envelope at row \(index)")
            if captured.mnemonic != "bl" {
                XCTAssertEqual(instruction.operands, captured.operands)
            } else {
                // Real BL text has its original symbolic opaque target; the
                // decoded envelope independently retains numeric PC authority.
                // This asserts no new symbol-address resolution theorem.
                XCTAssertTrue(captured.operands.hasPrefix("_"))
                XCTAssertEqual(envelope.coverage, .complete)
                XCTAssertEqual(envelope.opcodeClass, "bl")
            }
            XCTAssertEqual(try JSONDecoder().decode(InstructionOperands.self,
                from: JSONEncoder().encode(envelope)), envelope)
            return InstructionRow(address: captured.address, bytes: captured.bytes,
                mnemonic: captured.mnemonic, operands: captured.operands, hasBreakpoint: false,
                comment: captured.comment, structuredOperands: envelope)
        }
        let types = try suppliedTypes ?? loadTypes()
        let signature = seed.signature
        let summary = FunctionSummary(id: UUID(), name: seed.name, startAddress: seed.start,
            endAddress: seed.start + UInt64(bytes.count), confidence: 1)
        let snapshot = WorkspaceSnapshot(binaries: [], functions: [summary], instructions: rows,
            xrefs: [], hexBytes: Data(), importedPrototypes: signature.map {
                [ImageAddress(slot: .primary, address: seed.start): $0]
            } ?? [:], typeDefinitions: types)
        let input = snapshot.pseudocodeRenderInput(selectedAddress: seed.start, in: .primary)
        XCTAssertEqual(input.instructions, rows)
        XCTAssertEqual(input.signatureOverrides[seed.start], signature)
        XCTAssertNil(input.callerReturnWidth)
        XCTAssertTrue(input.nameOverrides.isEmpty)
        XCTAssertTrue(input.registerNameOverrides.isEmpty)
        XCTAssertTrue(input.stackLocalOverrides.isEmpty)
        XCTAssertTrue(input.jumpTables.isEmpty)
        XCTAssertTrue(input.objcSelectors.isEmpty)
        XCTAssertTrue(input.constantStrings.isEmpty)
        XCTAssertTrue(input.resolvedIndirectCalls.isEmpty)
        let printer = PseudocodePrinter(options: .default)
        let function = printer.buildFunction(functionName: input.functionName,
            startAddress: input.startAddress, jumpTables: input.jumpTables,
            objcSelectors: input.objcSelectors, constantStrings: input.constantStrings,
            signatureOverrides: input.signatureOverrides,
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            callerReturnWidth: input.callerReturnWidth, types: input.types,
            instructions: input.instructions)
        XCTAssertEqual(function.instructions.count, seed.rowCount)
        RenderProperties.assertCallShape(function, callRows: seed.callRows, decoded: rows,
            baselineCallLines: seed.baselineText.split(separator: "\n").map(String.init).filter { $0.hasSuffix("// call") })
        RenderProperties.assertReturnShape(function, returnRow: seed.returnRow)
        guard function.instructions.count == seed.rowCount else { throw Failure.invalidCapture }
        for (index, instruction) in function.instructions.enumerated() {
            XCTAssertEqual(instruction.source.structuredOperands, rows[index].structuredOperands)
        }
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        XCTAssertEqual(cfg.blocks.count, seed.blockCount)
        // Captured loop-header blocks end in CBZ (81/82); the back-edge
        // blocks end in B.LT (199/143). RET has no successor.
        RenderProperties.assertSuccessorCounts(cfg, rows: seed == .jinit
            ? [71: 2, 199: 2, seed.returnRow: 0]
            : [72: 2, 143: 2, seed.returnRow: 0])
        XCTAssertEqual(cfg.entryIndex, 0)
        XCTAssertEqual(cfg.loopHeaders, [15])
        XCTAssertEqual(cfg.backEdges, [CFGEdge(seed == .jinit ? 45 : 31, 15)])
        XCTAssertTrue(cfg.irreducibleBlocks.isEmpty)
        XCTAssertFalse(cfg.hasUnresolvedTargets)
        let actual = printer.print(function: function, types: input.types,
            nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
            stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
        XCTAssertEqual(actual.text, DocumentExportService().pseudocodeText(for: input, options: .default),
                       "the real default export must exercise the same full-context production route")
        var legacyOptions = DecompilerOptions.default
        legacyOptions.structureControlFlow = false
        let legacy = PseudocodePrinter(options: legacyOptions).print(function: function, types: input.types,
            nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
            stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
        return Self(seed: seed, rows: rows, function: function, document: actual, legacy: legacy, types: types, capturedInput: nil)
    }

    /// Preserve every reflected field. Only module qualification and the order
    /// of a numeric Set's elements are normalized. The actual captured function
    /// uses numeric sets only for call observation scopes (GPR0...7 and empty).
    /// No nil marker, operand role, scope member, memory effect or enum is dropped.
    static func normalizedShape<T>(_ value: T) -> String {
        var text = String(reflecting: value)
        for module in ["MacScopeAnalysisCore.", "MacScope.", "RenderAll."] {
            text = text.replacingOccurrences(of: module, with: "")
        }
        let pattern = try! NSRegularExpression(pattern: #"Set\(\[([0-9, ]*)\]\)"#)
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            let body = Range(match.range(at: 1), in: text)!
            let numbers = text[body].split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces))! }.sorted()
            let replacement = "Set([" + numbers.map(String.init).joined(separator: ", ") + "])"
            text.replaceSubrange(Range(match.range, in: text)!, with: replacement)
        }
        return text
    }

    static func fingerprint<T>(_ value: T) -> UInt64 {
        normalizedShape(value).utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }
}

/// The named behavioral RED is a default-export failure, never a text-machine
/// unsupported-helper or unbound-SSA error. The independent oracle calls this
/// before interpreting the new output. Baseline is the retained DEFAULT text,
/// not a regenerated disabled-structure comparator. The legacy path itself
/// still retains its established simple-if peepholes.
@discardableResult
func requireRegionalCallRepair(_ fixture: RegionalCallFixture,
                               file: StaticString = #filePath, line: UInt = #line) -> Bool {
    // A flat `goto loc_` label counts exactly like the numeric `goto 0x`
    // spelling, and an unconditional `goto loc_` like the `__branch` it
    // replaces (never counted), so label spelling earns no credit.
    func count(raw: Bool, _ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            if line.contains("goto loc_") || line.contains("goto L_") { return !line.contains("unconditional branch") }
            return line.contains(raw ? "goto 0x" : "goto ")
        }.count
    }
    let seed = fixture.seed, actual = fixture.document.text
    let baselineRaw = count(raw: true, seed.baselineText)
    let baselineTotal = count(raw: false, seed.baselineText)
    XCTAssertEqual(baselineRaw, seed.baselineRaw, file: file, line: line)
    XCTAssertEqual(baselineTotal, seed.baselineTotal, file: file, line: line)
    if count(raw: true, actual) == baselineRaw {
        XCTAssertEqual(actual, seed.baselineText,
            "PRE_REPAIR_CONTEXT_IDENTITY_REQUIRED: unchanged raw count must reproduce the complete retained default text, not a stripped type/render context",
            file: file, line: line)
    }
    let rawImproved = count(raw: true, actual) < baselineRaw
    let totalImproved = count(raw: false, actual) < baselineTotal
    let structured = actual.contains("while (") || actual.contains("do {") || actual.contains("for (")
    XCTAssertTrue(rawImproved,
        "REGIONAL_MULTICALL_REPAIR_REQUIRED: default export must decrease actual raw transfers for \(seed.name)\n\(actual)",
        file: file, line: line)
    XCTAssertTrue(totalImproved,
        "REGIONAL_MULTICALL_REPAIR_REQUIRED: relabeling transfers earns no structuring credit for \(seed.name)",
        file: file, line: line)
    XCTAssertTrue(structured,
        "REGIONAL_MULTICALL_REPAIR_REQUIRED: recover genuine loop control for \(seed.name)", file: file, line: line)
    return rawImproved && totalImproved && structured
}

final class DecodedRegionalCallTests: XCTestCase {
    func testFullCapturedUpsamplersRetainAuthoredJroundUpInBothModes() throws {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                for seed in [RegionalCallSeed.jinit, .j12init] {
                    let full = try OrdinaryCRecordedCallFixture.upsampler(seed)
                    XCTAssertEqual(full.function.ssaEnabled, ssa)
                    let row = seed == .jinit ? 187 : 131
                    XCTAssertEqual(full.rows[row].operands, "_jround_up")
                    guard case let .call(frame, result) = full.function.instructions[row].operation else {
                        return XCTFail("captured BL must remain a call")
                    }
                    let declaration = try XCTUnwrap(full.input.authoredCallSignaturesByTarget["_jround_up"])
                    let signature = try XCTUnwrap(frame.knownSignature)
                    XCTAssertEqual(signature.source, "authored-declaration")
                    XCTAssertEqual(signature.returnType, declaration.returnType)
                    XCTAssertEqual(signature.returnType, "int64_t")
                    XCTAssertEqual(signature.parameters.map(\.register), ["x0", "x1"])
                    XCTAssertEqual(signature.parameters.map(\.name), ["a", "b"])
                    XCTAssertEqual(signature.parameters.map(\.index), [0, 1])
                    XCTAssertEqual(frame.arguments.count, 2)
                    XCTAssertNotNil(result)
                    XCTAssertEqual(full.input.signatureOverrides[seed.start], seed.signature)
                }
            }
        }
    }

    func testOpaqueUpsamplerDerivativeRemovesOnlyCalleeDeclarationInBothModes() throws {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                for seed in [RegionalCallSeed.jinit, .j12init] {
                    let full = try OrdinaryCRecordedCallFixture.upsampler(seed)
                    let opaque = try OrdinaryCRecordedCallFixture.opaqueUpsampler(seed)
                    XCTAssertEqual(opaque.function.ssaEnabled, ssa)
                    var expected = full.input.authoredCallSignaturesByTarget
                    let declaration = try XCTUnwrap(expected.removeValue(forKey: "_jround_up"))
                    XCTAssertEqual(opaque.input.authoredCallSignaturesByTarget, expected)
                    var restored = opaque.input
                    restored.authoredCallSignaturesByTarget["_jround_up"] = declaration
                    XCTAssertEqual(restored, full.input)
                    XCTAssertEqual(RegionalSchema2Context(restored), RegionalSchema2Context(full.input))
                    XCTAssertEqual(RegionalSchema2ParameterIndex.capture(restored),
                                   RegionalSchema2ParameterIndex.capture(full.input))
                    XCTAssertEqual(opaque.input.instructions, full.input.instructions)
                    XCTAssertEqual(opaque.input.signatureOverrides, full.input.signatureOverrides)
                    XCTAssertEqual(opaque.input.types, full.input.types)
                    XCTAssertEqual(opaque.input.signatureOverrides[seed.start], seed.signature)
                    XCTAssertEqual(opaque.rows, full.rows)
                    XCTAssertEqual(opaque.baselineText, full.baselineText)
                    let row = seed == .jinit ? 187 : 131
                    guard case let .call(frame, result) = opaque.function.instructions[row].operation else {
                        return XCTFail("opaque derivative must retain the captured BL")
                    }
                    XCTAssertNil(frame.knownSignature)
                    XCTAssertEqual(frame.arguments.observationScope.canonicalGPRIndicesForAudit, Array(0..<8))
                    for argument in frame.arguments.canonicalPhysicalEntriesForAudit {
                        XCTAssertEqual(argument.role, .unknown)
                    }
                    XCTAssertNotNil(result)
                }
            }
        }
    }

    func testJinitUpsamplerPreservesCapturedContextAndStructuresDefaultExport() throws {
        var alpha = SSAAlphaEquivalence()
        try check(.jinit, alpha: &alpha)
    }

    func testJ12initUpsamplerPreservesCapturedContextAndStructuresDefaultExport() throws {
        var alpha = SSAAlphaEquivalence()
        try check(.j12init, alpha: &alpha)
    }

    // Each selector is intended for both the default and SSA property-test lanes.
    // Keep the exact captured bytes and the complete existing ownership assertions.
    func testJinitCMN7CarryConstantKeepsExact32BitBoundary() throws {
        let row = try XCTUnwrap(RegionalCallSeed.jinit.capturedRows().first { $0.address == 0x3ae4c })
        XCTAssertEqual(row.bytes, "3f 1d 00 31")
        XCTAssertEqual(row.mnemonic, "cmn")
        XCTAssertEqual(row.operands, "w9, #7")
        try RegionalCallRowOwnership.assertCMNConstantControls(amount: 7)
        var alpha = SSAAlphaEquivalence()
        try check(.jinit, alpha: &alpha)
    }

    func testJ12initCMN4CarryConstantKeepsExact32BitBoundary() throws {
        let row = try XCTUnwrap(RegionalCallSeed.j12init.capturedRows().first { $0.address == 0x3b7a8 })
        XCTAssertEqual(row.bytes, "3f 11 00 31")
        XCTAssertEqual(row.mnemonic, "cmn")
        XCTAssertEqual(row.operands, "w9, #4")
        try RegionalCallRowOwnership.assertCMNConstantControls(amount: 4)
        var alpha = SSAAlphaEquivalence()
        try check(.j12init, alpha: &alpha)
    }

    // The v1 j16 positive selector is superseded, not an accepted expectation.
    // Its complete capture remains used by the call/terminal-contract terminal-refusal regression.

    func testRetainedCallableNamesCannotBeShadowedByRegionalStorage() throws {
        let fixture = try RegionalCallFixture.make(.jinit)
        let capturedInput = try XCTUnwrap(fixture.capturedInput)
        var legacyOptions = DecompilerOptions.default
        legacyOptions.structureControlFlow = false
        // W21's merge at 0x3af04 has an incoming storage definition at the
        // branch 0x3aefc. Bind the collision to that same source address as
        // generated names evolve, never to an arbitrary declared temporary.
        let nativeStorage: String
        if SSAPropertyAssertions.enabled {
            guard let phi = SSAPropertyAssertions.phi(fixture.function, block: 0x3af04, cell: 21, width: 32,
                incoming: [(0x3aefc, 0x3aef8), (0x3af00, 0x3af00)]) else { return }
            let identity = MacIRPhiEdgeIdentity(blockAddress: phi.blockAddress,
                predecessorAddress: 0x3aefc, destination: phi.destination)
            let copies = fixture.document.lines.filter { $0.syntheticPhiEdge == identity && $0.kind == .instruction }
            let copy = try XCTUnwrap(copies.last)
            let tokens = try OrdinaryC.lex(copy.text).map(\.text)
            let assignment = try XCTUnwrap(tokens.firstIndex(of: "="))
            XCTAssertGreaterThan(assignment, 0)
            guard assignment > 0 else { return }
            let storageIdentity = tokens[assignment - 1]
            let declarations = try fixture.document.lines.filter { $0.kind == .declaration }.flatMap {
                try OrdinaryC.lex($0.text).map(\.text)
            }.filter { $0 == storageIdentity }
            XCTAssertEqual(declarations.count, 1, "the edge identity must name one declared storage object")
            nativeStorage = try XCTUnwrap(declarations.first)
            XCTAssertNil(copy.sourceAddress, "the edge copy must not claim a predecessor's source row")
        } else {
            let joinDefinitions = fixture.document.lines(sourcedAt: 0x3aefc)
                .filter { $0.kind == .instruction }
            let joinDefinition = try XCTUnwrap(joinDefinitions.count == 1 ? joinDefinitions.first : nil)
            let joinTokens = try OrdinaryC.lex(joinDefinition.text).map(\.text)
            guard joinTokens.count == 4, Array(joinTokens.dropFirst()) == ["=", "w21_1", ";"] else {
                return XCTFail("expected the source-bound W21 join definition")
            }
            nativeStorage = joinTokens[0]
        }
        let declared = try fixture.document.lines.filter { $0.kind == .declaration }.flatMap {
            try OrdinaryC.lex($0.text).map(\.text)
        }
        XCTAssertTrue(declared.contains(nativeStorage))
        XCTAssertFalse(declared.contains("rgn_regional_r0_0"))
        func exactCalls(_ after: PseudocodeDocument, _ old: PseudocodeDocument) {
            for row in fixture.seed.callRows {
                let address = fixture.rows[row].address
                let before = old.lines(sourcedAt: address).filter { $0.text.hasSuffix("// call") }
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                let actual = after.lines(sourcedAt: address).filter { $0.text.hasSuffix("// call") }
                    .map { $0.text.trimmingCharacters(in: .whitespaces) }
                XCTAssertEqual(before.count, 1)
                XCTAssertEqual(actual, before, "protected callable/result/arguments retain their exact identity")
            }
        }
        func check(_ after: PseudocodeDocument, _ old: PseudocodeDocument, collision: Bool) {
            exactCalls(after, old)
            if collision {
                XCTAssertEqual(after.lines, old.lines)
                XCTAssertNil(after.regionTree)
                XCTAssertEqual(after.lines.filter { $0.kind == .declaration },
                               old.lines.filter { $0.kind == .declaration })
            } else {
                XCTAssertNotNil(after.regionTree, "a harmless historical prefix is not native storage")
                XCTAssertTrue(after.text.contains("while ("))
                XCTAssertLessThan(after.text.components(separatedBy: "goto ").count,
                                  old.text.components(separatedBy: "goto ").count)
                XCTAssertFalse(after.lines.filter { $0.kind == .declaration }.contains {
                    $0.text.contains("rgn_regional_r0_0")
                })
            }
        }
        for name in ["rgn_regional_r0_0", "(rgn_regional_r0_0)", "x0_1", "(x0_1)",
                     nativeStorage, "(\(nativeStorage))"] {
            var overrides = capturedInput.nameOverrides
            overrides["_jround_up"] = name
            let after = PseudocodePrinter().print(function: fixture.function,
                types: capturedInput.types, nameOverrides: overrides,
                registerNameOverrides: capturedInput.registerNameOverrides,
                stackLocalOverrides: capturedInput.stackLocalOverrides,
                resolvedIndirectCalls: capturedInput.resolvedIndirectCalls)
            let old = PseudocodePrinter(options: legacyOptions).print(function: fixture.function,
                types: capturedInput.types, nameOverrides: overrides,
                registerNameOverrides: capturedInput.registerNameOverrides,
                stackLocalOverrides: capturedInput.stackLocalOverrides,
                resolvedIndirectCalls: capturedInput.resolvedIndirectCalls)
            check(after, old, collision: !name.contains("rgn_regional_r0_0"))
        }
        let address = fixture.rows[fixture.seed.callRows[0]].address
        for name in ["rgn_regional_r0_0", "(rgn_regional_r0_0)", nativeStorage, "(\(nativeStorage))"] {
            var resolved = capturedInput.resolvedIndirectCalls
            resolved[address] = PseudocodeIndirectCall(target: 0x1234,
                name: name, slot: "collision-test-slot")
            let after = PseudocodePrinter().print(function: fixture.function,
                types: capturedInput.types, nameOverrides: capturedInput.nameOverrides,
                registerNameOverrides: capturedInput.registerNameOverrides,
                stackLocalOverrides: capturedInput.stackLocalOverrides,
                resolvedIndirectCalls: resolved)
            let old = PseudocodePrinter(options: legacyOptions).print(function: fixture.function,
                types: capturedInput.types, nameOverrides: capturedInput.nameOverrides,
                registerNameOverrides: capturedInput.registerNameOverrides,
                stackLocalOverrides: capturedInput.stackLocalOverrides,
                resolvedIndirectCalls: resolved)
            check(after, old, collision: !name.contains("rgn_regional_r0_0"))
        }
    }

    private func check(_ seed: RegionalCallSeed, alpha: inout SSAAlphaEquivalence) throws {
        let fixture = try RegionalCallFixture.make(seed)
        let function = fixture.function, document = fixture.document
        let legacyFunction: MacIRFunction
        if SSAPropertyAssertions.enabled {
            legacyFunction = SSAAlphaEquivalence.legacyFunction(from: try XCTUnwrap(fixture.capturedInput))
            alpha = SSAAlphaEquivalence(expected: legacyFunction, actual: function)
        } else {
            legacyFunction = function
        }
        let formal = try XCTUnwrap(function.parameters.count == 1 ? function.parameters.first : nil)
        XCTAssertEqual(formal.register, "x0")
        XCTAssertEqual(formal.sourcePosition, 0)
        XCTAssertEqual(formal.bindingID, .gpr(0))
        XCTAssertEqual(formal.abiLocation, .gpr(index: 0, carrierWidth: 64))
        XCTAssertNil(formal.richLocation)
        if seed == .j16init {
            XCTAssertEqual(formal.id.rawValue, "recovered:gpr:0")
            XCTAssertEqual(formal.index, 0)
            XCTAssertEqual(formal.name, "arg0")
            XCTAssertEqual(formal.type, "int64_t")
            XCTAssertEqual(formal.evidence, .heuristicEntryRead)
            XCTAssertEqual(function.returnType, "int64_t")
            XCTAssertEqual(function.returnValue, .register(name: "x0", version: 13))
        } else {
            XCTAssertEqual(formal.id.rawValue, "compat-e86ab5708c5cb867bfc6396a")
            XCTAssertEqual(formal.index, -1)
            XCTAssertEqual(formal.name, "cinfo")
            XCTAssertEqual(formal.type, "struct jpeg_decompress_struct *")
            XCTAssertEqual(formal.evidence, .authoritativeUser)
            XCTAssertEqual(function.returnType, "void")
            XCTAssertNil(function.returnValue)
        }
        XCTAssertFalse(function.isNoReturn)
        XCTAssertFalse(function.isVariadic)
        XCTAssertFalse(function.observesFPSR)
        XCTAssertEqual(function.stackFrameSize, 0, "retain recorded metadata; this does not erase real SP saves/restores")
        XCTAssertTrue(function.localVariables.isEmpty)
        if SSAPropertyAssertions.enabled, seed != .j16init {
            let join: UInt64 = seed == .jinit ? 0x3b120 : 0x3b99c
            let producers: [(UInt64, UInt64)] = seed == .jinit
                ? [(0x3af7c, 0x3af74), (0x3afe8, 0x3afe4), (0x3b11c, 0x3b118)]
                : [(0x3b8dc, 0x3b8d4), (0x3b930, 0x3b92c), (0x3b998, 0x3b994)]
            guard let phi = SSAPropertyAssertions.phi(function, block: join, cell: 0, width: 64,
                incoming: producers),
                  let store = function.instructions.first(where: { $0.source.address == join }),
                  case let .store(value, address) = store.operation else {
                return XCTFail("the method store must consume its three concrete predecessors")
            }
            SSAPropertyAssertions.assertView(value, of: phi, width: 64)
            let pointerProducers: [(UInt64, UInt64)] = seed == .jinit
                ? [(0x3af7c, 0x3af70), (0x3afe8, 0x3afe0), (0x3b11c, 0x3b11c)]
                : [(0x3b8dc, 0x3b8d0), (0x3b930, 0x3b928), (0x3b998, 0x3b998)]
            guard let pointerPhi = SSAPropertyAssertions.phi(function, block: join, cell: 12, width: 64,
                incoming: pointerProducers),
                  case let .binaryExpression(_, base, _) = address else {
                return XCTFail("the method-table address must consume its pointer merge")
            }
            SSAPropertyAssertions.assertView(base, of: pointerPhi, width: 64)
            let info = try XCTUnwrap(function.ssaInfo)
            let storeRow = try XCTUnwrap(info.sourceAddresses.firstIndex(of: join))
            let indexID = try XCTUnwrap(info.plan.rowReadBindings[storeRow][22])
            let indexValue = try XCTUnwrap(info.values[info.plan.canonicalID(indexID)])
            guard case let .binaryExpression(_, _, scaledIndex) = address,
                  case let .binaryExpression(operation, index, amount) = scaledIndex else {
                return XCTFail("the table index must retain the original shifted X22 input")
            }
            XCTAssertEqual(operation, "<<")
            XCTAssertEqual(amount, .immediate(3))
            XCTAssertEqual(index, indexValue, "the store uses the bound reaching cell-22 definition")
            XCTAssertFalse(address.description.contains("unavailable"), "all table-address cells require bound SSA definitions")
            XCTAssertFalse(document.lines(sourcedAt: join).contains { $0.text.contains("unavailable_") })
        } else {
            XCTAssertTrue(function.phis.isEmpty)
        }
        let actualCallRows = function.instructions.indices.filter {
            if case .call = function.instructions[$0].operation { return true }; return false
        }
        XCTAssertEqual(actualCallRows, seed.callRows)
        for index in actualCallRows {
            guard case let .call(frame, result) = function.instructions[index].operation else { continue }
            XCTAssertNil(frame.knownSignature)
            XCTAssertNil(frame.tailCountEvidence)
            XCTAssertNil(frame.richArguments)
            XCTAssertNil(frame.indirectResultPointer)
            XCTAssertNotNil(result, "outer void never fabricates void callee authority")
            XCTAssertEqual(frame.arguments.observationScope.canonicalGPRIndicesForAudit, Array(0..<8))
            XCTAssertTrue(frame.arguments.observationScope.canonicalScalarSIMDIndicesForAudit.isEmpty)
            XCTAssertTrue(frame.arguments.observationScope.canonicalCallStackRangesForAudit.isEmpty)
            for argument in frame.arguments.canonicalPhysicalEntriesForAudit {
                XCTAssertEqual(argument.role, .unknown)
                XCTAssertNil(argument.selectorEvidence)
            }
        }
        XCTAssertEqual(document.parameters, fixture.legacy.parameters)
        XCTAssertEqual(document.returnType, fixture.legacy.returnType)
        XCTAssertEqual(document.nameBindings, fixture.legacy.nameBindings)
        XCTAssertEqual(document.callTargets, fixture.legacy.callTargets)
        XCTAssertEqual(document.callSignatures, fixture.legacy.callSignatures)
        XCTAssertEqual(document.localVariables, fixture.legacy.localVariables)
        XCTAssertEqual(document.stackFrameSize, fixture.legacy.stackFrameSize)
        XCTAssertEqual(document.lines.filter { $0.kind == .signature }.map(\.text),
                       fixture.legacy.lines.filter { $0.kind == .signature }.map(\.text))
        XCTAssertEqual(document.lines.filter { $0.kind == .signature }.map(\.text),
                       [String(seed.baselineText.split(separator: "\n").first!)])
        XCTAssertFalse(DecompilerOptions.default.recoverSharedTails)
        XCTAssertFalse(DecompilerOptions.default.recoverLoopExits)
        XCTAssertFalse(DecompilerOptions.default.recoverGuardRegions)

        XCTAssertEqual(document.lines.filter { $0.text.trimmingCharacters(in: .whitespaces).hasSuffix("// call") }.count,
                       seed.callRows.count, "exactly the captured number of static opaque call payloads")
        for call in fixture.callPayloads {
            if SSAPropertyAssertions.enabled {
                alpha.assertEquivalent(call.after, [call.baseline])
                XCTAssertEqual(document.lines.filter {
                    var candidate = alpha
                    return candidate.mismatch(actual: $0.text.trimmingCharacters(in: .whitespaces),
                                              expected: call.baseline) == nil
                }.count, 1, "no static call duplication, even when the source lies in a loop")
            } else {
                XCTAssertEqual(call.after, [call.baseline], "one unchanged opaque call payload at \(call.address)")
                XCTAssertFalse(call.changedBeyondIndentation,
                               "C4 forbids new, removed or renamed result/target/argument expressions")
                XCTAssertEqual(document.lines.filter { $0.text.trimmingCharacters(in: .whitespaces) == call.baseline }.count, 1,
                               "no static call duplication, even when the source lies in a loop")
            }
        }
        guard requireRegionalCallRepair(fixture) else { return }
        if SSAPropertyAssertions.enabled {
            let frozen = try OrdinaryC.contract(rows: fixture.rows, function: legacyFunction,
                baseline: seed.baselineText, callRows: seed.callRows)
            let contract = try frozen.alphaEquivalent(to: document, using: &alpha)
            try RegionalCallRowOwnership.require(document: document, rows: fixture.rows,
                function: function, baseline: seed.baselineText, callRows: seed.callRows,
                preparedContract: contract)
        } else {
            try RegionalCallRowOwnership.require(document: document, rows: fixture.rows,
                function: function, baseline: seed.baselineText, callRows: seed.callRows)
        }
        // Prefix and suffix remain real captured machine effects. A call may
        // alias saved-stack memory, so replacing restores by entry snapshots is
        // forbidden. Extra state-export lines may precede a suffix row, but its
        // exact original payload and source association must occur once.
        for index in Array(0..<7) + Array(seed.suffixStart..<seed.rowCount) {
            let address = fixture.rows[index].address
            let expected = fixture.legacy.lines(sourcedAt: address).map { $0.text.trimmingCharacters(in: .whitespaces) }
            let actual = document.lines(sourcedAt: address).map { $0.text.trimmingCharacters(in: .whitespaces) }
            for payload in expected {
                // Both documents were rendered from this same lifted function;
                // their register identities already use the actual namespace.
                XCTAssertEqual(actual.filter { $0 == payload }.count, 1, "immutable exterior effect at row \(index)")
            }
        }
        let returnAddress = fixture.rows.last!.address
        XCTAssertEqual(document.lines(sourcedAt: returnAddress).map { $0.text.trimmingCharacters(in: .whitespaces) },
                       [seed.returnText], "original void/X0 terminal payload, not a fabricated return")
        try assertContradictoryCallsDecline(fixture, alpha: &alpha)
    }

    /// Negative controls mutate one authority in a complete actual capture.
    /// They are not positive synthetic/source-void fixtures or callee proofs.
    /// Refusal must preserve the exact old structure() output transactionally,
    /// without partial alias bindings, new results or a selectively kept region.
    private func assertContradictoryCallsDecline(_ fixture: RegionalCallFixture,
                                               alpha: inout SSAAlphaEquivalence) throws {
        let seed = fixture.seed
        let index = try XCTUnwrap(seed.callRows.first { fixture.rows[$0].mnemonic == "bl" })
        let call = try XCTUnwrap(fixture.callPayloads.first { $0.row == index })
        let capturedPayload: String
        if SSAPropertyAssertions.enabled {
            capturedPayload = try XCTUnwrap(alpha.translatedExpected(call.baseline),
                "the method's source-bound map must already cover this frozen call")
            XCTAssertEqual(fixture.legacy.lines(sourcedAt: call.address).map {
                $0.text.trimmingCharacters(in: .whitespaces)
            }.filter { $0.hasSuffix("// call") }, [capturedPayload],
                "the translated original call retains its exact source row")
        } else {
            capturedPayload = call.baseline
        }
        let original = fixture.function.instructions[index]
        guard case let .call(frame, result) = original.operation else {
            return XCTFail("complete source lost its original direct opaque call")
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(original.source.operands, frame.target)
        let envelope = try XCTUnwrap(original.source.structuredOperands)
        XCTAssertEqual(envelope.operands.count, 1)
        guard envelope.operands.count == 1, case let .pcRelative(reference) = envelope.operands[0] else {
            return XCTFail("captured direct BL lost its numeric PC-relative authority")
        }
        func baseline(replacing payload: String) -> String {
            var lines = fixture.legacy.text.components(separatedBy: "\n")
            let sites = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == capturedPayload }
            XCTAssertEqual(sites.count, 1)
            guard let site = sites.first, sites.count == 1 else { return "INVALID_CAPTURED_CALL_SITE" }
            let indentation = lines[site].prefix { $0 == " " || $0 == "\t" }
            lines[site] = String(indentation) + payload
            return lines.joined(separator: "\n")
        }
        let capturedInput = try XCTUnwrap(fixture.capturedInput)
        func decline(_ function: MacIRFunction, expected: String, reason: String) {
            var options = DecompilerOptions.default
            options.structureControlFlow = false
            let legacy = PseudocodePrinter(options: options).print(function: function, types: capturedInput.types,
                nameOverrides: capturedInput.nameOverrides, registerNameOverrides: capturedInput.registerNameOverrides,
                stackLocalOverrides: capturedInput.stackLocalOverrides, resolvedIndirectCalls: capturedInput.resolvedIndirectCalls)
            XCTAssertEqual(legacy.text, expected,
                           "negative reference changes only the explicitly contradicted field: \(reason)")
            let actual = PseudocodePrinter(options: .default).print(function: function, types: capturedInput.types,
                nameOverrides: capturedInput.nameOverrides, registerNameOverrides: capturedInput.registerNameOverrides,
                stackLocalOverrides: capturedInput.stackLocalOverrides, resolvedIndirectCalls: capturedInput.resolvedIndirectCalls)
            XCTAssertEqual(actual.text, legacy.text,
                           "unproved call boundary must retain exact legacy fallback: \(reason)")
            XCTAssertEqual(actual.lines, legacy.lines,
                           "transactional refusal cannot leave alias declarations/source/token changes: \(reason)")
            XCTAssertEqual(actual.parameters, fixture.document.parameters)
            XCTAssertEqual(actual.returnType, fixture.document.returnType)
            XCTAssertNil(actual.regionTree, "contradictory evidence cannot gain structured admission")
            // A43/g: the physical-state classification (A38 gate) describes the SSA function only.
            if SSAPropertyAssertions.enabled {
                let declinedCFG = CFGBuilder.buildCFG(instructions: function.instructions)
                if case let .failure(refusal) = RegionalPhysicalStatePlan.proveClassified(
                    function: function, cfg: declinedCFG) {
                    XCTAssertTrue(refusal.isContradiction, "A41: \(reason) classifies as contradiction, got \(refusal)")
                } else {
                    XCTFail("A41: \(reason) must not prove")
                }
            }
            XCTAssertEqual(actual.lines.filter { $0.kind == .declaration },
                           legacy.lines.filter { $0.kind == .declaration },
                           "no partial physical-state declarations survive refusal")
            XCTAssertEqual(actual.lines.filter { $0.kind == .signature || $0.kind == .metadata },
                           fixture.legacy.lines.filter { $0.kind == .signature || $0.kind == .metadata },
                           "contradiction never changes original signature/metadata")
        }

        // The original source symbol stays fixed, while only the supplied opaque
        // operation claims a different symbol. No name/address whitelist is used.
        let wrongTarget = "_rgn_contradictory_opaque_target"
        let wrongFrame = try XCTUnwrap(MacIRCallFrame(target: wrongTarget,
            knownSignature: frame.knownSignature, tailCountEvidence: frame.tailCountEvidence,
            controlInputs: frame.controlInputs, arguments: frame.arguments,
            richArguments: frame.richArguments, indirectResultPointer: frame.indirectResultPointer))
        var changedTarget = fixture.function
        changedTarget.instructions[index].operation = .call(frame: wrongFrame, result: result)
        let wrongTargetPayload = capturedPayload.replacingOccurrences(of: frame.target + "(", with: wrongTarget + "(")
        XCTAssertNotEqual(wrongTargetPayload, capturedPayload)
        decline(changedTarget, expected: baseline(replacing: wrongTargetPayload),
                reason: "symbolic frame target contradicts unchanged captured BL source")

        // Byte text, PC and source symbol all stay fixed. Only the envelope's
        // encoded target delta changes; it must not become symbol authority.
        var changedEnvelope = fixture.function
        changedEnvelope.instructions[index].source.structuredOperands = InstructionOperands(
            architecture: envelope.architecture, schemaVersion: envelope.schemaVersion,
            coverage: envelope.coverage, opcodeClass: envelope.opcodeClass,
            operands: [.pcRelative(.init(baseAddress: reference.baseAddress,
                displacement: reference.displacement + 4, pageRelative: reference.pageRelative,
                format: reference.format))], presentation: envelope.presentation,
            semantics: envelope.semantics, legacyText: envelope.legacyText)
        decline(changedEnvelope, expected: fixture.legacy.text,
                reason: "BL numeric PC-relative envelope contradicts unchanged bytes")

        // No result is introduced here. Removing this already printed result
        // makes the boundary ineligible; fallback must print only f(...), never
        // invent x = f(...) or admit a current-state result on its continuation.
        var removedResult = fixture.function
        removedResult.instructions[index].operation = .call(frame: frame, result: nil)
        let resultPrefix = String(describing: try XCTUnwrap(result)) + " = "
        XCTAssertTrue(capturedPayload.hasPrefix(resultPrefix))
        let noResultPayload = String(capturedPayload.dropFirst(resultPrefix.count))
        decline(removedResult, expected: baseline(replacing: noResultPayload),
                reason: "existing opaque result removed; no fabricated result or source-void claim")
    }
}

/// ordinary-C presentation replacement for the two complete upsamplers and skip_variable.
/// Every original row is accounted for, but a pure NZCV definition need not emit
/// a fake statement. Literal source dataflow and parsed C establish the omitted
/// predicate operands; the edge ledger establishes routes, not arithmetic truth.
/// This is static ownership/refusal coverage, not another numerical-oracle run.
enum RegionalCallRowOwnership {
    /// A36: whether every listed reaching definition is a machine row sign-extending `narrow` bits into its X register.
    static func allSignExtend(_ definitions: [(mnemonic: String, first: String, register: Int)], narrow: Int) -> Bool {
        !definitions.isEmpty && definitions.allSatisfy {
            Proof.signExtends(mnemonic: $0.mnemonic, first: $0.first, register: $0.register, narrow: narrow)
        }
    }
    /// Only a resolver-certified signed32 encoding of an actual Boolean comparison.
    /// Unwrapping supplies no writer/edge authority: Proof still proves that below.
    static func transportedBooleanComparison(_ expression: OrdinaryC.Expression,
                                              in candidate: OrdinaryC.Program) -> OrdinaryC.Expression? {
        guard candidate.representationCasts.contains(expression.span),
              candidate.expressionTypes[expression.span] == .i32,
              case let .select(_, positive, _) = expression.node,
              case let .cast(signed, normalized) = positive.node, signed == .i32,
              case let .cast(unsigned, comparison) = normalized.node, unsigned == .u32,
              candidate.expressionTypes[normalized.span] == .u32,
              candidate.expressionTypes[comparison.span] == .i32,
              case let .binary(op, _, _) = comparison.node,
              ["==", "!=", "<", ">=", ">", "<="].contains(op) else { return nil }
        return comparison
    }
    private typealias C = OrdinaryC
    private typealias L = OrdinaryCSourceEdgeLedger
    private struct Definition: Hashable { let row: Int; let register: Int }
    private enum Value: Equatable { case definitions(Set<Definition>), constant(UInt64) }
    private indirect enum Predicate: Equatable {
        case compare(String, Int, Bool, Value, Value)
        case and(Predicate, Predicate), or(Predicate, Predicate)
        /// Only discrete unsigned constant bounds; never wrap the maximum,
        /// change signedness/width, or discard a reaching-definition identity.
        var canonical: Predicate {
            switch self {
            case let .compare(op, width, false, left, .constant(bound))
                where (op == ">" || op == "<=") && bound < C.CType(width, true).mask:
                return .compare(op == ">" ? ">=" : "<", width, false, left, .constant(bound + 1))
            case let .and(a, b): return .and(a.canonical, b.canonical)
            case let .or(a, b): return .or(a.canonical, b.canonical)
            default: return self
            }
        }
        func equivalent(to other: Predicate) -> Bool { canonical == other.canonical }
        var inverse: Predicate {
            switch self {
            case let .compare(op, width, signed, a, b):
                let opposite = ["==": "!=", "!=": "==", "<": ">=", ">=": "<", ">": "<=", "<=": ">"]
                return .compare(opposite[op]!, width, signed, a, b)
            case let .and(a, b): return .or(a.inverse, b.inverse)
            case let .or(a, b): return .and(a.inverse, b.inverse)
            }
        }
    }
    private static func constant(_ expression: C.Expression) throws -> C.Value? {
        switch expression.node {
        case let .literal(value): return value
        case let .cast(type, value): return try constant(value).map { try C.converted($0, to: type) }
        case let .unary("~", operand):
            guard let old = try constant(operand), !old.type.pointer else { return nil }
            let value = try C.converted(old, to: old.type.promoted)
            return .init(~value.bits, value.type)
        case let .unary("-", operand):
            guard let old = try constant(operand), !old.type.pointer else { return nil }
            let value = try C.converted(old, to: old.type.promoted)
            if value.type.unsigned { return .init(0 &- value.bits, value.type) }
            guard value.bits != value.type.sign else { throw C.Failure.undefinedC("negation of signed minimum") }
            return try C.signedResult(-value.signed, type: value.type, origins: value.origins)
        case let .binary("<<", left, right):
            guard let a = try constant(left), let b = try constant(right) else { return nil }
            return try C.binary("<<", a, b)
        default: return nil
        }
    }

    /// Direct controls exercise the same folding/equivalence used by Proof;
    /// full captured-row ownership is still required by each calling selector.
    static func assertCMNConstantControls(amount: UInt64, file: StaticString = #filePath, line: UInt = #line) throws {
        let span = C.Span(first: 0, last: 0)
        func literal(_ bits: UInt64, _ type: C.CType) -> C.Expression {
            .init(span: span, node: .literal(.init(bits, type)))
        }
        func complement(_ operand: C.Expression) -> C.Expression {
            .init(span: span, node: .unary("~", operand))
        }
        let u32 = C.CType.u32, mask = u32.mask
        let cast = C.Expression(span: span, node: .cast(u32, literal(amount, .i32)))
        let folded = try XCTUnwrap(constant(complement(cast)), file: file, line: line)
        XCTAssertEqual(folded.type, u32, file: file, line: line)
        XCTAssertEqual(folded.bits, mask - amount, file: file, line: line)
        let narrow = try XCTUnwrap(constant(complement(literal(amount, .init(8, true)))), file: file, line: line)
        XCTAssertEqual(narrow.type, .i32, "uint8_t promotes to signed int BEFORE complement", file: file, line: line)
        XCTAssertEqual(narrow.signed, -Int64(amount) - 1, file: file, line: line)
        let narrowNegative = C.Expression(span: span, node: .unary("-", literal(1, .init(8, true))))
        let nested = try XCTUnwrap(constant(complement(narrowNegative)), file: file, line: line)
        XCTAssertEqual(nested.type, .i32, file: file, line: line)
        XCTAssertEqual(nested.bits, 0, "~(-uint8_t(1)) must promote before BOTH unary operations", file: file, line: line)
        let minimumNegative = C.Expression(span: span, node: .unary("-", literal(C.CType.i32.sign, .i32)))
        XCTAssertThrowsError(try constant(complement(minimumNegative)), file: file, line: line) { error in
            guard case C.Failure.undefinedC = error else {
                return XCTFail("signed-minimum negation must stay undefined: \(error)", file: file, line: line)
            }
        }
        let wide = try XCTUnwrap(constant(complement(literal(amount, .u64))), file: file, line: line)
        XCTAssertEqual(wide.type, .u64, file: file, line: line)
        XCTAssertEqual(wide.bits, UInt64.max - amount, file: file, line: line)
        XCTAssertNil(try constant(complement(.init(span: span, node: .name("w9")))), file: file, line: line)
        XCTAssertNil(try constant(complement(literal(amount, .jpegPointer))), file: file, line: line)

        let owner = Value.definitions([.init(row: 12, register: 9)])
        let foreign = Value.definitions([.init(row: 11, register: 9)])
        let threshold = mask - amount + 1
        let source = Predicate.compare(">=", 32, false, owner, .constant(threshold))
        let emitted = Predicate.compare(">", 32, false, owner, .constant(folded.bits))
        XCTAssertTrue(emitted.equivalent(to: source), file: file, line: line)
        XCTAssertTrue(emitted.inverse.equivalent(to: source.inverse), file: file, line: line)
        XCTAssertFalse(emitted.equivalent(to: source.inverse), "polarity must not be erased", file: file, line: line)
        for wrong in [
            Predicate.compare(">=", 32, false, owner, .constant(folded.bits)),
            .compare(">", 32, false, owner, .constant(threshold)),
            .compare(">", 64, false, owner, .constant(wide.bits)),
            .compare(">", 32, true, owner, .constant(folded.bits)),
            .compare(">", 32, false, foreign, .constant(folded.bits)),
            .compare(">", 32, false, .constant(folded.bits), owner)
        ] {
            XCTAssertFalse(wrong.equivalent(to: source), "reject wrong boundary/width/sign/producer/operand", file: file, line: line)
        }
        XCTAssertFalse(Predicate.compare(">", 32, false, owner, .constant(mask)).equivalent(
            to: .compare(">=", 32, false, owner, .constant(0))), "maximum must not wrap", file: file, line: line)
        for value in [UInt64(0), threshold - 1, threshold, threshold + 1, mask] {
            let carry = value + amount > mask // widened sum is bounded by 2^32 + 7
            let native = try C.binary(">", .init(value, u32), folded)
            XCTAssertEqual(native.bits != 0, carry, "exact CMN W carry boundary", file: file, line: line)
        }
    }

    private struct Binding {
        let pc: Int
        let row: Int
        let name: String
        let value: C.Expression?
        var phiEdge: C.PhiEdgeSource? = nil
    }
    private struct BindingID: Hashable { let pc: Int; let name: String }

    static func require(document: PseudocodeDocument, rows: [InstructionRow], function: MacIRFunction,
                        baseline: String, callRows: [Int], preparedContract: OrdinaryC.Contract? = nil) throws {
        let (candidate, source) = try positive(document: document, rows: rows, function: function,
            baseline: baseline, callRows: callRows, preparedContract: preparedContract)
        try requireRefusalControls(candidate, source: source)
    }
    /// Semantic adapters reuse ownership without replaying these selectors'
    /// changed-input static controls or generating another production document.
    static func requirePositive(document: PseudocodeDocument, rows: [InstructionRow], function: MacIRFunction,
                                baseline: String, callRows: [Int]) throws {
        _ = try positive(document: document, rows: rows, function: function, baseline: baseline, callRows: callRows)
    }
    /// The constructor has already proved the exact one-call text/ABI bridge.
    /// This local derived contract is used only for full-document row ownership;
    /// it cannot be returned to or used by the opaque semantic machine.
    static func requirePositive(typedUpsampler pair: OrdinaryCUpsamplerFixturePair) throws {
        // This alpha transport belongs ONLY to full-text row ownership. Each
        // semantic consumer retains its own original contract construction route.
        let opaque = pair.opaque
        let frozen: C.Contract
        if opaque.function.ssaEnabled {
            let legacy = SSAAlphaEquivalence.legacyFunction(from: opaque.input)
            let original = try C.contract(rows: opaque.rows, function: legacy,
                baseline: opaque.baselineText, callRows: opaque.callRows)
            var alpha = SSAAlphaEquivalence(expected: legacy, actual: opaque.function)
            frozen = try original.alphaEquivalent(to: opaque.document, using: &alpha)
        } else {
            frozen = try C.contract(rows: opaque.rows, function: opaque.function,
                baseline: opaque.baselineText, callRows: opaque.callRows)
        }
        guard let old = frozen.calls[pair.roundRow], old.arguments.count == 2,
              old.arguments[0].register == 0, old.arguments[0].width == 32,
              old.arguments[1].register == 1, old.arguments[1].width == 64 else {
            throw C.Failure.invalidContract("TYPED_UPSAMPLER_BRIDGE: frozen round-call roles changed")
        }
        var calls = frozen.calls
        calls[pair.roundRow] = C.FrozenCall(row: old.row, payload: pair.typedCallPayload,
            target: old.target, resultName: old.resultName, control: old.control,
            arguments: [.init(register: 0, width: 64), old.arguments[1]])
        let ownership = C.Contract(signature: frozen.signature, inputs: frozen.inputs,
            fields: frozen.fields, calls: calls, exterior: frozen.exterior,
            terminalRow: frozen.terminalRow, terminalPayload: frozen.terminalPayload,
            terminalName: frozen.terminalName, returnType: frozen.returnType,
            rowsByAddress: frozen.rowsByAddress, allowedLabels: frozen.allowedLabels,
            memoryEffects: frozen.memoryEffects, helpers: frozen.helpers,
            deadResults: frozen.deadResults, permissions: frozen.permissions,
            noCallUnavailableTerminal: frozen.noCallUnavailableTerminal)
        _ = try positive(document: pair.full.document, rows: pair.full.rows,
            function: pair.full.function, baseline: pair.full.baselineText,
            callRows: pair.full.callRows, preparedContract: ownership,
            opaqueSourceFunction: pair.opaque.function)
    }
    private static func positive(document: PseudocodeDocument, rows: [InstructionRow], function: MacIRFunction,
                                 baseline: String, callRows: [Int], preparedContract: C.Contract? = nil,
                                 opaqueSourceFunction: MacIRFunction? = nil) throws -> (C.Program, L.Source) {
        let contract: C.Contract
        if let preparedContract { contract = preparedContract }
        else { contract = try C.contract(rows: rows, function: function, baseline: baseline, callRows: callRows) }
        let source = try L.source(rows: rows)
        // Validate the printer's provenance against both the persisted phi and
        // the independently decoded edge; it grants no value or effect facts.
        for line in document.lines {
            guard let identity = line.syntheticPhiEdge else { continue }
            guard function.ssaEnabled, line.sourceAddress == nil,
                  let phi = function.phis.first(where: {
                      $0.blockAddress == identity.blockAddress && $0.destination == identity.destination
                  }),
                  phi.incoming.contains(where: { $0.predecessor == identity.predecessor }),
                  let predecessorAddress = identity.machineAddress,
                  let predecessor = contract.rowsByAddress[predecessorAddress],
                  let successor = contract.rowsByAddress[identity.blockAddress],
                  let from = source.blockAtRow[predecessor], let to = source.blockAtRow[successor],
                  source.blocks[from].rows.upperBound - 1 == predecessor,
                  source.blocks[to].rows.lowerBound == successor,
                  source.blocks[from].successors.contains(to) else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: synthetic copy lacks its persisted phi and literal predecessor edge")
            }
        }
        let candidate = try C.Program(lines: C.lines(document), contract: contract)
        // These independent literal parsers also retain the full decoded operand,
        // call and terminal contracts. No current production plan supplies facts.
        if rows.first?.address == 0x33418 {
            _ = try OrdinaryCSkipSourceOracle.Program(rows: rows, function: function)
        } else {
            _ = try RegionalCallOracle.Program(rows: rows, function: opaqueSourceFunction ?? function)
        }
        try Proof(candidate: candidate, source: source).requireComplete()
        return (candidate, source)
    }

    /// Changed-input, static proof controls. All mutants first parse under the
    /// unchanged complete source/call/exterior contract; none earns a numerical
    /// mutation kill and no historical source/candidate scenario is replayed.
    private static func requireRefusalControls(_ candidate: C.Program, source: L.Source) throws {
        let skip = source.rows.first?.address == 0x33418
        let consumer = skip ? 43 : 28, wrongWriter = skip ? 30 : 9
        let conditions = candidate.code.compactMap { instruction -> C.Expression? in
            guard case let .branch(expression, _, _) = instruction.node,
                  (try? candidate.row(at: expression.span)) == consumer else { return nil }
            return expression
        }
        guard conditions.count == 1, let expression = conditions.first,
              case let .binary(_, left, right) = expression.node else {
            throw C.Failure.invalidContract("ROW_OWNERSHIP_CONTROL: missing real native predicate")
        }
        let width = skip ? 64 : 32
        // Unsigned SSA branches explicitly project the original operand width.
        // Extract only an exact-width unsigned name view for choosing mutants;
        // the ownership proof and every wrong-writer/width mutant remain intact.
        let operand: C.Expression
        if case let .cast(type, child) = left.node {
            guard type == C.CType(width, true),
                  let childType = candidate.expressionTypes[child.span],
                  !childType.pointer, childType.width == width else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP_CONTROL: invalid native predicate view")
            }
            operand = child
        } else { operand = left }
        guard case let .name(actualName) = operand.node else {
            throw C.Failure.invalidContract("ROW_OWNERSHIP_CONTROL: missing real native predicate name")
        }
        let alternatives = candidate.code.compactMap { instruction -> String? in
            guard (try? candidate.row(at: instruction.span)) == wrongWriter,
                  case let .assign(lhs, rhs) = instruction.node, lhs.count == 1, rhs.count == 1,
                  case let .name(name) = lhs[0].node else { return nil }
            return name
        }
        guard alternatives.count == 1, let different = alternatives.first, different != actualName else {
            throw C.Failure.invalidContract("ROW_OWNERSHIP_CONTROL: missing independently sourced alternative operand")
        }
        try reject(candidate, source: source, span: right.span,
            replacement: "(uint\(width)_t)(0x4)", reason: "changed omitted-CMP immediate")
        try reject(candidate, source: source, span: left.span,
            replacement: different, reason: "same-width wrong source writer")
        try reject(candidate, source: source, span: left.span,
            replacement: "(uint\(width)_t)((uint\(width / 2)_t)(\(actualName)))",
            reason: "narrowed original comparison snapshot")
        // A43/g: the merged-CMP edge copies are flags-phi copies, which exist only under the SSA lifter.
        if SSAPropertyAssertions.enabled, source.rows.first?.address == 0x3ae18 {
            guard let first = candidate.contract.calls[102]?.resultName,
                  let other = candidate.contract.calls[159]?.resultName else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP_CONTROL: missing retained call results")
            }
            // A33 negatives on the lifted merged-CMP edge copies: swapped and shared call-result operands.
            var operands: [String: (value: C.Expression, comparison: C.Expression, operand: C.Expression)] = [:]
            for instruction in candidate.code {
                guard case let .assign(lhs, rhs) = instruction.node, lhs.count == 1, rhs.count == 1,
                      case let .name(name) = lhs[0].node, name.hasPrefix("flag_"),
                      candidate.phiEdge(at: instruction.span) != nil else { continue }
                let comparison = transportedBooleanComparison(rhs[0], in: candidate) ?? rhs[0]
                guard case let .binary(_, left, _) = comparison.node else { continue }
                var operand = left
                if case let .cast(type, inner) = left.node, type == .u32 { operand = inner }
                if case let .name(operandName) = operand.node, operandName == first || operandName == other {
                    operands[operandName] = (rhs[0], comparison, operand)
                }
            }
            guard let firstSite = operands[first], let otherSite = operands[other] else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP_CONTROL: missing lifted merged-CMP call-result operands")
            }
            let firstEdit = try coherentComparisonEdit(firstSite.value, comparison: firstSite.comparison,
                operand: firstSite.operand, replacement: other, in: candidate)
            let otherEdit = try coherentComparisonEdit(otherSite.value, comparison: otherSite.comparison,
                operand: otherSite.operand, replacement: first, in: candidate)
            try reject(candidate, source: source, edits: [firstEdit, otherEdit],
                reason: "lifted merged CMP operands swapped between edges", expecting: "swapped, shared or foreign|uninitialized candidate snapshot")
            try reject(candidate, source: source, edits: [otherEdit],
                reason: "lifted merged CMP single operand shared by both edges", expecting: "swapped, shared or foreign|uninitialized candidate snapshot")
        }
        // A36 negatives: a sign-extended narrower name in a signed 64-bit compare.
        for instruction in candidate.code {
            guard case let .branch(expression, _, _) = instruction.node,
                  case let .binary(op, left, right) = expression.node, ["<", ">=", ">", "<="].contains(op),
                  case let .name(narrowName) = right.node,
                  let type = candidate.symbols[narrowName]?.type, !type.unsigned, type.width == 32,
                  let row = try? candidate.row(at: expression.span) else { continue }
            func text(_ expression: C.Expression) -> String {
                candidate.tokens[expression.span.first..<expression.span.last].map(\.text).joined(separator: " ")
            }
            let typed = "incorrectly typed operand \(narrowName)"
            let unsignedPartner = typed + "|partner of a narrower name is not signed"
            // Printed-type-only evidence: the machine rows no longer sign-extend.
            var zeroExtending = source.rows
            for (index, original) in zeroExtending.enumerated() where original.mnemonic == "ldrsw" {
                zeroExtending[index] = InstructionRow(address: original.address, bytes: original.bytes, mnemonic: "ldr",
                    operands: original.operands, hasBreakpoint: original.hasBreakpoint, comment: original.comment)
            }
            try reject(candidate, source: source, span: right.span, replacement: narrowName,
                reason: "sign-extended name backed only by its printed type", rows: zeroExtending, expecting: typed)
            // Unsigned condition: equality never grants the extension.
            try reject(candidate, source: source, span: expression.span,
                replacement: "\(text(left)) == \(narrowName)", reason: "sign-extended name under an unsigned condition",
                expecting: unsignedPartner)
            // Unaccepted partner: an unsigned partner makes the usual conversion unsigned.
            try reject(candidate, source: source, span: left.span, replacement: "(uint64_t)(\(text(left)))",
                reason: "sign-extended name with an unsigned partner", expecting: unsignedPartner)
            _ = row
            break
        }
        // A29.121b negative: a flags-phi edge copy carrying a different predicate than its
        // predecessor's own source comparison must be refused.
        // A43/g: flags-phi edge copies exist only under the SSA lifter (flag on).
        if SSAPropertyAssertions.enabled, source.rows.first?.address == 0x3ae18 {
            let edgeCopies = candidate.code.compactMap { instruction -> (C.Expression, C.Expression, C.Expression)? in
                guard case let .assign(lhs, rhs) = instruction.node, lhs.count == 1, rhs.count == 1,
                      case let .name(name) = lhs[0].node, name.hasPrefix("flag_"),
                      candidate.phiEdge(at: instruction.span) != nil else { return nil }
                let comparison = transportedBooleanComparison(rhs[0], in: candidate) ?? rhs[0]
                guard case let .binary(_, _, right) = comparison.node else { return nil }
                return (rhs[0], comparison, right)
            }
            guard let wrong = edgeCopies.first else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP_CONTROL: missing flags-phi edge copy")
            }
            let edit = try coherentComparisonEdit(wrong.0, comparison: wrong.1, operand: wrong.2,
                replacement: "(uint32_t)(0x7)", in: candidate)
            try reject(candidate, source: source, edits: [edit], reason: "flags-phi edge copy with a wrong-predicate operand")
        }
    }
    /// Preserve the existing certificate while changing the same operand in every
    /// repeated comparison. This edits test input only; it grants no proof authority.
    private static func coherentComparisonEdit(_ value: C.Expression, comparison: C.Expression,
                                               operand: C.Expression, replacement: String,
                                               in candidate: C.Program) throws -> (span: C.Span, replacement: String) {
        guard comparison.span.first <= operand.span.first, operand.span.last <= comparison.span.last else {
            throw C.Failure.invalidContract("ROW_OWNERSHIP_CONTROL: operand outside exact comparison")
        }
        let pattern = candidate.tokens[comparison.span.first..<comparison.span.last].map(\.text)
        let replacementTokens = candidate.tokens[comparison.span.first..<operand.span.first].map(\.text)
            + [replacement] + candidate.tokens[operand.span.last..<comparison.span.last].map(\.text)
        let original = candidate.tokens[value.span.first..<value.span.last].map(\.text)
        var output: [String] = [], index = 0, matches = 0
        while index < original.count {
            if !pattern.isEmpty, index + pattern.count <= original.count,
               Array(original[index..<(index + pattern.count)]) == pattern {
                output += replacementTokens; index += pattern.count; matches += 1
            } else { output.append(original[index]); index += 1 }
        }
        let certified = transportedBooleanComparison(value, in: candidate) != nil
        guard matches == (certified ? 3 : 1) else {
            throw C.Failure.invalidContract("ROW_OWNERSHIP_CONTROL: exact comparison copy count changed")
        }
        return (value.span, output.joined(separator: " "))
    }
    private static func reject(_ candidate: C.Program, source: L.Source, span: C.Span,
                               replacement: String, reason: String, rows: [InstructionRow]? = nil,
                               expecting: String? = nil) throws {
        try reject(candidate, source: source, edits: [(span, replacement)], reason: reason, rows: rows, expecting: expecting)
    }
    /// Applies single-line replacements on distinct lines, then requires the proof to refuse the result.
    private static func reject(_ candidate: C.Program, source: L.Source, edits: [(span: C.Span, replacement: String)],
                               reason: String, rows: [InstructionRow]? = nil, expecting: String? = nil) throws {
        var lines = candidate.lines
        for (span, replacement) in edits {
            let first = candidate.tokens[span.first], last = candidate.tokens[span.last - 1]
            guard first.line == last.line, !replacement.contains("\n") else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP_CONTROL: mutation changes source lines")
            }
            let index = first.line - 1, original = candidate.lines[index]
            guard original.envelope == .body, let address = original.source ?? original.phiEdge?.predecessorAddress,
                  let row = candidate.contract.rowsByAddress[address],
                  candidate.contract.calls[row] == nil, candidate.contract.exterior[row] == nil,
                  row != candidate.contract.terminalRow else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP_CONTROL: mutation touches protected payload")
            }
            let offset = candidate.lines.prefix(index).reduce(0) { $0 + $1.text.utf8.count + 1 }
            var bytes = Array(lines[index].text.utf8)
            bytes.replaceSubrange((first.byteOffset - offset)..<(last.byteOffset + last.text.utf8.count - offset),
                                  with: replacement.utf8)
            lines[index] = .init(text: String(decoding: bytes, as: UTF8.self), source: original.source,
                envelope: original.envelope, phiEdge: original.phiEdge)
        }
        let mutant = try C.Program(lines: lines, contract: candidate.contract)
        XCTAssertThrowsError(try Proof(candidate: mutant, source: source, rows: rows).requireComplete(), reason) { error in
            guard case let C.Failure.invalidContract(message) = error else {
                return XCTFail("\(reason): not a source-ownership refusal: \(error)")
            }
            XCTAssertTrue(message.hasPrefix("ROW_OWNERSHIP:"), "\(reason): \(message)")
            // `|` separates alternative genuine refusal reasons (an earlier check may fire first).
            if let expecting {
                XCTAssertTrue(expecting.components(separatedBy: "|").contains { message.contains($0) }, "\(reason): \(message)")
            }
        }
    }

    private final class Proof {
        let candidate: C.Program
        let source: L.Source
        let rows: [InstructionRow]
        var sourcePredecessors: [Int: Set<Int>] = [:]
        var candidatePredecessors: [Int: Set<Int>] = [:]
        var candidateReachable: Set<Int> = []
        var bindings: [String: [Binding]] = [:]
        var rowBindings: [Int: [Binding]] = [:]
        var primary: [BindingID: Definition] = [:]
        var ownedFlags: Set<Int> = []
        var copyOrigins: [BindingID: Set<Definition>] = [:]

        init(candidate: C.Program, source: L.Source, rows overrideRows: [InstructionRow]? = nil) throws {
            self.candidate = candidate; self.source = source; rows = overrideRows ?? source.rows
            for block in source.blocks {
                for row in block.rows where row > block.rows.lowerBound { sourcePredecessors[row] = [row - 1] }
                for successor in block.successors {
                    sourcePredecessors[source.blocks[successor].rows.lowerBound, default: []].insert(block.rows.upperBound - 1)
                }
            }
            var candidateSuccessors: [Int: [Int]] = [:]
            for (pc, instruction) in candidate.code.enumerated() {
                let next: [Int]
                switch instruction.node {
                case let .branch(_, yes, no): next = [yes, no]
                case let .jump(target): next = [target]
                case .returned, .unavailableReturn: next = []
                case .unresolved: throw C.Failure.invalidContract("ROW_OWNERSHIP: unresolved candidate edge")
                default: next = [pc + 1]
                }
                for target in next {
                    guard candidate.code.indices.contains(target) else { throw C.Failure.invalidContract("ROW_OWNERSHIP: candidate falls out") }
                    candidatePredecessors[target, default: []].insert(pc)
                }
                candidateSuccessors[pc] = next
                switch instruction.node {
                case let .assign(left, right):
                    guard left.count == right.count else { throw C.Failure.invalidContract("ROW_OWNERSHIP: mismatched scalar assignment") }
                    let row = try candidate.row(at: instruction.span)
                    for (lhs, rhs) in zip(left, right) {
                        if case let .name(name) = lhs.node {
                            add(.init(pc: pc, row: row, name: name, value: rhs,
                                phiEdge: candidate.phiEdge(at: instruction.span)))
                        }
                    }
                case let .call(row, result, _, _):
                    guard let result else { throw C.Failure.invalidContract("ROW_OWNERSHIP: lost original result") }
                    add(.init(pc: pc, row: row, name: result, value: nil))
                case .update, .declaration(_, .some):
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: unexpected executable declaration/update")
                default: break
                }
            }
            // Keep complete row/binding accounting, but a dead synthetic leave
            // after a goto is not an incoming execution path to a live use.
            guard candidate.code.indices.contains(0) else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: missing candidate entry")
            }
            var pending = [0]
            while let pc = pending.popLast() {
                guard candidateReachable.insert(pc).inserted else { continue }
                pending += candidateSuccessors[pc, default: []]
            }
            for pc in candidate.code.indices {
                candidatePredecessors[pc] = candidatePredecessors[pc, default: []].intersection(candidateReachable)
            }
            var gathered = C.Resolver(contract: candidate.contract, tokens: candidate.tokens)
            try gathered.gather(candidate.root)
            guard !gathered.allExpressions.contains(where: {
                if case .update = $0.node { return true }; return false
            }) else { throw C.Failure.invalidContract("ROW_OWNERSHIP: hidden nested scalar write") }
            for row in rows.indices {
                let writes = try registersWritten(at: row)
                // A copy on an edge must never satisfy a missing machine write.
                let sites = rowBindings[row, default: []].filter { $0.phiEdge == nil }
                guard sites.count >= writes.count else { throw C.Failure.invalidContract("ROW_OWNERSHIP: missing scalar definition at original row \(row)") }
                for (binding, register) in zip(sites, writes) {
                    let id = BindingID(pc: binding.pc, name: binding.name)
                    guard primary.updateValue(.init(row: row, register: register), forKey: id) == nil else {
                        throw C.Failure.invalidContract("ROW_OWNERSHIP: duplicated source definition")
                    }
                }
            }
        }
        private func add(_ binding: Binding) {
            bindings[binding.name, default: []].append(binding)
            rowBindings[binding.row, default: []].append(binding)
        }
        private func parts(_ row: Int) -> [String] {
            rows[row].operands.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        private func register(_ text: String) throws -> (index: Int, width: Int) {
            if text == "sp" { return (31, 64) }
            guard let prefix = text.first, prefix == "w" || prefix == "x",
                  let index = Int(text.dropFirst()), (0...30).contains(index) else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: nonliteral register \(text)")
            }
            return (index, prefix == "w" ? 32 : 64)
        }
        private func registersWritten(at row: Int) throws -> [Int] {
            let op = rows[row].mnemonic, operands = parts(row)
            if op == "bl" || op == "blr" { return [0] }
            if ["cmp", "cmn", "ccmp", "b", "cbz", "cbnz", "ret"].contains(op) || op.hasPrefix("b.") { return [] }
            if ["mov", "add", "sub", "subs", "mul", "sdiv", "msub", "and", "orr", "lsl", "adrp", "cset", "csel"].contains(op) {
                return [try register(operands[0]).index]
            }
            if ["ldr", "ldur", "ldrsw", "ldrb", "ldrh", "ldp", "str", "strb", "stp"].contains(op) {
                let pair = op == "ldp" || op == "stp"
                var result = op.hasPrefix("ld") ? try operands.prefix(pair ? 2 : 1).map { try register($0).index } : []
                // Complete retained exteriors include real pre/post SP updates.
                if rows[row].operands.contains("]!") || rows[row].operands.contains("],") {
                    guard let open = rows[row].operands.firstIndex(of: "[") else { throw C.Failure.invalidContract("ROW_OWNERSHIP: missing memory base") }
                    let tail = rows[row].operands[rows[row].operands.index(after: open)...]
                    let base = String(tail.prefix { $0 != "," && $0 != "]" })
                    result.append(try register(base).index)
                }
                return result
            }
            throw C.Failure.invalidContract("ROW_OWNERSHIP: unclassified original row \(row), \(op)")
        }
        private func isCall(_ row: Int) -> Bool { rows[row].mnemonic == "bl" || rows[row].mnemonic == "blr" }
        private func isFlag(_ row: Int) -> Bool { ["cmp", "cmn", "ccmp"].contains(rows[row].mnemonic) }
        private func writesFlags(_ row: Int) -> Bool { isFlag(row) || rows[row].mnemonic == "subs" }
        private func sourceDefinitions(before row: Int, register: Int, includingRow: Bool = false) throws -> Set<Definition> {
            var pending = includingRow ? [row] : Array(sourcePredecessors[row, default: []])
            var seen: Set<Int> = [], result: Set<Definition> = []
            guard !pending.isEmpty else { throw C.Failure.invalidContract("ROW_OWNERSHIP: unbound original register") }
            while let current = pending.popLast() {
                if !seen.insert(current).inserted { continue }
                if try registersWritten(at: current).contains(register) { result.insert(.init(row: current, register: register)); continue }
                if isCall(current), register < 19 || register == 30 {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: original register killed by opaque call")
                }
                let predecessors = sourcePredecessors[current, default: []]
                guard !predecessors.isEmpty else { throw C.Failure.invalidContract("ROW_OWNERSHIP: original predicate reads entry/unknown register") }
                pending += predecessors
            }
            guard !result.isEmpty else { throw C.Failure.invalidContract("ROW_OWNERSHIP: no original reaching definition") }
            return result
        }
        private func flagWriters(before row: Int) throws -> Set<Int> {
            var pending = Array(sourcePredecessors[row, default: []]), seen: Set<Int> = [], result: Set<Int> = []
            while let current = pending.popLast() {
                if !seen.insert(current).inserted { continue }
                if writesFlags(current) { result.insert(current); continue }
                guard !isCall(current), !sourcePredecessors[current, default: []].isEmpty else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: unknown/clobbered original NZCV")
                }
                pending += sourcePredecessors[current, default: []]
            }
            guard !result.isEmpty else { throw C.Failure.invalidContract("ROW_OWNERSHIP: missing NZCV writer") }
            return result
        }
        private func sourceValue(_ text: String, before row: Int, width: Int) throws -> Value {
            if text.hasPrefix("#") {
                let bits = try RegionalCallOracle.Program.number(text)
                return .constant(bits & C.CType(width, true).mask)
            }
            let operand = try register(text)
            guard operand.width == width else { throw C.Failure.invalidContract("ROW_OWNERSHIP: source compare width mismatch") }
            return .definitions(try sourceDefinitions(before: row, register: operand.index))
        }
        private func merge(_ a: Predicate, _ b: Predicate) throws -> Predicate {
            func value(_ a: Value, _ b: Value) throws -> Value {
                if a == b { return a }
                guard case let .definitions(x) = a, case let .definitions(y) = b,
                      Set(x.union(y).map(\.register)).count == 1 else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: incompatible reaching flag operands")
                }
                return .definitions(x.union(y))
            }
            switch (a, b) {
            case let (.compare(op, width, signed, x, y), .compare(other, otherWidth, otherSigned, z, w)):
                guard op == other, width == otherWidth, signed == otherSigned else { break }
                return .compare(op, width, signed, try value(x, z), try value(y, w))
            case let (.and(x, y), .and(z, w)): return .and(try merge(x, z), try merge(y, w))
            case let (.or(x, y), .or(z, w)): return .or(try merge(x, z), try merge(y, w))
            default: break
            }
            throw C.Failure.invalidContract("ROW_OWNERSHIP: incompatible NZCV merge")
        }
        private func sourcePredicate(before consumer: Int, condition: String) throws -> Predicate {
            let writers = try flagWriters(before: consumer).sorted()
            var result: Predicate?
            for writer in writers {
                let current = try sourcePredicate(writer: writer, condition: condition)
                result = try result.map { try merge($0, current) } ?? current
            }
            guard let result else { throw C.Failure.invalidContract("ROW_OWNERSHIP: absent source condition") }
            return result
        }
        private func sourcePredicate(writer: Int, condition: String) throws -> Predicate {
            ownedFlags.insert(writer)
            let operands = parts(writer), op = rows[writer].mnemonic
            if op == "subs" {
                guard rows.first?.address == 0x33418, writer == 17,
                      operands == ["x8", "x8", "#1"], condition == "eq" || condition == "ne" else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: unreviewed arithmetic flag writer")
                }
                // SUBS retains its printed scalar effect. EQ/NE tests that
                // exact 64-bit result, not the stale pre-decrement register.
                return .compare(condition == "eq" ? "==" : "!=", 64, false,
                    .definitions([.init(row: writer, register: 8)]), .constant(0))
            }
            guard operands.count == (op == "ccmp" ? 4 : 2) else { throw C.Failure.invalidContract("ROW_OWNERSHIP: compare arity") }
            let width = try register(operands[0]).width
            let left = try sourceValue(operands[0], before: writer, width: width)
            let right = try sourceValue(operands[1], before: writer, width: width)
            if op == "ccmp" {
                guard operands[2] == "#0", operands[3] == "eq", condition == "eq" || condition == "ne" else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: unreviewed CCMP predicate")
                }
                // Literal fallback NZCV=0 has Z clear; with EQ guarding the
                // comparison, final equality is exactly prior-EQ AND new-EQ.
                let equal = Predicate.and(try sourcePredicate(before: writer, condition: "eq"),
                    .compare("==", width, false, left, right))
                return condition == "eq" ? equal : equal.inverse
            }
            if op == "cmn" {
                guard condition == "hs", case let .constant(amount) = right, amount != 0 else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: unreviewed CMN condition")
                }
                return .compare(">=", width, false, left, .constant((0 &- amount) & C.CType(width, true).mask))
            }
            guard op == "cmp" else { throw C.Failure.invalidContract("ROW_OWNERSHIP: non-CMP writer") }
            let operators = ["eq": "==", "ne": "!=", "hs": ">=", "lo": "<", "lt": "<", "gt": ">", "le": "<=", "ge": ">=", "hi": ">", "ls": "<="]
            guard let comparison = operators[condition] else { throw C.Failure.invalidContract("ROW_OWNERSHIP: unsupported condition") }
            return .compare(comparison, width, ["lt", "gt", "le", "ge"].contains(condition), left, right)
        }

        private func reachingBindings(_ name: String, before pc: Int) throws -> [Binding] {
            guard candidateReachable.contains(pc) else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: unreachable candidate use \(name)")
            }
            var pending = Array(candidatePredecessors[pc, default: []]), seen: Set<Int> = [], found: [Binding] = []
            while let current = pending.popLast() {
                if !seen.insert(current).inserted { continue }
                let at = bindings[name, default: []].filter { $0.pc == current }
                if !at.isEmpty { found += at; continue }
                guard current != 0, !candidatePredecessors[current, default: []].isEmpty else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: uninitialized candidate snapshot \(name)")
                }
                pending += candidatePredecessors[current, default: []]
            }
            guard !found.isEmpty else { throw C.Failure.invalidContract("ROW_OWNERSHIP: missing candidate definition \(name)") }
            return found
        }
        private func constant(_ expression: C.Expression) throws -> C.Value? {
            try RegionalCallRowOwnership.constant(expression)
        }
        /// A36: every reaching definition is a machine instruction that sign-extends an N-bit value into the
        /// 64-bit register. Read from the original rows only, never from printed types.
        static func signExtends(mnemonic: String, first: String?, register: Int, narrow: Int) -> Bool {
            let extenders = ["ldrsw": 32, "ldrsh": 16, "ldrsb": 8, "sxtw": 32, "sxth": 16, "sxtb": 8]
            return extenders[mnemonic] == narrow && first == "x\(register)"
        }
        private func requireSignExtending(_ origins: Set<Definition>, from narrow: Int, name: String) throws {
            guard !origins.isEmpty, origins.allSatisfy({ definition in
                Self.signExtends(mnemonic: rows[definition.row].mnemonic, first: parts(definition.row).first,
                                 register: definition.register, narrow: narrow)
            }) else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: incorrectly typed operand \(name)")
            }
        }
        private func nativeValue(_ expression: C.Expression, width: Int, before pc: Int,
                                 visited: Set<BindingID> = [], extendSigned: Bool = false) throws -> Value {
            if let literal = try constant(expression) { return .constant(literal.extended & C.CType(width, true).mask) }
            switch expression.node {
            case let .cast(type, child):
                guard type.width == width, !type.pointer,
                      let childType = candidate.expressionTypes[child.span], !childType.pointer,
                      childType.width >= width, type.unsigned || type == childType else {
                    let text = candidate.tokens[expression.span.first..<expression.span.last].map(\.text).joined(separator: " ")
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: predicate width/pointer cast: `\(text)` (cast to \(type), child \(String(describing: candidate.expressionTypes[child.span])))")
                }
                return try nativeValue(child, width: childType.width, before: pc, visited: visited)
            case let .select(_, positive, _) where candidate.representationCasts.contains(expression.span):
                // Already independently checked by the ordinary type resolver as
                // exact unsigned-to-signed bit transport, not a value selection.
                // Unwrap only its certified unsigned bits, never grant arbitrary
                // signed narrowing/reinterpretation casts provenance authority.
                guard case let .cast(signed, normalized) = positive.node,
                      signed == C.CType(width, false),
                      candidate.expressionTypes[normalized.span] == C.CType(width, true) else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: malformed representation transport")
                }
                return try nativeValue(normalized, width: width, before: pc, visited: visited)
            case let .name(name):
                // A36: a signed name narrower than a signed compare is accepted only when the machine rows
                // show every reaching definition sign-extends to the compare width (checked below).
                guard let type = candidate.symbols[name]?.type, !type.pointer,
                      type.width == width || (extendSigned && !type.unsigned && type.width < width && width == 64) else {
                    let declared = candidate.symbols[name]?.type
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: incorrectly typed operand \(name) (declared \(String(describing: declared)), compare width \(width), signed-extension allowed \(extendSigned))")
                }
                var origins: Set<Definition> = []
                for binding in try reachingBindings(name, before: pc) {
                    let id = BindingID(pc: binding.pc, name: binding.name)
                    guard !visited.contains(id) else { throw C.Failure.invalidContract("ROW_OWNERSHIP: cyclic predicate transport") }
                    if let owner = primary[id] { origins.insert(owner); continue }
                    guard let rhs = binding.value,
                          case let .definitions(current) = try nativeValue(rhs, width: type.width, before: binding.pc, visited: visited.union([id])),
                          Set(current.map(\.register)).count == 1, let register = current.first?.register,
                          try sourceDefinitions(before: binding.row, register: register, includingRow: true) == current else {
                        throw C.Failure.invalidContract("ROW_OWNERSHIP: wrong-path/foreign predicate copy at row \(binding.row)")
                    }
                    copyOrigins[id] = current
                    origins.formUnion(current)
                }
                if type.width != width { try requireSignExtending(origins, from: type.width, name: name) }
                return .definitions(origins)
            default:
                let text = candidate.tokens[expression.span.first..<expression.span.last].map(\.text).joined(separator: " ")
                throw C.Failure.invalidContract("ROW_OWNERSHIP: predicate operand is not original snapshot/bit transport: `\(text)`")
            }
        }
        /// A27/A29: a flags-phi variable (`flag_*`) read by a consumer. Exactly one `__edge_*` copy per
        /// incoming predecessor edge, each a native comparison equal to that predecessor's own source
        /// predicate; together the edges' writers are exactly the consumer's reaching flag writers.
        private func flagsPhiVariable(_ expression: C.Expression) -> (name: String, inverted: Bool)? {
            switch expression.node {
            case let .name(name) where name.hasPrefix("flag_"): return (name, false)
            case let .unary("!", child): return flagsPhiVariable(child).map { ($0.name, !$0.inverted) }
            case let .binary(op, left, right) where op == "!=" || op == "==":
                guard let zero = try? constant(right), zero.bits == 0, let inner = flagsPhiVariable(left) else { return nil }
                return (inner.name, op == "==" ? !inner.inverted : inner.inverted)
            default: return nil
            }
        }
        private func consumerPredicate(_ expression: C.Expression, before pc: Int, consumer: Int, condition: String) throws -> Predicate {
            guard let (name, inverted) = flagsPhiVariable(expression) else { return try nativePredicate(expression, before: pc) }
            var predecessors: Set<UInt64> = [], writers: Set<Int> = [], result: Predicate?
            for binding in try reachingBindings(name, before: pc) {
                guard let edge = binding.phiEdge, let value = binding.value,
                      let predecessorAddress = edge.predecessorAddress,
                      predecessors.insert(predecessorAddress).inserted,
                      let predecessorRow = candidate.contract.rowsByAddress[predecessorAddress] else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: flags-phi variable \(name) lacks exactly one edge copy per incoming predecessor")
                }
                let reaching = writesFlags(predecessorRow) ? [predecessorRow] : Array(try flagWriters(before: predecessorRow))
                guard reaching.count == 1, let writer = reaching.first else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: flags-phi incoming edge has no single flag writer")
                }
                let native = try nativePredicate(value, before: binding.pc)
                guard native.equivalent(to: try sourcePredicate(writer: writer, condition: condition)) else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: flags-phi edge copy at 0x\(String(predecessorAddress, radix: 16)) is not that predecessor's source predicate")
                }
                writers.insert(writer)
                result = try result.map { try merge($0, native) } ?? native
            }
            guard let result, writers == (try flagWriters(before: consumer)) else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: flags-phi edges do not cover the consumer's reaching flag writers")
            }
            return inverted ? result.inverse : result
        }
        private func nativePredicate(_ expression: C.Expression, before pc: Int) throws -> Predicate {
            if let comparison = RegionalCallRowOwnership.transportedBooleanComparison(expression, in: candidate) {
                return try nativePredicate(comparison, before: pc)
            }
            if case let .unary("!", child) = expression.node { return try nativePredicate(child, before: pc).inverse }
            guard case let .binary(op, left, right) = expression.node else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: predicate lacks exact comparison")
            }
            if op == "&&" { return .and(try nativePredicate(left, before: pc), try nativePredicate(right, before: pc)) }
            if op == "||" { return .or(try nativePredicate(left, before: pc), try nativePredicate(right, before: pc)) }
            if (op == "==" || op == "!="), try constant(right)?.bits == 0,
               case .binary = left.node, let nested = try? nativePredicate(left, before: pc) {
                return op == "!=" ? nested : nested.inverse
            }
            guard ["==", "!=", "<", ">=", ">", "<="].contains(op),
                  let leftType = candidate.expressionTypes[left.span], let rightType = candidate.expressionTypes[right.span] else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: unsupported native comparison")
            }
            let common = try C.CType.common(leftType, rightType)
            var a = left, b = right, signed = !common.unsigned
            if case let .binary("^", valueA, signA) = left.node,
               case let .binary("^", valueB, signB) = right.node,
               try constant(signA)?.bits == common.sign, try constant(signB)?.bits == common.sign,
               leftType == C.CType(common.width, true), rightType == leftType {
                a = valueA; b = valueB; signed = true
            }
            if op == "==" || op == "!=" { signed = false }
            if case .name = b.node, rightType.width < common.width, !(signed && leftType == C.CType(common.width, false)) {
                let text = candidate.tokens[left.span.first..<left.span.last].map(\.text).joined(separator: " ")
                throw C.Failure.invalidContract("ROW_OWNERSHIP: partner of a narrower name is not signed \(common.width) (op \(op), signed \(signed), left \(leftType), right \(rightType), common \(common)): `\(text)`")
            }
            return .compare(op, common.width, signed,
                try nativeValue(a, width: common.width, before: pc,
                                extendSigned: signed && rightType == C.CType(common.width, false)),
                try nativeValue(b, width: common.width, before: pc,
                                extendSigned: signed && leftType == C.CType(common.width, false)))
        }

        func requireComplete() throws {
            let flagRows = Set(rows.indices.filter(isFlag))
            let forwarder: Set<Int>
            switch rows.first?.address {
            case 0x3ae18: forwarder = [200]
            case 0x3b774: forwarder = [144]
            case 0x33418: forwarder = []
            default: throw C.Failure.invalidContract("ROW_OWNERSHIP: outside the three retained complete call fixtures")
            }
            let allRows = Set(rows.indices), addresses = Set(rows.map(\.address))
            let printedAddresses = Set(candidate.lines.compactMap(\.source))
            guard printedAddresses.isSubset(of: addresses) else { throw C.Failure.invalidContract("ROW_OWNERSHIP: foreign printed source") }
            let copiedControlRows = Set(bindings.values.flatMap { $0 }.compactMap { binding -> Int? in
                let row = binding.row
                guard binding.phiEdge != nil, !forwarder.contains(row) else { return nil }
                let op = rows[row].mnemonic
                return op == "b" || op.hasPrefix("b.") || op == "cbz" || op == "cbnz" ? row : nil
            })
            let printed = Set(printedAddresses.compactMap { candidate.contract.rowsByAddress[$0] })
                .union(copiedControlRows)
            guard printed == allRows.subtracting(flagRows.union(forwarder)) else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: missing/extra row outside exhaustive payload/flag/edge partition")
            }
            let report = try L.analyze(candidate: candidate, source: source)
            try report.requireCompleteTopology()
            guard Set(report.accounts.map(\.origin)) == source.origins else { throw C.Failure.invalidContract("ROW_OWNERSHIP: missing original edge") }
            for row in forwarder {
                guard let block = source.blockAtRow[row], source.blocks[block].rows.count == 1,
                      rows[row].mnemonic == "b", rowBindings[row, default: []].allSatisfy({ $0.phiEdge != nil }),
                      let account = report.accounts.first(where: { $0.origin.row == row }),
                      report.accounts.filter({ $0.origin.row == row }).count == 1,
                      account.origin.role == .unconditional, !account.routeIndices.isEmpty,
                      account.routeIndices.allSatisfy({ report.routes[$0].origins.contains(account.origin) }) else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: omitted B is not a completely owned payload-free forwarder")
                }
            }
            for consumer in rows.indices {
                let mnemonic = rows[consumer].mnemonic
                guard mnemonic.hasPrefix("b.") || mnemonic == "cset" || mnemonic == "csel" else { continue }
                let condition = mnemonic.hasPrefix("b.") ? String(mnemonic.dropFirst(2)) : parts(consumer).last!
                let expected = try sourcePredicate(before: consumer, condition: condition)
                if mnemonic.hasPrefix("b.") {
                    let sites = candidate.code.enumerated().compactMap { pc, instruction -> (Int, C.Expression)? in
                        guard case let .branch(value, _, _) = instruction.node,
                              (try? candidate.row(at: value.span)) == consumer else { return nil }
                        return (pc, value)
                    }
                    guard sites.count == 1, let (pc, expression) = sites.first else { throw C.Failure.invalidContract("ROW_OWNERSHIP: missing/duplicate native branch") }
                    let actual = try consumerPredicate(expression, before: pc, consumer: consumer, condition: condition)
                    guard actual.equivalent(to: expected) || actual.equivalent(to: expected.inverse) else { throw C.Failure.invalidContract("ROW_OWNERSHIP: omitted NZCV operands/width/condition changed at \(consumer)") }
                    var outcomes: Set<Bool> = []
                    for route in report.routes where route.origins.contains(where: { $0.row == consumer }) {
                        let choices = route.choices.filter { $0.pc == pc && $0.expression == expression.span }
                        let origins = route.origins.filter { $0.row == consumer }
                        guard choices.count == 1, let choice = choices.first, origins.count == 1, let origin = origins.first else {
                            throw C.Failure.invalidContract("ROW_OWNERSHIP: predicate not bound to exact edge route")
                        }
                        let sourceTaken = actual.equivalent(to: expected) ? choice.taken : !choice.taken
                        guard origin.role == (sourceTaken ? .taken : .notTaken) else { throw C.Failure.invalidContract("ROW_OWNERSHIP: native condition polarity swapped original successors") }
                        outcomes.insert(choice.taken)
                    }
                    guard outcomes == [false, true] else { throw C.Failure.invalidContract("ROW_OWNERSHIP: incomplete predicate outcomes") }
                } else {
                    guard let binding = rowBindings[consumer]?.first, let rhs = binding.value else { throw C.Failure.invalidContract("ROW_OWNERSHIP: missing source-owned flag consumer") }
                    let expression: C.Expression
                    if mnemonic == "csel" {
                        guard case let .select(condition, _, _) = rhs.node else { throw C.Failure.invalidContract("ROW_OWNERSHIP: CSEL is not a value selection") }
                        expression = condition
                    } else { expression = rhs }
                    let actualPredicate = try consumerPredicate(expression, before: binding.pc, consumer: consumer, condition: condition)
                    guard actualPredicate.equivalent(to: expected) else {
                        throw C.Failure.invalidContract("ROW_OWNERSHIP: CSET/CSEL changed original flag semantics at 0x\(String(rows[consumer].address, radix: 16)) \(mnemonic); native=\(actualPredicate); source=\(expected)")
                    }
                    if try flagWriters(before: consumer).count > 1 {
                        if flagsPhiVariable(expression) != nil {
                            try requireLiftedMergedCallOperands(expression, consumer: consumer, usePC: binding.pc, report: report)
                        } else {
                            try requireMergedCallCopies(consumer: consumer, usePC: binding.pc, report: report)
                        }
                    }
                }
            }
            guard ownedFlags == Set(rows.indices.filter(writesFlags)) else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: a flag definition has no native consumer")
            }
            // Program initialization checks every memory access's row, direction,
            // width and ordinal, exact calls/exteriors/terminal and dead-result
            // authority. Remaining scalar rows must own real scalar definitions;
            // branch rows have the complete literal edge account above.
            for row in rows.indices where !flagRows.contains(row) && !forwarder.contains(row) {
                let op = rows[row].mnemonic
                if candidate.contract.memoryEffects[row] != nil || candidate.contract.calls[row] != nil || row == candidate.contract.terminalRow { continue }
                if op == "b" || op.hasPrefix("b.") || op == "cbz" || op == "cbnz" {
                    guard report.accounts.contains(where: { $0.origin.row == row }) else { throw C.Failure.invalidContract("ROW_OWNERSHIP: unowned original branch") }
                } else {
                    guard !rowBindings[row, default: []].isEmpty, try !registersWritten(at: row).isEmpty else {
                        throw C.Failure.invalidContract("ROW_OWNERSHIP: printed source tag without original scalar effect")
                    }
                }
            }
        }
        /// A33: the A27 lifted form of the merged CMP. Each `__edge_*` copy compares the call result of
        /// THAT edge's own call row; the two operands are distinct names, each defined exactly once by its
        /// call (never a phi/merge or a shared name) and each reaching the join only along its own edge.
        private func requireLiftedMergedCallOperands(_ expression: C.Expression, consumer: Int, usePC: Int,
                                                     report: L.Report) throws {
            guard rows.first?.address == 0x3ae18, consumer == 109, let (name, _) = flagsPhiVariable(expression),
                  try flagWriters(before: consumer) == [104, 161],
                  parts(104) == ["w0", "#0"], parts(161) == ["w0", "#0"],
                  let destination = source.blockAtRow[consumer] else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: unreviewed merged NZCV consumer")
            }
            let callForWriter = [104: 102, 161: 159]
            var operandNames: Set<String> = [], writersSeen: Set<Int> = []
            for binding in try reachingBindings(name, before: usePC) {
                guard let edge = binding.phiEdge, let value = binding.value else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: lifted merged CMP edge copy is not an edge-qualified comparison")
                }
                let comparison = RegionalCallRowOwnership.transportedBooleanComparison(value, in: candidate) ?? value
                guard case let .binary(_, left, _) = comparison.node,
                      let predecessorAddress = edge.predecessorAddress,
                      let predecessorRow = candidate.contract.rowsByAddress[predecessorAddress] else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: lifted merged CMP edge copy is not an edge-qualified comparison")
                }
                var operand = left
                if case let .cast(type, inner) = left.node, type == .u32 { operand = inner }
                guard case let .name(operandName) = operand.node else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: lifted merged CMP operand is not a call-result name")
                }
                let reaching = writesFlags(predecessorRow) ? [predecessorRow] : Array(try flagWriters(before: predecessorRow))
                guard reaching.count == 1, let writer = reaching.first, let callRow = callForWriter[writer],
                      writersSeen.insert(writer).inserted, operandNames.insert(operandName).inserted,
                      try sourceDefinitions(before: writer, register: 0) == [.init(row: callRow, register: 0)],
                      let call = candidate.contract.calls[callRow], call.resultName == operandName else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: lifted merged CMP operand is not its own edge's call result (swapped, shared or foreign)")
                }
                let definitions = try reachingBindings(operandName, before: binding.pc)
                guard definitions.count == 1, definitions.first?.row == callRow, definitions.first?.phiEdge == nil else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: lifted merged CMP operand \(operandName) is a merge or has another definition")
                }
                guard let from = source.blockAtRow[predecessorRow] else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: lifted merged CMP edge has no source block")
                }
                let routes = report.routes.filter { $0.fromBlock == from && $0.toBlock == destination }
                guard routes.count == 1, let route = routes.first,
                      route.executedPCs.filter({ $0 == binding.pc }).count == 1,
                      route.origins.count == 1, route.origins.first?.row == predecessorRow else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: lifted merged CMP copy lacks its exact original incoming edge")
                }
            }
            guard writersSeen == [104, 161] else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: missing merged CMP incoming definition")
            }
        }
        private func requireMergedCallCopies(consumer: Int, usePC: Int, report: L.Report) throws {
            guard rows.first?.address == 0x3ae18, consumer == 109,
                  try flagWriters(before: consumer) == [104, 161],
                  parts(104) == ["w0", "#0"], parts(161) == ["w0", "#0"] else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: unreviewed merged NZCV consumer")
            }
            let expected = [108: 102, 166: 159]
            let copies = copyOrigins.filter { _, origins in origins.contains { $0.row == 102 || $0.row == 159 } }
            guard copies.count == 2, let destination = source.blockAtRow[consumer] else {
                throw C.Failure.invalidContract("ROW_OWNERSHIP: merged CMP needs both edge-qualified call-result copies")
            }
            var copyRows: Set<Int> = []
            for (id, origins) in copies {
                guard let binding = bindings[id.name]?.first(where: { $0.pc == id.pc }),
                      let callRow = expected[binding.row], origins == [.init(row: callRow, register: 0)],
                      let from = source.blockAtRow[binding.row],
                      try reachingBindings(id.name, before: usePC).contains(where: { $0.pc == id.pc }),
                      let call = candidate.contract.calls[callRow], let result = call.resultName,
                      let rhs = binding.value, case let .cast(type, value) = rhs.node, type == .u32,
                      case let .name(name) = value.node, name == result,
                      try reachingBindings(result, before: binding.pc).count == 1,
                      try reachingBindings(result, before: binding.pc).first?.row == callRow else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: merged W0 snapshot is stale, swapped or rewritten")
                }
                if let edge = binding.phiEdge {
                    guard edge.blockAddress == rows[source.blocks[destination].rows.lowerBound].address,
                          edge.predecessorAddress == rows[binding.row].address else {
                        throw C.Failure.invalidContract("ROW_OWNERSHIP: merged W0 copy identifies a different phi edge")
                    }
                }
                let routes = report.routes.filter { $0.fromBlock == from && $0.toBlock == destination }
                guard routes.count == 1, let route = routes.first,
                      route.executedPCs.filter({ $0 == id.pc }).count == 1,
                      route.origins.count == 1, route.origins.first?.row == binding.row,
                      route.origins.first?.role == (binding.row == 108 ? .fallthrough : .unconditional) else {
                    throw C.Failure.invalidContract("ROW_OWNERSHIP: merged W0 copy lacks its exact original incoming edge")
                }
                copyRows.insert(binding.row)
            }
            guard copyRows == Set(expected.keys) else { throw C.Failure.invalidContract("ROW_OWNERSHIP: missing merged CMP incoming definition") }
        }
    }
}

private enum JinitCapturedData {
    static let functionWitness: UInt64 = 0x666c58398e34acec
    static let blocksWitness: UInt64 = 0xa4740efbbc760e49
    // address | exact bytes | original mnemonic | original operands | original comment |
    // independent complete operand envelope FNV | complete MacIRInstruction FNV
    static let sourceRecord = """
    3ae18|fc 6f ba a9|stp|x28, x27, [sp, #-0x60]!||ea093691bfe0ec26|0d48bdb9710b6f4c
    3ae1c|fa 67 01 a9|stp|x26, x25, [sp, #0x10]||456bd70c3f63b976|650f2f7f9ee7a076
    3ae20|f8 5f 02 a9|stp|x24, x23, [sp, #0x20]||b5838a7a65e31b84|e04835ae786f98ac
    3ae24|f6 57 03 a9|stp|x22, x21, [sp, #0x30]||e2e4cb2e957df179|ff802b140c767d3d
    3ae28|f4 4f 04 a9|stp|x20, x19, [sp, #0x40]||aaf1e2af151b4558|8ad127498f4f9cb8
    3ae2c|fd 7b 05 a9|stp|x29, x30, [sp, #0x50]||c21a77ab0bb55618|6c6b763985b9210c
    3ae30|fd 43 01 91|add|x29, sp, #0x50||5f247d1dd4e4be52|59c49f0ba71f300d
    3ae34|f3 03 00 aa|mov|x19, x0||b5a7cfada79f5022|06fe063e0341fc27
    3ae38|08 1c 41 f9|ldr|x8, [x0, #0x238]||df08abc597fe3f8d|1ca996cb8f8c3145
    3ae3c|09 15 40 b9|ldr|w9, [x8, #0x14]||5e0149a117968849|811715e8b58779d6
    3ae40|08 28 41 b9|ldr|w8, [x0, #0x128]||b9503b27410bee31|b38b2e7d3e56892c
    3ae44|09 02 00 34|cbz|w9, 0x000000000003ae84||37c2215f9d752edd|e0ca0ff741fb052e
    3ae48|09 25 00 51|sub|w9, w8, #9||0fbc2016538dcca1|90a06c202e581488
    3ae4c|3f 1d 00 31|cmn|w9, #7||fc637b37818f7aa1|63410c7b83653dc1
    3ae50|02 01 00 54|b.hs|0x000000000003ae70||f43326b72ef0da56|29028085c8831cea
    3ae54|69 02 40 f9|ldr|x9, [x19]||c03128173a42ef6f|31d001ec0cf9deb6
    3ae58|0a 02 80 52|mov|w10, #0x10||02aabb759b072b01|efb3700482aec7b5
    3ae5c|2a 21 05 29|stp|w10, w8, [x9, #0x28]||d9c2154fabee8e04|b73ab6c2e7bacfd0
    3ae60|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|1cf20f03cdee6e9c
    3ae64|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|a328da0315aa80ce
    3ae68|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|690a7df5a527b1de
    3ae6c|00 01 3f d6|blr|x8||d4648694c208727c|2e5587b5dc0de099
    3ae70|68 1e 41 f9|ldr|x8, [x19, #0x238]||53423a7c7ebc02a1|1a369398a2707bdc
    3ae74|08 71 40 b9|ldr|w8, [x8, #0x70]||d209ef724e956942|cdbd6b28523eee09
    3ae78|c8 00 00 34|cbz|w8, 0x000000000003ae90||45edda56c9e96911|ea07c93f3635b974
    3ae7c|74 3e 41 f9|ldr|x20, [x19, #0x278]||8a36e7b34aa38661|9b5d787dcf1b3b09
    3ae80|12 00 00 14|b|0x000000000003aec8||11470e3f5726caa3|16214254485c9349
    3ae84|1f 21 00 71|cmp|w8, #8||96100888ac8b3326|9b245f0c20c9342f
    3ae88|61 fe ff 54|b.ne|0x000000000003ae54||d6242a1b416a28b0|18ec6a16969859ac
    3ae8c|f9 ff ff 17|b|0x000000000003ae70||fb0823a682e6efd4|9b83176941505ef6
    3ae90|68 06 40 f9|ldr|x8, [x19, #8]||aa06f122615f7152|4c5b7cd1507e90ee
    3ae94|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|e5f85b3f44630baa
    3ae98|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|f6ca5f8df9587aa4
    3ae9c|21 00 80 52|mov|w1, #1||2fcba54fa2dba661|20e03745a23f081e
    3aea0|02 26 80 52|mov|w2, #0x130||9190dba258d51c68|7fd66457f764964b
    3aea4|00 01 3f d6|blr|x8||d4648694c208727c|6fd825e40b4f070c
    3aea8|f4 03 00 aa|mov|x20, x0||4c0d0a6a717cb852|857508f99ba1f283
    3aeac|08 00 00 b0|adrp|x8, 0x000000000003b000|Page-relative address|3caf64d1fcda4385|ad3d76d2256f9e2c
    3aeb0|08 e1 05 91|add|x8, x8, #0x178||a7334ad67e5071bc|def8ad43e7980674
    3aeb4|60 3e 01 f9|str|x0, [x19, #0x278]||31bb19ed1e2de3c7|31b1f34953d1bb81
    3aeb8|09 00 00 b0|adrp|x9, 0x000000000003b000|Page-relative address|cd3814ffbd3e2901|2b78f31c19dabd97
    3aebc|29 31 06 91|add|x9, x9, #0x18c||093a0db6e0e9013e|5369c62af44f3300
    3aec0|08 24 00 a9|stp|x8, x9, [x0]||9a9e869d47a56198|dcf7b00a5d74fadb
    3aec4|1f 40 00 b9|str|wzr, [x0, #0x40]||a2bcc67f771f6310|6c614d2bf3f45ada
    3aec8|68 8e 41 b9|ldr|w8, [x19, #0x18c]||57e940e1144ad3b2|7122087ed3221f87
    3aecc|e8 00 00 34|cbz|w8, 0x000000000003aee8||59bceeeb04555800|b348c51492d6d6cf
    3aed0|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|caec16dc918ba9a6
    3aed4|49 03 80 52|mov|w9, #0x1a||39acdfcb3dd4e4b3|5cac6f477f613885
    3aed8|09 29 00 b9|str|w9, [x8, #0x28]||bb4b144c535b7823|a0d40892b096e2e0
    3aedc|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|accbb8dc01874ca0
    3aee0|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|8e95cfcd051a8fc5
    3aee4|00 01 3f d6|blr|x8||d4648694c208727c|8f0957fa31b82f70
    3aee8|68 66 40 b9|ldr|w8, [x19, #0x64]||b3584f08c39b8c81|bc659741aae28222
    3aeec|a8 00 00 34|cbz|w8, 0x000000000003af00||22b76c29569849bf|55384f9e47b43420
    3aef0|68 a2 41 b9|ldr|w8, [x19, #0x1a0]||a9e209a0d780d559|93a128f812007812
    3aef4|1f 05 00 71|cmp|w8, #1||145914abb2da6be4|a05eaca93adec20a
    3aef8|f5 d7 9f 1a|cset|w21, gt||9e29cb2355c56646|37e074ef9b476b18
    3aefc|02 00 00 14|b|0x000000000003af04||cc9fd1e95ce4674e|15cc11cf262addef
    3af00|15 00 80 52|mov|w21, #0||c2d44e58748e8b2d|6e8936268bfbf5b7
    3af04|68 3a 40 b9|ldr|w8, [x19, #0x38]||d19f099e93149f69|1245deeb0f77fedc
    3af08|1f 05 00 71|cmp|w8, #1||145914abb2da6be4|3079a0102444b46e
    3af0c|8b 12 00 54|b.lt|0x000000000003b15c||e5adf95cd798370f|a270f03a46d63110
    3af10|16 00 80 d2|mov|x22, #0||88e72bf935d2cd45|dae86a22af3f32f0
    3af14|97 62 02 91|add|x23, x20, #0x98||22280db0aeedcdfd|42521064076e0f79
    3af18|68 9a 40 f9|ldr|x8, [x19, #0x130]||0f83715daf548161|92a73c86f9979080
    3af1c|98 22 01 91|add|x24, x20, #0x48||d7d0e7a3ac6a945a|019e82c146398239
    3af20|19 d1 00 91|add|x25, x8, #0x34||e73e8613675056fb|215e085a91598538
    3af24|1a 00 00 b0|adrp|x26, 0x000000000003b000|Page-relative address|3bb6a02c5eb31a8a|79f7609f634ee7d6
    3af28|5a 43 0b 91|add|x26, x26, #0x2d0||34c09273e7406414|a558534341c46de9
    3af2c|1b 00 00 b0|adrp|x27, 0x000000000003b000|Page-relative address|729c3aa1ce974ba6|794be60310eb00fe
    3af30|7b 63 0b 91|add|x27, x27, #0x2d8||3d8898a69253036c|3f0b192434e576e7
    3af34|2b 03 5f b8|ldur|w11, [x25, #-0x10]||06a08e06dad4a784|9c386deae066bc6d
    3af38|6c a2 41 b9|ldr|w12, [x19, #0x1a0]||3b03103fc3201668|90a6828d5bd78348
    3af3c|2d a3 7a 29|ldp|w13, w8, [x25, #-0x2c]||7cd5af1109887a82|eb994aebf824347f
    3af40|08 7d 0b 1b|mul|w8, w8, w11||4223f48c7b49a87a|2b37360e25c28298
    3af44|08 0d cc 1a|sdiv|w8, w8, w12||fee3eebc10b1f3d0|5113d3697abc2185
    3af48|6a 9a 41 b9|ldr|w10, [x19, #0x198]||aed607e8298de1d3|fd87e5bb20509da1
    3af4c|69 9e 41 b9|ldr|w9, [x19, #0x19c]||4393b1e5adbebee4|fd32b2a8458f09e8
    3af50|8e 0a 16 8b|add|x14, x20, x22, lsl #2||967b2ef3a85d35e9|f38071d41a56c429
    3af54|c8 f1 00 b9|str|w8, [x14, #0xf0]||9d76135188b96485|e42c5a68c9414824
    3af58|2e 03 40 b9|ldr|w14, [x25]||df96c5c18c73245c|6782fc9901979f3a
    3af5c|2e 04 00 34|cbz|w14, 0x000000000003afe0||e31eec3f776926da|e0abdb2984303ea6
    3af60|6b 7d 0d 1b|mul|w11, w11, w13||35d817d1536719de|9e8822b3fd5058ae
    3af64|6b 0d cc 1a|sdiv|w11, w11, w12||09db4f1ce24a9700|42430c046e2e73b3
    3af68|7f 01 0a 6b|cmp|w11, w10||9b4fa9e49de44480|77d87ef8058abfcf
    3af6c|a1 00 00 54|b.ne|0x000000000003af80||4167125716140b16|ff6ec06e86860c94
    3af70|ec 03 17 aa|mov|x12, x23||5787b7db5592064c|dcbcc323a0a70725
    3af74|e0 03 1b aa|mov|x0, x27||e27c9f46f4f593e2|a14822d4473e9a0c
    3af78|1f 01 09 6b|cmp|w8, w9||c155333d3e6b6dae|cde66973db5d92b8
    3af7c|20 0d 00 54|b.eq|0x000000000003b120||4a3db4032d20051f|c2f3017a783a717e
    3af80|6c 79 1f 53|lsl|w12, w11, #1||43a89db22ccef326|a4600b58e28e063c
    3af84|9f 01 0a 6b|cmp|w12, w10||f986b7becee28f99|31fccf72a0a2921a
    3af88|00 01 49 7a|ccmp|w8, w9, #0, eq||6130615f13e8d308|a80e21ec4c146421
    3af8c|00 03 00 54|b.eq|0x000000000003afec||6761e8680b76a869|1738e5a01889aea4
    3af90|7f 01 0a 6b|cmp|w11, w10||9b4fa9e49de44480|e120c7fbec8afa93
    3af94|0d 79 1f 53|lsl|w13, w8, #1||4690ad92dc38ce0a|6336b81a0cb7d44b
    3af98|a0 01 49 7a|ccmp|w13, w9, #0, eq||6c9e59c4df9a437e|0c0307d3266e845f
    3af9c|ee 17 9f 1a|cset|w14, eq||f1fc5f71f437cf1e|e6b943ef62a5ae78
    3afa0|ce 01 15 0a|and|w14, w14, w21||1cda42160d4400d6|de64057554ceda4e
    3afa4|df 05 00 71|cmp|w14, #1||1bb7163486de7c05|35bee41143d97942
    3afa8|61 04 00 54|b.ne|0x000000000003b034||5dd44a0befba42cd|7cdf23812644234b
    3afac|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|b3e9c6540ccbfa85
    3afb0|37 74 00 94|bl|_jsimd_set_h1v2_fancy_upsample||f7a035611068ccf0|1168a050691e4159
    3afb4|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|4ef308ff1b9cd47d
    3afb8|1f 00 00 71|cmp|w0, #0||e46399aaf7ab5d3e|918352ff33dca1ab
    3afbc|e9 00 00 d0|adrp|x9, 0x0000000000058000|Page-relative address|7170047d526b0e6b|71b058f5ce31bcdc
    3afc0|29 61 03 91|add|x9, x9, #0xd8||f05a54a07d2f56a8|d1e7969731e13c89
    3afc4|0a 00 00 b0|adrp|x10, 0x000000000003b000|Page-relative address|1eed086d0acd6cef|9f5afe6522321e7c
    3afc8|4a d1 0f 91|add|x10, x10, #0x3f4||308e1861df47e992|390e1e4613e20ff0
    3afcc|49 01 89 9a|csel|x9, x10, x9, eq||b51def6a573cc73a|6ac0a612dade507e
    3afd0|09 4d 00 f9|str|x9, [x8, #0x98]||16add3e815690a5f|cd122bb71e218a4e
    3afd4|28 00 80 52|mov|w8, #1||2c096c689aaf13c2|c3583d7f2714c7fb
    3afd8|88 42 00 b9|str|w8, [x20, #0x40]||f00983abac9b4dba|3f2d9d38fcee61ab
    3afdc|43 00 00 14|b|0x000000000003b0e8||955fdc9560d70cea|9d58a87eb7dc0928
    3afe0|ec 03 17 aa|mov|x12, x23||5787b7db5592064c|fb1079d7b769ea14
    3afe4|e0 03 1a aa|mov|x0, x26||beb2ddce8e008012|fb983ccbd1b8e7f7
    3afe8|4e 00 00 14|b|0x000000000003b120||91d97ffabc25ce2a|5fabd51023c9bcb4
    3afec|75 01 00 34|cbz|w21, 0x000000000003b018||3d7a666a393e5bf1|d5f285ecd50f172f
    3aff0|28 83 5f b8|ldur|w8, [x25, #-0x8]||8386d0a0947005f3|6f784a63f062adc3
    3aff4|1f 0d 00 71|cmp|w8, #3||2a772aec24fb2d08|2ac3bfe7eadf1afb
    3aff8|03 01 00 54|b.lo|0x000000000003b018||f505d95974d88600|4e7117608a70eae2
    3affc|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|487e77b8e6c33e86
    3b000|f3 73 00 94|bl|_jsimd_set_h2v1_fancy_upsample||20b4f0c0c5e22d32|66501ad0af84c3dc
    3b004|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|c2795e18b6ca6a91
    3b008|40 06 00 34|cbz|w0, 0x000000000003b0d0||6215255c40ef7bab|ce100c058c1d681e
    3b00c|e9 00 00 b0|adrp|x9, 0x0000000000058000|Page-relative address|d6838f6d37ff1610|3dafb4cc5e529893
    3b010|29 61 00 91|add|x9, x9, #0x18||4435544b43181c36|82df42af797438a4
    3b014|34 00 00 14|b|0x000000000003b0e4||dcd865ce88011962|e77e5c197b80e558
    3b018|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|2da93ba03025a50a
    3b01c|ba 73 00 94|bl|_jsimd_set_h2v1_upsample||d948ccd97cdf701c|b4ed293289d008ef
    3b020|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|958fbb8c1888c02d
    3b024|80 02 00 34|cbz|w0, 0x000000000003b074||8f9e6f9a5f0dbfa1|a34626520555e4be
    3b028|e9 00 00 90|adrp|x9, 0x0000000000057000|Page-relative address|b5884b140bcc71c7|6da1e8e87c4139f1
    3b02c|29 41 3d 91|add|x9, x9, #0xf50||675b80dc2bc4f182|2bc858f5581a08c7
    3b030|2d 00 00 14|b|0x000000000003b0e4||69dd6ed70f7de903|8533ed6ab2f2174a
    3b034|9f 01 0a 6b|cmp|w12, w10||f986b7becee28f99|a11e3e06bd3bcef5
    3b038|a0 01 49 7a|ccmp|w13, w9, #0, eq||6c9e59c4df9a437e|fb847f33e45e8070
    3b03c|20 02 00 54|b.eq|0x000000000003b080||bfdcb4180eb90c6a|7fada47008749002
    3b040|4c 0d cb 1a|sdiv|w12, w10, w11||81427e24a59d5f5c|028373cec92f4e94
    3b044|8a a9 0b 1b|msub|w10, w12, w11, w10||1800267e50f65732|7434b8890d127d58
    3b048|8a 00 00 35|cbnz|w10, 0x000000000003b058||958696f0502b61be|04523fb15d5caff2
    3b04c|2a 0d c8 1a|sdiv|w10, w9, w8||5eb355ba1f3afe44|c9a896a6195a11b9
    3b050|48 a5 08 1b|msub|w8, w10, w8, w9||1f620c519629032a|4db8f75a558a0f09
    3b054|48 07 00 34|cbz|w8, 0x000000000003b13c||3cbffbc6ba7250f4|2ea97bd99f79f158
    3b058|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|0c3e3ccf18c05234
    3b05c|e9 04 80 52|mov|w9, #0x27||51b72ccb3b8c550b|6988c9124c73572c
    3b060|09 29 00 b9|str|w9, [x8, #0x28]||bb4b144c535b7823|0855d21215689f9b
    3b064|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|2e2b8f812db6a12e
    3b068|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|72e667296ec04fe5
    3b06c|00 01 3f d6|blr|x8||d4648694c208727c|b4b63d0b59fe11cd
    3b070|1e 00 00 14|b|0x000000000003b0e8||1a3c98d7de330497|f541b96f3e29e7d8
    3b074|09 00 00 90|adrp|x9, 0x000000000003b000|Page-relative address|2e387c95fb9036d9|43ca59bdde700bb3
    3b078|29 81 0e 91|add|x9, x9, #0x3a0||4d6a0e0e4e5f5000|6ae4a96a4e6e3dc0
    3b07c|1a 00 00 14|b|0x000000000003b0e4||29e964a824e0c606|a493f6bb269deea0
    3b080|b5 01 00 34|cbz|w21, 0x000000000003b0b4||cc03d28398c0caf2|b9e4acd3c51f4f2b
    3b084|28 83 5f b8|ldur|w8, [x25, #-0x8]||8386d0a0947005f3|eb93386d49416961
    3b088|1f 0d 00 71|cmp|w8, #3||2a772aec24fb2d08|8af3d0f7065986c6
    3b08c|43 01 00 54|b.lo|0x000000000003b0b4||e8c91e979613b5b8|32fc309ff9ec42f5
    3b090|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|9e76fbc2debe233c
    3b094|e6 73 00 94|bl|_jsimd_set_h2v2_fancy_upsample||8b3a171054f94921|7c06b8be93ee26a2
    3b098|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|bcbc68d5c89edba8
    3b09c|1f 00 00 71|cmp|w0, #0||e46399aaf7ab5d3e|c05a327e14f9a21b
    3b0a0|e9 00 00 b0|adrp|x9, 0x0000000000058000|Page-relative address|af24d5689c163b63|cae9028f85c219b6
    3b0a4|29 e1 01 91|add|x9, x9, #0x78||2af4ea8013399b50|cd6ca05c9cc8cfaa
    3b0a8|0a 00 00 90|adrp|x10, 0x000000000003b000|Page-relative address|f949a3416e2ae0a9|fc9cd92d58beeb2a
    3b0ac|4a 81 12 91|add|x10, x10, #0x4a0||5eec06c1aaa93576|894d68b7ea7cac30
    3b0b0|c7 ff ff 17|b|0x000000000003afcc||30503746d837be39|51f708a3dab08953
    3b0b4|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|9b9322ab6d5193fa
    3b0b8|ac 73 00 94|bl|_jsimd_set_h2v2_upsample||7b6cda9af539fb9e|a7a0f28995a5fc22
    3b0bc|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|18ad2134fbee21e7
    3b0c0|e0 00 00 34|cbz|w0, 0x000000000003b0dc||42a227c45e8e6ca1|f2d6fca557482f34
    3b0c4|e9 00 00 90|adrp|x9, 0x0000000000057000|Page-relative address|d3005dc2e991b80a|7322693feedfc0e6
    3b0c8|29 d1 3e 91|add|x9, x9, #0xfb4||6f3720566c682f3e|ded4fc5d9e20d090
    3b0cc|06 00 00 14|b|0x000000000003b0e4||0ec73d08ad4cdc14|413d6d340571b04b
    3b0d0|09 00 00 90|adrp|x9, 0x000000000003b000|Page-relative address|f5c81b0a8204a2b5|d48970b5c5b1a2a1
    3b0d4|29 81 0b 91|add|x9, x9, #0x2e0||c5b1cd615738ff52|27a51fe8097c216f
    3b0d8|03 00 00 14|b|0x000000000003b0e4||fa365fecb87d3abb|bc7b308773c2c565
    3b0dc|09 00 00 90|adrp|x9, 0x000000000003b000|Page-relative address|ddd52c1275a39540|3f598ab830641793
    3b0e0|29 41 17 91|add|x9, x9, #0x5d0||72a0eeeba54a2412|276b4ec113b46001
    3b0e4|09 4d 00 f9|str|x9, [x8, #0x98]||16add3e815690a5f|660112540831c016
    3b0e8|68 1e 41 f9|ldr|x8, [x19, #0x238]||53423a7c7ebc02a1|bcf6470a5b33c6ef
    3b0ec|08 71 40 b9|ldr|w8, [x8, #0x70]||d209ef724e956942|e0ec3b753fec6ba3
    3b0f0|a8 01 00 35|cbnz|w8, 0x000000000003b124||3e4fef71bbc6006e|1e25cf92423447cc
    3b0f4|68 06 40 f9|ldr|x8, [x19, #8]||aa06f122615f7152|5316f78d21b2147f
    3b0f8|1c 09 40 f9|ldr|x28, [x8, #0x10]||0361d2c02a3c593b|98962c1f992af016
    3b0fc|60 8a 40 b9|ldr|w0, [x19, #0x88]||58fc5e7860d1b4ca|79bfc83f72bd9bd2
    3b100|61 9a 81 b9|ldrsw|x1, [x19, #0x198]||bc988508738f5d74|b06bdafbad8d6125
    3b104|dd 41 00 94|bl|_jround_up||186ed19b0ca77750|8bf604251d6dc13c
    3b108|e2 03 00 aa|mov|x2, x0||6aac86369e8025c4|a4a75af098cc68d2
    3b10c|63 9e 41 b9|ldr|w3, [x19, #0x19c]||a56ac99260371e7e|5b1eff5d38ea9527
    3b110|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|eddc316b9a86836a
    3b114|21 00 80 52|mov|w1, #1||2fcba54fa2dba661|ac615ab3725878db
    3b118|80 03 3f d6|blr|x28||9e3c57a19b74e67e|577a8a505cb18f9d
    3b11c|ec 03 18 aa|mov|x12, x24||e17f438152fdded2|d071cfaf674b9156
    3b120|80 79 36 f8|str|x0, [x12, x22, lsl #3]||e6a387ea87cbaf94|cf957817ff744289
    3b124|39 83 01 91|add|x25, x25, #0x60||838042d8989b9c1a|ee9d98bef89dcc3c
    3b128|d6 06 00 91|add|x22, x22, #1||760387c1280e9558|2bbe12e30288dfd7
    3b12c|68 3a 80 b9|ldrsw|x8, [x19, #0x38]||01cb3201f0ec64ee|7b4952f2499ee2ab
    3b130|df 02 08 eb|cmp|x22, x8||01972191fc7b1742|10a2354127bb9f82
    3b134|0b f0 ff 54|b.lt|0x000000000003af34||c785cc1c46cd91f2|9bd6df6c1c3d1f76
    3b138|09 00 00 14|b|0x000000000003b15c||29e233797f6b3113|9fe331a7efeafb35
    3b13c|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|62f8f9da59204ec3
    3b140|09 00 00 90|adrp|x9, 0x000000000003b000|Page-relative address|5e8cd342aa741ed7|5a067f11d7162982
    3b144|29 f1 19 91|add|x9, x9, #0x67c||94772d47a41f1d16|b123d532b6e44c81
    3b148|09 4d 00 f9|str|x9, [x8, #0x98]||16add3e815690a5f|4a4ef345e566bcba
    3b14c|88 02 16 8b|add|x8, x20, x22||59b44bd3697d6f5c|cdb933d5709bfd95
    3b150|0c 61 04 39|strb|w12, [x8, #0x118]||10f85510e40c7864|3dd308640e2fddd3
    3b154|0a 89 04 39|strb|w10, [x8, #0x122]||1ca01ad9ae93d501|93e944d4cec7f853
    3b158|e4 ff ff 17|b|0x000000000003b0e8||bd1400935b5d54aa|5a4d35b527b994d4
    3b15c|fd 7b 45 a9|ldp|x29, x30, [sp, #0x50]||51d203dcacd423e6|9352880b23936847
    3b160|f4 4f 44 a9|ldp|x20, x19, [sp, #0x40]||1807fcc4fffc49ca|24ac02af36ec7c47
    3b164|f6 57 43 a9|ldp|x22, x21, [sp, #0x30]||d53cf918c80ecdb5|813164a9a4b8e59b
    3b168|f8 5f 42 a9|ldp|x24, x23, [sp, #0x20]||33d15f561fa36de2|0f7bbd83ca3654a6
    3b16c|fa 67 41 a9|ldp|x26, x25, [sp, #0x10]||641b0efa53c5ea6c|a495bec39d30479e
    3b170|fc 6f c6 a8|ldp|x28, x27, [sp], #0x60||07ef66cf676afb46|e9a2c920d2f310c0
    3b174|c0 03 5f d6|ret|||52dc34e2ac6a9178|1d76250101c5834b
    """
    static let baselineText = """
    void _jinit_upsampler(struct jpeg_decompress_struct * cinfo) {
        // entry 0x000000000003ae18; stack frame 0x60 bytes; calls (*x8), _jsimd_set_h1v2_fancy_upsample, _jsimd_set_h2v1_fancy_upsample, _jsimd_set_h2v1_upsample, _jsimd_set_h2v2_fancy_upsample, _jsimd_set_h2v2_upsample, _jround_up, (*x28)
        *(uint64_t *)(sp_0 + -0x60), *(uint64_t *)((sp_0 + -0x60) + 0x8), sp_1 = x28_0, x27_0, sp_0 - 0x60;
        *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8) = x26_0, x25_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8) = x24_0, x23_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8) = x22_0, x21_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8) = x20_0, x19_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x50), *(uint64_t *)((sp_1 + 0x50) + 0x8) = x29_0, x30_0; // saves register pair
        x29_1 = sp_1 + 0x50;
        x19_1 = cinfo;
        tmp0 = *(cinfo + 0x238);
        tmp1 = *(uint32_t *)(tmp0 + 0x14);
        tmp2 = cinfo->data_precision;
        if (tmp1 == 0x0) goto 0x3ae84; // conditional branch
        tmp3 = tmp2 - 0x9;
        if ((uint32_t)(tmp3) >= (uint32_t)(-0x7)) goto 0x3ae70; // conditional branch
        tmp4 = *(x19_1);
        tmp5 = 0x10;
        *(uint32_t *)(tmp4 + 0x28), *(uint32_t *)((tmp4 + 0x28) + 0x4) = tmp5, tmp2; // saves register pair
        tmp6 = *(x19_1);
        tmp7 = *(tmp6);
        x0_1 = x19_1;
        x0_2 = (*tmp7)(x0_1); // call
        tmp8 = *(x19_1 + 0x238);
        tmp9 = *(uint32_t *)(tmp8 + 0x70);
        if (tmp9 == 0x0) goto 0x3ae90; // conditional branch
        x20_1 = *(x19_1 + 0x278);
        __branch(0x3aec8); // unconditional branch
        __compare(unavailable_w8, 0x8); // sets condition flags
        if (unavailable_w8 != 0x8) goto 0x3ae54; // conditional branch
        __branch(0x3ae70); // unconditional branch
        tmp10 = *(x19_1 + 0x8);
        tmp11 = *(tmp10);
        x0_3 = x19_1;
        w1_1 = 0x1;
        w2_1 = 0x130;
        x0_4 = (*tmp11)(x0_3, w1_1, w2_1); // call
        x20_2 = x0_4;
        tmp12 = __adrp(0x3b000); // Page-relative address
        tmp13 = tmp12 + 0x178;
        *(x19_1 + 0x278) = x0_4;
        tmp14 = __adrp(0x3b000); // Page-relative address
        tmp15 = tmp14 + 0x18c;
        *(uint64_t *)(x0_4), *(uint64_t *)(x0_4 + 0x8) = tmp13, tmp15; // saves register pair
        *(uint32_t *)(x0_4 + 0x40) = 0x0;
        tmp16 = *(uint32_t *)(x19_1 + 0x18c);
        if (tmp16) { // conditional branch
            tmp17 = *(x19_1);
            tmp18 = 0x1a;
            *(uint32_t *)(tmp17 + 0x28) = tmp18;
            tmp19 = *(tmp17);
            x0_5 = x19_1;
            x0_6 = (*tmp19)(x0_5); // call
        }
        tmp20 = *(uint32_t *)(x19_1 + 0x64);
        if (tmp20) { // conditional branch
            tmp21 = *(uint32_t *)(x19_1 + 0x1a0);
            w21_1 = tmp21 > 0x1; // compare to bool
        } else {
            w21_2 = 0x0;
        }
        tmp22 = *(uint32_t *)(x19_1 + 0x38);
        if (tmp22 < 0x1) goto 0x3b15c; // conditional branch
        x22_1 = 0x0;
        x23_1 = unavailable_x20 + 0x98;
        tmp23 = *(x19_1 + 0x130);
        x24_1 = unavailable_x20 + 0x48;
        x25_1 = tmp23 + 0x34;
        x26_1 = __adrp(0x3b000); // Page-relative address
        x26_2 = x26_1 + 0x2d0;
        x27_1 = __adrp(0x3b000); // Page-relative address
        x27_2 = x27_1 + 0x2d8;
        tmp24 = *(uint32_t *)(unavailable_x25 + -0x10);
        tmp25 = *(uint32_t *)(x19_1 + 0x1a0);
        tmp26, tmp27 = *(uint32_t *)(unavailable_x25 + -0x2c), *(uint32_t *)((unavailable_x25 + -0x2c) + 0x4); // restores register pair
        tmp28 = tmp27 * tmp24;
        tmp29 = __a64_sdiv32(tmp28, tmp25);
        tmp30 = *(uint32_t *)(x19_1 + 0x198);
        tmp31 = *(uint32_t *)(x19_1 + 0x19c);
        tmp32 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x2);
        *(uint32_t *)(tmp32 + 0xf0) = tmp29;
        tmp33 = *(uint32_t *)(unavailable_x25);
        if (tmp33 == 0x0) goto 0x3afe0; // conditional branch
        tmp34 = tmp24 * tmp26;
        tmp35 = __a64_sdiv32(tmp34, tmp25);
        if (tmp35 != tmp30) goto 0x3af80; // conditional branch
        tmp36 = x23_1;
        x0_7 = x27_2;
        if (tmp29 == tmp31) goto 0x3b120; // conditional branch
        tmp37 = (uint32_t)(tmp35) << 0x1;
        __compare(tmp37, tmp30); // sets condition flags
        __conditional_compare_eq(tmp29, tmp31, 0x0);
        if ((tmp37 == tmp30) && (tmp29 == tmp31)) goto 0x3afec; // conditional branch
        __compare(tmp35, tmp30); // sets condition flags
        tmp38 = (uint32_t)(tmp29) << 0x1;
        __conditional_compare_eq(tmp38, tmp31, 0x0);
        tmp39 = __unknown(\"cset\", \"w14, eq\");
        tmp40 = tmp39 & unavailable_w21;
        if (tmp40 != 0x1) goto 0x3b034; // conditional branch
        x0_8 = x19_1;
        x0_9 = _jsimd_set_h1v2_fancy_upsample(x0_8); // call
        tmp41 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        __compare((uint32_t)(x0_9), 0x0); // sets condition flags
        tmp42 = __adrp(0x58000); // Page-relative address
        tmp43 = tmp42 + 0xd8;
        tmp44 = __adrp(0x3b000); // Page-relative address
        tmp45 = tmp44 + 0x3f4;
        tmp46 = __unknown(\"csel\", \"x9, x10, x9, eq\");
        *(unavailable_x8 + 0x98) = tmp46;
        tmp47 = 0x1;
        *(uint32_t *)(unavailable_x20 + 0x40) = tmp47;
        __branch(0x3b0e8); // unconditional branch
        tmp48 = x23_1;
        x0_10 = x26_2;
        __branch(0x3b120); // unconditional branch
        if (unavailable_w21 == 0x0) goto 0x3b018; // conditional branch
        tmp49 = *(uint32_t *)(unavailable_x25 + -0x8);
        if ((uint32_t)(tmp49) < (uint32_t)(0x3)) goto 0x3b018; // conditional branch
        x0_11 = x19_1;
        x0_12 = _jsimd_set_h2v1_fancy_upsample(x0_11); // call
        tmp50 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        if ((uint32_t)(x0_12) == 0x0) goto 0x3b0d0; // conditional branch
        tmp51 = __adrp(0x58000); // Page-relative address
        tmp52 = tmp51 + 0x18;
        __branch(0x3b0e4); // unconditional branch
        x0_13 = x19_1;
        x0_14 = _jsimd_set_h2v1_upsample(x0_13); // call
        tmp53 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        if ((uint32_t)(x0_14) == 0x0) goto 0x3b074; // conditional branch
        tmp54 = __adrp(0x57000); // Page-relative address
        tmp55 = tmp54 + 0xf50;
        __branch(0x3b0e4); // unconditional branch
        __compare(unavailable_w12, unavailable_w10); // sets condition flags
        __conditional_compare_eq(unavailable_w13, unavailable_w9, 0x0);
        if ((unavailable_w12 == unavailable_w10) && (unavailable_w13 == unavailable_w9)) goto 0x3b080; // conditional branch
        tmp56 = __a64_sdiv32(unavailable_w10, unavailable_w11);
        tmp57 = unavailable_w10 - (tmp56 * unavailable_w11);
        if (tmp57 != 0x0) goto 0x3b058; // conditional branch
        tmp58 = __a64_sdiv32(unavailable_w9, unavailable_w8);
        tmp59 = unavailable_w9 - (tmp58 * unavailable_w8);
        if (tmp59 == 0x0) goto 0x3b13c; // conditional branch
        tmp60 = *(x19_1);
        tmp61 = 0x27;
        *(uint32_t *)(tmp60 + 0x28) = tmp61;
        tmp62 = *(tmp60);
        x0_15 = x19_1;
        x0_16 = (*tmp62)(x0_15); // call
        __branch(0x3b0e8); // unconditional branch
        tmp63 = __adrp(0x3b000); // Page-relative address
        tmp64 = tmp63 + 0x3a0;
        __branch(0x3b0e4); // unconditional branch
        if (unavailable_w21 == 0x0) goto 0x3b0b4; // conditional branch
        tmp65 = *(uint32_t *)(unavailable_x25 + -0x8);
        if ((uint32_t)(tmp65) < (uint32_t)(0x3)) goto 0x3b0b4; // conditional branch
        x0_17 = x19_1;
        x0_18 = _jsimd_set_h2v2_fancy_upsample(x0_17); // call
        tmp66 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        __compare((uint32_t)(x0_18), 0x0); // sets condition flags
        tmp67 = __adrp(0x58000); // Page-relative address
        tmp68 = tmp67 + 0x78;
        tmp69 = __adrp(0x3b000); // Page-relative address
        tmp70 = tmp69 + 0x4a0;
        __branch(0x3afcc); // unconditional branch
        x0_19 = x19_1;
        x0_20 = _jsimd_set_h2v2_upsample(x0_19); // call
        tmp71 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        if ((uint32_t)(x0_20) == 0x0) goto 0x3b0dc; // conditional branch
        tmp72 = __adrp(0x57000); // Page-relative address
        tmp73 = tmp72 + 0xfb4;
        __branch(0x3b0e4); // unconditional branch
        tmp74 = __adrp(0x3b000); // Page-relative address
        tmp75 = tmp74 + 0x2e0;
        __branch(0x3b0e4); // unconditional branch
        tmp76 = __adrp(0x3b000); // Page-relative address
        tmp77 = tmp76 + 0x5d0;
        *(unavailable_x8 + 0x98) = unavailable_x9;
        tmp78 = *(x19_1 + 0x238);
        tmp79 = *(uint32_t *)(tmp78 + 0x70);
        if (!tmp79) { // conditional branch
            tmp80 = *(x19_1 + 0x8);
            x28_1 = *(tmp80 + 0x10);
            w0_1 = *(uint32_t *)(x19_1 + 0x88);
            x1_1 = *(int32_t *)(x19_1 + 0x198);
            x0_21 = _jround_up(w0_1, x1_1); // call
            x2_1 = x0_21;
            w3_1 = *(uint32_t *)(x19_1 + 0x19c);
            x0_22 = x19_1;
            w1_2 = 0x1;
            x0_23 = (*x28_1)(x0_22, w1_2, x2_1, w3_1); // call
            tmp81 = x24_1;
            *(unavailable_x12 + (unavailable_x22 << 0x3)) = unavailable_x0;
        }
        x25_2 = unavailable_x25 + 0x60;
        x22_2 = unavailable_x22 + 0x1;
        tmp82 = *(int32_t *)(x19_1 + 0x38);
        if (x22_2 < tmp82) goto 0x3af34; // conditional branch
        __branch(0x3b15c); // unconditional branch
        tmp83 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp84 = __adrp(0x3b000); // Page-relative address
        tmp85 = tmp84 + 0x67c;
        *(tmp83 + 0x98) = tmp85;
        tmp86 = unavailable_x20 + unavailable_x22;
        *(uint8_t *)(tmp86 + 0x118) = unavailable_w12;
        *(uint8_t *)(tmp86 + 0x122) = unavailable_w10;
        __branch(0x3b0e8); // unconditional branch
        x29_2, x30_1 = *(uint64_t *)(sp_1 + 0x50), *(uint64_t *)((sp_1 + 0x50) + 0x8); // restores register pair
        x20_3, x19_2 = *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8); // restores register pair
        x22_3, x21_1 = *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8); // restores register pair
        x24_2, x23_2 = *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8); // restores register pair
        x26_3, x25_3 = *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8); // restores register pair
        x28_2, x27_3, sp_2 = *(uint64_t *)(sp_1), *(uint64_t *)(sp_1 + 0x8), sp_1 + 0x60;
        return; // return
    }
    """
    // Current flat output; differs from the capture above by the single renderer's flat-if form.
    static let flatText = """
    void _jinit_upsampler(struct jpeg_decompress_struct * cinfo) {
        // entry 0x000000000003ae18; stack frame 0x60 bytes; calls (*x8), _jsimd_set_h1v2_fancy_upsample, _jsimd_set_h2v1_fancy_upsample, _jsimd_set_h2v1_upsample, _jsimd_set_h2v2_fancy_upsample, _jsimd_set_h2v2_upsample, _jround_up, (*x28)
        *(uint64_t *)(sp_0 + -0x60), *(uint64_t *)((sp_0 + -0x60) + 0x8), sp_1 = x28_0, x27_0, sp_0 - 0x60;
        *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8) = x26_0, x25_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8) = x24_0, x23_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8) = x22_0, x21_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8) = x20_0, x19_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x50), *(uint64_t *)((sp_1 + 0x50) + 0x8) = x29_0, x30_0; // saves register pair
        x29_1 = sp_1 + 0x50;
        x19_1 = cinfo;
        tmp0 = *(uint64_t *)((uint8_t *)(cinfo) + 0x238);
        tmp1 = *(uint32_t *)(tmp0 + 0x14);
        tmp2 = cinfo->data_precision;
        if (tmp1 == 0x0) goto loc_3ae84; // conditional branch
        tmp3 = tmp2 - 0x9;
        if ((uint32_t)(tmp3) >= (uint32_t)(-0x7)) goto loc_3ae70; // conditional branch
        loc_3ae54:
        tmp4 = *(x19_1);
        tmp5 = 0x10;
        *(uint32_t *)(tmp4 + 0x28), *(uint32_t *)((tmp4 + 0x28) + 0x4) = tmp5, tmp2; // saves register pair
        tmp6 = *(x19_1);
        tmp7 = *(tmp6);
        x0_1 = x19_1;
        x0_2 = (*tmp7)(x0_1); // call
        loc_3ae70:
        tmp8 = *(x19_1 + 0x238);
        tmp9 = *(uint32_t *)(tmp8 + 0x70);
        if (tmp9 == 0x0) goto loc_3ae90; // conditional branch
        x20_1 = *(x19_1 + 0x278);
        goto loc_3aec8; // unconditional branch
        loc_3ae84:
        __compare(unavailable_w8, 0x8); // sets condition flags
        if (unavailable_w8 != 0x8) goto loc_3ae54; // conditional branch
        goto loc_3ae70; // unconditional branch
        loc_3ae90:
        tmp10 = *(x19_1 + 0x8);
        tmp11 = *(tmp10);
        x0_3 = x19_1;
        w1_1 = 0x1;
        w2_1 = 0x130;
        x0_4 = (*tmp11)(x0_3, w1_1, w2_1); // call
        x20_2 = x0_4;
        tmp12 = __adrp(0x3b000); // Page-relative address
        tmp13 = tmp12 + 0x178;
        *(x19_1 + 0x278) = x0_4;
        tmp14 = __adrp(0x3b000); // Page-relative address
        tmp15 = tmp14 + 0x18c;
        *(uint64_t *)(x0_4), *(uint64_t *)(x0_4 + 0x8) = tmp13, tmp15; // saves register pair
        *(uint32_t *)(x0_4 + 0x40) = 0x0;
        loc_3aec8:
        tmp16 = *(uint32_t *)(x19_1 + 0x18c);
        if (tmp16 == 0x0) goto loc_3aee8; // conditional branch
        tmp17 = *(x19_1);
        tmp18 = 0x1a;
        *(uint32_t *)(tmp17 + 0x28) = tmp18;
        tmp19 = *(tmp17);
        x0_5 = x19_1;
        x0_6 = (*tmp19)(x0_5); // call
        loc_3aee8:
        tmp20 = *(uint32_t *)(x19_1 + 0x64);
        if (tmp20 == 0x0) goto loc_3af00; // conditional branch
        tmp21 = *(uint32_t *)(x19_1 + 0x1a0);
        w21_1 = tmp21 > 0x1; // compare to bool
        goto loc_3af04; // unconditional branch
        loc_3af00:
        w21_2 = 0x0;
        loc_3af04:
        tmp22 = *(uint32_t *)(x19_1 + 0x38);
        if (tmp22 < 0x1) goto loc_3b15c; // conditional branch
        x22_1 = 0x0;
        x23_1 = unavailable_x20 + 0x98;
        tmp23 = *(x19_1 + 0x130);
        x24_1 = unavailable_x20 + 0x48;
        x25_1 = tmp23 + 0x34;
        x26_1 = __adrp(0x3b000); // Page-relative address
        x26_2 = x26_1 + 0x2d0;
        x27_1 = __adrp(0x3b000); // Page-relative address
        x27_2 = x27_1 + 0x2d8;
        loc_3af34:
        tmp24 = *(uint32_t *)(unavailable_x25 + -0x10);
        tmp25 = *(uint32_t *)(x19_1 + 0x1a0);
        tmp26, tmp27 = *(uint32_t *)(unavailable_x25 + -0x2c), *(uint32_t *)((unavailable_x25 + -0x2c) + 0x4); // restores register pair
        tmp28 = tmp27 * tmp24;
        tmp29 = __a64_sdiv32(tmp28, tmp25);
        tmp30 = *(uint32_t *)(x19_1 + 0x198);
        tmp31 = *(uint32_t *)(x19_1 + 0x19c);
        tmp32 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x2);
        *(uint32_t *)(tmp32 + 0xf0) = tmp29;
        tmp33 = *(uint32_t *)(unavailable_x25);
        if (tmp33 == 0x0) goto loc_3afe0; // conditional branch
        tmp34 = tmp24 * tmp26;
        tmp35 = __a64_sdiv32(tmp34, tmp25);
        if (tmp35 != tmp30) goto loc_3af80; // conditional branch
        tmp36 = x23_1;
        x0_7 = x27_2;
        if (tmp29 == tmp31) goto loc_3b120; // conditional branch
        loc_3af80:
        tmp37 = (uint32_t)(tmp35) << 0x1;
        __compare(tmp37, tmp30); // sets condition flags
        __conditional_compare_eq(tmp29, tmp31, 0x0);
        if ((tmp37 == tmp30) && (tmp29 == tmp31)) goto loc_3afec; // conditional branch
        __compare(tmp35, tmp30); // sets condition flags
        tmp38 = (uint32_t)(tmp29) << 0x1;
        __conditional_compare_eq(tmp38, tmp31, 0x0);
        tmp39 = __unknown(\"cset\", \"w14, eq\");
        tmp40 = tmp39 & unavailable_w21;
        if (tmp40 != 0x1) goto loc_3b034; // conditional branch
        x0_8 = x19_1;
        x0_9 = _jsimd_set_h1v2_fancy_upsample(x0_8); // call
        tmp41 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        __compare((uint32_t)(x0_9), 0x0); // sets condition flags
        tmp42 = __adrp(0x58000); // Page-relative address
        tmp43 = tmp42 + 0xd8;
        tmp44 = __adrp(0x3b000); // Page-relative address
        tmp45 = tmp44 + 0x3f4;
        loc_3afcc:
        tmp46 = __unknown(\"csel\", \"x9, x10, x9, eq\");
        *(unavailable_x8 + 0x98) = tmp46;
        tmp47 = 0x1;
        *(uint32_t *)(unavailable_x20 + 0x40) = tmp47;
        goto loc_3b0e8; // unconditional branch
        loc_3afe0:
        tmp48 = x23_1;
        x0_10 = x26_2;
        goto loc_3b120; // unconditional branch
        loc_3afec:
        if (unavailable_w21 == 0x0) goto loc_3b018; // conditional branch
        tmp49 = *(uint32_t *)(unavailable_x25 + -0x8);
        if ((uint32_t)(tmp49) < (uint32_t)(0x3)) goto loc_3b018; // conditional branch
        x0_11 = x19_1;
        x0_12 = _jsimd_set_h2v1_fancy_upsample(x0_11); // call
        tmp50 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        if ((uint32_t)(x0_12) == 0x0) goto loc_3b0d0; // conditional branch
        tmp51 = __adrp(0x58000); // Page-relative address
        tmp52 = tmp51 + 0x18;
        goto loc_3b0e4; // unconditional branch
        loc_3b018:
        x0_13 = x19_1;
        x0_14 = _jsimd_set_h2v1_upsample(x0_13); // call
        tmp53 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        if ((uint32_t)(x0_14) == 0x0) goto loc_3b074; // conditional branch
        tmp54 = __adrp(0x57000); // Page-relative address
        tmp55 = tmp54 + 0xf50;
        goto loc_3b0e4; // unconditional branch
        loc_3b034:
        __compare(unavailable_w12, unavailable_w10); // sets condition flags
        __conditional_compare_eq(unavailable_w13, unavailable_w9, 0x0);
        if ((unavailable_w12 == unavailable_w10) && (unavailable_w13 == unavailable_w9)) goto loc_3b080; // conditional branch
        tmp56 = __a64_sdiv32(unavailable_w10, unavailable_w11);
        tmp57 = unavailable_w10 - (tmp56 * unavailable_w11);
        if (tmp57 != 0x0) goto loc_3b058; // conditional branch
        tmp58 = __a64_sdiv32(unavailable_w9, unavailable_w8);
        tmp59 = unavailable_w9 - (tmp58 * unavailable_w8);
        if (tmp59 == 0x0) goto loc_3b13c; // conditional branch
        loc_3b058:
        tmp60 = *(x19_1);
        tmp61 = 0x27;
        *(uint32_t *)(tmp60 + 0x28) = tmp61;
        tmp62 = *(tmp60);
        x0_15 = x19_1;
        x0_16 = (*tmp62)(x0_15); // call
        goto loc_3b0e8; // unconditional branch
        loc_3b074:
        tmp63 = __adrp(0x3b000); // Page-relative address
        tmp64 = tmp63 + 0x3a0;
        goto loc_3b0e4; // unconditional branch
        loc_3b080:
        if (unavailable_w21 == 0x0) goto loc_3b0b4; // conditional branch
        tmp65 = *(uint32_t *)(unavailable_x25 + -0x8);
        if ((uint32_t)(tmp65) < (uint32_t)(0x3)) goto loc_3b0b4; // conditional branch
        x0_17 = x19_1;
        x0_18 = _jsimd_set_h2v2_fancy_upsample(x0_17); // call
        tmp66 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        __compare((uint32_t)(x0_18), 0x0); // sets condition flags
        tmp67 = __adrp(0x58000); // Page-relative address
        tmp68 = tmp67 + 0x78;
        tmp69 = __adrp(0x3b000); // Page-relative address
        tmp70 = tmp69 + 0x4a0;
        goto loc_3afcc; // unconditional branch
        loc_3b0b4:
        x0_19 = x19_1;
        x0_20 = _jsimd_set_h2v2_upsample(x0_19); // call
        tmp71 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        if ((uint32_t)(x0_20) == 0x0) goto loc_3b0dc; // conditional branch
        tmp72 = __adrp(0x57000); // Page-relative address
        tmp73 = tmp72 + 0xfb4;
        goto loc_3b0e4; // unconditional branch
        loc_3b0d0:
        tmp74 = __adrp(0x3b000); // Page-relative address
        tmp75 = tmp74 + 0x2e0;
        goto loc_3b0e4; // unconditional branch
        loc_3b0dc:
        tmp76 = __adrp(0x3b000); // Page-relative address
        tmp77 = tmp76 + 0x5d0;
        loc_3b0e4:
        *(unavailable_x8 + 0x98) = unavailable_x9;
        loc_3b0e8:
        tmp78 = *(x19_1 + 0x238);
        tmp79 = *(uint32_t *)(tmp78 + 0x70);
        if (tmp79 != 0x0) goto loc_3b124; // conditional branch
        tmp80 = *(x19_1 + 0x8);
        x28_1 = *(tmp80 + 0x10);
        w0_1 = *(uint32_t *)(x19_1 + 0x88);
        x1_1 = *(int32_t *)(x19_1 + 0x198);
        x0_21 = _jround_up(w0_1, x1_1); // call
        x2_1 = x0_21;
        w3_1 = *(uint32_t *)(x19_1 + 0x19c);
        x0_22 = x19_1;
        w1_2 = 0x1;
        x0_23 = (*x28_1)(x0_22, w1_2, x2_1, w3_1); // call
        tmp81 = x24_1;
        loc_3b120:
        *(unavailable_x12 + (unavailable_x22 << 0x3)) = unavailable_x0;
        loc_3b124:
        x25_2 = unavailable_x25 + 0x60;
        x22_2 = unavailable_x22 + 0x1;
        tmp82 = *(int32_t *)(x19_1 + 0x38);
        if (x22_2 < tmp82) goto loc_3af34; // conditional branch
        goto loc_3b15c; // unconditional branch
        loc_3b13c:
        tmp83 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp84 = __adrp(0x3b000); // Page-relative address
        tmp85 = tmp84 + 0x67c;
        *(tmp83 + 0x98) = tmp85;
        tmp86 = unavailable_x20 + unavailable_x22;
        *(uint8_t *)(tmp86 + 0x118) = unavailable_w12;
        *(uint8_t *)(tmp86 + 0x122) = unavailable_w10;
        goto loc_3b0e8; // unconditional branch
        loc_3b15c:
        x29_2, x30_1 = *(uint64_t *)(sp_1 + 0x50), *(uint64_t *)((sp_1 + 0x50) + 0x8); // restores register pair
        x20_3, x19_2 = *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8); // restores register pair
        x22_3, x21_1 = *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8); // restores register pair
        x24_2, x23_2 = *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8); // restores register pair
        x26_3, x25_3 = *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8); // restores register pair
        x28_2, x27_3, sp_2 = *(uint64_t *)(sp_1), *(uint64_t *)(sp_1 + 0x8), sp_1 + 0x60;
        return; // return
    }
    """
}

private enum J12InitCapturedData {
    static let functionWitness: UInt64 = 0xf5d7af5b87362db6
    static let blocksWitness: UInt64 = 0x2ec95f3164db8c69
    // address | exact bytes | original mnemonic | original operands | original comment |
    // independent complete operand envelope FNV | complete MacIRInstruction FNV
    static let sourceRecord = """
    3b774|fc 6f ba a9|stp|x28, x27, [sp, #-0x60]!||ea093691bfe0ec26|b9ce0182a8d88e96
    3b778|fa 67 01 a9|stp|x26, x25, [sp, #0x10]||456bd70c3f63b976|217e780c7346bb15
    3b77c|f8 5f 02 a9|stp|x24, x23, [sp, #0x20]||b5838a7a65e31b84|9e297370439581e6
    3b780|f6 57 03 a9|stp|x22, x21, [sp, #0x30]||e2e4cb2e957df179|8da0bab2e8ed2f5b
    3b784|f4 4f 04 a9|stp|x20, x19, [sp, #0x40]||aaf1e2af151b4558|86bedd0cfc5b18d1
    3b788|fd 7b 05 a9|stp|x29, x30, [sp, #0x50]||c21a77ab0bb55618|b08c5dd6ef96e3fe
    3b78c|fd 43 01 91|add|x29, sp, #0x50||5f247d1dd4e4be52|b3908711ca298699
    3b790|f3 03 00 aa|mov|x19, x0||b5a7cfada79f5022|8fe7792a8a4c3011
    3b794|08 1c 41 f9|ldr|x8, [x0, #0x238]||df08abc597fe3f8d|b41e6cc284654e3b
    3b798|09 15 40 b9|ldr|w9, [x8, #0x14]||5e0149a117968849|f2afe6d434a939a3
    3b79c|08 28 41 b9|ldr|w8, [x0, #0x128]||b9503b27410bee31|d64fc9b315566922
    3b7a0|09 02 00 34|cbz|w9, 0x000000000003b7e0||a02ed5a4af1061e2|690fa6fe767af316
    3b7a4|09 35 00 51|sub|w9, w8, #0xd||144f3ced68244db3|47ae0f0d95bbd09b
    3b7a8|3f 11 00 31|cmn|w9, #4||4712751820d19103|a2fdd37dd4e3b732
    3b7ac|02 01 00 54|b.hs|0x000000000003b7cc||f86fdffab3bd1ee9|91d0f30f5ad0bceb
    3b7b0|69 02 40 f9|ldr|x9, [x19]||c03128173a42ef6f|3aab521b927c14c0
    3b7b4|0a 02 80 52|mov|w10, #0x10||02aabb759b072b01|67f74664b55e3706
    3b7b8|2a 21 05 29|stp|w10, w8, [x9, #0x28]||d9c2154fabee8e04|0da10b082e54d45a
    3b7bc|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|6b27696076bfa33a
    3b7c0|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|a352d0462493d909
    3b7c4|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|8f13f36ddeeea0c0
    3b7c8|00 01 3f d6|blr|x8||d4648694c208727c|31b0ef42a0c3d2d6
    3b7cc|68 1e 41 f9|ldr|x8, [x19, #0x238]||53423a7c7ebc02a1|fee9554c30ff27a2
    3b7d0|08 71 40 b9|ldr|w8, [x8, #0x70]||d209ef724e956942|c4ed7c68b151bd6f
    3b7d4|c8 00 00 34|cbz|w8, 0x000000000003b7ec||0d58726751d88e94|eec722b9eaa68afc
    3b7d8|74 3e 41 f9|ldr|x20, [x19, #0x278]||8a36e7b34aa38661|b8d95773cca42f27
    3b7dc|13 00 00 14|b|0x000000000003b828||c0b52d0c06ec393c|2523e67fc9e0ed6a
    3b7e0|1f 31 00 71|cmp|w8, #0xc||08cb9aa7f40c686e|072dd74d6f301c34
    3b7e4|61 fe ff 54|b.ne|0x000000000003b7b0||662e55ff4408e0d6|cab3ff6b52e227df
    3b7e8|f9 ff ff 17|b|0x000000000003b7cc||546329851b7465bb|3f98b234c71b77d0
    3b7ec|68 06 40 f9|ldr|x8, [x19, #8]||aa06f122615f7152|303259329cfa265c
    3b7f0|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|c77c15d6213cbc84
    3b7f4|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|9c57cba236d9ac26
    3b7f8|21 00 80 52|mov|w1, #1||2fcba54fa2dba661|60ab81d30bbccd3c
    3b7fc|02 26 80 52|mov|w2, #0x130||9190dba258d51c68|25b55cb7afc8c24c
    3b800|00 01 3f d6|blr|x8||d4648694c208727c|652b2387663d082a
    3b804|f4 03 00 aa|mov|x20, x0||4c0d0a6a717cb852|3b191c88ed2bab56
    3b808|08 00 00 90|adrp|x8, 0x000000000003b000|Page-relative address|69a2271305d18892|1d7133e24adbcbc2
    3b80c|08 91 29 91|add|x8, x8, #0xa64||4e342dd310a584d0|576bf9894ae3d656
    3b810|60 3e 01 f9|str|x0, [x19, #0x278]||31bb19ed1e2de3c7|0f3b0af15f1d8b32
    3b814|08 00 00 f9|str|x8, [x0]||da65fb7e618a6cc6|7090c330dcd38eb8
    3b818|08 00 00 90|adrp|x8, 0x000000000003b000|Page-relative address|c0daa5244ba725f9|18edc216f839e288
    3b81c|08 e1 29 91|add|x8, x8, #0xa78||8893ea4d6b0bdd54|a29f2a16b5ade953
    3b820|08 08 00 f9|str|x8, [x0, #0x10]||1c6087633e42b2b5|dd5654c074c52b6d
    3b824|1f 40 00 b9|str|wzr, [x0, #0x40]||a2bcc67f771f6310|f08365cba71faa84
    3b828|68 8e 41 b9|ldr|w8, [x19, #0x18c]||57e940e1144ad3b2|3d70af1eae7f5cf1
    3b82c|e8 00 00 34|cbz|w8, 0x000000000003b848||00a0bcedc658ad52|b1a93ec9c4a1756b
    3b830|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|a7df27e76116ecd9
    3b834|49 03 80 52|mov|w9, #0x1a||39acdfcb3dd4e4b3|85808eee546af3a7
    3b838|09 29 00 b9|str|w9, [x8, #0x28]||bb4b144c535b7823|f403e521b05005bb
    3b83c|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|e11f4b737abca465
    3b840|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|d5b5f8c2eedf620f
    3b844|00 01 3f d6|blr|x8||d4648694c208727c|b97fa8fbb1234d90
    3b848|68 66 40 b9|ldr|w8, [x19, #0x64]||b3584f08c39b8c81|195bdfddc050b214
    3b84c|a8 00 00 34|cbz|w8, 0x000000000003b860||c03d6a50573371e5|78210d84780b90c8
    3b850|68 a2 41 b9|ldr|w8, [x19, #0x1a0]||a9e209a0d780d559|82aea65e811d3f98
    3b854|1f 05 00 71|cmp|w8, #1||145914abb2da6be4|4ec65d025d247290
    3b858|f5 d7 9f 1a|cset|w21, gt||9e29cb2355c56646|966b91876abb36aa
    3b85c|02 00 00 14|b|0x000000000003b864||3183dc9ea9ba92d0|0b0d1c136d8cb9a1
    3b860|15 00 80 52|mov|w21, #0||c2d44e58748e8b2d|eb2a1134de42413d
    3b864|68 3a 40 b9|ldr|w8, [x19, #0x38]||d19f099e93149f69|70fb3609b23b0646
    3b868|1f 05 00 71|cmp|w8, #1||145914abb2da6be4|a2b34531c4ead66c
    3b86c|eb 0e 00 54|b.lt|0x000000000003ba48||aa506535806a2b42|305f5da10de8eb9e
    3b870|16 00 80 d2|mov|x22, #0||88e72bf935d2cd45|d8e7b1476d309b6a
    3b874|97 62 02 91|add|x23, x20, #0x98||22280db0aeedcdfd|429f073e9f911df7
    3b878|68 9a 40 f9|ldr|x8, [x19, #0x130]||0f83715daf548161|6bbddc5b74490eac
    3b87c|98 22 01 91|add|x24, x20, #0x48||d7d0e7a3ac6a945a|40d70ca32b80e3ff
    3b880|19 d1 00 91|add|x25, x8, #0x34||e73e8613675056fb|8e15d42886f61004
    3b884|1a 00 00 90|adrp|x26, 0x000000000003b000|Page-relative address|3dc08b2c72662437|a52a0df4f4c75c8c
    3b888|5a f3 2e 91|add|x26, x26, #0xbbc||0c4eb1847fb29e0e|e9cdf8c7019bc5f4
    3b88c|1b 00 00 90|adrp|x27, 0x000000000003b000|Page-relative address|4f8ac34de8f92abb|8d8a69049c8f4af2
    3b890|7b 13 2f 91|add|x27, x27, #0xbc4||ed6b048b895026e2|384b93278a170500
    3b894|2b 03 5f b8|ldur|w11, [x25, #-0x10]||06a08e06dad4a784|cfdfe410785ad5a7
    3b898|6c a2 41 b9|ldr|w12, [x19, #0x1a0]||3b03103fc3201668|f78c7fa4f677b3ce
    3b89c|2d a3 7a 29|ldp|w13, w8, [x25, #-0x2c]||7cd5af1109887a82|974cc52529c4a879
    3b8a0|08 7d 0b 1b|mul|w8, w8, w11||4223f48c7b49a87a|60c5132530be2e6a
    3b8a4|08 0d cc 1a|sdiv|w8, w8, w12||fee3eebc10b1f3d0|1855e47293ca5bd7
    3b8a8|6a 9a 41 b9|ldr|w10, [x19, #0x198]||aed607e8298de1d3|3e41d63b7ddd0d9f
    3b8ac|69 9e 41 b9|ldr|w9, [x19, #0x19c]||4393b1e5adbebee4|442333e4626f490a
    3b8b0|8e 0a 16 8b|add|x14, x20, x22, lsl #2||967b2ef3a85d35e9|6625ecc8eb0d8743
    3b8b4|c8 f1 00 b9|str|w8, [x14, #0xf0]||9d76135188b96485|e7504cff7fd2487e
    3b8b8|2e 03 40 b9|ldr|w14, [x25]||df96c5c18c73245c|efbb96713698e4c0
    3b8bc|6e 03 00 34|cbz|w14, 0x000000000003b928||c7ce7454ecd93949|f158f1f9cdb1805e
    3b8c0|6b 7d 0d 1b|mul|w11, w11, w13||35d817d1536719de|aaa566a7164ac7dc
    3b8c4|6b 0d cc 1a|sdiv|w11, w11, w12||09db4f1ce24a9700|e6130302d5ddcd25
    3b8c8|7f 01 0a 6b|cmp|w11, w10||9b4fa9e49de44480|9ab5b6abf7328f15
    3b8cc|a1 00 00 54|b.ne|0x000000000003b8e0||2face6c2d2c2a014|ab8ad74ec9aef960
    3b8d0|ec 03 17 aa|mov|x12, x23||5787b7db5592064c|b03490b3431d1f83
    3b8d4|e0 03 1b aa|mov|x0, x27||e27c9f46f4f593e2|90bb1bd9d502b75e
    3b8d8|1f 01 09 6b|cmp|w8, w9||c155333d3e6b6dae|b1b25618d3a041ba
    3b8dc|00 06 00 54|b.eq|0x000000000003b99c||85bc6177b87c6c3f|1d805c106b8f0ffc
    3b8e0|6c 79 1f 53|lsl|w12, w11, #1||43a89db22ccef326|37e99cdf25ce50a2
    3b8e4|9f 01 0a 6b|cmp|w12, w10||f986b7becee28f99|362ad67e0e5296d4
    3b8e8|00 01 49 7a|ccmp|w8, w9, #0, eq||6130615f13e8d308|5a0ccb3a8fdb1b3f
    3b8ec|40 02 00 54|b.eq|0x000000000003b934||9abbc7fce5405ce9|38ee1725fff99c31
    3b8f0|7f 01 0a 6b|cmp|w11, w10||9b4fa9e49de44480|18e8241846b57479
    3b8f4|0d 79 1f 53|lsl|w13, w8, #1||4690ad92dc38ce0a|82569d2ab622dff1
    3b8f8|a0 01 49 7a|ccmp|w13, w9, #0, eq||6c9e59c4df9a437e|5c85d8debc5d204d
    3b8fc|ee 17 9f 1a|cset|w14, eq||f1fc5f71f437cf1e|8fe20ddf3368d3c6
    3b900|ce 01 15 0a|and|w14, w14, w21||1cda42160d4400d6|a518165f8507ba80
    3b904|df 05 00 71|cmp|w14, #1||1bb7163486de7c05|c07edfbc8efac4c8
    3b908|81 05 00 54|b.ne|0x000000000003b9b8||758a1b788905bb04|091b70d6c73a83db
    3b90c|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|9b18405840b59eb5
    3b910|09 00 00 90|adrp|x9, 0x000000000003b000|Page-relative address|12db1061d42572c9|38b9ddd79ce94f23
    3b914|29 81 33 91|add|x9, x9, #0xce0||da61ba315d179e66|773f68bb07cdeb0b
    3b918|09 4d 00 f9|str|x9, [x8, #0x98]||16add3e815690a5f|edf263246e0aaaee
    3b91c|28 00 80 52|mov|w8, #1||2c096c689aaf13c2|7dc096dab1303a35
    3b920|88 42 00 b9|str|w8, [x20, #0x40]||f00983abac9b4dba|924a8402da5ca0f0
    3b924|10 00 00 14|b|0x000000000003b964||e05605a18f7aef3f|99de09b7148b6d44
    3b928|ec 03 17 aa|mov|x12, x23||5787b7db5592064c|0103e9792cc7fec6
    3b92c|e0 03 1a aa|mov|x0, x26||beb2ddce8e008012|7ef06bd5ceb197cd
    3b930|1b 00 00 14|b|0x000000000003b99c||17af3488d7c5fb97|c1eb0d17cc9cb8e7
    3b934|15 01 00 34|cbz|w21, 0x000000000003b954||fdbcc7af4966490d|1b30c61a7c306c04
    3b938|28 83 5f b8|ldur|w8, [x25, #-0x8]||8386d0a0947005f3|6e37a110c8c006d6
    3b93c|1f 0d 00 71|cmp|w8, #3||2a772aec24fb2d08|6e5b1d31b81d0df1
    3b940|a3 00 00 54|b.lo|0x000000000003b954||de00f80986c6b882|e050c85580d5e621
    3b944|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|11083a5e41c187a7
    3b948|09 00 00 90|adrp|x9, 0x000000000003b000|Page-relative address|44e6c45561ba7e6d|c56b1f6b4a471061
    3b94c|29 31 2f 91|add|x9, x9, #0xbcc||40951d53f419f70a|0b19cdcc5cb423ee
    3b950|04 00 00 14|b|0x000000000003b960||20a952868e4f0a8a|b4b3b16f88fb38ec
    3b954|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|1c7e7a972de5cca6
    3b958|09 00 00 90|adrp|x9, 0x000000000003b000|Page-relative address|018b2f90e548bfa2|a580a89ce2f3d48f
    3b95c|29 31 32 91|add|x9, x9, #0xc8c||2dbdb4ae95cf8dae|b1e30104e7136993
    3b960|09 4d 00 f9|str|x9, [x8, #0x98]||16add3e815690a5f|6dedf54727565b77
    3b964|68 1e 41 f9|ldr|x8, [x19, #0x238]||53423a7c7ebc02a1|33801bfb324d75cd
    3b968|08 71 40 b9|ldr|w8, [x8, #0x70]||d209ef724e956942|048096d8ef0eb1fa
    3b96c|a8 01 00 35|cbnz|w8, 0x000000000003b9a0||7358a852180468ff|ef4d4fd3a34323ec
    3b970|68 06 40 f9|ldr|x8, [x19, #8]||aa06f122615f7152|8d3cf012c9c2f8a8
    3b974|1c 09 40 f9|ldr|x28, [x8, #0x10]||0361d2c02a3c593b|e6b4add5044899b4
    3b978|60 8a 40 b9|ldr|w0, [x19, #0x88]||58fc5e7860d1b4ca|094440b0695cfbdb
    3b97c|61 9a 81 b9|ldrsw|x1, [x19, #0x198]||bc988508738f5d74|05f70b534a2a73d6
    3b980|be 3f 00 94|bl|_jround_up||1667ad2227d24ab0|b9869fb0b4b3a156
    3b984|e2 03 00 aa|mov|x2, x0||6aac86369e8025c4|70732aeb0e5c3ab5
    3b988|63 9e 41 b9|ldr|w3, [x19, #0x19c]||a56ac99260371e7e|0b93b9ea169f48e7
    3b98c|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|c9f0ef9c9f94bce5
    3b990|21 00 80 52|mov|w1, #1||2fcba54fa2dba661|f478a241b9c6eee1
    3b994|80 03 3f d6|blr|x28||9e3c57a19b74e67e|51e879e39359043d
    3b998|ec 03 18 aa|mov|x12, x24||e17f438152fdded2|012dc46927c77feb
    3b99c|80 79 36 f8|str|x0, [x12, x22, lsl #3]||e6a387ea87cbaf94|9dbb9fbf40a7b89c
    3b9a0|39 83 01 91|add|x25, x25, #0x60||838042d8989b9c1a|f55017c190ecc028
    3b9a4|d6 06 00 91|add|x22, x22, #1||760387c1280e9558|3c49d32efc4d4265
    3b9a8|68 3a 80 b9|ldrsw|x8, [x19, #0x38]||01cb3201f0ec64ee|1af29b2b2814f556
    3b9ac|df 02 08 eb|cmp|x22, x8||01972191fc7b1742|287f5d3bf249f552
    3b9b0|2b f7 ff 54|b.lt|0x000000000003b894||35146bbd34c8f99c|3b29c4088da44a4a
    3b9b4|25 00 00 14|b|0x000000000003ba48||38e1e7ef17438b73|3851071dd22b33a1
    3b9b8|9f 01 0a 6b|cmp|w12, w10||f986b7becee28f99|09b7ac5eb37d5dbd
    3b9bc|a0 01 49 7a|ccmp|w13, w9, #0, eq||6c9e59c4df9a437e|1c5fc4f5e78cb1bf
    3b9c0|c0 01 00 54|b.eq|0x000000000003b9f8||472bf54247ca9fb4|4126446b0d0957ef
    3b9c4|4c 0d cb 1a|sdiv|w12, w10, w11||81427e24a59d5f5c|9a392386e350c91b
    3b9c8|8a a9 0b 1b|msub|w10, w12, w11, w10||1800267e50f65732|1a6d2aa50009aa1c
    3b9cc|8a 00 00 35|cbnz|w10, 0x000000000003b9dc||2f5c7fcafb4522cb|11e47d4dc78044b2
    3b9d0|2a 0d c8 1a|sdiv|w10, w9, w8||5eb355ba1f3afe44|c576082c287f29eb
    3b9d4|48 a5 08 1b|msub|w8, w10, w8, w9||1f620c519629032a|86a2963b95ee539b
    3b9d8|88 02 00 34|cbz|w8, 0x000000000003ba28||82ea46c37b366752|fba087f7fee7ad5f
    3b9dc|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|ba6462af1a147228
    3b9e0|e9 04 80 52|mov|w9, #0x27||51b72ccb3b8c550b|5da1edbda8eb37a9
    3b9e4|09 29 00 b9|str|w9, [x8, #0x28]||bb4b144c535b7823|0840cb4694613ce5
    3b9e8|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|9d7b427bc719e460
    3b9ec|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|3c73a988802af386
    3b9f0|00 01 3f d6|blr|x8||d4648694c208727c|787a837d8faef93c
    3b9f4|dc ff ff 17|b|0x000000000003b964||848b23bc1b325cd2|f7730f04a57a4c17
    3b9f8|15 01 00 34|cbz|w21, 0x000000000003ba18||fa3df268f60bda7e|37e6e2f02f22260c
    3b9fc|28 83 5f b8|ldur|w8, [x25, #-0x8]||8386d0a0947005f3|2b8920d176025b52
    3ba00|1f 0d 00 71|cmp|w8, #3||2a772aec24fb2d08|56cebcb70ef0f3d0
    3ba04|a3 00 00 54|b.lo|0x000000000003ba18||616f705e969096c9|acc44420e8c29b7e
    3ba08|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|194ca23bf252f7b0
    3ba0c|09 00 00 90|adrp|x9, 0x000000000003b000|Page-relative address|2292cafbfa3a4942|d999ed8e15f93019
    3ba10|29 f1 35 91|add|x9, x9, #0xd7c||72cec317b66098f2|6b85842aa5cf303d
    3ba14|c1 ff ff 17|b|0x000000000003b918||fae1200e06d2a5b7|20b3cae53394e234
    3ba18|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|9edb1274768f6d3a
    3ba1c|09 00 00 90|adrp|x9, 0x000000000003b000|Page-relative address|d2771422a379fdc8|331af9e76595fefe
    3ba20|29 e1 3a 91|add|x9, x9, #0xeb8||6c7b3c401f643a62|7c0005e473af4afb
    3ba24|cf ff ff 17|b|0x000000000003b960||8dcd8b8af2ef66f8|aa11500dbd1f42ec
    3ba28|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|3c456980453e08bb
    3ba2c|09 00 00 90|adrp|x9, 0x000000000003b000|Page-relative address|7961a59cbdf183d1|1544abb6570b2fa8
    3ba30|29 61 3d 91|add|x9, x9, #0xf58||d0c460eb64fe4642|c487afdccf4374b3
    3ba34|09 4d 00 f9|str|x9, [x8, #0x98]||16add3e815690a5f|76affbe89391ff62
    3ba38|88 02 16 8b|add|x8, x20, x22||59b44bd3697d6f5c|f743b394ae4fe690
    3ba3c|0c 61 04 39|strb|w12, [x8, #0x118]||10f85510e40c7864|f941f71b1290ae1e
    3ba40|0a 89 04 39|strb|w10, [x8, #0x122]||1ca01ad9ae93d501|6fca6e26ab40f535
    3ba44|c8 ff ff 17|b|0x000000000003b964||bdc7d91b00bb2211|967d68249970264c
    3ba48|fd 7b 45 a9|ldp|x29, x30, [sp, #0x50]||51d203dcacd423e6|c1b9c95b588e5517
    3ba4c|f4 4f 44 a9|ldp|x20, x19, [sp, #0x40]||1807fcc4fffc49ca|1b20ce0ee8845c4b
    3ba50|f6 57 43 a9|ldp|x22, x21, [sp, #0x30]||d53cf918c80ecdb5|d94a5089f5bf332e
    3ba54|f8 5f 42 a9|ldp|x24, x23, [sp, #0x20]||33d15f561fa36de2|4edf5e73720fc49f
    3ba58|fa 67 41 a9|ldp|x26, x25, [sp, #0x10]||641b0efa53c5ea6c|82a3753d4245aba4
    3ba5c|fc 6f c6 a8|ldp|x28, x27, [sp], #0x60||07ef66cf676afb46|ecf57318d8e40241
    3ba60|c0 03 5f d6|ret|||52dc34e2ac6a9178|522186c00a8d0047
    """
    static let baselineText = """
    void _j12init_upsampler(struct jpeg_decompress_struct * cinfo) {
        // entry 0x000000000003b774; stack frame 0x60 bytes; calls (*x8), _jround_up, (*x28)
        *(uint64_t *)(sp_0 + -0x60), *(uint64_t *)((sp_0 + -0x60) + 0x8), sp_1 = x28_0, x27_0, sp_0 - 0x60;
        *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8) = x26_0, x25_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8) = x24_0, x23_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8) = x22_0, x21_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8) = x20_0, x19_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x50), *(uint64_t *)((sp_1 + 0x50) + 0x8) = x29_0, x30_0; // saves register pair
        x29_1 = sp_1 + 0x50;
        x19_1 = cinfo;
        tmp0 = *(cinfo + 0x238);
        tmp1 = *(uint32_t *)(tmp0 + 0x14);
        tmp2 = cinfo->data_precision;
        if (tmp1 == 0x0) goto 0x3b7e0; // conditional branch
        tmp3 = tmp2 - 0xd;
        if ((uint32_t)(tmp3) >= (uint32_t)(-0x4)) goto 0x3b7cc; // conditional branch
        tmp4 = *(x19_1);
        tmp5 = 0x10;
        *(uint32_t *)(tmp4 + 0x28), *(uint32_t *)((tmp4 + 0x28) + 0x4) = tmp5, tmp2; // saves register pair
        tmp6 = *(x19_1);
        tmp7 = *(tmp6);
        x0_1 = x19_1;
        x0_2 = (*tmp7)(x0_1); // call
        tmp8 = *(x19_1 + 0x238);
        tmp9 = *(uint32_t *)(tmp8 + 0x70);
        if (tmp9 == 0x0) goto 0x3b7ec; // conditional branch
        x20_1 = *(x19_1 + 0x278);
        __branch(0x3b828); // unconditional branch
        __compare(unavailable_w8, 0xc); // sets condition flags
        if (unavailable_w8 != 0xc) goto 0x3b7b0; // conditional branch
        __branch(0x3b7cc); // unconditional branch
        tmp10 = *(x19_1 + 0x8);
        tmp11 = *(tmp10);
        x0_3 = x19_1;
        w1_1 = 0x1;
        w2_1 = 0x130;
        x0_4 = (*tmp11)(x0_3, w1_1, w2_1); // call
        x20_2 = x0_4;
        tmp12 = __adrp(0x3b000); // Page-relative address
        tmp13 = tmp12 + 0xa64;
        *(x19_1 + 0x278) = x0_4;
        *(x0_4) = tmp13;
        tmp14 = __adrp(0x3b000); // Page-relative address
        tmp15 = tmp14 + 0xa78;
        *(x0_4 + 0x10) = tmp15;
        *(uint32_t *)(x0_4 + 0x40) = 0x0;
        tmp16 = *(uint32_t *)(x19_1 + 0x18c);
        if (tmp16) { // conditional branch
            tmp17 = *(x19_1);
            tmp18 = 0x1a;
            *(uint32_t *)(tmp17 + 0x28) = tmp18;
            tmp19 = *(tmp17);
            x0_5 = x19_1;
            x0_6 = (*tmp19)(x0_5); // call
        }
        tmp20 = *(uint32_t *)(x19_1 + 0x64);
        if (tmp20) { // conditional branch
            tmp21 = *(uint32_t *)(x19_1 + 0x1a0);
            w21_1 = tmp21 > 0x1; // compare to bool
        } else {
            w21_2 = 0x0;
        }
        tmp22 = *(uint32_t *)(x19_1 + 0x38);
        if (tmp22 < 0x1) goto 0x3ba48; // conditional branch
        x22_1 = 0x0;
        x23_1 = unavailable_x20 + 0x98;
        tmp23 = *(x19_1 + 0x130);
        x24_1 = unavailable_x20 + 0x48;
        x25_1 = tmp23 + 0x34;
        x26_1 = __adrp(0x3b000); // Page-relative address
        x26_2 = x26_1 + 0xbbc;
        x27_1 = __adrp(0x3b000); // Page-relative address
        x27_2 = x27_1 + 0xbc4;
        tmp24 = *(uint32_t *)(unavailable_x25 + -0x10);
        tmp25 = *(uint32_t *)(x19_1 + 0x1a0);
        tmp26, tmp27 = *(uint32_t *)(unavailable_x25 + -0x2c), *(uint32_t *)((unavailable_x25 + -0x2c) + 0x4); // restores register pair
        tmp28 = tmp27 * tmp24;
        tmp29 = __a64_sdiv32(tmp28, tmp25);
        tmp30 = *(uint32_t *)(x19_1 + 0x198);
        tmp31 = *(uint32_t *)(x19_1 + 0x19c);
        tmp32 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x2);
        *(uint32_t *)(tmp32 + 0xf0) = tmp29;
        tmp33 = *(uint32_t *)(unavailable_x25);
        if (tmp33 == 0x0) goto 0x3b928; // conditional branch
        tmp34 = tmp24 * tmp26;
        tmp35 = __a64_sdiv32(tmp34, tmp25);
        if (tmp35 != tmp30) goto 0x3b8e0; // conditional branch
        tmp36 = x23_1;
        x0_7 = x27_2;
        if (tmp29 == tmp31) goto 0x3b99c; // conditional branch
        tmp37 = (uint32_t)(tmp35) << 0x1;
        __compare(tmp37, tmp30); // sets condition flags
        __conditional_compare_eq(tmp29, tmp31, 0x0);
        if ((tmp37 == tmp30) && (tmp29 == tmp31)) goto 0x3b934; // conditional branch
        __compare(tmp35, tmp30); // sets condition flags
        tmp38 = (uint32_t)(tmp29) << 0x1;
        __conditional_compare_eq(tmp38, tmp31, 0x0);
        tmp39 = __unknown(\"cset\", \"w14, eq\");
        tmp40 = tmp39 & unavailable_w21;
        if (tmp40 != 0x1) goto 0x3b9b8; // conditional branch
        tmp41 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp42 = __adrp(0x3b000); // Page-relative address
        tmp43 = tmp42 + 0xce0;
        *(unavailable_x8 + 0x98) = unavailable_x9;
        tmp44 = 0x1;
        *(uint32_t *)(unavailable_x20 + 0x40) = tmp44;
        __branch(0x3b964); // unconditional branch
        tmp45 = x23_1;
        x0_8 = x26_2;
        __branch(0x3b99c); // unconditional branch
        if (unavailable_w21 == 0x0) goto 0x3b954; // conditional branch
        tmp46 = *(uint32_t *)(unavailable_x25 + -0x8);
        if ((uint32_t)(tmp46) < (uint32_t)(0x3)) goto 0x3b954; // conditional branch
        tmp47 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp48 = __adrp(0x3b000); // Page-relative address
        tmp49 = tmp48 + 0xbcc;
        __branch(0x3b960); // unconditional branch
        tmp50 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp51 = __adrp(0x3b000); // Page-relative address
        tmp52 = tmp51 + 0xc8c;
        *(unavailable_x8 + 0x98) = unavailable_x9;
        tmp53 = *(x19_1 + 0x238);
        tmp54 = *(uint32_t *)(tmp53 + 0x70);
        if (!tmp54) { // conditional branch
            tmp55 = *(x19_1 + 0x8);
            x28_1 = *(tmp55 + 0x10);
            w0_1 = *(uint32_t *)(x19_1 + 0x88);
            x1_1 = *(int32_t *)(x19_1 + 0x198);
            x0_9 = _jround_up(w0_1, x1_1); // call
            x2_1 = x0_9;
            w3_1 = *(uint32_t *)(x19_1 + 0x19c);
            x0_10 = x19_1;
            w1_2 = 0x1;
            x0_11 = (*x28_1)(x0_10, w1_2, x2_1, w3_1); // call
            tmp56 = x24_1;
            *(unavailable_x12 + (unavailable_x22 << 0x3)) = unavailable_x0;
        }
        x25_2 = unavailable_x25 + 0x60;
        x22_2 = unavailable_x22 + 0x1;
        tmp57 = *(int32_t *)(x19_1 + 0x38);
        if (x22_2 < tmp57) goto 0x3b894; // conditional branch
        __branch(0x3ba48); // unconditional branch
        __compare(unavailable_w12, unavailable_w10); // sets condition flags
        __conditional_compare_eq(unavailable_w13, unavailable_w9, 0x0);
        if ((unavailable_w12 == unavailable_w10) && (unavailable_w13 == unavailable_w9)) goto 0x3b9f8; // conditional branch
        tmp58 = __a64_sdiv32(unavailable_w10, unavailable_w11);
        tmp59 = unavailable_w10 - (tmp58 * unavailable_w11);
        if (tmp59 != 0x0) goto 0x3b9dc; // conditional branch
        tmp60 = __a64_sdiv32(unavailable_w9, unavailable_w8);
        tmp61 = unavailable_w9 - (tmp60 * unavailable_w8);
        if (tmp61 == 0x0) goto 0x3ba28; // conditional branch
        tmp62 = *(x19_1);
        tmp63 = 0x27;
        *(uint32_t *)(tmp62 + 0x28) = tmp63;
        tmp64 = *(tmp62);
        x0_12 = x19_1;
        x0_13 = (*tmp64)(x0_12); // call
        __branch(0x3b964); // unconditional branch
        if (unavailable_w21 == 0x0) goto 0x3ba18; // conditional branch
        tmp65 = *(uint32_t *)(unavailable_x25 + -0x8);
        if ((uint32_t)(tmp65) < (uint32_t)(0x3)) goto 0x3ba18; // conditional branch
        tmp66 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp67 = __adrp(0x3b000); // Page-relative address
        tmp68 = tmp67 + 0xd7c;
        __branch(0x3b918); // unconditional branch
        tmp69 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp70 = __adrp(0x3b000); // Page-relative address
        tmp71 = tmp70 + 0xeb8;
        __branch(0x3b960); // unconditional branch
        tmp72 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp73 = __adrp(0x3b000); // Page-relative address
        tmp74 = tmp73 + 0xf58;
        *(tmp72 + 0x98) = tmp74;
        tmp75 = unavailable_x20 + unavailable_x22;
        *(uint8_t *)(tmp75 + 0x118) = unavailable_w12;
        *(uint8_t *)(tmp75 + 0x122) = unavailable_w10;
        __branch(0x3b964); // unconditional branch
        x29_2, x30_1 = *(uint64_t *)(sp_1 + 0x50), *(uint64_t *)((sp_1 + 0x50) + 0x8); // restores register pair
        x20_3, x19_2 = *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8); // restores register pair
        x22_3, x21_1 = *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8); // restores register pair
        x24_2, x23_2 = *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8); // restores register pair
        x26_3, x25_3 = *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8); // restores register pair
        x28_2, x27_3, sp_2 = *(uint64_t *)(sp_1), *(uint64_t *)(sp_1 + 0x8), sp_1 + 0x60;
        return; // return
    }
    """
    // Current flat output; differs from the capture above by the single renderer's flat-if form.
    static let flatText = """
    void _j12init_upsampler(struct jpeg_decompress_struct * cinfo) {
        // entry 0x000000000003b774; stack frame 0x60 bytes; calls (*x8), _jround_up, (*x28)
        *(uint64_t *)(sp_0 + -0x60), *(uint64_t *)((sp_0 + -0x60) + 0x8), sp_1 = x28_0, x27_0, sp_0 - 0x60;
        *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8) = x26_0, x25_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8) = x24_0, x23_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8) = x22_0, x21_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8) = x20_0, x19_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x50), *(uint64_t *)((sp_1 + 0x50) + 0x8) = x29_0, x30_0; // saves register pair
        x29_1 = sp_1 + 0x50;
        x19_1 = cinfo;
        tmp0 = *(uint64_t *)((uint8_t *)(cinfo) + 0x238);
        tmp1 = *(uint32_t *)(tmp0 + 0x14);
        tmp2 = cinfo->data_precision;
        if (tmp1 == 0x0) goto loc_3b7e0; // conditional branch
        tmp3 = tmp2 - 0xd;
        if ((uint32_t)(tmp3) >= (uint32_t)(-0x4)) goto loc_3b7cc; // conditional branch
        loc_3b7b0:
        tmp4 = *(x19_1);
        tmp5 = 0x10;
        *(uint32_t *)(tmp4 + 0x28), *(uint32_t *)((tmp4 + 0x28) + 0x4) = tmp5, tmp2; // saves register pair
        tmp6 = *(x19_1);
        tmp7 = *(tmp6);
        x0_1 = x19_1;
        x0_2 = (*tmp7)(x0_1); // call
        loc_3b7cc:
        tmp8 = *(x19_1 + 0x238);
        tmp9 = *(uint32_t *)(tmp8 + 0x70);
        if (tmp9 == 0x0) goto loc_3b7ec; // conditional branch
        x20_1 = *(x19_1 + 0x278);
        goto loc_3b828; // unconditional branch
        loc_3b7e0:
        __compare(unavailable_w8, 0xc); // sets condition flags
        if (unavailable_w8 != 0xc) goto loc_3b7b0; // conditional branch
        goto loc_3b7cc; // unconditional branch
        loc_3b7ec:
        tmp10 = *(x19_1 + 0x8);
        tmp11 = *(tmp10);
        x0_3 = x19_1;
        w1_1 = 0x1;
        w2_1 = 0x130;
        x0_4 = (*tmp11)(x0_3, w1_1, w2_1); // call
        x20_2 = x0_4;
        tmp12 = __adrp(0x3b000); // Page-relative address
        tmp13 = tmp12 + 0xa64;
        *(x19_1 + 0x278) = x0_4;
        *(x0_4) = tmp13;
        tmp14 = __adrp(0x3b000); // Page-relative address
        tmp15 = tmp14 + 0xa78;
        *(x0_4 + 0x10) = tmp15;
        *(uint32_t *)(x0_4 + 0x40) = 0x0;
        loc_3b828:
        tmp16 = *(uint32_t *)(x19_1 + 0x18c);
        if (tmp16 == 0x0) goto loc_3b848; // conditional branch
        tmp17 = *(x19_1);
        tmp18 = 0x1a;
        *(uint32_t *)(tmp17 + 0x28) = tmp18;
        tmp19 = *(tmp17);
        x0_5 = x19_1;
        x0_6 = (*tmp19)(x0_5); // call
        loc_3b848:
        tmp20 = *(uint32_t *)(x19_1 + 0x64);
        if (tmp20 == 0x0) goto loc_3b860; // conditional branch
        tmp21 = *(uint32_t *)(x19_1 + 0x1a0);
        w21_1 = tmp21 > 0x1; // compare to bool
        goto loc_3b864; // unconditional branch
        loc_3b860:
        w21_2 = 0x0;
        loc_3b864:
        tmp22 = *(uint32_t *)(x19_1 + 0x38);
        if (tmp22 < 0x1) goto loc_3ba48; // conditional branch
        x22_1 = 0x0;
        x23_1 = unavailable_x20 + 0x98;
        tmp23 = *(x19_1 + 0x130);
        x24_1 = unavailable_x20 + 0x48;
        x25_1 = tmp23 + 0x34;
        x26_1 = __adrp(0x3b000); // Page-relative address
        x26_2 = x26_1 + 0xbbc;
        x27_1 = __adrp(0x3b000); // Page-relative address
        x27_2 = x27_1 + 0xbc4;
        loc_3b894:
        tmp24 = *(uint32_t *)(unavailable_x25 + -0x10);
        tmp25 = *(uint32_t *)(x19_1 + 0x1a0);
        tmp26, tmp27 = *(uint32_t *)(unavailable_x25 + -0x2c), *(uint32_t *)((unavailable_x25 + -0x2c) + 0x4); // restores register pair
        tmp28 = tmp27 * tmp24;
        tmp29 = __a64_sdiv32(tmp28, tmp25);
        tmp30 = *(uint32_t *)(x19_1 + 0x198);
        tmp31 = *(uint32_t *)(x19_1 + 0x19c);
        tmp32 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x2);
        *(uint32_t *)(tmp32 + 0xf0) = tmp29;
        tmp33 = *(uint32_t *)(unavailable_x25);
        if (tmp33 == 0x0) goto loc_3b928; // conditional branch
        tmp34 = tmp24 * tmp26;
        tmp35 = __a64_sdiv32(tmp34, tmp25);
        if (tmp35 != tmp30) goto loc_3b8e0; // conditional branch
        tmp36 = x23_1;
        x0_7 = x27_2;
        if (tmp29 == tmp31) goto loc_3b99c; // conditional branch
        loc_3b8e0:
        tmp37 = (uint32_t)(tmp35) << 0x1;
        __compare(tmp37, tmp30); // sets condition flags
        __conditional_compare_eq(tmp29, tmp31, 0x0);
        if ((tmp37 == tmp30) && (tmp29 == tmp31)) goto loc_3b934; // conditional branch
        __compare(tmp35, tmp30); // sets condition flags
        tmp38 = (uint32_t)(tmp29) << 0x1;
        __conditional_compare_eq(tmp38, tmp31, 0x0);
        tmp39 = __unknown(\"cset\", \"w14, eq\");
        tmp40 = tmp39 & unavailable_w21;
        if (tmp40 != 0x1) goto loc_3b9b8; // conditional branch
        tmp41 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp42 = __adrp(0x3b000); // Page-relative address
        tmp43 = tmp42 + 0xce0;
        loc_3b918:
        *(unavailable_x8 + 0x98) = unavailable_x9;
        tmp44 = 0x1;
        *(uint32_t *)(unavailable_x20 + 0x40) = tmp44;
        goto loc_3b964; // unconditional branch
        loc_3b928:
        tmp45 = x23_1;
        x0_8 = x26_2;
        goto loc_3b99c; // unconditional branch
        loc_3b934:
        if (unavailable_w21 == 0x0) goto loc_3b954; // conditional branch
        tmp46 = *(uint32_t *)(unavailable_x25 + -0x8);
        if ((uint32_t)(tmp46) < (uint32_t)(0x3)) goto loc_3b954; // conditional branch
        tmp47 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp48 = __adrp(0x3b000); // Page-relative address
        tmp49 = tmp48 + 0xbcc;
        goto loc_3b960; // unconditional branch
        loc_3b954:
        tmp50 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp51 = __adrp(0x3b000); // Page-relative address
        tmp52 = tmp51 + 0xc8c;
        loc_3b960:
        *(unavailable_x8 + 0x98) = unavailable_x9;
        loc_3b964:
        tmp53 = *(x19_1 + 0x238);
        tmp54 = *(uint32_t *)(tmp53 + 0x70);
        if (tmp54 != 0x0) goto loc_3b9a0; // conditional branch
        tmp55 = *(x19_1 + 0x8);
        x28_1 = *(tmp55 + 0x10);
        w0_1 = *(uint32_t *)(x19_1 + 0x88);
        x1_1 = *(int32_t *)(x19_1 + 0x198);
        x0_9 = _jround_up(w0_1, x1_1); // call
        x2_1 = x0_9;
        w3_1 = *(uint32_t *)(x19_1 + 0x19c);
        x0_10 = x19_1;
        w1_2 = 0x1;
        x0_11 = (*x28_1)(x0_10, w1_2, x2_1, w3_1); // call
        tmp56 = x24_1;
        loc_3b99c:
        *(unavailable_x12 + (unavailable_x22 << 0x3)) = unavailable_x0;
        loc_3b9a0:
        x25_2 = unavailable_x25 + 0x60;
        x22_2 = unavailable_x22 + 0x1;
        tmp57 = *(int32_t *)(x19_1 + 0x38);
        if (x22_2 < tmp57) goto loc_3b894; // conditional branch
        goto loc_3ba48; // unconditional branch
        loc_3b9b8:
        __compare(unavailable_w12, unavailable_w10); // sets condition flags
        __conditional_compare_eq(unavailable_w13, unavailable_w9, 0x0);
        if ((unavailable_w12 == unavailable_w10) && (unavailable_w13 == unavailable_w9)) goto loc_3b9f8; // conditional branch
        tmp58 = __a64_sdiv32(unavailable_w10, unavailable_w11);
        tmp59 = unavailable_w10 - (tmp58 * unavailable_w11);
        if (tmp59 != 0x0) goto loc_3b9dc; // conditional branch
        tmp60 = __a64_sdiv32(unavailable_w9, unavailable_w8);
        tmp61 = unavailable_w9 - (tmp60 * unavailable_w8);
        if (tmp61 == 0x0) goto loc_3ba28; // conditional branch
        loc_3b9dc:
        tmp62 = *(x19_1);
        tmp63 = 0x27;
        *(uint32_t *)(tmp62 + 0x28) = tmp63;
        tmp64 = *(tmp62);
        x0_12 = x19_1;
        x0_13 = (*tmp64)(x0_12); // call
        goto loc_3b964; // unconditional branch
        loc_3b9f8:
        if (unavailable_w21 == 0x0) goto loc_3ba18; // conditional branch
        tmp65 = *(uint32_t *)(unavailable_x25 + -0x8);
        if ((uint32_t)(tmp65) < (uint32_t)(0x3)) goto loc_3ba18; // conditional branch
        tmp66 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp67 = __adrp(0x3b000); // Page-relative address
        tmp68 = tmp67 + 0xd7c;
        goto loc_3b918; // unconditional branch
        loc_3ba18:
        tmp69 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp70 = __adrp(0x3b000); // Page-relative address
        tmp71 = tmp70 + 0xeb8;
        goto loc_3b960; // unconditional branch
        loc_3ba28:
        tmp72 = unavailable_x20 + ((uint64_t)(unavailable_x22) << 0x3);
        tmp73 = __adrp(0x3b000); // Page-relative address
        tmp74 = tmp73 + 0xf58;
        *(tmp72 + 0x98) = tmp74;
        tmp75 = unavailable_x20 + unavailable_x22;
        *(uint8_t *)(tmp75 + 0x118) = unavailable_w12;
        *(uint8_t *)(tmp75 + 0x122) = unavailable_w10;
        goto loc_3b964; // unconditional branch
        loc_3ba48:
        x29_2, x30_1 = *(uint64_t *)(sp_1 + 0x50), *(uint64_t *)((sp_1 + 0x50) + 0x8); // restores register pair
        x20_3, x19_2 = *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8); // restores register pair
        x22_3, x21_1 = *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8); // restores register pair
        x24_2, x23_2 = *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8); // restores register pair
        x26_3, x25_3 = *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8); // restores register pair
        x28_2, x27_3, sp_2 = *(uint64_t *)(sp_1), *(uint64_t *)(sp_1 + 0x8), sp_1 + 0x60;
        return; // return
    }
    """
}

private enum J16InitCapturedData {
    static let functionWitness: UInt64 = 0xe939da67072a683f
    static let blocksWitness: UInt64 = 0x2ec95f3164db8c69
    // address | exact bytes | original mnemonic | original operands | original comment |
    // independent complete operand envelope FNV | complete MacIRInstruction FNV
    static let sourceRecord = """
    3c038|fc 6f ba a9|stp|x28, x27, [sp, #-0x60]!||ea093691bfe0ec26|1c3b30f9f549d403
    3c03c|fa 67 01 a9|stp|x26, x25, [sp, #0x10]||456bd70c3f63b976|474507491cd7f59b
    3c040|f8 5f 02 a9|stp|x24, x23, [sp, #0x20]||b5838a7a65e31b84|6401287e7490e479
    3c044|f6 57 03 a9|stp|x22, x21, [sp, #0x30]||e2e4cb2e957df179|9ce1c2e3cce61920
    3c048|f4 4f 04 a9|stp|x20, x19, [sp, #0x40]||aaf1e2af151b4558|261c77fec3703c95
    3c04c|fd 7b 05 a9|stp|x29, x30, [sp, #0x50]||c21a77ab0bb55618|6ffaf5f482a3c281
    3c050|fd 43 01 91|add|x29, sp, #0x50||5f247d1dd4e4be52|8836732dd1e798a3
    3c054|f3 03 00 aa|mov|x19, x0||b5a7cfada79f5022|63428d7db6c4e36d
    3c058|08 1c 41 f9|ldr|x8, [x0, #0x238]||df08abc597fe3f8d|5f65ed883f23598f
    3c05c|09 15 40 b9|ldr|w9, [x8, #0x14]||5e0149a117968849|d6559737df16918c
    3c060|08 28 41 b9|ldr|w8, [x0, #0x128]||b9503b27410bee31|36e24c4c7f10e33e
    3c064|09 02 00 34|cbz|w9, 0x000000000003c0a4||3a2ed5ed1f98a7a3|0f762eab84fd09f2
    3c068|09 45 00 51|sub|w9, w8, #0x11||6149dc467d4216eb|f33307c499499d2c
    3c06c|3f 11 00 31|cmn|w9, #4||4712751820d19103|905d3187dbef040e
    3c070|02 01 00 54|b.hs|0x000000000003c090||78998c18191ca6f0|f17fa34afdb5355d
    3c074|69 02 40 f9|ldr|x9, [x19]||c03128173a42ef6f|250775d71bb2862c
    3c078|0a 02 80 52|mov|w10, #0x10||02aabb759b072b01|62d9c68159a7c883
    3c07c|2a 21 05 29|stp|w10, w8, [x9, #0x28]||d9c2154fabee8e04|cade22198f6f9c96
    3c080|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|9038614404f228d6
    3c084|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|60eb86f4bcd1b514
    3c088|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|4a7492c502febaec
    3c08c|00 01 3f d6|blr|x8||d4648694c208727c|458f53debe626332
    3c090|68 1e 41 f9|ldr|x8, [x19, #0x238]||53423a7c7ebc02a1|02ec4fd26d423cd7
    3c094|08 71 40 b9|ldr|w8, [x8, #0x70]||d209ef724e956942|60b7b9f70a91b9e4
    3c098|c8 00 00 34|cbz|w8, 0x000000000003c0b0||799238bfe4cf90ae|4bd83980c3da9298
    3c09c|74 3e 41 f9|ldr|x20, [x19, #0x278]||8a36e7b34aa38661|d12d7d3b0f595808
    3c0a0|13 00 00 14|b|0x000000000003c0ec||0b8c01e2b42ba850|f8d2fe291ace681e
    3c0a4|1f 41 00 71|cmp|w8, #0x10||b84f9ae53f983036|0c89aa7fa5993368
    3c0a8|61 fe ff 54|b.ne|0x000000000003c074||cde6944366f69477|4d67133079b15ffb
    3c0ac|f9 ff ff 17|b|0x000000000003c090||016b82e71db3dc25|9be200f66b92fdca
    3c0b0|68 06 40 f9|ldr|x8, [x19, #8]||aa06f122615f7152|aeba45e7aa80aa3d
    3c0b4|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|171ce0bb679b1df8
    3c0b8|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|49d7e52184eb7af2
    3c0bc|21 00 80 52|mov|w1, #1||2fcba54fa2dba661|5a6206ca481acd88
    3c0c0|02 26 80 52|mov|w2, #0x130||9190dba258d51c68|ad2e72e08da78d85
    3c0c4|00 01 3f d6|blr|x8||d4648694c208727c|b609d75f564ac186
    3c0c8|f4 03 00 aa|mov|x20, x0||4c0d0a6a717cb852|010de35e286928c5
    3c0cc|08 00 00 90|adrp|x8, 0x000000000003c000|Page-relative address|122d4342b51b4466|1d6ddd36f8a63e1c
    3c0d0|08 a1 0c 91|add|x8, x8, #0x328||8b007af12d1a7624|4c019d28d5c2d972
    3c0d4|60 3e 01 f9|str|x0, [x19, #0x278]||31bb19ed1e2de3c7|e3ad0f824ee690bb
    3c0d8|08 00 00 f9|str|x8, [x0]||da65fb7e618a6cc6|6de265410cc50e34
    3c0dc|08 00 00 90|adrp|x8, 0x000000000003c000|Page-relative address|318595e03f306464|a7cb9dd6355390f2
    3c0e0|08 f1 0c 91|add|x8, x8, #0x33c||54fb1151dbc8d514|a0f82a7e02f6804e
    3c0e4|08 0c 00 f9|str|x8, [x0, #0x18]||0a944cfd986c09d4|a900a2da24f5daeb
    3c0e8|1f 40 00 b9|str|wzr, [x0, #0x40]||a2bcc67f771f6310|0f779db13a38da4f
    3c0ec|68 8e 41 b9|ldr|w8, [x19, #0x18c]||57e940e1144ad3b2|978fbcd18c511edd
    3c0f0|e8 00 00 34|cbz|w8, 0x000000000003c10c||42c06fa8f7aed3d1|7a2b060e8106cc2b
    3c0f4|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|2bbc8cc24e68bb17
    3c0f8|49 03 80 52|mov|w9, #0x1a||39acdfcb3dd4e4b3|82b3414e0cdc5541
    3c0fc|09 29 00 b9|str|w9, [x8, #0x28]||bb4b144c535b7823|825bd475f99519c6
    3c100|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|37f19d23a249d37b
    3c104|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|fcac916c4e629742
    3c108|00 01 3f d6|blr|x8||d4648694c208727c|0c2c43baca42b3be
    3c10c|68 66 40 b9|ldr|w8, [x19, #0x64]||b3584f08c39b8c81|9bd7f42d86e493fa
    3c110|a8 00 00 34|cbz|w8, 0x000000000003c124||f15f0038ea918e3c|987a064d006cc4a8
    3c114|68 a2 41 b9|ldr|w8, [x19, #0x1a0]||a9e209a0d780d559|c9193b5c87aa6712
    3c118|1f 05 00 71|cmp|w8, #1||145914abb2da6be4|818aa8527e75915b
    3c11c|f5 d7 9f 1a|cset|w21, gt||9e29cb2355c56646|ac7fa47ea7eb4209
    3c120|02 00 00 14|b|0x000000000003c128||f9b222301758a11b|9a4fd776a43590ff
    3c124|15 00 80 52|mov|w21, #0||c2d44e58748e8b2d|e68c6cc4167bc9cf
    3c128|68 3a 40 b9|ldr|w8, [x19, #0x38]||d19f099e93149f69|3bc466704ee93fe9
    3c12c|1f 05 00 71|cmp|w8, #1||145914abb2da6be4|909c9e70467bdb18
    3c130|eb 0e 00 54|b.lt|0x000000000003c30c||b5a7c91c4966f5ab|8c5f434334bd5dfc
    3c134|16 00 80 d2|mov|x22, #0||88e72bf935d2cd45|0caffcbad47fc62b
    3c138|97 62 02 91|add|x23, x20, #0x98||22280db0aeedcdfd|8f3d333f508c8099
    3c13c|68 9a 40 f9|ldr|x8, [x19, #0x130]||0f83715daf548161|d3f822ec6773aa17
    3c140|98 22 01 91|add|x24, x20, #0x48||d7d0e7a3ac6a945a|b85def7f203d8b17
    3c144|19 d1 00 91|add|x25, x8, #0x34||e73e8613675056fb|93eca49eb9c93365
    3c148|1a 00 00 90|adrp|x26, 0x000000000003c000|Page-relative address|8de26f1363ba448a|5b3708f4bfefb5d2
    3c14c|5a 03 12 91|add|x26, x26, #0x480||1b5f54e2a96bee2a|4cf474e6a9041ef4
    3c150|1b 00 00 90|adrp|x27, 0x000000000003c000|Page-relative address|2aea36cddabff612|ae75a04606ccbf5c
    3c154|7b 23 12 91|add|x27, x27, #0x488||d44cfd34f3a7b122|c1e0d3378ba89bd1
    3c158|2b 03 5f b8|ldur|w11, [x25, #-0x10]||06a08e06dad4a784|3577f675861b52f3
    3c15c|6c a2 41 b9|ldr|w12, [x19, #0x1a0]||3b03103fc3201668|68fdec12d3edfa22
    3c160|2d a3 7a 29|ldp|w13, w8, [x25, #-0x2c]||7cd5af1109887a82|42ea99a9b79a457e
    3c164|08 7d 0b 1b|mul|w8, w8, w11||4223f48c7b49a87a|b94de916ac109c36
    3c168|08 0d cc 1a|sdiv|w8, w8, w12||fee3eebc10b1f3d0|adac57ecf7acad46
    3c16c|6a 9a 41 b9|ldr|w10, [x19, #0x198]||aed607e8298de1d3|36d839b32d077cc7
    3c170|69 9e 41 b9|ldr|w9, [x19, #0x19c]||4393b1e5adbebee4|2abfb48594e0721a
    3c174|8e 0a 16 8b|add|x14, x20, x22, lsl #2||967b2ef3a85d35e9|71fa8c64a7e3cf32
    3c178|c8 f1 00 b9|str|w8, [x14, #0xf0]||9d76135188b96485|d6eb66a14d76b72e
    3c17c|2e 03 40 b9|ldr|w14, [x25]||df96c5c18c73245c|d626e57e5f4fc2eb
    3c180|6e 03 00 34|cbz|w14, 0x000000000003c1ec||e3faba8737da78b2|c911956c17f0aa60
    3c184|6b 7d 0d 1b|mul|w11, w11, w13||35d817d1536719de|5e2ae709a8dd354f
    3c188|6b 0d cc 1a|sdiv|w11, w11, w12||09db4f1ce24a9700|54585c9f8b97aa97
    3c18c|7f 01 0a 6b|cmp|w11, w10||9b4fa9e49de44480|85a2b8c1cc19c582
    3c190|a1 00 00 54|b.ne|0x000000000003c1a4||0c1f53465a099da0|08ea66c5a8948ed4
    3c194|ec 03 17 aa|mov|x12, x23||5787b7db5592064c|24a88d747cf88268
    3c198|e0 03 1b aa|mov|x0, x27||e27c9f46f4f593e2|22b4048079ead599
    3c19c|1f 01 09 6b|cmp|w8, w9||c155333d3e6b6dae|d3be232f337a298c
    3c1a0|00 06 00 54|b.eq|0x000000000003c260||6649ad206decba5e|55a462d37c27e7ea
    3c1a4|6c 79 1f 53|lsl|w12, w11, #1||43a89db22ccef326|adcf912e466762e2
    3c1a8|9f 01 0a 6b|cmp|w12, w10||f986b7becee28f99|fbba8054e7651ea7
    3c1ac|00 01 49 7a|ccmp|w8, w9, #0, eq||6130615f13e8d308|b6e200d9780cc76a
    3c1b0|40 02 00 54|b.eq|0x000000000003c1f8||b75112a89dd7004b|6f406cb56bfd8fe9
    3c1b4|7f 01 0a 6b|cmp|w11, w10||9b4fa9e49de44480|97ed37df326543be
    3c1b8|0d 79 1f 53|lsl|w13, w8, #1||4690ad92dc38ce0a|2ae50534e80e8edc
    3c1bc|a0 01 49 7a|ccmp|w13, w9, #0, eq||6c9e59c4df9a437e|b8ee1d5f2986e95f
    3c1c0|ee 17 9f 1a|cset|w14, eq||f1fc5f71f437cf1e|5722b200c7f99440
    3c1c4|ce 01 15 0a|and|w14, w14, w21||1cda42160d4400d6|34591185d2b9480f
    3c1c8|df 05 00 71|cmp|w14, #1||1bb7163486de7c05|eec2674c515a1042
    3c1cc|81 05 00 54|b.ne|0x000000000003c27c||fb421be073cd4773|17552d16bf7adabd
    3c1d0|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|02aae712d0a74587
    3c1d4|09 00 00 90|adrp|x9, 0x000000000003c000|Page-relative address|3e6685eb0063fb5f|802ddfe223b8d59d
    3c1d8|29 91 16 91|add|x9, x9, #0x5a4||13202dba95de40ea|7d3ab61945c0f7f0
    3c1dc|09 4d 00 f9|str|x9, [x8, #0x98]||16add3e815690a5f|c8d588ff99d8710c
    3c1e0|28 00 80 52|mov|w8, #1||2c096c689aaf13c2|63692d379e06141a
    3c1e4|88 42 00 b9|str|w8, [x20, #0x40]||f00983abac9b4dba|134f56d7ec81e860
    3c1e8|10 00 00 14|b|0x000000000003c228||26ea4dc6cdd9dca7|1df8047214925eb4
    3c1ec|ec 03 17 aa|mov|x12, x23||5787b7db5592064c|55c5a58d49b3b4ab
    3c1f0|e0 03 1a aa|mov|x0, x26||beb2ddce8e008012|3330421f963ebb5d
    3c1f4|1b 00 00 14|b|0x000000000003c260||3118c2d05b8741cc|760ed7d90c39379d
    3c1f8|15 01 00 34|cbz|w21, 0x000000000003c218||3322cb2a4317488d|f98a6fb0feb85af8
    3c1fc|28 83 5f b8|ldur|w8, [x25, #-0x8]||8386d0a0947005f3|8585427630f17b6e
    3c200|1f 0d 00 71|cmp|w8, #3||2a772aec24fb2d08|eb8ef229c5eb8250
    3c204|a3 00 00 54|b.lo|0x000000000003c218||2497bc5c18161b02|191dde8346c8f849
    3c208|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|9f4b9cdaff9c1984
    3c20c|09 00 00 90|adrp|x9, 0x000000000003c000|Page-relative address|cce7a889d5a62571|fd71e04dd2f25287
    3c210|29 41 12 91|add|x9, x9, #0x490||cb760ff88be17bb2|d538a877a4032d36
    3c214|04 00 00 14|b|0x000000000003c224||dc4d72637eaa9035|b2d70d2d74d189b2
    3c218|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|00d20e20929b53ce
    3c21c|09 00 00 90|adrp|x9, 0x000000000003c000|Page-relative address|db5c5a82c844336e|ebf91318a5a28911
    3c220|29 41 15 91|add|x9, x9, #0x550||f31bc1890c7cebaa|bfb86e691b8880b4
    3c224|09 4d 00 f9|str|x9, [x8, #0x98]||16add3e815690a5f|fc3f018a7cb9f85c
    3c228|68 1e 41 f9|ldr|x8, [x19, #0x238]||53423a7c7ebc02a1|9b98e3dc73b4ea3f
    3c22c|08 71 40 b9|ldr|w8, [x8, #0x70]||d209ef724e956942|1f723a838b7467ad
    3c230|a8 01 00 35|cbnz|w8, 0x000000000003c264||1119f12ef76478cb|2006799f8d01092a
    3c234|68 06 40 f9|ldr|x8, [x19, #8]||aa06f122615f7152|5974b1420fab914f
    3c238|1c 09 40 f9|ldr|x28, [x8, #0x10]||0361d2c02a3c593b|1b868b8b323e4565
    3c23c|60 8a 40 b9|ldr|w0, [x19, #0x88]||58fc5e7860d1b4ca|bef3a3654be6ea11
    3c240|61 9a 81 b9|ldrsw|x1, [x19, #0x198]||bc988508738f5d74|f029f8b88e4c0737
    3c244|8d 3d 00 94|bl|_jround_up||d79b076ac9020619|b45b979648fd69ac
    3c248|e2 03 00 aa|mov|x2, x0||6aac86369e8025c4|444aa81de60ccecd
    3c24c|63 9e 41 b9|ldr|w3, [x19, #0x19c]||a56ac99260371e7e|ec9a6c6525403aa7
    3c250|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|a3f2ec4a6546a7ca
    3c254|21 00 80 52|mov|w1, #1||2fcba54fa2dba661|9de08718b0828b21
    3c258|80 03 3f d6|blr|x28||9e3c57a19b74e67e|e6f3e2752aa0c792
    3c25c|ec 03 18 aa|mov|x12, x24||e17f438152fdded2|4e2818674cb022ab
    3c260|80 79 36 f8|str|x0, [x12, x22, lsl #3]||e6a387ea87cbaf94|905e3faaedc7f354
    3c264|39 83 01 91|add|x25, x25, #0x60||838042d8989b9c1a|8209ae224bbb3a27
    3c268|d6 06 00 91|add|x22, x22, #1||760387c1280e9558|52c9fad84f9dca25
    3c26c|68 3a 80 b9|ldrsw|x8, [x19, #0x38]||01cb3201f0ec64ee|943176f9f920fca7
    3c270|df 02 08 eb|cmp|x22, x8||01972191fc7b1742|fddce29bccd2b6c2
    3c274|2b f7 ff 54|b.lt|0x000000000003c158||84b3366ea3d7401c|baf6ae1a0dcce5c2
    3c278|25 00 00 14|b|0x000000000003c30c||226c5c04f32efb2a|ca43924df8f331c7
    3c27c|9f 01 0a 6b|cmp|w12, w10||f986b7becee28f99|1944fb95c0e37ef5
    3c280|a0 01 49 7a|ccmp|w13, w9, #0, eq||6c9e59c4df9a437e|341d3028b0411081
    3c284|c0 01 00 54|b.eq|0x000000000003c2bc||e8e0efef82181b2d|bd0379db6a0738e9
    3c288|4c 0d cb 1a|sdiv|w12, w10, w11||81427e24a59d5f5c|3542802c6e3fe658
    3c28c|8a a9 0b 1b|msub|w10, w12, w11, w10||1800267e50f65732|882d70bfab330444
    3c290|8a 00 00 35|cbnz|w10, 0x000000000003c2a0||7843f78a10e0b606|0442e2514cdebd12
    3c294|2a 0d c8 1a|sdiv|w10, w9, w8||5eb355ba1f3afe44|1240dda56d37dc59
    3c298|48 a5 08 1b|msub|w8, w10, w8, w9||1f620c519629032a|3249e8e84008d3aa
    3c29c|88 02 00 34|cbz|w8, 0x000000000003c2ec||391964b9f1525f1d|1e49d77fb8c99277
    3c2a0|68 02 40 f9|ldr|x8, [x19]||01176cffb76174ea|21bf83df829efaac
    3c2a4|e9 04 80 52|mov|w9, #0x27||51b72ccb3b8c550b|1ef0eb962002c47c
    3c2a8|09 29 00 b9|str|w9, [x8, #0x28]||bb4b144c535b7823|68b230bce765e307
    3c2ac|08 01 40 f9|ldr|x8, [x8]||e0a63c98b4921bae|0516788deed742b4
    3c2b0|e0 03 13 aa|mov|x0, x19||8b3632a42f59dd8a|b236a09622e42362
    3c2b4|00 01 3f d6|blr|x8||d4648694c208727c|0315d242b2438091
    3c2b8|dc ff ff 17|b|0x000000000003c228||78e4f450d07ef826|747aab92b1693457
    3c2bc|15 01 00 34|cbz|w21, 0x000000000003c2dc||96f5c96e769c668f|4bd35a43dd558568
    3c2c0|28 83 5f b8|ldur|w8, [x25, #-0x8]||8386d0a0947005f3|e102bc74775a3b76
    3c2c4|1f 0d 00 71|cmp|w8, #3||2a772aec24fb2d08|e789b9735a0f2ecc
    3c2c8|a3 00 00 54|b.lo|0x000000000003c2dc||1b7902672961c430|dae58c148d70f448
    3c2cc|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|49123e9201b3e1b4
    3c2d0|09 00 00 90|adrp|x9, 0x000000000003c000|Page-relative address|405643baa3833bb7|2404c67dc7b9674b
    3c2d4|29 01 19 91|add|x9, x9, #0x640||dc5d9edb80fa4ad2|8006a42b9b89cf21
    3c2d8|c1 ff ff 17|b|0x000000000003c1dc||3e5b99a84164aebb|6b42a4b7c7fefea0
    3c2dc|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|30ca2d4d99f341b3
    3c2e0|09 00 00 90|adrp|x9, 0x000000000003c000|Page-relative address|8750049508159bf8|eac8fde9e02f2fbe
    3c2e4|29 f1 1d 91|add|x9, x9, #0x77c||c99143a996f47112|8b40f6b00136934b
    3c2e8|cf ff ff 17|b|0x000000000003c224||9057ea330f17e94d|00ceaba7ef1b89be
    3c2ec|88 0e 16 8b|add|x8, x20, x22, lsl #3||11a24790179f11e9|73788f2a313b8170
    3c2f0|09 00 00 90|adrp|x9, 0x000000000003c000|Page-relative address|8f42b389f4db9267|33f717296a2a50dc
    3c2f4|29 71 20 91|add|x9, x9, #0x81c||bd6d5fe81f27bc8a|5dddf5eb6aa324d6
    3c2f8|09 4d 00 f9|str|x9, [x8, #0x98]||16add3e815690a5f|e1a44b02e609bbda
    3c2fc|88 02 16 8b|add|x8, x20, x22||59b44bd3697d6f5c|27464d8c7c69c179
    3c300|0c 61 04 39|strb|w12, [x8, #0x118]||10f85510e40c7864|1d4140fc08d051e5
    3c304|0a 89 04 39|strb|w10, [x8, #0x122]||1ca01ad9ae93d501|d862f1a0ca8a0e4f
    3c308|c8 ff ff 17|b|0x000000000003c228||41cb76a5745c16f8|a992cfe99637c7da
    3c30c|fd 7b 45 a9|ldp|x29, x30, [sp, #0x50]||51d203dcacd423e6|7c2d0fc310277f8f
    3c310|f4 4f 44 a9|ldp|x20, x19, [sp, #0x40]||1807fcc4fffc49ca|3f4f25b5dabd883f
    3c314|f6 57 43 a9|ldp|x22, x21, [sp, #0x30]||d53cf918c80ecdb5|c43964303051f362
    3c318|f8 5f 42 a9|ldp|x24, x23, [sp, #0x20]||33d15f561fa36de2|8e6c32af9f6e1ce4
    3c31c|fa 67 41 a9|ldp|x26, x25, [sp, #0x10]||641b0efa53c5ea6c|ee2726a1ce61ae00
    3c320|fc 6f c6 a8|ldp|x28, x27, [sp], #0x60||07ef66cf676afb46|f8b44f17f5139d20
    3c324|c0 03 5f d6|ret|||52dc34e2ac6a9178|b0778a9d12e6dc50
    """
    static let baselineText = """
    int64_t _j16init_upsampler(int64_t arg0) {
        // entry 0x000000000003c038; no stack frame; calls (*x8), _jround_up, (*x28)
        *(uint64_t *)(sp_0 + -0x60), *(uint64_t *)((sp_0 + -0x60) + 0x8), sp_1 = x28_0, x27_0, sp_0 - 0x60;
        *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8) = x26_0, x25_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8) = x24_0, x23_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8) = x22_0, x21_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8) = x20_0, x19_0; // saves register pair
        *(uint64_t *)(sp_1 + 0x50), *(uint64_t *)((sp_1 + 0x50) + 0x8) = x29_0, x30_0; // saves register pair
        x29_1 = sp_1 + 0x50;
        x19_1 = arg0;
        tmp0 = *(arg0 + 0x238);
        tmp1 = *(uint32_t *)(tmp0 + 0x14);
        tmp2 = *(uint32_t *)(arg0 + 0x128);
        if (tmp1 == 0x0) goto 0x3c0a4; // conditional branch
        tmp3 = tmp2 - 0x11;
        if ((uint32_t)(tmp3) >= (uint32_t)(-0x4)) goto 0x3c090; // conditional branch
        tmp4 = *(x19_1);
        tmp5 = 0x10;
        *(uint32_t *)(tmp4 + 0x28), *(uint32_t *)((tmp4 + 0x28) + 0x4) = tmp5, tmp2; // saves register pair
        tmp6 = *(x19_1);
        tmp7 = *(tmp6);
        x0_1 = x19_1;
        x0_2 = (*tmp7)(x0_1); // call
        tmp8 = *(x19_1 + 0x238);
        tmp9 = *(uint32_t *)(tmp8 + 0x70);
        if (tmp9 == 0x0) goto 0x3c0b0; // conditional branch
        x20_1 = *(x19_1 + 0x278);
        __branch(0x3c0ec); // unconditional branch
        if (tmp9 != 0x10) goto 0x3c074; // conditional branch
        __branch(0x3c090); // unconditional branch
        tmp10 = *(x19_1 + 0x8);
        tmp11 = *(tmp10);
        x0_3 = x19_1;
        w1_1 = 0x1;
        w2_1 = 0x130;
        x0_4 = (*tmp11)(x0_3, w1_1, w2_1); // call
        x20_2 = x0_4;
        tmp12 = __adrp(0x3c000); // Page-relative address
        tmp13 = tmp12 + 0x328;
        *(x19_1 + 0x278) = x0_4;
        *(x0_4) = tmp13;
        tmp14 = __adrp(0x3c000); // Page-relative address
        tmp15 = tmp14 + 0x33c;
        *(x0_4 + 0x18) = tmp15;
        *(uint32_t *)(x0_4 + 0x40) = 0x0;
        tmp16 = *(uint32_t *)(x19_1 + 0x18c);
        if (tmp16) { // conditional branch
            tmp17 = *(x19_1);
            tmp18 = 0x1a;
            *(uint32_t *)(tmp17 + 0x28) = tmp18;
            tmp19 = *(tmp17);
            x0_5 = x19_1;
            x0_6 = (*tmp19)(x0_5); // call
        }
        tmp20 = *(uint32_t *)(x19_1 + 0x64);
        if (tmp20) { // conditional branch
            tmp21 = *(uint32_t *)(x19_1 + 0x1a0);
            w21_1 = tmp21 > 0x1; // compare to bool
        } else {
            w21_2 = 0x0;
        }
        tmp22 = *(uint32_t *)(x19_1 + 0x38);
        if (tmp22 < 0x1) goto 0x3c30c; // conditional branch
        x22_1 = 0x0;
        x23_1 = x20_2 + 0x98;
        tmp23 = *(x19_1 + 0x130);
        x24_1 = x20_2 + 0x48;
        x25_1 = tmp23 + 0x34;
        x26_1 = __adrp(0x3c000); // Page-relative address
        x26_2 = x26_1 + 0x480;
        x27_1 = __adrp(0x3c000); // Page-relative address
        x27_2 = x27_1 + 0x488;
        tmp24 = *(uint32_t *)(x25_1 + -0x10);
        tmp25 = *(uint32_t *)(x19_1 + 0x1a0);
        tmp26, tmp27 = *(uint32_t *)(x25_1 + -0x2c), *(uint32_t *)((x25_1 + -0x2c) + 0x4); // restores register pair
        tmp28 = tmp27 * tmp24;
        tmp29 = __a64_sdiv32(tmp28, tmp25);
        tmp30 = *(uint32_t *)(x19_1 + 0x198);
        tmp31 = *(uint32_t *)(x19_1 + 0x19c);
        tmp32 = x20_2 + ((uint64_t)(x22_1) << 0x2);
        *(uint32_t *)(tmp32 + 0xf0) = tmp29;
        tmp33 = *(uint32_t *)(x25_1);
        if (tmp33 == 0x0) goto 0x3c1ec; // conditional branch
        tmp34 = tmp24 * tmp26;
        tmp35 = __a64_sdiv32(tmp34, tmp25);
        if (tmp35 != tmp30) goto 0x3c1a4; // conditional branch
        tmp36 = x23_1;
        x0_7 = x27_2;
        if (tmp29 == tmp31) goto 0x3c260; // conditional branch
        tmp37 = (uint32_t)(tmp35) << 0x1;
        __compare(tmp37, tmp30); // sets condition flags
        __conditional_compare_eq(tmp29, tmp31, 0x0);
        if ((tmp37 == tmp30) && (tmp29 == tmp31)) goto 0x3c1f8; // conditional branch
        __compare(tmp35, tmp30); // sets condition flags
        tmp38 = (uint32_t)(tmp29) << 0x1;
        __conditional_compare_eq(tmp38, tmp31, 0x0);
        tmp39 = __unknown("cset", "w14, eq");
        tmp40 = tmp39 & w21_2;
        if (tmp40 != 0x1) goto 0x3c27c; // conditional branch
        tmp41 = x20_2 + ((uint64_t)(x22_1) << 0x3);
        tmp42 = __adrp(0x3c000); // Page-relative address
        tmp43 = tmp42 + 0x5a4;
        *(tmp41 + 0x98) = tmp43;
        tmp44 = 0x1;
        *(uint32_t *)(x20_2 + 0x40) = tmp44;
        __branch(0x3c228); // unconditional branch
        tmp45 = x23_1;
        x0_8 = x26_2;
        __branch(0x3c260); // unconditional branch
        if (w21_2 == 0x0) goto 0x3c218; // conditional branch
        tmp46 = *(uint32_t *)(x25_1 + -0x8);
        if ((uint32_t)(tmp46) < (uint32_t)(0x3)) goto 0x3c218; // conditional branch
        tmp47 = x20_2 + ((uint64_t)(x22_1) << 0x3);
        tmp48 = __adrp(0x3c000); // Page-relative address
        tmp49 = tmp48 + 0x490;
        __branch(0x3c224); // unconditional branch
        tmp50 = x20_2 + ((uint64_t)(x22_1) << 0x3);
        tmp51 = __adrp(0x3c000); // Page-relative address
        tmp52 = tmp51 + 0x550;
        *(tmp50 + 0x98) = tmp52;
        tmp53 = *(x19_1 + 0x238);
        tmp54 = *(uint32_t *)(tmp53 + 0x70);
        if (!tmp54) { // conditional branch
            tmp55 = *(x19_1 + 0x8);
            x28_1 = *(tmp55 + 0x10);
            w0_1 = *(uint32_t *)(x19_1 + 0x88);
            x1_1 = *(int32_t *)(x19_1 + 0x198);
            x0_9 = _jround_up(w0_1, x1_1); // call
            x2_1 = x0_9;
            w3_1 = *(uint32_t *)(x19_1 + 0x19c);
            x0_10 = x19_1;
            w1_2 = 0x1;
            x0_11 = (*x28_1)(x0_10, w1_2, x2_1, w3_1); // call
            tmp56 = x24_1;
            *(tmp56 + (x22_1 << 0x3)) = x0_11;
        }
        x25_2 = x25_1 + 0x60;
        x22_2 = x22_1 + 0x1;
        tmp57 = *(int32_t *)(x19_1 + 0x38);
        if (x22_2 < tmp57) goto 0x3c158; // conditional branch
        __branch(0x3c30c); // unconditional branch
        __compare((uint32_t)(tmp56), unavailable_w10); // sets condition flags
        __conditional_compare_eq(unavailable_w13, unavailable_w9, 0x0);
        if (((uint32_t)(tmp56) == unavailable_w10) && (unavailable_w13 == unavailable_w9)) goto 0x3c2bc; // conditional branch
        tmp58 = __a64_sdiv32(unavailable_w10, unavailable_w11);
        tmp59 = unavailable_w10 - (tmp58 * unavailable_w11);
        if (tmp59 != 0x0) goto 0x3c2a0; // conditional branch
        tmp60 = __a64_sdiv32(unavailable_w9, (uint32_t)(tmp57));
        tmp61 = unavailable_w9 - (tmp60 * (uint32_t)(tmp57));
        if (tmp61 == 0x0) goto 0x3c2ec; // conditional branch
        tmp62 = *(x19_1);
        tmp63 = 0x27;
        *(uint32_t *)(tmp62 + 0x28) = tmp63;
        tmp64 = *(tmp62);
        x0_12 = x19_1;
        x0_13 = (*tmp64)(x0_12); // call
        __branch(0x3c228); // unconditional branch
        if (w21_2 == 0x0) goto 0x3c2dc; // conditional branch
        tmp65 = *(uint32_t *)(x25_2 + -0x8);
        if ((uint32_t)(tmp65) < (uint32_t)(0x3)) goto 0x3c2dc; // conditional branch
        tmp66 = x20_2 + ((uint64_t)(x22_2) << 0x3);
        tmp67 = __adrp(0x3c000); // Page-relative address
        tmp68 = tmp67 + 0x640;
        __branch(0x3c1dc); // unconditional branch
        tmp69 = x20_2 + ((uint64_t)(x22_2) << 0x3);
        tmp70 = __adrp(0x3c000); // Page-relative address
        tmp71 = tmp70 + 0x77c;
        __branch(0x3c224); // unconditional branch
        tmp72 = x20_2 + ((uint64_t)(x22_2) << 0x3);
        tmp73 = __adrp(0x3c000); // Page-relative address
        tmp74 = tmp73 + 0x81c;
        *(tmp72 + 0x98) = tmp74;
        tmp75 = x20_2 + x22_2;
        *(uint8_t *)(tmp75 + 0x118) = unavailable_w12;
        *(uint8_t *)(tmp75 + 0x122) = unavailable_w10;
        __branch(0x3c228); // unconditional branch
        x29_2, x30_1 = *(uint64_t *)(sp_1 + 0x50), *(uint64_t *)((sp_1 + 0x50) + 0x8); // restores register pair
        x20_3, x19_2 = *(uint64_t *)(sp_1 + 0x40), *(uint64_t *)((sp_1 + 0x40) + 0x8); // restores register pair
        x22_3, x21_1 = *(uint64_t *)(sp_1 + 0x30), *(uint64_t *)((sp_1 + 0x30) + 0x8); // restores register pair
        x24_2, x23_2 = *(uint64_t *)(sp_1 + 0x20), *(uint64_t *)((sp_1 + 0x20) + 0x8); // restores register pair
        x26_3, x25_3 = *(uint64_t *)(sp_1 + 0x10), *(uint64_t *)((sp_1 + 0x10) + 0x8); // restores register pair
        x28_2, x27_3, sp_2 = *(uint64_t *)(sp_1), *(uint64_t *)(sp_1 + 0x8), sp_1 + 0x60;
        return x0_13; // return
    }
    """
}

extension RegionalCallSeed {
    var functionWitness: UInt64 {
        switch self {
        case .jinit: return JinitCapturedData.functionWitness
        case .j12init: return J12InitCapturedData.functionWitness
        case .j16init: return J16InitCapturedData.functionWitness
        }
    }
    var blocksWitness: UInt64 {
        switch self {
        case .jinit: return JinitCapturedData.blocksWitness
        case .j12init: return J12InitCapturedData.blocksWitness
        case .j16init: return J16InitCapturedData.blocksWitness
        }
    }
    var sourceRecord: String {
        switch self {
        case .jinit: return JinitCapturedData.sourceRecord
        case .j12init: return J12InitCapturedData.sourceRecord
        case .j16init: return J16InitCapturedData.sourceRecord
        }
    }
    var baselineText: String {
        switch self {
        case .jinit: return JinitCapturedData.baselineText
        case .j12init: return J12InitCapturedData.baselineText
        case .j16init: return J16InitCapturedData.baselineText
        }
    }
}
