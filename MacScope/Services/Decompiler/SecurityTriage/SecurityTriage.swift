import Foundation

public enum SecurityTriageRule: String, Codable, CaseIterable, Sendable {
    case r1UnboundedCopy = "R1"
    case r2AllocationSizeOverflow = "R2"
    case r3NonconstantFormat = "R3"
    case r4UncheckedAllocation = "R4"
    case r5XPCPeerTrust = "R5"

    public var cwe: [String] {
        switch self {
        case .r1UnboundedCopy: ["CWE-120", "CWE-787"]
        case .r2AllocationSizeOverflow: ["CWE-190", "CWE-680"]
        case .r3NonconstantFormat: ["CWE-134"]
        case .r4UncheckedAllocation: ["CWE-690"]
        case .r5XPCPeerTrust: ["CWE-863"]
        }
    }
}

public enum SecurityTriageConfidence: String, Codable, Sendable {
    case definite
    case likely
    case needsReview = "needs-review"
}

public struct SecurityTriageFinding: Codable, Equatable, Sendable {
    public var rule: SecurityTriageRule
    public var cwe: [String]
    public var confidence: SecurityTriageConfidence
    public var evidenceAddresses: [UInt64]
    public var reason: String

    public init(
        rule: SecurityTriageRule,
        confidence: SecurityTriageConfidence,
        evidenceAddresses: [UInt64],
        reason: String
    ) {
        self.rule = rule
        cwe = rule.cwe
        self.confidence = confidence
        self.evidenceAddresses = Array(Set(evidenceAddresses)).sorted()
        self.reason = reason
    }
}

public struct SecurityTriageMitigation: Codable, Equatable, Sendable {
    public var rule: SecurityTriageRule
    public var evidenceAddresses: [UInt64]
    public var reason: String

    public init(rule: SecurityTriageRule, evidenceAddresses: [UInt64], reason: String) {
        self.rule = rule
        self.evidenceAddresses = Array(Set(evidenceAddresses)).sorted()
        self.reason = reason
    }
}

public struct SecurityTriageFunctionReport: Codable, Equatable, Sendable {
    public var functionName: String
    public var functionStartAddress: UInt64
    public var findings: [SecurityTriageFinding]
    public var mitigations: [SecurityTriageMitigation]

    public init(
        functionName: String,
        functionStartAddress: UInt64,
        findings: [SecurityTriageFinding] = [],
        mitigations: [SecurityTriageMitigation] = []
    ) {
        self.functionName = functionName
        self.functionStartAddress = functionStartAddress
        self.findings = findings
        self.mitigations = mitigations
    }
}

public struct SecurityTriageReport: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var functions: [SecurityTriageFunctionReport]

    public init(schemaVersion: Int = 1, functions: [SecurityTriageFunctionReport]) {
        self.schemaVersion = schemaVersion
        self.functions = functions
    }
}

public struct SecurityTriageObjectiveCMethodIdentity: Hashable, Sendable {
    public var ownerName: String
    public var selector: String
    public var isClassMethod: Bool

    public init(ownerName: String, selector: String, isClassMethod: Bool) {
        self.ownerName = ownerName
        self.selector = selector
        self.isClassMethod = isClassMethod
    }
}

public struct SecurityTriageContext: Sendable {
    public var constantStrings: [UInt64: MacIRConstantString]
    public var readOnlyAddressRanges: [Range<UInt64>]
    public var destinationObjectRanges: [Range<UInt64>]
    public var objectiveCMethodsByImplementation: [UInt64: [SecurityTriageObjectiveCMethodIdentity]]
    public var xpcPeerHandlerFunctionAddresses: Set<UInt64>

    public init(
        constantStrings: [UInt64: MacIRConstantString] = [:],
        readOnlyAddressRanges: [Range<UInt64>] = [],
        destinationObjectRanges: [Range<UInt64>] = [],
        objectiveCMethodsByImplementation: [UInt64: [SecurityTriageObjectiveCMethodIdentity]] = [:],
        xpcPeerHandlerFunctionAddresses: Set<UInt64> = []
    ) {
        self.constantStrings = constantStrings
        self.readOnlyAddressRanges = readOnlyAddressRanges
        self.destinationObjectRanges = destinationObjectRanges
        self.objectiveCMethodsByImplementation = objectiveCMethodsByImplementation
        self.xpcPeerHandlerFunctionAddresses = xpcPeerHandlerFunctionAddresses
    }
}

public enum SecurityTriageService {
    /// Read-only security triage over already-built MacIR. The pass never rewrites the function.
    ///
    /// Soundness boundary (v1):
    /// - R1 recognizes catalog-backed copy calls, exact caller-supplied object ranges, constant
    ///   heap-allocation bounds, and simple dominating scalar bounds. Stack object extents are not
    ///   present in MacIR, so constants copied to stack addresses are not declared safe merely
    ///   from the frame size.
    /// - R2 recognizes multiply/shift size expressions and the common `umulh`/`smulh`, dominating
    ///   limit-check, and catalog-backed overflow-builtin shapes. Equivalent arithmetic proofs may
    ///   be missed; computed callees are never guessed from register use.
    /// - R3 requires the catalog's parameter layout and proof that the format address is in a
    ///   caller-supplied read-only range. A resolved string without section authority is not enough.
    /// - R4 follows SSA assignments and phis from catalog-backed allocation results to loads,
    ///   stores, and catalog-backed copy destinations. It recognizes simple dominating NULL tests;
    ///   interprocedural contracts and custom allocators are outside v1.
    /// - R5 identifies Objective-C listener methods only through supplied Objective-C metadata.
    ///   C XPC block-handler membership must likewise be supplied by a caller with block metadata.
    ///
    /// Evidence that crosses a phi/join, natural loop, unknown row, unresolved call, or unresolved
    /// CFG target is conservatively downgraded to `needs-review` and names the reason.
    public static func analyze(
        function: MacIRFunction,
        context: SecurityTriageContext = SecurityTriageContext()
    ) -> SecurityTriageFunctionReport {
        SecurityTriageAnalyzer(function: function, context: context).run()
    }

