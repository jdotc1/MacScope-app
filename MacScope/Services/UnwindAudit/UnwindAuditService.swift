import Foundation

/// Static, bounded recovery comparison. LoadedBinary remains the byte and image
/// authority; this service never opens a path, rehashes provenance or executes code.
enum UnwindAuditService {
    static func audit(binary: LoadedBinary, limits: UnwindAuditLimits = .init(),
                      model: UnwindAuditModel = .boundedLoops) throws -> UnwindAuditReport {
        guard binary.artifactIntegrityState == .verified, let identity = binary.artifactIdentity,
              identity.rawCPUType == binary.cpuType, identity.rawCPUSubtype == binary.cpuSubtype,
              let layout = binary.preferredSegmentLayout,
              let base = layout.records.first(where: { $0.name == "__TEXT" })?.preferredVMStart,
              binary.sliceOffset <= UInt64(binary.bytes.count),
              identity.selectedSliceByteCount == (binary.sliceSize ?? (UInt64(binary.bytes.count) - binary.sliceOffset)),
              identity.selectedSliceByteCount <= UInt64(binary.bytes.count) - binary.sliceOffset else {
            throw UnwindAuditModelError(code: "unverified_slice", message: "Exact verified selected-slice identity and mappings are required", address: nil)
        }
        guard limits.maxInstructions > 0, limits.maxInstructions <= 1_000_000,
              limits.maxObservations > 0, limits.maxObservations <= 100_000,
              limits.maxEvidence > 0, limits.maxEvidence <= 4096,
              limits.maxSteps > 0, limits.maxSteps <= 1_000_000,
              limits.maxPaths > 0, limits.maxPaths <= 4096,
              binary.functionStarts.count <= 50_000 else { throw UnwindAuditReportError.invalidConfiguration }
        let slice = binary.bytes.subdata(in: Int(binary.sliceOffset)..<Int(binary.sliceOffset + identity.selectedSliceByteCount))
        let unwindSections = binary.sections.filter { $0.name == "__TEXT,__unwind_info" }
        var compact: [MachOUnwindFunctionStarts.ResolvedRow]?
        if unwindSections.count == 1, let section = unwindSections.first, !section.isZeroFill,
           section.fileSize.map({ $0 >= section.size }) ?? true,
           let fileOffset = UInt32(exactly: section.fileOffset) {
            let descriptor = MachOSection(sectionName: "__unwind_info", segmentName: "__TEXT",
                                          address: section.address, size: section.size, fileOffset: fileOffset,
                                          alignment: 2, relocationOffset: 0, relocationCount: 0,
                                          flags: 0, reserved1: 0, reserved2: 0, reserved3: 0)
            compact = MachOUnwindFunctionStarts.resolvedRows(in: slice, section: descriptor)
        }
        var cfi: UnwindAuditCFI?
        var cfiError = "No complete supported CFI table is available"
        if compact?.contains(where: { $0.dwarfFDESectionOffset != nil }) == true {
            do {
                let sections = binary.sections.filter { $0.name == "__TEXT,__eh_frame" }
                guard sections.count == 1, let section = sections.first, section.size <= 8 * 1024 * 1024 else {
                    throw modelError("dwarf_cfi_unsupported", "A unique bounded CFI section is required")
                }
                let bytes = try sectionData(section, slice: slice)
                let reader = DWARFReader(sections: .init(ehFrame: bytes))
                cfi = try UnwindAuditCFI(table: reader.recoverStructuredCallFrameInfo(sectionAddress: section.address))
            } catch { cfiError = String(describing: error) }
        }
        let starts = Array(Set(binary.functionStarts)).sorted()
        let calleeEntries = Set(starts)
        var findings: [UnwindAuditFinding] = []
        var remainingInstructions = 1_000_000
        var remainingSteps = 1_000_000
        for (index, start) in starts.enumerated() {
            let executable = binary.sections.filter { section in
                !section.isZeroFill && section.isExecutable && section.address <= start
                    && start - section.address < section.size
            }
            guard executable.count == 1, let section = executable.first,
                  section.size <= UInt64.max - section.address else {
                throw modelError("untrusted_function_boundary", "Function start has no unique executable section", start)
            }
            let sectionEnd = section.address + section.size
            let end = index + 1 < starts.count ? min(starts[index + 1], sectionEnd) : sectionEnd
            guard start < end else { throw modelError("untrusted_function_boundary", "Function extent is empty", start) }
            let names = binary.symbols.filter { $0.address == start }.map { $0.rawLinkageName ?? $0.name }
                .filter { !FunctionVersionFingerprinting.isGeneratedName($0) }.sorted()
            let fingerprint = FunctionVersionFingerprint(id: String(start, radix: 16), address: start,
                                                         symbolName: names.first, size: end - start)
            let entry = start >= base ? compact?.last(where: { UInt64($0.range.lowerBound) <= start - base
                && start - base < UInt64($0.range.upperBound) }) : nil
            let encoding = entry?.encoding
            let mode = encoding.map(encodingMode) ?? "none"
            var result = UnwindAuditFinding(identity: identity, function: fingerprint, endAddress: end,
                                            verdict: "unresolved", coverage: mode == "dwarf" ? "dwarf_reference" : (entry == nil ? "none" : "compact"),
                                            mode: mode, scope: "metadata_only", encoding: encoding,
                                            limitations: limitations)
            if model == .boundedLoopCalls {
                result.limitations.append("Loop calls use a same-image entry ABI summary, with no callee traversal: x0–x18, x30 and NZCV are clobbered after return; SP and x19–x29 are preserved. SIMD effects remain outside the evaluator; ABI preservation of v8–v15 low halves is an assumption, not evaluated recovery.")
            }
            func unresolved(_ code: String, _ message: String, address: UInt64? = nil) -> UnwindAuditFinding {
                var value = result
                value.verdict = "unresolved"
                value.checkedPCs = []
                value.reasonCodes = [code]
                value.evidence = [.init(code: code, message: message, address: address)]
                return value
            }
            guard let entry, let encoding else {
                findings.append(unresolved(compact == nil && !unwindSections.isEmpty ? "malformed_unwind_metadata" : "missing_unwind_metadata",
                                           "No complete resolved compact rule covers this function")); continue
            }
            guard end >= base, end - base <= UInt64(entry.range.upperBound) else {
                findings.append(unresolved("metadata_range_incomplete", "One metadata range must cover the complete independent function")); continue
            }
            guard encoding != 0 else {
                result.coverage = "none"
                findings.append(unresolved("empty_unwind_rule", "The metadata explicitly contains no compact rule")); continue
            }
            guard identity.architectureVariant == .arm64,
                  [0, 1].contains(identity.rawCPUSubtype) else {
                findings.append(unresolved("unsupported_current_cpu_subtype", "Only exact ordinary ARM64 subtype 0 or 1 is modeled")); continue
            }
            guard ["frame", "frameless", "dwarf"].contains(mode) else {
                findings.append(unresolved("unsupported_unwind_mode", "The encoding has no modeled recovery mode")); continue
            }
            if mode != "dwarf" {
                let allowed: UInt32 = mode == "frame" ? 0xff00_001f : 0xffff_f000
                guard encoding & ~allowed == 0 else {
                    findings.append(unresolved("unsupported_encoding_bits", "Encoding requests unmodeled integer/SIMD recovery")); continue
                }
            }
            var fde: UnwindAuditCFI.FDE?
            if mode == "dwarf" {
                do {
                    guard let cfi else { throw modelError("dwarf_cfi_unsupported", cfiError) }
                    fde = try cfi.select(offset: encoding & 0x00ff_ffff, start: start, end: end)
                    result.coverage = "dwarf_evaluated"
                } catch {
                    findings.append(unresolved("dwarf_cfi_unsupported", String(describing: error))); continue
                }
            }
            do {
                let size = end - start
                guard size % 4 == 0, start % 4 == 0 else {
                    throw modelError("unaligned_function_range", "Function bytes must be aligned", start)
                }
                guard size / 4 <= UInt64(limits.maxInstructions), size / 4 <= UInt64(remainingInstructions) else {
                    throw modelError("function_instruction_limit", "Function or report instruction budget exhausted", start)
                }
                guard !binary.codeDataRanges.contains(where: { range in
                    range.address < end && (range.size > UInt64.max - range.address || start < range.address + range.size)
                }) else { throw modelError("untrusted_function_boundary", "Function range contains declared data", start) }
                remainingInstructions -= Int(size / 4)
                let bytes = try functionData(section, start: start, end: end, slice: slice)
                let instructions = try UnwindAuditInstruction.decode(data: bytes, start: start, maximum: limits.maxInstructions)
                result.instructionCount = instructions.count
                var effective = limits
                effective.maxSteps = min(limits.maxSteps, remainingSteps)
                let selectedFDE = fde
                let reservedSteps = effective.maxSteps
                remainingSteps -= reservedSteps
                let execution = try UnwindAuditExecution.run(instructions: instructions, mode: mode,
                                                              calleeEntries: calleeEntries, limits: effective, model: model) { state, pc in
                    if let selectedFDE { return try selectedFDE.row(at: pc).recover(state) }
                    return try recoverCompact(state, encoding: encoding, mode: mode)
                }
                remainingSteps += reservedSteps - execution.steps
                result.scope = execution.scope
                var unknowns = 0
                var mismatches: [UnwindAuditEvidence] = []
                var possibleMismatch = false
                let expected = expectedCaller()
                for observation in execution.observations {
                    for register in ["SP"] + (19...30).map({ "x\($0)" }) {
                        guard let want = expected[register] else { continue }
                        let got = observation.recovered[register] ?? .unknown("Recovery rule omitted required register")
                        if !got.known { unknowns += 1 }
                        else if got != want {
                            possibleMismatch = true
                            if observation.certain && mismatches.count < limits.maxEvidence {
                                mismatches.append(.init(code: "caller_state_mismatch",
                                                        message: "Modeled recovery differs for \(register) on a known-reachable path",
                                                        address: observation.pc, expected: want.describe(), observed: got.describe()))
                            }
                        }
                    }
                }
                if unknowns > 0 {
                    findings.append(unresolved("unknown_recovery_value", "\(unknowns) required recovery values are unknown")); continue
                }
                if possibleMismatch && mismatches.isEmpty {
                    findings.append(unresolved("cfg_path_feasibility_unknown", "Discrepancy occurs only on paths with uncertain reachability")); continue
                }
                result.verdict = mismatches.isEmpty ? "agreement" : "inconsistency"
                result.reasonCodes = [mismatches.isEmpty ? "supported_model_agreement" : "caller_state_mismatch"]
                result.checkedPCs = Array(Set(execution.observations.map(\.pc))).sorted()
                result.evidence = mismatches.isEmpty ? [.init(code: "caller_state_recovered", message: "Entry SP and original x19–x30 recovered at every listed modeled observation")] : mismatches
                if let header = execution.loopHeader, result.evidence.count < limits.maxEvidence {
                    result.evidence.append(.init(code: "cfg_loop_checked",
                                                message: "One natural loop; \(execution.loopVisits) full path-header states, \(execution.loopClosures) exact recurrence closures; no termination claim",
                                                address: header))
                }
                if let fde {
                    result.limitations.append("CFI uses the Apple unchanged-register default and exact CIE/FDE identity at original PCs.")
                    for pc in result.checkedPCs where result.evidence.count < limits.maxEvidence {
                        let row = try fde.row(at: pc)
                        result.evidence.append(.init(code: "dwarf_cfi_row", message: "FDE +\(fde.offset), CIE +\(fde.cieOffset), row 0x\(String(row.pc, radix: 16)); CFA register \(row.register)+\(row.offset)", address: pc))
                    }
                }
                findings.append(result)
            } catch let error as UnwindAuditModelError {
                findings.append(unresolved(error.code, error.message, address: error.address))
            } catch {
                findings.append(unresolved("unsupported_recovery", String(describing: error)))
            }
        }
        let report = UnwindAuditReport(identity: identity, analysisModelVersion: model.rawValue,
                                       configuration: limits, findings: findings)
        try report.validate()
        return report
    }

