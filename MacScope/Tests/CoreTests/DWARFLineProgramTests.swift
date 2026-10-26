//===----------------------------------------------------------------------===//
//
// This source file is part of the MacScope project.
//
// Copyright (c) 2026-present MacScope authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// These tests exercise the DWARF line number program decoder. A synthetic
// hand‑assembled `.debug_line` fixture proves the basic state machine, and
// an integration test compares the decoder against the system `dwarfdump`
// utility on a real dSYM built at test time. When clang/dsymutil/dwarfdump
// are unavailable on the host the integration test is skipped.
//
//===----------------------------------------------------------------------===//

import Foundation
import XCTest
@testable import MacScope

final class DWARFLineProgramTests: XCTestCase {

    // MARK: - 1. Synthetic line program

    /// Constructs a minimal DWARF v4 line table with one file and a single
    /// opcode sequence that emits a row then ends the sequence. Verifies that
    /// the decoder recovers exactly two rows: one ordinary and one
    /// end‑sequence row, and that the fields match the expected defaults.
    func testSyntheticLineProgramEmitsExpectedRows() throws {
        // Build a minimal header and opcode stream (see comments in the
        // implementation for byte layout).
        var body: [UInt8] = []
        // version (u16) = 4
        body.append(0x04); body.append(0x00)
        // header_length (u32) placeholder to be filled later
        let headerLengthPlaceholderIndex = body.count
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        // The offset just past the header_length field — header_length counts
        // bytes starting here.
        let afterHeaderLength = body.count
        // minimum_instruction_length
        body.append(0x01)
        // maximum_operations_per_instruction
        body.append(0x01)
        // default_is_stmt
        body.append(0x01)
        // line_base (int8)
        body.append(0x00)
        // line_range
        body.append(0x01)
        // opcode_base
        body.append(0x0d)
        // standard_opcode_lengths[opcode_base-1] (12 zeros)
        body.append(contentsOf: Array(repeating: UInt8(0), count: 12))
        // include_directories: just a terminating NUL
        body.append(0x00)
        // file_names: one file "test.c" followed by terminating empty entry
        let fileName = "test.c"
        body.append(contentsOf: fileName.utf8)
        body.append(0x00)
        // dir_index (ULEB128) = 0
        body.append(0x00)
        // mod_time (ULEB128) = 0
        body.append(0x00)
        // file_length (ULEB128) = 0
        body.append(0x00)
        // terminating empty name
        body.append(0x00)
        // Compute header_length and fill placeholder. header_length counts
        // bytes starting after the header_length field up to this point (the
        // first opcode).
        let headerLength = UInt32(body.count - afterHeaderLength)
        body[headerLengthPlaceholderIndex + 0] = UInt8(headerLength & 0xff)
        body[headerLengthPlaceholderIndex + 1] = UInt8((headerLength >> 8) & 0xff)
        body[headerLengthPlaceholderIndex + 2] = UInt8((headerLength >> 16) & 0xff)
        body[headerLengthPlaceholderIndex + 3] = UInt8((headerLength >> 24) & 0xff)
        // Opcodes: DW_LNS_copy followed by DW_LNE_end_sequence.
        body.append(0x01)              // DW_LNS_copy
        body.append(0x00)              // extended opcode
        body.append(0x01)              // length = 1 byte of payload
        body.append(0x01)              // DW_LNE_end_sequence
        // Prepend the unit_length (u32) = length of the rest of the unit
        var unit: [UInt8] = []
        let unitLength = UInt32(body.count)
        unit.append(UInt8(unitLength & 0xff))
        unit.append(UInt8((unitLength >> 8) & 0xff))
        unit.append(UInt8((unitLength >> 16) & 0xff))
        unit.append(UInt8((unitLength >> 24) & 0xff))
        unit.append(contentsOf: body)
        let debugLine = Data(unit)
        let program = DWARFLineProgram(debugLine: debugLine)
        let rows = program.decode()
        // Expect exactly two rows: one regular and one end_sequence
        XCTAssertEqual(rows.count, 2, "Expected two rows, got \(rows)")
        if rows.count == 2 {
            let first = rows[0]
            XCTAssertEqual(first.address, 0)
            XCTAssertEqual(first.fileIndex, 1)
            XCTAssertEqual(first.line, 1)
            XCTAssertEqual(first.column, 0)
            XCTAssertTrue(first.isStmt)
            XCTAssertFalse(first.endSequence)
            let second = rows[1]
            XCTAssertEqual(second.address, 0)
            XCTAssertEqual(second.fileIndex, 1)
            XCTAssertEqual(second.line, 1)
            XCTAssertEqual(second.column, 0)
            XCTAssertTrue(second.isStmt)
            XCTAssertTrue(second.endSequence)
        }
    }

