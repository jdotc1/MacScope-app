import XCTest
@testable import MacScope

final class Phase2TerminalInputEncoderTests: XCTestCase {
    private let encoder = Phase2TerminalInputEncoder()

    func testNavigationAndFunctionKeysUseCanonicalXtermSequences() {
        XCTAssertEqual(text(key(126)), "\u{1B}[A")
        XCTAssertEqual(text(key(115)), "\u{1B}[H")
        XCTAssertEqual(text(key(119)), "\u{1B}[F")
        XCTAssertEqual(text(key(116)), "\u{1B}[5~")
        XCTAssertEqual(text(key(121)), "\u{1B}[6~")
        XCTAssertEqual(text(key(114)), "\u{1B}[2~")
        XCTAssertEqual(text(key(117)), "\u{1B}[3~")
        XCTAssertEqual(text(key(122)), "\u{1B}OP")
        XCTAssertEqual(text(key(96)), "\u{1B}[15~")
        XCTAssertEqual(text(key(111)), "\u{1B}[24~")
    }

    func testModifierParameterCombinesShiftOptionAndControl() {
        XCTAssertEqual(text(key(126, modifiers: [.shift])), "\u{1B}[1;2A")
        XCTAssertEqual(text(key(124, modifiers: [.option, .control])), "\u{1B}[1;7C")
        XCTAssertEqual(text(key(96, modifiers: [.shift, .option, .control])), "\u{1B}[15;8~")
    }

    func testApplicationCursorAndKeypadModesAreExplicit() {
        var modes = Phase2TerminalInputEncoder.Modes.normal
        modes.applicationCursorKeys = true
        modes.applicationKeypad = true
        XCTAssertEqual(text(key(123, modes: modes)), "\u{1B}OD")
        XCTAssertEqual(text(key(82, modes: modes)), "\u{1B}Op")
        XCTAssertEqual(text(key(82)), "0")
    }

    func testBracketedPasteFramesUTF8PayloadOnlyWhenEnabled() {
        var modes = Phase2TerminalInputEncoder.Modes.normal
        modes.bracketedPaste = true
        XCTAssertEqual(String(decoding: encoder.encodePaste("hé", modes: modes), as: UTF8.self), "\u{1B}[200~hé\u{1B}[201~")
        XCTAssertEqual(String(decoding: encoder.encodePaste("hé", modes: .normal), as: UTF8.self), "hé")
    }

    func testPrintableInputPreservesBytesAndOptionPrefixesEscape() {
        XCTAssertEqual(encoder.encode(.init(keyCode: 0, characters: "é", charactersIgnoringModifiers: "e", modifiers: []), modes: .normal), Array("é".utf8))
        XCTAssertEqual(encoder.encode(.init(keyCode: 7, characters: "≈", charactersIgnoringModifiers: "x", modifiers: [.option]), modes: .normal), [0x1B, 0x78])
        XCTAssertEqual(encoder.encode(.init(keyCode: 8, characters: "\u{3}", charactersIgnoringModifiers: "c", modifiers: [.control]), modes: .normal), [0x03])
    }

    func testCommandAndUnknownEmptyEventsFailClosed() {
        XCTAssertNil(encoder.encode(.init(keyCode: 0, characters: "x", charactersIgnoringModifiers: "x", modifiers: [.command]), modes: .normal))
        XCTAssertNil(encoder.encode(.init(keyCode: 200, characters: nil, charactersIgnoringModifiers: nil, modifiers: []), modes: .normal))
    }

    private func key(
        _ keyCode: UInt16,
        modifiers: Phase2TerminalInputEncoder.Modifiers = [],
        modes: Phase2TerminalInputEncoder.Modes = .normal
    ) -> [UInt8]? {
        encoder.encode(.init(keyCode: keyCode, characters: nil, charactersIgnoringModifiers: nil, modifiers: modifiers), modes: modes)
    }

    private func text(_ bytes: [UInt8]?) -> String? {
        bytes.map { String(decoding: $0, as: UTF8.self) }
    }
}
