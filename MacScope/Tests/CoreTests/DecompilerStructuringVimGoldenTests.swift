import Foundation
import XCTest
@testable import MacScope

/// Opt-in real-input checks. CP2_ROOT points at the unzipped CP2 or CP6 task
/// package; CP2_HANDBACK may point at a separately extracted handback directory.
/// This is deliberately not a synthetic reconstruction of the unavailable Widget.
final class DecompilerStructuringVimGoldenTests: XCTestCase {
    private func roots() throws -> (URL, URL) {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["CP2_ROOT"] else { throw XCTSkip("Set CP2_ROOT to the supplied Vim specimen package") }
        let input = URL(fileURLWithPath: root)
        let output = env["CP2_HANDBACK"].map { URL(fileURLWithPath: $0) } ?? input.appendingPathComponent("handback")
        return (input, output)
    }

    private func specimen(_ root: URL) -> URL {
        let current = root.appendingPathComponent("specimen/vim-arm64e")
        return FileManager.default.fileExists(atPath: current.path)
            ? current : root.appendingPathComponent("fixtures/specimen/vim-arm64e")
    }

    func testFrozenLinuxVimTextGoldens() throws {
        let (root, handback) = try roots()
        // The input package omits SDKCallSignaturePack.json. A Mac with that
        // resource has a different lifting/catalogue baseline; do not silently
        // re-bless its output against the Linux no-pack receipts.
        guard CallSignaturePack.bundled == nil else {
            throw XCTSkip("Frozen Linux text goldens require the recorded no-SDK-pack profile; use the semantic test with the Mac pack")
        }
        let snapshot = try AnalysisEngine(loader: MachOBinaryLoader(), decoder: ARM64Decoder()).analyze(
            url: specimen(root))
        // One successful loop repair, one successful guard/dominance repair,
        // and one real tail-class conservative fallback control.
        for address: UInt64 in [0x1000cc360, 0x100143bd8, 0x10001a8bc] {
            let input = snapshot.pseudocodeRenderInput(selectedAddress: address, in: snapshot.primarySlot)
            XCTAssertEqual(input.startAddress, address)
            let printer = PseudocodePrinter(options: .recoveryOn)
            let function = printer.buildFunction(functionName: input.functionName, startAddress: input.startAddress,
                jumpTables: input.jumpTables, objcSelectors: input.objcSelectors, constantStrings: input.constantStrings,
                signatureOverrides: input.signatureOverrides, instructions: input.instructions)
            let actual = printer.print(function: function, types: input.types, nameOverrides: input.nameOverrides,
                                       registerNameOverrides: input.registerNameOverrides)
            let key = "0x\(String(address, radix: 16))"
            let expected = try String(contentsOf: handback.appendingPathComponent("goldens/vim/\(key).c"), encoding: .utf8)
            XCTAssertEqual(actual.text + "\n", expected, key)
        }
    }

    func testRealVimRecoveryProofsAndLegacySwitches() throws {
        let (root, _) = try roots()
        let snapshot = try AnalysisEngine(loader: MachOBinaryLoader(), decoder: ARM64Decoder()).analyze(
            url: specimen(root))
        var provedCandidates = 0
        for address: UInt64 in [0x1000cc360, 0x100143bd8, 0x10001a8bc] {
            let input = snapshot.pseudocodeRenderInput(selectedAddress: address, in: snapshot.primarySlot)
            let printer = PseudocodePrinter(options: .recoveryOn)
            let function = printer.buildFunction(functionName: input.functionName, startAddress: input.startAddress,
                jumpTables: input.jumpTables, objcSelectors: input.objcSelectors, constantStrings: input.constantStrings,
                signatureOverrides: input.signatureOverrides, instructions: input.instructions)
            let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            let diagnosis = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
            var old = DecompilerOptions.default
            old.recoverSharedTails = false; old.recoverLoopExits = false; old.recoverGuardRegions = false
            let legacy = PseudocodePrinter(options: old).print(function: function)
            let actual = printer.print(function: function)
            let plan = diagnosis.diagnostics.fatalVeto.flatMap {
                RegionTree.recoveryPlan(cfg: cfg, instructions: function.instructions, options: .recoveryOn, veto: $0)
            }
            if let plan {
                provedCandidates += 1
                XCTAssertTrue(RegionTree.recoveryIsEquivalent(plan.root, to: cfg))
            }
            if legacy.structureFallback != nil && actual.structureFallback == nil {
                XCTAssertNotNil(plan)
                XCTAssertTrue(PseudocodePrinter.recoveryReadabilityAdmits(candidate: actual.lines,
                                                                         legacy: legacy.lines,
                                                                         startingAt: 0, options: .recoveryOn))
                XCTAssertLessThan(actual.text.components(separatedBy: "goto ").count,
                                  legacy.text.components(separatedBy: "goto ").count)
            } else { XCTAssertEqual(actual.text, legacy.text) }
        }
        XCTAssertGreaterThan(provedCandidates, 0, "the supplied loop/guard controls must exercise the proof even when readability rejects them")
    }

