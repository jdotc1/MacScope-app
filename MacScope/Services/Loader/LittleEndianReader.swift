import Foundation

enum BinaryReadError: Error {
    case truncated(String)
}

/// Bounds-checked reads over a file's bytes, shared by the format loaders (ELF,
/// PE/COFF). Defaults to little-endian (the format the PE/COFF loader and the original
/// ELF64-LSB path need); pass `bigEndian: true` to decode ELFDATA2MSB images. Every
/// accessor validates against the buffer end, and `range` converts an untrusted
/// `UInt64` offset/size to an `Int` range ONLY after a bounds check — so a
/// crafted/malformed header degrades gracefully (nil / thrown) instead of trapping on a
/// `UInt64`→`Int` conversion or an out-of-bounds subscript.
struct LittleEndianReader {
    let bytes: Data
    let bigEndian: Bool
    private let start: Int

    init(_ bytes: Data, bigEndian: Bool = false) {
        self.bytes = bytes
        self.bigEndian = bigEndian
        self.start = bytes.startIndex
    }

    /// Validate in file-relative coordinates before any potentially overflowing add.
    /// Once admitted, `start + offset + width` cannot exceed Data.endIndex.
    private func contains(offset: Int, width: Int) -> Bool {
        offset >= 0 && width >= 0 && offset <= bytes.count
            && width <= bytes.count - offset
    }

    func byte(_ offset: Int) -> UInt8? {
        guard contains(offset: offset, width: 1) else { return nil }
        return bytes[start + offset]
    }

    /// Validates that `[offset, offset+size)` lies fully within the file and returns
    /// it as a 0-based `Int` range — no UInt64→Int trap, no overflow. nil if out of
    /// range or overflowing.
    func range(_ offset: UInt64, _ size: UInt64) -> Range<Int>? {
        let count = UInt64(bytes.count)
        guard offset <= count, size <= count - offset else { return nil }
        return Int(offset)..<Int(offset + size)
    }

    func u16(_ offset: Int) throws -> UInt16 {
        guard contains(offset: offset, width: 2) else { throw BinaryReadError.truncated("u16@\(offset)") }
        let b0 = UInt16(bytes[start + offset])
        let b1 = UInt16(bytes[start + offset + 1])
        return bigEndian ? (b0 << 8 | b1) : (b0 | b1 << 8)
    }

    func u32(_ offset: Int) throws -> UInt32 {
        guard contains(offset: offset, width: 4) else { throw BinaryReadError.truncated("u32@\(offset)") }
        var value: UInt32 = 0
        for i in 0..<4 {
            let shift = bigEndian ? (8 * (3 - i)) : (8 * i)
            value |= UInt32(bytes[start + offset + i]) << shift
        }
        return value
    }

    func u64(_ offset: Int) throws -> UInt64 {
        guard contains(offset: offset, width: 8) else { throw BinaryReadError.truncated("u64@\(offset)") }
        var value: UInt64 = 0
        for i in 0..<8 {
            let shift = bigEndian ? (8 * (7 - i)) : (8 * i)
            value |= UInt64(bytes[start + offset + i]) << shift
        }
        return value
    }

    /// Reads a NUL-terminated string starting at `fileOffset`, never reading at or
    /// past `limit`. Both arguments are file-relative offsets, matching `range`.
    /// Clamp before converting to Data indices: a Data slice may start above zero.
    func cString(fileOffset: Int, limit: Int) -> String {
        let relativeUpper = min(limit, bytes.count)
        guard fileOffset >= 0, fileOffset < relativeUpper else { return "" }
        let upper = start + relativeUpper
        var scalars: [UInt8] = []
        var index = start + fileOffset
        while index < upper {
            let byte = bytes[index]
            if byte == 0 { break }
            scalars.append(byte)
            index += 1
        }
        return String(decoding: scalars, as: UTF8.self)
    }

    /// Scans `[fileOffset, fileOffset+size)` for NUL-terminated printable C-strings,
    /// emitting one `StringLiteralSummary` per run (address = section base + offset).
    func scanCStrings(fileOffset: Int, size: Int, baseAddress: UInt64, sectionName: String, emit: (StringLiteralSummary) -> Void) {
        guard size > 0, contains(offset: fileOffset, width: size) else { return }
        var runStart = -1
        var current: [UInt8] = []
        for relative in 0..<size {
            let byte = bytes[start + fileOffset + relative]
            let isPrintable = byte >= 0x20 && byte < 0x7F
            if byte == 0 {
                if runStart >= 0, !current.isEmpty {
                    emit(StringLiteralSummary(
                        id: UUID(),
                        value: String(decoding: current, as: UTF8.self),
                        address: baseAddress &+ UInt64(runStart),
                        sourceSection: sectionName,
                        byteLength: current.count + 1
                    ))
                }
                runStart = -1
                current.removeAll(keepingCapacity: true)
            } else if isPrintable {
                if runStart < 0 { runStart = relative }
                current.append(byte)
            } else {
                runStart = -1
                current.removeAll(keepingCapacity: true)
            }
        }
    }
}
