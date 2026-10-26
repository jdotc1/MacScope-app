import Foundation
import XCTest
@testable import MacScope

/// Cache images whose nlist table can't be projected still name their exported functions from
/// the image's exports trie (live check: libz functions showed as sub_0x… instead of deflate).
final class DyldCacheSymbolNamingTests: XCTestCase {
    func testExternalDirectCallKeepsAddressAndOwnedName() throws {
        let fixture = DyldCallFixture.make()
        let loaded = try fixture.load()
        let snapshot = try analyze(loaded)
        let call = try XCTUnwrap(snapshot.xrefs.first { $0.kind == XRefKind.call && $0.from == fixture.call })
        XCTAssertEqual(call.to, fixture.target)
        XCTAssertEqual(snapshot.symbolizedLabel(for: call.to), "_ownedTarget")
        XCTAssertFalse(snapshot.functions.contains { $0.startAddress == fixture.target })
        XCTAssertEqual(loaded.symbols.first { $0.address == fixture.target }?.libraryName, "/usr/lib/libTarget.dylib")
    }

    func testAuthStubAndIslandResolveOnlyWithCompleteEvidence() throws {
        let fixture = DyldCallFixture.make(authStub: true)
        let snapshot = try analyze(fixture.load())
        let call = try XCTUnwrap(snapshot.xrefs.first { $0.kind == XRefKind.call && $0.from == fixture.call })
        XCTAssertEqual(call.to, fixture.stub)
        XCTAssertEqual(snapshot.symbolizedLabel(for: call.to), "_ownedTarget")
        XCTAssertFalse(snapshot.functions.contains { $0.startAddress == fixture.target })
        let ordinary = DyldCallFixture.make(authStub: true, authenticatedPointer: false)
        let ordinaryResult = try analyze(ordinary.load())
        let ordinaryCall = try XCTUnwrap(ordinaryResult.xrefs.first { $0.kind == XRefKind.call && $0.from == ordinary.call })
        XCTAssertEqual(ordinaryCall.to, ordinary.stub)
        XCTAssertEqual(ordinaryResult.symbolizedLabel(for: ordinaryCall.to), "_ownedTarget")
        for fault in 0..<5 {
            var damaged = fixture
            switch fault {
            case 0: damaged.bytes.replaceLocalU32(at: 0x400, value: 99)
            case 1: damaged.bytes.replaceLocalU32(at: 0x3840, value: 0x14000000) // island cycle
            case 2: damaged.bytes.replaceLocalU32(at: 0x1848, value: 0xd503201f) // no loaded pointer
            case 3:
                damaged.bytes.replaceLocalU64(at: 0x1f80, value: (UInt64(1) << 63) | (1 << 50) | (7 << 34) | 0x10840)
            default:
                // Authenticated LDR -> ADD #0 -> BR must not erase authentication evidence.
                damaged.bytes.replaceLocalU32(at: 0x184c, value: 0x91000210)
                damaged.bytes.replaceLocalU32(at: 0x1850, value: 0xd61f0200)
            }
            let result = try analyze(damaged.load())
            let refused = try XCTUnwrap(result.xrefs.first { $0.kind == XRefKind.call && $0.from == fixture.call })
            XCTAssertEqual(refused.to, fixture.stub)
            XCTAssertNotEqual(result.symbolizedLabel(for: refused.to), "_ownedTarget", "fault \(fault)")
        }
    }

    func testOwnedLocalSymbolNamesRecoveredProcedureWithoutImageSymtab() throws {
        let fixture = DyldLocalSymbolFixture.make()
        let loaded = try fixture.load()
        XCTAssertTrue(loaded.exports.isEmpty)
        XCTAssertEqual(loaded.symbols.map(\.name), ["_ownedLocal"])
        let snapshot = try analyze(loaded)
        XCTAssertEqual(snapshot.functions.first { $0.startAddress == fixture.textAddress }?.name, "_ownedLocal")
        XCTAssertFalse(loaded.loaderFindings.contains { $0.code == "cacheLocalSymbolsUnavailable" })
    }