    private static func functionData(_ section: BinarySection, start: UInt64, end: UInt64,
                                     slice: Data) throws -> Data {
        guard !section.isZeroFill, section.fileSize.map({ $0 >= section.size }) ?? true,
              section.fileOffset <= UInt64(slice.count), section.size <= UInt64(slice.count) - section.fileOffset,
              start >= section.address, end >= start, end - section.address <= section.size else {
            throw modelError("section_not_file_backed", "Function bytes exceed the exact section or slice")
        }
        let low = Int(section.fileOffset + (start - section.address))
        let high = Int(section.fileOffset + (end - section.address))
        return slice.subdata(in: low..<high)
    }

    private static func sectionData(_ section: BinarySection, slice: Data) throws -> Data {
        guard !section.isZeroFill, section.fileSize.map({ $0 >= section.size }) ?? true,
              section.fileOffset <= UInt64(slice.count), section.size <= UInt64(slice.count) - section.fileOffset else {
            throw modelError("section_not_file_backed", "Section bytes exceed the exact selected slice")
        }
        return slice.subdata(in: Int(section.fileOffset)..<Int(section.fileOffset + section.size))
    }

    private static func encodingMode(_ encoding: UInt32) -> String {
        guard encoding != 0 else { return "none" }
        switch encoding & 0x0f00_0000 {
        case 0x0200_0000: return "frameless"
        case 0x0300_0000: return "dwarf"
        case 0x0400_0000: return "frame"
        case 0x0500_0000: return "pauth_frame"
        default: return "unknown"
        }
    }

