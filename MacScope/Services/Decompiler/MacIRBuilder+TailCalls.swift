import Foundation

// Tail-branch proof uses instruction effects without builder-state or printer inference.
enum MacIRTailCallProof {
    struct Instruction {
        let address: UInt64
        let mnemonic: String
        let operands: String
    }

    struct Decision {
        let admitted: Bool
        let reason: String
        let restoringAddress: UInt64?
    }

    static func split(_ text: String) -> [String] {
        var result: [String] = [], current = "", depth = 0
        for character in text {
            if character == "[" { depth += 1 }
            if character == "]" { depth -= 1 }
            if character == "," && depth == 0 {
                result.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else { current.append(character) }
        }
        if !current.isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        return result
    }

    static func number(_ text: String) -> Int64? {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        let negative = value.hasPrefix("-")
        if negative { value.removeFirst() }
        let magnitude = value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
        guard let magnitude, magnitude <= UInt64(Int64.max) else { return nil }
        return negative ? -Int64(magnitude) : Int64(magnitude)
    }

    static func address(_ text: String) -> UInt64? {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        return value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
    }

    static func register(_ text: String, width: Int? = nil) -> Int? {
        if text == "xzr" { return width == 32 ? nil : 31 }
        if text == "wzr" { return width == 64 ? nil : 31 }
        guard let prefix = text.first, prefix == "x" || prefix == "w",
              width == nil || width == (prefix == "x" ? 64 : 32),
              let index = Int(text.dropFirst()), (0...30).contains(index),
              text == "\(prefix)\(index)" else { return nil }
        return index
    }

    struct Memory {
        let base: String
        let offset: Int64
        let writeback: Int64
        let preIndex: Bool
        let hasWriteback: Bool
    }

    static func memory(_ pieces: ArraySlice<String>) -> Memory? {
        guard let first = pieces.first, first.hasPrefix("["), pieces.count <= 2 else { return nil }
        let pre = first.hasSuffix("]!")
        guard pre || first.hasSuffix("]") else { return nil }
        let body = String(first.dropFirst().dropLast(pre ? 2 : 1))
        let parts = split(body)
        guard (1...2).contains(parts.count),
              parts[0] == "sp" || register(parts[0], width: 64) != nil,
              parts[0] != "xzr",
              let offset = parts.count == 1 ? Int64(0) : number(parts[1]) else { return nil }
        if pieces.count == 2 {
            guard !pre, offset == 0, let post = number(pieces.last!) else { return nil }
            return Memory(base: parts[0], offset: 0, writeback: post, preIndex: false, hasWriteback: true)
        }
        return Memory(base: parts[0], offset: offset, writeback: pre ? offset : 0, preIndex: pre, hasWriteback: pre)
    }

    static func prove(_ rows: [Instruction], at index: Int, entry: UInt64,
                      knownFunctionStarts: Set<UInt64>, recoveredSwitches: Set<UInt64>) -> Decision {
        func no(_ reason: String) -> Decision { Decision(admitted: false, reason: reason, restoringAddress: nil) }
        guard rows.indices.contains(index), rows.first?.address == entry,
              index <= 256 else { return no("entry-path-bound-or-missing-entry") }
        let branch = rows[index], mnemonic = branch.mnemonic.lowercased()
        let operands = split(branch.operands.lowercased())
        // Preserved LR and balanced SP do not prove that a register target
        // leaves the function. Only an exact known direct target is admitted.
        guard mnemonic == "b" else { return no("not-direct-B") }
        guard operands.count == 1 else { return no("branch-operands-unclassified") }
        let lastAddress = rows.map(\.address).max() ?? entry
        guard let target = address(operands[0]) else { return no("direct-target-not-exact-address") }
        if target >= entry && target <= lastAddress { return no("intra-function-branch") }
        guard knownFunctionStarts.contains(target) else { return no("target-not-known-function-start") }
        guard !recoveredSwitches.contains(branch.address) else { return no("recovered-switch") }
        for offset in 0...index {
            let (expected, overflow) = entry.addingReportingOverflow(UInt64(offset) * 4)
            guard !overflow, rows[offset].address == expected else { return no("noncontiguous-entry-path") }
        }
        var sp: Int64 = 0
        var slot: Int64?
        var lrIsEntry = true
        var restore: Int?
        var pac: String?
        var authenticated = false
        func add(_ a: Int64, _ b: Int64) -> Int64? {
            let (value, overflow) = a.addingReportingOverflow(b)
            return overflow ? nil : value
        }
        func writesLR(_ name: String) -> Bool { register(name) == 30 }
        for position in 0..<index {
            let row = rows[position], op = row.mnemonic.lowercased()
            let a = split(row.operands.lowercased())
            if let restore, index - restore >= 16 { return no("restore-window-exceeds-16") }
            if op == "nop" && a.isEmpty { continue }
            if op == "paciasp" || op == "pacibsp" {
                guard position == 0, a.isEmpty, sp == 0, pac == nil else { return no("PAC-outside-entry") }
                pac = op; continue
            }
            if op == "autiasp" || op == "autibsp" {
                guard a.isEmpty, restore != nil, sp == 0, !authenticated,
                      pac == (op == "autiasp" ? "paciasp" : "pacibsp") else {
                    return no("AUT-without-matching-entry-PAC")
                }
                authenticated = true; continue
            }
            if op == "add" || op == "sub" {
                guard a.count == 3 || a.count == 4 else { return no("arithmetic-operands-unclassified") }
                if a[0] == "sp" {
                    guard a[1] == "sp", let immediate = number(a[2]), (0...4095).contains(immediate),
                          a.count == 3 || a[3] == "lsl #12" else { return no("untracked-SP-write") }
                    let delta = immediate * (a.count == 4 ? 4096 : 1) * (op == "sub" ? -1 : 1)
                    guard let next = add(sp, delta) else { return no("SP-overflow") }
                    sp = next; continue
                }
                let width = a[0].hasPrefix("x") ? 64 : 32
                guard register(a[0], width: width) != nil else { return no("arithmetic-operands-unclassified") }
                if let immediate = number(a[2]) {
                    guard (0...4095).contains(immediate),
                          register(a[1], width: width) != nil || (width == 64 && a[1] == "sp"),
                          a.count == 3 || a[3] == "lsl #12" else { return no("arithmetic-operands-unclassified") }
                } else {
                    guard register(a[1], width: width) != nil, register(a[2], width: width) != nil,
                          a.count == 3 || validShift(a[3], width: width) else { return no("arithmetic-operands-unclassified") }
                }
                if writesLR(a[0]) {
                    if restore != nil { return no("X30-overwritten-after-restore") }
                    lrIsEntry = false
                }
                continue
            }
            if op == "stp" || op == "ldp" {
                guard (3...4).contains(a.count), let first = register(a[0], width: 64),
                      let second = register(a[1], width: 64), let mem = memory(a.dropFirst(2)),
                      mem.base == "sp", mem.offset % 8 == 0, mem.writeback % 8 == 0,
                      (-512...504).contains(mem.offset), (-512...504).contains(mem.writeback),
                      let location = add(sp, mem.offset), let next = add(sp, mem.writeback) else {
                    return no("pair-memory-unclassified")
                }
                if op == "stp" {
                    if second == 30 || first == 30 {
                        guard first == 29, second == 30, slot == nil, restore == nil, lrIsEntry,
                              position <= 4, location >= min(sp, next), location <= -16 else {
                            return no("X30-save-not-entry-frame-slot")
                        }
                        slot = location + 8
                    } else if let slot, location < slot + 8 && location + 16 > slot {
                        return no("store-may-replace-saved-X30")
                    }
                } else {
                    guard first != second else { return no("overlapping-pair-destinations") }
                    if first == 30 || second == 30 {
                        guard restore == nil else { return no("X30-overwritten-after-restore") }
                        guard let slot, location + (second == 30 ? 8 : 0) == slot else {
                            return no("X30-load-not-prologue-slot")
                        }
                        restore = position; lrIsEntry = true
                    }
                }
                sp = next; continue
            }
            let loads = ["ldr", "ldur", "ldrb", "ldurb", "ldrh", "ldurh", "ldrsw", "ldursw", "ldrsb", "ldrsh"]
            let stores = ["str", "stur", "strb", "sturb", "strh", "sturh"]
            if loads.contains(op) || stores.contains(op) {
                guard (2...3).contains(a.count), let destination = register(a[0]),
                      let mem = memory(a.dropFirst()), mem.base == "sp" || !mem.hasWriteback else {
                    return no("single-memory-unclassified")
                }
                let width: Int64 = op.hasSuffix("b") ? 1 : op.hasSuffix("h") ? 2 : a[0].hasPrefix("w") || op.hasSuffix("sw") ? 4 : 8
                let unscaled = op.hasPrefix("ldur") || op.hasPrefix("stur")
                guard !unscaled || !mem.hasWriteback else { return no("single-memory-unclassified") }
                guard (!unscaled && !mem.hasWriteback && mem.offset >= 0 &&
                       mem.offset % width == 0 && mem.offset / width <= 4095) ||
                      ((-256...255).contains(mem.offset) && (-256...255).contains(mem.writeback)) else {
                    return no("single-memory-offset-unclassified")
                }
                if loads.contains(op) && destination == 30 {
                    guard restore == nil else { return no("X30-overwritten-after-restore") }
                    guard (op == "ldr" || op == "ldur"), a[0] == "x30", mem.base == "sp",
                          let slot, add(sp, mem.offset) == slot else { return no("X30-load-not-prologue-slot") }
                    restore = position; lrIsEntry = true
                }
                if stores.contains(op) {
                    if destination == 30 { return no("X30-save-not-entry-frame-slot") }
                    if let slot {
                        guard mem.base == "sp", let location = add(sp, mem.offset) else {
                            return no("store-may-alias-saved-X30")
                        }
                        guard location >= slot + 8 || location + width <= slot else {
                            return no("store-may-replace-saved-X30")
                        }
                    }
                }
                if mem.base == "sp" {
                    guard let next = add(sp, mem.writeback) else { return no("SP-overflow") }
                    sp = next
                }
                continue
            }
            if op == "mov" {
                guard a.count == 2, register(a[0]) != nil,
                      register(a[1]) != nil || a[1] == "sp" || number(a[1]) != nil else {
                    return no("MOV-operands-or-SP-write-unclassified")
                }
                if writesLR(a[0]) {
                    if restore != nil { return no("X30-overwritten-after-restore") }
                    lrIsEntry = false
                }
                continue
            }
            if op == "adr" || op == "adrp" {
                guard a.count == 2, register(a[0], width: 64) != nil, address(a[1]) != nil else {
                    return no("PC-relative-operands-unclassified")
                }
                if writesLR(a[0]) {
                    if restore != nil { return no("X30-overwritten-after-restore") }
                    lrIsEntry = false
                }
                continue
            }
            // Only these fully understood scalar forms are irrelevant to frame
            // authority. No destination=SP convention is borrowed from an unknown op.
            if ["cmp", "cmn", "tst"].contains(op) {
                guard a.count == 2, register(a[0]) != nil,
                      register(a[1]) != nil || number(a[1]) != nil else { return no("comparison-unclassified") }
                continue
            }
            return no("unclassified-or-control-flow-on-entry-path")
        }
        guard lrIsEntry else { return no("entry-X30-not-restored") }
        guard slot == nil || restore != nil else { return no("saved-X30-not-restored") }
        guard sp == 0 else { return no("SP-not-entry-balanced") }
        if let restore, index - restore >= 16 { return no("restore-window-exceeds-16") }
        guard pac == nil || authenticated else { return no("PAC-not-authenticated-after-restore") }
        for row in rows {
            let op = row.mnemonic.lowercased()
            let isDirectEdge = op == "b" || op.hasPrefix("b.") || op.hasPrefix("bc.") ||
                ["cbz", "cbnz", "tbz", "tbnz"].contains(op)
            guard isDirectEdge else { continue }
            guard let operand = split(row.operands.lowercased()).last, let target = address(operand) else {
                return no("incoming-edge-target-unresolved")
            }
            if target >= entry && target <= branch.address {
                return no(restore.map { target > rows[$0].address } == true
                    ? "incoming-edge-after-restore" : "incoming-edge-bypasses-entry-proof")
            }
        }
        return Decision(admitted: true, reason: restore == nil ? "entry-X30-untouched-balanced-SP" :
                        "matched-frame-X30-balanced-SP", restoringAddress: restore.map { rows[$0].address })
    }

    static func validShift(_ text: String, width: Int) -> Bool {
        let pieces = text.split(separator: " ").map(String.init)
        return pieces.count == 2 && ["lsl", "lsr", "asr"].contains(pieces[0]) &&
            number(pieces[1]).map { (0..<Int64(width)).contains($0) } == true
    }
}

extension MacIRTailCallProof {
    /// Frame facts only. The caller must independently prove that the terminal
    /// transfer names an exact external entry and must preserve return refusals.
    struct FrameCertificate {
        let certified: Bool
        let reason: String
        let entryFPPreserved: Bool
    }

