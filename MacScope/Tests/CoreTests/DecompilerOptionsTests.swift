import XCTest
import LumenUI
@testable import MacScope

/// Exercises the user-tunable `DecompilerOptions` end-to-end through the
/// `PseudocodePrinter`: each option must demonstrably change the emitted text
/// (and the defaults must reproduce the prior byte-for-byte output). Also covers
/// the pure `UserDefaults` readers for `DecompilerOptions` /
/// `MacScopeCodeFont` / `AppAppearancePreference`.
final class DecompilerOptionsTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String, _ comment: String? = nil) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: comment)
    }

    private func document(_ name: String, _ rows: [InstructionRow], options: DecompilerOptions) -> PseudocodeDocument {
        let function = MacIRBuilder().buildFunction(name: name, instructions: rows)
        return PseudocodePrinter(options: options).print(function: function)
    }

    // MARK: - structureControlFlow

    /// A reducible `if (cc) { <bodyCount> body instrs }` guard. With a body over
    /// 64 instructions the legacy peephole structurer's `maxInstructionDistance`
    /// cap cannot fold it (emits `goto`), while the region structurer has no such
    /// cap (no `goto`). This is the discriminating shape between the two paths.
    private func largeGuardedBody(bodyCount: Int) -> [InstructionRow] {
        var rows: [InstructionRow] = []
        let exitAddress: UInt64 = 0x1000 + UInt64(bodyCount + 1) * 4
        rows.append(row(0x1000, "cbz", "x0, 0x\(String(exitAddress, radix: 16))", "guard"))
        for i in 0..<bodyCount {
            rows.append(row(0x1000 + UInt64(i + 1) * 4, "nop", "", "b\(i)"))
        }
        rows.append(row(exitAddress, "ret", ""))
        return rows
    }

    func testDisablingStructuringForcesGotoForm() {
        // 100-instruction guarded body: only the region structurer can fold it
        // without goto, so the toggle is observable on the emitted text.
        let rows = largeGuardedBody(bodyCount: 100)

        let structured = document("_if", rows, options: .default)
        XCTAssertFalse(structured.text.contains("goto"), "default (structured) folds the large guard without goto")
        XCTAssertTrue(structured.text.contains("if ("))

        var gotoForm = DecompilerOptions.default
        gotoForm.structureControlFlow = false
        let raw = document("_if", rows, options: gotoForm)
        XCTAssertTrue(raw.text.contains("goto"), "structureControlFlow=false uses the legacy path, which emits goto past its cap")
    }

    // MARK: - nopElision

    func testNopElisionDropsNopLines() {
        let rows = [
            row(0x1000, "nop", "", "pad"),
            row(0x1004, "nop", "", "pad"),
            row(0x1008, "ret", "")
        ]

        let withNops = document("_n", rows, options: .default)
        XCTAssertTrue(withNops.text.contains("__nop()"), "default must render nop intrinsics")

        var elide = DecompilerOptions.default
        elide.nopElision = true
        let elided = document("_n", rows, options: elide)
        XCTAssertFalse(elided.text.contains("__nop()"), "nopElision must drop __nop() lines")
        // The non-nop content survives.
        XCTAssertTrue(elided.text.contains("return"))
    }

    // MARK: - deadCodeElimination

    func testDeadCodeEliminationDropsInstructionsAfterReturn() {
        // A straight-line function with instructions textually AFTER a return.
        // `add` ops are emitted as binary statements; after the early `ret` they
        // are unreachable and dropped only when the option is on.
        let rows = [
            row(0x1000, "ret", ""),
            row(0x1004, "add", "x0, x0, #0x1", "dead1"),
            row(0x1008, "add", "x1, x1, #0x2", "dead2")
        ]

        let keepAll = document("_d", rows, options: .default)
        XCTAssertTrue(keepAll.text.contains("dead1"), "default must keep post-return instructions (byte-faithful)")
        XCTAssertTrue(keepAll.text.contains("dead2"))

        var dce = DecompilerOptions.default
        dce.deadCodeElimination = true
        // Disable structuring so the whole body flows through the single linear
        // emitter where DCE applies, making the assertion unambiguous.
        dce.structureControlFlow = false
        let eliminated = document("_d", rows, options: dce)
        XCTAssertTrue(eliminated.text.contains("return"), "the return itself stays")
        XCTAssertFalse(eliminated.text.contains("dead1"), "deadCodeElimination must drop post-return instructions")
        XCTAssertFalse(eliminated.text.contains("dead2"))
    }

    // MARK: - functionSizeGate

    func testFunctionAboveGateSkipsStructuring() {
        // A 100-instruction guarded body (102 instructions total). Under the
        // default gate (1024) the region structurer folds it without goto; with
        // the gate lowered below the instruction count, structuring is skipped and
        // the legacy path emits goto past its peephole cap.
        let rows = largeGuardedBody(bodyCount: 100)

        let ungated = document("_big", rows, options: .default)
        XCTAssertFalse(ungated.text.contains("goto"), "under the default gate the function structures (no goto)")

        var smallGate = DecompilerOptions.default
        smallGate.functionSizeGate = 64 // below the ~102-instruction function
        let gated = document("_big", rows, options: smallGate)
        XCTAssertTrue(gated.text.contains("goto"), "a function above the size gate uses the legacy renderer")
    }

    func testSizeGateMemberwiseInitClampsHostileValues() {
        // The memberwise init clamps the gate into range (direct field mutation
        // does not — only the inits enforce the invariant, matching
        // DisassemblyDisplayOptions).
        XCTAssertEqual(
            DecompilerOptions(structureControlFlow: true, deadCodeElimination: false, nopElision: false, functionSizeGate: 1).functionSizeGate,
            DecompilerOptions.functionSizeGateRange.lowerBound
        )
        XCTAssertEqual(
            DecompilerOptions(structureControlFlow: true, deadCodeElimination: false, nopElision: false, functionSizeGate: 1_000_000).functionSizeGate,
            DecompilerOptions.functionSizeGateRange.upperBound
        )
    }

    // MARK: - pure UserDefaults readers

    func testDecompilerOptionsReadFromUserDefaults() {
        let defaults = UserDefaults(suiteName: "DecompilerOptionsTests.\(UUID().uuidString)")!
        // Absent keys → shipped defaults.
        let fresh = DecompilerOptions(userDefaults: defaults)
        XCTAssertEqual(fresh, .default)

        defaults.set(false, forKey: DecompilerOptions.Key.structureControlFlow)
        defaults.set(true, forKey: DecompilerOptions.Key.nopElision)
        defaults.set(true, forKey: DecompilerOptions.Key.deadCodeElimination)
        defaults.set(9_999_999, forKey: DecompilerOptions.Key.functionSizeGate)
        let read = DecompilerOptions(userDefaults: defaults)
        XCTAssertFalse(read.structureControlFlow)
        XCTAssertTrue(read.nopElision)
        XCTAssertTrue(read.deadCodeElimination)
        XCTAssertEqual(read.functionSizeGate, DecompilerOptions.functionSizeGateRange.upperBound, "hostile gate clamps to the max")
    }

    func testCodeFontMigratesLegacyListingFontKeysOnceAndClamps() {
        let suite = "codefont.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Never set: the system monospaced font at 12 pt, nothing written.
        XCTAssertEqual(MacScopeCodeFont.current(defaults), LumenCodeFont.standard)
        XCTAssertNil(defaults.string(forKey: MacScopeCodeFont.storageKey))
        // Legacy keys migrate once, clamped; unknown families fall back to the system font.
        defaults.set("Menlo", forKey: MacScopeCodeFont.LegacyKey.family)
        defaults.set(1000.0, forKey: MacScopeCodeFont.LegacyKey.size)
        XCTAssertEqual(MacScopeCodeFont.current(defaults), LumenCodeFont(family: "Menlo", size: 24))
        XCTAssertEqual(defaults.string(forKey: MacScopeCodeFont.storageKey), "Menlo:24")
        defaults.set("Comic Sans", forKey: MacScopeCodeFont.LegacyKey.family)
        XCTAssertEqual(MacScopeCodeFont.current(defaults).family, "Menlo", "the stored value wins after migration")
        defaults.removeObject(forKey: MacScopeCodeFont.storageKey)
        XCTAssertNil(MacScopeCodeFont.current(defaults).family, "unknown legacy family -> system font")
    }

    func testAppAppearancePreferenceMapping() {
        XCTAssertNil(AppAppearancePreference.auto.colorScheme, "auto follows the system (nil)")
        XCTAssertEqual(AppAppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppAppearancePreference.dark.colorScheme, .dark)
        XCTAssertEqual(AppAppearancePreference.resolve("garbage"), .auto, "unrecognised raw resolves to auto")
        XCTAssertEqual(AppAppearancePreference.resolve("dark"), .dark)
    }
}


extension DecompilerOptionsTests {
    func testDefaultCodeFontUsesInjectedBaselineWithoutAppMigration() {
        let before = NSDictionary(dictionary:
            UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:])
        XCTAssertNotNil(MacIRConfiguration.installedTestBaseline)
        XCTAssertEqual(MacScopeCodeFont.current(), LumenCodeFont.standard)
        XCTAssertTrue(before.isEqual(to:
            UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:]))
    }
}