    private static func expectedCaller() -> [String: UnwindAuditValue] {
        var values: [String: UnwindAuditValue] = ["SP": .stack(displacement: 0)]
        for number in 19...30 { values["x\(number)"] = .original(register: number, displacement: 0) }
        return values
    }

    private static func recoverCompact(_ state: UnwindAuditMachine, encoding: UInt32,
                                       mode: String) throws -> [String: UnwindAuditValue] {
        var result = Dictionary(uniqueKeysWithValues: (19...30).map { ("x\($0)", state.registers[$0]) })
        if mode == "frameless" {
            result["SP"] = try state.sp.add(Int64((encoding & 0x00ff_f000) >> 12) * 16)
            return result
        }
        let fp = state.registers[29]
        result["SP"] = try fp.add(16)
        guard case .stack(let slot) = fp, case .stack(let stack) = state.sp else {
            result["x29"] = .unknown("FP does not identify a modeled frame record")
            result["x30"] = .unknown("FP does not identify a modeled frame record")
            return result
        }
        func saved(_ offset: Int64) -> UnwindAuditValue {
            guard offset % 8 == 0, offset >= stack, offset <= -8 else { return .unknown("Unwind read is outside the allocated frame") }
            return state.memory[offset] ?? .unknown("No modeled store at entry SP\(offset)")
        }
        result["x29"] = saved(slot)
        let (lrSlot, overflow) = slot.addingReportingOverflow(8)
        result["x30"] = overflow ? .unknown("Frame offset overflow") : saved(lrSlot)
        var pairSlot = slot
        for pair in 0..<5 where encoding & (1 << UInt32(pair)) != 0 {
            let (next, overflow) = pairSlot.subtractingReportingOverflow(16)
            guard !overflow else { throw modelError("frame_offset_overflow", "Saved pair offset overflows") }
            pairSlot = next
            result["x\(19 + pair * 2)"] = saved(pairSlot + 8)
            result["x\(20 + pair * 2)"] = saved(pairSlot)
        }
        return result
    }

    private static let limitations = [
        "Bounded static caller recovery; no arbitrary-PC, asynchronous or runtime correctness claim.",
        "One natural loop closes only on exact complete-state recurrence; no termination guarantee.",
        "Unsupported effects, SIMD, pointer authentication and unmodeled CFI remain unresolved.",
        "Direct callees are summarized as ABI-conforming returns; their implementations are not analyzed."
    ]

    private static func modelError(_ code: String, _ message: String, _ address: UInt64? = nil) -> UnwindAuditModelError {
        UnwindAuditModelError(code: code, message: message, address: address)
    }
}