    private enum FrameValue: Equatable {
        case entryLR, entryFP, stack(Int64)
    }

    private struct FrameState: Equatable {
        var sp: Int64 = 0
        var registers: [Int: FrameValue] = [29: .entryFP, 30: .entryLR]
        var slots: [Int64: FrameValue] = [:]
    }

    /// Only the bounded register-index form used here; no writeback or guessed extension.
    static func indexedMemory(_ operand: String, width: Int64) -> (base: String, index: String, shift: Int64)? {
        guard operand.hasPrefix("["), operand.hasSuffix("]") else { return nil }
        let parts = split(String(operand.dropFirst().dropLast()))
        guard (2...3).contains(parts.count), register(parts[0], width: 64) != nil,
              parts[0] != "xzr", register(parts[1], width: 64) != nil else { return nil }
        var shift: Int64 = 0
        if parts.count == 3 {
            let modifier = parts[2].split(separator: " ").map(String.init)
            guard modifier.count == 2, modifier[0] == "lsl", let amount = number(modifier[1]),
                  (0...3).contains(amount), amount == 0 || (Int64(1) << amount) == width else { return nil }
            shift = amount
        }
        return (parts[0], parts[1], shift)
    }

    /// Standard function-analysis precondition: entry is authoritative and rows
    /// contain the complete retained function interval. All retained predecessors
    /// are checked; this is not a whole-image no-external-entry certificate.
    static func certifyRetainedFramePaths(
        _ rows: [Instruction], at terminal: Int, entry: UInt64,
        knownFunctionStarts: Set<UInt64>, recoveredSwitches: Set<UInt64>
    ) -> FrameCertificate {
        func no(_ reason: String) -> FrameCertificate {
            .init(certified: false, reason: reason, entryFPPreserved: false)
        }
        guard rows.indices.contains(terminal), !rows.isEmpty, rows.count <= 512,
              rows.first?.address == entry else { return no("path-bound-or-missing-entry") }
        var byAddress: [UInt64: Int] = [:]
        for (index, row) in rows.enumerated() {
            let (expected, overflow) = entry.addingReportingOverflow(UInt64(index) * 4)
            guard !overflow, row.address == expected,
                  byAddress.updateValue(index, forKey: row.address) == nil else {
                return no("noncontiguous-or-duplicate-path-row")
            }
        }
        let conditions: Set<String> = ["eq", "ne", "hs", "cs", "lo", "cc", "mi", "pl",
            "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le"]
        var successors = Array(repeating: [Int](), count: rows.count)
        var predecessors = Array(repeating: [Int](), count: rows.count)
        var exits: Set<Int> = [terminal]
        for (index, row) in rows.enumerated() {
            guard !recoveredSwitches.contains(row.address) else { return no("recovered-switch-path") }
            if index == terminal { continue }
            let op = row.mnemonic.lowercased(), a = split(row.operands.lowercased())
            if op == "ret" {
                guard a.isEmpty || a == ["x30"] else { return no("unproved-return-edge") }
                exits.insert(index); continue
            }
            if op == "b" {
                guard a.count == 1, let target = address(a[0]) else { return no("unresolved-direct-edge") }
                if let next = byAddress[target] { successors[index] = [next] }
                else if knownFunctionStarts.contains(target), target < entry || target > rows.last!.address {
                    exits.insert(index)
                } else { return no("unproved-external-edge") }
            } else if op.hasPrefix("b.") || ["cbz", "cbnz", "tbz", "tbnz"].contains(op) {
                let valid: Bool
                if op.hasPrefix("b.") { valid = conditions.contains(String(op.dropFirst(2))) && a.count == 1 }
                else if op == "cbz" || op == "cbnz" { valid = a.count == 2 && register(a[0]) != nil }
                else {
                    valid = a.count == 3 && register(a[0]) != nil
                        && number(a[1]).map { (0..<Int64(a[0].hasPrefix("w") ? 32 : 64)).contains($0) } == true
                }
                guard valid, let operand = a.last, let target = address(operand),
                      let next = byAddress[target], index + 1 < rows.count else {
                    return no("unproved-conditional-edge")
                }
                successors[index] = [next, index + 1]
            } else {
                guard !op.hasPrefix("br"), !op.hasPrefix("bl"), op != "eret",
                      index + 1 < rows.count else { return no("opaque-call-or-indirect-edge") }
                successors[index] = [index + 1]
            }
            for next in successors[index] { predecessors[next].append(index) }
        }

        func adding(_ a: Int64, _ b: Int64) -> Int64? {
            let (value, overflow) = a.addingReportingOverflow(b)
            return overflow ? nil : value
        }
        func transfer(_ row: Instruction, _ state: inout FrameState) -> String? {
            let op = row.mnemonic.lowercased(), a = split(row.operands.lowercased())
            func value(_ operand: String) -> FrameValue? {
                if operand == "sp" { return .stack(state.sp) }
                guard operand.hasPrefix("x"), let r = register(operand) else { return nil }
                return state.registers[r]
            }
            func set(_ operand: String, _ value: FrameValue?) {
                guard let r = register(operand), r != 31 else { return }
                state.registers[r] = operand.hasPrefix("x") ? value : nil
            }
            if op == "nop" && a.isEmpty { return nil }
            if op == "mov", a.count == 2, register(a[0]) != nil,
               register(a[1]) != nil || a[1] == "sp" || number(a[1]) != nil {
                set(a[0], value(a[1])); return nil
            }
            if op == "add" || op == "sub" {
                guard (3...4).contains(a.count) else { return "arithmetic-shape" }
                if let immediate = number(a[2]), (0...4095).contains(immediate),
                   a.count == 3 || a[3] == "lsl #12" {
                    let delta = immediate * (a.count == 4 ? 4096 : 1) * (op == "sub" ? -1 : 1)
                    if case let .stack(base)? = value(a[1]) {
                        guard let next = adding(base, delta) else { return "stack-alias-overflow" }
                        if a[0] == "sp" { state.sp = next }
                        else { guard register(a[0], width: 64) != nil else { return "narrow-stack-alias" }; set(a[0], .stack(next)) }
                        return nil
                    }
                }
                let width = a[0].hasPrefix("x") ? 64 : 32
                guard register(a[0], width: width) != nil, register(a[1], width: width) != nil,
                      register(a[2], width: width) != nil || number(a[2]) != nil,
                      a.count == 3 || validShift(a[3], width: width),
                      value(a[1]) == nil, value(a[2]) == nil else { return "unproved-arithmetic-alias-or-SP-write" }
                set(a[0], nil); return nil
            }
            if ["cmp", "cmn", "tst"].contains(op), a.count == 2,
               register(a[0]) != nil, register(a[1]) != nil || number(a[1]) != nil { return nil }
            if ["ccmp", "ccmn"].contains(op), a.count == 4,
               register(a[0]) != nil, register(a[1]) != nil || number(a[1]) != nil,
               number(a[2]).map({ (0...15).contains($0) }) == true, conditions.contains(a[3]) { return nil }
            if ["mul", "udiv", "sdiv", "and", "orr", "eor"].contains(op), a.count == 3 {
                let width = a[0].hasPrefix("x") ? 64 : 32
                guard register(a[0], width: width) != nil, register(a[1], width: width) != nil,
                      register(a[2], width: width) != nil,
                      value(a[1]) == nil, value(a[2]) == nil else { return "unproved-scalar-alias" }
                set(a[0], nil); return nil
            }
            if op == "sxtw", a.count == 2, register(a[0], width: 64) != nil,
               register(a[1], width: 32) != nil { set(a[0], nil); return nil }
            if op == "adr" || op == "adrp" {
                guard a.count == 2, register(a[0], width: 64) != nil, address(a[1]) != nil else { return "address-shape" }
                set(a[0], nil); return nil
            }
            let loads = ["ldr", "ldur", "ldrb", "ldurb", "ldrh", "ldurh", "ldrsw", "ldursw", "ldrsb", "ldrsh", "ldp"]
            let stores = ["str", "stur", "strb", "sturb", "strh", "sturh", "stp"]
            guard loads.contains(op) || stores.contains(op) else { return "unclassified-path-effect" }
            let pair = op == "ldp" || op == "stp", count = pair ? 2 : 1
            guard (count + 1...count + 2).contains(a.count),
                  a.prefix(count).allSatisfy({ register($0, width: pair ? 64 : nil) != nil }),
                  !pair || a[0] != a[1] else { return "memory-register-shape" }
            let width: Int64 = op.hasSuffix("b") ? 1 : op.hasSuffix("h") ? 2
                : a[0].hasPrefix("w") || op.hasSuffix("sw") ? 4 : 8
            var location: Int64?, writeback: Int64 = 0
            if let mem = memory(a.dropFirst(count)) {
                guard mem.base == "sp" || !mem.hasWriteback else { return "untracked-memory-writeback" }
                if pair {
                    guard mem.offset % 8 == 0, mem.writeback % 8 == 0,
                          (-512...504).contains(mem.offset), (-512...504).contains(mem.writeback)
                    else { return "pair-memory-offset" }
                } else {
                    let unscaled = op.hasPrefix("ldur") || op.hasPrefix("stur")
                    guard !unscaled || !mem.hasWriteback else { return "unscaled-writeback" }
                    let scaled = !unscaled && !mem.hasWriteback && mem.offset >= 0
                        && mem.offset % width == 0 && mem.offset / width <= 4095
                    guard scaled || ((-256...255).contains(mem.offset) && (-256...255).contains(mem.writeback))
                    else { return "single-memory-offset" }
                }
                if case let .stack(base)? = value(mem.base) {
                    guard let offset = adding(base, mem.offset) else { return "frame-address-overflow" }
                    location = offset
                }
                writeback = mem.writeback
            } else {
                // Positively parsed register-indexed memory has no writeback.
                guard !pair, !op.hasPrefix("ldur"), !op.hasPrefix("stur"),
                      a.count == count + 1, indexedMemory(a[count], width: width) != nil
                else { return "indexed-memory-shape" }
            }
            guard let nextSP = adding(state.sp, writeback) else { return "SP-overflow" }
            for position in 0..<count {
                let offset: Int64?
                if let location { offset = adding(location, Int64(position) * width) } else { offset = nil }
                if loads.contains(op) {
                    set(a[position], width == 8 ? offset.flatMap { state.slots[$0] } : nil)
                } else {
                    guard let offset, let end = adding(offset, width) else {
                        if !state.slots.isEmpty { return "store-may-alias-frame-proof-slot" }
                        continue
                    }
                    for saved in Array(state.slots.keys) where saved < end && saved + 8 > offset {
                        state.slots.removeValue(forKey: saved)
                    }
                    if width == 8, let stored = value(a[position]) {
                        guard offset >= min(state.sp, nextSP), end <= 0 else { return "frame-value-save-outside-allocation" }
                        state.slots[offset] = stored
                    }
                }
            }
            state.sp = nextSP
            return nil
        }

        var states: [Int: FrameState] = [0: FrameState()], queue = [0], cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]; cursor += 1
            guard cursor <= rows.count else { return no("path-work-bound") }
            var state = states[index]!
            if exits.contains(index) {
                guard state.sp == 0, state.registers[30] == .entryLR else { return no("exit-SP-or-entry-LR-unproved") }
            } else {
                let op = rows[index].mnemonic.lowercased()
                if op != "b" && !op.hasPrefix("b.") && !["cbz", "cbnz", "tbz", "tbnz"].contains(op),
                   let refusal = transfer(rows[index], &state) { return no(refusal) }
            }
            for next in successors[index] {
                if let previous = states[next] {
                    guard previous == state else { return no("conflicting-frame-state-at-join") }
                } else { states[next] = state; queue.append(next) }
            }
        }
        guard let result = states[terminal] else { return no("unreachable-terminal") }
        for index in states.keys where predecessors[index].contains(where: { states[$0] == nil }) {
            return no("unproved-retained-incoming-predecessor")
        }
        return .init(certified: true, reason: "all-retained-entry-paths-preserve-frame",
                     entryFPPreserved: result.registers[29] == .entryFP)
    }
}

