import XCTest
@testable import MacScope

/// C1 contracts: these defensive fixtures exercise the actual lifted IR.
extension IndirectTargetWriteSeparationTests {
    private func c1Function(_ start: UInt64, type: String? = nil,
                            _ rows: [(String, String)]) -> MacIRFunction {
        let instructions = rows.enumerated().map { index, row in
            let address = start + UInt64(index * 4)
            var bytes = ""
            if row.0 == "bl", row.1.hasPrefix("0x"), let target = UInt64(row.1.dropFirst(2), radix: 16) {
                let delta = (Int64(target) - Int64(address)) / 4
                let word = 0x9400_0000 | (UInt32(truncatingIfNeeded: delta) & 0x03ff_ffff)
                bytes = (0..<4).map { String(format: "%02x", UInt8(truncatingIfNeeded: word >> (8 * $0))) }.joined(separator: " ")
            }
            return InstructionRow(address: address, bytes: bytes, mnemonic: row.0,
                                  operands: row.1, hasBreakpoint: false, comment: nil)
        }
        let signatures: [UInt64: FunctionSignatureOverride] = type.map {
            [start: .init(args: [.init(index: 0, name: "object", type: "struct \($0) *")])]
        } ?? [:]
        return PseudocodePrinter().buildFunction(functionName: "_c1_\(start)", startAddress: start,
                                                signatureOverrides: signatures, instructions: instructions)
    }

    private var c1Install: [(String, String)] {
        [("mov", "x9, #0x9040"), ("str", "x9, [x0, #0x18]")]
    }

    private var c1Dispatch: [(String, String)] {
        [("ldr", "x8, [x0, #0x18]"), ("blr", "x8"), ("ret", "")]
    }

    private func c1Report(_ additional: [MacIRFunction],
                          installerSuffix: [(String, String)] = [("ret", "")],
                          extraStarts: Set<UInt64> = []) -> MacIRIndirectTargetResolution.Report {
        let functions = [c1Function(0x1000, type: "T", c1Install + installerSuffix),
                         c1Function(0x2000, type: "T", c1Dispatch)] + additional
        return MacIRIndirectTargetResolution.resolve(
            functions: functions, functionStarts: Set(functions.map(\.startAddress)).union([0x9040]).union(extraStarts))
    }

    private func c1AssertTyped(_ report: MacIRIndirectTargetResolution.Report,
                               file: StaticString = #filePath, line: UInt = #line) {
        let resolved = report.resolutions.first { $0.functionStart == 0x2000 }
        XCTAssertEqual(resolved?.target, 0x9040, "\(report)", file: file, line: line)
        XCTAssertEqual(resolved?.scope, .type("T"), "\(report)", file: file, line: line)
    }

    private func c1AssertPoisoned(_ report: MacIRIndirectTargetResolution.Report,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(report.resolutions.contains { $0.functionStart == 0x2000 }, "\(report)", file: file, line: line)
        XCTAssertEqual(report.refusals.first { $0.functionStart == 0x2000 }?.reason, .poisoned,
                       "\(report)", file: file, line: line)
    }

