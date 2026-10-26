//===----------------------------------------------------------------------===//
//
// This source file is part of the MacScope project.
//
// Copyright (c) 2026-present MacScope authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// This file defines a decoder for the DWARF line number program. Given raw
// `.debug_line` bytes (plus the companion string tables), it interprets the
// line‑number program state machine and produces a sequence of `LineRow`
// records. Each row describes a mapping from a machine instruction address to
// source coordinate information. See DWARF v2–v5 §6.2 for the line program
// specification. The implementation here is careful to bound‑check all reads
// and to degrade cleanly on malformed data — it never traps and it never
// guesses values. Unsupported or truncated units simply stop decoding.
//
//===----------------------------------------------------------------------===//

import Foundation

/// Recovery bounds for the DWARF v5 line-table directory/file loops, whose entry
/// counts are attacker-controlled ULEB128 values. These cap the count before any
/// iteration; a per-iteration forward-progress guard handles zero-width entries.
private enum DWARFLineRecoveryLimits {
    static let maximumDirectoryEntries: UInt64 = 100_000
    static let maximumFileEntries: UInt64 = 100_000
}

/// A single row in a DWARF line number program. Each row records the state
/// machine registers at the moment a row is emitted (either by a `DW_LNS_copy`,
/// a special opcode, or an `DW_LNE_end_sequence`). The importer can use these
/// rows to map instruction addresses to source file/line locations.
public struct LineRow: Hashable, Sendable {
    /// The instruction address corresponding to this row.
    public var address: UInt64
    /// The file index, as maintained by the line number program. The value is
    /// whatever the machine's `file` register holds; the caller should treat
    /// it as an index into the file table described by the line program
    /// header. Line-table file indexes are 1-based for DWARF v2–v4 and 0-based for DWARF v5;
    /// this is the line-machine register value, not a basename-derived surrogate.
    public var fileIndex: UInt64
    /// The source line number.
    public var line: UInt64
    /// The source column number.
    public var column: UInt64
    /// Whether this row marks a statement boundary (`is_stmt` register).
    public var isStmt: Bool
    /// Whether this row ends a sequence (`DW_LNE_end_sequence`). When true
    /// the consumer should start a new basic block at the next row.
    public var endSequence: Bool
    /// The exact source path represented by the line-table file and directory entries. This is
    /// never standardized or remapped through the current machine. It is nil when the table did
    /// not carry valid UTF-8 evidence. Defaulted so existing construction sites are unaffected.
    public var file: String? = nil
    /// Byte offset of this line-program unit within `.debug_line`, including its initial-length
    /// field. This distinguishes compilation units whose rows otherwise share file/line/address.
    public var lineProgramUnitOffset: UInt64 = 0
    /// The version-correct file-table index. DWARF v5 indexes the table from zero; v2–v4 indexes
    /// it from one. Values outside the durable UInt32 domain remain displayable but ineligible for
    /// source-breakpoint authority.
    public var fileTableIndex: UInt32? = nil
    /// Exact path identity retained from the line table. Relative paths are relative to the
    /// compilation directory described by DWARF, not to the importing Mac's filesystem.
    var canonicalTablePath: DebuggerCanonicalSourceTablePath? = nil
}

/// A decoder for the DWARF line number program. Constructed with the raw
/// `.debug_line` section plus the companion `.debug_line_str` and `.debug_str`
/// sections, its `decode()` method returns the complete set of `LineRow` records
/// recovered from all units in the section. Truncated or malformed units are
/// skipped; unsupported features (64‑bit DWARF) are ignored.
public struct DWARFLineProgram {
    private let debugLine: Data
    private let debugLineStr: Data
    private let debugStr: Data

    /// Initializes a new line program decoder. The supplied `line` data is
    /// the content of the `__debug_line` section. The other sections are
    /// optional and may be empty; they are only consulted when resolving
    /// `DW_FORM_line_strp` or `DW_FORM_strp` entries in DWARF v5 headers.
    public init(
        debugLine: Data,
        debugLineStr: Data = Data(),
        debugStr: Data = Data()
    ) {
        self.debugLine = debugLine
        self.debugLineStr = debugLineStr
        self.debugStr = debugStr
    }

