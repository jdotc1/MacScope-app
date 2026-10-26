import Foundation

/// `proof.function-start-structural@1`: a loader-only proof that an address is a function start.
///
/// Subject `function:<entry>`, predicate `isFunctionStart`, value `true`. Premises, every one a
/// resolvable loader record:
///   (a) the entry lies in an executable section (`S_ATTR_PURE_INSTRUCTIONS`, or `__TEXT,__text`);
///   (b) the entry is 4-byte aligned;
///   (c) at least one loader table lists it: `LC_FUNCTION_STARTS` (`functionStarts[<i>]@<address>`),
///       the export table (`exports[<i>]@<address>`), an N_SECT symbol (`nlist[<i>]@<address>`), or a
///       compact-unwind entry (`unwind[<i>]@<address>`).
/// Outcome `proven` when all three hold; otherwise `insufficientEvidence` (absence from the tables
/// is not disproof, so the rule never yields `refuted`). No decoder is involved.
enum FunctionStartStructuralProof {
    static let rule = "proof.function-start-structural"
    static let ruleVersion = "1"
    static let predicate = "isFunctionStart"
    /// The loader tables premise (c) searches, in search order.
    static let tablesSearched = NavigatorProvenanceRef.tables
    static let assumptions = ["macho.slice-identity: the Mach-O load commands describe this slice"]
    static let trustedBase = ["MachOParser", "MachOUnwindFunctionStarts.resolvedRows", "NavigatorProvenanceResolver"]

    struct Output: Hashable {
        let result: NavigatorPrimitiveResult
        /// The certificate of every run that reached a verdict (proven, insufficientEvidence, timeout,
        /// cancelled); nil only when the certificate itself could not be built.
        let certificate: NavigatorProofCertificate?
    }

    /// The rule entry that leads a fact's provenance, so the fact id carries `rule@ruleVersion`.
    static var ruleProvenance: NavigatorProvenance {
        NavigatorProvenance(kind: "rule", ref: NavigatorProvenanceRef.rule(id: rule, version: ruleVersion).ref,
                            rule: rule, ruleVersion: ruleVersion)
    }

    static func subject(entry: UInt64, evidence: NavigatorImageEvidence) -> NavigatorSubject {
        NavigatorSubject(kind: "function", ref: NavigatorSubjectRef.function(entry: entry), image: evidence.image)
    }

    /// Premise (a): the `section[<segment>,<name>]` record of the executable section holding `entry`.
    static func sectionPremise(entry: UInt64, evidence: NavigatorImageEvidence) -> NavigatorProvenance? {
        guard let section = evidence.section(containing: entry), NavigatorImageEvidence.isExecutable(section) else {
            return nil
        }
        return NavigatorProvenanceRef.section(segment: section.segmentName, name: section.sectionName).provenance
    }

    /// Premise (c): every table entry that lists `entry` and resolves, preceded by the load command
    /// (or section header) that holds each table, in `tablesSearched` order.
    static func tableHits(entry: UInt64, evidence: NavigatorImageEvidence) -> [NavigatorProvenance] {
        var premises: [NavigatorProvenance] = []
        for table in tablesSearched {
            premises += hits(in: table, entry: entry, evidence: evidence)
        }
        return premises
    }

