import Foundation

/// The Apple ordinary-ARM64 recovery subset. Structured decoding is deliberately
/// separate from evaluation: a decoded operation need not have modeled effects.
struct UnwindAuditCFI {
    struct Row {
        var pc: UInt64
        var register: Int
        var offset: Int64
        var rules: [Int: Rule]

        func recover(_ state: UnwindAuditMachine) throws -> [String: UnwindAuditValue] {
            let base = register == 31 ? state.sp : state.registers[register]
            let cfa = try base.add(offset)
            var result: [String: UnwindAuditValue] = ["SP": cfa]
            for number in 19...30 {
                switch rules[number] ?? .same {
                case .same: result["x\(number)"] = state.registers[number]
                case .undefined: result["x\(number)"] = .unknown("DW_CFA_undefined")
                case .offset(let displacement):
                    let location = try cfa.add(displacement)
                    guard case .stack(let slot) = location,
                          case .stack(let stack) = state.sp,
                          slot % 8 == 0, slot >= stack, slot <= -8 else {
                        result["x\(number)"] = .unknown("CFI read is outside the modeled allocated frame")
                        continue
                    }
                    result["x\(number)"] = state.memory[slot] ?? .unknown("CFI slot has no modeled store")
                }
            }
            return result
        }
    }

    enum Rule { case same, undefined, offset(Int64) }
    struct FDE {
        var offset: Int
        var cieOffset: Int
        var start: UInt64
        var end: UInt64
        var rows: [Row]

        func row(at pc: UInt64) throws -> Row {
            guard start <= pc, pc < end,
                  let row = rows.last(where: { $0.pc <= pc }) else {
                throw UnwindAuditCFI.failure("Requested PC is outside the exact FDE")
            }
            return row
        }
    }

    let fdes: [Int: FDE]
    let overlapping: Set<Int>

    init(table: DWARFStructuredCallFrameTable) throws {
        guard table.cies.count + table.fdes.count <= 4096 else {
            throw Self.failure("CFI record budget exhausted")
        }
        var operations = 0
        var rowCount = 0
        var initials: [Int: Row] = [:]
        for cie in table.cies {
            guard cie.version == 1, cie.augmentation == "zR",
                  cie.augmentationData == [0x10], cie.codeAlignmentFactor == 1,
                  cie.dataAlignmentFactor == -8, cie.returnAddressRegister == 30,
                  cie.fdePointerEncoding == 0x10,
                  initials[cie.sectionOffset] == nil else {
                throw Self.failure("Only CIEv1 zR, code1/data-8, RA30, pcrel-pointer64 is modeled")
            }
            let rows = try Self.evaluate(cie.initialProgram, start: 0, end: 0,
                                         initial: nil, operations: &operations, rowCount: &rowCount)
            initials[cie.sectionOffset] = rows.last
        }
        var decoded: [Int: FDE] = [:]
        for fde in table.fdes {
            let (end, overflow) = fde.initialLocation.addingReportingOverflow(fde.rangeSize)
            guard let initial = initials[fde.cieSectionOffset],
                  fde.cieSectionOffset < fde.sectionOffset,
                  fde.augmentationData.isEmpty, !overflow, fde.rangeSize > 0,
                  fde.initialLocation % 4 == 0, fde.rangeSize % 4 == 0,
                  decoded[fde.sectionOffset] == nil else {
                throw Self.failure("Malformed, unsupported or duplicate FDE")
            }
            let rows = try Self.evaluate(fde.program, start: fde.initialLocation, end: end,
                                         initial: initial, operations: &operations, rowCount: &rowCount)
            decoded[fde.sectionOffset] = FDE(offset: fde.sectionOffset, cieOffset: fde.cieSectionOffset,
                                            start: fde.initialLocation, end: end, rows: rows)
        }
        var overlaps = Set<Int>()
        var furthest: FDE?
        for fde in decoded.values.sorted(by: { ($0.start, $0.end, $0.offset) < ($1.start, $1.end, $1.offset) }) {
            if let previous = furthest, fde.start < previous.end {
                overlaps.insert(previous.offset)
                overlaps.insert(fde.offset)
            }
            if let previous = furthest {
                if fde.end > previous.end { furthest = fde }
            } else { furthest = fde }
        }
        fdes = decoded
        overlapping = overlaps
    }