    /// Decodes every line number program unit in `debugLine` and returns the
    /// emitted rows. A malformed unit causes decoding to stop at its boundary
    /// but does not prevent decoding of subsequent units. An empty result
    /// indicates either an empty section or that all units were malformed.
    public func decode() -> [LineRow] {
        var rows: [LineRow] = []
        guard !debugLine.isEmpty else { return rows }
        let cursor = DWARFByteCursor(debugLine)
        // Walk each unit sequentially. Each unit is length‑prefixed and
        // independent of the others.
        while cursor.remaining >= 4 {
            let unitStart = cursor.offset
            // Read the 32‑bit unit length (the number of bytes after this field).
            guard let initialLength = try? cursor.readU32() else { break }
            // Reject 64‑bit DWARF units (0xffffffff escape) explicitly.
            if initialLength == 0xffff_ffff { break }
            let unitLength = Int(initialLength)
            // Ensure the declared unit fits inside the section.
            let unitEndOffset = cursor.offset + unitLength
            if unitLength <= 0 || unitEndOffset > cursor.count { break }
            // Parse this unit in a do/catch so a malformed unit does not
            // propagate failure to subsequent units.
            do {
                try decodeUnit(
                    cursor: cursor,
                    endOffset: unitEndOffset,
                    unitOffset: UInt64(unitStart),
                    into: &rows
                )
            } catch {
                // On any error, seek to the end of this unit and continue.
            }
            // Move to the next unit.
            cursor.seek(to: unitEndOffset)
            // Guard against infinite loops on zero‑length units.
            if unitEndOffset <= unitStart { break }
        }
        return rows
    }

    private struct ResolvedFileEvidence {
        let path: String
        let tablePath: DebuggerCanonicalSourceTablePath
        let tableIndex: UInt32
    }

    /// Resolves a `file` register to exact file-table evidence. DWARF v5 file and directory
    /// indexes are zero-based; v2–v4 file indexes are one-based and directory index zero denotes
    /// the compilation directory. Path components are joined without Unicode normalization,
    /// symlink resolution, `standardizingPath`, or current-machine filesystem consultation.
    private func resolveFileEvidence(
        _ fileIndex: UInt64,
        version: UInt16,
        directories: [String],
        fileNames: [(name: String, dirIndex: UInt64)]
    ) -> ResolvedFileEvidence? {
        let idx: Int
        if version >= 5 {
            guard let exact = Int(exactly: fileIndex) else { return nil }
            idx = exact
        } else {
            guard fileIndex >= 1 else { return nil }
            guard let exact = Int(exactly: fileIndex - 1) else { return nil }
            idx = exact
        }
        guard idx >= 0, idx < fileNames.count,
              let tableIndex = UInt32(exactly: fileIndex) else { return nil }
        let file = fileNames[idx]
        guard !file.name.isEmpty else { return nil }

        let path: String
        if file.name.utf8.first == 0x2f {
            path = file.name
        } else if let directory = directory(
            at: file.dirIndex,
            version: version,
            directories: directories
        ), !directory.isEmpty {
            path = directory.hasSuffix("/") ? directory + file.name : directory + "/" + file.name
        } else {
            path = file.name
        }
        guard !path.isEmpty else { return nil }
        let tablePath: DebuggerCanonicalSourceTablePath = path.utf8.first == 0x2f
            ? .absoluteUTF8(path)
            : .compilationDirectoryRelativeUTF8(path)
        return ResolvedFileEvidence(path: path, tablePath: tablePath, tableIndex: tableIndex)
    }

    private func directory(
        at directoryIndex: UInt64,
        version: UInt16,
        directories: [String]
    ) -> String? {
        if version >= 5 {
            guard let index = Int(exactly: directoryIndex), directories.indices.contains(index) else {
                return nil
            }
            return directories[index]
        }
        guard directoryIndex > 0,
              let index = Int(exactly: directoryIndex - 1),
              directories.indices.contains(index) else { return nil }
        return directories[index]
    }

