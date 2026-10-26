import Foundation

/// WS-9: extracts candidate FUNCTION-START addresses from a binary's Swift metadata — the one
/// function-bearing metadata form the discovery pipeline does not yet mine. Swift methods, property
/// accessors, protocol witnesses, and metadata accessors are reached only through the runtime's
/// descriptor tables (no static `bl`, often prologue-less when optimized), so the linear sweep +
/// direct-call + prologue recovery miss them on binaries WITHOUT `LC_FUNCTION_STARTS` (stripped
/// executables, dyld-cache dylibs). The `__swift5_types` class descriptors (vtable method impls),
/// nominal descriptors (metadata accessors), and `__swift5_proto` conformances (witnesses) name them.
///
/// The returned addresses are CANDIDATES only — every one is re-validated by
/// `AnalysisEngine.validatedMetadataStarts` (in text, aligned to a decoded-instruction start, not
/// data-marked) before it can seed a function boundary, so a wrong candidate is dropped, never
/// allowed to corrupt the `[start, nextStart)` slicing.
///
/// Every metadata read is range-checked because relative pointers, counts, section spans, and slice
/// offsets are all attacker-controlled. Measured baseline (Phase A): a Swift fixture recovers 22/41
/// held-out starts (53.7%); this extractor targets the descriptor-backed portion of those misses.
enum SwiftMetadataFunctionExtractor {
    struct MethodLinks {
        var types: [UInt64: [SwiftMetadataMethod]] = [:]
        var conformances: [UInt64: [SwiftMetadataMethod]] = [:]
    }

    private struct Extraction {
        var candidates: Set<UInt64> = []
        var links = MethodLinks()
        var collectLinks: Bool
        private var remainingLinks: UInt64 = 200_000

        init(collectLinks: Bool) { self.collectLinks = collectLinks }

        mutating func reserveLinks(_ count: UInt64) -> Bool {
            guard collectLinks, count <= remainingLinks else { return false }
            remainingLinks -= count
            return true
        }
    }

    static func functionCandidates(in loaded: LoadedBinary) -> Set<UInt64> {
        let reader = Reader(loaded: loaded)
        let rebases = reader.section(named: "__swift5_proto") == nil ? [:] : chainedRebaseTargets(in: loaded)
        return extract(reader: reader, rebaseTargets: rebases, collectLinks: false).candidates
    }

    /// Parser bridge: reuse the selected slice and already-decoded fixups, never reopen/reparse it.
    static func methodLinks(data: Data, sections: [SwiftMetadataParser.Section],
                            rebaseTargets: [UInt64: UInt64], bindNames: [UInt64: String]) -> MethodLinks {
        extract(reader: Reader(data: data, sections: sections, boundSlots: Set(bindNames.keys)),
                rebaseTargets: rebaseTargets).links
    }

    private static func extract(reader: Reader, rebaseTargets: [UInt64: UInt64], collectLinks: Bool = true) -> Extraction {
        var result = Extraction(collectLinks: collectLinks)
        if let section = reader.section(named: "__swift5_types") {
            extractNominalCandidates(from: section, reader: reader, into: &result)
        }
        if let section = reader.section(named: "__swift5_proto") {
            extractWitnessCandidates(from: section, reader: reader, rebaseTargets: rebaseTargets, into: &result)
        }
        return result
    }

    private enum Limits {
        static let maxTopLevelRecords: UInt64 = 200_000
        static let maxMethodsOrRequirements: UInt64 = 65_536
        static let maxStringLength = 4_096
    }

    private enum ContextKind: UInt32 {
        case `protocol` = 3
        case `class` = 16
        case `struct` = 17
        case `enum` = 18

        init?(flags: UInt32) {
            self.init(rawValue: flags & 0x1f)
        }

        var isNominalType: Bool {
            self == .class || self == .struct || self == .enum
        }
    }

    private enum Offset {
        // Common TypeContextDescriptor prefix.
        static let name: UInt64 = 8
        static let accessFunction: UInt64 = 12

        // Fixed, non-generic class descriptor and its trailing records.
        static let classFixedSize: UInt64 = 44
        static let vtableHeaderSize: UInt64 = 8
        static let methodDescriptorSize: UInt64 = 8
        static let methodImplementation: UInt64 = 4
        static let overrideHeaderSize: UInt64 = 4
        static let overrideDescriptorSize: UInt64 = 12
        static let overrideBaseMethod: UInt64 = 4
        static let overrideImplementation: UInt64 = 8

