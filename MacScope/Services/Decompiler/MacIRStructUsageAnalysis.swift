import Foundation

/// DP04 D1: collects how one explicitly selected root pointer is used, from typed MacIR
/// memory accesses (never pseudocode), as a `StructLayoutCandidate`. Read-only: no
/// persistence, no type catalog or local mutation (D2 accepts candidates).
///
/// A value derives from the root only through exact copies, `+`/`-` of a constant, and
/// phis whose every incoming value is the same derivation; anything else drops it.
/// Register-indexed or non-constant addresses off the root are recorded as unresolved.
public enum MacIRStructUsageAnalysis {
    /// The selected root. A parameter is named by its GPR argument index (x0 = 0).
    public enum Root: Hashable, Sendable {
        case parameter(gprIndex: Int)
        /// A value produced inside the function (a load or call result), by its SSA name.
        case value(MacIRValue)

        public var identity: String {
            switch self {
            case let .parameter(index): "param:x\(index)"
            case let .value(value): "value:\(value.description)"
            }
        }
    }

    /// Bounds the direct-call transfer.
    public struct Budget: Hashable, Sendable {
        public var maximumDepth: Int
        public var maximumFunctions: Int
        public init(maximumDepth: Int = 2, maximumFunctions: Int = 16) {
            self.maximumDepth = maximumDepth
            self.maximumFunctions = maximumFunctions
        }
    }

    /// Resolves a direct call target name to the callee's MacIR (nil = not followed).
    public typealias CalleeResolver = (String) -> MacIRFunction?

    public static func candidate(
        for root: Root,
        in function: MacIRFunction,
        callees: CalleeResolver = { _ in nil },
        budget: Budget = .init()
    ) -> StructLayoutCandidate {
        var visited: Set<UInt64> = [function.startAddress]
        var functionsUsed = 1
        var incomplete: Set<StructLayoutCandidate.Incompleteness> = []
        let summary = summarize(root: root, in: function, callees: callees, budget: budget, depth: 0,
                                visited: &visited, functionsUsed: &functionsUsed, incomplete: &incomplete)
        return StructLayoutCandidate(functionStart: function.startAddress, root: root,
                                     observations: summary.observations,
                                     unresolvedAccessAddresses: summary.unresolvedAccessAddresses,
                                     incompleteness: incomplete)
    }

    // MARK: - Engine

    static func summarize(
        root: Root,
        in function: MacIRFunction,
        callees: CalleeResolver,
        budget: Budget,
        depth: Int,
        visited: inout Set<UInt64>,
        functionsUsed: inout Int,
        incomplete: inout Set<StructLayoutCandidate.Incompleteness>
    ) -> MacIRStructUsageSummary {
        let derived = derivations(of: root, in: function)
        func resolve(_ value: MacIRValue) -> Int64? {
            if let offset = derived[value] { return offset }
            if case let .binaryExpression(op, left, .immediate(constant)) = value,
               op == "+" || op == "-", let base = resolve(left) {
                return op == "+" ? base &+ constant : base &- constant
            }
            return nil
        }
        func touchesRoot(_ value: MacIRValue) -> Bool {
            if derived[value] != nil { return true }
            switch value {
            case let .signedBitfield(node): return touchesRoot(node.source)
            case let .binaryExpression(_, left, right): return touchesRoot(left) || touchesRoot(right)
            case let .unary(_, inner): return touchesRoot(inner)
            default: return false
            }
        }
        var observations: [StructLayoutCandidate.Observation] = []
        var unresolved: [UInt64] = []
        func observe(_ address: MacIRValue, role: StructLayoutCandidate.Role, carrier: MacIRValue,
                     _ instruction: MacIRInstruction) {
            guard let width = instruction.memoryAccess?.byteWidth else { return }
            if let offset = resolve(address) {
                observations.append(.init(offset: offset, byteWidth: width, role: role,
                                          extensionKind: instruction.memoryAccess?.extensionKind ?? .none,
                                          carrier: carrierKind(carrier), sourceAddress: instruction.source.address,
                                          viaCalls: []))
            } else if touchesRoot(address) {
                unresolved.append(instruction.source.address)
            }
        }
        for instruction in function.instructions {
            switch instruction.operation {
            case let .load(destination, address):
                observe(address, role: .read, carrier: destination, instruction)
            case let .store(source, address):
                observe(address, role: .write, carrier: source, instruction)
            case let .loadWriteback(destination, _, baseSource, delta, preIndex):
                observe(preIndex ? .binaryExpression(op: "+", left: baseSource, right: .immediate(delta)) : baseSource,
                        role: .read, carrier: destination, instruction)
            case let .storeWriteback(source, _, baseSource, delta, preIndex):
                observe(preIndex ? .binaryExpression(op: "+", left: baseSource, right: .immediate(delta)) : baseSource,
                        role: .write, carrier: source, instruction)
            case let .call(frame, _):
                for index in 0..<8 {
                    guard let argument = frame.arguments.argument(at: .gpr(index: index))?.value,
                          let offset = resolve(argument) else { continue }
                    let target = frame.target
                    guard isDirectTarget(target), let callee = callees(target) else {
                        incomplete.insert(.unresolvedCall)
                        continue
                    }
                    guard !visited.contains(callee.startAddress) else {
                        incomplete.insert(.recursion)
                        continue
                    }
                    guard depth + 1 <= budget.maximumDepth, functionsUsed < budget.maximumFunctions else {
                        incomplete.insert(.budget)
                        continue
                    }
                    visited.insert(callee.startAddress)
                    functionsUsed += 1
                    let calleeSummary = summarize(root: .parameter(gprIndex: index), in: callee, callees: callees,
                                                  budget: budget, depth: depth + 1, visited: &visited,
                                                  functionsUsed: &functionsUsed, incomplete: &incomplete)
                    visited.remove(callee.startAddress)
                    observations += calleeSummary.shifted(by: offset, via: target).observations
                }
            default:
                break
            }
        }
        return MacIRStructUsageSummary(observations: observations, unresolvedAccessAddresses: unresolved)
    }