    /// Decodes a single line number program unit starting at the current
    /// `cursor.offset` and ending just before `endOffset`. Appends all
    /// emitted rows to `rows`. Throws on malformed input (consumed at caller).
    private func decodeUnit(
        cursor: DWARFByteCursor,
        endOffset: Int,
        unitOffset: UInt64,
        into rows: inout [LineRow]
    ) throws {
        // A unit may not use the following unit's bytes to finish an operand.
        // The outer section cursor is advanced independently after this walk.
        let cursor = try cursor.bounded(to: endOffset)
        // At this point the initial length field has been consumed. The next
        // fields are: version (2 bytes), and depending on version other
        // fields. We must remember the default_is_stmt for each unit.
        guard cursor.remaining >= 2 else { return }
        let version = try cursor.readU16()
        // Only DWARF v2–v5 are supported. Unknown versions are skipped.
        guard version >= 2 && version <= 5 else { return }
        // Fields that differ by version.
        var addressSize: UInt8 = 4
        var segmentSelectorSize: UInt8 = 0
        // The length of the header, excluding the unit_length, version and
        // (for v5) address/segment fields, AND the header_length field itself.
        // For DWARF32 the header_length is 4 bytes; DWARF64 is rejected above.
        var headerLength: UInt32 = 0
        if version >= 5 {
            // DWARF v5 header fields: address_size (u8), segment_selector_size (u8), header_length (u32)
            addressSize = try cursor.readU8()
            segmentSelectorSize = try cursor.readU8()
            headerLength = try cursor.readU32()
            // Non‑zero segment selector sizes are unsupported — skip the unit.
            if segmentSelectorSize != 0 { return }
        } else {
            // DWARF v2–v4 header fields: header_length (u32). The address size is
            // implicit; line number opcodes work on addresses that have been
            // relocated into absolute virtual addresses by the producer, so we
            // treat them as 4 or 8 bytes depending on the target ISA. Apple
            // arm64 dSYMs emit 8‑byte addresses, so default to 8 here.
            headerLength = try cursor.readU32()
            addressSize = 8
        }
        // Calculate the offset in the stream where the header ends — i.e. the
        // first opcode. `header_length` counts the bytes that follow it, so the
        // first opcode is at (position just after header_length) + header_length.
        let headerEnd = cursor.offset + Int(headerLength)
        if headerEnd > endOffset { return }
        // Read the fixed header fields common to all versions (after the
        // version/address_size/segment_selector fields).
        guard cursor.remaining >= 1 else { return }
        let minimumInstructionLength = try cursor.readU8()
        // For v4 and later a maximum operations per instruction field is
        // present; for earlier versions it is implicitly 1.
        let maximumOperationsPerInstruction: UInt8
        if version >= 4 {
            maximumOperationsPerInstruction = try cursor.readU8()
        } else {
            maximumOperationsPerInstruction = 1
        }
        // default_is_stmt is a single byte (0 or non‑zero)
        let defaultIsStmtByte = try cursor.readU8()
        let defaultIsStmt = defaultIsStmtByte != 0
        // line_base is a signed int8
        let lineBase = Int8(bitPattern: try cursor.readU8())
        // line_range is an unsigned byte
        let lineRange = try cursor.readU8()
        // opcode_base is an unsigned byte
        let opcodeBase = try cursor.readU8()
        // A line_range of 0 would divide by zero in the special‑opcode math.
        guard lineRange != 0 else { return }
        // standard_opcode_lengths is an array of opcode_base‑1 bytes
        var standardOpcodeLengths: [UInt8] = []
        if opcodeBase > 1 {
            guard cursor.remaining >= Int(opcodeBase - 1) else { return }
            for _ in 0..<(Int(opcodeBase) - 1) {
                standardOpcodeLengths.append(try cursor.readU8())
            }
        }
        // Storage for the directory and file tables. We retain these in
        // memory only to correctly update file indices for DW_LNE_define_file
        // directives. The actual strings are not surfaced to the caller.
        var directories: [String] = []
        var fileNames: [(name: String, dirIndex: UInt64)] = []
        // Parse DWARF v5 directory and file table. The header describes the
        // formats of these tables using (content_type, form) pairs. The
        // directory table immediately follows standard_opcode_lengths for v5.
        if version >= 5 {
            // directory_entry_format_count is a single ubyte (DWARF v5 §6.2.4),
            // NOT a ULEB128. Same for file_name_entry_format_count below.
            let dirFormatCount = try cursor.readU8()
            var dirFormats: [(contentType: UInt64, form: UInt64)] = []
            for _ in 0..<dirFormatCount {
                let contentType = try cursor.readULEB128()
                let form = try cursor.readULEB128()
                dirFormats.append((contentType, form))
            }
            // Read number of directories, then parse that many entries.
            // The count is an attacker-controlled ULEB128 (up to ~2^64) and an
            // entry can consume zero bytes — empty formats, or skipForm's
            // "skip nothing" default for an unknown form — so an unbounded loop
            // could spin and exhaust memory without throwing. Cap the count,
            // reject a nonzero count with no formats, and require forward
            // progress on every iteration. These throws are contained by the
            // per-unit do/catch in decode().
            let dirCount = try cursor.readULEB128()
            guard dirCount <= DWARFLineRecoveryLimits.maximumDirectoryEntries else {
                throw DWARFByteCursor.Error.malformed("directory table entry count exceeds recovery limit")
            }
            guard dirCount == 0 || !dirFormats.isEmpty else {
                throw DWARFByteCursor.Error.malformed("nonzero directory count with no entry formats")
            }
            for _ in 0..<dirCount {
                let entryStart = cursor.offset
                var dirName: String = ""
                for (contentType, form) in dirFormats {
                    if contentType == 0x01 /* DW_LNCT_path */ {
                        if let str = try readFormString(form: form, cursor: cursor) {
                            dirName = str
                        } else {
                            // Skip unsupported forms.
                            try skipForm(form: form, cursor: cursor)
                        }
                    } else {
                        // Unknown content types are skipped using the form size.
                        try skipForm(form: form, cursor: cursor)
                    }
                }
                guard cursor.offset > entryStart, cursor.offset <= endOffset else {
                    throw DWARFByteCursor.Error.malformed("directory table entry made no progress")
                }
                directories.append(dirName)
            }
            // Read file name entry formats.
            let fileFormatCount = try cursor.readU8()
            var fileFormats: [(contentType: UInt64, form: UInt64)] = []
            for _ in 0..<fileFormatCount {
                let contentType = try cursor.readULEB128()
                let form = try cursor.readULEB128()
                fileFormats.append((contentType, form))
            }
            // Read number of file entries and parse them, under the same
            // recovery discipline as the directory table above.
            let fileCount = try cursor.readULEB128()
            guard fileCount <= DWARFLineRecoveryLimits.maximumFileEntries else {
                throw DWARFByteCursor.Error.malformed("file table entry count exceeds recovery limit")
            }
            guard fileCount == 0 || !fileFormats.isEmpty else {
                throw DWARFByteCursor.Error.malformed("nonzero file count with no entry formats")
            }
            for _ in 0..<fileCount {
                let entryStart = cursor.offset
                var fileName: String = ""
                var dirIndex: UInt64 = 0
                for (contentType, form) in fileFormats {
                    switch contentType {
                    case 0x01 /* DW_LNCT_path */:
                        if let str = try readFormString(form: form, cursor: cursor) {
                            fileName = str
                        } else {
                            try skipForm(form: form, cursor: cursor)
                        }
                    case 0x02 /* DW_LNCT_directory_index */:
                        // Directory indices are ULEB128 or fixed‑width integers.
                        if let idx = try readFormUint(form: form, cursor: cursor) {
                            dirIndex = idx
                        } else {
                            try skipForm(form: form, cursor: cursor)
                        }
                    default:
                        // Skip timestamp, size, MD5, etc.
                        try skipForm(form: form, cursor: cursor)
                    }
                }
                guard cursor.offset > entryStart, cursor.offset <= endOffset else {
                    throw DWARFByteCursor.Error.malformed("file table entry made no progress")
                }
                fileNames.append((fileName, dirIndex))
            }
        } else {
            // Parse DWARF v2–v4 directory table: a sequence of NUL‑terminated
            // strings terminated by an empty string.
            while true {
                guard let dir = try? cursor.readCString() else { return }
                if dir.isEmpty { break }
                directories.append(dir)
            }
            // Parse DWARF v2–v4 file table: each entry is (name, dirIndex,
            // timestamp, size) where name is a NUL‑terminated string. The table
            // ends with an empty name.
            while true {
                let name = try cursor.readCString()
                if name.isEmpty { break }
                let dirIdx = try cursor.readULEB128()
                _ = try cursor.readULEB128() // mod_time (unused)
                _ = try cursor.readULEB128() // file_length (unused)
                fileNames.append((name, dirIdx))
            }
        }
        // At this point we should be positioned at the first opcode. Ensure
        // cursor does not run past the declared header length.
        if cursor.offset > headerEnd { return }
        // Move the cursor to the end of the declared header. There may be
        // padding bytes that we skip over silently.
        if cursor.offset < headerEnd {
            let skipLen = headerEnd - cursor.offset
            try cursor.skip(skipLen)
        }
        // Initialize the state machine registers per Table 6.4 of the DWARF
        // standard. `file` defaults to 1 (1‑based) for both DWARF v2–v4 and
        // DWARF v5. `line` defaults to 1, `column` to 0, `address` to 0,
        // `is_stmt` to the header's default, and the rest to zero/false.
        var address: UInt64 = 0
        var opIndex: UInt64 = 0
        var fileReg: UInt64 = 1
        var line: UInt64 = 1
        var column: UInt64 = 0
        var isStmt: Bool = defaultIsStmt
        var basicBlock: Bool = false
        var endSequence: Bool = false
        var prologueEnd: Bool = false
        var epilogueBegin: Bool = false
        var isa: UInt64 = 0
        var discriminator: UInt64 = 0
        func row(endSequence: Bool) -> LineRow {
            let evidence = resolveFileEvidence(
                fileReg,
                version: version,
                directories: directories,
                fileNames: fileNames
            )
            return LineRow(
                address: address,
                fileIndex: fileReg,
                line: line,
                column: column,
                isStmt: isStmt,
                endSequence: endSequence,
                file: evidence?.path,
                lineProgramUnitOffset: unitOffset,
                fileTableIndex: evidence?.tableIndex,
                canonicalTablePath: evidence?.tablePath
            )
        }
        // Precompute divisors for address updates. Converting to UInt64
        // simplifies calculations and avoids repeated division by casting.
        // maximum_operations_per_instruction of 0 is malformed; clamp to 1 to
        // avoid a divide‑by‑zero in the VLIW address advance math.
        let maxOps = UInt64(max(maximumOperationsPerInstruction, 1))
        let minInstLen = UInt64(minimumInstructionLength)
        let lineRangeU64 = UInt64(lineRange)
        // An opcode operand can span the full ULEB128 domain. Reject arithmetic
        // that cannot represent the source location; neither a Swift trap nor a
        // wrapped low address is a valid recovery from malformed debug data.
        func advanceAddress(byOperations advance: UInt64) -> Bool {
            let totalOps = opIndex.addingReportingOverflow(advance)
            guard !totalOps.overflow else { return false }
            let displacement = (totalOps.partialValue / maxOps)
                .multipliedReportingOverflow(by: minInstLen)
            guard !displacement.overflow else { return false }
            let nextAddress = address.addingReportingOverflow(displacement.partialValue)
            guard !nextAddress.overflow else { return false }
            address = nextAddress.partialValue
            opIndex = totalOps.partialValue % maxOps
            return true
        }
        func advanceLine(by delta: Int64) -> Bool {
            let nextLine = Int64(bitPattern: line).addingReportingOverflow(delta)
            guard !nextLine.overflow else { return false }
            line = nextLine.partialValue < 0 ? 0 : UInt64(nextLine.partialValue)
            return true
        }
        // Process opcodes until we reach the end of this unit.
        while cursor.offset < endOffset {
            guard let opcodeByte = try? cursor.readU8() else { break }
            if opcodeByte == 0 {
                // Extended opcode. The next byte is the length of the
                // extended opcode data (excluding the length itself). If the
                // length is truncated or would run past the unit, we stop.
                guard let extLength = try? cursor.readULEB128(),
                      cursor.offset <= endOffset else { return }
                // extLength counts the bytes *after* this length field. If
                // extLength == 0 there is nothing to do.
                if extLength == 0 { continue }
                // The length is attacker-controlled: Int(UInt64) traps above
                // Int.max, and do/catch cannot contain a trap. A length that
                // does not fit the remaining section bytes is malformed — stop
                // decoding this unit. (Mirrors the DW_FORM_block guard below.)
                guard extLength <= UInt64(endOffset - cursor.offset) else { return }
                // Remember the position where this extended opcode should end.
                let extEnd = cursor.offset + Int(extLength)
                let extended = try cursor.bounded(to: extEnd)
                // Read the subopcode.
                let subOpcode = try extended.readU8()
                switch subOpcode {
                case 0x01: // DW_LNE_end_sequence
                    endSequence = true
                    // Emit a row marking the end of a sequence.
                    rows.append(row(endSequence: true))
                    // Reset the registers for the start of the next sequence.
                    address = 0
                    opIndex = 0
                    fileReg = 1
                    line = 1
                    column = 0
                    isStmt = defaultIsStmt
                    basicBlock = false
                    prologueEnd = false
                    epilogueBegin = false
                    isa = 0
                    discriminator = 0
                    endSequence = false
                case 0x02: // DW_LNE_set_address
                    // The address must fit inside this extended opcode. A
                    // truncated operand must not borrow the following opcode's
                    // bytes or fabricate an address of zero.
                    guard Int(addressSize) <= extended.remaining else { return }
                    let newAddr: UInt64
                    if addressSize == 8 {
                        newAddr = try extended.readU64()
                    } else if addressSize == 4 {
                        newAddr = UInt64(try extended.readU32())
                    } else {
                        return
                    }
                    address = newAddr
                    opIndex = 0
                case 0x03: // DW_LNE_define_file (v2–v4 only)
                    // New file definition appended to fileNames. Format:
                    // name: NUL‑terminated string, dir index: ULEB128,
                    // mod_time: ULEB128, file_length: ULEB128. Append to
                    // fileNames so that subsequent set_file opcodes can
                    // reference this entry.
                    let name = try extended.readCString()
                    let dirIdx = try extended.readULEB128()
                    _ = try extended.readULEB128() // mod_time
                    _ = try extended.readULEB128() // file_length
                    fileNames.append((name, dirIdx))
                default:
                    // Unknown extended opcode: skip the remaining bytes.
                    break
                }
                // Skip any bytes left over in the extended opcode, if any.
                cursor.seek(to: extEnd)
                continue
            }
            // Special opcode: opcodeBase defines the threshold. Opcode values
            // greater than or equal to opcodeBase encode both an address and
            // line increment. The operation advance is computed by dividing
            // the adjusted opcode by lineRange. The line increment is
            // lineBase + (adjusted % lineRange).
            if opcodeByte >= opcodeBase {
                let adjusted = UInt64(opcodeByte - opcodeBase)
                let opAdvance = adjusted / lineRangeU64
                let lineIncrement = Int64(lineBase) + Int64(adjusted % lineRangeU64)
                // Update address and opIndex according to DWARF v4+. The
                // algorithm accounts for the maximum operations per instruction.
                guard advanceAddress(byOperations: opAdvance),
                      advanceLine(by: lineIncrement) else { return }
                // Emit a row with endSequence=false.
                rows.append(row(endSequence: false))
                // Clear flags as specified.
                basicBlock = false
                prologueEnd = false
                epilogueBegin = false
                discriminator = 0
                continue
            }
            // Standard opcode (< opcodeBase). Handle known opcodes explicitly.
            switch opcodeByte {
            case 0x01: // DW_LNS_copy
                rows.append(row(endSequence: false))
                basicBlock = false
                prologueEnd = false
                epilogueBegin = false
                discriminator = 0
            case 0x02: // DW_LNS_advance_pc
                guard let opAdvance = try? cursor.readULEB128(),
                      cursor.offset <= endOffset,
                      advanceAddress(byOperations: opAdvance) else { return }
            case 0x03: // DW_LNS_advance_line
                guard let delta = try? cursor.readSLEB128(),
                      cursor.offset <= endOffset,
                      advanceLine(by: delta) else { return }
            case 0x04: // DW_LNS_set_file
                fileReg = try cursor.readULEB128()
            case 0x05: // DW_LNS_set_column
                column = try cursor.readULEB128()
            case 0x06: // DW_LNS_negate_stmt
                isStmt.toggle()
            case 0x07: // DW_LNS_set_basic_block
                basicBlock = true
            case 0x08: // DW_LNS_const_add_pc
                // Advance the address by the same amount as the largest special
                // opcode (255). The specification uses 255 (0xff) for this
                // calculation regardless of opcodeBase; see DWARF v4 §6.2.5.1.
                let adjusted = UInt64(255 - opcodeBase)
                let opAdvance = adjusted / lineRangeU64
                guard advanceAddress(byOperations: opAdvance) else { return }
            case 0x09: // DW_LNS_fixed_advance_pc
                // This opcode takes a 2‑byte uhalf operand and sets opIndex=0
                guard endOffset - cursor.offset >= 2,
                      let advance = try? cursor.readU16() else { return }
                let nextAddress = address.addingReportingOverflow(UInt64(advance))
                guard !nextAddress.overflow else { return }
                address = nextAddress.partialValue
                opIndex = 0
            case 0x0a: // DW_LNS_set_prologue_end
                prologueEnd = true
            case 0x0b: // DW_LNS_set_epilogue_begin
                epilogueBegin = true
            case 0x0c: // DW_LNS_set_isa
                isa = try cursor.readULEB128()
            default:
                // Unknown standard opcode: skip its operands according to
                // standardOpcodeLengths. Unrecognized opcodes prior to
                // opcodeBase are forward‑compatible. If there is no entry
                // for this opcode we have no choice but to skip nothing.
                let index = Int(opcodeByte) - 1
                if index < standardOpcodeLengths.count {
                    let operandCount = Int(standardOpcodeLengths[index])
                    for _ in 0..<operandCount {
                        _ = try cursor.readULEB128()
                    }
                }
            }
        }
        // Silence unused-variable warnings for registers we track but do not
        // surface (they are kept for spec completeness / future consumers).
        _ = directories
        _ = fileNames
        _ = basicBlock
        _ = endSequence
        _ = prologueEnd
        _ = epilogueBegin
        _ = isa
        _ = discriminator
    }