extension MacIRBuilder {
    struct ProvenTailCall {
        let callMnemonic: String
        let callOperands: String
        let targetAddress: UInt64

        func source(_ original: MacIRSourceSpan, phase: MacIRTailCallEffect.Phase) -> MacIRSourceSpan {
            var result = original
            result.tailCallEffect = .init(targetAddress: targetAddress, targetName: callOperands, phase: phase)
            return result
        }
    }

    static func provenTailCalls<Row: DecompilerInstructionRow>(
        rows: [Row], entry: UInt64, knownTargets: [UInt64: String], recoveredSwitches: Set<UInt64>,
        pathCompleteEnabled: Bool = false
    ) -> [UInt64: ProvenTailCall] {
        // A proof keyed by address cannot distinguish disagreeing duplicate
        // source rows. Keep every such transfer opaque instead of borrowing proof.
        let addressCounts = Dictionary(grouping: rows, by: \.address).mapValues { $0.count }
        let proofRows = rows.map { MacIRTailCallProof.Instruction(address: $0.address,
            mnemonic: $0.mnemonic, operands: $0.operands) }
        let starts = Set(knownTargets.keys)
        var result: [UInt64: ProvenTailCall] = [:]
        for (index, row) in rows.enumerated() where row.mnemonic.lowercased() == "b" {
            guard addressCounts[row.address] == 1 else { continue }
            // Lifting prefers typed memory when supplied. The proof's textual
            // frame coordinates must describe that same access, not a shadow
            // interpretation of inconsistent sidecar data.
            let linearMemoryAgrees = rows.prefix(index).allSatisfy { tailCallMemorySidecarAgrees($0) }
            let linear = MacIRTailCallProof.prove(proofRows, at: index, entry: entry,
                knownFunctionStarts: starts, recoveredSwitches: recoveredSwitches)
            if !linear.admitted || !linearMemoryAgrees {
                // Only the existing flag-on exact-identity route may use this
                // fallback. Frame facts never supply identity or a return type.
                guard pathCompleteEnabled, let target = MacIRTailCallProof.address(row.operands),
                      starts.contains(target), let last = rows.last?.address,
                      target < entry || target > last,
                      rows.allSatisfy({ tailCallPathMemorySidecarAgrees($0) }),
                      MacIRTailCallProof.certifyRetainedFramePaths(proofRows, at: index, entry: entry,
                        knownFunctionStarts: starts, recoveredSwitches: recoveredSwitches).certified else { continue }
            }
            guard let address = MacIRTailCallProof.address(row.operands), let name = knownTargets[address] else { continue }
            result[row.address] = ProvenTailCall(callMnemonic: "bl",
                callOperands: name.isEmpty ? "0x" + String(address, radix: 16) : name,
                targetAddress: address)
        }
        return result
    }