    /// Values exactly derived from the root, with their byte offset from it.
    static func derivations(of root: Root, in function: MacIRFunction) -> [MacIRValue: Int64] {
        var derived: [MacIRValue: Int64] = [:]
        switch root {
        case let .parameter(index):
            for parameter in function.parameters {
                guard case let .gpr(gprIndex, _) = parameter.abiLocation, gprIndex == index,
                      let binding = parameter.bindingID else { continue }
                derived[.argument(bindingID: binding)] = 0
            }
            derived[.register(name: "x\(index)", version: 0)] = 0
        case let .value(value):
            derived[value] = 0
        }
        // SSA values: iterate to a fixed point (phis may name later definitions).
        for _ in 0 ..< 8 {
            var changed = false
            func define(_ destination: MacIRValue, _ offset: Int64?) {
                guard let offset, derived[destination] == nil else { return }
                derived[destination] = offset
                changed = true
            }
            for instruction in function.instructions {
                switch instruction.operation {
                case let .assign(destination, source):
                    define(destination, derived[source])
                case let .binary(destination, op, left, .immediate(constant)) where op == "+" || op == "-":
                    define(destination, derived[left].map { op == "+" ? $0 &+ constant : $0 &- constant })
                case let .binary(destination, "+", .immediate(constant), right):
                    define(destination, derived[right].map { $0 &+ constant })
                case let .loadWriteback(_, baseDestination, baseSource, delta, _),
                     let .storeWriteback(_, baseDestination, baseSource, delta, _):
                    define(baseDestination, derived[baseSource].map { $0 &+ delta })
                default:
                    break
                }
            }
            for phi in function.phis {
                let offsets = phi.incoming.map { derived[$0.value] }
                guard let first = offsets.first, let offset = first,
                      offsets.allSatisfy({ $0 == offset }) else { continue }
                define(phi.destination, offset)
            }
            if !changed { break }
        }
        return derived
    }

    private static func isDirectTarget(_ target: String) -> Bool {
        !target.isEmpty && !target.hasPrefix("x") && !target.hasPrefix("*") && !target.contains("(")
    }

    private static func carrierKind(_ value: MacIRValue) -> StructLayoutCandidate.Carrier {
        guard case let .register(name, _) = value, let first = name.lowercased().first else { return .unknown }
        return "xwr".contains(first) ? .gpr : ("qdsbhv".contains(first) ? .simd : .unknown)
    }
}