    func select(offset: UInt32, start: UInt64, end: UInt64) throws -> FDE {
        guard let fde = fdes[Int(offset)], !overlapping.contains(Int(offset)),
              fde.start == start, fde.end == end else {
            throw Self.failure("Exact nonoverlapping FDE record and independent function extent are required")
        }
        return fde
    }

    private static func evaluate(_ program: DWARFStructuredCFAProgram, start: UInt64,
                                 end: UInt64, initial: Row?, operations: inout Int,
                                 rowCount: inout Int) throws -> [Row] {
        guard program.status == .complete else { throw failure("CFI program is unsupported or malformed") }
        var pc = start
        var cfa: (Int, Int64)? = initial.map { ($0.register, $0.offset) }
        var rules = initial?.rules ?? Dictionary(uniqueKeysWithValues: (19...30).map { ($0, Rule.same) })
        var rows: [Row] = []
        func save() throws {
            guard let cfa else { throw failure("No explicit supported CFA definition is available") }
            let row = Row(pc: pc, register: cfa.0, offset: cfa.1, rules: rules)
            if rows.last?.pc == pc { rows[rows.count - 1] = row }
            else {
                rowCount += 1
                guard rowCount <= 50_000 else { throw failure("CFI row budget exhausted") }
                rows.append(row)
            }
        }
        for operation in program.operations {
            operations += 1
            guard operations <= 200_000 else { throw failure("CFI instruction budget exhausted") }
            func operand(_ index: Int) throws -> UInt64 {
                guard operation.operands.indices.contains(index),
                      case .unsigned(let value) = operation.operands[index] else {
                    throw failure("CFI operand is absent or unsupported")
                }
                return value
            }
            func register(_ index: Int) throws -> Int {
                let value = try operand(index)
                guard (19...30).contains(value) else { throw failure("Register rule is outside x19–x30") }
                return Int(value)
            }
            switch operation.opcode & 0xc0 {
            case 0x40:
                let delta = try operand(0)
                let (next, overflow) = pc.addingReportingOverflow(delta)
                guard initial != nil, delta > 0, !overflow, next <= end, next % 4 == 0 else {
                    throw failure("CFI location advance is outside the supported aligned FDE")
                }
                try save()
                pc = next
            case 0x80:
                let number = try register(0), scaled = try operand(1)
                guard scaled <= UInt64(Int64.max) / 8 + 1 else { throw failure("CFI stack offset overflows") }
                let displacement = scaled == UInt64(Int64.max) / 8 + 1 ? Int64.min : -Int64(scaled) * 8
                rules[number] = .offset(displacement)
            case 0xc0:
                guard let initial else { throw failure("Restore has no CIE initial rule") }
                rules[try register(0)] = initial.rules[try register(0)]
            default:
                switch operation.opcode {
                case 0: break
                case 7: rules[try register(0)] = .undefined
                case 8: rules[try register(0)] = .same
                case 12:
                    let number = try operand(0), offset = try operand(1)
                    guard [29, 31].contains(number), offset <= UInt64(Int64.max) else {
                        throw failure("CFA requires x29/SP and a bounded unsigned offset")
                    }
                    cfa = (Int(number), Int64(offset))
                case 13:
                    let number = try operand(0)
                    guard let old = cfa, [29, 31].contains(number) else {
                        throw failure("CFA register update lacks a supported prior definition")
                    }
                    cfa = (Int(number), old.1)
                case 14:
                    let offset = try operand(0)
                    guard let old = cfa, offset <= UInt64(Int64.max) else {
                        throw failure("CFA offset update lacks a supported prior definition")
                    }
                    cfa = (old.0, Int64(offset))
                default: throw failure("CFI opcode 0x\(String(operation.opcode, radix: 16)) is outside the evaluation subset")
                }
            }
        }
        try save()
        return rows
    }

    private static func failure(_ message: String) -> UnwindAuditModelError {
        UnwindAuditModelError(code: "dwarf_cfi_unsupported", message: message, address: nil)
    }
}
