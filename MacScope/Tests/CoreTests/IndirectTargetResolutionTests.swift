import XCTest
@testable import MacScope

/// Single-target resolution of indirect calls through memory slots.
final class IndirectTargetResolutionTests: XCTestCase {
    private func build(_ name: String, at start: UInt64, typed: String? = nil,
                       _ text: [(String, String)]) -> MacIRFunction {
        let rows = text.enumerated().map { index, pair in
            InstructionRow(address: start + UInt64(index * 4), bytes: "", mnemonic: pair.0, operands: pair.1,
                           hasBreakpoint: false, comment: nil)
        }
        let overrides = typed.map { [start: FunctionSignatureOverride(args: [ArgOverride(index: 0, name: "ops", type: $0)])] } ?? [:]
        return PseudocodePrinter().buildFunction(functionName: name, startAddress: start,
                                                 signatureOverrides: overrides, instructions: rows)
    }

    func testLocalAndTypedSingleTargetSlotsResolveAndOthersAreRefused() {
        let handler: UInt64 = 0x9040, other: UInt64 = 0x9080
        let starts: Set<UInt64> = [handler, other]
        // Function-local: the store reaches the slot load in one block.
        let local = build("_local", at: 0x1000, [
            ("adrp", "x9, 0x9000"), ("add", "x9, x9, #0x40"), ("str", "x9, [x0, #0x18]"),
            ("ldr", "x8, [x0, #0x18]"), ("blr", "x8"), ("ret", ""),
        ])
        // A call between the store and the load may rewrite the slot.
        let clobbered = build("_clobbered", at: 0x2000, [
            ("adrp", "x9, 0x9000"), ("add", "x9, x9, #0x40"), ("str", "x9, [x0, #0x18]"),
            ("bl", "_unknown"), ("ldr", "x8, [x0, #0x18]"), ("blr", "x8"), ("ret", ""),
        ])
        // Signature-typed: one installer stores the handler into Ops+0x10; a dispatcher calls it.
        let installer = build("_install", at: 0x3000, typed: "struct Ops *", [
            ("adrp", "x9, 0x9000"), ("add", "x9, x9, #0x40"), ("str", "x9, [x0, #0x10]"), ("ret", ""),
        ])
        let dispatcher = build("_dispatch", at: 0x4000, typed: "struct Ops *", [
            ("ldr", "x8, [x0, #0x10]"), ("blr", "x8"), ("ret", ""),
        ])
        // Two different functions stored to Multi+0x8: refused.
        let multiA = build("_multiA", at: 0x5000, typed: "struct Multi *", [
            ("adrp", "x9, 0x9000"), ("add", "x9, x9, #0x40"), ("str", "x9, [x0, #0x8]"), ("ret", ""),
        ])
        let multiB = build("_multiB", at: 0x5100, typed: "struct Multi *", [
            ("adrp", "x9, 0x9000"), ("add", "x9, x9, #0x80"), ("str", "x9, [x0, #0x8]"), ("ret", ""),
        ])
        let multiCall = build("_multiCall", at: 0x5200, typed: "struct Multi *", [
            ("ldr", "x8, [x0, #0x8]"), ("blr", "x8"), ("ret", ""),
        ])
        // An indexed store through Indexed poisons all its slots (libjpeg methods[ci]).
        let indexed = build("_indexed", at: 0x6000, typed: "struct Indexed *", [
            ("adrp", "x9, 0x9000"), ("add", "x9, x9, #0x40"), ("add", "x8, x0, x1, lsl #3"),
            ("str", "x9, [x8, #0x98]"), ("str", "x9, [x0, #0x98]"), ("ret", ""),
        ])
        let indexedCall = build("_indexedCall", at: 0x6100, typed: "struct Indexed *", [
            ("ldr", "x8, [x0, #0x98]"), ("blr", "x8"), ("ret", ""),
        ])
        // Untyped cross-function: not the same object, so no resolution.
        let untypedCall = build("_untyped", at: 0x7000, [("ldr", "x8, [x0, #0x10]"), ("blr", "x8"), ("ret", "")])

        // Each image has its own writer inventory. Unrelated/untyped roots in a
        // combined image cannot be assumed non-aliasing just from type names.
        let reports = [[local, clobbered, untypedCall], [installer, dispatcher],
                       [multiA, multiB, multiCall], [indexed, indexedCall]].map {
            MacIRIndirectTargetResolution.resolve(functions: $0, functionStarts: starts)
        }
        let report = MacIRIndirectTargetResolution.Report(resolutions: reports.flatMap(\.resolutions),
                                                          refusals: reports.flatMap(\.refusals))
        let resolved = Dictionary(uniqueKeysWithValues: report.resolutions.map { ($0.functionStart, $0) })
        let refused = Dictionary(uniqueKeysWithValues: report.refusals.map { ($0.functionStart, $0.reason) })
        XCTAssertEqual(resolved[0x1000]?.target, handler, "\(report)")
        XCTAssertEqual(resolved[0x1000]?.scope, .function(0x1000))
        XCTAssertEqual(resolved[0x1000]?.slot.description, "x0+0x18")
        XCTAssertNil(resolved[0x2000], "a call between store and load blocks local resolution")
        XCTAssertEqual(resolved[0x4000]?.target, handler, "\(report)")
        XCTAssertEqual(resolved[0x4000]?.scope, .type("Ops"))
        XCTAssertEqual(refused[0x5200], .multipleValues)
        XCTAssertEqual(refused[0x6100], .poisoned)
        XCTAssertEqual(refused[0x7000], .noStore)
    }
}