        // Protocol/conformance descriptors and witness patterns.
        static let conformanceWitnessPattern: UInt64 = 8
        static let conformanceFlags: UInt64 = 12
        static let protocolNumRequirementsInSignature: UInt64 = 12
        static let protocolNumRequirements: UInt64 = 16
        static let protocolFixedSize: UInt64 = 24
        static let genericRequirementSize: UInt64 = 12
        static let protocolRequirementSize: UInt64 = 8
        static let witnessPointerSize: UInt64 = 8
        static let witnessFirstRequirementIndex: UInt64 = 1
    }

    private enum Flag {
        static let isGeneric: UInt32 = 0x80
        // TypeContextDescriptorFlags live in flags' high 16 bits. These whole-word masks correspond
        // to kind-specific class bits 13–15.
        static let classHasResilientSuperclass: UInt32 = 1 << 29
        static let classHasOverrideTable: UInt32 = 1 << 30
        static let classHasVTable: UInt32 = 1 << 31
    }

    // MARK: - Nominal type descriptors

    private static func extractNominalCandidates(
        from section: BinarySection,
        reader: Reader,
        into result: inout Extraction
    ) {
        let count = min(section.size / 4, Limits.maxTopLevelRecords)
        var visitedDescriptors: Set<UInt64> = []
        for index in 0..<count {
            guard let entryOffset = checkedMultiply(index, 4),
                  let entryVA = checkedAdd(section.address, entryOffset),
                  let descriptorVA = reader.resolveRelativeDirectPointer(at: entryVA),
                  visitedDescriptors.insert(descriptorVA).inserted,
                  let descriptor = nominalDescriptor(at: descriptorVA, reader: reader) else {
                continue
            }

            if let accessFieldVA = checkedAdd(descriptorVA, Offset.accessFunction),
               let accessFunctionVA = reader.resolveRelativeDirectPointer(at: accessFieldVA) {
                insertPlausible(accessFunctionVA, reader: reader, into: &result.candidates)
            }

            guard descriptor.kind == .class else { continue }
            extractClassTail(
                descriptorVA: descriptorVA,
                flags: descriptor.flags,
                reader: reader,
                into: &result
            )
        }
    }

    private static func nominalDescriptor(
        at descriptorVA: UInt64,
        reader: Reader
    ) -> (flags: UInt32, kind: ContextKind)? {
        guard let flags = reader.readU32(atVA: descriptorVA),
              let kind = ContextKind(flags: flags), kind.isNominalType,
              let nameFieldVA = checkedAdd(descriptorVA, Offset.name),
              let nameVA = reader.resolveRelativeDirectPointer(at: nameFieldVA),
              let name = reader.readCString(atVA: nameVA), !name.isEmpty else {
            return nil
        }
        return (flags, kind)
    }

