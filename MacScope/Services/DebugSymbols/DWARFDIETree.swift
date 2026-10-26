//===----------------------------------------------------------------------===//
//
// This source file is part of the MacScope project.
//
// Copyright (c) 2026-present MacScope authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// This file defines a lightweight reader for the DWARF Debug Information
// Entries (DIE) tree. It reconstructs the parent/child nesting of DIEs
// (compile units, subprograms, formal parameters, etc.) and surfaces the
// attributes of each entry through a flexible `AttributeValue` enum. Like the
// function‑name reader, this parser is conservative: it only interprets
// supported forms, bounds‑checks every read, and degrades gracefully on
// malformed input. Unknown forms or abbreviations cause the current unit
// to be skipped rather than risking misalignment.
//
//===----------------------------------------------------------------------===//

import Foundation

/// Represents a Debug Information Entry (DIE) in the DWARF tree. Each node
/// carries its DWARF tag, a dictionary of attributes keyed by DW_AT values,
/// its CU-relative byte offset, and its child DIEs. The tree reflects the
/// lexical nesting of the source.
struct DWARFDIENode: Hashable, Sendable {
    var tag: UInt64
    var attributes: [UInt64: DWARFAttributeValue]
    var cuOffset: Int?
    var children: [DWARFDIENode]
}

/// The decoded value of a DWARF attribute. Only a subset of forms is
/// represented here; unknown or unsupported forms result in `.uint` with the
/// raw integer bytes or are skipped entirely. String and address values are
/// resolved eagerly when possible.
enum DWARFAttributeValue: Hashable, Sendable {
    case string(String)
    case address(UInt64)
    case uint(UInt64)
    case sint(Int64)
    case addrIndex(UInt64)
    case strIndex(UInt64)
    case skipped
}

/// Builds a DIE tree from raw DWARF sections. Each call to `parse()` reads
/// every compilation unit in `.debug_info`, decodes the abbreviation tables
/// from `.debug_abbrev`, and walks the DIE tree to produce a root node per
/// compilation unit. Malformed units are skipped entirely; no partial trees
/// are emitted.
struct DWARFDIETree {
    private let sections: DWARFReader.Sections

    init(sections: DWARFReader.Sections) {
        self.sections = sections
    }

    /// Parses all compilation units and returns their root DIE nodes. Each
    /// returned node represents a compile unit (`DW_TAG_compile_unit`) and
    /// contains its nested subprograms, parameters, and other entries.
    func parse() -> [DWARFDIENode] {
        var result: [DWARFDIENode] = []
        guard !sections.debugInfo.isEmpty, !sections.debugAbbrev.isEmpty else { return result }
        let info = TreeByteCursor(sections.debugInfo)
        while info.remaining > 0 {
            let unitStart = info.offset
            guard let unit = try? parseCompilationUnit(info) else { break }
            // Always advance past the unit even if the DIE walk throws.
            defer { info.seek(to: unit.nextUnitOffset) }
            guard unit.nextUnitOffset > unitStart else { break }
            do {
                if let root = try walkUnit(unit) {
                    result.append(root)
                }
            } catch {
                // Skip malformed units silently.
                continue
            }
        }
        return result
    }

    // MARK: - Compilation unit parsing

    /// A compilation unit header, mirroring DWARFReader.CompilationUnit but
    /// defined locally to avoid exposing internals. The nextUnitOffset
    /// identifies where this unit ends in .debug_info.
    private struct CompilationUnit {
        var version: UInt16
        var addressSize: UInt8
        var abbrevOffset: UInt64
        var unitStartOffset: Int
        var firstDIEOffset: Int
        var nextUnitOffset: Int
        var strOffsetsBase: UInt64
        var addrBase: UInt64
    }

