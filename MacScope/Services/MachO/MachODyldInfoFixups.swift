import Foundation

/// Rebase and exact-bind slots recovered from the classic `LC_DYLD_INFO(_ONLY)` opcode streams of
/// an image that has no `LC_DYLD_CHAINED_FIXUPS`. Mirrors what the chained-fixup walk yields so
/// pointer consumers (Swift metadata) read the same maps for either encoding.
struct MachODyldInfoFixups: Equatable, Sendable {
    /// Slot VA -> in-image target VA, read from the slot's (unslid) pointer value.
    var rebaseTargets: [UInt64: UInt64] = [:]
    /// Slot VA -> imported symbol name, for binds whose addend is zero.
    var bindNames: [UInt64: String] = [:]

    struct Streams: Sendable {
        var rebase: Range<Int>
        var bind: Range<Int>
    }

    private static let maxEntries = 4_000_000
    private static let pointerMask: UInt64 = 0x0000_ffff_ffff_ffff

    static func decode(data: Data, streams: Streams, segments: [MachOSegment]) -> MachODyldInfoFixups {
        var result = MachODyldInfoFixups()
        decodeRebases(data: data, range: streams.rebase, segments: segments, into: &result)
        decodeBinds(data: data, range: streams.bind, segments: segments, into: &result)
        return result
    }

    private struct Reader {
        let data: Data
        var cursor: Int
        let end: Int

        var atEnd: Bool { cursor >= end }

        mutating func byte() -> UInt8? {
            guard cursor < end else { return nil }
            defer { cursor += 1 }
            return data[data.startIndex + cursor]
        }

        mutating func uleb() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while let b = byte() {
                if shift < 64 { value |= UInt64(b & 0x7f) << shift }
                if b & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }

        mutating func sleb() -> Int64? {
            var value: Int64 = 0
            var shift: Int64 = 0
            while let b = byte() {
                if shift < 64 { value |= Int64(b & 0x7f) << shift }
                shift += 7
                if b & 0x80 == 0 {
                    if shift < 64, b & 0x40 != 0 { value |= -(Int64(1) << shift) }
                    return value
                }
            }
            return nil
        }

        mutating func cString() -> String? {
            var bytes: [UInt8] = []
            while let b = byte() {
                if b == 0 { return String(decoding: bytes, as: UTF8.self) }
                bytes.append(b)
            }
            return nil
        }
    }

