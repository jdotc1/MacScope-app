import Foundation
import CryptoKit

/// Literal reference math adapted from UnsignedMemoryScenario.rgbToPlanes8 and
/// PlanarScenario, with exact original-row observations added. It receives only
/// external scenario values and byte memory, never candidate text, names or IR.
/// Scope: the two complete frozen original streams, bounded whole-entry runs.
enum NativeScalarScalarOracle {
    typealias C = OrdinaryC
    struct Write: Equatable { let row: Int; let slot: Int; let width: Int; let bits: UInt64 }
    struct Reference {
        var memory: [UInt64: UInt8]
        var events: [C.Event] = []
        var writes: [Write] = []
        var branches: [RegionalCallOracle.Branch] = []
        var rowVisits: [Int: Int] = [:]
        var returned = false
    }
    struct Scenario {
        enum Alias: String { case none, sameSample, nextSample, nextRowPointer, addressWrap, signedBoundary }
        let context: UInt64 = 0x1_0000_1000
        let planes: UInt64 = 0x3_0000_3000
        let width: UInt32
        let rows: UInt32
        let components: UInt32
        let index: UInt32
        let alias: Alias
        var memory: [UInt64: UInt8] = [:]
        var sourceRows: UInt64 { alias == .signedBoundary ? UInt64(Int64.max) - 7 : 0x2_0000_2000 }
        var physical: [Int: UInt64] { [0: context, 1: sourceRows, 2: planes, 3: UInt64(index), 4: UInt64(rows)] }
        var label: String { "width=\(width), rows=\(rows), components=\(components), index=\(index), alias=\(alias.rawValue)" }
        func table(_ component: Int) -> UInt64 { 0x4_0000_0000 + UInt64(component * 0x10000) }
        func samples(_ row: Int) -> UInt64 { alias == .addressWrap && row == 0 ? UInt64.max - 4 : 0x5_0000_0000 + UInt64(row * 0x10000) }
        func destination(_ component: Int, _ row: Int) -> UInt64 {
            if component == 0 && row == 0 {
                switch alias {
                case .sameSample: return samples(0) &+ 1
                case .nextSample: return samples(0) &+ UInt64(components)
                case .nextRowPointer: return sourceRows &+ 8
                case .addressWrap: return UInt64.max - 1
                default: break
                }
            }
            return 0x6_0000_0000 + UInt64(component * 0x10000 + row * 0x1000)
        }
        init(width: UInt32, rows: UInt32, components: UInt32 = 3, index: UInt32 = 7, alias: Alias = .none) {
            self.width = width; self.rows = rows; self.components = components; self.index = index; self.alias = alias
            func put(_ bits: UInt64, at address: UInt64, bytes: Int) {
                for offset in 0..<bytes { memory[address &+ UInt64(offset)] = UInt8(truncatingIfNeeded: bits >> (offset * 8)) }
            }
            put(UInt64(components), at: context &+ 0x5c, bytes: 4)
            put(UInt64(width), at: context &+ 0x30, bytes: 4)
            for row in 0..<2 { put(samples(row), at: sourceRows &+ UInt64(row * 8), bytes: 8) }
            for component in 0..<5 {
                put(table(component), at: planes &+ UInt64(component * 8), bytes: 8)
                for row in 0..<2 {
                    put(destination(component, row), at: table(component) &+ (UInt64(index &+ UInt32(row)) << 3), bytes: 8)
                    let normal: UInt64 = 0x6_0000_0000 + UInt64(component * 0x10000 + row * 0x1000)
                    for offset in 0..<32 { memory[normal &+ UInt64(offset)] = 0xa5 }
                }
            }
            for row in 0..<2 {
                for offset in 0..<512 { memory[samples(row) &+ UInt64(offset)] = UInt8(truncatingIfNeeded: 0x91 + row * 0x61 + offset * 0x11) }
            }
            if alias == .nextRowPointer {
                // Plane zero replaces the low three bytes of next row's source
                // pointer with samples(1)+0x80. Subsequent loads must reread it.
                for (pixel, byte): (Int, UInt8) in [(0, 0x80), (1, 0), (2, 1)] {
                    memory[samples(0) &+ UInt64(pixel) * UInt64(components)] = byte
                }
            }
        }
    }
    private struct State {
        let start: UInt64
        var result: Reference
        var occurrences: [C.SourceSite: Int] = [:]
        mutating func visit(_ row: Int) { result.rowVisits[row, default: 0] += 1 }
        mutating func write(_ row: Int, _ slot: Int, _ width: Int, _ value: UInt64, visitRow: Bool = true) {
            if visitRow { visit(row) }
            let bits = width == 64 ? value : value & ((UInt64(1) << width) - 1)
            result.writes.append(.init(row: row, slot: slot, width: width, bits: bits))
        }
        mutating func load(_ row: Int, _ address: UInt64, _ bytes: Int, effect: Int = 0) throws -> UInt64 {
            if effect == 0 { visit(row) }
            guard address <= UInt64.max - UInt64(bytes - 1) else { throw C.Failure.invalidContract("literal multibyte read crosses address-space end") }
            var value: UInt64 = 0
            for offset in 0..<bytes {
                guard let byte = result.memory[address + UInt64(offset)] else { throw C.Failure.uninitializedRead("literal scalar byte at \(address + UInt64(offset))") }
                value |= UInt64(byte) << (offset * 8)
            }
            let site = C.SourceSite(row: row, effectOrdinal: effect), occurrence = occurrences[site, default: 0]
            occurrences[site] = occurrence + 1
            result.events.append(.load(site, occurrence, address, bytes, value))
            write(row, effect, bytes == 8 ? 64 : 32, value, visitRow: false)
            return value
        }
        mutating func store(_ row: Int, _ address: UInt64, _ value: UInt64) {
            visit(row)
            let site = C.SourceSite(row: row, effectOrdinal: 0), occurrence = occurrences[site, default: 0]
            occurrences[site] = occurrence + 1
            let byte = UInt8(truncatingIfNeeded: value)
            result.events.append(.store(site, occurrence, address, 1, UInt64(byte))); result.memory[address] = byte
        }
        @discardableResult mutating func branch(_ row: Int, _ taken: Bool, _ target: Int) -> Bool {
            visit(row); result.branches.append(.init(row: row, taken: taken, target: start + UInt64(target * 4))); return taken
        }
        mutating func finish(_ row: Int) -> Reference { visit(row); result.returned = true; return result }
    }