    // New-path-only agreement; the old linear/default gate below is unchanged.
    private static func tailCallPathMemorySidecarAgrees<Row: DecompilerInstructionRow>(_ row: Row) -> Bool {
        guard let sidecar = row.structuredOperands else { return true }
        let op = row.mnemonic.lowercased(), operands = MacIRTailCallProof.split(row.operands.lowercased())
        let pair = op == "ldp" || op == "stp", count = pair ? 2 : 1
        guard pair || ["ldr", "ldur", "ldrb", "ldurb", "ldrh", "ldurh", "ldrsw", "ldursw",
                       "ldrsb", "ldrsh", "str", "stur", "strb", "sturb", "strh", "sturh"].contains(op)
        else { return true }
        guard operands.count >= count + 1 else { return false }
        let width: Int64 = op.hasSuffix("b") ? 1 : op.hasSuffix("h") ? 2
            : operands[0].hasPrefix("w") || op.hasSuffix("sw") ? 4 : 8
        if let bits = sidecar.semantics?.memoryAccessWidth, bits != Int(width * 8) { return false }
        let source = MacIRSourceSpan(address: row.address, byteText: row.bytes,
            mnemonic: op, operands: row.operands, comment: row.comment, structuredOperands: sidecar)
        guard let actual = typedMemoryOperand(of: source) else { return false }
        if let expected = MacIRTailCallProof.memory(operands.dropFirst(count)) {
            return tailCallMemorySidecarAgrees(row) && actual.writeback == expected.hasWriteback
        }
        guard !pair, operands.count == 2,
              let expected = MacIRTailCallProof.indexedMemory(operands[1], width: width),
              registerName(actual.base) == expected.base, actual.index.flatMap(registerName) == expected.index,
              actual.displacement == 0, actual.indexing == .offset, !actual.writeback else { return false }
        if let modifier = actual.modifier {
            return modifier.kind == .lsl && Int64(modifier.amount ?? 0) == expected.shift
        }
        return expected.shift == 0
    }

