import Foundation
import XCTest
@testable import MacScope

/// Crafted-input regression tests for the SECTION-field trap surface (the parser
/// security audit follow-up to F2–F5, which hardened the SEGMENT fields). A hostile thin Mach-O
/// whose section table carries adversarial 64-bit `size`/`address` values must produce a TYPED
/// error, a `nil`, or a saturated/skipped result — never a process trap.
///
/// Scope note — like the segment follow-up, this hardens the CONSUMERS, not the parser: section
/// `fileOffset`s in a dyld shared cache are cache-relative, so a parser-level section-range
/// rejection would reject valid input (the same reason F1 was deferred for segments). Each fixture
/// therefore parses successfully and then exercises a hardened consumer.
///
/// The traps are integer-conversion / arithmetic OVERFLOWS (a Swift trap aborts the process — it
/// cannot be caught with `XCTAssertThrowsError`), so the guarantee under test is "the call returns
/// at all". The concrete unguarded sites covered here:
///   • `MachOParser` indirect-symbol address      `section.address + UInt64(entryIndex * entrySize)`
///   • `MachOParser` metadata-string address       `section.address + UInt64(stringStart - offset)`
///   • `MachOParser` ObjC-reference source address `section.address + UInt64(entryIndex * 8)`
///   • `MachOExceptionMetadata.totalByteCount`      `partialResult + section.size`  (UInt64 sum)
///   • `DSYMImportService.sliceSection`             `Int(section.size)` + `start + Int(section.size)`
/// `WorkspaceScriptingAPI`'s `read-bytes` (`section.size - delta`) was found ALREADY overflow-safe
/// (its `address &+ size` selection predicate guarantees `delta < size`); the last test LOCKS that.
final class MachOSectionConsumerSecurityTests: XCTestCase {

    // MARK: - MachOParser: per-entry address projections must not trap on a wrapping section address

    /// `__objc_methname` carrying "A\0B\0" at a hostile `address == UInt64.max`: the first string
    /// ("A", in-section offset 0) projects to `.max`; the second ("B", offset 2) would compute
    /// `.max + 2`, which TRAPS. The hardened reader keeps the representable string and drops the
    /// overflowing one — the parse never crashes.
    func testMetadataStringRecoveryDoesNotTrapOnWrappingSectionAddress() throws {
        let image = CraftedMachO()
            .addSegment(name: "__TEXT", sections: [
                .init(sectionName: "__objc_methname", segmentName: "__TEXT",
                      address: .max, size: 4, content: [0x41, 0x00, 0x42, 0x00]) // "A\0B\0"
            ])
        let machO = try MachOParser().parse(image.data())
        XCTAssertTrue(machO.stringLiterals.contains { $0.value == "A" },
                      "the representable string (address .max) must survive")
        XCTAssertFalse(machO.stringLiterals.contains { $0.value == "B" },
                       "the overflowing string (.max + 2) must be dropped, not crash the parse")
    }

    /// `__objc_selrefs` with two 8-byte pointer slots at `address == .max - 4`: slot 0 projects to
    /// `.max - 4`; slot 1 would compute `(.max - 4) + 8`, which overflows. The hardened reader drops
    /// the overflowing slot and keeps the representable one.
    func testObjectiveCReferenceRecoveryDoesNotTrapOnWrappingSectionAddress() throws {
        let image = CraftedMachO()
            .addSegment(name: "__DATA", sections: [
                .init(sectionName: "__objc_selrefs", segmentName: "__DATA",
                      address: .max - 4, size: 16, content: [UInt8](repeating: 0x01, count: 16))
            ])
        let machO = try MachOParser().parse(image.data())
        let references = machO.objectiveCMetadata.selectorReferences
        XCTAssertEqual(references.count, 1, "only the representable reference survives")
        XCTAssertEqual(references.first?.sourceAddress, .max - 4)
    }

    /// A lazy-pointer section (entry size 8, two entries) at `address == .max - 4`, with an
    /// `LC_DYSYMTAB` indirect table of two entries: the second entry's address `(.max - 4) + 8`
    /// overflows. The hardened reader drops it.
    func testIndirectSymbolRecoveryDoesNotTrapOnWrappingSectionAddress() throws {
        let image = CraftedMachO()
            .addSegment(name: "__DATA", sections: [
                .init(sectionName: "__la_symbol_ptr", segmentName: "__DATA",
                      address: .max - 4, size: 16,
                      flags: MachOConstants.sectionTypeLazySymbolPointers, reserved1: 0)
            ])
            .addDysymtabWithIndirectTable(count: 2)
        let machO = try MachOParser().parse(image.data())
        XCTAssertEqual(machO.indirectSymbols.count, 1, "only the representable indirect symbol survives")
        XCTAssertEqual(machO.indirectSymbols.first?.address, .max - 4)
    }

    // MARK: - MachOExceptionMetadata.totalByteCount: a wrapping size sum must saturate, not trap

