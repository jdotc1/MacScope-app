import Foundation
@testable import MacScope

/// Abstract graph lowering for the structurer regression/census harness.
/// Each logical vertex has a visible side effect. An explicit false-edge
/// trampoline makes arbitrary out-degree-two graphs valid linear MacIR.
enum CP2GraphFixture {
    static func addresses(_ edges: [[Int]]) -> [UInt64] {
        var next: UInt64 = 0x1000
        return edges.map { successors in
            defer { next += successors.count == 2 ? 12 : 8 }
            return next
        }
    }

    static func rows(_ edges: [[Int]]) -> [InstructionRow] {
        let starts = addresses(edges)
        var rows: [InstructionRow] = []
        func row(_ a: UInt64, _ m: String, _ o: String, _ c: String? = nil) -> InstructionRow {
            .init(address:a,bytes:"00 00 00 00",mnemonic:m,operands:o,hasBreakpoint:false,comment:c)
        }
        for (node, successors) in edges.enumerated() {
            let a=starts[node]
            rows.append(row(a,"mov","x20, #0x\(String(node,radix:16))","visit_\(node)"))
            switch successors.count {
            case 0: rows.append(row(a+4,"ret",""))
            case 1: rows.append(row(a+4,"b","0x\(String(starts[successors[0]],radix:16))"))
            case 2:
                rows.append(row(a+4,"cbnz","x0, 0x\(String(starts[successors[0]],radix:16))"))
                rows.append(row(a+8,"b","0x\(String(starts[successors[1]],radix:16))"))
            default: preconditionFailure("out-degree must not exceed two")
            }
        }
        return rows
    }

    static func function(_ edges: [[Int]], name: String = "_cp2_graph") -> MacIRFunction {
        let rows=rows(edges)
        var instructions: [MacIRInstruction] = []
        for row in rows {
            let source=MacIRSourceSpan(address:row.address,byteText:row.bytes,mnemonic:row.mnemonic,operands:row.operands,comment:row.comment)
            let op: MacIROperation
            switch row.mnemonic {
            case "mov":
                let node=Int(row.comment!.dropFirst("visit_".count))!
                op = .assign(destination:.register(name:"x20",version:node+1),source:.immediate(Int64(node)))
            case "ret": op = .returnValue(nil)
            case "b": op = .intrinsic(destination:nil,name:"branch",arguments:[.immediate(Int64(row.operands.dropFirst(2),radix:16)!)])
            default:
                let target=String(row.operands.split(separator:" ").last!).dropFirst(2)
                op = .conditionalBranch(condition:"!=",left:.register(name:"x0",version:0),right:.immediate(0),target:.immediate(Int64(target,radix:16)!))
            }
            instructions.append(.init(source:source,operation:op))
        }
        return MacIRFunction(name:name,startAddress:0x1000,endAddress:rows.last!.address+4,instructions:instructions)
    }

    static func reachable(_ edges: [[Int]]) -> Bool {
        guard !edges.isEmpty else { return false }
        var seen: Set<Int> = [0]; var pending=[0]
        while let node=pending.popLast() {
            for next in edges[node] where seen.insert(next).inserted { pending.append(next) }
        }
        return seen.count == edges.count
    }

    static func edgeChoices(_ count:Int) -> [[Int]] {
        var result: [[Int]] = [[]]
        for a in 0..<count { result.append([a]) }
        for a in 0..<count { for b in (a+1)..<count { result.append([a,b]) } }
        return result
    }
}

extension DecompilerOptions {
    /// The shipped defaults with CP2's three recovery switches on. Recovery ships off, so the
    /// recovery tests opt in explicitly.
    static var recoveryOn: DecompilerOptions {
        var options = DecompilerOptions.default
        options.recoverSharedTails = true
        options.recoverLoopExits = true
        options.recoverGuardRegions = true
        return options
    }
}

extension DecompilerOptions {
    /// Semantic fixtures deliberately exercise plans outside the default
    /// readability budget. Separate admission tests cover the shipped budget.
    static var recoveryForSemantics: DecompilerOptions {
        var options = recoveryOn
        options.recoveryMaxTransferRatioPercent = 400
        options.recoveryMaxAdditionalNesting = 16
        return options
    }
}