    private static func tailCallMemorySidecarAgrees<Row: DecompilerInstructionRow>(_ row: Row) -> Bool {
        guard row.structuredOperands != nil else { return true }
        let op = row.mnemonic.lowercased()
        let pair = op == "ldp" || op == "stp"
        let single = ["ldr", "ldur", "ldrb", "ldurb", "ldrh", "ldurh", "ldrsw", "ldursw",
                      "ldrsb", "ldrsh", "str", "stur", "strb", "sturb", "strh", "sturh"].contains(op)
        guard pair || single else { return true }
        let operands = MacIRTailCallProof.split(row.operands.lowercased())
        guard let expected = MacIRTailCallProof.memory(operands.dropFirst(pair ? 2 : 1)) else { return false }
        let source = MacIRSourceSpan(address: row.address, byteText: row.bytes,
            mnemonic: op, operands: row.operands, comment: row.comment, structuredOperands: row.structuredOperands)
        guard let actual = typedMemoryOperand(of: source), registerName(actual.base) == expected.base,
              actual.index == nil, actual.modifier == nil,
              actual.displacement == (expected.hasWriteback ? expected.writeback : expected.offset) else { return false }
        if expected.preIndex { return actual.indexing == .preIndex }
        return actual.indexing == (expected.hasWriteback ? .postIndex : .offset)
    }

    struct TailCallParameterRow: DecompilerInstructionRow {
        let address: UInt64
        let bytes: String
        let mnemonic: String
        let operands: String
        let comment: String?
        let structuredOperands: InstructionOperands?
    }

    static func tailCallParameterRows<Row: DecompilerInstructionRow>(
        _ rows: [Row], tailCalls: [UInt64: ProvenTailCall]
    ) -> [TailCallParameterRow] {
        rows.map { row in
            let call = tailCalls[row.address]
            return TailCallParameterRow(address: row.address, bytes: row.bytes,
                mnemonic: call?.callMnemonic ?? row.mnemonic,
                operands: call?.callOperands ?? row.operands, comment: row.comment,
                structuredOperands: call == nil ? row.structuredOperands : nil)
        }
    }

}