    private static func extractClassTail(
        descriptorVA: UInt64,
        flags: UInt32,
        reader: Reader,
        into result: inout Extraction
    ) {
        // A generic class's vtable follows a variable generic-context record. Supporting only the
        // fixed accessor is safer than guessing a tail offset from hostile counts or future flags.
        guard flags & Flag.isGeneric == 0,
              var cursor = checkedAdd(descriptorVA, Offset.classFixedSize) else { return }

        if flags & Flag.classHasResilientSuperclass != 0 {
            guard let advanced = checkedAdd(cursor, 4) else { return }
            cursor = advanced
        }

        let metadataInitialization = (flags >> 16) & 0x3
        switch metadataInitialization {
        case 0:
            break
        case 1: // TargetSingletonMetadataInitialization: three relative 32-bit fields.
            guard let advanced = checkedAdd(cursor, 12) else { return }
            cursor = advanced
        case 2: // TargetForeignMetadataInitialization: one compact function pointer.
            guard let advanced = checkedAdd(cursor, 4) else { return }
            cursor = advanced
        default:
            return // Reserved ABI form: its trailing layout is not known.
        }

        var linkageAllowed = result.collectLinks
        if flags & Flag.classHasVTable != 0 {
            guard let countFieldVA = checkedAdd(cursor, 4),
                  let count = reader.readU32(atVA: countFieldVA).map(UInt64.init),
                  count <= Limits.maxMethodsOrRequirements,
                  let methodsVA = checkedAdd(cursor, Offset.vtableHeaderSize),
                  let tableSize = checkedMultiply(count, Offset.methodDescriptorSize),
                  reader.canRead(atVA: methodsVA, byteCount: tableSize) else {
                return
            }

            let canLink = result.reserveLinks(count)
            linkageAllowed = canLink
            if canLink { result.links.types[descriptorVA] = [] }
            for index in 0..<count {
                guard let recordOffset = checkedMultiply(index, Offset.methodDescriptorSize),
                      let methodVA = checkedAdd(methodsVA, recordOffset),
                      let methodFlags = reader.readU32(atVA: methodVA) else {
                    continue
                }
                let target = checkedAdd(methodVA, Offset.methodImplementation)
                    .flatMap { reader.resolveRelativeDirectPointer(at: $0) }
                let knownKind = validMethodDescriptor(at: methodVA, reader: reader)
                // Async/callee-allocated coroutine entries name data records, not code pointers.
                let implementation = knownKind && methodFlags & 0x40 == 0
                    ? target.flatMap { reader.isPlausibleCodeAddress($0) ? $0 : nil } : nil
                if canLink {
                    result.links.types[descriptorVA, default: []].append(SwiftMetadataMethod(
                        source: .vtable, index: index, descriptorAddress: methodVA,
                        implementation: implementation, flags: methodFlags
                    ))
                }
                if knownKind, let target { insertPlausible(target, reader: reader, into: &result.candidates) }
            }
            guard let advanced = checkedAdd(methodsVA, tableSize) else { return }
            cursor = advanced
        }

        guard flags & Flag.classHasOverrideTable != 0 else { return }
        guard let count = reader.readU32(atVA: cursor).map(UInt64.init),
              count <= Limits.maxMethodsOrRequirements,
              let recordsVA = checkedAdd(cursor, Offset.overrideHeaderSize),
              let tableSize = checkedMultiply(count, Offset.overrideDescriptorSize),
              reader.canRead(atVA: recordsVA, byteCount: tableSize) else {
            return
        }

        let canLink = linkageAllowed && result.reserveLinks(count)
        if !canLink { result.links.types[descriptorVA] = nil }
        for index in 0..<count {
            guard let recordOffset = checkedMultiply(index, Offset.overrideDescriptorSize),
                  let recordVA = checkedAdd(recordsVA, recordOffset) else { continue }
            let linkIndex = result.links.types[descriptorVA]?.count ?? 0
            if canLink {
                result.links.types[descriptorVA, default: []].append(SwiftMetadataMethod(
                    source: .override, index: index, descriptorAddress: recordVA, implementation: nil, flags: nil
                ))
            }
            guard
                  let classVA = reader.resolveRelativeIndirectableDirectPointer(at: recordVA),
                  nominalDescriptor(at: classVA, reader: reader)?.kind == .class,
                  let methodFieldVA = checkedAdd(recordVA, Offset.overrideBaseMethod),
                  let baseMethodVA = reader.resolveRelativeIndirectableDirectPointer(at: methodFieldVA),
                  validMethodDescriptor(at: baseMethodVA, reader: reader),
                  let implementationFieldVA = checkedAdd(recordVA, Offset.overrideImplementation),
                  let implementationVA = reader.resolveRelativeDirectPointer(at: implementationFieldVA) else {
                continue
            }
            insertPlausible(implementationVA, reader: reader, into: &result.candidates)
            let methodFlags = reader.readU32(atVA: baseMethodVA)
            if canLink {
                result.links.types[descriptorVA]?[linkIndex].flags = methodFlags
                if let methodFlags, methodFlags & 0x40 == 0, reader.isPlausibleCodeAddress(implementationVA) {
                    result.links.types[descriptorVA]?[linkIndex].implementation = implementationVA
                }
            }
        }
    }

    private static func validMethodDescriptor(at methodVA: UInt64, reader: Reader) -> Bool {
        guard let flags = reader.readU32(atVA: methodVA) else { return false }
        // Current MethodDescriptorFlags.Kind: method, init, getter, setter, modify, read.
        return flags & 0x0f <= 5
    }

    // MARK: - Protocol conformances and witness tables