    /// Entries of one table that list `entry`, each resolvable, preceded by their container records.
    static func hits(in table: String, entry: UInt64, evidence: NavigatorImageEvidence) -> [NavigatorProvenance] {
        let indices: [Int]
        switch table {
        case "functionStarts": indices = evidence.functionStartHits(entry)
        case "exports": indices = evidence.exportHits(entry)
        case "nlist": indices = evidence.sectionSymbolHits(entry)
        case "unwind": indices = evidence.unwindHits(entry)
        default: indices = []
        }
        var entries: [NavigatorProvenance] = []
        var containers: [NavigatorProvenance] = []
        for index in indices.sorted() {
            let premise = NavigatorProvenanceRef.tableEntry(table: table, index: index, address: entry).provenance
            guard NavigatorProvenanceResolver.resolve(premise, in: evidence).isResolved else { continue }
            entries.append(premise)
            let container: NavigatorProvenance?
            switch table {
            case "functionStarts":
                container = evidence.functionStartsCommand.map { NavigatorProvenanceRef.loadCommand(index: $0).provenance }
            case "nlist":
                container = evidence.symtabCommand.map { NavigatorProvenanceRef.loadCommand(index: $0).provenance }
            case "exports":
                let commandIndex = evidence.file.exports[index].symbolIndex == nil
                    ? evidence.exportTrieCommand : evidence.symtabCommand
                container = commandIndex.map { NavigatorProvenanceRef.loadCommand(index: $0).provenance }
            case "unwind":
                container = evidence.unwindSection.map {
                    NavigatorProvenanceRef.section(segment: $0.segmentName, name: $0.sectionName).provenance
                }
            default:
                container = nil
            }
            if let container, !containers.contains(container) { containers.append(container) }
        }
        return containers + entries
    }