extension IndirectTargetResolutionTests {
    @MainActor func testMCPExposesTheReadOnlyCommand() {
        XCTAssertTrue(HeadlessAutomationAuthority.availableCommands.contains { $0.name == "indirect-call-targets" && !$0.mutates })
        XCTAssertTrue(MCPAttachExecutor.attachCommands.contains("indirect-call-targets"))
    }
}

extension IndirectTargetResolutionTests {
    /// Item 3: a resolved slot call prints as the target with its slot; refused ones are unchanged.
    func testResolvedIndirectCallRendersAsTargetViaSlot() {
        let rows: [(String, String)] = [
            ("adrp", "x9, 0x9000"), ("add", "x9, x9, #0x40"), ("str", "x9, [x0, #0x18]"),
            ("ldr", "x8, [x0, #0x18]"), ("blr", "x8"), ("ret", ""),
        ]
        let local = build("_local", at: 0x1000, rows)
        let before = PseudocodePrinter().print(function: local).text
        XCTAssertTrue(before.range(of: #"\(\*\w+\)\("#, options: .regularExpression) != nil, before)
        let calls = PseudocodePrinter.functionLocalIndirectCalls(in: local, functionStarts: [0x9040]) { _ in "_handler" }
        XCTAssertEqual(calls, [0x1010: PseudocodeIndirectCall(target: 0x9040, name: "_handler", slot: "x0+0x18")])
        let after = PseudocodePrinter().print(function: local, resolvedIndirectCalls: calls).text
        XCTAssertTrue(after.range(of: #"_handler\([^)]*\) /\* via x0\+0x18 \*/"#, options: .regularExpression) != nil, after)
        XCTAssertNil(after.range(of: #"\(\*\w+\)\("#, options: .regularExpression), after)

        // A call between the store and the load: refused, so nothing is resolved or rendered.
        let clobbered = build("_clobbered", at: 0x2000, [
            ("adrp", "x9, 0x9000"), ("add", "x9, x9, #0x40"), ("str", "x9, [x0, #0x18]"),
            ("bl", "_unknown"), ("ldr", "x8, [x0, #0x18]"), ("blr", "x8"), ("ret", ""),
        ])
        XCTAssertTrue(PseudocodePrinter.functionLocalIndirectCalls(in: clobbered, functionStarts: [0x9040]) { _ in "_handler" }.isEmpty)

        // The pane renders what the render input carries.
        let instructions = rows.enumerated().map { index, pair in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "", mnemonic: pair.0, operands: pair.1,
                           hasBreakpoint: false, comment: nil)
        }
        let input = PseudocodeRenderInput(
            imageSlot: .primary, functionName: "_local", startAddress: 0x1000, jumpTables: [:], objcSelectors: [:],
            nameOverrides: [:], signatureOverrides: [:], registerNameOverrides: [:], types: [],
            instructions: instructions, resolvedIndirectCalls: calls)
        XCTAssertTrue(PseudocodeView.document(for: input, options: .default).text.contains("/* via x0+0x18 */"))
    }
}

extension IndirectTargetResolutionTests {
    static func typedSnapshot(includingLocalCaller: Bool = true) -> WorkspaceSnapshot {
        func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
            InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil)
        }
        var analysis = ImageAnalysis()
        analysis.functions = [
            FunctionSummary(id: UUID(), name: "_install", startAddress: 0x3000, endAddress: 0x3010, confidence: 1),
            FunctionSummary(id: UUID(), name: "_dispatch", startAddress: 0x4000, endAddress: 0x400c, confidence: 1),
            FunctionSummary(id: UUID(), name: "_local", startAddress: 0x5000, endAddress: 0x5018, confidence: 1),
            FunctionSummary(id: UUID(), name: "_handler", startAddress: 0x9040, endAddress: 0x9044, confidence: 1),
        ]
        analysis.instructions = [
            row(0x3000, "adrp", "x9, 0x9000"), row(0x3004, "add", "x9, x9, #0x40"),
            row(0x3008, "str", "x9, [x0, #0x10]"), row(0x300c, "ret", ""),
            row(0x4000, "ldr", "x8, [x0, #0x10]"), row(0x4004, "blr", "x8"), row(0x4008, "ret", ""),
            row(0x5000, "adrp", "x9, 0x9000"), row(0x5004, "add", "x9, x9, #0x40"),
            row(0x5008, "str", "x9, [x0, #0x18]"), row(0x500c, "ldr", "x8, [x0, #0x18]"),
            row(0x5010, "blr", "x8"), row(0x5014, "ret", ""), row(0x9040, "ret", ""),
        ]
        if !includingLocalCaller {
            analysis.functions.removeAll { $0.startAddress == 0x5000 }
            analysis.instructions.removeAll { (0x5000..<0x5018).contains($0.address) }
        }
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "ops", path: "/tmp/ops", kind: "executable",
                                                 architecture: "arm64", slot: .primary), analysis: analysis)
        for start: UInt64 in [0x3000, 0x4000, 0x5000] {
            var value = AddressOverride()
            value.signature = FunctionSignatureOverride(args: [ArgOverride(index: 0, name: "ops", type: "struct Ops *")])
            snapshot.addressOverrides[ImageAddress(slot: .primary, address: start)] = value
        }
        return snapshot
    }

    static func render(_ snapshot: WorkspaceSnapshot, at address: UInt64 = 0x4000) -> String {
        PseudocodeView.document(for: snapshot.pseudocodeRenderInput(selectedAddress: address, in: .primary),
                                options: .default).text
    }

    func testTypedResolutionRendersFromTheWarmImageWideMemo() {
        var snapshot = Self.typedSnapshot(includingLocalCaller: false)
        let report = snapshot.imageWideIndirectCalls(in: .primary, compute: true)
        XCTAssertEqual(report?.resolutions.first?.scope, .type("Ops"))
        let after = Self.render(snapshot)
        XCTAssertTrue(after.range(of: #"_handler\([^)]*\) /\* via struct Ops \+0x10 \*/"#, options: .regularExpression) != nil, after)

        // Mutating authoring creates a new snapshot identity; its fresh report uses the rename.
        var renamed = AddressOverride()
        renamed.customName = "on_event"
        snapshot.addressOverrides[ImageAddress(slot: .primary, address: 0x9040)] = renamed
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: false))
        _ = snapshot.imageWideIndirectCalls(in: .primary, compute: true)
        XCTAssertTrue(Self.render(snapshot).contains("on_event("))
        snapshot.addressOverrides[ImageAddress(slot: .primary, address: 0x3000)] = nil
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: false))
    }

    func testColdMemoRendersFunctionLocalOnly() {
        let snapshot = Self.typedSnapshot()
        XCTAssertFalse(Self.render(snapshot).contains("/* via"))
        XCTAssertTrue(Self.render(snapshot, at: 0x5000).contains("/* via x0+0x18 */"))
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: false), "rendering must never warm the memo")
    }

    func testOverCapImageRendersFunctionLocalOnly() {
        var snapshot = Self.typedSnapshot()
        snapshot.functions += (0..<WorkspaceSnapshot.maximumImageWideIndirectCallFunctions).map { index in
            FunctionSummary(id: UUID(), name: "f", startAddress: 0x10000 + UInt64(index * 4),
                            endAddress: 0x10004 + UInt64(index * 4), confidence: 1)
        }
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true))
        XCTAssertFalse(Self.render(snapshot).contains("/* via"))
        XCTAssertTrue(Self.render(snapshot, at: 0x5000).contains("/* via x0+0x18 */"))
    }

    func testNewSnapshotDoesNotReuseOldReport() {
        let original = Self.typedSnapshot(includingLocalCaller: false)
        XCTAssertNotNil(original.imageWideIndirectCalls(in: .primary, compute: true))
        let fresh = WorkspaceSnapshot(binaries: original.binaries, analysisBySlot: original.analysisBySlot,
                                      addressOverrides: original.addressOverrides, typeDefinitions: original.typeDefinitions)
        XCTAssertNil(fresh.imageWideIndirectCalls(in: .primary, compute: false))
        XCTAssertFalse(Self.render(fresh).contains("/* via"))
        var changed = original
        changed.instructions[1].operands = "x9, x9, #0x80"
        XCTAssertNil(changed.imageWideIndirectCalls(in: .primary, compute: false))
        XCTAssertFalse(Self.render(changed).contains("/* via"))
        XCTAssertTrue(Self.render(original).contains("/* via struct Ops +0x10 */"))
    }

    func testExportAndScriptingWarmIdenticalRenderingAndPreserveLocalText() {
        let exported = Self.typedSnapshot(), scripted = Self.typedSnapshot()
        let localBefore = Self.render(exported, at: 0x5000)
        let text = DocumentExportService().renderAllPseudocode(snapshot: exported)
        _ = WorkspaceScriptingAPI.indirectCallTargets(snapshot: scripted, function: scripted.functions[1])
        // The local caller's opaque callee may mutate Ops after its local load.
        // Local proof survives; the separate dispatcher's typed proof must refuse.
        XCTAssertFalse(text.contains("/* via struct Ops +0x10 */"))
        XCTAssertFalse(Self.render(exported).contains("/* via struct Ops"))
        XCTAssertEqual(Self.render(exported), Self.render(scripted))
        XCTAssertEqual(Self.render(exported, at: 0x5000), localBefore)
        XCTAssertEqual(Self.render(scripted, at: 0x5000), localBefore)

        // With no other call capable of writing the object, both consumers still
        // publish the typed result. Do not hide the mixed-image refusal above.
        let typedExport = Self.typedSnapshot(includingLocalCaller: false)
        let typedScript = Self.typedSnapshot(includingLocalCaller: false)
        let typedText = DocumentExportService().renderAllPseudocode(snapshot: typedExport)
        _ = WorkspaceScriptingAPI.indirectCallTargets(snapshot: typedScript, function: typedScript.functions[1])
        XCTAssertTrue(typedText.contains("/* via struct Ops +0x10 */"))
        XCTAssertEqual(Self.render(typedExport), Self.render(typedScript))
    }

    @MainActor func testCancelledComputationDoesNotPublish() async {
        let snapshot = Self.typedSnapshot()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return snapshot.imageWideIndirectCalls(in: .primary, compute: true)
        }
        let report = await task.value
        XCTAssertNil(report)
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: false))
        XCTAssertFalse(Self.render(snapshot).contains("/* via"))
        XCTAssertTrue(Self.render(snapshot, at: 0x5000).contains("/* via x0+0x18 */"))
    }

    func testCancellationDuringBuildDiscardsReport() async {
        let memo = IndirectCallResolutionMemo()
        let key = IndirectCallResolutionMemo.Key(snapshotID: UUID(), slot: .primary)
        let task = Task {
            memo.report(for: key) {
                withUnsafeCurrentTask { $0?.cancel() }
                return MacIRIndirectTargetResolution.Report(resolutions: [], refusals: [])
            }
        }
        let report = await task.value
        XCTAssertNil(report)
        XCTAssertNil(memo.report(for: key))
    }

    func testMemoSerializesBuildersAndDoesNotPublishIncompleteReport() {
        let memo = IndirectCallResolutionMemo()
        let key = IndirectCallResolutionMemo.Key(snapshotID: UUID(), slot: .primary)
        let calls = LockedBuildCount()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            _ = memo.report(for: key) {
                calls.increment()
                return MacIRIndirectTargetResolution.Report(resolutions: [], refusals: [])
            }
        }
        XCTAssertEqual(calls.value, 1)
        XCTAssertNotNil(memo.report(for: key))
        let incomplete = IndirectCallResolutionMemo.Key(snapshotID: UUID(), slot: .primary)
        XCTAssertNil(memo.report(for: incomplete) { nil })
        XCTAssertNil(memo.report(for: incomplete) {
            XCTFail("an incomplete attempt must not be retried")
            return MacIRIndirectTargetResolution.Report(resolutions: [], refusals: [])
        })
    }
}

