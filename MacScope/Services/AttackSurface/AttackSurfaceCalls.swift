import Foundation

extension AttackSurfaceAnalyzer {
    private static var xpcCallSignatures: CallSignatureCatalog { CallSignatureCatalog([
        .init(canonicalName: "xpc_connection_create_mach_service", returnType: "xpc_connection_t",
              parameters: [.init(type: "const char *", name: "name"),
                           .init(type: "dispatch_queue_t", name: "queue"),
                           .init(type: "uint64_t", name: "flags")]),
        .init(canonicalName: "xpc_main", returnType: "void",
              parameters: [.init(type: "xpc_connection_handler_t", name: "handler")]),
        .init(canonicalName: "xpc_dictionary_get_string", returnType: "const char *",
              parameters: [.init(type: "xpc_object_t", name: "dictionary"),
                           .init(type: "const char *", name: "key")]),
    ]) }
    /// Uses resolved executable stubs, then a bounded straight-line constant slice. A selector,
    /// string, or register value without a resolved callee never creates a listener link.
    func inspectCalls(_ file: MachOFile, bytes: Data?) -> [Report.Listener] {
        guard let bytes else { return [] }
        let entries = file.indirectSymbols.map {
            IndirectSymbolSummary(id: UUID(), kind: $0.kind.rawValue, sourceSection: $0.sourceSection,
                                  address: $0.address, entrySize: $0.entrySize, tableIndex: $0.tableIndex,
                                  rawSymbolIndex: $0.rawSymbolIndex, symbolIndex: $0.symbolIndex,
                                  symbolName: $0.symbolName, libraryOrdinal: $0.libraryOrdinal,
                                  libraryName: $0.libraryName, isLocal: $0.isLocal, isAbsolute: $0.isAbsolute)
        }
        let selrefs = Dictionary(file.objectiveCMetadata.selectorReferences.compactMap { reference -> (UInt64, String)? in
            guard let name = reference.resolvedName else { return nil }
            return (reference.sourceAddress, name)
        }, uniquingKeysWith: { first, _ in first })
        let msgTargets = Set(entries.filter { $0.symbolName == "_objc_msgSend" && $0.kind == MachOIndirectSymbolKind.symbolStub.rawValue }.map(\.address))
            .union(file.symbols.compactMap { $0.name == "_objc_msgSend" ? $0.address : nil })
        let msgSlots = Set(entries.filter { $0.symbolName == "_objc_msgSend" && $0.kind != MachOIndirectSymbolKind.symbolStub.rawValue }.map(\.address))
        var objcStubs: [UInt64: String] = [:]
        for section in file.sections where section.sectionName == "__objc_stubs" {
            if let sectionBytes = sectionData(section, file: file, bytes: bytes) {
                objcStubs.merge(ObjCStubSelectorRecovery.names(stubBytes: sectionBytes,
                    sectionAddress: section.address, selectorBySelrefAddress: selrefs,
                    messageSendTargets: msgTargets, messageSendPointerSlots: msgSlots),
                    uniquingKeysWith: { first, _ in first })
            }
        }
        let symbolicator = StubCallSymbolicator(indirectSymbols: entries, objcStubNames: objcStubs)
        let directNames = Dictionary(file.symbols.compactMap { symbol -> (UInt64, String)? in
            guard let address = symbol.address else { return nil }
            return (address, symbol.name)
        }, uniquingKeysWith: { first, _ in first })
        var strings = Dictionary(file.stringLiterals.map { ($0.address, $0.value) }, uniquingKeysWith: { first, _ in first })
        let rebases = Dictionary((file.dyldChainedFixups?.fixups ?? []).compactMap { fixup -> (UInt64, UInt64)? in
            guard let target = fixup.rebaseTargetAddress else { return nil }
            return (fixup.address, target)
        }, uniquingKeysWith: { first, _ in first })
        for section in file.sections where section.sectionName == "__cfstring" {
            guard let data = sectionData(section, file: file, bytes: bytes) else { continue }
            for offset in stride(from: 0, to: data.count - data.count % 32, by: 32) {
                let object = section.address + UInt64(offset)
                let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 16, as: UInt64.self).littleEndian }
                if let value = strings[rebases[object + 16] ?? raw] { strings[object] = value }
            }
        }
        let protocols = Dictionary(file.objectiveCMetadata.protocols.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        let executableImportStubs = Set(entries.filter {
            StubCallSymbolicator.linkageSlotClass(for: $0) == .executableImportStub
        }.map(\.address))
        var calls: [Call] = []
        for section in file.sections where section.isExecutableInstructions {
            guard let data = sectionData(section, file: file, bytes: bytes) else { continue }
            let words = stride(from: 0, to: data.count - data.count % 4, by: 4).map { offset in
                data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
            }
            for index in words.indices {
                let word = words[index]
                let isCall = word & 0xFC00_0000 == 0x9400_0000
                let isTailBranch = word & 0xFC00_0000 == 0x1400_0000
                guard isCall || isTailBranch else { continue }
                let pc = section.address &+ UInt64(index * 4)
                let signed = Int64(Int32(bitPattern: (word & 0x03FF_FFFF) << 6) >> 6) * 4
                let target = signed >= 0 ? pc.addingReportingOverflow(UInt64(signed)) : pc.subtractingReportingOverflow(UInt64(-signed))
                guard !target.overflow else { continue }
                guard let callee = symbolicator.name(forStubTarget: target.partialValue) ?? directNames[target.partialValue] else { continue }
                // A B is a call only with an executable import stub and a catalog signature.
                guard isCall || (executableImportStubs.contains(target.partialValue)
                    && Self.xpcCallSignatures.signature(for: callee) != nil) else { continue }
                calls.append(.init(address: pc, callee: callee,
                                   x0: constantAddress(register: 0, before: index, words: words, base: section.address),
                                   x1: constantAddress(register: 1, before: index, words: words, base: section.address),
                                   x2: constantAddress(register: 2, before: index, words: words, base: section.address)
                                       ?? referencedAddress(register: 2, before: index, words: words,
                                                            base: section.address, file: file, bytes: bytes, rebases: rebases),
                                   immediateX2: immediate(register: 2, before: index, words: words)))
            }
        }
        let interfaceCalls = calls.filter { $0.callee.hasSuffix("interfaceWithProtocol:") }
        let interfaces: [Report.Interface] = interfaceCalls.map { call in
            guard let address = call.x2, let proto = protocols[address] else {
                return .init(protocolName: "unresolved", methods: [], allowListSelectors: [],
                             confidence: .needsReview,
                             reason: "interfaceWithProtocol: callee resolved, protocol argument is not a proven in-image protocol")
            }
            return .init(protocolName: proto.name,
                         methods: (proto.requiredMethods + proto.optionalMethods).map { method in
                            .init(selector: method.selector, typeEncoding: method.typeEncoding,
                                  parameterTypes: parameterTypes(method),
                                  takesReplyBlock: method.typeEncoding?.contains("@?") == true)
                         }, allowListSelectors: [], confidence: .needsReview,
                         reason: calls.contains(where: { $0.callee.hasSuffix("setClasses:forSelector:argumentIndex:ofReply:") })
                            ? "Protocol construction and allow-list call found; selector and exported-interface assignment unresolved"
                            : "Protocol construction found; exported-interface assignment to this listener is not proven")
        }
        let accepts = file.objectiveCMetadata.classes.compactMap { cls -> (String, UInt64)? in
            guard let method = cls.instanceMethods.first(where: { $0.selector == "listener:shouldAcceptNewConnection:" }),
                  let address = method.implementation else { return nil }
            return (cls.name, address)
        }
        let starts = file.functionStarts.map(\.address).sorted()
        func functionRange(containing address: UInt64) -> Range<UInt64>? {
            guard let start = starts.last(where: { $0 <= address }) else { return nil }
            let end = starts.first(where: { $0 > start }) ?? UInt64.max
            return start..<end
        }
        func blockHandlers(in address: UInt64) -> [UInt64] {
            guard let range = functionRange(containing: address) else { return [] }
            return calls.filter { range.contains($0.address)
                && ($0.callee == "_xpc_connection_set_event_handler" || $0.callee == "xpc_connection_set_event_handler")
            }.compactMap { $0.x1.flatMap { blockInvoke(at: $0, file: file, bytes: bytes, rebases: rebases) } }
        }
        func messageKeys(in address: UInt64) -> [String] {
            guard let range = functionRange(containing: address) else { return [] }
            return calls.filter { range.contains($0.address)
                && Self.xpcCallSignatures.signature(for: $0.callee) != nil
                && $0.callee.contains("xpc_dictionary_get_")
            }.compactMap { $0.x1.flatMap { strings[$0] } }
        }
        var result: [Report.Listener] = []
        for call in calls {
            if call.callee.hasSuffix("initWithMachServiceName:") || call.callee.hasSuffix("serviceListener") || call.callee.hasSuffix("anonymousListener") {
                let name = call.callee.hasSuffix("initWithMachServiceName:") ? call.x2.flatMap { strings[$0] } : nil
                let accept = accepts.count == 1 ? accepts[0] : nil
                result.append(.init(kind: .nsxpc, setupAPI: call.callee, serviceName: name, setupAddress: call.address,
                    delegateClass: accept?.0, acceptanceAddress: accept?.1, peerHandlerAddress: nil,
                    interfaces: interfaces, messageKeys: [], confidence: .needsReview,
                    reason: name == nil ? "Mach service name is absent or constant argument unresolved; delegate/interface assignment unproven"
                        : "Service name is constant at resolved setup call; delegate/interface assignment unproven"))
            } else if call.callee == "_xpc_connection_create_mach_service" || call.callee == "xpc_connection_create_mach_service" {
                guard Self.xpcCallSignatures.signature(for: call.callee) != nil else { continue }
                guard let flags = call.immediateX2, flags & 1 != 0 else { continue }
                let name = call.x0.flatMap { strings[$0] }
                let handlerCandidates = blockHandlers(in: call.address)
                let handler = handlerCandidates.count == 1 ? handlerCandidates[0] : nil
                result.append(.init(kind: .libxpc, setupAPI: call.callee, serviceName: name, setupAddress: call.address,
                                    delegateClass: nil, acceptanceAddress: nil, peerHandlerAddress: handler,
                                    interfaces: [], messageKeys: handler.map { messageKeys(in: $0) } ?? [], confidence: .needsReview,
                                    reason: "Listener flag is constant; handler candidate shares a function, but receiver assignment is unproven"))
            } else if call.callee == "_xpc_main" || call.callee == "xpc_main" {
                guard Self.xpcCallSignatures.signature(for: call.callee) != nil else { continue }
                let handler = call.x0.flatMap { starts.contains($0) ? $0 : nil }
                let keys = handler.map { address in
                    Array(Set(messageKeys(in: address)
                        + blockHandlers(in: address).flatMap { messageKeys(in: $0) })).sorted()
                } ?? []
                result.append(.init(kind: .libxpc, setupAPI: call.callee, serviceName: nil, setupAddress: call.address,
                                    delegateClass: nil, acceptanceAddress: nil, peerHandlerAddress: handler,
                                    interfaces: [], messageKeys: keys, confidence: .needsReview,
                                    reason: "xpc_main handler is present; no static Mach service name is bound by this call"))
            }
        }
        return result
    }

    private struct Call {
        var address: UInt64
        var callee: String
        var x0: UInt64?
        var x1: UInt64?
        var x2: UInt64?
        var immediateX2: UInt64?
    }

    private func sectionData(_ section: MachOSection, file: MachOFile, bytes: Data) -> Data? {
        guard !section.isZeroFill else { return nil }
        let offset = file.selectedSliceOffset.addingReportingOverflow(UInt64(section.fileOffset))
        guard !offset.overflow, section.size <= 32 * 1024 * 1024,
              offset.partialValue <= UInt64(bytes.count), section.size <= UInt64(bytes.count) - offset.partialValue else { return nil }
        let start = Int(offset.partialValue)
        return bytes.subdata(in: start..<(start + Int(section.size)))
    }

    // Accept only ADRP + ADD in one straight-line window. No call, branch, or unknown write to
    // the destination may intervene; this establishes the actual argument to a known callee.
    private func constantAddress(register: UInt32, before index: Int, words: [UInt32], base: UInt64) -> UInt64? {
        guard index > 0 else { return nil }
        let lower = max(0, index - 8)
        for addIndex in stride(from: index - 1, through: lower, by: -1) {
            let add = words[addIndex]
            guard add & 0xFF00_0000 == 0x9100_0000, add & 0x1F == register,
                  (add >> 5) & 0x1F == register else { continue }
            let shift = (add >> 22) & 1 == 0 ? 0 : 12
            let delta = UInt64((add >> 10) & 0xFFF) << shift
            guard addIndex > lower else { continue }
            for pageIndex in stride(from: addIndex - 1, through: lower, by: -1) {
                let page = words[pageIndex]
                guard let pageAddress = ObjCStubSelectorRecovery.adrpPage(page,
                    pc: base &+ UInt64(pageIndex * 4), destination: register) else { continue }
                let between = words[(pageIndex + 1)..<index]
                guard !between.contains(where: { $0 & 0xFC00_0000 == 0x9400_0000 || $0 & 0x7C00_0000 == 0x1400_0000 }) else { return nil }
                let firstGap = words[(pageIndex + 1)..<addIndex]
                let secondGap = words[(addIndex + 1)..<index]
                guard !firstGap.contains(where: { $0 & 0x1F == register }),
                      !secondGap.contains(where: { $0 & 0x1F == register }) else { return nil }
                let sum = pageAddress.addingReportingOverflow(delta)
                return sum.overflow ? nil : sum.partialValue
            }
        }
        return nil
    }

    private func immediate(register: UInt32, before index: Int, words: [UInt32]) -> UInt64? {
        guard index > 0 else { return nil }
        for offset in 1...min(index, 8) {
            let word = words[index - offset]
            if word & 0xFF80_001F == (0xD280_0000 | register)
                || word & 0xFF80_001F == (0x5280_0000 | register) {
                return UInt64((word >> 5) & 0xFFFF) << (((word >> 21) & 0x3) * 16)
            }
            if word & 0xFC00_0000 == 0x9400_0000 || word & 0x7C00_0000 == 0x1400_0000
                || word & 0x1F == register { return nil }
        }
        return nil
    }

    private func referencedAddress(register: UInt32, before index: Int, words: [UInt32],
                                   base: UInt64, file: MachOFile, bytes: Data,
                                   rebases: [UInt64: UInt64]) -> UInt64? {
        guard index >= 2 else { return nil }
        let callAddress = base + UInt64(index * 4)
        guard let functionStart = file.functionStarts.map(\.address)
            .filter({ $0 >= base && $0 <= callAddress }).max() else { return nil }
        let lower = max(Int((functionStart - base) / 4), index - 24)
        var tracked = register
        for cursor in stride(from: index - 1, through: lower, by: -1) {
            let word = words[cursor]
            if word & 0xFC00_0000 == 0x9400_0000 {
                // AAPCS64 preserves x19-x28. Caller-saved arguments cannot cross a call.
                guard (19...28).contains(tracked) else { return nil }
                continue
            }
            // MOV Xd, Xm (the unshifted ORR Xd, XZR, Xm alias).
            if word & 0xFFE0_FFE0 == 0xAA00_03E0 {
                if word & 0x1F == tracked {
                    tracked = (word >> 16) & 0x1F
                    guard tracked != 31 else { return nil }
                }
                continue
            }
            // Only a direct ADRP/LDR pointer slot is accepted; no speculative dereference.
            if word & 0xFFC0_0000 == 0xF940_0000 {
                guard word & 0x1F == tracked else { continue }
                let pageRegister = (word >> 5) & 0x1F
                guard cursor > lower,
                      let offset = ObjCStubSelectorRecovery.ldr64UnsignedOffset(word,
                          destination: tracked, base: pageRegister),
                      let page = ObjCStubSelectorRecovery.adrpPage(words[cursor - 1],
                          pc: base + UInt64((cursor - 1) * 4), destination: pageRegister) else { return nil }
                let slot = page.addingReportingOverflow(offset)
                guard !slot.overflow else { return nil }
                return pointerTarget(at: slot.partialValue, file: file, bytes: bytes, rebases: rebases)
            }
            // Known independent address writes are harmless; every other instruction abstains.
            if word & 0x9F00_0000 == 0x9000_0000 || word & 0xFF00_0000 == 0x9100_0000 {
                guard word & 0x1F != tracked else { return nil }
                continue
            }
            return nil
        }
        return nil
    }

    private func blockInvoke(at address: UInt64, file: MachOFile, bytes: Data,
                             rebases: [UInt64: UInt64]) -> UInt64? {
        let field = address.addingReportingOverflow(16)
        return field.overflow ? nil : pointerTarget(at: field.partialValue, file: file, bytes: bytes, rebases: rebases)
    }

    private func pointerTarget(at address: UInt64, file: MachOFile, bytes: Data,
                               rebases: [UInt64: UInt64]) -> UInt64? {
        if let target = rebases[address] { return target }
        guard let section = file.sections.first(where: {
            address >= $0.address && address - $0.address <= $0.size
                && $0.size - (address - $0.address) >= 8
        }), let data = sectionData(section, file: file, bytes: bytes) else { return nil }
        let local = Int(address - section.address)
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: local, as: UInt64.self).littleEndian }
    }

    private func parameterTypes(_ method: ObjCMethod) -> [String] {
        let count = method.selector.filter { $0 == ":" }.count
        guard let encoding = method.typeEncoding else { return Array(repeating: "unknown", count: count) }
        // ObjCTypeEncoding renders the authoritative grammar; extract only its positional
        // argument annotations. Unknown encodings remain explicit.
        let signature = ObjCTypeEncoding.methodSignature(method)
        let pattern = try? NSRegularExpression(pattern: ":\\(([^)]*)\\)arg[0-9]+")
        let matches = pattern?.matches(in: signature, range: NSRange(signature.startIndex..., in: signature)) ?? []
        let extracted = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: signature) else { return nil }
            return String(signature[range])
        }
        return (0..<count).map { $0 < extracted.count ? extracted[$0] : (encoding.contains("@?") ? "block/unknown" : "unknown") }
    }
}