    func testOtherImageLocalSymbolsCannotNameSelectedProcedure() throws {
        let fixture = DyldLocalSymbolFixture.make(onlyOtherImage: true)
        let loaded = try fixture.load()
        let snapshot = try analyze(loaded)
        XCTAssertFalse(loaded.symbols.contains { $0.name == "_otherImage" })
        XCTAssertFalse(snapshot.functions.contains { $0.name == "_otherImage" })
        XCTAssertNotNil(snapshot.functions.first { $0.startAddress == fixture.textAddress })
    }

    func testMissingSymbolsPreservesExportNamingAndUnavailableCoverage() throws {
        let fixture = DyldLocalSymbolFixture.make(exportName: "_exported")
        let loaded = try fixture.load(includeCompanion: false)
        XCTAssertEqual(loaded.exports.first?.name, "_exported")
        XCTAssertEqual(try analyze(loaded).functions.first { $0.startAddress == fixture.textAddress }?.name, "_exported")
        XCTAssertTrue(loaded.loaderFindings.contains { $0.code == "cacheLocalSymbolsUnavailable" })
    }

    func testNamePrecedenceKeepsUserThenEmbeddedThenExportThenLocal() throws {
        let local = DyldLocalSymbolFixture.make()
        let loaded = try local.load()
        let renamed = try analyze(loaded, overrides: [local.textAddress: AddressOverride(customName: "userEntry")])
        let procedure = try XCTUnwrap(renamed.functions.first { $0.startAddress == local.textAddress })
        // Authored names overlay the recovered name; they do not replace source metadata.
        XCTAssertEqual(procedure.name, "_ownedLocal")
        XCTAssertEqual(renamed.displayName(at: procedure.startAddress, default: procedure.name), "userEntry")
        let exported = DyldLocalSymbolFixture.make(exportName: "_exported")
        XCTAssertEqual(try analyze(exported.load()).functions.first { $0.startAddress == exported.textAddress }?.name, "_exported")
        let embedded = DyldLocalSymbolFixture.make(keepEmbedded: true)
        XCTAssertEqual(try analyze(embedded.load()).functions.first { $0.startAddress == embedded.textAddress }?.name, "_fixtureEntry")
    }

    func testMismatchedAndAmbiguousLocalSymbolsStayUnavailable() throws {
        for ambiguous in [false, true] {
            var fixture = DyldLocalSymbolFixture.make()
            if ambiguous {
                // Another owner may not share the selected nlist range.
                fixture.companion.replaceLocalU32(at: 0x200 + 24 + 16 + 8, value: 0)
            } else {
                fixture.companion[0x58] ^= 1
            }
            let loaded = try fixture.load()
            XCTAssertTrue(loaded.symbols.isEmpty)
            XCTAssertTrue(loaded.loaderFindings.contains { $0.code == "cacheLocalSymbolsUnavailable" })
        }
    }

    private func analyze(_ binary: LoadedBinary, overrides: [UInt64: AddressOverride] = [:]) throws -> WorkspaceSnapshot {
        try AnalysisEngine(loader: LocalSymbolFixtureLoader(binary: binary))
            .analyze(url: URL(fileURLWithPath: "/tmp/cache"), selection: .automatic, overrides: overrides)
    }