    /// Parses one compilation unit header starting at the cursor's current
    /// position. Returns nil if there are not enough bytes even for the
    /// length field. Throws on malformed units (e.g. truncated lengths).
    private func parseCompilationUnit(_ cursor: TreeByteCursor) throws -> CompilationUnit? {
        guard cursor.remaining >= 4 else { return nil }
        let headerStart = cursor.offset
        let initialLength = try cursor.readU32()
        // Reject 64‑bit DWARF (0xffffffff escape) explicitly.
        if initialLength == 0xffff_ffff { throw ParseError.malformed("64‑bit DWARF unit length is unsupported") }
        let unitLength = Int(initialLength)
        let nextUnitOffset = cursor.offset + unitLength
        guard unitLength > 0, nextUnitOffset <= cursor.count else {
            throw ParseError.malformed("compilation unit length runs past .debug_info")
        }
        let version = try cursor.readU16()
        let addressSize: UInt8
        let abbrevOffset: UInt64
        if version >= 5 {
            // version, unit_type (ignored), address_size, debug_abbrev_offset
            _ = try cursor.readU8() // unit_type
            addressSize = try cursor.readU8()
            abbrevOffset = UInt64(try cursor.readU32())
        } else {
            // version, debug_abbrev_offset, address_size
            abbrevOffset = UInt64(try cursor.readU32())
            addressSize = try cursor.readU8()
        }
        guard addressSize == 4 || addressSize == 8 else {
            throw ParseError.malformed("unsupported address size \(addressSize)")
        }
        _ = headerStart
        return CompilationUnit(
            version: version,
            addressSize: addressSize,
            abbrevOffset: abbrevOffset,
            unitStartOffset: headerStart,
            firstDIEOffset: cursor.offset,
            nextUnitOffset: nextUnitOffset,
            strOffsetsBase: 8,
            addrBase: 8
        )
    }

    // MARK: - DIE walk

    /// Walks the DIE tree of a compilation unit and returns the root node.
    /// A null return indicates that no DIEs were recovered for the unit. Any
    /// malformed abbreviation or attribute causes this unit to be skipped.
    private func walkUnit(_ unit: CompilationUnit) throws -> DWARFDIENode? {
        // Parse the abbreviation table referenced by this unit.
        let abbrevTable = try parseAbbrevTable(at: unit.abbrevOffset)
        var unit = unit
        let info = TreeByteCursor(sections.debugInfo, endOffset: unit.nextUnitOffset)
        info.seek(to: unit.firstDIEOffset)
        var stack: [DWARFDIENode] = []
        var rootNode: DWARFDIENode?
        var guardCounter = 0
        let maxDIEs = sections.debugInfo.count + 1
        while info.offset < unit.nextUnitOffset {
            guardCounter += 1
            if guardCounter > maxDIEs { throw ParseError.malformed("DIE walk exceeded the entry-count cap") }
            let dieCUOffset = info.offset - unit.unitStartOffset
            let code = try info.readULEB128()
            if code == 0 {
                // Null entry: end of children for the current parent. Pop one
                // level off the stack.
                if stack.isEmpty { continue }
                let completed = stack.removeLast()
                if stack.isEmpty {
                    // This was a root-level DIE. If no root is recorded, set
                    // it; otherwise, append as sibling of the root.
                    if rootNode == nil {
                        rootNode = completed
                    } else {
                        rootNode?.children.append(completed)
                    }
                } else {
                    var parent = stack.removeLast()
                    parent.children.append(completed)
                    stack.append(parent)
                }
                continue
            }
            guard let abbrev = abbrevTable[code] else {
                throw ParseError.malformed("DIE references undefined abbreviation code \(code)")
            }
            var attributes: [UInt64: DWARFAttributeValue] = [:]
            // Decode the whole DIE before resolving indexed values: a CU's
            // str_offsets_base/addr_base may follow its name or low_pc in the
            // abbreviation. Keep indexes raw until both bases are available.
            for attribute in abbrev.attributes {
                let value = try readAttributeValue(attribute, cursor: info, unit: unit)
                if attribute.attribute == DWARFConstants.atStrOffsetsBase {
                    if case let .uint(base) = value { unit.strOffsetsBase = base }
                } else if attribute.attribute == DWARFConstants.atAddrBase {
                    if case let .uint(base) = value { unit.addrBase = base }
                }
                if value != .skipped {
                    attributes[attribute.attribute] = value
                }
            }
            for (attribute, value) in attributes {
                switch value {
                case .addrIndex(let index):
                    if let address = resolveAddress(index: index, base: unit.addrBase) {
                        attributes[attribute] = .address(address)
                    }
                case .strIndex(let index):
                    if let string = stringFromStrIndex(index, base: unit.strOffsetsBase) {
                        attributes[attribute] = .string(string)
                    }
                default:
                    break
                }
            }
            let node = DWARFDIENode(tag: abbrev.tag, attributes: attributes, cuOffset: dieCUOffset, children: [])
            if stack.isEmpty {
                // Top‑level DIE. If it has children we push it; else we set
                // rootNode immediately.
                if abbrev.hasChildren {
                    stack.append(node)
                } else {
                    if rootNode == nil {
                        rootNode = node
                    } else {
                        rootNode?.children.append(node)
                    }
                }
            } else {
                if abbrev.hasChildren {
                    // Push the new node onto the stack so its children are
                    // collected until we see a null entry; it is attached to
                    // its parent when that null entry pops it.
                    stack.append(node)
                } else {
                    // Leaf DIE: attach to the current parent immediately.
                    var parent = stack.removeLast()
                    parent.children.append(node)
                    stack.append(parent)
                }
            }
        }
        return rootNode
    }