    /// Runs the proof for `entry`. `clock` returns milliseconds; `wallMillisLimit` bounds the run and
    /// `isCancelled` is polled between steps. `generation` and `dependsOn` stamp the fact or frontier
    /// item the run lands. Never throws: a contract failure becomes a refusal.
    static func run(entry: UInt64, evidence: NavigatorImageEvidence, toolchain: String,
                    generation: NavigatorGeneration? = nil, dependsOn: [String]? = nil,
                    wallMillisLimit: Int64? = nil,
                    clock: () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) },
                    isCancelled: () -> Bool = { false }) -> Output {
        let started = clock()
        let subject = Self.subject(entry: entry, evidence: evidence)
        let address = NavigatorSubjectRef.address(entry)

        var premises: [NavigatorProvenance] = []
        var stop = interruption(started: started, limit: wallMillisLimit, clock: clock, isCancelled: isCancelled)

        // (a) executable section, (b) alignment.
        let section = stop == nil ? sectionPremise(entry: entry, evidence: evidence) : nil
        if let section { premises.append(section) }
        let aligned = entry % 4 == 0

        // (c) table membership, one table at a time so a budget or cancellation stops between tables.
        var listedBy: [String] = []
        if stop == nil {
            for table in tablesSearched {
                if let reason = interruption(started: started, limit: wallMillisLimit, clock: clock,
                                             isCancelled: isCancelled) {
                    stop = reason
                    break
                }
                let found = hits(in: table, entry: entry, evidence: evidence)
                if found.contains(where: { $0.ref.hasPrefix(table + "[") }) { listedBy.append(table) }
                for premise in found where !premises.contains(premise) { premises.append(premise) }
            }
        }
        if stop == nil {
            stop = interruption(started: started, limit: wallMillisLimit, clock: clock, isCancelled: isCancelled)
        }

        var bytesRead: Int64 = 0
        for premise in premises {
            if let range = NavigatorProvenanceResolver.resolve(premise, in: evidence).range {
                bytesRead += Int64(range.count)
            }
        }

        let outcome: NavigatorProofCertificate.Outcome
        let conclusion: String
        if let stop {
            outcome = stop
            conclusion = "\(address): run stopped (\(stop.rawValue)) before every table was searched"
        } else if section != nil, aligned, !listedBy.isEmpty {
            outcome = .proven
            let sectionName = section.map(\.ref) ?? ""
            conclusion = "\(address) lies in executable \(sectionName), is 4-byte aligned and is listed by "
                + listedBy.joined(separator: ", ") + "; isFunctionStart = true"
        } else {
            outcome = .insufficientEvidence
            var missing: [String] = []
            if section == nil { missing.append("not in an executable section") }
            if !aligned { missing.append("not 4-byte aligned") }
            if listedBy.isEmpty { missing.append("listed by no loader table") }
            conclusion = "\(address): " + missing.joined(separator: "; ") + "; isFunctionStart not established"
        }
        let wallMs = max(0, clock() - started)
        let budget: [String: Int64] = ["bytes": bytesRead, "wallMillis": wallMs]

        let certificate: NavigatorProofCertificate
        do {
            certificate = try NavigatorProofCertificate.make(
                rule: rule, ruleVersion: ruleVersion, subject: subject, predicate: predicate, value: .bool(true),
                premises: premises, assumptions: assumptions, conclusion: conclusion, trustedBase: trustedBase,
                outcome: outcome, budget: .init(wallMs: wallMs, bytesRead: bytesRead))
        } catch {
            return Output(result: refusal(subject, budget, "malformedInput", describe(error), retryable: false),
                          certificate: nil)
        }

        switch outcome {
        case .proven:
            do {
                let fact = try NavigatorFact.make(
                    subject: subject, predicate: predicate, value: .bool(true), status: "proven",
                    provenance: [ruleProvenance, certificate.reference] + premises, toolchain: toolchain,
                    generation: generation, dependsOn: dependsOn)
                return Output(result: NavigatorPrimitiveResult(primitive: rule, primitiveVersion: ruleVersion,
                                                               subject: subject, budget: budget, facts: [fact]),
                              certificate: certificate)
            } catch {
                return Output(result: refusal(subject, budget, "malformedInput", describe(error), retryable: false),
                              certificate: certificate)
            }
        case .insufficientEvidence, .refuted:
            var missingEvidence: [String] = []
            if section == nil { missingEvidence.append("executableSection") }
            if !aligned { missingEvidence.append("alignment") }
            if listedBy.isEmpty { missingEvidence += tablesSearched }
            do {
                let item = try NavigatorFrontierItem.make(
                    subject: subject, gap: "boundaryUncertain",
                    detail: "\(address): " + (listedBy.isEmpty
                        ? "no loader table lists the address (searched \(tablesSearched.joined(separator: ", ")))"
                        : "loader tables list the address but premise (a) or (b) fails"),
                    toolchain: toolchain, missingEvidence: missingEvidence,
                    primitives: [NavigatorPrimitiveRef(
                        name: FunctionStartCallTargetDerivation.rule,
                        preconditions: ["a direct bl to \(address) from a function whose isFunctionStart is proven"])],
                    generation: generation, dependsOn: dependsOn)
                return Output(result: NavigatorPrimitiveResult(primitive: rule, primitiveVersion: ruleVersion,
                                                               subject: subject, budget: budget, frontier: [item]),
                              certificate: certificate)
            } catch {
                return Output(result: refusal(subject, budget, "malformedInput", describe(error), retryable: false),
                              certificate: certificate)
            }
        case .timeout:
            let limit = wallMillisLimit.map { String($0) } ?? "?"
            return Output(result: refusal(subject, budget, "budgetExceeded",
                                          "\(rule)@\(ruleVersion) exceeded wallMillis \(limit)", retryable: true),
                          certificate: certificate)
        case .cancelled:
            return Output(result: refusal(subject, budget, "cancelled", "\(rule)@\(ruleVersion) cancelled", retryable: true),
                          certificate: certificate)
        }
    }

    /// `cancelled` when `isCancelled` reports it, `timeout` when more than `limit` milliseconds have
    /// passed since `started`, else nil.
    static func interruption(started: Int64, limit: Int64?, clock: () -> Int64,
                             isCancelled: () -> Bool) -> NavigatorProofCertificate.Outcome? {
        if isCancelled() { return .cancelled }
        if let limit, clock() - started > limit { return .timeout }
        return nil
    }

    private static func refusal(_ subject: NavigatorSubject, _ budget: [String: Int64], _ code: String, _ detail: String,
                                retryable: Bool) -> NavigatorPrimitiveResult {
        NavigatorPrimitiveResult(primitive: rule, primitiveVersion: ruleVersion, subject: subject, budget: budget,
                                 refusal: NavigatorRefusal(code, detail, retryable: retryable))
    }

    static func describe(_ error: Error) -> String {
        if let contract = error as? NavigatorContractError { return contract.reasons.joined(separator: "; ") }
        return String(describing: error)
    }
}