    func testExportsNameAddressesTheSymbolTableLeavesUnnamed() {
        let nlist = [SymbolSummary(id: UUID(), name: "_crc32", address: 0x2000, kind: "export", libraryName: nil,
                                   rawLinkageName: "_crc32")]
        let merged = DyldSharedCacheBinaryLoader.namingSymbols(symbols: nlist, exports: [
            (name: "_inflate", address: 0x3000),
            (name: "_crc32_alias", address: 0x2000),   // already named by nlist: kept as is
            (name: "_deflate", address: 0x1000),
            (name: "_reexported", address: nil),        // no address: nothing to name
            (name: "_deflate_alias", address: 0x1000),  // second name at one address: first by name wins
        ])
        XCTAssertEqual(merged.map(\.name), ["_crc32", "_deflate", "_deflate_alias", "_inflate"].filter { $0 != "_deflate_alias" })
        XCTAssertEqual(merged.first { $0.name == "_deflate" }?.address, 0x1000)
        XCTAssertEqual(merged.first { $0.name == "_inflate" }?.kind, MachOSymbolKind.export.rawValue)
        XCTAssertEqual(merged.first { $0.name == "_inflate" }?.rawLinkageName, "_inflate")
    }

    func testFixtureImageKeepsItsSymbolTableNames() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let loaded = try DyldSharedCacheBinaryLoader().loadFromBytes(fixture.bytes, name: "cache", path: "/tmp/cache")
        XCTAssertTrue(loaded.symbols.contains { $0.name == "_fixtureEntry" })
    }
}

private struct LocalSymbolFixtureLoader: BinaryLoader {
    let binary: LoadedBinary
    func load(at url: URL) throws -> LoadedBinary { binary }
}

/// A true unmapped local-symbol companion, separate from LC_SYMTAB and exports.
struct DyldLocalSymbolFixture {
    var main: Data
    var companion: Data
    var textAddress: UInt64

    func load(includeCompanion: Bool = true) throws -> LoadedBinary {
        try DyldSharedCacheBinaryLoader().loadFromBytes(main, name: "cache", path: "/tmp/cache",
            symbolCompanionData: includeCompanion ? companion : nil)
    }

    static func make(onlyOtherImage: Bool = false, exportName: String? = nil,
                     keepEmbedded: Bool = false) -> DyldLocalSymbolFixture {
        let original = DyldCacheFixture.makeSingleImageCache()
        var main = original.bytes
        let uuid = Array(repeating: UInt8(0x5A), count: 16)
        main.replaceSubrange(0x190..<0x1A0, with: uuid)
        main.replaceLocalU64(at: 0xE0, value: original.imageVMAddress)
        let symtab = original.imageFileOffset + 32 + 152
        if !keepEmbedded {
            for offset in [8, 12, 16, 20] { main.replaceLocalU32(at: symtab + offset, value: 0) }
        }
        if let exportName {
            // Reuse the 24-byte command slot as LC_DYLD_EXPORTS_TRIE; the trailing
            // eight bytes remain padding in the command. One bounded trie terminal.
            let edge = Array(exportName.utf8) + [0]
            let child = 2 + edge.count + 1
            precondition(child < 128)
            var address = original.textVMAddress - original.imageVMAddress
            var encoded: [UInt8] = []
            repeat {
                var byte = UInt8(address & 0x7f)
                address >>= 7
                if address != 0 { byte |= 0x80 }
                encoded.append(byte)
            } while address != 0
            let trie = Data([0, 1] + edge + [UInt8(child), UInt8(1 + encoded.count), 0] + encoded + [0])
            let offset = main.count
            main.append(trie)
            main.replaceLocalU32(at: symtab, value: MachOConstants.loadCommandDyldExportsTrie)
            main.replaceLocalU32(at: symtab + 8, value: UInt32(offset))
            main.replaceLocalU32(at: symtab + 12, value: UInt32(trie.count))
            main.replaceLocalU64(at: original.mappingOffset + 8, value: UInt64(main.count - original.imageFileOffset))
            main.replaceLocalU64(at: original.imageFileOffset + 32 + 32, value: UInt64(main.count - original.imageFileOffset))
            main.replaceLocalU64(at: original.imageFileOffset + 32 + 48, value: UInt64(main.count - original.imageFileOffset))
        }
        let base = 0x200, entries = 24, nlists = 56, strings = 88
        let table = Data([0] + Array("_ownedLocal".utf8) + [0] + Array("_otherImage".utf8) + [0])
        var companion = Data(repeating: 0, count: base + strings + table.count)
        // Fifteen magic bytes plus one NUL must preserve the 16-byte header field.
        companion.replaceSubrange(0..<16, with: Array("dyld_v1  arm64e".utf8) + [0])
        companion.replaceLocalU32(at: 16, value: 0x200) // header extent, zero mappings
        companion.replaceSubrange(0x58..<0x68, with: uuid)
        companion.replaceLocalU64(at: 0x48, value: UInt64(base))
        companion.replaceLocalU64(at: 0x50, value: UInt64(companion.count - base))
        for (field, value) in [(0, nlists), (4, 2), (8, strings), (12, table.count), (16, entries), (20, 2)] {
            companion.replaceLocalU32(at: base + field, value: UInt32(value))
        }
        companion.replaceLocalU64(at: base + entries, value: onlyOtherImage ? 0x2000 : 0)
        companion.replaceLocalU32(at: base + entries + 8, value: 0)
        companion.replaceLocalU32(at: base + entries + 12, value: 1)
        companion.replaceLocalU64(at: base + entries + 16, value: 0x1000)
        companion.replaceLocalU32(at: base + entries + 24, value: 1)
        companion.replaceLocalU32(at: base + entries + 28, value: 1)
        for index in 0..<2 {
            let at = base + nlists + index * 16
            companion.replaceLocalU32(at: at, value: index == 0 ? 1 : 13)
            companion[at + 4] = 0x0e
            companion[at + 5] = 1
            // Both names target the selected code address. Only ownership may decide.
            companion.replaceLocalU64(at: at + 8, value: original.textVMAddress)
        }
        companion.replaceSubrange((base + strings)..<companion.count, with: table)
        return DyldLocalSymbolFixture(main: main, companion: companion, textAddress: original.textVMAddress)
    }
}