    // MARK: - Abbreviation table

    /// An abbreviation entry describes the tag and attributes of a DIE.
    private struct Abbreviation {
        var tag: UInt64
        var hasChildren: Bool
        var attributes: [AbbrevAttribute]
    }
    private struct AbbrevAttribute {
        var attribute: UInt64
        var form: UInt64
        var implicitConst: Int64?
    }

    /// Parses the abbreviation table starting at the given offset in
    /// `.debug_abbrev`. Returns a dictionary keyed by abbrev code. Throws on
    /// malformed tables.
    private func parseAbbrevTable(at offset: UInt64) throws -> [UInt64: Abbreviation] {
        let cursor = TreeByteCursor(sections.debugAbbrev)
        guard offset <= UInt64(cursor.count) else {
            throw ParseError.malformed("abbrev offset runs past .debug_abbrev")
        }
        cursor.seek(to: Int(offset))
        var table: [UInt64: Abbreviation] = [:]
        while cursor.remaining > 0 {
            let code = try cursor.readULEB128()
            if code == 0 { break }
            let tag = try cursor.readULEB128()
            let hasChildren = try cursor.readU8() != 0
            var attributes: [AbbrevAttribute] = []
            while true {
                let attr = try cursor.readULEB128()
                let form = try cursor.readULEB128()
                if attr == 0 && form == 0 { break }
                var implicitConst: Int64?
                if form == DWARFConstants.formImplicitConst {
                    implicitConst = try cursor.readSLEB128()
                }
                attributes.append(AbbrevAttribute(attribute: attr, form: form, implicitConst: implicitConst))
            }
            table[code] = Abbreviation(tag: tag, hasChildren: hasChildren, attributes: attributes)
        }
        return table
    }

    // MARK: - Attribute decoding

    /// Reads a single attribute value according to its form. Advances the
    /// cursor by exactly the size of the encoded form. Unsupported forms
    /// throw, so the caller can skip the entire unit. The semantics mirror
    /// DWARFReader.readAttributeValue but produce our own DWARFAttributeValue.
    private func readAttributeValue(
        _ attribute: AbbrevAttribute,
        cursor: TreeByteCursor,
        unit: CompilationUnit
    ) throws -> DWARFAttributeValue {
        // Every indirect form consumes a bounded ULEB. Iteration preserves
        // nested forms without giving untrusted bytes control of stack depth.
        var attribute = attribute
        while attribute.form == DWARFConstants.formIndirect {
            attribute = AbbrevAttribute(
                attribute: attribute.attribute,
                form: try cursor.readULEB128(),
                implicitConst: attribute.implicitConst
            )
        }
        switch attribute.form {
        case DWARFConstants.formAddr:
            let value = unit.addressSize == 8 ? try cursor.readU64() : UInt64(try cursor.readU32())
            return .address(value)
        case DWARFConstants.formData1, DWARFConstants.formFlag, DWARFConstants.formStrx1, DWARFConstants.formAddrx1, DWARFConstants.formRef1:
            let value = UInt64(try cursor.readU8())
            return classifyIndexed(form: attribute.form, value: value)
        case DWARFConstants.formData2, DWARFConstants.formStrx2, DWARFConstants.formAddrx2, DWARFConstants.formRef2:
            let value = UInt64(try cursor.readU16())
            return classifyIndexed(form: attribute.form, value: value)
        case DWARFConstants.formStrx3, DWARFConstants.formAddrx3:
            let value = try cursor.readU24()
            return classifyIndexed(form: attribute.form, value: value)
        case DWARFConstants.formData4, DWARFConstants.formRef4, DWARFConstants.formStrx4, DWARFConstants.formAddrx4, DWARFConstants.formSecOffset:
            let value = UInt64(try cursor.readU32())
            return classifyIndexed(form: attribute.form, value: value)
        case DWARFConstants.formData8, DWARFConstants.formRef8, DWARFConstants.formRefSig8:
            let value = try cursor.readU64()
            return .uint(value)
        case DWARFConstants.formData16:
            try cursor.skip(16)
            return .skipped
        case DWARFConstants.formSData:
            let v = try cursor.readSLEB128()
            return .sint(v)
        case DWARFConstants.formUData, DWARFConstants.formRefUData:
            let value = try cursor.readULEB128()
            return .uint(value)
        case DWARFConstants.formStrx, DWARFConstants.formAddrx:
            let index = try cursor.readULEB128()
            return classifyIndexed(form: attribute.form, value: index)
        case DWARFConstants.formString:
            let str = try cursor.readCString()
            return .string(str)
        case DWARFConstants.formStrp, DWARFConstants.formLineStrp:
            let offset = UInt64(try cursor.readU32())
            if attribute.form == DWARFConstants.formStrp {
                return .string(stringFromDebugStr(offset: offset))
            }
            return .skipped
        case DWARFConstants.formFlagPresent:
            return .uint(1)
        case DWARFConstants.formImplicitConst:
            return .sint(attribute.implicitConst ?? 0)
        case DWARFConstants.formExprLoc, DWARFConstants.formBlock:
            let length = try cursor.readULEB128()
            if length > UInt64(Int.max) { throw ParseError.malformed("block/exprloc length overflow") }
            try cursor.skip(Int(length))
            return .skipped
        case DWARFConstants.formBlock1:
            let length = UInt64(try cursor.readU8())
            try cursor.skip(Int(length))
            return .skipped
        case DWARFConstants.formBlock2:
            let length = UInt64(try cursor.readU16())
            try cursor.skip(Int(length))
            return .skipped
        case DWARFConstants.formBlock4:
            let length = UInt64(try cursor.readU32())
            try cursor.skip(Int(length))
            return .skipped
        case DWARFConstants.formRefAddr:
            try cursor.skip(4)
            return .skipped
        case DWARFConstants.formLoclistx, DWARFConstants.formRnglistx:
            _ = try cursor.readULEB128()
            return .skipped
        default:
            throw ParseError.malformed("unsupported DWARF form 0x\(String(attribute.form, radix: 16))")
        }
    }

