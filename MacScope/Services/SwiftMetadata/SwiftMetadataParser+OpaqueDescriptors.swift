import Foundation

extension SwiftMetadataParser {
    func parseOpaqueTypeDescriptors() -> [SwiftOpaqueTypeDescriptor] {
        parseOpaqueTypeDescriptorsReport().records
    }

    func parseOpaqueTypeDescriptorsReport() -> (records: [SwiftOpaqueTypeDescriptor], diagnostics: [MetadataParseDiagnostic], symbolicReferenceKinds: [UInt32], descriptorAddresses: [UInt64], accessorReferenceAddresses: [UInt64], callSiteDescriptorAddresses: [UInt64], structuralDescriptorAddresses: [UInt64]) {
        var diagnostics: [MetadataParseDiagnostic] = []
        var roots = opaqueMangledRoots(diagnostics: &diagnostics)
        var visitedNames: Set<UInt64> = []
        var visitedDescriptors: Set<UInt64> = []
        var recordedDescriptors: Set<UInt64> = []
        var records: [SwiftOpaqueTypeDescriptor] = []
        var rootEnqueueCapped = false
        var cursor = 0
        var symbolicReferenceKinds: Set<UInt32> = []
        var accessorReferences: Set<UInt64> = []
        func drainRoots() {
            while cursor < roots.count, visitedNames.count < Limits.maxTypes {
                let address = roots[cursor]
                cursor += 1
                guard visitedNames.insert(address).inserted else { continue }
                guard let raw = opaqueMangledBytes(at: address) else {
                    diagnostics.append(opaqueDiagnostic(address, "Unreadable or unterminated mangled name during opaque discovery"))
                    continue
                }
                var index = 0
                while index < raw.count {
                    let control = raw[index]
                    guard let width = Self.symbolicReferencePayloadWidth(control) else { index += 1; continue }
                    guard index + width < raw.count else {
                        diagnostics.append(opaqueDiagnostic(address, "Truncated symbolic reference during opaque discovery"))
                        break
                    }
                    if control == 1 || control == 2 {
                        let field = address + UInt64(index + 1)
                        if let target = resolveRelativePointer(at: field) {
                            let descriptor = control == 1 ? target : rebaseTargets[target]
                            // Kind reporting intentionally retains the original file-bounded read,
                            // including malformed non-opaque targets. Only opaque acceptance is section-bounded.
                            if let descriptor, let flags = readU32(atVA: descriptor) {
                                symbolicReferenceKinds.insert(flags & 0x1f)
                                if ContextKind(flags: flags) == .opaque, visitedDescriptors.insert(descriptor).inserted {
                                    if let record = opaqueDescriptor(at: descriptor, flags: flags, roots: &roots, diagnostics: &diagnostics, rootEnqueueCapped: &rootEnqueueCapped) {
                                        if recordedDescriptors.insert(descriptor).inserted { records.append(record) }
                                    }
                                }
                            }
                        }
                    } else if control == 0x09 {
                        let field = address + UInt64(index + 1)
                        if accessorReferences.insert(field).inserted {
                            diagnostics.append(opaqueDiagnostic(field,
                                "Accessor function symbolic reference cannot identify an opaque descriptor without resolving executable code"))
                        }
                    }
                    index += 1 + width
                }
            }
        }
        drainRoots()
        let calls = opaqueCallSiteCandidates(diagnostics: &diagnostics)
        var callDescriptors: Set<UInt64> = []
        var structuralDescriptors: Set<UInt64> = []
        func accept(_ address: UInt64, structural: Bool, section: Section? = nil) -> Bool {
            guard opaqueDescriptorOffset(address, at: address, width: 8, section: section) != nil,
                  let flags = opaqueDescriptorWord(at: address, descriptor: address, section: section), flags & 0x1f == 4,
                  flags & 0xff00 == 0, address <= UInt64.max - 8,
                  let parent = opaqueDescriptorPointer(at: address + 4, descriptor: address, indirectable: true, section: section),
                  let parentFlags = readU32(atVA: parent),
                  [0, 1, 16, 17, 18].contains(parentFlags & 0x1f),
                  qualifiedName(atDescriptor: parent) != nil else { return false }
            let rootCount = roots.count
            let wasRootEnqueueCapped = rootEnqueueCapped
            var accepted = false
            defer {
                if !accepted {
                    roots.removeLast(roots.count - rootCount)
                    rootEnqueueCapped = wasRootEnqueueCapped
                }
            }
            var localDiagnostics: [MetadataParseDiagnostic] = []
            guard let record = opaqueDescriptor(at: address, flags: flags, roots: &roots,
                diagnostics: &localDiagnostics, rootEnqueueCapped: &rootEnqueueCapped, requireTypeRefSection: structural, section: section) else {
                if !structural { diagnostics.append(contentsOf: localDiagnostics) }
                return false
            }
            guard localDiagnostics.isEmpty else {
                if !structural { diagnostics.append(contentsOf: localDiagnostics) }
                return false
            }
            visitedDescriptors.insert(address)
            if recordedDescriptors.insert(address).inserted { records.append(record) }
            accepted = true
            return true
        }
        for address in calls.sorted() {
            if accept(address, structural: false) { callDescriptors.insert(address) }
            else { diagnostics.append(opaqueDiagnostic(address, "Opaque runtime argument failed descriptor validation")) }
        }
        var candidateCount = 0
        var unreadableWordCount = 0
        for section in sections where (section.name == "__constg_swiftt" || section.name == "__const")
            && (section.segmentName == nil || section.segmentName == "__TEXT") {
            guard section.address <= UInt64.max - section.size else {
                diagnostics.append(opaqueDiagnostic(section.address, "Overflowing opaque descriptor section")); continue
            }
            var offset: UInt64 = (4 - section.address % 4) % 4
            while offset < section.size, section.size - offset >= 8 {
                let address = section.address + offset
                guard let flags = opaqueDescriptorWord(at: address, descriptor: address, section: section) else {
                    guard unreadableWordCount < Limits.maxTypes else {
                        diagnostics.append(opaqueDiagnostic(address, "Opaque unreadable structural words reached maxTypes cap", grade: .walkCapped))
                        break
                    }
                    unreadableWordCount += 1
                    diagnostics.append(opaqueDiagnostic(address, "Truncated opaque descriptor section"))
                    offset += 4
                    continue
                }
                if flags & 0x1f == 4 {
                    guard candidateCount < Limits.maxTypes else {
                        diagnostics.append(opaqueDiagnostic(address, "Opaque structural candidates reached maxTypes cap", grade: .walkCapped)); break
                    }
                    candidateCount += 1
                    if accept(address, structural: true, section: section) { structuralDescriptors.insert(address) }
                }
                offset += 4
            }
        }
        // Structural and call-site acceptance can enqueue names; drain to the same bounded fixed point.
        drainRoots()
        if cursor < roots.count || rootEnqueueCapped {
            let cappedAddress = cursor < roots.count ? roots[cursor] : roots.last ?? 0
            diagnostics.append(opaqueDiagnostic(cappedAddress, "Opaque mangled-name walk reached maxTypes cap", grade: .walkCapped))
        }
        return (records.sorted { $0.descriptorAddress < $1.descriptorAddress }, diagnostics,
                symbolicReferenceKinds.sorted(), visitedDescriptors.sorted(), accessorReferences.sorted(),
                callDescriptors.sorted(), structuralDescriptors.sorted())
    }