private extension Data {
    mutating func replaceLocalU32(at offset: Int, value: UInt32) {
        for index in 0..<4 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    mutating func replaceLocalU64(at offset: Int, value: UInt64) {
        for index in 0..<8 { self[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}


struct DyldCallFixture {
    static let base: UInt64 = 0x1_8000_0000
    var bytes: Data
    let call: UInt64
    let stub: UInt64
    let target: UInt64
    let slot: UInt64

    func load() throws -> LoadedBinary {
        try DyldSharedCacheBinaryLoader(targetImagePath: "/usr/lib/libCaller.dylib")
            .loadFromBytes(bytes, name: "cache", path: "/tmp/cache")
    }

    static func make(authStub: Bool = false, slideVersion: UInt32 = 5,
                     pointerToSelected: Bool = false, diversity: UInt16 = 0, key: UInt8 = 0,
                     authenticatedPointer: Bool = true) -> Self {
        var data = Data(repeating: 0, count: 0x5000)
        func u32(_ offset: Int, _ value: UInt32) { data.replaceLocalU32(at: offset, value: value) }
        func u64(_ offset: Int, _ value: UInt64) { data.replaceLocalU64(at: offset, value: value) }
        func string(_ offset: Int, _ value: String) {
            data.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
        }
        string(0, "dyld_v1  arm64e")
        u32(16, 0x200); u32(20, 2); u32(24, 0x240); u32(28, 2); u64(0xe0, base)
        u32(0x138, 0x300); u32(0x13c, 2)
        for index in 0..<2 {
            let address = base + UInt64(index) * 0x10000
            let file = 0x1000 + index * 0x2000
            let map = 0x200 + index * 32
            u64(map, address); u64(map + 8, 0x2000); u64(map + 16, UInt64(file))
            u32(map + 24, 5); u32(map + 28, 5)
            let slide = 0x300 + index * 56
            u64(slide, address); u64(slide + 8, 0x2000); u64(slide + 16, UInt64(file))
            u32(slide + 48, 5); u32(slide + 52, 5)
            if index == 0 { u64(slide + 24, 0x400); u64(slide + 32, 28) }
            u64(0x240 + index * 32, address); u32(0x258 + index * 32, UInt32(0x280 + index * 48))
            string(0x280 + index * 48, index == 0 ? "/usr/lib/libCaller.dylib" : "/usr/lib/libTarget.dylib")
            let sections: [(String, Int, Int, UInt32)] = index == 0
                ? [("__text", 0x800, 8, 0x80000400), (authenticatedPointer ? "__auth_stubs" : "__stubs", 0x840, 24, 0x80000408), ("__got", 0xf80, 8, 0)]
                : [("__text", 0x800, 0x44, 0x80000400)]
            let segmentSize = 72 + sections.count * 80
            let commandSize = segmentSize + 24 + (index == 1 ? 16 : 0)
            u32(file, 0xfeedfacf); u32(file + 4, 0x0100000c); u32(file + 12, 6)
            u32(file + 16, index == 1 ? 3 : 2); u32(file + 20, UInt32(commandSize))
            let segment = file + 32
            u32(segment, 0x19); u32(segment + 4, UInt32(segmentSize)); string(segment + 8, "__TEXT")
            u64(segment + 24, address); u64(segment + 32, 0x2000)
            u64(segment + 40, UInt64(file)); u64(segment + 48, 0x2000)
            u32(segment + 56, 5); u32(segment + 60, 5); u32(segment + 64, UInt32(sections.count))
            for (s, section) in sections.enumerated() {
                let record = segment + 72 + s * 80
                string(record, section.0); string(record + 16, "__TEXT")
                u64(record + 32, address + UInt64(section.1)); u64(record + 40, UInt64(section.2))
                u32(record + 48, UInt32(file + section.1)); u32(record + 52, 2); u32(record + 64, section.3)
                if section.3 & 0xff == 8 { u32(record + 72, 24) }
            }
            let uuid = segment + segmentSize
            u32(uuid, 0x1b); u32(uuid + 4, 24)
            data.replaceSubrange((uuid + 8)..<(uuid + 24), with: repeatElement(UInt8(index + 1), count: 16))
            if index == 1 {
                let name = Array("_ownedTarget".utf8) + [0]
                let trie = [UInt8(0), 1] + name + [UInt8(3 + name.count), 3, 0, 0x80, 0x10, 0]
                u32(uuid + 24, 0x80000033); u32(uuid + 28, 16)
                u32(uuid + 32, UInt32(file + 0xf00)); u32(uuid + 36, UInt32(trie.count))
                data.replaceSubrange((file + 0xf00)..<(file + 0xf00 + trie.count), with: trie)
            }
        }
        u32(0x400, slideVersion); u32(0x404, 4096); u32(0x408, 2); u64(0x410, base)
        data[0x418] = 0x80; data[0x419] = 0x0f; data[0x41a] = 0xff; data[0x41b] = 0xff
        let targetOffset: UInt64 = pointerToSelected ? 0x800 : 0x10840
        var raw = targetOffset
        if authenticatedPointer {
            raw |= UInt64(1) << 63
            if slideVersion == 3 { raw |= UInt64(diversity) << 32 | (1 << 48) | UInt64(key) << 49 }
            else { raw |= UInt64(diversity) << 34 | (1 << 50) | UInt64(key == 2 ? 1 : 0) << 51 }
        } else if slideVersion == 3 { raw = base + targetOffset }
        u64(0x1f80, raw)
        u32(0x1800, authStub ? 0x94000010 : 0x94004000); u32(0x1804, 0xd65f03c0)
        u32(0x1840, 0x90000011); u32(0x1844, 0x913e0231)
        u32(0x1848, 0xf9400230); u32(0x184c, authenticatedPointer ? 0xd71f0a11 : 0xd61f0200)
        u32(0x3800, 0xd65f03c0); u32(0x3840, 0x17fffff0)
        return Self(bytes: data, call: base + 0x800, stub: base + 0x840,
                    target: base + 0x10800, slot: base + 0xf80)
    }
}