    /// Classifies an integer value according to its form: returns an
    /// address index, string index, or raw unsigned integer.
    private func classifyIndexed(form: UInt64, value: UInt64) -> DWARFAttributeValue {
        switch form {
        case DWARFConstants.formAddrx, DWARFConstants.formAddrx1, DWARFConstants.formAddrx2,
             DWARFConstants.formAddrx3, DWARFConstants.formAddrx4:
            return .addrIndex(value)
        case DWARFConstants.formStrx, DWARFConstants.formStrx1, DWARFConstants.formStrx2,
             DWARFConstants.formStrx3, DWARFConstants.formStrx4:
            return .strIndex(value)
        default:
            return .uint(value)
        }
    }

    // MARK: - String / address resolution

    /// Resolves a `.debug_str` offset to a NUL‑terminated string. Returns an empty string
    /// when the offset is out of range. This implementation
    /// reads directly from the `debugStr` data rather than relying on
    /// `LittleEndianReader` so that the parser remains self‑contained.
    private func stringFromDebugStr(offset: UInt64) -> String {
        let bytes = [UInt8](sections.debugStr)
        guard offset < UInt64(bytes.count) else { return "" }
        var idx = Int(offset)
        var scalars: [UInt8] = []
        while idx < bytes.count {
            let byte = bytes[idx]
            if byte == 0 { break }
            scalars.append(byte)
            idx += 1
        }
        return String(decoding: scalars, as: UTF8.self)
    }
    /// Resolves a `DW_FORM_strx` index through `.debug_str_offsets` to a
    /// `.debug_str` offset, then to a string. Returns nil when either table
    /// is missing or the index is out of range.
    private func stringFromStrIndex(_ index: UInt64, base: UInt64) -> String? {
        guard !sections.debugStrOffsets.isEmpty else { return nil }
        let (product, mulOverflow) = index.multipliedReportingOverflow(by: 4)
        guard !mulOverflow else { return nil }
        let (entryOffset, addOverflow) = base.addingReportingOverflow(product)
        let (end, endOverflow) = entryOffset.addingReportingOverflow(4)
        guard !addOverflow, !endOverflow, end <= UInt64(sections.debugStrOffsets.count) else { return nil }
        let cursor = TreeByteCursor(sections.debugStrOffsets)
        cursor.seek(to: Int(entryOffset))
        guard let strOffset = try? cursor.readU32() else { return nil }
        return stringFromDebugStr(offset: UInt64(strOffset))
    }
    /// Resolves a `DW_FORM_addrx` index through `.debug_addr` to an 8‑byte
    /// address. Returns nil when the table is missing or the index is out of range.
    private func resolveAddress(index: UInt64, base: UInt64) -> UInt64? {
        guard !sections.debugAddr.isEmpty else { return nil }
        let (product, mulOverflow) = index.multipliedReportingOverflow(by: 8)
        guard !mulOverflow else { return nil }
        let (entryOffset, addOverflow) = base.addingReportingOverflow(product)
        let (end, endOverflow) = entryOffset.addingReportingOverflow(8)
        guard !addOverflow, !endOverflow, end <= UInt64(sections.debugAddr.count) else { return nil }
        let cursor = TreeByteCursor(sections.debugAddr)
        cursor.seek(to: Int(entryOffset))
        return try? cursor.readU64()
    }