    private static func extractWitnessCandidates(
        from section: BinarySection,
        reader: Reader,
        rebaseTargets: [UInt64: UInt64],
        into result: inout Extraction
    ) {
        let count = min(section.size / 4, Limits.maxTopLevelRecords)
        var visitedDescriptors: Set<UInt64> = []
        for index in 0..<count {
            guard let entryOffset = checkedMultiply(index, 4),
                  let entryVA = checkedAdd(section.address, entryOffset),
                  let descriptorVA = reader.resolveRelativeDirectPointer(at: entryVA),
                  visitedDescriptors.insert(descriptorVA).inserted else {
                continue
            }
            extractWitnesses(
                fromConformanceAt: descriptorVA,
                reader: reader,
                rebaseTargets: rebaseTargets,
                into: &result
            )
        }
    }

    private static func extractWitnesses(
        fromConformanceAt descriptorVA: UInt64,
        reader: Reader,
        rebaseTargets: [UInt64: UInt64],
        into result: inout Extraction
    ) {
        guard reader.canRead(atVA: descriptorVA, byteCount: 16),
              let conformanceFlagsVA = checkedAdd(descriptorVA, Offset.conformanceFlags),
              let conformanceFlags = reader.readU32(atVA: conformanceFlagsVA),
              ((conformanceFlags >> 3) & 0x7) <= 3,
              let protocolVA = reader.resolveRelativeIndirectableDirectPointer(at: descriptorVA),
              let protocolFlags = reader.readU32(atVA: protocolVA),
              ContextKind(flags: protocolFlags) == .protocol,
              let protocolNameFieldVA = checkedAdd(protocolVA, Offset.name),
              let protocolNameVA = reader.resolveRelativeDirectPointer(at: protocolNameFieldVA),
              let protocolName = reader.readCString(atVA: protocolNameVA), !protocolName.isEmpty,
              let signatureCountVA = checkedAdd(protocolVA, Offset.protocolNumRequirementsInSignature),
              let signatureCount = reader.readU32(atVA: signatureCountVA).map(UInt64.init),
              signatureCount <= Limits.maxMethodsOrRequirements,
              let requirementCountVA = checkedAdd(protocolVA, Offset.protocolNumRequirements),
              let requirementCount = reader.readU32(atVA: requirementCountVA).map(UInt64.init),
              requirementCount > 0, requirementCount <= Limits.maxMethodsOrRequirements,
              let signatureBytes = checkedMultiply(signatureCount, Offset.genericRequirementSize),
              let requirementsBase = checkedAdd(protocolVA, Offset.protocolFixedSize),
              let requirementsVA = checkedAdd(requirementsBase, signatureBytes),
              let requirementsSize = checkedMultiply(requirementCount, Offset.protocolRequirementSize),
              reader.canRead(atVA: requirementsVA, byteCount: requirementsSize),
              let patternFieldVA = checkedAdd(descriptorVA, Offset.conformanceWitnessPattern),
              let patternVA = reader.resolveRelativeDirectPointer(at: patternFieldVA),
              let slotCount = checkedAdd(requirementCount, Offset.witnessFirstRequirementIndex),
              let patternSize = checkedMultiply(slotCount, Offset.witnessPointerSize),
              reader.canRead(atVA: patternVA, byteCount: patternSize) else {
            return
        }

        // Only a complete, absolute witness pattern with its own conformance header establishes
        // a method association. Relative patterns and resilient/generic instantiation stay unknown.
        let patternOwner = reader.isBound(at: patternVA) ? nil : rebaseTargets[patternVA] ?? reader.readU64(atVA: patternVA)
        let canLink = patternOwner == descriptorVA && conformanceFlags & ((1 << 16) | (1 << 17)) == 0
            && result.reserveLinks(requirementCount)
        if canLink { result.links.conformances[descriptorVA] = [] }
        for index in 0..<requirementCount {
            guard let requirementOffset = checkedMultiply(index, Offset.protocolRequirementSize),
                  let requirementVA = checkedAdd(requirementsVA, requirementOffset),
                  let requirementFlags = reader.readU32(atVA: requirementVA) else {
                continue
            }
            let kind = requirementFlags & 0x0f
            // Base-protocol entries point to another witness table. Kinds 1...8 are callable
            // method/init/property/accessor witnesses under the current Swift ABI.
            guard (1...8).contains(kind),
                  let slotIndex = checkedAdd(index, Offset.witnessFirstRequirementIndex),
                  let slotOffset = checkedMultiply(slotIndex, Offset.witnessPointerSize),
                  let slotVA = checkedAdd(patternVA, slotOffset) else {
                continue
            }

            let target = reader.isBound(at: slotVA) ? nil : rebaseTargets[slotVA] ?? reader.readU64(atVA: slotVA)
            if canLink {
                // Associated-type/conformance access entries are not source member methods.
                // Retain their requirement records, but do not claim a callable implementation.
                let implementation = kind <= 6 && requirementFlags & 0x20 == 0
                    ? target.flatMap { reader.isPlausibleCodeAddress($0) ? $0 : nil } : nil
                result.links.conformances[descriptorVA, default: []].append(SwiftMetadataMethod(
                    source: .witness, index: index, descriptorAddress: requirementVA,
                    implementation: implementation, flags: requirementFlags
                ))
            }
            if let targetVA = rebaseTargets[slotVA] {
                insertPlausible(targetVA, reader: reader, into: &result.candidates)
            } else if let rawTargetVA = reader.readU64(atVA: slotVA) {
                // Covers already-rebased/prelinked images and hermetic fixtures. Encoded chained
                // pointers never look like a valid in-image text VA and are therefore rejected.
                insertPlausible(rawTargetVA, reader: reader, into: &result.candidates)
            }
        }
    }