    public static func report(
        functions: [MacIRFunction],
        context: SecurityTriageContext = SecurityTriageContext()
    ) -> SecurityTriageReport {
        SecurityTriageReport(functions: functions.map { analyze(function: $0, context: context) })
    }
}

private struct SecurityTriageAnalyzer {
    private struct Definition {
        enum Kind {
            case alias(MacIRValue)
            case binary(String, MacIRValue, MacIRValue)
            case load(MacIRValue)
            case call(MacIRCallFrame)
            case select(MacIRValue, MacIRValue)
            case intrinsic(String, [MacIRValue])
            case unknown
        }

        var instructionIndex: Int
        var address: UInt64
        var kind: Kind
    }

    private struct Trace {
        var addresses: Set<UInt64> = []
        var leaves: Set<MacIRValue> = []
        var reviewReasons: Set<String> = []

        mutating func merge(_ other: Trace) {
            addresses.formUnion(other.addresses)
            leaves.formUnion(other.leaves)
            reviewReasons.formUnion(other.reviewReasons)
        }
    }

    private struct CallSite {
        var index: Int
        var address: UInt64
        var frame: MacIRCallFrame
        var result: MacIRValue?
        var canonicalName: String
    }

    private struct AllocationOrigin {
        var site: CallSite
        var size: MacIRValue?
    }

    private let function: MacIRFunction
    private let context: SecurityTriageContext
    private let cfg: CFG
    private let definitions: [MacIRValue: Definition]
    private let phis: [MacIRValue: MacIRPhi]
    private let blockByInstruction: [Int]
    private let loopBlocks: Set<Int>

    init(function: MacIRFunction, context: SecurityTriageContext) {
        self.function = function
        self.context = context
        cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        definitions = Self.makeDefinitions(function.instructions)
        phis = Dictionary(uniqueKeysWithValues: function.phis.map { ($0.destination, $0) })

        var blockMap = [Int](repeating: -1, count: function.instructions.count)
        for block in cfg.blocks {
            for index in block.instructionRange where blockMap.indices.contains(index) {
                blockMap[index] = block.index
            }
        }
        blockByInstruction = blockMap
        loopBlocks = Self.makeLoopBlocks(cfg)
    }

    func run() -> SecurityTriageFunctionReport {
        let sites = callSites()
        var findings: [SecurityTriageFinding] = []
        var mitigations: [SecurityTriageMitigation] = []

        analyzeR1(sites, findings: &findings, mitigations: &mitigations)
        analyzeR2(sites, findings: &findings)
        analyzeR3(sites, findings: &findings)
        analyzeR4(sites, findings: &findings)
        analyzeR5(sites, findings: &findings)

        findings.sort {
            ($0.evidenceAddresses.first ?? 0, $0.rule.rawValue, $0.reason)
                < ($1.evidenceAddresses.first ?? 0, $1.rule.rawValue, $1.reason)
        }
        mitigations.sort {
            ($0.evidenceAddresses.first ?? 0, $0.rule.rawValue, $0.reason)
                < ($1.evidenceAddresses.first ?? 0, $1.rule.rawValue, $1.reason)
        }
        return SecurityTriageFunctionReport(
            functionName: function.name,
            functionStartAddress: function.startAddress,
            findings: findings,
            mitigations: mitigations
        )
    }

    // MARK: - R1: unbounded copy

    private func analyzeR1(
        _ sites: [CallSite],
        findings: inout [SecurityTriageFinding],
        mitigations: inout [SecurityTriageMitigation]
    ) {
        let sizedSinks: [String: Int] = [
            "memcpy": 2, "memmove": 2, "strncpy": 2, "strncat": 2
        ]
        let unboundedSinks: Set<String> = [
            "strcpy", "strcat", "stpcpy", "sprintf", "vsprintf", "gets"
        ]

        for site in sites {
            if fortifyBaseName(site.canonicalName) != nil {
                mitigations.append(SecurityTriageMitigation(
                    rule: .r1UnboundedCopy,
                    evidenceAddresses: [site.address],
                    reason: "FORTIFY checked copy \(site.canonicalName)"
                ))
                continue
            }
            guard sizedSinks[site.canonicalName] != nil
                    || unboundedSinks.contains(site.canonicalName) else { continue }

            if unboundedSinks.contains(site.canonicalName) {
                let trace = traceCallArguments(site.frame)
                findings.append(makeFinding(
                    rule: .r1UnboundedCopy,
                    baseConfidence: .definite,
                    addresses: trace.addresses.union([site.address]),
                    trace: trace,
                    reason: "\(site.canonicalName) has no destination-bound parameter"
                ))
                continue
            }

            guard let lengthPosition = sizedSinks[site.canonicalName],
                  let length = site.frame.arguments.fixedArgument(at: lengthPosition)?.value,
                  let destination = site.frame.arguments.fixedArgument(at: 0)?.value else {
                continue
            }
            let lengthTrace = trace(length)
            let destinationCapacity = knownDestinationCapacity(destination, before: site.index)
            if let constant = resolvedNonnegativeConstant(length),
               let destinationCapacity,
               constant <= destinationCapacity {
                continue
            }
            if let destinationCapacity,
               let guardAddress = dominatingUpperBound(
                   for: length,
                   maximum: destinationCapacity,
                   useIndex: site.index
               ) {
                _ = guardAddress
                continue
            }

            let assumption = destinationCapacity == nil
                ? "destination extent is not represented in MacIR"
                : "no recognized dominating bound limits the copy length"
            findings.append(makeFinding(
                rule: .r1UnboundedCopy,
                baseConfidence: destinationCapacity == nil ? .likely : .definite,
                addresses: lengthTrace.addresses.union([site.address]),
                trace: lengthTrace,
                reason: "\(site.canonicalName) length is not proven within the destination: \(assumption)"
            ))
        }
    }