/// `derive.function-start-call-target@1`: a `derived` (never `proven`) function start for an
/// address that no loader table lists but that is the target of a direct `bl` inside a function
/// whose `isFunctionStart` is proven. Premises: the proven fact ids (`derivedFrom`) and one
/// `decodedInstruction <bl address>` per call site. No certificate.
enum FunctionStartCallTargetDerivation {
    static let rule = "derive.function-start-call-target"
    static let ruleVersion = "1"
    /// Precedence tier of the derived fact (contract: 1–3 for derived facts).
    static let tier: Int64 = 2
    static let trustedBase = FunctionStartStructuralProof.trustedBase + ["ARM64Decoder"]
    static let missingEvidence = FunctionStartStructuralProof.tablesSearched + ["directCallFromProvenStart"]

    struct CallSite: Hashable, Sendable {
        let callerFactID: String
        let callerEntry: UInt64
        let address: UInt64
    }

    static var ruleProvenance: NavigatorProvenance {
        NavigatorProvenance(kind: "rule", ref: NavigatorProvenanceRef.rule(id: rule, version: ruleVersion).ref,
                            rule: rule, ruleVersion: ruleVersion)
    }

    /// The function entry of a proven, true `isFunctionStart` fact about a function of this image.
    static func provenEntry(_ fact: NavigatorFact, image: String?) -> UInt64? {
        guard fact.status == "proven", fact.predicate == FunctionStartStructuralProof.predicate,
              fact.value == .bool(true), fact.subject.kind == "function", fact.subject.image == image,
              fact.provenance.contains(where: {
                  $0.kind == "proofCertificate" && NavigatorContractValidator.isCertificateRef($0.ref)
              }),
              case .function(let entry)? = NavigatorSubjectRef.parse(fact.subject.ref, kind: "function") else {
            return nil
        }
        return entry
    }

    /// The callee of a direct `bl` word at `address`; nil for any other instruction.
    static func directCallTarget(word: UInt32, at address: UInt64) -> UInt64? {
        guard word & 0xfc00_0000 == 0x9400_0000 else { return nil }
        let displacement = Int64(Int32(bitPattern: (word & 0x03ff_ffff) << 6) >> 6) * 4
        return address &+ UInt64(bitPattern: displacement)
    }

    /// Decodes `function`'s bytes (clamped to its executable section) with `decoder`.
    static func decodeFunction(_ function: FunctionSummary, evidence: NavigatorImageEvidence,
                               decoder: any Disassembler) -> [DecodedInstruction] {
        guard function.endAddress > function.startAddress,
              let section = evidence.section(containing: function.startAddress),
              NavigatorImageEvidence.isExecutable(section) else { return [] }
        let sectionEnd = section.address + section.size
        let end = min(function.endAddress, sectionEnd)
        let length = Int(clamping: (end - function.startAddress) & ~UInt64(3))
        guard length > 0, let offset = evidence.fileOffset(of: function.startAddress, length: length, in: section) else {
            return []
        }
        let bytes = Data(evidence.slice[(evidence.slice.startIndex + offset) ..< (evidence.slice.startIndex + offset + length)])
        return decoder.decode(bytes, baseAddress: function.startAddress, maxInstructionCount: length / 4)
    }

    /// Direct `bl` call sites targeting `target` inside proven function starts. Each site's decoded
    /// bytes must equal the slice bytes at its address and re-encode to the same target.
    static func callSites(target: UInt64, evidence: NavigatorImageEvidence, provenFacts: [NavigatorFact],
                          functions: [FunctionSummary], decoder: any Disassembler) -> (sites: [CallSite], decoded: Int) {
        var sites: [CallSite] = []
        var decoded = 0
        for fact in provenFacts.sorted(by: { $0.id < $1.id }) {
            guard let entry = provenEntry(fact, image: evidence.image),
                  let function = functions.first(where: { $0.startAddress == entry }) else { continue }
            let instructions = decodeFunction(function, evidence: evidence, decoder: decoder)
            decoded += instructions.count
            for instruction in instructions where instruction.flow == .call && instruction.branchTarget == target {
                guard instruction.address >= function.startAddress, instruction.address < function.endAddress,
                      instruction.bytes.count == 4,
                      let section = evidence.section(containing: instruction.address),
                      let offset = evidence.fileOffset(of: instruction.address, length: 4, in: section) else { continue }
                let base = evidence.slice.startIndex + offset
                let raw = Array(evidence.slice[base ..< (base + 4)])
                guard raw == instruction.bytes else { continue }
                let word = UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
                guard directCallTarget(word: word, at: instruction.address) == target else { continue }
                let site = CallSite(callerFactID: fact.id, callerEntry: entry, address: instruction.address)
                if !sites.contains(site) { sites.append(site) }
            }
        }
        return (sites, decoded)
    }