    /// The two vim functions recovery changes, against their reviewed Mac-profile renderings
    /// (`GoldenFixtures/cp2-structurer-recovery/`): shipped (recovery off) and recovery on.
    /// CP6 deliberately does not bless Mac bytes on Linux. Review the two
    /// recovery-on fixtures on the Mac after applying this change; fallback
    /// output may now equal the shipped fixture because of readability admission.
    func testMacProfileVimGoldens() throws {
        let (root, _) = try roots()
        guard CallSignaturePack.bundled != nil else {
            throw XCTSkip("The Mac goldens were recorded with the bundled SDK call-signature pack")
        }
        let goldens = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("GoldenFixtures/cp2-structurer-recovery", isDirectory: true)
        let snapshot = try AnalysisEngine(loader: MachOBinaryLoader(), decoder: ARM64Decoder()).analyze(
            url: specimen(root))
        for address: UInt64 in [0x1000cc360, 0x100143bd8] {
            let key = "0x\(String(address, radix: 16))"
            let (recovered, shipped) = renderings(snapshot, address)
            XCTAssertEqual(shipped.text + "\n", try String(contentsOf: goldens.appendingPathComponent("vim-\(key).shipped.c"), encoding: .utf8), key)
            XCTAssertEqual(recovered.text + "\n", try String(contentsOf: goldens.appendingPathComponent("vim-\(key).recovery-on.c"), encoding: .utf8), key)
        }
    }

    /// The pseudocode of one function with recovery explicitly on and with all three switches off.
    private func renderings(_ snapshot: WorkspaceSnapshot, _ address: UInt64) -> (recovered: PseudocodeDocument, legacy: PseudocodeDocument) {
        let input = snapshot.pseudocodeRenderInput(selectedAddress: address, in: snapshot.primarySlot)
        let printer = PseudocodePrinter(options: .recoveryOn)
        let function = printer.buildFunction(functionName: input.functionName, startAddress: input.startAddress,
            jumpTables: input.jumpTables, objcSelectors: input.objcSelectors, constantStrings: input.constantStrings,
            signatureOverrides: input.signatureOverrides, instructions: input.instructions)
        var old = DecompilerOptions.default
        old.recoverSharedTails = false; old.recoverLoopExits = false; old.recoverGuardRegions = false
        let legacy = PseudocodePrinter(options: old).print(function: function, types: input.types, nameOverrides: input.nameOverrides,
                                                           registerNameOverrides: input.registerNameOverrides)
        let recovered = printer.print(function: function, types: input.types, nameOverrides: input.nameOverrides,
                                      registerNameOverrides: input.registerNameOverrides)
        return (recovered, legacy)
    }

    /// The three Widget functions that already structure (CP2's controls, capture-only in the cloud):
    /// recovery never runs for them, so their text is byte-identical with the switches on or off.
    /// CP2_WIDGET points at the widget fixture binary.
    func testWidgetControlsAreByteIdentical() throws {
        guard let path = ProcessInfo.processInfo.environment["CP2_WIDGET"] else { throw XCTSkip("Set CP2_WIDGET to the widget fixture binary") }
        let snapshot = try AnalysisEngine(loader: MachOBinaryLoader(), decoder: ARM64Decoder()).analyze(url: URL(fileURLWithPath: path))
        for address: UInt64 in [0x100000908, 0x10000091c, 0x100000944] {
            let (recovered, legacy) = renderings(snapshot, address)
            XCTAssertNil(legacy.structureFallback, "0x\(String(address, radix: 16)) structures without recovery")
            XCTAssertEqual(recovered.text, legacy.text, "0x\(String(address, radix: 16))")
            try dump(recovered: recovered, legacy: legacy, name: "widget-0x\(String(address, radix: 16))")
        }
    }

    /// The sweep's 20 vim functions on this Mac's profile: when CP2_MAC_OUTPUT is set, writes each
    /// function's text with recovery on and off plus a summary, for review. Recovery must keep the
    /// text byte-identical or remove gotos with an equivalent plan.
    func testTwentyVimFunctionsOnThisProfile() throws {
        let (root, _) = try roots()
        guard ProcessInfo.processInfo.environment["CP2_MAC_OUTPUT"] != nil else { throw XCTSkip("Set CP2_MAC_OUTPUT to write the 20 renderings") }
        let snapshot = try AnalysisEngine(loader: MachOBinaryLoader(), decoder: ARM64Decoder()).analyze(
            url: specimen(root))
        let addresses: [UInt64] = [0x100004650, 0x10001a8bc, 0x100083ba0, 0x100088770, 0x10008f79c, 0x10009a470, 0x1000bd220,
                                   0x1000cc360, 0x1000cd1f0, 0x1000d768c, 0x10012df90, 0x100137dc4, 0x10013efb0, 0x100143bd8,
                                   0x10014adec, 0x100151718, 0x100158e4c, 0x10017a88c, 0x1001b3594, 0x100207b40]
        var summary = ["address\tgotos-before\tgotos-after\tlines-before\tlines-after\tresult"]
        for address in addresses {
            let (recovered, legacy) = renderings(snapshot, address)
            let key = "0x\(String(address, radix: 16))"
            let gotos = { (text: String) in text.components(separatedBy: "goto ").count - 1 }
            let lines = { (text: String) in text.split(separator: "\n", omittingEmptySubsequences: false).count }
            let identical = recovered.text == legacy.text
            if !identical {
                XCTAssertLessThan(gotos(recovered.text), gotos(legacy.text), key)
                XCTAssertNil(recovered.structureFallback, key)
            }
            summary.append("\(key)\t\(gotos(legacy.text))\t\(gotos(recovered.text))\t\(lines(legacy.text))\t\(lines(recovered.text))\t"
                + (identical ? "identical" : "recovered"))
            try dump(recovered: recovered, legacy: legacy, name: "vim-\(key)")
        }
        try dumpText(summary.joined(separator: "\n") + "\n", name: "vim-summary.tsv")
    }

    private func dump(recovered: PseudocodeDocument, legacy: PseudocodeDocument, name: String) throws {
        try dumpText(legacy.text + "\n", name: "\(name).legacy.c")
        try dumpText(recovered.text + "\n", name: "\(name).recovered.c")
    }

    private func dumpText(_ text: String, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["CP2_MAC_OUTPUT"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try text.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