    // MARK: - Form decoding for v5 directory/file tables

    /// Reads a string encoded by the given DWARF form. Returns nil when the
    /// form is not a supported string form. Advances the cursor past the
    /// encoded value. The forms supported here are those relevant for
    /// `DW_LNCT_path` in v5 line table headers.
    private func readFormString(form: UInt64, cursor: DWARFByteCursor) throws -> String? {
        switch form {
        case 0x08: // DW_FORM_string
            return try cursor.readCString()
        case 0x1f: // DW_FORM_line_strp
            // 4‑byte offset into .debug_line_str
            let offset = UInt64(try cursor.readU32())
            return stringFromDebugLineStr(offset: offset)
        case 0x0e: // DW_FORM_strp
            // 4‑byte offset into .debug_str
            let offset = UInt64(try cursor.readU32())
            return stringFromDebugStr(offset: offset)
        default:
            return nil
        }
    }

    /// Reads an unsigned integer encoded by the given DWARF form. Supports the
    /// basic integer forms used in v5 directory/file tables. Returns nil when
    /// the form is not a supported numeric form.
    private func readFormUint(form: UInt64, cursor: DWARFByteCursor) throws -> UInt64? {
        switch form {
            case 0x0b: // DW_FORM_data1
                return UInt64(try cursor.readU8())
            case 0x05: // DW_FORM_data2
                return UInt64(try cursor.readU16())
            case 0x06: // DW_FORM_data4
                return UInt64(try cursor.readU32())
            case 0x07: // DW_FORM_data8
                return try cursor.readU64()
            case 0x0f: // DW_FORM_udata
                return try cursor.readULEB128()
            default:
                return nil
        }
    }