    // MARK: - R2: allocation-size overflow

    private func analyzeR2(_ sites: [CallSite], findings: inout [SecurityTriageFinding]) {
        for site in sites {
            guard let sizePosition = allocationSizePosition(site.canonicalName),
                  let size = site.frame.arguments.fixedArgument(at: sizePosition)?.value,
                  arithmeticRisk(in: size) != nil else { continue }
            if hasDominatingOverflowCheck(for: size, useIndex: site.index, sites: sites) {
                continue
            }
            let trace = trace(size)
            findings.append(makeFinding(
                rule: .r2AllocationSizeOverflow,
                baseConfidence: .likely,
                addresses: trace.addresses.union([site.address]),
                trace: trace,
                reason: "\(site.canonicalName) size contains \(arithmeticRisk(in: size) ?? "arithmetic") without a recognized overflow check; assumes no equivalent unmodeled proof"
            ))
        }
    }

    // MARK: - R3: non-constant format

    private func analyzeR3(_ sites: [CallSite], findings: inout [SecurityTriageFinding]) {
        for site in sites {
            guard let formatPosition = formatPosition(for: site) else { continue }
            if case let .formatString(evidence)? = site.frame.tailCountEvidence,
               evidence.formatSourcePosition == formatPosition,
               context.constantStrings[evidence.formatAddress] != nil,
               isReadOnly(evidence.formatAddress) {
                continue
            }
            guard let format = site.frame.arguments.fixedArgument(at: formatPosition)?.value else {
                continue
            }
            if let address = resolvedAddress(format),
               context.constantStrings[address] != nil,
               isReadOnly(address) {
                continue
            }
            let trace = trace(format)
            findings.append(makeFinding(
                rule: .r3NonconstantFormat,
                baseConfidence: .definite,
                addresses: trace.addresses.union([site.address]),
                trace: trace,
                reason: "\(site.canonicalName) format is not proven to be a constant string in a read-only section"
            ))
        }
    }

    // MARK: - R4: unchecked allocation

    private func analyzeR4(_ sites: [CallSite], findings: inout [SecurityTriageFinding]) {
        let allocations = sites.compactMap { site -> AllocationOrigin? in
            guard site.result != nil, allocationSizePosition(site.canonicalName) != nil else { return nil }
            let position = allocationSizePosition(site.canonicalName)
            return AllocationOrigin(
                site: site,
                size: position.flatMap { site.frame.arguments.fixedArgument(at: $0)?.value }
            )
        }

        for allocation in allocations {
            guard let result = allocation.site.result else { continue }
            for (index, instruction) in function.instructions.enumerated()
                where index > allocation.site.index {
                guard let useReason = dangerousAllocationUse(
                    of: result,
                    instruction: instruction,
                    callSites: sites
                ) else { continue }
                if dominatingNonNullCheck(for: result, useIndex: index) != nil { break }
                var useTrace = trace(result)
                useTrace.addresses.insert(allocation.site.address)
                useTrace.addresses.insert(instruction.source.address)
                findings.append(makeFinding(
                    rule: .r4UncheckedAllocation,
                    baseConfidence: .definite,
                    addresses: useTrace.addresses,
                    trace: useTrace,
                    reason: "unchecked \(allocation.site.canonicalName) result \(useReason)"
                ))
                break
            }
        }
    }

    // MARK: - R5: XPC peer trust