    private func c1Decoded(_ words: [UInt32], at start: UInt64 = 0x3000) -> MacIRFunction {
        let data = Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } })
        let rows = ARM64Decoder(validateStructuredOperands: true).decode(data, baseAddress: start).map { InstructionRow(decoded: $0) }
        return PseudocodePrinter().buildFunction(functionName: "_c1_decoded", startAddress: start, instructions: rows)
    }

    // Case 1: the complete 16-byte prologue write is below entry SP.
    func testC1FrameLocalPairWriteAllowsTypedResolution() {
        let frame = c1Decoded([0xa9bf7bfd, 0x910003fd, 0xa8c17bfd, 0xd65f03c0])
        c1AssertTyped(c1Report([frame]))
    }

    // Case 2: the leaf's entire body is already in the writer inventory.
    func testC1VisibleLeafCallAllowsTypedResolution() {
        let caller = c1Function(0x3000, [("bl", "0x4000"), ("ret", "")])
        let leaf = c1Function(0x4000, [("ret", "")])
        c1AssertTyped(c1Report([caller, leaf]))
    }

    // Case 3: a closed recursive component is visible at the greatest fixpoint.
    func testC1VisibleMutualRecursionAllowsTypedResolution() {
        let first = c1Function(0x3000, [("bl", "0x4000"), ("ret", "")])
        let second = c1Function(0x4000, [("bl", "0x3000"), ("ret", "")])
        c1AssertTyped(c1Report([first, second]))
    }

    // Case 4: a function-start address alone is not an analyzed callee contract.
    func testC1ImportAndNonAnalyzedCallsRemainPoisoned() {
        for target in ["_external_stub", "0x5000"] {
            let caller = c1Function(0x3000, [("bl", target), ("ret", "")])
            c1AssertPoisoned(c1Report([caller], extraStarts: [0x5000]))
        }
    }

    // Case 5: indirect calls never enter the visible direct-call graph.
    func testC1IndirectCallRemainsPoisoned() {
        let caller = c1Function(0x3000, [("blr", "x12"), ("ret", "")])
        c1AssertPoisoned(c1Report([caller]))
    }

    // Case 6: incoming argument storage belongs to the caller, not this frame.
    func testC1IncomingStackArgumentWriteRemainsPoisoned() {
        let writer = c1Decoded([0xf9000be9, 0xd65f03c0])
        c1AssertPoisoned(c1Report([writer]))
    }

    // Case 7: visibility does not excuse any callee's foreign-root store.
    func testC1VisibleForeignTypeWriterRemainsPoisoned() {
        let caller = c1Function(0x3000, [("bl", "0x4000"), ("ret", "")])
        let writer = c1Function(0x4000, type: "Foreign", [("str", "x9, [x0, #0x18]"), ("ret", "")])
        c1AssertPoisoned(c1Report([caller, writer]))
    }

    // Case 8: preserve the #768 installer-then-opaque-call regression.
    func testC1OpaqueCallAfterInstallerRemainsPoisoned() {
        c1AssertPoisoned(c1Report([], installerSuffix: [("bl", "_opaque"), ("ret", "")]))
    }

    // Case 9: visible callees are still barriers to the local reaching proof.
    func testC1VisibleCallStillBlocksLocalReachingProof() {
        // Keep the object across the ABI call clobber so this tests the local
        // memory barrier, rather than losing the slot's parameter provenance.
        let local = c1Function(0x1000, type: "T", [("mov", "x19, x0")] + c1Install
                               + [("bl", "0x4000"), ("mov", "x0, x19")] + c1Dispatch)
        let leaf = c1Function(0x4000, [("ret", "")])
        let report = MacIRIndirectTargetResolution.resolve(functions: [local, leaf], functionStarts: [0x1000, 0x4000, 0x9040])
        XCTAssertTrue(report.resolutions.isEmpty, "\(report)")
        XCTAssertEqual(report.refusals.first { $0.functionStart == 0x1000 }?.reason, .notDominating)
    }

    // A1: a live frame-local T can carry a different target into the dispatcher.
    func testC1FrameAddressPassedToDispatcherPoisonsAllFrameWrites() {
        let installer = c1Function(0x1000, type: "T", [
            ("mov", "x9, #0x9040"), ("str", "x9, [x0, #8]"), ("ret", "")])
        let dispatcher = c1Function(0x2000, type: "T", [
            ("ldr", "x8, [x0, #8]"), ("blr", "x8"), ("ret", "")])
        // sub sp,sp,#32; adrp/add x8,0xa000; str x8,[sp,#24]; add x0,sp,#16
        let prefix: [UInt32] = [0xd10083ff, 0xf0000028, 0x91000108, 0xf9000fe8, 0x910043e0]
        let call = UInt32(0x94000000) | (UInt32(truncatingIfNeeded: (Int64(0x2000) - 0x3014) / 4) & 0x03ffffff)
        // Also isolate the escape from the independent opaque-call refusal.
        for suffix: [UInt32] in [[call, 0x910083ff, 0xd65f03c0], [0x910083ff, 0xd65f03c0]] {
            let writer = c1Decoded(prefix + suffix)
            c1AssertPoisoned(MacIRIndirectTargetResolution.resolve(
                functions: [installer, dispatcher, writer], functionStarts: [0x1000, 0x2000, 0x3000, 0x9040, 0xa000]))
        }
    }

    // A2: frame-pointer setup is allowed, but using its value exposes the frame.
    func testC1FramePointerDerivedArgumentPoisonsAllFrameWrites() {
        // sub sp,sp,#32; str x9,[sp,#16]; mov x29,sp; sub x0,x29,#16; ret
        c1AssertPoisoned(c1Report([c1Decoded([0xd10083ff, 0xf9000be9, 0x910003fd, 0xd10043a0, 0xd65f03c0])]))
    }

    // A3: an SP-derived value stored into memory cannot retain frame exemption.
    func testC1StoredFrameAddressPoisonsAllFrameWrites() {
        // sub sp,sp,#32; str x9,[sp,#16]; add x8,sp,#8; str x8,[sp]; ret
        c1AssertPoisoned(c1Report([c1Decoded([0xd10083ff, 0xf9000be9, 0x910023e8, 0xf90003e8, 0xd65f03c0])]))
    }

    func testC1SavedFramePointerReloadCannotHideEscape() {
        // Save derived x29 in the frame, then reload it into an ordinary argument.
        let prefix: [UInt32] = [0xd10083ff, 0x910003fd, 0xa9bf7bfd]
        for reload in [UInt32(0xf94003e0), UInt32(0xa8c17be0)] {
            // ldr x0,[sp] OR ldp x0,x30,[sp],#16; add x1,x0,#8; ret
            c1AssertPoisoned(c1Report([c1Decoded(prefix + [reload, 0x91002001, 0xd65f03c0])]))
        }
        // The original x29/x30 restoration does not export the saved pointer.
        c1AssertTyped(c1Report([c1Decoded(prefix + [0xa8c17bfd, 0x910083ff, 0xd65f03c0])]))
    }

    // B1: an excluded conditional destination can contain unaccounted writes.
    func testC1ConditionalExitMakesCalleeOpaque() {
        let caller = c1Function(0x3000, [("bl", "0x4000"), ("ret", "")])
        for target in ["0x5000", "_unparsed_exit"] {
            let helper = c1Function(0x4000, [("cbz", "x0, \(target)"), ("ret", "")])
            c1AssertPoisoned(c1Report([caller, helper], extraStarts: [0x5000]))
        }
    }

    // B2: both the taken edge and fallthrough stay within the analyzed helper.
    func testC1InternalConditionalRemainsVisible() {
        let caller = c1Function(0x3000, [("bl", "0x4000"), ("ret", "")])
        let helper = c1Function(0x4000, [("cbz", "x0, 0x4008"), ("ret", ""), ("ret", "")])
        c1AssertTyped(c1Report([caller, helper]))
    }

    func testC1SwitchExitsRequireEveryTargetInsideBody() {
        let caller = c1Function(0x3000, [("bl", "0x4000"), ("ret", "")])
        for target: MacIRValue in [.immediate(0x5000), .unknown("exit")] {
            var helper = c1Function(0x4000, [("br", "x8"), ("ret", "")])
            helper.instructions[0].operation = .switchDispatch(index: .register(name: "x0", version: 0),
                cases: [.init(value: 0, target: target)], defaultTarget: .immediate(0x4004))
            c1AssertPoisoned(c1Report([caller, helper]))
            helper.instructions[0].operation = .switchDispatch(index: .register(name: "x0", version: 0),
                cases: [.init(value: 0, target: .immediate(0x4004))], defaultTarget: target)
            c1AssertPoisoned(c1Report([caller, helper]))
        }
    }

    func testC1NonABIReturnTargetsMakeCalleeOpaque() {
        let caller = c1Function(0x3000, [("bl", "0x4000"), ("ret", "")])
        for exit in [("ret", "x8"), ("ret", "x29"), ("eret", "")] {
            c1AssertPoisoned(c1Report([caller, c1Function(0x4000, [exit])]))
        }
        // A return-target read is not preserved by returnValue's result operand.
        let frame = c1Decoded([0xd10083ff, 0xf9000be9, 0x910003fd, 0xd65f03a0])
        c1AssertPoisoned(c1Report([frame]))
    }

    func testC1AuthenticatedReturnSPReadPoisonsFrameWrites() {
        for (word, mnemonic) in [(UInt32(0xd65f0bff), "retaa"), (UInt32(0xd65f0fff), "retab")] {
            let frame = c1Decoded([0xd10083ff, 0xf9000be9, 0x910083ff, word])
            XCTAssertEqual(frame.instructions.last?.source.mnemonic, mnemonic)
            c1AssertPoisoned(c1Report([frame]))
        }
    }

    func testC1ImmediateAllocationSpillAndFreeAreFrameLocal() {
        // sub sp,sp,#32; str x9,[sp,#16]; add sp,sp,#32; ret
        c1AssertTyped(c1Report([c1Decoded([0xd10083ff, 0xf9000be9, 0x910083ff, 0xd65f03c0])]))
    }

    func testC1PairFullExtentAndPostIndexUseActualAccessAddress() {
        // A 16-byte pair at entrySP-8 crosses the boundary.
        c1AssertPoisoned(c1Report([c1Decoded([0xa9bffbfd, 0xd65f03c0])]))
        // Post-index stores at old SP, even when updated SP is below entry SP.
        c1AssertPoisoned(c1Report([c1Decoded([0xa8bf7bfd, 0xd65f03c0])]))
        // Allocate 32, then post-index pair at -32 and update SP to -16.
        c1AssertTyped(c1Report([c1Decoded([0xd10083ff, 0xa8817bfd, 0xd65f03c0])]))
    }

    func testC1FrameAliasAndUnknownSPRemainUnsupported() {
        // sub sp,sp,#32; mov x29,sp; str x9,[x29,#16]; ret
        c1AssertPoisoned(c1Report([c1Decoded([0xd10083ff, 0x910003fd, 0xf9000ba9, 0xd65f03c0])]))
        // A non-SP restore destroys authority, even after a known allocation.
        c1AssertPoisoned(c1Report([c1Decoded([0xd10083ff, 0x910003bf, 0xf90003e9, 0xd65f03c0])]))
        var frame = c1Decoded([0xd10083ff, 0xf9000be9, 0xd65f03c0])
        if case let .intrinsic(destination, name, _) = frame.instructions[0].operation {
            frame.instructions[0].operation = .intrinsic(destination: destination, name: name,
                                                        arguments: [.register(name: "x12", version: 0)])
        } else { XCTFail("expected stack_alloc") }
        c1AssertPoisoned(c1Report([frame]))
    }

    func testC1MissingAndMismatchedMemorySidecarsRemainUnsupported() {
        var frame = c1Decoded([0xa9bf7bfd, 0xd65f03c0])
        frame.instructions[0].source.structuredOperands = nil
        c1AssertPoisoned(c1Report([frame]))
        frame = c1Decoded([0xa9bf7bfd, 0xd65f03c0])
        frame.instructions[0].source.operands = "x29, x30, [sp, #-32]!"
        c1AssertPoisoned(c1Report([frame]))
    }

    func testC1SymbolicCallUsesBLBytesAndRejectsMissingOrNonBLBytes() {
        let rows = [InstructionRow(address: 0x3000, bytes: "00 04 00 94", mnemonic: "bl",
                                   operands: "_symbolized_leaf", hasBreakpoint: false, comment: nil),
                    InstructionRow(address: 0x3004, bytes: "c0 03 5f d6", mnemonic: "ret",
                                   operands: "", hasBreakpoint: false, comment: nil)]
        var caller = PseudocodePrinter().buildFunction(functionName: "caller", startAddress: 0x3000, instructions: rows)
        let leaf = c1Function(0x4000, [("ret", "")])
        c1AssertTyped(c1Report([caller, leaf]))
        for bytes in ["", "00 04 00 14", "00 00 3f d6", "00 04 00"] {
            caller.instructions[0].source.byteText = bytes
            c1AssertPoisoned(c1Report([caller, leaf]))
        }
    }

    func testC1AnalyzedCalleeMustAlsoBeAFunctionStart() {
        let caller = c1Function(0x3000, [("bl", "0x4000"), ("ret", "")])
        let leaf = c1Function(0x4000, [("ret", "")])
        let installer = c1Function(0x1000, type: "T", c1Install + [("ret", "")])
        let dispatcher = c1Function(0x2000, type: "T", c1Dispatch)
        c1AssertPoisoned(MacIRIndirectTargetResolution.resolve(functions: [installer, dispatcher, caller, leaf],
                                                               functionStarts: [0x1000, 0x2000, 0x3000, 0x9040]))
    }

    func testC1OpaqueEdgePoisonsRecursiveComponentTransitively() {
        let first = c1Function(0x3000, [("bl", "0x4000"), ("ret", "")])
        let second = c1Function(0x4000, [("bl", "0x3000"), ("bl", "0x5000"), ("ret", "")])
        c1AssertPoisoned(c1Report([first, second], extraStarts: [0x5000]))
    }

    func testC1FrameExemptionDoesNotRelaxLocalClobbers() {
        var local = c1Function(0x1000, type: "T", c1Install + c1Dispatch)
        let frame = c1Decoded([0xd10083ff])
        local.instructions.insert(contentsOf: frame.instructions, at: 0)
        let report = MacIRIndirectTargetResolution.resolve(functions: [local], functionStarts: [0x9040])
        XCTAssertTrue(report.resolutions.isEmpty)
        XCTAssertEqual(report.refusals.first?.reason, .poisoned)
    }
}