    private static func reader(_ data: Data, _ range: Range<Int>) -> Reader? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= data.count else { return nil }
        return Reader(data: data, cursor: range.lowerBound, end: range.upperBound)
    }

    private static func slot(segment: Int, offset: UInt64, segments: [MachOSegment], fileSize: Int) -> (va: UInt64, file: Int)? {
        guard segment < segments.count else { return nil }
        let seg = segments[segment]
        guard seg.fileSize >= 8, offset <= seg.fileSize - 8 else { return nil }
        let (va, vaOverflow) = seg.vmAddress.addingReportingOverflow(offset)
        let (file, fileOverflow) = seg.fileOffset.addingReportingOverflow(offset)
        guard !vaOverflow, !fileOverflow, fileSize >= 8, file <= UInt64(fileSize - 8) else { return nil }
        return (va, Int(file))
    }

    private static func pointer(in data: Data, at file: Int) -> UInt64? {
        guard file >= 0, file <= data.count - 8 else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(data[data.startIndex + file + i]) << UInt64(8 * i) }
        return value & pointerMask
    }

    private static func advance(_ offset: inout UInt64, by amount: UInt64) -> Bool {
        let (next, overflow) = offset.addingReportingOverflow(amount)
        guard !overflow else { return false }
        offset = next
        return true
    }

    private static func decodeRebases(data: Data, range: Range<Int>, segments: [MachOSegment],
                                      into result: inout MachODyldInfoFixups) {
        guard var r = reader(data, range) else { return }
        var segment = 0
        var offset: UInt64 = 0

        var type: UInt64 = 0

        func rebase() -> Bool {
            guard result.rebaseTargets.count < maxEntries else { return false }
            if type == 1, let s = slot(segment: segment, offset: offset, segments: segments, fileSize: data.count),
               let target = pointer(in: data, at: s.file) {
                result.rebaseTargets[s.va] = target
            }
            return advance(&offset, by: 8)
        }

        while let op = r.byte() {
            let imm = UInt64(op & 0x0f)
            switch op & 0xf0 {
            case 0x00: return
            case 0x10: type = imm
            case 0x20:
                segment = Int(imm)
                guard let o = r.uleb() else { return }
                offset = o
            case 0x30:
                guard let a = r.uleb() else { return }
                guard advance(&offset, by: a) else { return }
            case 0x40:
                let (scaled, overflow) = imm.multipliedReportingOverflow(by: 8)
                guard !overflow, advance(&offset, by: scaled) else { return }
            case 0x50:
                for _ in 0..<imm { guard rebase() else { return } }
            case 0x60:
                guard let n = r.uleb(), n <= UInt64(maxEntries) else { return }
                for _ in 0..<n { guard rebase() else { return } }
            case 0x70:
                guard rebase(), let a = r.uleb() else { return }
                guard advance(&offset, by: a) else { return }
            case 0x80:
                guard let n = r.uleb(), let skip = r.uleb(), n <= UInt64(maxEntries) else { return }
                for _ in 0..<n {
                    guard rebase() else { return }
                    guard advance(&offset, by: skip) else { return }
                }
            default: return
            }
        }
    }

    private static func decodeBinds(data: Data, range: Range<Int>, segments: [MachOSegment],
                                    into result: inout MachODyldInfoFixups) {
        guard var r = reader(data, range) else { return }
        var segment = 0
        var offset: UInt64 = 0
        var symbol: String?
        var addend: Int64 = 0

        func bind() -> Bool {
            guard result.bindNames.count < maxEntries else { return false }
            if addend == 0, let symbol, !symbol.isEmpty,
               let s = slot(segment: segment, offset: offset, segments: segments, fileSize: data.count) {
                result.bindNames[s.va] = symbol
            }
            return true
        }

        while let op = r.byte() {
            let imm = UInt64(op & 0x0f)
            switch op & 0xf0 {
            case 0x00: return
            case 0x10, 0x30, 0x50: break
            case 0x20: guard r.uleb() != nil else { return }
            case 0x40:
                guard let name = r.cString() else { return }
                symbol = name
            case 0x60:
                guard let a = r.sleb() else { return }
                addend = a
            case 0x70:
                segment = Int(imm)
                guard let o = r.uleb() else { return }
                offset = o
            case 0x80:
                guard let a = r.uleb() else { return }
                if a > UInt64(Int64.max) {
                    // dyld's ADD_ADDR_ULEB permits two's-complement backward deltas.
                    // Use checked subtraction, bounded to file-backed segment positions.
                    guard segment < segments.count, offset <= segments[segment].fileSize else { return }
                    let (previous, underflow) = offset.subtractingReportingOverflow(UInt64.max - a + 1)
                    guard !underflow,
                          slot(segment: segment, offset: previous, segments: segments, fileSize: data.count) != nil else { return }
                    offset = previous
                } else {
                    guard advance(&offset, by: a) else { return }
                }
            case 0x90:
                guard bind() else { return }
                guard advance(&offset, by: 8) else { return }
            case 0xa0:
                guard bind(), let a = r.uleb() else { return }
                guard advance(&offset, by: 8), advance(&offset, by: a) else { return }
            case 0xb0:
                guard bind() else { return }
                let (scaled, overflow) = imm.multipliedReportingOverflow(by: 8)
                guard !overflow, advance(&offset, by: 8), advance(&offset, by: scaled) else { return }
            case 0xc0:
                guard let n = r.uleb(), let skip = r.uleb(), n <= UInt64(maxEntries) else { return }
                for _ in 0..<n {
                    guard bind() else { return }
                    guard advance(&offset, by: 8), advance(&offset, by: skip) else { return }
                }
            default: return // threaded binds (0xd0) and unknown opcodes: stop rather than guess
            }
        }
    }
}