private final class LockedBuildCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// B10: slot identity includes the complete memory extent and every possible writer.
final class IndirectTargetWriteSeparationTests: XCTestCase {
    private let handler: UInt64 = 0x9040
    private let install = [("adrp", "x9, 0x9000"), ("add", "x9, x9, #0x40"), ("str", "x9, [x0, #0x18]")]
    private let dispatch = [("ldr", "x8, [x0, #0x18]"), ("blr", "x8"), ("ret", "")]

    private func build(_ start: UInt64, typed: Bool, _ rows: [(String, String)]) -> MacIRFunction {
        let instructions = rows.enumerated().map { index, row in
            InstructionRow(address: start + UInt64(index * 4), bytes: "", mnemonic: row.0,
                           operands: row.1, hasBreakpoint: false, comment: nil)
        }
        let signatures: [UInt64: FunctionSignatureOverride] = typed ?
            [start: .init(args: [.init(index: 0, name: "ops", type: "struct Ops *")])] : [:]
        return PseudocodePrinter().buildFunction(functionName: "_case", startAddress: start,
                                                signatureOverrides: signatures, instructions: instructions)
    }

    func testLocalAndTypedFallbackRefuseOverlappingAliasedAndUnknownWrites() {
        let writes = [
            ("overlap", [("str", "w2, [x0, #0x1c]")]),
            ("same-start-narrow", [("str", "w2, [x0, #0x18]")]),
            ("aliased-parameter", [("str", "w2, [x1, #0x18]")]),
            ("untraceable", [("str", "w2, [x12]")]),
            ("indexed", [("str", "w2, [x0, x1]")]),
        ]
        for typed in [false, true] {
            for (label, write) in writes {
                let function = build(0x1000, typed: typed, install + write + dispatch)
                let report = MacIRIndirectTargetResolution.resolve(functions: [function], functionStarts: [handler])
                XCTAssertEqual(report.refusals.count, 1, "\(label), typed=\(typed): \(report)")
                XCTAssertTrue(report.resolutions.isEmpty, "\(label), typed=\(typed): \(report)")
            }
        }
    }