    private func analyzeR5(_ sites: [CallSite], findings: inout [SecurityTriageFinding]) {
        let identities = context.objectiveCMethodsByImplementation[function.startAddress] ?? []
        let isListenerMethod = identities.contains {
            $0.selector == "listener:shouldAcceptNewConnection:"
        }
        let isCHandler = context.xpcPeerHandlerFunctionAddresses.contains(function.startAddress)
        guard isListenerMethod || isCHandler else { return }

        let selectors = Set(sites.compactMap { site in
            site.frame.arguments.fixedArgument(at: 1)?.selectorEvidence?.name
        })
        let callNames = Set(sites.map(\.canonicalName))
        let trustedSelectors: Set<String> = ["auditToken", "setCodeSigningRequirement:"]
        let trustedCalls: Set<String> = [
            "xpc_connection_get_audit_token", "SecCodeCreateWithXPCMessage",
            "xpc_connection_set_peer_code_signing_requirement"
        ]
        if !selectors.isDisjoint(with: trustedSelectors)
            || !callNames.isDisjoint(with: trustedCalls) {
            return
        }

        let pidSelectors: Set<String> = ["processIdentifier"]
        let pidCalls: Set<String> = ["xpc_connection_get_pid"]
        if !selectors.isDisjoint(with: pidSelectors) || !callNames.isDisjoint(with: pidCalls) {
            let evidence = sites.filter { site in
                pidCalls.contains(site.canonicalName)
                    || site.frame.arguments.fixedArgument(at: 1)
                        .flatMap(\.selectorEvidence).map { pidSelectors.contains($0.name) } == true
            }.map(\.address)
            let trace = traceAcross(addresses: Set(evidence))
            findings.append(makeFinding(
                rule: .r5XPCPeerTrust,
                baseConfidence: .definite,
                addresses: Set(evidence),
                trace: trace,
                reason: "peer trust depends on a process identifier, which is subject to PID reuse"
            ))
            return
        }

        let returns = function.instructions.compactMap { instruction -> (UInt64, MacIRValue?)? in
            guard case let .returnValue(value) = instruction.operation else { return nil }
            return (instruction.source.address, value)
        }
        guard !returns.isEmpty,
              returns.allSatisfy({ _, value in value.flatMap(resolvedNonnegativeConstant) == 1 }) else {
            return
        }
        let addresses = Set(returns.map(\.0))
        findings.append(makeFinding(
            rule: .r5XPCPeerTrust,
            baseConfidence: .definite,
            addresses: addresses,
            trace: traceAcross(addresses: addresses),
            reason: "listener accepts every new connection without peer identity evidence"
        ))
    }

    // MARK: - Call and value authority

    private func callSites() -> [CallSite] {
        function.instructions.enumerated().compactMap { index, instruction in
            guard case let .call(frame, result) = instruction.operation,
                  let canonicalName = canonicalCatalogName(frame) else { return nil }
            return CallSite(
                index: index,
                address: instruction.source.address,
                frame: frame,
                result: result,
                canonicalName: canonicalName
            )
        }
    }

    /// A call is eligible only when MacIR attached a catalog/SDK signature. The target string of an
    /// unresolved frame is deliberately insufficient, even if it resembles a well-known symbol.
    private func canonicalCatalogName(_ frame: MacIRCallFrame) -> String? {
        guard let signature = frame.knownSignature else { return nil }
        var name = signature.target
        if name.hasPrefix("_") { name.removeFirst() }
        if let suffix = name.firstIndex(of: "$") { name = String(name[..<suffix]) }
        return name
    }

    private func fortifyBaseName(_ name: String) -> String? {
        guard name.hasPrefix("__"), name.hasSuffix("_chk") else { return nil }
        let start = name.index(name.startIndex, offsetBy: 2)
        let end = name.index(name.endIndex, offsetBy: -4)
        let base = String(name[start..<end])
        return ["memcpy", "memmove", "strcpy", "strcat", "stpcpy", "sprintf", "vsprintf",
                "strncpy", "strncat"].contains(base) ? base : nil
    }

    private func allocationSizePosition(_ name: String) -> Int? {
        switch name {
        case "malloc", "valloc", "operator new", "operator new[]": 0
        case "realloc": 1
        case "aligned_alloc": 1
        case "posix_memalign": 2
        default: nil
        }
    }

    private func formatPosition(for site: CallSite) -> Int? {
        if let format = site.frame.knownSignature?.format {
            return format.formatIndex - 1
        }
        return switch site.canonicalName {
        case "printf", "vprintf", "NSLog": 0
        case "fprintf", "vfprintf", "dprintf", "vdprintf", "syslog", "vsyslog": 1
        case "sprintf", "vsprintf": 1
        case "snprintf", "vsnprintf": 2
        case "_os_log_impl", "_os_log_debug_impl", "_os_log_error_impl", "_os_log_fault_impl": 3
        default: nil
        }
    }

    private func isReadOnly(_ address: UInt64) -> Bool {
        context.readOnlyAddressRanges.contains { $0.contains(address) }
    }

    // MARK: - Data flow

    private func trace(_ value: MacIRValue) -> Trace {
        var visited: Set<MacIRValue> = []
        return trace(value, visited: &visited, depth: 0)
    }

