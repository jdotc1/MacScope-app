import Foundation

extension SwiftMetadataParser {
    func parseCaptureDescriptors() -> [SwiftCaptureDescriptor] { parseCaptureDescriptorsReport().records }

    func parseCaptureDescriptorsReport() -> (records: [SwiftCaptureDescriptor], diagnostics: [MetadataParseDiagnostic]) {
        reflectionRecords(in: "__swift5_capture") { address, remaining in
            guard remaining >= 12,
                  let captures = readU32(atVA: address), let sources = readU32(atVA: address + 4),
                  let bindings = readU32(atVA: address + 8),
                  captures <= Limits.maxFieldsPerType, sources <= Limits.maxFieldsPerType,
                  bindings <= Limits.maxFieldsPerType else { return (nil, nil) }
            let length = 12 + UInt64(captures) * 4 + UInt64(sources) * 8
            guard length <= remaining, reflectionRangeIsReadable(address, length) else { return (nil, nil) }
            var names: [String] = []
            var metadata: [SwiftCaptureMetadataSource] = []
            for index in 0..<Int(captures) {
                guard let name = reflectionName(at: address + 12 + UInt64(index) * 4) else { return (nil, length) }
                names.append(name)
            }
            let sourceBase = address + 12 + UInt64(captures) * 4
            for index in 0..<Int(sources) {
                let slot = sourceBase + UInt64(index) * 8
                guard let type = reflectionName(at: slot),
                      let source = reflectionName(at: slot + 4, decodeType: false) else { return (nil, length) }
                metadata.append(.init(typeName: type, sourceName: source))
            }
            return (.init(descriptorAddress: address, captureTypeNames: names,
                          metadataSources: metadata, numBindings: bindings), length)
        }
    }

    func parseAssociatedTypes() -> [SwiftAssociatedTypeRecord] { parseAssociatedTypesReport().records }

    func parseAssociatedTypesReport() -> (records: [SwiftAssociatedTypeRecord], diagnostics: [MetadataParseDiagnostic]) {
        reflectionRecords(in: "__swift5_assocty") { address, remaining in
            guard remaining >= 16, let count = readU32(atVA: address + 8),
                  let stride = readU32(atVA: address + 12), stride >= 8,
                  count <= Limits.maxFieldsPerType else { return (nil, nil) }
            let length = 16 + UInt64(count) * UInt64(stride)
            guard length <= remaining, reflectionRangeIsReadable(address, length) else { return (nil, nil) }
            guard let conforming = reflectionName(at: address),
                  let proto = reflectionName(at: address + 4) else { return (nil, length) }
            var substitutions: [SwiftAssociatedTypeSubstitution] = []
            for index in 0..<Int(count) {
                let slot = address + 16 + UInt64(index) * UInt64(stride)
                guard let nameVA = resolveRelativePointer(at: slot), let name = readCString(atVA: nameVA),
                      reflectionRangeIsReadable(nameVA, UInt64(name.utf8.count) + 1),
                      let type = reflectionName(at: slot + 4) else { return (nil, length) }
                substitutions.append(.init(name: name, substitutedTypeName: type))
            }
            return (.init(descriptorAddress: address, conformingTypeName: conforming,
                          protocolTypeName: proto, associatedTypes: substitutions), length)
        }
    }

    func parseBuiltinTypes() -> [SwiftBuiltinTypeRecord] { parseBuiltinTypesReport().records }

    func parseBuiltinTypesReport() -> (records: [SwiftBuiltinTypeRecord], diagnostics: [MetadataParseDiagnostic]) {
        reflectionRecords(in: "__swift5_builtin") { address, remaining in
            guard remaining >= 20, reflectionRangeIsReadable(address, 20) else { return (nil, nil) }
            guard let name = reflectionName(at: address), let size = readU32(atVA: address + 4),
                  let alignment = readU32(atVA: address + 8), let stride = readU32(atVA: address + 12),
                  let extra = readU32(atVA: address + 16) else { return (nil, 20) }
            return (.init(descriptorAddress: address, typeName: name, size: size,
                          alignmentAndFlags: alignment, stride: stride, extraInhabitantCount: extra), 20)
        }
    }