    func testDisjointWriteStillResolvesLocallyAndAcrossTypedFunctions() {
        let installer = build(0x1000, typed: true, install + [("str", "w2, [x0, #0x20]"), ("ret", "")])
        let local = build(0x2000, typed: false, install + [("str", "w2, [x0, #0x20]")] + dispatch)
        let caller = build(0x3000, typed: true, dispatch)
        let localReport = MacIRIndirectTargetResolution.resolve(functions: [local], functionStarts: [handler])
        XCTAssertEqual(localReport.resolutions.map(\.target), [handler], "\(localReport)")
        XCTAssertEqual(localReport.resolutions.map(\.scope), [.function(0x2000)])
        let typedReport = MacIRIndirectTargetResolution.resolve(functions: [installer, caller], functionStarts: [handler])
        XCTAssertEqual(typedReport.resolutions.map(\.target), [handler], "\(typedReport)")
        XCTAssertEqual(typedReport.resolutions.map(\.scope), [.type("Ops")])
    }

    func testOpaqueCallAfterInstallationPoisonsImageWideTypedSlot() {
        let installer = build(0x1000, typed: true, install + [("bl", "_opaque"), ("ret", "")])
        let caller = build(0x3000, typed: true, dispatch)
        let report = MacIRIndirectTargetResolution.resolve(functions: [installer, caller], functionStarts: [handler])
        XCTAssertTrue(report.resolutions.isEmpty, "_opaque may overwrite Ops+0x18: \(report)")
        XCTAssertEqual(report.refusals.map(\.reason), [.poisoned])
    }