    // MARK: - 1b. Address advancement via DW_LNS_advance_pc + advance_line

    /// A DWARF v4 program that advances the PC and the line before copying a
    /// row, then ends the sequence. Verifies the state-machine arithmetic
    /// (advance_pc * minimum_instruction_length, advance_line delta).
    func testAdvancePCAndLineAreApplied() throws {
        var body: [UInt8] = []
        body.append(0x04); body.append(0x00)                 // version 4
        let hlIdx = body.count
        body.append(contentsOf: [0, 0, 0, 0])                // header_length placeholder
        let afterHL = body.count
        body.append(0x04)                                    // minimum_instruction_length = 4
        body.append(0x01)                                    // max_ops_per_instruction = 1
        body.append(0x01)                                    // default_is_stmt = 1
        body.append(0x00)                                    // line_base = 0
        body.append(0x01)                                    // line_range = 1
        body.append(0x0d)                                    // opcode_base = 13
        body.append(contentsOf: Array(repeating: UInt8(0), count: 12))
        body.append(0x00)                                    // include_directories terminator
        body.append(contentsOf: "a.c".utf8); body.append(0x00)
        body.append(0x00); body.append(0x00); body.append(0x00) // dir/mtime/len
        body.append(0x00)                                    // file table terminator
        let headerLength = UInt32(body.count - afterHL)
        body[hlIdx + 0] = UInt8(headerLength & 0xff)
        body[hlIdx + 1] = UInt8((headerLength >> 8) & 0xff)
        body[hlIdx + 2] = UInt8((headerLength >> 16) & 0xff)
        body[hlIdx + 3] = UInt8((headerLength >> 24) & 0xff)
        // DW_LNE_set_address 0x1000 (8-byte operand)
        body.append(0x00); body.append(0x09); body.append(0x02)
        body.append(contentsOf: [0x00, 0x10, 0, 0, 0, 0, 0, 0])
        body.append(0x02); body.append(0x05)                 // advance_pc 5 → +5*4 = +20
        body.append(0x03); body.append(0x07)                 // advance_line +7 → line 8
        body.append(0x01)                                    // DW_LNS_copy
        body.append(0x00); body.append(0x01); body.append(0x01) // end_sequence
        var unit: [UInt8] = []
        let unitLength = UInt32(body.count)
        unit.append(UInt8(unitLength & 0xff))
        unit.append(UInt8((unitLength >> 8) & 0xff))
        unit.append(UInt8((unitLength >> 16) & 0xff))
        unit.append(UInt8((unitLength >> 24) & 0xff))
        unit.append(contentsOf: body)
        let rows = DWARFLineProgram(debugLine: Data(unit)).decode()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.address, 0x1000 + 20)
        XCTAssertEqual(rows.first?.line, 8)
        XCTAssertEqual(rows.last?.endSequence, true)
    }

    // MARK: - 1c. DWARF v5 directory/file format count is a single ubyte

    /// Builds a minimal DWARF v5 line program whose directory_entry_format_count
    /// and file_name_entry_format_count are single ubytes (per DWARF v5 §6.2.4).
    /// A decoder that read these as ULEB128 would coincidentally agree for small
    /// counts; this fixture proves we consume exactly one byte and stay aligned
    /// through the v5 header into the opcode stream.
    func testV5DirectoryFileFormatCountIsUByte() throws {
        var body: [UInt8] = []
        body.append(0x05); body.append(0x00)                 // version 5
        body.append(0x08)                                    // address_size = 8
        body.append(0x00)                                    // segment_selector_size = 0
        let hlIdx = body.count
        body.append(contentsOf: [0, 0, 0, 0])                // header_length placeholder
        let afterHL = body.count
        body.append(0x01)                                    // minimum_instruction_length
        body.append(0x01)                                    // max_ops_per_instruction
        body.append(0x01)                                    // default_is_stmt
        body.append(0x00)                                    // line_base
        body.append(0x01)                                    // line_range
        body.append(0x0d)                                    // opcode_base = 13
        body.append(contentsOf: Array(repeating: UInt8(0), count: 12))
        // directory_entry_format_count (ubyte) = 1, then (DW_LNCT_path, DW_FORM_string)
        body.append(0x01)
        body.append(0x01); body.append(0x08)                 // content=path, form=string
        // directories_count (ULEB) = 1
        body.append(0x01)
        body.append(contentsOf: "/tmp".utf8); body.append(0x00)
        // file_name_entry_format_count (ubyte) = 2: (path,string),(dir_index,udata)
        body.append(0x02)
        body.append(0x01); body.append(0x08)                 // path, string
        body.append(0x02); body.append(0x0f)                 // directory_index, udata
        // file_names_count (ULEB) = 1
        body.append(0x01)
        body.append(contentsOf: "a.c".utf8); body.append(0x00)
        body.append(0x00)                                    // dir_index = 0
        let headerLength = UInt32(body.count - afterHL)
        body[hlIdx + 0] = UInt8(headerLength & 0xff)
        body[hlIdx + 1] = UInt8((headerLength >> 8) & 0xff)
        body[hlIdx + 2] = UInt8((headerLength >> 16) & 0xff)
        body[hlIdx + 3] = UInt8((headerLength >> 24) & 0xff)
        // Opcodes: set_address 0x2000, copy, end_sequence.
        body.append(0x00); body.append(0x09); body.append(0x02)
        body.append(contentsOf: [0x00, 0x20, 0, 0, 0, 0, 0, 0])
        body.append(0x01)                                    // DW_LNS_copy
        body.append(0x00); body.append(0x01); body.append(0x01) // end_sequence
        var unit: [UInt8] = []
        let unitLength = UInt32(body.count)
        unit.append(UInt8(unitLength & 0xff))
        unit.append(UInt8((unitLength >> 8) & 0xff))
        unit.append(UInt8((unitLength >> 16) & 0xff))
        unit.append(UInt8((unitLength >> 24) & 0xff))
        unit.append(contentsOf: body)
        let rows = DWARFLineProgram(debugLine: Data(unit)).decode()
        XCTAssertEqual(rows.count, 2, "v5 header desync would drop or corrupt rows: \(rows)")
        XCTAssertEqual(rows.first?.address, 0x2000)
        XCTAssertEqual(rows.first?.line, 1)
        XCTAssertEqual(rows.last?.endSequence, true)
    }

    // MARK: - 1d. Malformed line_range must not trap

    /// A header declaring line_range = 0 would divide-by-zero in the special-
    /// opcode math. The decoder must skip the unit and return no rows, never crash.
    func testZeroLineRangeIsRejectedWithoutTrap() throws {
        var body: [UInt8] = []
        body.append(0x04); body.append(0x00)                 // version 4
        let hlIdx = body.count
        body.append(contentsOf: [0, 0, 0, 0])
        let afterHL = body.count
        body.append(0x01)                                    // min_inst_length
        body.append(0x01)                                    // max_ops
        body.append(0x01)                                    // default_is_stmt
        body.append(0x00)                                    // line_base
        body.append(0x00)                                    // line_range = 0 (malformed!)
        body.append(0x0d)                                    // opcode_base
        body.append(contentsOf: Array(repeating: UInt8(0), count: 12))
        body.append(0x00)                                    // dirs terminator
        body.append(0x00)                                    // files terminator
        let headerLength = UInt32(body.count - afterHL)
        body[hlIdx + 0] = UInt8(headerLength & 0xff)
        body[hlIdx + 1] = UInt8((headerLength >> 8) & 0xff)
        body[hlIdx + 2] = UInt8((headerLength >> 16) & 0xff)
        body[hlIdx + 3] = UInt8((headerLength >> 24) & 0xff)
        body.append(0xff)                                    // a special opcode (would div-by-zero)
        var unit: [UInt8] = []
        let unitLength = UInt32(body.count)
        unit.append(UInt8(unitLength & 0xff))
        unit.append(UInt8((unitLength >> 8) & 0xff))
        unit.append(UInt8((unitLength >> 16) & 0xff))
        unit.append(UInt8((unitLength >> 24) & 0xff))
        unit.append(contentsOf: body)
        // Must not trap; the unit is skipped so no rows are produced.
        let rows = DWARFLineProgram(debugLine: Data(unit)).decode()
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - 2. Integration test against dwarfdump

    /// Builds a small C program with clang and dsymutil, runs dwarfdump on
    /// its .dSYM to extract (address,line) tuples, and asserts that the
    /// DWARFLineProgram decoder produces the same set of mappings. The test
    /// is skipped when clang, dsymutil, or dwarfdump are unavailable.
    func testLineProgramMatchesDwarfdumpOnRealDSYM() throws {
        let built = try RealLineDSYM.build()
        // Locate the actual DWARF Mach‑O inside the dSYM bundle.
        let dwarfURL = built.dsymURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("DWARF", isDirectory: true)
            .appendingPathComponent(built.binaryURL.lastPathComponent)
        let bytes = try Data(contentsOf: dwarfURL, options: [.mappedIfSafe])
        // Parse the Mach‑O to locate the DWARF sections.
        // Once the toolchain has produced the fixture, a loader/parser failure
        // is a regression, not an unavailable-oracle skip.
        let machO = try MachOParser().parse(bytes, options: MachOParseOptions(
            recoverStringLiterals: false,
            recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: false,
            parseCodeSignature: false
        ))
        // Slice out the debug sections we need.
        var debugLine = Data()
        var debugLineStr = Data()
        var debugStr = Data()
        for section in machO.sections where section.segmentName == "__DWARF" {
            let data: Data
            do {
                guard section.size > 0, let sizeInt = Int(exactly: section.size) else { continue }
                let start = Int(section.fileOffset)
                let end = start + sizeInt
                guard end <= bytes.count else { continue }
                data = bytes.subdata(in: start..<end)
            }
            switch section.sectionName {
            case "__debug_line":
                debugLine = data
            case "__debug_line_str":
                debugLineStr = data
            case "__debug_str":
                debugStr = data
            default:
                continue
            }
        }
        // Decode the line program using our implementation.
        let program = DWARFLineProgram(debugLine: debugLine, debugLineStr: debugLineStr, debugStr: debugStr)
        let ourRows = program.decode()
        // The decoder must resolve each row's source FILE name (version-aware: DWARF v5 file indices
        // are 0-based, v2–v4 1-based), not just the line number — "file:line" is the useful unit.
        XCTAssertTrue(ourRows.contains { ($0.file ?? "").hasSuffix(".c") },
                      "line rows must resolve a source file name from the line-program file table")
        let ourPairs = Set(ourRows.map { LineKey(address: $0.address, line: $0.line) })
        // Run dwarfdump to get the ground truth. We invoke /usr/bin/dwarfdump
        // directly and parse its output. Skip the test if dwarfdump is missing.
        let dwarfdumpURL = URL(fileURLWithPath: "/usr/bin/dwarfdump")
        guard FileManager.default.isExecutableFile(atPath: dwarfdumpURL.path) else {
            throw XCTSkip("dwarfdump is unavailable on this host")
        }
        let process = Process()
        process.executableURL = dwarfdumpURL
        process.arguments = ["--debug-line", built.dsymURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Read incrementally to avoid the pipe-buffer deadlock dwarfdump's
        // large output can cause when waiting before draining.
        let handle = pipe.fileHandleForReading
        do {
            try process.run()
        } catch {
            throw XCTSkip("Failed to run dwarfdump: \(error)")
        }
        let outputData = handle.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("dwarfdump failed: \(String(decoding: outputData, as: UTF8.self))")
        }
        let outputString = String(decoding: outputData, as: UTF8.self)
        var dwarfPairs: Set<LineKey> = []
        let hexPrefix = "0x"
        for line in outputString.split(separator: "\n") {
            // Find tokens separated by whitespace.
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            guard tokens.count >= 2 else { continue }
            let addrToken = tokens[0]
            guard addrToken.starts(with: hexPrefix) else { continue }
            if let addr = UInt64(addrToken.dropFirst(hexPrefix.count), radix: 16) {
                // The line number is the second column in dwarfdump's --debug-line
                // table output (Address  Line  Column  File  ...).
                if let ln = UInt64(tokens[1]) {
                    dwarfPairs.insert(LineKey(address: addr, line: ln))
                }
            }
        }
        // Sanity: ensure dwarfdump produced some rows.
        XCTAssertFalse(dwarfPairs.isEmpty, "dwarfdump produced no address/line pairs")
        // Compare sets. Use set equality rather than ordering.
        XCTAssertEqual(ourPairs, dwarfPairs, "Line table rows differ from dwarfdump")
    }

    // MARK: - Crafted-input no-trap hardening (review BUG-005 / BUG-006)

    /// Wraps a v4 header (one file `a.c`, no rows) around a caller-supplied
    /// opcode stream and frames it as a single unit. Mirrors the byte layout of
    /// `testAdvancePCAndLineAreApplied` above.
    private func v4Unit(
        opcodes: [UInt8],
        minimumInstructionLength: UInt8 = 1,
        maximumOperationsPerInstruction: UInt8 = 1,
        lineBase: Int8 = 0
    ) -> Data {
        var body: [UInt8] = []
        body.append(0x04); body.append(0x00)                 // version 4
        let hlIdx = body.count
        body.append(contentsOf: [0, 0, 0, 0])                // header_length placeholder
        let afterHL = body.count
        body.append(minimumInstructionLength)
        body.append(maximumOperationsPerInstruction)
        body.append(0x01)                                    // default_is_stmt
        body.append(UInt8(bitPattern: lineBase))
        body.append(0x01)                                    // line_range
        body.append(0x0d)                                    // opcode_base = 13
        body.append(contentsOf: Array(repeating: UInt8(0), count: 12))
        body.append(0x00)                                    // include_directories terminator
        body.append(contentsOf: "a.c".utf8); body.append(0x00)
        body.append(0x00); body.append(0x00); body.append(0x00) // dir/mtime/len
        body.append(0x00)                                    // file table terminator
        let headerLength = UInt32(body.count - afterHL)
        body[hlIdx + 0] = UInt8(headerLength & 0xff)
        body[hlIdx + 1] = UInt8((headerLength >> 8) & 0xff)
        body[hlIdx + 2] = UInt8((headerLength >> 16) & 0xff)
        body[hlIdx + 3] = UInt8((headerLength >> 24) & 0xff)
        body.append(contentsOf: opcodes)
        var unit: [UInt8] = []
        let unitLength = UInt32(body.count)
        unit.append(UInt8(unitLength & 0xff))
        unit.append(UInt8((unitLength >> 8) & 0xff))
        unit.append(UInt8((unitLength >> 16) & 0xff))
        unit.append(UInt8((unitLength >> 24) & 0xff))
        unit.append(contentsOf: body)
        return Data(unit)
    }

    func testAdvancePCOverflowRejectsUnitAndPreservesIndependentRows() {
        // Canonical ULEB128 for UInt64.max; multiplying by min_inst_length=4
        // cannot describe an address movement in a 64-bit image.
        let maximumULEB: [UInt8] = Array(repeating: 0xff, count: 9) + [0x01]
        let cases: [(String, UInt8, [UInt8])] = [
            ("address multiplication", 1, [0x01]),
            // With max_ops=2, advance_pc 1 leaves op_index=1. Adding
            // UInt64.max must also reject rather than wrapping the op index.
            ("operation-index addition", 2, [0x02, 0x01, 0x01]),
        ]
        for (name, maximumOperations, prefix) in cases {
            let malformed = v4Unit(
                opcodes: prefix + [0x02] + maximumULEB + [0x01, 0x00, 0x01, 0x01],
                minimumInstructionLength: 4,
                maximumOperationsPerInstruction: maximumOperations
            )
            let following = v4Unit(opcodes: [0x02, 0x07, 0x03, 0x03, 0x01, 0x00, 0x01, 0x01])
            let rows = DWARFLineProgram(debugLine: malformed + following).decode()

            XCTAssertEqual(rows.map(\.address), [0, 7, 7], name)
            XCTAssertEqual(rows.map(\.line), [1, 4, 4], name)
            XCTAssertEqual(rows.map(\.endSequence), [false, false, true], name)
            XCTAssertEqual(
                rows.map(\.lineProgramUnitOffset),
                [0, UInt64(malformed.count), UInt64(malformed.count)], name
            )
        }
    }

    func testSpecialOpcodeLineOverflowRejectsUnitWithoutFabricatingZeroLine() {
        // SLEB128(Int64.max - 1), added to the initial line=1, reaches the
        // signed boundary exactly. The following special opcode adds one.
        let maximumMinusOneSLEB: [UInt8] = [0xfe] + Array(repeating: 0xff, count: 8) + [0x00]
        let malformed = v4Unit(
            opcodes: [0x03] + maximumMinusOneSLEB + [0x01, 0x0d, 0x01, 0x00, 0x01, 0x01],
            lineBase: 1
        )
        let following = v4Unit(opcodes: [0x02, 0x07, 0x03, 0x03, 0x01, 0x00, 0x01, 0x01])
        let rows = DWARFLineProgram(debugLine: malformed + following).decode()

        XCTAssertEqual(rows.map(\.address), [0, 7, 7])
        XCTAssertEqual(rows.map(\.line), [UInt64(Int64.max), 4, 4])
        XCTAssertEqual(rows.map(\.endSequence), [false, false, true])
    }

    func testAddressAdvancesCannotWrapIntoLowImageAddresses() {
        let setNearMaximumAddress: [UInt8] = [0x00, 0x09, 0x02, 0xfe]
            + Array(repeating: 0xff, count: 7)
        let advances: [(String, [UInt8])] = [
            ("fixed_advance_pc", [0x09, 0x03, 0x00]),
            ("advance_pc", [0x02, 0x01]),
            ("special opcode", [0x0e]),
            ("const_add_pc", [0x08]),
        ]
        for (name, advance) in advances {
            let malformed = v4Unit(
                opcodes: setNearMaximumAddress + [0x01] + advance + [0x01, 0x00, 0x01, 0x01],
                minimumInstructionLength: 4
            )
            let following = v4Unit(opcodes: [0x02, 0x07, 0x03, 0x03, 0x01, 0x00, 0x01, 0x01])
            let rows = DWARFLineProgram(debugLine: malformed + following).decode()

            XCTAssertEqual(rows.map(\.address), [UInt64.max - 1, 7, 7], name)
            XCTAssertEqual(rows.map(\.line), [1, 4, 4], name)
            XCTAssertEqual(rows.map(\.endSequence), [false, false, true], name)
        }
    }

    func testV5BlockLengthAtIntMaximumRejectsUnitAndContinues() {
        // A representable length still cannot be added to a nonzero cursor
        // offset. The unknown directory field takes DW_FORM_block's skip path.
        let maximumIntULEB: [UInt8] = Array(repeating: 0xff, count: 8) + [0x7f]
        let header: [UInt8] = [1, 1, 1, 0, 1, 13]
            + Array(repeating: 0, count: 12)
            + [1, 0x7f, 0x09, 1] + maximumIntULEB
        let body: [UInt8] = [5, 0, 8, 0, UInt8(header.count), 0, 0, 0] + header
        let malformed = Data([UInt8(body.count), 0, 0, 0] + body)
        let following = v4Unit(opcodes: [0x02, 0x07, 0x01, 0x00, 0x01, 0x01])
        let rows = DWARFLineProgram(debugLine: malformed + following).decode()

        XCTAssertEqual(rows.map(\.address), [7, 7])
        XCTAssertEqual(rows.map(\.lineProgramUnitOffset), Array(repeating: UInt64(malformed.count), count: 2))
        XCTAssertEqual(rows.map(\.endSequence), [false, true])
    }

    func testSetAddressRequiresFullOperandInsideDeclaredExtendedOpcode() {
        // extLength=1 contains only the set_address subopcode, with no address.
        // Bytes after that declared boundary cannot supply its missing operand.
        let malformed = v4Unit(
            opcodes: [0x01, 0x00, 0x01, 0x02]
                + Array(repeating: 0xff, count: 8) + [0x01, 0x00, 0x01, 0x01]
        )
        let following = v4Unit(opcodes: [0x02, 0x07, 0x01, 0x00, 0x01, 0x01])
        let rows = DWARFLineProgram(debugLine: malformed + following).decode()

        XCTAssertEqual(rows.map(\.address), [0, 7, 7])
        XCTAssertEqual(rows.map(\.endSequence), [false, false, true])
        XCTAssertEqual(
            rows.map(\.lineProgramUnitOffset),
            [0, UInt64(malformed.count), UInt64(malformed.count)]
        )
    }

    func testLEBBoundaryOperandsRemainValidInLineProgram() {
        let unsignedCases: [(String, [UInt8], UInt64)] = [
            ("UInt64.max", Array(repeating: 0xff, count: 9) + [0x01], UInt64.max),
            ("unsigned zero extension", Array(repeating: 0x80, count: 10) + [0x00], 0),
        ]
        for (name, operand, expectedColumn) in unsignedCases {
            let rows = DWARFLineProgram(debugLine: v4Unit(
                opcodes: [0x05] + operand + [0x01, 0x00, 0x01, 0x01]
            )).decode()
            XCTAssertEqual(rows.map(\.column), [expectedColumn, expectedColumn], name)
        }

        let signedCases: [(String, [UInt8], UInt64)] = [
            ("Int64.max", Array(repeating: 0xff, count: 9) + [0x00], UInt64(Int64.max)),
            ("Int64.min", Array(repeating: 0x80, count: 9) + [0x7f], 0),
        ]
        for (name, operand, expectedLine) in signedCases {
            // First advance_line -1 moves the initial line=1 to zero. This
            // isolates LEB decoding from positive addition overflow; negative
            // lines retain the line program's existing conservative zero floor.
            let rows = DWARFLineProgram(debugLine: v4Unit(
                opcodes: [0x03, 0x7f, 0x03] + operand + [0x01, 0x00, 0x01, 0x01]
            )).decode()
            XCTAssertEqual(rows.map(\.line), [expectedLine, expectedLine], name)
        }
    }

    func testOutOfDomainLEBLineOperandsCannotBecomeZeroOrWrappedValues() {
        let cases: [(String, UInt8, [UInt8])] = [
            ("unsigned 2^64", 0x05, Array(repeating: 0x80, count: 9) + [0x02]),
            ("unsigned nonzero eleventh octet", 0x05, Array(repeating: 0x80, count: 10) + [0x01]),
            ("signed positive overflow", 0x03, Array(repeating: 0x80, count: 9) + [0x01]),
            ("signed negative overflow", 0x03, Array(repeating: 0xff, count: 9) + [0x7e]),
            ("signed eleventh octet", 0x03, Array(repeating: 0xff, count: 10) + [0x7f]),
        ]
        for (name, opcode, operand) in cases {
            let malformed = v4Unit(opcodes: [0x01, opcode] + operand + [0x01, 0x00, 0x01, 0x01])
            let following = v4Unit(opcodes: [0x02, 0x07, 0x03, 0x03, 0x01, 0x00, 0x01, 0x01])
            let rows = DWARFLineProgram(debugLine: malformed + following).decode()
            XCTAssertEqual(rows.map(\.address), [0, 7, 7], name)
            XCTAssertEqual(rows.map(\.line), [1, 4, 4], name)
            XCTAssertEqual(rows.map(\.column), [0, 0, 0], name)
            XCTAssertEqual(rows.map(\.endSequence), [false, false, true], name)
        }
    }

    func testDefineFileCannotBorrowNameAndMetadataOutsideItsExtendedRecord() {
        let filePayload: [UInt8] = Array("b.c".utf8) + [0, 0, 0, 0]
        let valid = v4Unit(
            opcodes: [0x00, 0x08, 0x03] + filePayload + [0x04, 0x02, 0x01, 0x00, 0x01, 0x01]
        )
        XCTAssertEqual(DWARFLineProgram(debugLine: valid).decode().map(\.file), ["b.c", "b.c"])

        // extLength=1 contains the subopcode only. The following string and
        // metadata bytes are outside that record and cannot create file #2.
        let malformed = v4Unit(
            opcodes: [0x01, 0x00, 0x01, 0x03] + filePayload
                + [0x04, 0x02, 0x01, 0x00, 0x01, 0x01]
        )
        let following = v4Unit(opcodes: [0x02, 0x07, 0x01, 0x00, 0x01, 0x01])
        let rows = DWARFLineProgram(debugLine: malformed + following).decode()
        XCTAssertEqual(rows.map(\.address), [0, 7, 7])
        XCTAssertEqual(rows.map(\.file), ["a.c", "a.c", "a.c"])
        XCTAssertEqual(rows.map(\.endSequence), [false, false, true])
    }

    /// BUG-005: an extended opcode (`0x00`) whose ULEB128 length is
    /// `0xFFFFFFFFFFFFFFFF` overflows `Int(extLength)`. That is a runtime trap,
    /// not a thrown error, so the decoder's own do/catch cannot contain it — the
    /// length must be range-checked against the remaining bytes first. `decode()`
    /// must return without aborting the process.
    func testExtendedOpcodeHugeLengthDoesNotTrap() {
        let opcodes: [UInt8] = [
            0x00,                                            // extended-opcode marker
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, // ULEB128 ≈ UInt64.max
            0x01,                                            // DW_LNE_end_sequence subopcode
        ]
        let rows = DWARFLineProgram(debugLine: v4Unit(opcodes: opcodes)).decode()
        XCTAssertTrue(rows.isEmpty, "the malformed extended opcode yields no rows and no trap")
    }

    /// BUG-006: a DWARF v5 line unit whose `directory_entry_format_count` is 0
    /// while `directories_count` is enormous. Each loop iteration consumes zero
    /// bytes and cannot throw, so the pre-fix loop spun and grew `directories`
    /// unboundedly until OOM. The recovery cap must reject the count and let the
    /// per-unit do/catch drop the unit — `decode()` returns promptly.
    func testV5UnboundedDirectoryCountIsRejectedNotSpun() {
        var body: [UInt8] = []
        body.append(0x05); body.append(0x00)                 // version 5
        body.append(0x08)                                    // address_size = 8
        body.append(0x00)                                    // segment_selector_size = 0
        let hlIdx = body.count
        body.append(contentsOf: [0, 0, 0, 0])                // header_length placeholder
        let afterHL = body.count
        body.append(0x01)                                    // minimum_instruction_length
        body.append(0x01)                                    // max_ops_per_instruction
        body.append(0x01)                                    // default_is_stmt
        body.append(0x00)                                    // line_base
        body.append(0x01)                                    // line_range
        body.append(0x0d)                                    // opcode_base = 13
        body.append(contentsOf: Array(repeating: UInt8(0), count: 12))
        body.append(0x00)                                    // directory_entry_format_count = 0
        // directories_count (ULEB128) = 0xFFFFFFFF — huge, with no entry formats.
        body.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0x0F])
        let headerLength = UInt32(body.count - afterHL)
        body[hlIdx + 0] = UInt8(headerLength & 0xff)
        body[hlIdx + 1] = UInt8((headerLength >> 8) & 0xff)
        body[hlIdx + 2] = UInt8((headerLength >> 16) & 0xff)
        body[hlIdx + 3] = UInt8((headerLength >> 24) & 0xff)
        var unit: [UInt8] = []
        let unitLength = UInt32(body.count)
        unit.append(UInt8(unitLength & 0xff))
        unit.append(UInt8((unitLength >> 8) & 0xff))
        unit.append(UInt8((unitLength >> 16) & 0xff))
        unit.append(UInt8((unitLength >> 24) & 0xff))
        unit.append(contentsOf: body)

        let rows = DWARFLineProgram(debugLine: Data(unit)).decode()
        XCTAssertTrue(rows.isEmpty, "the over-cap directory count is dropped without spinning or OOM")
    }

    /// A hashable (address, line) key used to compare our rows against dwarfdump.
    private struct LineKey: Hashable {
        var address: UInt64
        var line: UInt64
    }

    // MARK: - Private helper for integration test

    /// End-to-end: DSYMImportService must recover the line table from a real matched dSYM into
    /// DSYMImportResult.sourceLines, and those rows must resolve back through the snapshot lookup —
    /// the wired path that feeds the inspector + listing gutter (previously the line program was
    /// fully implemented but reachable only from tests).
    func testDSYMImportRecoversSourceLinesReachableThroughLookup() throws {
        let built = try RealLineDSYM.build()
        let result = try DSYMImportService().importDebugSymbols(at: built.dsymURL, expectedUUID: built.uuid)
        XCTAssertFalse(result.sourceLines.isEmpty, "the dSYM's line program must surface source lines")
        XCTAssertTrue(result.sourceLines.contains { ($0.file ?? "").hasSuffix(".c") && $0.line > 0 },
                      "a recovered row must carry a .c source file and a positive line number")

        var snapshot = WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        snapshot.sourceLines = result.sourceLines
        let firstReal = try XCTUnwrap(result.sourceLines.first { !$0.endSequence },
                                      "expected at least one non-terminator row")
        XCTAssertEqual(snapshot.sourceLine(at: firstReal.address)?.line, firstReal.line,
                       "a recovered row's own address must resolve to its line through the snapshot lookup")
    }

    /// A reimplementation of the RealDSYM builder from DSYMImportTests. It
    /// produces a tiny C program, compiles it with debug info, runs dsymutil
    /// to generate a dSYM, and returns the paths and UUID. Tests using this
    /// builder must call it from within a try context and be prepared to
    /// catch XCTSkip when the toolchain is unavailable.
    private enum RealLineDSYM {
        struct Built {
            var dsymURL: URL
            var binaryURL: URL
            var uuid: String
        }
        static func build() throws -> Built {
            let clang = URL(fileURLWithPath: "/usr/bin/clang")
            let dsymutil = URL(fileURLWithPath: "/usr/bin/dsymutil")
            let dwarfdump = URL(fileURLWithPath: "/usr/bin/dwarfdump")
            guard FileManager.default.isExecutableFile(atPath: clang.path),
                  FileManager.default.isExecutableFile(atPath: dsymutil.path),
                  FileManager.default.isExecutableFile(atPath: dwarfdump.path) else {
                throw XCTSkip("clang/dsymutil/dwarfdump unavailable on this host")
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("macscope-line-dsym-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let sourceURL = dir.appendingPathComponent("x.c")
            try """
            int helper_alpha(int a) { return a + 1; }
            int helper_beta(int a, int b) { return a * b; }
            int main(void) { return helper_alpha(2) + helper_beta(3, 4); }
            """.write(to: sourceURL, atomically: true, encoding: .utf8)
            let objectURL = dir.appendingPathComponent("x.o")
            let binaryURL = dir.appendingPathComponent("x")
            try run(clang, ["-g", "-O0", "-c", "-o", objectURL.path, sourceURL.path])
            try run(clang, ["-g", "-O0", "-o", binaryURL.path, objectURL.path])
            try run(dsymutil, [binaryURL.path])
            let dsymURL = dir.appendingPathComponent("x.dSYM", isDirectory: true)
            guard FileManager.default.fileExists(atPath: dsymURL.path) else {
                throw XCTSkip("dsymutil did not produce a dSYM on this host")
            }
            // Parse the binary to extract its UUID.
            let bytes = try Data(contentsOf: binaryURL)
            let machO = try MachOParser().parse(bytes, options: MachOParseOptions(
                recoverStringLiterals: false,
                recoverObjectiveCMetadata: false,
                recoverSwiftMetadata: false,
                parseCodeSignature: false
            ))
            guard let uuid = machO.uuid?.stringValue else {
                throw XCTSkip("the test binary has no LC_UUID on this host")
            }
            return Built(dsymURL: dsymURL, binaryURL: binaryURL, uuid: uuid)
        }
        private static func run(_ tool: URL, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let handle = pipe.fileHandleForReading
            try process.run()
            let output = handle.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw XCTSkip("\(tool.lastPathComponent) failed (\(process.terminationStatus)): \(String(decoding: output, as: UTF8.self))")
            }
        }
    }
}