    /// Skips over a value encoded by the given DWARF form. Used to ignore
    /// unknown content types in v5 directory/file tables. Throws when the
    /// encoded length would run past the end of the section.
    private func skipForm(form: UInt64, cursor: DWARFByteCursor) throws {
        switch form {
        case 0x08: // DW_FORM_string
            _ = try cursor.readCString()
        case 0x1f: // DW_FORM_line_strp
            try cursor.skip(4)
        case 0x0e: // DW_FORM_strp
            try cursor.skip(4)
        case 0x0b: // DW_FORM_data1
            try cursor.skip(1)
        case 0x05: // DW_FORM_data2
            try cursor.skip(2)
        case 0x06: // DW_FORM_data4
            try cursor.skip(4)
        case 0x07: // DW_FORM_data8
            try cursor.skip(8)
        case 0x1e: // DW_FORM_data16 (e.g. MD5 checksum on v5 file entries)
            try cursor.skip(16)
        case 0x0a: // DW_FORM_block1
            let length = try cursor.readU8()
            try cursor.skip(Int(length))
        case 0x03: // DW_FORM_block2
            let length = try cursor.readU16()
            try cursor.skip(Int(length))
        case 0x04: // DW_FORM_block4
            let length = try cursor.readU32()
            try cursor.skip(Int(length))
        case 0x09: // DW_FORM_block
            let length = try cursor.readULEB128()
            if length > UInt64(Int.max) { throw DWARFByteCursor.Error.malformed("block length overflow") }
            try cursor.skip(Int(length))
        case 0x0f: // DW_FORM_udata
            _ = try cursor.readULEB128()
        case 0x0d: // DW_FORM_sdata
            _ = try cursor.readSLEB128()
        case 0x17: // DW_FORM_sec_offset
            try cursor.skip(4)
        default:
            // Unknown form: we cannot know the size, so we skip nothing.
            break
        }
    }