    func testOtherCallsCannotSupplyAnImageWideNoWriteProof() {
        let caller = build(0x3000, typed: true, dispatch)
        let effects: [[(String, String)]] = [
            install + [("mov", "x0, #0"), ("bl", "_opaque"), ("ret", "")],
            install + [("blr", "x12"), ("ret", "")],
            install + [("bl", "0x9040"), ("ret", "")],
            [("mov", "x19, x0"), ("bl", "_opaque"), ("mov", "x0, x19")] + install + [("ret", "")],
        ]
        for rows in effects {
            let writer = build(0x1000, typed: true, rows)
            let report = MacIRIndirectTargetResolution.resolve(functions: [writer, caller], functionStarts: [handler])
            XCTAssertFalse(report.resolutions.contains { $0.functionStart == 0x3000 }, "\(rows): \(report)")
            XCTAssertEqual(report.refusals.first { $0.functionStart == 0x3000 }?.reason, .poisoned)
        }
        // A function with no explicit store may still forward a typed pointer or
        // unknown arguments to a writer. Such calls must enter the writer inventory.
        for typed in [false, true] {
            let installer = build(0x1000, typed: true, install + [("ret", "")])
            let forwarder = build(0x2000, typed: typed, [("bl", "_opaque"), ("ret", "")])
            let report = MacIRIndirectTargetResolution.resolve(functions: [installer, forwarder, caller], functionStarts: [handler])
            XCTAssertTrue(report.resolutions.isEmpty, "typed=\(typed): \(report)")
            XCTAssertEqual(report.refusals.map(\.reason), [.poisoned])
        }
    }