    private static func chainedRebaseTargets(in loaded: LoadedBinary) -> [UInt64: UInt64] {
        guard let slice = selectedSliceData(from: loaded) else { return [:] }
        let options = MachOParseOptions(
            recoverStringLiterals: false,
            recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: false,
            parseCodeSignature: false
        )
        guard let machO = try? MachOParser().parse(slice, options: options),
              machO.header.cpuType == loaded.cpuType else {
            return [:]
        }

        var result: [UInt64: UInt64] = [:]
        for fixup in machO.dyldChainedFixups?.fixups ?? [] {
            guard let targetVA = fixup.rebaseTargetAddress else { continue }
            // Assignment is deterministic and cannot trap if hostile input repeats a source slot.
            result[fixup.address] = targetVA
        }
        return result
    }

    private static func selectedSliceData(from loaded: LoadedBinary) -> Data? {
        guard loaded.sliceOffset <= UInt64(Int.max) else { return nil }
        let start = Int(loaded.sliceOffset)
        guard start >= 0, start <= loaded.bytes.count else { return nil }
        let available = loaded.bytes.count - start

        let count: Int
        if let declaredSize = loaded.sliceSize {
            guard declaredSize <= UInt64(available), declaredSize <= UInt64(Int.max) else { return nil }
            count = Int(declaredSize)
        } else {
            count = available
        }

        guard count > 0 else { return nil }
        if start == 0, count == loaded.bytes.count { return loaded.bytes }
        return loaded.bytes.subdata(in: start..<(start + count))
    }

    private static func insertPlausible(
        _ address: UInt64,
        reader: Reader,
        into candidates: inout Set<UInt64>
    ) {
        guard reader.isPlausibleCodeAddress(address) else { return }
        candidates.insert(address)
    }