    private func trace(_ value: MacIRValue, visited: inout Set<MacIRValue>, depth: Int) -> Trace {
        guard depth < 64, visited.insert(value).inserted else {
            return Trace(reviewReasons: ["cyclic or over-deep value provenance"])
        }
        defer { visited.remove(value) }

        switch value {
        case let .signedBitfield(node):
            return trace(node.source, visited: &visited, depth: depth + 1)
        case let .unary(_, nested), let .bitTest(nested, _):
            return trace(nested, visited: &visited, depth: depth + 1)
        case let .binaryExpression(_, left, right):
            var result = trace(left, visited: &visited, depth: depth + 1)
            result.merge(trace(right, visited: &visited, depth: depth + 1))
            return result
        case let .abiComposite(_, fragments):
            return fragments.reduce(into: Trace()) {
                $0.merge(trace($1, visited: &visited, depth: depth + 1))
            }
        case .unknown:
            return Trace(leaves: [value], reviewReasons: ["value provenance reaches an unknown line"])
        default:
            break
        }

        if let phi = phis[value] {
            var result = Trace(addresses: [phi.blockAddress], reviewReasons: ["value provenance crosses a join"])
            for incoming in phi.incoming {
                if let address = incoming.machineAddress { result.addresses.insert(address) }
                result.merge(trace(incoming.value, visited: &visited, depth: depth + 1))
            }
            return result
        }
        guard let definition = definitions[value] else {
            return Trace(leaves: [value])
        }

        var result = Trace(addresses: [definition.address])
        switch definition.kind {
        case let .alias(source):
            result.merge(trace(source, visited: &visited, depth: depth + 1))
        case let .binary(_, left, right):
            result.merge(trace(left, visited: &visited, depth: depth + 1))
            result.merge(trace(right, visited: &visited, depth: depth + 1))
        case let .load(address):
            result.merge(trace(address, visited: &visited, depth: depth + 1))
            result.reviewReasons.insert("value provenance crosses an unresolved memory load")
        case let .call(frame):
            if frame.knownSignature == nil {
                result.reviewReasons.insert("value provenance crosses an unresolved call")
            }
            result.leaves.insert(value)
        case let .select(trueValue, falseValue):
            result.merge(trace(trueValue, visited: &visited, depth: depth + 1))
            result.merge(trace(falseValue, visited: &visited, depth: depth + 1))
            result.reviewReasons.insert("value provenance crosses a join")
        case let .intrinsic(name, arguments):
            for argument in arguments {
                result.merge(trace(argument, visited: &visited, depth: depth + 1))
            }
            if name.hasPrefix("branch_") == false {
                result.reviewReasons.insert("value provenance crosses intrinsic \(name)")
            }
        case .unknown:
            result.reviewReasons.insert("value provenance reaches an unknown line")
        }
        return result
    }

    private func traceCallArguments(_ frame: MacIRCallFrame) -> Trace {
        var result = Trace()
        for position in 0..<(frame.knownSignature?.parameters.count ?? 0) {
            if let value = frame.arguments.fixedArgument(at: position)?.value {
                result.merge(trace(value))
            }
        }
        return result
    }

    private func traceAcross(addresses: Set<UInt64>) -> Trace {
        var result = Trace(addresses: addresses)
        addCrossingHazards(to: &result)
        return result
    }

    private func resolvedNonnegativeConstant(_ value: MacIRValue) -> UInt64? {
        var visited: Set<MacIRValue> = []
        return resolvedNonnegativeConstant(value, visited: &visited)
    }

    private func resolvedNonnegativeConstant(
        _ value: MacIRValue,
        visited: inout Set<MacIRValue>
    ) -> UInt64? {
        guard visited.insert(value).inserted else { return nil }
        defer { visited.remove(value) }
        switch value {
        case let .immediate(raw) where raw >= 0:
            return UInt64(raw)
        case let .unary(op, nested):
            guard let constant = resolvedNonnegativeConstant(nested, visited: &visited) else {
                return nil
            }
            switch op {
            case "+", "(uint64_t)", "(size_t)":
                return constant
            case "(uint32_t)":
                return constant & UInt64(UInt32.max)
            case "(uint16_t)":
                return constant & UInt64(UInt16.max)
            case "(uint8_t)":
                return constant & UInt64(UInt8.max)
            default:
                return nil
            }
        case let .binaryExpression(op, left, right):
            return foldConstant(op, left, right, visited: &visited)
        default:
            break
        }
        guard let definition = definitions[value] else { return nil }
        switch definition.kind {
        case let .alias(source):
            return resolvedNonnegativeConstant(source, visited: &visited)
        case let .binary(op, left, right):
            return foldConstant(op, left, right, visited: &visited)
        default:
            return nil
        }
    }

    private func foldConstant(
        _ op: String,
        _ left: MacIRValue,
        _ right: MacIRValue,
        visited: inout Set<MacIRValue>
    ) -> UInt64? {
        guard let lhs = resolvedNonnegativeConstant(left, visited: &visited),
              let rhs = resolvedNonnegativeConstant(right, visited: &visited) else { return nil }
        switch op {
        case "+":
            let value = lhs.addingReportingOverflow(rhs)
            return value.overflow ? nil : value.partialValue
        case "*":
            let value = lhs.multipliedReportingOverflow(by: rhs)
            return value.overflow ? nil : value.partialValue
        case "<<" where rhs < 64:
            guard lhs <= UInt64.max >> rhs else { return nil }
            return lhs << rhs
        default:
            return nil
        }
    }

    private func resolvedAddress(_ value: MacIRValue) -> UInt64? {
        var visited: Set<MacIRValue> = []
        return resolvedAddress(value, visited: &visited)
    }

    private func resolvedAddress(
        _ value: MacIRValue,
        visited: inout Set<MacIRValue>
    ) -> UInt64? {
        guard visited.insert(value).inserted else { return nil }
        defer { visited.remove(value) }
        switch value {
        case let .immediate(raw) where raw >= 0:
            return UInt64(raw)
        case let .unary(op, nested) where op == "+":
            return resolvedAddress(nested, visited: &visited)
        case let .binaryExpression("+", left, right):
            return foldedAddress(left, right, visited: &visited)
        default:
            break
        }
        guard let definition = definitions[value] else { return nil }
        switch definition.kind {
        case let .alias(source):
            return resolvedAddress(source, visited: &visited)
        case let .binary("+", left, right):
            return foldedAddress(left, right, visited: &visited)
        case let .intrinsic(name, arguments):
            // MacIRBuilder emits this only from the disassembler's resolved absolute page base.
            guard name == "adrp", arguments.count == 1 else { return nil }
            return resolvedAddress(arguments[0], visited: &visited)
        default:
            return nil
        }
    }