    func parseTypes2Targets() -> [SwiftTypes2Target] { parseTypes2TargetsReport().records }

    func parseTypes2TargetsReport() -> (records: [SwiftTypes2Target], diagnostics: [MetadataParseDiagnostic]) {
        var records: [SwiftTypes2Target] = []
        var diagnostics: [MetadataParseDiagnostic] = []
        for section in sections where section.name == "__swift5_types2" {
            let count = min(section.size / 4, UInt64(Limits.maxTypes))
            for index in 0..<count {
                guard section.address <= UInt64.max - index * 4 else {
                    diagnostics.append(opaqueDiagnostic(section.address, "Overflowing __swift5_types2 array address")); break
                }
                let entry = section.address + index * 4
                guard let descriptor = resolveRelativePointer(at: entry), let flags = readU32(atVA: descriptor) else {
                    diagnostics.append(opaqueDiagnostic(entry, "Unreadable __swift5_types2 target")); continue
                }
                records.append(.init(descriptorAddress: descriptor, flags: flags, kind: flags & 0x1f,
                                     qualifiedName: qualifiedName(atDescriptor: descriptor)))
            }
            if section.size % 4 != 0 { diagnostics.append(opaqueDiagnostic(section.address, "Truncated __swift5_types2 entry")) }
            if section.size / 4 > count { diagnostics.append(opaqueDiagnostic(section.address, "__swift5_types2 reached maxTypes cap", grade: .walkCapped)) }
        }
        return (records, diagnostics)
    }