    // MARK: - Parse errors and cursor

    /// Sentinel error type used internally to signal malformed input.
    private enum ParseError: Swift.Error {
        case malformed(String)
    }

    /// A forward cursor over a byte slice, with little‑endian primitive reads and
    /// LEB128 decoders. Identical to DWARFReader.ByteCursor but defined here
    /// independently to avoid any reliance on its visibility. Methods throw
    /// ParseError when reads go out of bounds.
    private final class TreeByteCursor {
        private let bytes: [UInt8]
        private let endOffset: Int
        fileprivate private(set) var offset: Int
        fileprivate init(_ data: Data, endOffset: Int? = nil) {
            self.bytes = [UInt8](data)
            self.endOffset = max(0, min(endOffset ?? data.count, data.count))
            self.offset = 0
        }
        fileprivate var count: Int { endOffset }
        fileprivate var remaining: Int { endOffset - offset }
        fileprivate func seek(to newOffset: Int) { offset = max(0, min(newOffset, endOffset)) }
        fileprivate func skip(_ length: Int) throws {
            guard length >= 0, length <= remaining else {
                throw ParseError.malformed("read past end of section")
            }
            offset += length
        }
        fileprivate func readU8() throws -> UInt8 {
            guard remaining >= 1 else { throw ParseError.malformed("u8 past end") }
            defer { offset += 1 }
            return bytes[offset]
        }
        fileprivate func readU16() throws -> UInt16 {
            guard remaining >= 2 else { throw ParseError.malformed("u16 past end") }
            defer { offset += 2 }
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        fileprivate func readU24() throws -> UInt64 {
            guard remaining >= 3 else { throw ParseError.malformed("u24 past end") }
            defer { offset += 3 }
            return UInt64(bytes[offset]) | (UInt64(bytes[offset + 1]) << 8) | (UInt64(bytes[offset + 2]) << 16)
        }
        fileprivate func readU32() throws -> UInt32 {
            guard remaining >= 4 else { throw ParseError.malformed("u32 past end") }
            defer { offset += 4 }
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(bytes[offset + i]) << (8 * i) }
            return value
        }
        fileprivate func readU64() throws -> UInt64 {
            guard remaining >= 8 else { throw ParseError.malformed("u64 past end") }
            defer { offset += 8 }
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (8 * i) }
            return value
        }
        fileprivate func readCString() throws -> String {
            var scalars: [UInt8] = []
            while offset < endOffset {
                let byte = bytes[offset]
                offset += 1
                if byte == 0 { return String(decoding: scalars, as: UTF8.self) }
                scalars.append(byte)
            }
            throw ParseError.malformed("unterminated string")
        }
        fileprivate func readULEB128() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let byte = try readU8()
                let payload = byte & 0x7f
                if (shift == 63 && payload > 1) || (shift > 63 && payload != 0) {
                    throw ParseError.malformed("ULEB128 value exceeds UInt64")
                }
                if shift < 64 { result |= UInt64(payload) << shift }
                if byte & 0x80 == 0 { break }
                shift += 7
                if shift > 70 { throw ParseError.malformed("ULEB128 too long") }
            }
            return result
        }
        fileprivate func readSLEB128() throws -> Int64 {
            var result: Int64 = 0
            var shift: UInt64 = 0
            var byte: UInt8 = 0
            repeat {
                byte = try readU8()
                let payload = byte & 0x7f
                if shift == 63 && payload != 0 && payload != 0x7f {
                    throw ParseError.malformed("SLEB128 value exceeds Int64")
                }
                if shift < 64 { result |= Int64(payload) << shift }
                shift += 7
                if shift > 70 { throw ParseError.malformed("SLEB128 too long") }
            } while byte & 0x80 != 0
            if shift < 64, byte & 0x40 != 0 { result |= -(Int64(1) << shift) }
            return result
        }
    }
}