    private func foldedAddress(
        _ left: MacIRValue,
        _ right: MacIRValue,
        visited: inout Set<MacIRValue>
    ) -> UInt64? {
        guard let base = resolvedAddress(left, visited: &visited),
              let offset = resolvedNonnegativeConstant(right) else { return nil }
        let sum = base.addingReportingOverflow(offset)
        return sum.overflow ? nil : sum.partialValue
    }

    private func valuesOverlap(_ lhs: MacIRValue, _ rhs: MacIRValue) -> Bool {
        if lhs == rhs { return true }
        let left = trace(lhs).leaves
        let right = trace(rhs).leaves
        return !left.isDisjoint(with: right)
    }

    private func contains(_ candidate: MacIRValue, in value: MacIRValue) -> Bool {
        if valuesOverlap(candidate, value) { return true }
        switch value {
        case let .signedBitfield(node):
            return contains(candidate, in: node.source)
        case let .unary(_, nested), let .bitTest(nested, _):
            return contains(candidate, in: nested)
        case let .binaryExpression(_, left, right):
            return contains(candidate, in: left) || contains(candidate, in: right)
        case let .abiComposite(_, fragments):
            return fragments.contains { contains(candidate, in: $0) }
        default:
            return false
        }
    }

    // MARK: - Bounds, checks, and uses

    private func knownDestinationCapacity(_ value: MacIRValue, before index: Int) -> UInt64? {
        if let address = resolvedAddress(value),
           let range = context.destinationObjectRanges.first(where: { $0.contains(address) }) {
            return range.upperBound - address
        }
        if let origin = allocationOrigin(of: value, before: index),
           let size = origin.size,
           let capacity = resolvedNonnegativeConstant(size) {
            return capacity
        }

        // Scalar CFG projection can replace a direct alias chain with a phi whose non-live arm
        // has no definition. Accept the allocation capacity only when the destination's entire
        // provenance still collapses to one catalog-backed allocation result. An offset, mixed
        // phi, unknown value, or other source adds another leaf and therefore cannot pass.
        let leaves = trace(value).leaves
        guard leaves.count == 1, let soleLeaf = leaves.first else { return nil }
        for (candidateIndex, instruction) in function.instructions.enumerated().reversed()
            where candidateIndex < index {
            guard case let .call(frame, result?) = instruction.operation,
                  result == soleLeaf,
                  let name = canonicalCatalogName(frame),
                  let position = allocationSizePosition(name),
                  let size = frame.arguments.fixedArgument(at: position)?.value,
                  let capacity = resolvedNonnegativeConstant(size) else { continue }
            return capacity
        }
        return nil
    }

    private func allocationOrigin(
        of value: MacIRValue,
        before index: Int,
        visited: inout Set<MacIRValue>
    ) -> AllocationOrigin? {
        guard visited.insert(value).inserted else { return nil }
        defer { visited.remove(value) }
        if let phi = phis[value] {
            let origins = phi.incoming.compactMap {
                allocationOrigin(of: $0.value, before: index, visited: &visited)
            }
            guard origins.count == phi.incoming.count,
                  let first = origins.first,
                  origins.dropFirst().allSatisfy({ $0.site.address == first.site.address }) else {
                return nil
            }
            return first
        }
        guard let definition = definitions[value], definition.instructionIndex < index else { return nil }
        switch definition.kind {
        case let .alias(source):
            return allocationOrigin(of: source, before: index, visited: &visited)
        case let .select(trueValue, falseValue):
            guard let trueOrigin = allocationOrigin(of: trueValue, before: index, visited: &visited),
                  let falseOrigin = allocationOrigin(of: falseValue, before: index, visited: &visited),
                  trueOrigin.site.address == falseOrigin.site.address else { return nil }
            return trueOrigin
        case let .call(frame):
            guard let name = canonicalCatalogName(frame),
                  let position = allocationSizePosition(name) else { return nil }
            let site = CallSite(
                index: definition.instructionIndex,
                address: definition.address,
                frame: frame,
                result: value,
                canonicalName: name
            )
            return AllocationOrigin(
                site: site,
                size: frame.arguments.fixedArgument(at: position)?.value
            )
        default:
            return nil
        }
    }

    private func allocationOrigin(of value: MacIRValue, before index: Int) -> AllocationOrigin? {
        var visited: Set<MacIRValue> = []
        return allocationOrigin(of: value, before: index, visited: &visited)
    }

    private func dominatingUpperBound(
        for value: MacIRValue,
        maximum: UInt64,
        useIndex: Int
    ) -> UInt64? {
        for (index, instruction) in function.instructions.enumerated() where index < useIndex {
            guard case let .conditionalBranch(condition, left, right, _) = instruction.operation,
                  let arm = dominatingArm(branchIndex: index, useIndex: useIndex) else { continue }
            let valueOnLeft: Bool
            let bound: UInt64
            if valuesOverlap(value, left), let candidate = resolvedNonnegativeConstant(right) {
                valueOnLeft = true
                bound = candidate
            } else if valuesOverlap(value, right),
                      let candidate = resolvedNonnegativeConstant(left) {
                valueOnLeft = false
                bound = candidate
            } else {
                continue
            }
            guard bound <= maximum,
                  predicateGuaranteesUpperBound(
                    condition: condition,
                    predicateIsTrue: arm,
                    valueOnLeft: valueOnLeft
                  ) else { continue }
            return instruction.source.address
        }
        return nil
    }