    func testImageWideTypedResolutionRefusesMayAliasWrites() {
        for write in [[("str", "w2, [x0, #0x1c]")], [("str", "w2, [x1]")], [("str", "w2, [x12]")]] {
            let installer = build(0x1000, typed: true, install + write + [("ret", "")])
            let caller = build(0x3000, typed: true, dispatch)
            let report = MacIRIndirectTargetResolution.resolve(functions: [installer, caller], functionStarts: [handler])
            XCTAssertTrue(report.resolutions.isEmpty, "\(write): \(report)")
            XCTAssertEqual(report.refusals.count, 1)
        }
    }

    func testNestedPointerReplacementInvalidatesLocalAndTypedSlotIdentity() {
        for typed in [false, true] {
            let prefix = [("adrp", "x9, 0x9000"), ("add", "x9, x9, #0x40"),
                          ("ldr", "x10, [x0, #0x8]"), ("str", "x9, [x10, #0x18]"),
                          ("str", "x2, [x0, #0x8]")]
            let suffix = [("ldr", "x11, [x0, #0x8]"), ("ldr", "x8, [x11, #0x18]"), ("blr", "x8"), ("ret", "")]
            let local = build(0x1000, typed: typed, prefix + suffix)
            let localReport = MacIRIndirectTargetResolution.resolve(functions: [local], functionStarts: [handler])
            XCTAssertTrue(localReport.resolutions.isEmpty, "typed=\(typed): \(localReport)")
            XCTAssertEqual(localReport.refusals.count, 1)
            if typed {
                let installer = build(0x2000, typed: true, prefix + [("ret", "")])
                let caller = build(0x3000, typed: true, suffix)
                let report = MacIRIndirectTargetResolution.resolve(functions: [installer, caller], functionStarts: [handler])
                XCTAssertTrue(report.resolutions.isEmpty, "\(report)")
                XCTAssertEqual(report.refusals.count, 1)
            }
        }
    }

    func testMissingStoreWidthCannotProveCompletePointer() {
        var function = build(0x1000, typed: true, install + dispatch)
        for index in function.instructions.indices {
            if case .store = function.instructions[index].operation { function.instructions[index].memoryAccess = nil }
        }
        let report = MacIRIndirectTargetResolution.resolve(functions: [function], functionStarts: [handler])
        XCTAssertTrue(report.resolutions.isEmpty, "\(report)")
        XCTAssertEqual(report.refusals.count, 1)
    }
}

extension IndirectTargetWriteSeparationTests {
    func testCallInvalidatesNestedDependencyBeforeInstallation() {
        let prefix = [("mov", "x20, x0"), ("ldr", "x19, [x0, #0x8]"), ("bl", "_may_replace_object"),
                      ("adrp", "x9, 0x9000"), ("add", "x9, x9, #0x40"), ("str", "x9, [x19, #0x18]"),
                      ("mov", "x0, x20")]
        let suffix = [("ldr", "x11, [x0, #0x8]"), ("ldr", "x8, [x11, #0x18]"), ("blr", "x8"), ("ret", "")]
        for typed in [false, true] {
            let local = build(0x1000, typed: typed, prefix + suffix)
            XCTAssertTrue(MacIRIndirectTargetResolution.resolve(functions: [local], functionStarts: [handler]).resolutions.isEmpty)
        }
        let installer = build(0x1000, typed: true, prefix + [("ret", "")])
        let caller = build(0x2000, typed: true, suffix)
        XCTAssertTrue(MacIRIndirectTargetResolution.resolve(functions: [installer, caller], functionStarts: [handler]).resolutions.isEmpty)
    }