    /// Resolves a `.debug_line_str` offset to a NUL‑terminated string.
    private func stringFromDebugLineStr(offset: UInt64) -> String {
        let bytes = [UInt8](debugLineStr)
        guard offset < UInt64(bytes.count) else { return "" }
        var idx = Int(offset)
        var scalars: [UInt8] = []
        while idx < bytes.count {
            let byte = bytes[idx]
            if byte == 0 { break }
            scalars.append(byte)
            idx += 1
        }
        return String(bytes: scalars, encoding: .utf8) ?? ""
    }

    /// Resolves a `.debug_str` offset to a NUL‑terminated string.
    private func stringFromDebugStr(offset: UInt64) -> String {
        let bytes = [UInt8](debugStr)
        guard offset < UInt64(bytes.count) else { return "" }
        var idx = Int(offset)
        var scalars: [UInt8] = []
        while idx < bytes.count {
            let byte = bytes[idx]
            if byte == 0 { break }
            scalars.append(byte)
            idx += 1
        }
        return String(bytes: scalars, encoding: .utf8) ?? ""
    }
}

// MARK: - DWARFByteCursor

/// A minimal, bounds‑checked forward cursor over an immutable array of bytes.
/// The line number program parser uses this to traverse the raw section data.
/// Functions return nil on malformed input rather than throwing at the call
/// sites, enabling the decoder to degrade gracefully when encountering
/// truncated or unsupported structures.
private final class DWARFByteCursor {
    fileprivate enum Error: Swift.Error {
        case malformed(String)
    }
    private let bytes: [UInt8]
    private let endOffset: Int
    fileprivate private(set) var offset: Int

