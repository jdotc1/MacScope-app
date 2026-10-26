import Foundation

/// DP04 B2 (slice 1): stack storage regions with deterministic local identity,
/// derived from B1's frame accesses. Analysis only; locals and the printer adopt
/// it in the next slice. Never a source of value-forwarding facts.
struct MacIRStackRegionAnalysis: Sendable {
    enum Role: String, Hashable, Sendable {
        /// At or above entry SP: the caller's area (incoming stack arguments).
        case incomingArgument
        /// Only a callee-saved register's spill and its matching reload.
        case savedRegister
        case candidateLocal
    }

    /// Versioned MacIR locator: entry-SP byte range plus the defining store (the
    /// lifetime anchor). Equal inputs give equal locators; a reused interval with a
    /// proven new lifetime gets a different anchor, so it never inherits identity.
    struct Locator: Hashable, Sendable {
        static let schema = 1
        let functionStart: UInt64
        let range: Range<Int64>
        /// The first store of this lifetime; nil when the region is only read.
        let anchor: UInt64?

        var identity: String {
            "macir-stack-v\(Self.schema):\(String(functionStart, radix: 16)):\(range.lowerBound):\(range.upperBound):"
                + (anchor.map { String($0, radix: 16) } ?? "-")
        }
    }

    struct Region: Hashable, Sendable {
        /// The storage group's byte interval (union of overlapping accesses).
        let range: Range<Int64>
        let role: Role
        /// True when the region's address is taken (passed to a call, stored, returned).
        let escapes: Bool
        /// True when accesses of different extents overlap inside the group.
        let hasPartialOverlap: Bool
        let lifetimes: [Locator]
        let accessAddresses: [UInt64]
    }

    let regions: [Region]
    let isComplete: Bool

    private static let calleeSaved: Set<String> = Set((19...30).map { "x\($0)" } + (8...15).map { "d\($0)" } + ["fp", "lr"])

    static func analyze<Row: DecompilerInstructionRow>(
        functionStart: UInt64, rows: [Row], instructions: [MacIRInstruction], frame: MacIRFrameAnalysis
    ) -> Self {
        guard frame.isComplete else { return .init(regions: [], isComplete: false) }
        // Storage groups: union of overlapping access intervals.
        var groups: [(range: Range<Int64>, accesses: [MacIRFrameAnalysis.Access])] = []
        for access in frame.accesses.sorted(by: { ($0.range.lowerBound, $0.address) < ($1.range.lowerBound, $1.address) }) {
            if var last = groups.last, last.range.overlaps(access.range) {
                last.range = min(last.range.lowerBound, access.range.lowerBound)..<max(last.range.upperBound, access.range.upperBound)
                last.accesses.append(access)
                groups[groups.count - 1] = last
            } else {
                groups.append((access.range, [access]))
            }
        }
        let escapedOffsets = escapedStackOffsets(rows: rows, frame: frame)
        let cfg = CFGBuilder.buildCFG(instructions: instructions)
        let straightLine = cfg.blocks.count == 1
        let rowOrder = Dictionary(rows.enumerated().map { ($0.element.address, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let regions = groups.map { group -> Region in
            let accesses = group.accesses.sorted { (rowOrder[$0.address] ?? 0, $0.range.lowerBound) < (rowOrder[$1.address] ?? 0, $1.range.lowerBound) }
            let escapes = escapedOffsets.contains { group.range.contains($0) }
            let partial = Set(accesses.map(\.range)).count > 1
            let role: Role
            if group.range.lowerBound >= 0 {
                role = .incomingArgument
            } else if !escapes, let first = accesses.first, first.isWrite,
                      let register = first.register, calleeSaved.contains(register),
                      accesses.dropFirst().allSatisfy({ !$0.isWrite && $0.register == register && $0.range == first.range }) {
                role = .savedRegister
            } else {
                role = .candidateLocal
            }
            return Region(range: group.range, role: role, escapes: escapes, hasPartialOverlap: partial,
                          lifetimes: lifetimes(functionStart: functionStart, range: group.range, accesses: accesses,
                                               splittable: straightLine && !escapes && !partial),
                          accessAddresses: accesses.map(\.address))
        }
        return .init(regions: regions, isComplete: true)
    }

    /// Lifetimes split only when separation is proven: straight-line code, no escape,
    /// one access extent, and a full overwrite after the previous lifetime was read.
    private static func lifetimes(functionStart: UInt64, range: Range<Int64>,
                                  accesses: [MacIRFrameAnalysis.Access], splittable: Bool) -> [Locator] {
        guard splittable else {
            return [Locator(functionStart: functionStart, range: range, anchor: accesses.first(where: \.isWrite)?.address)]
        }
        var anchors: [UInt64?] = []
        var current: UInt64?
        var readSinceDefinition = false
        var started = false
        for access in accesses {
            if access.isWrite {
                if !started || readSinceDefinition {
                    if started { anchors.append(current) }
                    current = access.address
                    readSinceDefinition = false
                    started = true
                }
            } else {
                if !started { started = true; current = nil }
                readSinceDefinition = true
            }
        }
        if started { anchors.append(current) }
        return anchors.map { Locator(functionStart: functionStart, range: range, anchor: $0) }
    }

    /// Entry-SP offsets whose address leaves the function's control: a stack alias in
    /// an argument register at a call, stored to memory, or in x0 at a return.
    private static func escapedStackOffsets<Row: DecompilerInstructionRow>(rows: [Row],
                                                                           frame: MacIRFrameAnalysis) -> [Int64] {
        var escaped: [Int64] = []
        func note(_ base: MacIRFrameAnalysis.Base?) {
            if case let .entrySP(offset)? = base { escaped.append(offset) }
        }
        for row in rows {
            guard let state = frame.stateBefore[row.address] else { continue }
            let mnemonic = row.mnemonic.lowercased()
            let operands = MacIRBuilder.splitOperands(row.operands)
            switch mnemonic {
            case "bl", "blr", "blraa", "blrab", "blraaz", "blrabz", "b", "br":
                for index in 0...7 { note(state.aliases[index]) }
            case "ret", "retaa", "retab":
                note(state.aliases[0])
            default:
                guard mnemonic.hasPrefix("st"), let memoryIndex = operands.firstIndex(where: { $0.hasPrefix("[") }) else { continue }
                for register in operands[..<memoryIndex] { note(state.value(of: register)) }
            }
        }
        return escaped
    }
}
