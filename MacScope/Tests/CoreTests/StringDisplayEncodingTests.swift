import XCTest
@testable import MacScope

/// Tier 3 — the text-encoding preference for string literals. Asserts (1) the default
/// `.utf8` renderer is byte-identical to the historical C-escape renderer (a golden-style
/// no-regression gate), (2) the SAME bytes render DIFFERENTLY under each encoding, and
/// (3) the preference reads from UserDefaults and degrades safely on garbage. Also drives
/// the encoding through the real `readCString` seam to prove the wiring, not just the pure type.
final class StringDisplayEncodingTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let suite = "StringDisplayEncodingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Preference read

    func testAbsentKeyYieldsUTF8Default() {
        XCTAssertEqual(StringDisplayEncoding.read(from: defaults()), .utf8)
        XCTAssertEqual(StringDisplayEncoding.default, .utf8)
    }

    func testKeyIsRead() {
        let d = defaults()
        d.set(StringDisplayEncoding.hex.rawValue, forKey: StringDisplayEncoding.storageKey)
        XCTAssertEqual(StringDisplayEncoding.read(from: d), .hex)
    }

    func testGarbagePreferenceDegradesToDefault() {
        let d = defaults()
        d.set("klingon", forKey: StringDisplayEncoding.storageKey)
        XCTAssertEqual(StringDisplayEncoding.read(from: d), .utf8)
        XCTAssertEqual(StringDisplayEncoding.resolve(nil), .utf8)
    }

    // MARK: - The default renderer is byte-identical to the historical C-escape loop

    /// The exact byte-loop the renderer replaced, reproduced here as the oracle. The default
    /// `.utf8` path MUST match it for every input so no existing listing changes.
    private func historicalCEscape(_ bytes: [UInt8], stopAtNUL: Bool) -> String {
        var result = ""
        for byte in bytes {
            if stopAtNUL, byte == 0 { break }
            switch byte {
            case 0x00: result += "\\0"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x20..<0x7F: result.append(Character(UnicodeScalar(byte)))
            default: result += "\\x" + String(format: "%02x", byte)
            }
        }
        return result
    }

    func testUTF8DefaultMatchesHistoricalRendererAcrossByteSpace() {
        // Cover the whole byte range plus the escape-trigger bytes, both NUL-stopped and not.
        let samples: [[UInt8]] = [
            Array("hello world".utf8),
            Array("tab\there\nnewline".utf8),
            [0x22, 0x5C, 0x41, 0x00, 0x42], // quote, backslash, 'A', NUL, 'B'
            Array(0...255).map { UInt8($0) }, // every byte value
            []
        ]
        for stopAtNUL in [true, false] {
            for bytes in samples {
                XCTAssertEqual(
                    StringDisplayEncoding.utf8.render(bytes: bytes, stopAtNUL: stopAtNUL),
                    historicalCEscape(bytes, stopAtNUL: stopAtNUL),
                    "utf8 render diverged from the historical renderer (stopAtNUL=\(stopAtNUL))"
                )
            }
        }
    }

    // MARK: - The SAME bytes render differently per encoding

    func testSameBytesRenderDifferentlyPerEncoding() {
        // "Hi" with a high byte then a control: 0x48 0x69 0x80 0x01
        let bytes: [UInt8] = [0x48, 0x69, 0x80, 0x01]
        let utf8 = StringDisplayEncoding.utf8.render(bytes: bytes, stopAtNUL: false)
        let ascii = StringDisplayEncoding.ascii.render(bytes: bytes, stopAtNUL: false)
        let hex = StringDisplayEncoding.hex.render(bytes: bytes, stopAtNUL: false)
        XCTAssertEqual(utf8, "Hi\\x80\\x01")
        XCTAssertEqual(ascii, "Hi\\x80\\x01")
        XCTAssertEqual(hex, "48 69 80 01")
        // Hex is text-free, so it must differ from the escaped text forms.
        XCTAssertNotEqual(hex, utf8)
    }

    func testUTF16LEPairsBytesIntoCodeUnits() {
        // "Hi" as UTF-16LE: 0x48 0x00 0x69 0x00
        let bytes: [UInt8] = [0x48, 0x00, 0x69, 0x00]
        XCTAssertEqual(StringDisplayEncoding.utf16le.render(bytes: bytes, stopAtNUL: false), "Hi")
        // Under UTF-8 the same bytes read as 'H', NUL, 'i', NUL.
        XCTAssertEqual(StringDisplayEncoding.utf8.render(bytes: bytes, stopAtNUL: false), "H\\0i\\0")
    }

    func testUTF16LEStopsAtNULCodeUnit() {
        // "Hi" NUL-terminated as UTF-16LE then trailing junk.
        let bytes: [UInt8] = [0x48, 0x00, 0x69, 0x00, 0x00, 0x00, 0x5A, 0x00]
        XCTAssertEqual(StringDisplayEncoding.utf16le.render(bytes: bytes, stopAtNUL: true), "Hi")
    }

    func testHexHonorsNULStop() {
        let bytes: [UInt8] = [0x41, 0x42, 0x00, 0x43]
        XCTAssertEqual(StringDisplayEncoding.hex.render(bytes: bytes, stopAtNUL: true), "41 42")
        XCTAssertEqual(StringDisplayEncoding.hex.render(bytes: bytes, stopAtNUL: false), "41 42 00 43")
    }

    // MARK: - Through the real readCString seam (wiring, not just the pure type)

    func testReadCStringRespectsEncoding() {
        let shape = DataShapeOverride(kind: .string, isNullTerminated: true)
        let stringBytes: [UInt8] = [0x48, 0x69, 0x00] // "Hi\0"
        let reader: (UInt64, Int) -> Data? = { address, count in
            guard address == 0x1000 else { return nil }
            let available = stringBytes.count
            guard count <= available else { return nil }
            return Data(stringBytes.prefix(count))
        }
        let utf8 = WorkspaceSnapshot.readCString(at: 0x1000, shape: shape, encoding: .utf8, readBytes: reader)
        let hex = WorkspaceSnapshot.readCString(at: 0x1000, shape: shape, encoding: .hex, readBytes: reader)
        XCTAssertEqual(utf8, "Hi")
        XCTAssertEqual(hex, "48 69")
        // The default-parameter call (no encoding) must equal the explicit .utf8 call.
        let defaulted = WorkspaceSnapshot.readCString(at: 0x1000, shape: shape, readBytes: reader)
        XCTAssertEqual(defaulted, utf8)
    }

    func testDataDirectiveThreadsEncodingIntoTheStringOperand() {
        let shape = DataShapeOverride(kind: .string, isNullTerminated: true)
        let stringBytes: [UInt8] = [0x41, 0x42, 0x00] // "AB\0"
        let reader: (UInt64, Int) -> Data? = { address, count in
            guard address == 0x2000, count <= stringBytes.count else { return nil }
            return Data(stringBytes.prefix(count))
        }
        let utf8 = WorkspaceSnapshot.dataDirective(forShape: shape, at: 0x2000, encoding: .utf8, readBytes: reader)
        let hex = WorkspaceSnapshot.dataDirective(forShape: shape, at: 0x2000, encoding: .hex, readBytes: reader)
        XCTAssertEqual(utf8.mnemonic, ".asciz")
        XCTAssertEqual(utf8.operands, "\"AB\"")
        XCTAssertEqual(hex.operands, "\"41 42\"")
    }
}