    func testTwoSameTypedRootsCannotProveOffsetSeparation() {
        let rows = install + [("str", "w2, [x1, #0x20]"), ("ret", "")]
        let instructions = rows.enumerated().map { index, row in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "", mnemonic: row.0,
                           operands: row.1, hasBreakpoint: false, comment: nil)
        }
        let signature = FunctionSignatureOverride(args: [
            .init(index: 0, name: "a", type: "struct Ops *"),
            .init(index: 1, name: "b", type: "struct Ops *")])
        let installer = PseudocodePrinter().buildFunction(functionName: "_install", startAddress: 0x1000,
                                                          signatureOverrides: [0x1000: signature], instructions: instructions)
        let caller = build(0x2000, typed: true, dispatch)
        let report = MacIRIndirectTargetResolution.resolve(functions: [installer, caller], functionStarts: [handler])
        XCTAssertTrue(report.resolutions.isEmpty, "different typed roots may be shifted aliases: \(report)")
        XCTAssertEqual(report.refusals.count, 1)
    }

    func testWarmImageWideConsumerRefusesOverlapsAliasesAndNestedReplacement() {
        let nestedInstall = [("ldr", "x10, [x0, #0x8]"), ("adrp", "x9, 0x9000"), ("add", "x9, x9, #0x40"),
                             ("str", "x9, [x10, #0x18]"), ("str", "x2, [x0, #0x8]"), ("ret", "")]
        let nestedDispatch = [("ldr", "x10, [x0, #0x8]"), ("ldr", "x8, [x10, #0x18]"), ("blr", "x8"), ("ret", "")]
        let cases: [([(String, String)], [(String, String)], Bool)] = [
            (install + [("str", "w2, [x0, #0x1c]"), ("ret", "")], dispatch, false),
            (install + [("str", "w2, [x1]"), ("ret", "")], dispatch, false),
            (install + [("str", "w2, [x12]"), ("ret", "")], dispatch, false),
            (nestedInstall, nestedDispatch, false),
            (install + [("bl", "_opaque"), ("ret", "")], dispatch, false),
            (install + [("str", "w2, [x0, #0x20]"), ("ret", "")], dispatch, true),
        ]
        for (installer, caller, resolves) in cases {
            var analysis = ImageAnalysis()
            let functions: [(UInt64, String, [(String, String)])] = [
                (0x1000, "_install", installer), (0x2000, "_dispatch", caller), (handler, "_handler", [("ret", "")])
            ]
            for (start, name, rows) in functions {
                analysis.functions.append(.init(id: UUID(), name: name, startAddress: start,
                                                endAddress: start + UInt64(rows.count * 4), confidence: 1))
                analysis.instructions += rows.enumerated().map { index, row in
                    InstructionRow(address: start + UInt64(index * 4), bytes: "", mnemonic: row.0,
                                   operands: row.1, hasBreakpoint: false, comment: nil)
                }
            }
            var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
            snapshot.insertImage(binary: .init(id: UUID(), name: "defensive-ir", path: "/tmp/defensive-ir",
                                               kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
            for start: UInt64 in [0x1000, 0x2000] {
                var value = AddressOverride()
                value.signature = .init(args: [.init(index: 0, name: "ops", type: "struct Ops *")])
                snapshot.addressOverrides[.init(slot: .primary, address: start)] = value
            }
            let report = snapshot.imageWideIndirectCalls(in: .primary, compute: true)
            XCTAssertNotNil(report)
            XCTAssertEqual(report?.resolutions.count, resolves ? 1 : 0, "\(installer): \(String(describing: report))")
            let rendered = PseudocodeView.document(for: snapshot.pseudocodeRenderInput(selectedAddress: 0x2000, in: .primary),
                                                   options: .default).text
            XCTAssertEqual(rendered.contains("/* via struct Ops"), resolves, rendered)
        }
    }
}