    func parseMultiPayloadEnums() -> [SwiftMultiPayloadEnumRecord] { parseMultiPayloadEnumsReport().records }

    func parseMultiPayloadEnumsReport() -> (records: [SwiftMultiPayloadEnumRecord], diagnostics: [MetadataParseDiagnostic]) {
        reflectionRecords(in: "__swift5_mpenum") { address, remaining in
            guard remaining >= 8, let sizeFlags = readU32(atVA: address + 4) else { return (nil, nil) }
            let words = sizeFlags >> 16
            guard words > 0, words <= Limits.maxFieldsPerType else { return (nil, nil) }
            let length = 4 + UInt64(words) * 4
            guard length <= remaining, reflectionRangeIsReadable(address, length) else { return (nil, nil) }
            var maskBytes: UInt32 = 0
            if sizeFlags & 1 != 0 {
                guard words >= 2, let maskInfo = readU32(atVA: address + 8) else { return (nil, length) }
                maskBytes = maskInfo & 0xffff
                guard UInt64(words) >= 2 + (UInt64(maskBytes) + 3) / 4 else { return (nil, length) }
            }
            guard let name = reflectionName(at: address) else { return (nil, length) }
            return (.init(descriptorAddress: address, typeName: name, maskByteCount: maskBytes), length)
        }
    }

    /// The pinned reflection ABI uses variable-sized capture, associated-type and enum records.
    /// A corrupt size abandons the section because its next record boundary is unknown.
    private func reflectionRecords<Record>(in sectionName: String,
        read: (UInt64, UInt64) -> (Record?, UInt64?)
    ) -> (records: [Record], diagnostics: [MetadataParseDiagnostic]) {
        var records: [Record] = []
        var diagnostics: [MetadataParseDiagnostic] = []
        for section in sections where section.name == sectionName {
            guard section.address <= UInt64.max - section.size else {
                diagnostics.append(.init(grade: .abandonedList, address: section.address,
                                         message: "Overflowing \(sectionName) section range"))
                continue
            }
            var offset: UInt64 = 0
            var count = 0
            while offset < section.size {
                let address = section.address + offset
                guard count < Limits.maxTypes else {
                    diagnostics.append(.init(grade: .walkCapped, address: address,
                                             message: "\(sectionName) record count reached Limits.maxTypes"))
                    break
                }
                let (record, length) = read(address, section.size - offset)
                if let record { records.append(record) }
                else {
                    diagnostics.append(.init(grade: length == nil ? .abandonedList : .skippedItem,
                                             address: address,
                                             message: "Unreadable, truncated or capped \(sectionName) record"))
                }
                guard let length, length > 0, length <= section.size - offset else { break }
                offset += length
                count += 1
            }
        }
        return (records, diagnostics)
    }

    private func reflectionRangeIsReadable(_ address: UInt64, _ length: UInt64) -> Bool {
        guard length > 0, address <= UInt64.max - (length - 1),
              let section = sections.first(where: { section in
                  !section.isZeroFill && address >= section.address && address - section.address < section.size
              }), length <= section.size - (address - section.address),
              let offset = fileOffset(forVA: address), offset >= 0, offset <= bytes.count,
              length <= UInt64(bytes.count - offset) else { return false }
        return true
    }

    private func reflectionName(at slot: UInt64, decodeType: Bool = true) -> String? {
        guard let address = resolveRelativePointer(at: slot),
              let raw = readMangledBytes(atVA: address, requiresTerminator: true), !raw.isEmpty,
              reflectionRangeIsReadable(address, UInt64(raw.count) + 1) else { return nil }
        if decodeType {
            var diagnostics: [MetadataParseDiagnostic] = []
            let decoded = decodeFieldType(at: address, diagnostics: &diagnostics)
            if let name = decoded.typeName { return name }
        }
        return sanitizedMangled(raw)
    }
}
