import Foundation
import MachO

func relative(_ p: UnsafeRawPointer, indirect: Bool = false) -> UnsafeRawPointer? {
    let offset = p.loadUnaligned(as: Int32.self)
    if offset == 0 { return nil }
    let target = p.advanced(by: Int(indirect ? offset & ~1 : offset))
    return indirect && offset & 1 != 0 ? target.load(as: UnsafeRawPointer?.self) : target
}
func cstring(_ p: UnsafeRawPointer?) -> String? {
    p.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
}
struct ImageTypes {
    let header: UnsafePointer<mach_header_64>
    let slide: Int
    var ranges: [Range<UInt>] = []
    init(header: UnsafePointer<mach_header>, slide: Int) {
        self.header = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        self.slide = slide
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<self.header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == LC_SEGMENT_64 {
                let segment = command.load(as: segment_command_64.self)
                if segment.vmsize > 0 && segment.initprot != 0 {
                    let start = UInt(Int(segment.vmaddr) + slide)
                    ranges.append(start..<(start + UInt(segment.vmsize)))
                }
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
    }
    func address(_ p: UnsafeRawPointer) -> UInt? {
        let value = UInt(bitPattern: p)
        return ranges.contains(where: { $0.contains(value) }) ? UInt(Int(value) - slide) : nil
    }
    func descriptors() -> [UnsafeRawPointer] {
        var size: UInt = 0
        guard let bytes = getsectiondata(header, "__TEXT", "__swift5_types", &size) else { return [] }
        return stride(from: 0, to: Int(size), by: 4).compactMap { relative(UnsafeRawPointer(bytes).advanced(by: $0)) }
    }
    func path(_ descriptor: UnsafeRawPointer) -> (text: String, mangled: String?, anonymous: Bool) {
        var nodes: [(String, UInt32)] = []
        var current: UnsafeRawPointer? = descriptor
        var seen = Set<UInt>()
        var anonymous = false
        while let p = current, seen.insert(UInt(bitPattern: p)).inserted, seen.count < 64 {
            let kind = p.loadUnaligned(as: UInt32.self) & 31
            if kind == 2 { anonymous = true; break }
            if kind == 0 || (16...18).contains(kind) {
                guard let name = cstring(relative(p.advanced(by: 8))) else { break }
                nodes.append((name, kind))
            } else { anonymous = true; break }
            current = relative(p.advanced(by: 4), indirect: true)
        }
        nodes.reverse()
        let letters: [UInt32: String] = [16: "C", 17: "V", 18: "O"]
        let mangled = !anonymous && nodes.first?.1 == 0 ? nodes.map { "\($0.0.utf8.count)\($0.0)" + (letters[$0.1] ?? "") }.joined() : nil
        return (nodes.map(\.0).joined(separator: "."), mangled, anonymous)
    }
}

// Symbolic references contain binary payloads, including zero bytes.
func mangledBytes(_ p: UnsafeRawPointer) -> (length: Int, display: String, dependent: Bool) {
    var i = 0
    var text = ""
    var dependent = false
    while i < 65536 {
        let b = p.load(fromByteOffset: i, as: UInt8.self)
        if b == 0 { break }
        if (1...31).contains(b) {
            text += String(format: "<symbolic:%02x>", b)
            i += b <= 0x17 ? 5 : 9
            continue
        }
        if b == 120 { dependent = true }
        if b == 113 {
            let next = p.load(fromByteOffset: i + 1, as: UInt8.self)
            if next == 100 || next == 95 || (48...57).contains(next) { dependent = true }
        }
        text.append(Character(UnicodeScalar(b)))
        i += 1
    }
    return (i, text, dependent)
}