    // MARK: - Checked arithmetic

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private static func checkedMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : value
    }

    // MARK: - Bounds-checked LoadedBinary reader

    private struct Reader {
        private let bytes: [UInt8]
        private let sections: [BinarySection]
        private let sliceOffset: UInt64
        private let sliceSize: UInt64?
        private let codeSections: [BinarySection]
        private let boundSlots: Set<UInt64>

        init(loaded: LoadedBinary) {
            bytes = [UInt8](loaded.bytes)
            sections = loaded.sections
            sliceOffset = loaded.sliceOffset
            sliceSize = loaded.sliceSize
            boundSlots = []
            if let primaryText = loaded.executableTextSection {
                codeSections = [primaryText]
            } else {
                codeSections = loaded.sections.filter(\.isExecutable)
            }
        }

        init(data: Data, sections: [SwiftMetadataParser.Section], boundSlots: Set<UInt64>) {
            bytes = [UInt8](data)
            self.sections = sections.map {
                BinarySection(name: $0.name, address: $0.address, size: $0.size,
                              fileOffset: $0.fileOffset, isExecutable: $0.isExecutable, isZeroFill: $0.isZeroFill)
            }
            sliceOffset = 0
            sliceSize = UInt64(data.count)
            codeSections = self.sections.filter(\.isExecutable)
            self.boundSlots = boundSlots
        }

        func isBound(at address: UInt64) -> Bool { boundSlots.contains(address) }

        func section(named leafName: String) -> BinarySection? {
            sections.first { section in
                section.name == leafName || section.name.split(separator: ",").last == Substring(leafName)
            }
        }

        func resolveRelativeDirectPointer(at fieldVA: UInt64) -> UInt64? {
            guard let raw = readI32(atVA: fieldVA), raw != 0 else { return nil }
            return UInt64(bitPattern: Int64(bitPattern: fieldVA) &+ Int64(raw))
        }

        /// Resolves the direct form of RelativeIndirectablePointer. Indirect forms need a source-slot
        /// fixup map that LoadedBinary does not retain, so they are rejected rather than guessed.
        func resolveRelativeIndirectableDirectPointer(at fieldVA: UInt64) -> UInt64? {
            guard let raw = readI32(atVA: fieldVA), raw != 0, raw & 1 == 0 else { return nil }
            return UInt64(bitPattern: Int64(bitPattern: fieldVA) &+ Int64(raw))
        }

        func readU64(atVA va: UInt64) -> UInt64? {
            guard let offset = fileOffset(forVA: va, byteCount: 8) else { return nil }
            var result: UInt64 = 0
            for byte in 0..<8 {
                result |= UInt64(bytes[offset + byte]) << UInt64(byte * 8)
            }
            return result
        }

        func readU32(atVA va: UInt64) -> UInt32? {
            guard let offset = fileOffset(forVA: va, byteCount: 4) else { return nil }
            return UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }

        func readI32(atVA va: UInt64) -> Int32? {
            readU32(atVA: va).map(Int32.init(bitPattern:))
        }

        func readCString(atVA va: UInt64) -> String? {
            guard let start = fileOffset(forVA: va, byteCount: 1) else { return nil }
            let available = bytes.count - start
            let scanLength = min(available, Limits.maxStringLength)
            let limit = start + scanLength
            var end = start
            while end < limit, bytes[end] != 0 { end += 1 }
            guard end < limit else { return nil }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        func canRead(atVA va: UInt64, byteCount: UInt64) -> Bool {
            guard byteCount <= UInt64(Int.max) else { return false }
            return fileOffset(forVA: va, byteCount: Int(byteCount)) != nil
        }

        func isPlausibleCodeAddress(_ address: UInt64) -> Bool {
            // This WS-9 implementation targets Swift 6 Mach-O on Apple Silicon. Requiring ARM64
            // instruction alignment here matters because the downstream gate accepts aligned text
            // addresses without requiring prior linear-sweep decoding.
            guard address & 0x3 == 0 else { return false }
            return codeSections.contains { section in
                guard section.isExecutable, !section.isZeroFill, address >= section.address else {
                    return false
                }
                let delta = address - section.address
                guard delta < section.size else { return false }
                return fileOffset(forVA: address, byteCount: 4) != nil
            }
        }

        private func fileOffset(forVA va: UInt64, byteCount: Int) -> Int? {
            guard byteCount >= 0 else { return nil }
            let width = UInt64(byteCount)

            for section in sections where !section.isZeroFill && section.size > 0 && va >= section.address {
                let delta = va - section.address
                guard delta < section.size else { continue }
                let backedSize = min(section.size, section.fileSize ?? section.size)
                guard delta <= backedSize, width <= backedSize - delta else { continue }

                let (relativeOffset, relativeOverflow) = section.fileOffset.addingReportingOverflow(delta)
                guard !relativeOverflow else { continue }
                let (absoluteOffset, absoluteOverflow) = sliceOffset.addingReportingOverflow(relativeOffset)
                guard !absoluteOverflow else { continue }

                if let sliceSize {
                    guard absoluteOffset >= sliceOffset else { continue }
                    let withinSlice = absoluteOffset - sliceOffset
                    guard withinSlice <= sliceSize, width <= sliceSize - withinSlice else { continue }
                }

                guard absoluteOffset <= UInt64(Int.max) else { continue }
                let offset = Int(absoluteOffset)
                guard offset >= 0, offset <= bytes.count, byteCount <= bytes.count - offset else { continue }
                return offset
            }
            return nil
        }
    }
}