    static func validateOriginal(_ fixture: NativeScalarFixture, bound: NativeScalarOriginalBindings.Bound) throws {
        let expected: String
        switch fixture.seed {
        case .interleavedRGB8: expected = "79910bc7bacabf5f032636ffbe4b9fc8bedd54587b821aafb54be0ecf773a6ba"
        case .nullRGB8: expected = "eb75cd617e7f8e9427392a98bfd1d9b94f48c7ebb74bf6b556d780289a0ff8b0"
        case .entryNoscale8, .entryDownscale17c88, .entryUpscale30134, .entryNoscale30630, .entryNoscale30b10:
            throw C.Failure.invalidContract("entry5 has a separate literal reference")
        }
        let text = fixture.rows.map { "\($0.address)|\($0.bytes)|\($0.mnemonic)|\($0.operands)" }.joined(separator: "\n")
        let actual = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected, Set(bound.inputs.map(\.register)) == [0, 1, 2, 3, 4],
              bound.inputs.allSatisfy({ $0.initializedWidth == ($0.register >= 3 ? 32 : 64) }),
              case .unavailableReturnContract = bound.manifest.terminal else {
            throw C.Failure.invalidContract("literal scalar reference does not match complete original bytes/ABI/terminal")
        }
    }
    static func reference(_ scenario: Scenario, seed: NativeScalarSeed) throws -> Reference {
        guard scenario.width <= 3, scenario.rows <= 2 || Int32(bitPattern: scenario.rows) < 0,
              scenario.components <= 5 || Int32(bitPattern: scenario.components) < 0 else {
            throw C.Failure.invalidContract("first scalar reference requires its bounded finite scenario domain")
        }
        switch seed {
        case .interleavedRGB8:
            guard scenario.components == 3 else { throw C.Failure.invalidContract("RGB reference has exactly three channels") }
            return try rgb(scenario)
        case .nullRGB8: return try planar(scenario)
        case .entryNoscale8, .entryDownscale17c88, .entryUpscale30134, .entryNoscale30630, .entryNoscale30b10:
            throw C.Failure.invalidContract("wrong scalar reference seed")
        }
    }
    private static func rgb(_ input: Scenario) throws -> Reference {
        var s = State(start: 0x3854, result: .init(memory: input.memory))
        var remaining = input.rows, index = input.index, rowPointers = input.sourceRows
        s.visit(0)
        if s.branch(1, Int32(bitPattern: remaining) < 1, 25) { return s.finish(25) }
        let pixels = UInt32(truncatingIfNeeded: try s.load(2, input.context &+ 0x30, 4))
        repeat {
            if !s.branch(3, pixels == 0, 20) {
                let a = try s.load(4, input.planes, 8), b = try s.load(4, input.planes &+ 8, 8, effect: 1)
                var pointers = [try s.load(5, a &+ (UInt64(index) << 3), 8), try s.load(6, b &+ (UInt64(index) << 3), 8)]
                let c = try s.load(7, input.planes &+ 16, 8)
                pointers.append(try s.load(8, c &+ (UInt64(index) << 3), 8))
                var source = try s.load(9, rowPointers, 8), left = UInt64(pixels)
                s.write(10, 0, 64, left)
                repeat {
                    for component in 0..<3 {
                        let row = 11 + component * 2
                        let value = try s.load(row, source &+ UInt64(component), 1)
                        s.store(row + 1, pointers[component], value)
                        pointers[component] &+= 1; s.write(row + 1, 1, 64, pointers[component], visitRow: false)
                    }
                    source &+= 3; s.write(17, 0, 64, source)
                    left &-= 1; s.write(18, 0, 64, left)
                } while s.branch(19, left != 0, 11)
            }
            rowPointers &+= 8; s.write(20, 0, 64, rowPointers)
            index &+= 1; s.write(21, 0, 32, UInt64(index))
            let writerTime = remaining; s.visit(22)
            remaining &-= 1; s.write(23, 0, 32, UInt64(remaining))
            if !s.branch(24, writerTime >= 2, 3) { break }
        } while true
        return s.finish(25)
    }
    private static func planar(_ input: Scenario) throws -> Reference {
        var s = State(start: 0x3704, result: .init(memory: input.memory))
        let count = UInt32(truncatingIfNeeded: try s.load(0, input.context &+ 0x5c, 4))
        let pixels = UInt32(truncatingIfNeeded: try s.load(1, input.context &+ 0x30, 4))
        var remaining = input.rows, index = input.index, rowPointers = input.sourceRows
        s.visit(2)
        let three = s.branch(3, count == 3, 34)
        var four = false
        if !three { s.visit(4); four = !s.branch(5, count != 4, 59) }
        if three || four {
            let guardRow = three ? 34 : 6
            s.visit(guardRow)
            if s.branch(guardRow + 1, Int32(bitPattern: remaining) < 1, 83) { return s.finish(83) }
            repeat {
                let zero = three ? 36 : 8, tail = three ? 53 : 28
                if !s.branch(zero, pixels == 0, tail) {
                    let pair = three ? 37 : 9
                    let a = try s.load(pair, input.planes, 8), b = try s.load(pair, input.planes &+ 8, 8, effect: 1)
                    var pointers = [try s.load(pair + 1, a &+ (UInt64(index) << 3), 8), try s.load(pair + 2, b &+ (UInt64(index) << 3), 8)]
                    let c = try s.load(pair + 3, input.planes &+ 16, 8)
                    if four {
                        let d = try s.load(pair + 3, input.planes &+ 24, 8, effect: 1)
                        pointers.append(try s.load(13, c &+ (UInt64(index) << 3), 8))
                        pointers.append(try s.load(14, d &+ (UInt64(index) << 3), 8))
                    } else { pointers.append(try s.load(41, c &+ (UInt64(index) << 3), 8)) }
                    var left = UInt64(pixels), source: UInt64
                    if four { s.write(15, 0, 64, left); source = try s.load(16, rowPointers, 8) }
                    else { source = try s.load(42, rowPointers, 8); s.write(43, 0, 64, left) }
                    let first = three ? 44 : 17, advance = three ? 50 : 25
                    repeat {
                        for component in 0..<Int(count) {
                            let row = first + component * 2
                            let value = try s.load(row, source &+ UInt64(component), 1)
                            s.store(row + 1, pointers[component], value)
                            pointers[component] &+= 1; s.write(row + 1, 1, 64, pointers[component], visitRow: false)
                        }
                        source &+= UInt64(count); s.write(advance, 0, 64, source)
                        left &-= 1; s.write(advance + 1, 0, 64, left)
                    } while s.branch(advance + 2, left != 0, first)
                }
                rowPointers &+= 8; s.write(tail, 0, 64, rowPointers)
                index &+= 1; s.write(tail + 1, 0, 32, UInt64(index))
                let writerTime = remaining; s.visit(tail + 2)
                remaining &-= 1; s.write(tail + 3, 0, 32, UInt64(remaining))
                if s.branch(tail + 4, writerTime < 2, 83) { break }
                s.branch(tail + 5, true, zero)
            } while true
        } else {
            s.visit(59)
            if s.branch(60, Int32(bitPattern: remaining) < 1, 83) { return s.finish(83) }
            let stride = UInt64(bitPattern: Int64(Int32(bitPattern: count))); s.write(61, 0, 64, stride)
            repeat {
                s.visit(62)
                if !s.branch(63, Int32(bitPattern: count) < 1, 78) {
                    var component: UInt64 = 0; s.write(64, 0, 64, component)
                    repeat {
                        if !s.branch(65, pixels == 0, 75) {
                            let table = try s.load(66, input.planes &+ (component << 3), 8)
                            var destination = try s.load(67, table &+ (UInt64(index) << 3), 8)
                            var source = try s.load(68, rowPointers, 8), left = UInt64(pixels)
                            s.write(69, 0, 64, left)
                            repeat {
                                let value = try s.load(70, source &+ component, 1)
                                s.store(71, destination, value)
                                destination &+= 1; s.write(71, 1, 64, destination, visitRow: false)
                                source &+= stride; s.write(72, 0, 64, source)
                                left &-= 1; s.write(73, 0, 64, left)
                            } while s.branch(74, left != 0, 70)
                        }
                        component &+= 1; s.write(75, 0, 64, component); s.visit(76)
                    } while s.branch(77, component != UInt64(count), 65)
                }
                rowPointers &+= 8; s.write(78, 0, 64, rowPointers)
                index &+= 1; s.write(79, 0, 32, UInt64(index))
                let writerTime = remaining; s.visit(80)
                remaining &-= 1; s.write(81, 0, 32, UInt64(remaining))
                if !s.branch(82, Int32(bitPattern: writerTime) > 1, 62) { break }
            } while true
        }
        return s.finish(83)
    }
}