    fileprivate init(_ data: Data) {
        self.bytes = [UInt8](data)
        self.endOffset = data.count
        self.offset = 0
    }
    private init(bytes: [UInt8], offset: Int, endOffset: Int) {
        self.bytes = bytes
        self.offset = offset
        self.endOffset = endOffset
    }
    fileprivate var count: Int { endOffset }
    fileprivate var remaining: Int { endOffset - offset }

    /// Shares immutable storage while giving a nested record its own bounds.
    fileprivate func bounded(to limit: Int) throws -> DWARFByteCursor {
        guard limit >= offset, limit <= endOffset else {
            throw Error.malformed("invalid record boundary")
        }
        return DWARFByteCursor(bytes: bytes, offset: offset, endOffset: limit)
    }

    fileprivate func seek(to newOffset: Int) {
        offset = max(0, min(newOffset, endOffset))
    }
    fileprivate func skip(_ length: Int) throws {
        guard length >= 0, length <= remaining else {
            throw Error.malformed("read past end of section")
        }
        offset += length
    }
    fileprivate func readU8() throws -> UInt8 {
        guard remaining >= 1 else { throw Error.malformed("u8 past end") }
        defer { offset += 1 }
        return bytes[offset]
    }
    fileprivate func readU16() throws -> UInt16 {
        guard remaining >= 2 else { throw Error.malformed("u16 past end") }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
    fileprivate func readU32() throws -> UInt32 {
        guard remaining >= 4 else { throw Error.malformed("u32 past end") }
        defer { offset += 4 }
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(bytes[offset + i]) << (8 * i) }
        return value
    }
    fileprivate func readU64() throws -> UInt64 {
        guard remaining >= 8 else { throw Error.malformed("u64 past end") }
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
            if byte == 0 {
                guard let string = String(bytes: scalars, encoding: .utf8) else {
                    throw Error.malformed("invalid UTF-8 string")
                }
                return string
            }
            scalars.append(byte)
        }
        throw Error.malformed("unterminated string")
    }
    fileprivate func readULEB128() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try readU8()
            let payload = byte & 0x7f
            if (shift == 63 && payload > 1) || (shift > 63 && payload != 0) {
                throw Error.malformed("ULEB128 value exceeds UInt64")
            }
            if shift < 64 {
                result |= UInt64(payload) << shift
            }
            if byte & 0x80 == 0 { break }
            shift += 7
            if shift > 70 { throw Error.malformed("ULEB128 too long") }
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
                throw Error.malformed("SLEB128 value exceeds Int64")
            }
            if shift < 64 {
                result |= Int64(payload) << shift
            }
            shift += 7
            if shift > 70 { throw Error.malformed("SLEB128 too long") }
        } while byte & 0x80 != 0
        // Sign extend if necessary
        if shift < 64, byte & 0x40 != 0 {
            result |= -(Int64(1) << shift)
        }
        return result
    }
}