    /// Two recognized exception sections whose sizes sum past `UInt64.max` — `__eh_frame` at `.max`
    /// and `__gcc_except_tab` at `2`. `totalByteCount` folds `partialResult + section.size`, which
    /// TRAPS on the overflow; the hardened fold saturates at `.max`.
    func testExceptionMetadataTotalByteCountSaturatesInsteadOfTrapping() throws {
        let image = CraftedMachO()
            .addSegment(name: "__TEXT", sections: [
                .init(sectionName: "__eh_frame", segmentName: "__TEXT", address: 0, size: .max),
                .init(sectionName: "__gcc_except_tab", segmentName: "__TEXT", address: 0, size: 2)
            ])
        let machO = try MachOParser().parse(image.data())
        XCTAssertEqual(machO.exceptionMetadata.totalByteCount, .max,
                       "the overflowing byte-count sum must saturate, not trap")
    }

    // MARK: - DSYMImportService.sliceSection: Int(size) / start+size must not trap

    /// A bare DWARF Mach-O (the importer accepts a plain file, not only a `.dSYM` bundle) whose
    /// `__DWARF,__debug_info` section declares `size == UInt64.max`. `sliceSection` runs
    /// `Int(section.size)` then `start + Int(section.size)` — both TRAP on this value, BEFORE the
    /// post-read range guard. The hardened slicer returns `nil` (the section degrades to absent), so
    /// the importer surfaces a TYPED `DSYMImportError` instead of crashing.
    func testDSYMImportDoesNotTrapOnHostileDWARFSectionSize() throws {
        let uuidBytes: [UInt8] = Array(0..<16)
        let expectedUUID = MachOUUID(bytes: uuidBytes).stringValue
        let image = CraftedMachO()
            .addUUID(uuidBytes)
            .addSegment(name: "__DWARF", sections: [
                .init(sectionName: "__debug_info", segmentName: "__DWARF", address: 0, size: .max)
            ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-hostile-dwarf-\(UUID().uuidString)")
        try image.data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try DSYMImportService().importDebugSymbols(at: url, expectedUUID: expectedUUID)
        ) { error in
            XCTAssertTrue(error is DSYMImportError,
                          "a hostile __DWARF section size must surface a typed error, not trap; got \(error)")
        }
    }

    // MARK: - WorkspaceScriptingAPI read-bytes: lock the already-safe size arithmetic

    /// `read-bytes` clamps the requested count via `section.size - delta`. A near-`Int.max` section
    /// size (one that does NOT wrap the `address &+ size` selection predicate) drives that
    /// subtraction; it must clamp to the requested 16 bytes, never trap. This consumer is already
    /// overflow-safe — this test locks the invariant against regression.
    @MainActor
    func testReadBytesDoesNotTrapOnHugeSectionSize() throws {
        var metadata = BinaryMetadataSummary.empty
        metadata.uuid = "00000000-0000-0000-0000-000000000000"
        var snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "x", path: "/tmp/x", kind: "Mach-O executable",
                                   architecture: "arm64", metadata: metadata)],
            functions: [],
            instructions: [],
            xrefs: [],
            hexBytes: Data(),
            sections: [SectionSummary(id: UUID(), name: "__DATA,__data", address: 0x1000,
                                      size: 0x7FFF_FFFF_FFFF_FFFE, fileOffset: 0, isExecutable: false)]
        )
        snapshot.imageBytes = Data((0..<32).map { UInt8($0) })
        let store = WorkspaceStore(workspaceName: "x", snapshot: snapshot,
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        let api = WorkspaceScriptingAPI(store: store)
        let result = try api.execute("read-bytes", arguments: .object(["address": .int(0x1008), "count": .int(16)]))
        XCTAssertEqual(result["length"]?.intValue, 16, "a huge section.size must clamp the read, not trap")
    }
}

// MARK: - Crafted thin Mach-O builder (sections + payload + extra load commands)

/// Assembles a thin arm64 Mach-O from a declarative description: a header, a list of load-command
/// blobs, and a trailing payload region. Section `fileOffset` fields and the `LC_DYSYMTAB`
/// indirect-table offset are PATCHED at `data()` time, once the payload's absolute file offset
/// (`32 + sizeofcmds`) is known — so a section can carry real file content (or a dysymtab can point
/// at a real table) without the caller hand-computing file offsets.
///
/// Richer than `MachOParserSecurityTests`' `craftedThinMachO` (which builds a no-section segment):
/// this one emits `section_64` records and a payload, which the section CONSUMERS need to reach.
private final class CraftedMachO {
    struct SectionSpec {
        var sectionName: String
        var segmentName: String
        var address: UInt64
        var size: UInt64
        var flags: UInt32 = 0
        var reserved1: UInt32 = 0
        var reserved2: UInt32 = 0
        /// File bytes for this section; appended to the payload, with the record's `fileOffset`
        /// patched to point at them. `nil` leaves `fileOffset == 0` (consumers that read no content
        /// don't need it).
        var content: [UInt8]?
    }

    private var commandBlobs: [[UInt8]] = []
    private var payload: [UInt8] = []
    /// (blobIndex, byteOffsetWithinBlob, payloadOffset) → write `UInt32(payloadBase + payloadOffset)`.
    private var fileOffsetFixups: [(blob: Int, pos: Int, payloadOffset: Int)] = []

