import XCTest
@testable import MacScope

/// Tier 3 — the preference-driven disassembly formatter. These assert that the SAME
/// instruction renders DIFFERENTLY per display preference (uppercase hex, hidden bytes,
/// hidden address, operand spacing), driving the previously write-only preference keys
/// through `DisassemblyDisplayOptions` into rendered text. Table-driven where natural.
final class DisassemblyFormattingTests: XCTestCase {

    // MARK: - Reading options from UserDefaults (the pure preferences -> options bridge)

    private func defaults() -> UserDefaults {
        // A throwaway suite so the test never touches the real app domain.
        let suite = "DisassemblyFormattingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testAbsentKeysYieldShippedDefaults() {
        let options = DisassemblyDisplayOptions(userDefaults: defaults())
        XCTAssertEqual(options, .default)
        // Spelled out so a default flip is caught.
        XCTAssertFalse(options.uppercaseHex)
        XCTAssertTrue(options.showInstructionBytes)
        XCTAssertTrue(options.showAddresses)
        XCTAssertEqual(options.operandSpacing, 1)
    }

    func testKeysAreRead() {
        let d = defaults()
        d.set(true, forKey: DisassemblyDisplayOptions.Key.uppercaseHex)
        d.set(false, forKey: DisassemblyDisplayOptions.Key.showInstructionBytes)
        d.set(false, forKey: DisassemblyDisplayOptions.Key.showAddresses)
        d.set(4, forKey: DisassemblyDisplayOptions.Key.operandSpacing)
        let options = DisassemblyDisplayOptions(userDefaults: d)
        XCTAssertTrue(options.uppercaseHex)
        XCTAssertFalse(options.showInstructionBytes)
        XCTAssertFalse(options.showAddresses)
        XCTAssertEqual(options.operandSpacing, 4)
    }

    func testOperandSpacingIsClampedFromHostileDefaults() {
        let high = defaults()
        high.set(9999, forKey: DisassemblyDisplayOptions.Key.operandSpacing)
        XCTAssertEqual(DisassemblyDisplayOptions(userDefaults: high).operandSpacing,
                       DisassemblyDisplayOptions.operandSpacingRange.upperBound)

        let low = defaults()
        low.set(-5, forKey: DisassemblyDisplayOptions.Key.operandSpacing)
        XCTAssertEqual(DisassemblyDisplayOptions(userDefaults: low).operandSpacing,
                       DisassemblyDisplayOptions.operandSpacingRange.lowerBound)
    }

    func testMemberwiseInitClampsSpacing() {
        let options = DisassemblyDisplayOptions(uppercaseHex: false, showInstructionBytes: true, showAddresses: true, operandSpacing: 100)
        XCTAssertEqual(options.operandSpacing, DisassemblyDisplayOptions.operandSpacingRange.upperBound)
    }

    // MARK: - The same instruction renders differently per option

    private func render(_ options: DisassemblyDisplayOptions) -> DisassemblyRowFormatter.RenderedColumns {
        DisassemblyRowFormatter.columns(
            address: 0x1000,
            bytes: "e0 03 01 aa",
            mnemonic: "mov",
            operands: "x0, x1",
            options: options
        )
    }

    func testDefaultRender() {
        let columns = render(.default)
        XCTAssertEqual(columns.address, "0x0000000000001000")
        XCTAssertEqual(columns.bytes, "e0 03 01 aa")
        XCTAssertEqual(columns.mnemonic, "mov")
        XCTAssertEqual(columns.operands, "x0, x1")
    }

    func testUppercaseHexUppercasesAddressAndBytes() {
        let columns = render(DisassemblyDisplayOptions(uppercaseHex: true, showInstructionBytes: true, showAddresses: true, operandSpacing: 1))
        XCTAssertEqual(columns.address, "0X0000000000001000")
        XCTAssertEqual(columns.bytes, "E0 03 01 AA")
        // The mnemonic/operands are NOT hex, so they are untouched.
        XCTAssertEqual(columns.mnemonic, "mov")
        XCTAssertEqual(columns.operands, "x0, x1")
    }

    func testHideInstructionBytes() {
        let columns = render(DisassemblyDisplayOptions(uppercaseHex: false, showInstructionBytes: false, showAddresses: true, operandSpacing: 1))
        XCTAssertEqual(columns.bytes, "")
        // Address still present.
        XCTAssertEqual(columns.address, "0x0000000000001000")
    }

    func testHideAddresses() {
        let columns = render(DisassemblyDisplayOptions(uppercaseHex: false, showInstructionBytes: true, showAddresses: false, operandSpacing: 1))
        XCTAssertEqual(columns.address, "")
        // Bytes still present.
        XCTAssertEqual(columns.bytes, "e0 03 01 aa")
    }

    func testHideBothAddressAndBytes() {
        let columns = render(DisassemblyDisplayOptions(uppercaseHex: false, showInstructionBytes: false, showAddresses: false, operandSpacing: 1))
        XCTAssertEqual(columns.address, "")
        XCTAssertEqual(columns.bytes, "")
        XCTAssertEqual(columns.mnemonic, "mov")
        XCTAssertEqual(columns.operands, "x0, x1")
    }

    // MARK: - Operand spacing in the joined line

    func testJoinedLineUsesConfiguredSpacing() {
        let cases: [(spacing: Int, expected: String)] = [
            (1, "mov x0, x1"),
            (2, "mov  x0, x1"),
            (4, "mov    x0, x1"),
        ]
        for testCase in cases {
            let options = DisassemblyDisplayOptions(uppercaseHex: false, showInstructionBytes: true, showAddresses: true, operandSpacing: testCase.spacing)
            let line = DisassemblyRowFormatter.joinedLine(mnemonic: "mov", operands: "x0, x1", options: options)
            XCTAssertEqual(line, testCase.expected, "spacing \(testCase.spacing)")
        }
    }

    func testJoinedLineWithEmptyOperandsHasNoTrailingSpace() {
        let options = DisassemblyDisplayOptions(uppercaseHex: false, showInstructionBytes: true, showAddresses: true, operandSpacing: 4)
        XCTAssertEqual(DisassemblyRowFormatter.joinedLine(mnemonic: "ret", operands: "", options: options), "ret")
    }

    // MARK: - Uppercase + joined line interplay (full row, table-driven)

    func testFullRowRendersPerOptionTable() {
        struct Row { let options: DisassemblyDisplayOptions; let address: String; let bytes: String; let line: String }
        let rows: [Row] = [
            Row(options: .default, address: "0x0000000000001000", bytes: "e0 03 01 aa", line: "mov x0, x1"),
            Row(options: DisassemblyDisplayOptions(uppercaseHex: true, showInstructionBytes: true, showAddresses: true, operandSpacing: 1),
                address: "0X0000000000001000", bytes: "E0 03 01 AA", line: "mov x0, x1"),
            Row(options: DisassemblyDisplayOptions(uppercaseHex: false, showInstructionBytes: false, showAddresses: false, operandSpacing: 3),
                address: "", bytes: "", line: "mov   x0, x1"),
        ]
        for row in rows {
            let columns = DisassemblyRowFormatter.columns(
                address: 0x1000, bytes: "e0 03 01 aa", mnemonic: "mov", operands: "x0, x1", options: row.options
            )
            XCTAssertEqual(columns.address, row.address)
            XCTAssertEqual(columns.bytes, row.bytes)
            let line = DisassemblyRowFormatter.joinedLine(mnemonic: columns.mnemonic, operands: columns.operands, options: row.options)
            XCTAssertEqual(line, row.line)
        }
    }
}