    private func dominatingNonNullCheck(for value: MacIRValue, useIndex: Int) -> UInt64? {
        for (index, instruction) in function.instructions.enumerated() where index < useIndex {
            guard case let .conditionalBranch(condition, left, right, _) = instruction.operation,
                  let arm = dominatingArm(branchIndex: index, useIndex: useIndex) else { continue }
            let comparesValueToZero = (valuesOverlap(value, left) && resolvedNonnegativeConstant(right) == 0)
                || (valuesOverlap(value, right) && resolvedNonnegativeConstant(left) == 0)
            guard comparesValueToZero,
                  predicateGuaranteesNonzero(condition: condition, predicateIsTrue: arm) else { continue }
            return instruction.source.address
        }
        return nil
    }

    /// Returns whether the branch predicate is true on the unique successor that dominates the use.
    private func dominatingArm(branchIndex: Int, useIndex: Int) -> Bool? {
        guard blockByInstruction.indices.contains(branchIndex),
              blockByInstruction.indices.contains(useIndex) else { return nil }
        let branchBlock = blockByInstruction[branchIndex]
        let useBlock = blockByInstruction[useIndex]
        guard branchBlock >= 0, useBlock >= 0,
              cfg.blocks.indices.contains(branchBlock),
              cfg.blocks[branchBlock].successors.count == 2,
              CFGBuilder.dominates(branchBlock, useBlock, domTree: cfg.domTree) else { return nil }
        let successors = cfg.blocks[branchBlock].successors
        let reaches = successors.map { CFGBuilder.dominates($0, useBlock, domTree: cfg.domTree) }
        guard reaches.filter({ $0 }).count == 1 else { return nil }
        return reaches[0]
    }

    private func predicateGuaranteesUpperBound(
        condition: String,
        predicateIsTrue: Bool,
        valueOnLeft: Bool
    ) -> Bool {
        let relation = valueOnLeft ? condition : reversed(condition)
        if predicateIsTrue {
            return ["<", "<=", "=="].contains(relation)
        }
        return [">", ">=", "!="].contains(relation)
    }

    private func predicateGuaranteesNonzero(condition: String, predicateIsTrue: Bool) -> Bool {
        if predicateIsTrue { return ["!=", "<", ">"].contains(condition) }
        return ["==", "<=", ">="].contains(condition)
    }

    private func reversed(_ condition: String) -> String {
        switch condition {
        case "<": ">"
        case "<=": ">="
        case ">": "<"
        case ">=": "<="
        default: condition
        }
    }

    private func arithmeticRisk(in value: MacIRValue) -> String? {
        switch value {
        case let .signedBitfield(node):
            return arithmeticRisk(in: node.source)
        case let .binaryExpression(op, left, right):
            if op == "*", resolvedNonnegativeConstant(left) == nil,
               resolvedNonnegativeConstant(right) == nil { return "a product of non-constant values" }
            if ["<<", "lsl"].contains(op), resolvedNonnegativeConstant(left) == nil {
                return "a shifted non-constant value"
            }
        default:
            break
        }
        guard let definition = definitions[value] else { return nil }
        switch definition.kind {
        case let .alias(source):
            return arithmeticRisk(in: source)
        case let .binary(op, left, right):
            if ["*", "mul"].contains(op), resolvedNonnegativeConstant(left) == nil,
               resolvedNonnegativeConstant(right) == nil { return "a product of non-constant values" }
            if ["<<", "lsl"].contains(op), resolvedNonnegativeConstant(left) == nil {
                return "a shifted non-constant value"
            }
            return nil
        default:
            return nil
        }
    }

    private func hasDominatingOverflowCheck(
        for size: MacIRValue,
        useIndex: Int,
        sites: [CallSite]
    ) -> Bool {
        if sites.contains(where: {
            $0.index < useIndex && $0.canonicalName.lowercased().contains("mul_overflow")
                && CFGBuilder.dominates(
                    blockByInstruction[$0.index],
                    blockByInstruction[useIndex],
                    domTree: cfg.domTree
                )
        }) {
            return true
        }

        for (index, instruction) in function.instructions.enumerated() where index < useIndex {
            let mnemonic = instruction.source.mnemonic.lowercased()
            guard mnemonic == "umulh" || mnemonic == "smulh" else { continue }
            for (branchIndex, branch) in function.instructions.enumerated()
                where branchIndex > index && branchIndex < useIndex {
                guard case let .conditionalBranch(condition, left, right, _) = branch.operation,
                      let arm = dominatingArm(branchIndex: branchIndex, useIndex: useIndex),
                      condition == "==" || condition == "!=",
                      resolvedNonnegativeConstant(left) == 0 || resolvedNonnegativeConstant(right) == 0,
                      (condition == "==") == arm else { continue }
                return true
            }
        }

        // A dominating comparison of one multiplication operand against SIZE_MAX / the other is
        // accepted only when the divide relation remains explicit in MacIR.
        let sizeTrace = trace(size)
        for (index, instruction) in function.instructions.enumerated() where index < useIndex {
            guard case let .conditionalBranch(_, left, right, _) = instruction.operation,
                  dominatingArm(branchIndex: index, useIndex: useIndex) != nil else { continue }
            if [left, right].contains(where: { value in
                guard case let .binaryExpression(op, _, divisor) = value,
                      ["/", "udiv"].contains(op) else { return false }
                return !trace(divisor).leaves.isDisjoint(with: sizeTrace.leaves)
            }) {
                return true
            }
        }
        return false
    }