    @discardableResult
    func addSegment(name: String, sections: [SectionSpec]) -> CraftedMachO {
        let cmdsize = UInt32(72 + sections.count * 80)
        var blob: [UInt8] = []
        blob += Self.u32(MachOConstants.loadCommandSegment64)
        blob += Self.u32(cmdsize)
        blob += Self.fixedCString(name, length: 16)
        blob += Self.u64(0)  // vmaddr
        blob += Self.u64(0)  // vmsize
        blob += Self.u64(0)  // fileoff
        blob += Self.u64(0)  // filesize
        blob += Self.u32(7)  // maxprot
        blob += Self.u32(7)  // initprot
        blob += Self.u32(UInt32(sections.count))  // nsects
        blob += Self.u32(0)  // flags

        let blobIndex = commandBlobs.count
        for section in sections {
            let recordStart = blob.count
            blob += Self.fixedCString(section.sectionName, length: 16)  // +0  sectname
            blob += Self.fixedCString(section.segmentName, length: 16)  // +16 segname
            blob += Self.u64(section.address)                           // +32 addr
            blob += Self.u64(section.size)                              // +40 size
            let fileOffsetPos = blob.count                              // +48 offset (patched)
            blob += Self.u32(0)
            blob += Self.u32(0)                                         // +52 align
            blob += Self.u32(0)                                         // +56 reloff
            blob += Self.u32(0)                                         // +60 nreloc
            blob += Self.u32(section.flags)                            // +64 flags
            blob += Self.u32(section.reserved1)                        // +68 reserved1
            blob += Self.u32(section.reserved2)                        // +72 reserved2
            blob += Self.u32(0)                                        // +76 reserved3
            precondition(blob.count - recordStart == 80, "section_64 record must be 80 bytes")
            if let content = section.content {
                let payloadOffset = reservePayload(content)
                fileOffsetFixups.append((blob: blobIndex, pos: fileOffsetPos, payloadOffset: payloadOffset))
            }
        }
        commandBlobs.append(blob)
        return self
    }

    @discardableResult
    func addUUID(_ bytes: [UInt8]) -> CraftedMachO {
        var blob: [UInt8] = []
        blob += Self.u32(MachOConstants.loadCommandUUID)
        blob += Self.u32(24)
        blob += Array(bytes.prefix(16))
        if blob.count < 24 { blob += [UInt8](repeating: 0, count: 24 - blob.count) }
        commandBlobs.append(blob)
        return self
    }

    /// An `LC_DYSYMTAB` whose indirect symbol table is `count` zeroed `UInt32` entries placed in the
    /// payload; `indirectsymoff` (record offset +56) is patched to the table's file offset.
    @discardableResult
    func addDysymtabWithIndirectTable(count: UInt32) -> CraftedMachO {
        let payloadOffset = reservePayload([UInt8](repeating: 0, count: Int(count) * 4))
        var blob = [UInt8](repeating: 0, count: 80)
        Self.write(&blob, at: 0, Self.u32(MachOConstants.loadCommandDysymtab))
        Self.write(&blob, at: 4, Self.u32(80))                 // cmdsize
        Self.write(&blob, at: 60, Self.u32(count))             // nindirectsyms
        let blobIndex = commandBlobs.count
        fileOffsetFixups.append((blob: blobIndex, pos: 56, payloadOffset: payloadOffset)) // indirectsymoff
        commandBlobs.append(blob)
        return self
    }

    func data() -> Data {
        let sizeofcmds = commandBlobs.reduce(0) { $0 + $1.count }
        let payloadBase = 32 + sizeofcmds
        for fixup in fileOffsetFixups {
            Self.write(&commandBlobs[fixup.blob], at: fixup.pos, Self.u32(UInt32(payloadBase + fixup.payloadOffset)))
        }

        var out: [UInt8] = []
        out += Self.u32(MachOConstants.machMagic64)
        out += Self.u32(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        out += Self.u32(0)                                // cpusubtype
        out += Self.u32(MachOConstants.fileTypeExecute)   // filetype
        out += Self.u32(UInt32(commandBlobs.count))       // ncmds
        out += Self.u32(UInt32(sizeofcmds))               // sizeofcmds
        out += Self.u32(0)                                // flags
        out += Self.u32(0)                                // reserved
        for blob in commandBlobs { out += blob }
        out += payload
        return Data(out)
    }

    // MARK: byte helpers

    private func reservePayload(_ bytes: [UInt8]) -> Int {
        let offset = payload.count
        payload += bytes
        return offset
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
    }
    private static func u64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xff) }
    }
    private static func fixedCString(_ string: String, length: Int) -> [UInt8] {
        var field = Array(string.utf8.prefix(length))
        if field.count < length { field += [UInt8](repeating: 0, count: length - field.count) }
        return Array(field.prefix(length))
    }
    private static func write(_ buffer: inout [UInt8], at offset: Int, _ bytes: [UInt8]) {
        for (i, byte) in bytes.enumerated() { buffer[offset + i] = byte }
    }
}