    /// Runs the derivation for `target`. Refuses `preconditionFailed` when the target is not an
    /// aligned address in an executable section, or when a loader table lists it (the structural
    /// proof applies instead). Never emits `proven`. `generation` and `dependsOn` stamp the fact or
    /// frontier item.
    static func run(target: UInt64, evidence: NavigatorImageEvidence, provenFacts: [NavigatorFact],
                    functions: [FunctionSummary], toolchain: String,
                    generation: NavigatorGeneration? = nil, dependsOn: [String]? = nil,
                    decoder: any Disassembler = ARM64Decoder()) -> NavigatorPrimitiveResult {
        let subject = FunctionStartStructuralProof.subject(entry: target, evidence: evidence)
        let address = NavigatorSubjectRef.address(target)
        func refuse(_ code: String, _ detail: String, _ budget: [String: Int64]) -> NavigatorPrimitiveResult {
            NavigatorPrimitiveResult(primitive: rule, primitiveVersion: ruleVersion, subject: subject, budget: budget,
                                     refusal: NavigatorRefusal(code, detail))
        }

        guard target % 4 == 0, FunctionStartStructuralProof.sectionPremise(entry: target, evidence: evidence) != nil else {
            return refuse("preconditionFailed", "\(address) is not a 4-byte-aligned address in an executable section", [:])
        }
        guard FunctionStartStructuralProof.tableHits(entry: target, evidence: evidence).isEmpty else {
            return refuse("preconditionFailed",
                          "\(address) is listed by a loader table; \(FunctionStartStructuralProof.rule) applies", [:])
        }

        let (sites, decoded) = callSites(target: target, evidence: evidence, provenFacts: provenFacts,
                                         functions: functions, decoder: decoder)
        let budget: [String: Int64] = ["instructions": Int64(decoded), "bytes": Int64(decoded) * 4]

        guard !sites.isEmpty else {
            do {
                let item = try NavigatorFrontierItem.make(
                    subject: subject, gap: "boundaryUncertain",
                    detail: "\(address): no loader table lists the address and no direct bl from a proven function start targets it",
                    toolchain: toolchain, missingEvidence: missingEvidence, generation: generation, dependsOn: dependsOn)
                return NavigatorPrimitiveResult(primitive: rule, primitiveVersion: ruleVersion, subject: subject,
                                                budget: budget, frontier: [item])
            } catch {
                return refuse("malformedInput", FunctionStartStructuralProof.describe(error), budget)
            }
        }

        let callSiteAddresses = Array(Set(sites.map(\.address))).sorted()
        let callers = sites.map(\.callerFactID).uniqueSortedByScalars()
        let provenance = [ruleProvenance] + callSiteAddresses.map {
            NavigatorProvenanceRef.instruction(address: $0).provenance
        }
        do {
            let fact = try NavigatorFact.make(
                subject: subject, predicate: FunctionStartStructuralProof.predicate, value: .bool(true),
                status: "derived", provenance: provenance, toolchain: toolchain, tier: tier,
                derivedFrom: callers.map { [$0] }, generation: generation, dependsOn: dependsOn)
            return NavigatorPrimitiveResult(primitive: rule, primitiveVersion: ruleVersion, subject: subject,
                                            budget: budget, facts: [fact])
        } catch {
            return refuse("malformedInput", FunctionStartStructuralProof.describe(error), budget)
        }
    }
}