    private func dangerousAllocationUse(
        of result: MacIRValue,
        instruction: MacIRInstruction,
        callSites: [CallSite]
    ) -> String? {
        switch instruction.operation {
        case let .load(_, address), let .store(_, address):
            return contains(result, in: address) ? "is dereferenced" : nil
        case let .loadWriteback(_, _, base, _, _), let .storeWriteback(_, _, base, _, _):
            return contains(result, in: base) ? "is dereferenced" : nil
        case let .call(frame, _):
            guard let name = canonicalCatalogName(frame),
                  ["memcpy", "memmove", "strcpy", "strcat", "stpcpy", "strncpy", "strncat"]
                    .contains(name),
                  let destination = frame.arguments.fixedArgument(at: 0)?.value,
                  contains(result, in: destination) else { return nil }
            return "is passed to copy sink \(name)"
        default:
            return nil
        }
    }

    // MARK: - Confidence

    private func makeFinding(
        rule: SecurityTriageRule,
        baseConfidence: SecurityTriageConfidence,
        addresses: Set<UInt64>,
        trace: Trace,
        reason: String
    ) -> SecurityTriageFinding {
        var combined = trace
        combined.addresses.formUnion(addresses)
        addCrossingHazards(to: &combined)
        let review = combined.reviewReasons.sorted()
        let confidence: SecurityTriageConfidence = review.isEmpty ? baseConfidence : .needsReview
        let suffix = review.isEmpty ? "" : "; needs review because " + review.joined(separator: ", ")
        return SecurityTriageFinding(
            rule: rule,
            confidence: confidence,
            evidenceAddresses: Array(combined.addresses),
            reason: reason + suffix
        )
    }

    private func addCrossingHazards(to trace: inout Trace) {
        guard let lower = trace.addresses.min(), let upper = trace.addresses.max() else { return }
        if cfg.hasUnresolvedTargets {
            trace.reviewReasons.insert("the CFG has an unresolved target")
        }
        for (index, instruction) in function.instructions.enumerated()
            where instruction.source.address >= lower && instruction.source.address <= upper {
            let block = blockByInstruction.indices.contains(index) ? blockByInstruction[index] : -1
            if loopBlocks.contains(block) {
                trace.reviewReasons.insert("the evidence crosses a loop backedge")
            }
            switch instruction.operation {
            case .unknown:
                trace.reviewReasons.insert("the evidence crosses an unknown line")
            case let .call(frame, _) where frame.knownSignature == nil:
                trace.reviewReasons.insert("the evidence crosses an unresolved call")
            default:
                break
            }
        }
    }

    // MARK: - Index construction

    private static func makeDefinitions(_ instructions: [MacIRInstruction]) -> [MacIRValue: Definition] {
        var result: [MacIRValue: Definition] = [:]
        for (index, instruction) in instructions.enumerated() {
            let address = instruction.source.address
            func record(_ destination: MacIRValue, _ kind: Definition.Kind) {
                result[destination] = Definition(
                    instructionIndex: index,
                    address: address,
                    kind: kind
                )
            }
            switch instruction.operation {
            case let .assign(destination, source):
                record(destination, .alias(source))
            case let .binary(destination, op, left, right):
                record(destination, .binary(op, left, right))
            case let .load(destination, address):
                record(destination, .load(address))
            case let .stackSlotRead(destination, _, value):
                record(destination, .alias(value))
            case let .stackSlotPairRead(first, _, firstValue, second, _, secondValue):
                record(first, .alias(firstValue))
                record(second, .alias(secondValue))
            case let .call(frame, resultValue):
                if let resultValue { record(resultValue, .call(frame)) }
            case let .select(destination, _, _, _, trueValue, falseValue):
                record(destination, .select(trueValue, falseValue))
            case let .compareToBool(destination, _, left, right):
                record(destination, .binary("compare", left, right))
            case let .intrinsic(destination, name, arguments):
                if let destination { record(destination, .intrinsic(name, arguments)) }
            case let .unknown(destination, _, _, _):
                if let destination { record(destination, .unknown) }
            case let .loadWriteback(destination, baseDestination, baseSource, delta, _):
                record(destination, .load(baseSource))
                record(baseDestination, .binary("+", baseSource, .immediate(delta)))
            case let .storeWriteback(_, baseDestination, baseSource, delta, _):
                record(baseDestination, .binary("+", baseSource, .immediate(delta)))
            default:
                break
            }
        }
        return result
    }

    private static func makeLoopBlocks(_ cfg: CFG) -> Set<Int> {
        var result: Set<Int> = []
        for edge in cfg.backEdges {
            var members: Set<Int> = [edge.to, edge.from]
            var pending = [edge.from]
            while let block = pending.popLast() {
                if block == edge.to { continue }
                for predecessor in cfg.blocks[block].predecessors where members.insert(predecessor).inserted {
                    pending.append(predecessor)
                }
            }
            result.formUnion(members)
        }
        return result
    }
}