    private func opaqueDescriptor(at address: UInt64, flags: UInt32, roots: inout [UInt64],
                                  diagnostics: inout [MetadataParseDiagnostic], rootEnqueueCapped: inout Bool, requireTypeRefSection: Bool = false, section: Section? = nil) -> SwiftOpaqueTypeDescriptor? {
        func fail(_ message: String) -> SwiftOpaqueTypeDescriptor? {
            diagnostics.append(opaqueDiagnostic(address, message)); return nil
        }
        guard address <= UInt64.max - 16, opaqueDescriptorOffset(address, at: address, width: 8, section: section) != nil else {
            return fail("Truncated opaque context header")
        }
        func word16(_ field: UInt64) -> UInt16? {
            guard let offset = opaqueDescriptorOffset(address, at: field, width: 2, section: section) else { return nil }
            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        var discoveredRoots: [UInt64] = []
        var droppedRoot = false
        func enqueue(_ name: UInt64) {
            if roots.count < Limits.maxTypes, discoveredRoots.count < Limits.maxTypes - roots.count {
                discoveredRoots.append(name)
            } else {
                droppedRoot = true
            }
        }
        // Swift ABI: context header, generic header/parameters/requirements and optional
        // generic objects, followed by the underlying-type relative pointers.
        guard flags & 0x20 == 0 else { return fail("Unsupported opaque invertible-protocol trailing objects") }
        var next = address + 8
        var requirementCount: UInt32 = 0
        if flags & 0x80 != 0 {
            guard opaqueDescriptorOffset(address, at: next, width: 8, section: section) != nil,
                  let parameterCount = word16(next), let requirements = word16(next + 2),
                  word16(next + 4) != nil, let genericFlags = word16(next + 6) else {
                return fail("Truncated opaque generic header")
            }
            guard genericFlags == 0 else { return fail("Unsupported opaque generic pack, invertible-protocol or value trailing objects (flags \(genericFlags))") }
            guard Int(parameterCount) <= Limits.maxFieldsPerType, Int(requirements) <= Limits.maxFieldsPerType else {
                return fail("Opaque generic signature exceeded maxFieldsPerType cap")
            }
            next += 8
            guard UInt64(parameterCount) + 3 <= UInt64.max - next else { return fail("Overflowing opaque generic parameters") }
            for index in 0..<UInt64(parameterCount) {
                guard let offset = opaqueDescriptorOffset(address, at: next + index, width: 1, section: section) else { return fail("Truncated opaque generic parameter") }
                let byte = bytes[offset]
                guard byte & 0x3f == 0 else { return fail("Unsupported opaque generic pack or value parameter") }
            }
            next += UInt64(parameterCount)
            guard next <= UInt64.max - 3 else { return fail("Overflowing opaque generic alignment") }
            next = (next + 3) & ~UInt64(3)
            guard opaqueDescriptorOffset(address, at: address, width: next - address, section: section) != nil else {
                return fail("Truncated opaque generic alignment")
            }
            requirementCount = UInt32(requirements)
            for _ in 0..<requirements {
                guard next <= UInt64.max - 12, opaqueDescriptorOffset(address, at: next, width: 12, section: section) != nil,
                      let requirementFlags = opaqueDescriptorWord(at: next, descriptor: address, section: section) else {
                    return fail("Truncated opaque generic requirement")
                }
                if let parameter = opaqueDescriptorPointer(at: next + 4, descriptor: address, section: section) { enqueue(parameter) }
                let kind = requirementFlags & 0x1f
                if kind == 1 || kind == 2, let name = opaqueDescriptorPointer(at: next + 8, descriptor: address, section: section) { enqueue(name) }
                next += 12
            }
        }
        let underlyingCount = UInt64(flags >> 16)
        guard !requireTypeRefSection || underlyingCount > 0 else { return fail("Opaque structural candidate has no underlying types") }
        guard underlyingCount <= UInt64(Limits.maxFieldsPerType) else { return fail("Opaque underlying types exceeded maxFieldsPerType cap") }
        var underlying: [SwiftOpaqueTypeDescriptor.UnderlyingType] = []
        for _ in 0..<underlyingCount {
            guard next <= UInt64.max - 4, let name = opaqueDescriptorPointer(at: next, descriptor: address, section: section), let raw = opaqueMangledBytes(at: name) else {
                return fail("Truncated or unreadable opaque underlying type")
            }
            if requireTypeRefSection {
                guard !raw.isEmpty, sections.contains(where: {
                    $0.name == "__swift5_typeref" && name >= $0.address && name - $0.address < $0.size
                }) else { return fail("Opaque underlying argument is outside __swift5_typeref") }
            }
            let mangled = sanitizedMangled(raw)
            let demangled: String?
            if raw.allSatisfy({ $0 >= 0x20 }) {
                demangled = SwiftDemangler.demangleType(String(decoding: raw, as: UTF8.self))
            } else {
                demangled = decodeFieldType(at: name, diagnostics: &diagnostics).typeName
            }
            underlying.append(.init(mangledTypeName: mangled, typeName: demangled))
            enqueue(name)
            next += 4
        }
        roots.append(contentsOf: discoveredRoots)
        rootEnqueueCapped = rootEnqueueCapped || droppedRoot
        let parent = opaqueDescriptorPointer(at: address + 4, descriptor: address, indirectable: true, section: section).flatMap { qualifiedName(atDescriptor: $0) }
        return .init(descriptorAddress: address, parentQualifiedName: parent, underlyingTypes: underlying, requirementCount: requirementCount)
    }

    /// Anchor every descriptor field to its original section, including file bounds and padding.
    /// Structural reads use the section being scanned; other discovery retains first-containing mapping.
    /// Never let another section complete a truncated descriptor.
    private func opaqueDescriptorOffset(_ descriptor: UInt64, at field: UInt64, width: UInt64, section: Section? = nil) -> Int? {
        guard let section = section ?? sections.first(where: { descriptor >= $0.address && descriptor - $0.address < $0.size }),
              descriptor >= section.address, descriptor - section.address < section.size,
              !section.isZeroFill, section.address <= UInt64.max - section.size,
              field >= descriptor, field >= section.address else { return nil }
        let delta = field - section.address
        guard delta <= section.size, width <= section.size - delta,
              section.fileOffset <= UInt64.max - delta else { return nil }
        let offset = section.fileOffset + delta
        guard offset <= UInt64(bytes.count), width <= UInt64(bytes.count) - offset else { return nil }
        return Int(offset)
    }

    private func opaqueDescriptorWord(at field: UInt64, descriptor: UInt64, section: Section? = nil) -> UInt32? {
        guard let offset = opaqueDescriptorOffset(descriptor, at: field, width: 4, section: section) else { return nil }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private func opaqueDescriptorPointer(at field: UInt64, descriptor: UInt64, indirectable: Bool = false, section: Section? = nil) -> UInt64? {
        guard let word = opaqueDescriptorWord(at: field, descriptor: descriptor, section: section), word != 0 else { return nil }
        let raw = Int32(bitPattern: word)
        let displacement = indirectable ? raw & ~1 : raw
        let target = UInt64(bitPattern: Int64(bitPattern: field) &+ Int64(displacement))
        return indirectable && raw & 1 == 1 ? rebaseTargets[target] : target
    }

    /// A bounded constant-address interpreter. Unknown instructions discard all register
    /// facts; calls and control-flow joins never carry facts into another basic block.
    private func opaqueCallSiteCandidates(diagnostics: inout [MetadataParseDiagnostic]) -> Set<UInt64> {
        enum Value { case address(UInt64), bound(String) }
        func signed(_ bits: UInt32, width: Int) -> Int64 {
            Int64(Int32(bitPattern: bits << (32 - width)) >> (32 - width))
        }
        func target(_ pc: UInt64, _ displacement: Int64) -> UInt64? {
            if displacement >= 0 {
                let (value, overflow) = pc.addingReportingOverflow(UInt64(displacement))
                return overflow ? nil : value
            }
            let (value, overflow) = pc.subtractingReportingOverflow(UInt64(-displacement))
            return overflow ? nil : value
        }
        func loaded(_ slot: UInt64) -> Value? {
            if let name = bindNames[slot] { return .bound(name) }
            return (rebaseTargets[slot] ?? readU64(atVA: slot)).map { .address($0) }
        }
        func step(_ word: UInt32, _ pc: UInt64, _ registers: inout [Int: Value]) {
            let rd = Int(word & 31), rn = Int((word >> 5) & 31)
            if word & 0x1f000000 == 0x10000000 { // ADR / ADRP
                let immediate = signed(((word >> 5) & 0x7ffff) << 2 | ((word >> 29) & 3), width: 21)
                let page = word & 0x80000000 != 0
                registers[rd] = target(page ? pc & ~0xfff : pc, page ? immediate * 4096 : immediate).map { .address($0) }
            } else if word & 0xff800000 == 0x91000000 { // ADD Xd, Xn, #imm
                if rn != 31, case let .address(base)? = registers[rn] {
                    let amount = UInt64((word >> 10) & 0xfff) << (word & 0x400000 == 0 ? 0 : 12)
                    let (value, overflow) = base.addingReportingOverflow(amount)
                    registers[rd] = overflow ? nil : .address(value)
                } else { registers[rd] = nil }
            } else if word & 0xffc00000 == 0xf9400000 { // LDR Xt, [Xn, #imm]
                if rn != 31, case let .address(base)? = registers[rn] {
                    let (slot, overflow) = base.addingReportingOverflow(UInt64((word >> 10) & 0xfff) * 8)
                    registers[rd] = overflow ? nil : loaded(slot)
                } else { registers[rd] = nil }
            } else if word & 0xff000000 == 0x58000000 { // LDR Xt, label
                registers[rd] = target(pc, signed((word >> 5) & 0x7ffff, width: 19) * 4).flatMap(loaded)
            } else if word & 0xffe0ffe0 == 0xaa0003e0 { // MOV Xd, Xm
                registers[rd] = registers[Int((word >> 16) & 31)]
            } else if word & 0x1f800000 == 0x12800000 { // move-wide writes only Rd
                registers[rd] = nil
            } else if word == 0xd503201f { // NOP
            } else {
                registers.removeAll(keepingCapacity: true)
            }
            registers[31] = nil
        }
        func runtime(_ value: Value?) -> String? {
            guard let value else { return nil }
            if case let .bound(name) = value { return name }
            guard case let .address(start) = value,
                  sections.contains(where: { $0.name.contains("stubs") && start >= $0.address && start - $0.address < $0.size }) else { return nil }
            var registers: [Int: Value] = [:]
            for index in 0..<8 {
                guard start <= UInt64.max - UInt64(index * 4) else { return nil }
                let pc = start + UInt64(index * 4)
                guard let word = readU32(atVA: pc) else { return nil }
                if word & 0xfffffc1f == 0xd61f0000 {
                    if case let .bound(name)? = registers[Int((word >> 5) & 31)] { return name }
                    return nil
                }
                step(word, pc, &registers)
            }
            return nil
        }
        func descriptorRegister(_ name: String) -> Int? {
            switch name {
            case "_swift_getOpaqueTypeMetadata", "_swift_getOpaqueTypeMetadata2": return 2
            case "_swift_getOpaqueTypeConformance", "_swift_getOpaqueTypeConformance2": return 1
            default: return nil
            }
        }
        var result: Set<UInt64> = []
        var callCount = 0
        for section in sections where section.name == "__text" {
            guard section.address <= UInt64.max - section.size else {
                diagnostics.append(opaqueDiagnostic(section.address, "Overflowing opaque call-site section")); continue
            }
            // Discover branch targets before interpreting, so even a forward join starts
            // with unknown registers. This is instruction decoding, without execution.
            var joins: Set<UInt64> = []
            var offset: UInt64 = 0
            while offset < section.size, section.size - offset >= 4 {
                let pc = section.address + offset
                guard let word = readU32(atVA: pc) else { break }
                let destination: UInt64?
                if word & 0x7c000000 == 0x14000000 {
                    destination = target(pc, signed(word & 0x03ffffff, width: 26) * 4)
                } else if word & 0xff000010 == 0x54000000 || word & 0x7e000000 == 0x34000000 {
                    destination = target(pc, signed((word >> 5) & 0x7ffff, width: 19) * 4)
                } else if word & 0x7e000000 == 0x36000000 {
                    destination = target(pc, signed((word >> 5) & 0x3fff, width: 14) * 4)
                } else { destination = nil }
                if let destination { joins.insert(destination) }
                offset += 4
            }
            var registers: [Int: Value] = [:]
            offset = 0
            while offset < section.size, section.size - offset >= 4 {
                let pc = section.address + offset
                guard let word = readU32(atVA: pc) else {
                    diagnostics.append(opaqueDiagnostic(pc, "Truncated opaque call-site instruction")); break
                }
                if joins.contains(pc) { registers.removeAll(keepingCapacity: true) }
                var callee: Value?
                let direct = word & 0x7c000000 == 0x14000000
                let indirect = word & 0xfffffc1f == 0xd63f0000 || word & 0xfffffc1f == 0xd61f0000
                if direct { callee = target(pc, signed(word & 0x03ffffff, width: 26) * 4).map { .address($0) } }
                else if indirect { callee = registers[Int((word >> 5) & 31)] }
                if let name = runtime(callee), let argument = descriptorRegister(name) {
                    guard callCount < Limits.maxTypes else {
                        diagnostics.append(opaqueDiagnostic(pc, "Opaque runtime calls reached maxTypes cap", grade: .walkCapped)); break
                    }
                    callCount += 1
                    if case let .address(address)? = registers[argument] { result.insert(address) }
                    else { diagnostics.append(opaqueDiagnostic(pc, "Opaque runtime descriptor argument x\(argument) is not established in this basic block")) }
                }
                if direct || indirect { registers.removeAll(keepingCapacity: true) }
                else { step(word, pc, &registers) }
                offset += 4
            }
        }
        return result
    }

    private func opaqueByte(at address: UInt64) -> UInt8? {
        guard let offset = fileOffset(forVA: address), offset >= 0, offset < bytes.count else { return nil }
        return bytes[offset]
    }

    private func opaqueMangledBytes(at address: UInt64) -> [UInt8]? {
        guard let raw = readMangledBytes(atVA: address, requiresTerminator: true),
              let section = sections.first(where: { address >= $0.address && address - $0.address < $0.size }),
              UInt64(raw.count) < UInt64.max - address,
              UInt64(raw.count) < section.size - (address - section.address) else { return nil }
        return raw
    }

    private func opaqueDiagnostic(_ address: UInt64, _ message: String,
                                  grade: MetadataParseDiagnostic.Grade = .skippedItem) -> MetadataParseDiagnostic {
        .init(grade: grade, address: address, message: message)
    }

    /// Recover addresses from every reflection name source decoded by the parser, including
    /// extension contexts and nominal superclass names. The name walk also follows names
    /// discovered in opaque underlying types and generic requirements.
    private func opaqueMangledRoots(diagnostics: inout [MetadataParseDiagnostic]) -> [UInt64] {
        var roots: Set<UInt64> = []
        func add(_ field: UInt64) {
            if roots.count < Limits.maxTypes, let target = resolveRelativePointer(at: field) { roots.insert(target) }
        }
        for section in sections where section.name == "__swift5_typeref" {
            var offset: UInt64 = 0
            var count = 0
            while offset < section.size, count < Limits.maxTypes, section.address <= UInt64.max - offset {
                let address = section.address + offset
                guard let raw = opaqueMangledBytes(at: address) else {
                    diagnostics.append(opaqueDiagnostic(address, "Truncated __swift5_typeref mangled name")); break
                }
                if !raw.isEmpty { roots.insert(address) }
                offset += UInt64(raw.count) + 1
                count += 1
            }
            if offset < section.size, count == Limits.maxTypes { diagnostics.append(opaqueDiagnostic(section.address, "__swift5_typeref reached maxTypes cap", grade: .walkCapped)) }
        }
        let reflectionSections: Set<String> = ["__swift5_fieldmd", "__swift5_assocty", "__swift5_capture", "__swift5_builtin", "__swift5_mpenum"]
        for section in sections where reflectionSections.contains(section.name) {
            var offset: UInt64 = 0
            var count = 0
            recordLoop: while offset < section.size, count < Limits.maxTypes, section.address <= UInt64.max - offset {
                let address = section.address + offset
                guard address <= UInt64.max - 16 else { break recordLoop }
                let length: UInt64
                switch section.name {
                case "__swift5_fieldmd":
                    guard section.size - offset >= 16, let size = readU16(atVA: address + 10), size >= 12,
                          let fields = readU32(atVA: address + 12), fields <= UInt32(Limits.maxFieldsPerType) else { break recordLoop }
                    length = 16 + UInt64(size) * UInt64(fields)
                    guard length <= section.size - offset, length <= UInt64.max - address else { break recordLoop }
                    add(address); add(address + 4)
                    for field in 0..<UInt64(fields) { add(address + 16 + field * UInt64(size) + 4) }
                case "__swift5_assocty":
                    guard section.size - offset >= 16, let fields = readU32(atVA: address + 8), fields <= UInt32(Limits.maxFieldsPerType),
                          let size = readU32(atVA: address + 12), size >= 8 else { break recordLoop }
                    length = 16 + UInt64(size) * UInt64(fields)
                    guard length <= section.size - offset, length <= UInt64.max - address else { break recordLoop }
                    add(address); add(address + 4)
                    for field in 0..<UInt64(fields) { add(address + 16 + field * UInt64(size) + 4) }
                case "__swift5_capture":
                    guard section.size - offset >= 12, let captures = readU32(atVA: address), let sources = readU32(atVA: address + 4),
                          captures <= UInt32(Limits.maxFieldsPerType), sources <= UInt32(Limits.maxFieldsPerType) else { break recordLoop }
                    length = 12 + UInt64(captures) * 4 + UInt64(sources) * 8
                    guard length <= section.size - offset, length <= UInt64.max - address else { break recordLoop }
                    for field in 0..<(UInt64(captures) + UInt64(sources) * 2) { add(address + 12 + field * 4) }
                case "__swift5_builtin":
                    length = 20
                    guard length <= section.size - offset, length <= UInt64.max - address else { break recordLoop }
                    add(address)
                case "__swift5_mpenum":
                    guard section.size - offset >= 8, let flags = readU32(atVA: address + 4) else { break recordLoop }
                    guard flags >> 16 > 0 else { break recordLoop }
                    length = 4 + UInt64(flags >> 16) * 4
                    guard length <= section.size - offset, length <= UInt64.max - address else { break recordLoop }
                    add(address)
                default: break recordLoop
                }
                offset += length
                count += 1
            }
            if offset < section.size {
                let address = section.address <= UInt64.max - offset ? section.address + offset : section.address
                diagnostics.append(opaqueDiagnostic(address,
                    "Incomplete opaque-name discovery in \(section.name): truncated record or count cap",
                    grade: count >= Limits.maxTypes ? .walkCapped : .abandonedList))
            }
        }
        for section in sections where section.name == "__swift5_types" || section.name == "__swift5_types2" || section.name == "__swift5_protos" {
            for index in 0..<min(section.size / 4, UInt64(Limits.maxTypes)) {
                guard section.address <= UInt64.max - index * 4,
                      let target = resolveRelativeIndirectablePointer(at: section.address + index * 4) else { continue }
                var context = target
                var visited: Set<UInt64> = []
                for _ in 0..<Limits.maxParentWalk {
                    guard visited.insert(context).inserted, context <= UInt64.max - 24, let flags = readU32(atVA: context) else { break }
                    if flags & 0x1f == 1 { add(context + 8) }
                    if flags & 0x1f == 16 { add(context + 20) }
                    guard let parent = resolveRelativeIndirectablePointer(at: context + 4) else { break }
                    context = parent
                }
            }
        }
        if roots.count >= Limits.maxTypes { diagnostics.append(opaqueDiagnostic(0, "Opaque name roots reached maxTypes cap", grade: .walkCapped)) }
        return roots.sorted()
    }
}
