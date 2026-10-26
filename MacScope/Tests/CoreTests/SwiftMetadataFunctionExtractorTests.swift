import Foundation
import XCTest
@testable import MacScope

final class SwiftMetadataFunctionExtractorTests: XCTestCase {
    func testCompiledFixtureRecoversEachFunctionBearingMetadataForm() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws9swift-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try WS9SwiftFunctionFixture.require(in: directory)
        let loaded = try MachOBinaryLoader().load(at: url)
        let candidates = SwiftMetadataFunctionExtractor.functionCandidates(in: loaded)
        let oracle = Set(loaded.functionStarts)

        let expected: [(label: String, predicate: (String) -> Bool)] = [
            ("class vtable method", { $0.hasSuffix("4BaseC5greetSiyF") }),
            ("class override-table method", { $0.hasSuffix("7DerivedC5greetSiyF") }),
            ("nominal metadata accessor", { $0.hasSuffix("4BaseCMa") }),
            ("protocol witness", {
                $0.contains("4BaseC") && $0.hasSuffix("DP5greetSiyFTW")
            }),
        ]

        for expectedForm in expected {
            let address = try uniqueSymbolAddress(
                in: loaded,
                label: expectedForm.label,
                matching: expectedForm.predicate
            )
            XCTAssertTrue(
                oracle.contains(address),
                "\(expectedForm.label) is not in LC_FUNCTION_STARTS: \(address.hexAddress)"
            )
            XCTAssertTrue(
                candidates.contains(address),
                "\(expectedForm.label) missing from candidates: \(address.hexAddress)"
            )
        }
        let base = try XCTUnwrap(loaded.swiftTypes.first { $0.name == "Base" })
        let derived = try XCTUnwrap(loaded.swiftTypes.first { $0.name == "Derived" })
        let baseMethod = try uniqueSymbolAddress(in: loaded, label: "base", matching: { $0.hasSuffix("4BaseC5greetSiyF") })
        let overrideAddress = try uniqueSymbolAddress(in: loaded, label: "override", matching: { $0.hasSuffix("7DerivedC5greetSiyF") })
        XCTAssertTrue(base.methods?.contains { $0.source == .vtable && $0.implementation == baseMethod } == true)
        XCTAssertTrue(derived.methods?.contains { $0.source == .override && $0.implementation == overrideAddress } == true)
        XCTAssertFalse(base.methods?.contains { $0.implementation == overrideAddress } == true)
        let witness = try uniqueSymbolAddress(in: loaded, label: "witness", matching: {
            $0.contains("4BaseC") && $0.hasSuffix("DP5greetSiyFTW")
        })
        let conformance = try XCTUnwrap(loaded.swiftConformances.first { $0.typeName == "Base" && $0.protocolName == "Greeter" })
        XCTAssertEqual(conformance.typeDescriptorAddress, base.descriptorAddress)
        XCTAssertNotNil(conformance.descriptorAddress)
        XCTAssertTrue(conformance.methods?.contains { $0.implementation == witness } == true)
    }

    func testVTableLinksKeepOwnerSlotsAndUnknownImplementations() throws {
        var loaded = Self.classPropertyAccessorFixture()
        let original = try XCTUnwrap(Self.metadataParser(loaded).parseTypes().first)
        XCTAssertEqual(original.descriptorAddress, 0x1020)
        XCTAssertEqual(original.methods?.map(\.implementation), [0x2000, 0x2004, 0x2008])
        XCTAssertEqual(original.methods?.map(\.descriptorAddress), [0x1054, 0x105c, 0x1064])
        XCTAssertEqual(original.methods?.map(\.isInstance), [true, true, true])
        XCTAssertFalse(original.methods?.contains { $0.implementation == 0x200c } == true,
                       "metadata accessors are discovery candidates, not member methods")

        var bytes = [UInt8](loaded.bytes)
        Self.writeUInt32(0, in: &bytes, at: 0x60) // unresolved second implementation
        Self.writeUInt32(0x54, in: &bytes, at: 0x64) // third record refers to coroutine data
        loaded.bytes = Data(bytes)
        let unknown = try XCTUnwrap(Self.metadataParser(loaded).parseTypes().first?.methods)
        XCTAssertEqual(unknown.count, 3)
        XCTAssertEqual(unknown.map(\.implementation), [0x2000, nil, nil])
        XCTAssertEqual(unknown.map(\.index), [0, 1, 2])
    }

    func testVTableLinksRejectNonExecutableZeroFillAndUnsupportedGenericTails() throws {
        var loaded = Self.classPropertyAccessorFixture()
        loaded.sections = loaded.sections.map { section in var s = section; s.isExecutable = false; return s }
        XCTAssertTrue(try XCTUnwrap(Self.metadataParser(loaded).parseTypes().first?.methods).allSatisfy { $0.implementation == nil })
        loaded = Self.classPropertyAccessorFixture()
        loaded.sections = loaded.sections.map { section in var s = section; if s.isExecutable { s.isZeroFill = true }; return s }
        XCTAssertTrue(try XCTUnwrap(Self.metadataParser(loaded).parseTypes().first?.methods).allSatisfy { $0.implementation == nil })
        loaded = Self.classPropertyAccessorFixture()
        var bytes = [UInt8](loaded.bytes)
        Self.writeUInt32(0x8000_00d0, in: &bytes, at: 0x20) // generic class: variable tail is unknown
        loaded.bytes = Data(bytes)
        XCTAssertNil(Self.metadataParser(loaded).parseTypes().first?.methods)
    }

    func testWitnessLinksUseDescriptorOwnershipAndRebasesButBindingsStayUnknown() throws {
        let fixture = Self.witnessFixture()
        let rebases: [UInt64: UInt64] = [0x1190: 0x2004]
        let parser = Self.metadataParser(fixture, rebases: rebases)
        let conformance = try XCTUnwrap(parser.parseConformances().first)
        XCTAssertEqual(conformance.typeDescriptorAddress, 0x1080)
        XCTAssertEqual(conformance.descriptorAddress, 0x1100)
        XCTAssertEqual(conformance.methods?.map(\.implementation), [0x2000, 0x2004, nil])
        XCTAssertEqual(conformance.methods?.map(\.descriptorAddress), [0x1058, 0x1060, 0x1068])
        let bound = Self.metadataParser(fixture, rebases: rebases, binds: [0x1190: "_external"])
        XCTAssertEqual(bound.parseConformances().first?.methods?.map(\.implementation), [0x2000, nil, nil])
    }

    func testRelativeIndirectAndRuntimeInstantiatedWitnessLayoutsStayUnknown() {
        for flags in [UInt32(1 << 16), UInt32(1 << 17)] {
            let parser = Self.metadataParser(Self.witnessFixture(flags: flags))
            XCTAssertEqual(parser.parseConformances().count, 1)
            XCTAssertNil(parser.parseConformances().first?.methods)
        }
        var fixture = Self.witnessFixture()
        var bytes = [UInt8](fixture.bytes)
        Self.writeUInt32(UInt32(bitPattern: -128), in: &bytes, at: 0x180) // relative header, not absolute
        fixture.bytes = Data(bytes)
        XCTAssertNil(Self.metadataParser(fixture).parseConformances().first?.methods)
        fixture = Self.witnessFixture()
        bytes = [UInt8](fixture.bytes)
        Self.writeUInt32(0x101, in: &bytes, at: 0x100) // indirect protocol through slot 0x1200
        fixture.bytes = Data(bytes)
        let indirect = Self.metadataParser(fixture, rebases: [0x1200: 0x1040])
        XCTAssertEqual(indirect.parseConformances().first?.protocolName, "P")
        XCTAssertNil(indirect.parseConformances().first?.methods)
    }

    private static func metadataParser(_ loaded: LoadedBinary, rebases: [UInt64: UInt64] = [:],
                                       binds: [UInt64: String] = [:]) -> SwiftMetadataParser {
        SwiftMetadataParser(data: loaded.bytes, sections: loaded.sections.map {
            .init(name: String($0.name.split(separator: ",").last ?? ""), address: $0.address,
                  fileOffset: $0.fileOffset, size: $0.size, isExecutable: $0.isExecutable, isZeroFill: $0.isZeroFill)
        }, rebaseTargets: rebases, bindNames: binds)
    }

    private static func witnessFixture(flags: UInt32 = 0) -> LoadedBinary {
        var bytes = [UInt8](repeating: 0, count: 0x40c)
        func relative(_ slot: Int, _ target: UInt64) {
            writeRelativePointer(in: &bytes, fieldVA: 0x1000 + UInt64(slot), targetVA: target, fileOffset: slot)
        }
        relative(0, 0x1100); relative(4, 0x1080)
        writeUInt32(3, in: &bytes, at: 0x40); relative(0x48, 0x10c0)
        writeUInt32(3, in: &bytes, at: 0x50) // three requirements
        writeUInt32(0x11, in: &bytes, at: 0x58)
        writeUInt32(0x13, in: &bytes, at: 0x60)
        writeUInt32(0x31, in: &bytes, at: 0x68) // async method: data target is not a method IMP
        writeUInt32(17, in: &bytes, at: 0x80); relative(0x88, 0x10d0)
        bytes[0xc0...0xc1] = [0x50, 0]; bytes[0xd0...0xd1] = [0x53, 0]
        relative(0x100, 0x1040); relative(0x104, 0x1080); relative(0x108, 0x1180)
        writeUInt32(flags, in: &bytes, at: 0x10c)
        writeUInt32(0x1100, in: &bytes, at: 0x180)
        writeUInt32(0x2000, in: &bytes, at: 0x188)
        writeUInt32(0xdead, in: &bytes, at: 0x190)
        writeUInt32(0x2008, in: &bytes, at: 0x198)
        let text = BinarySection(name: "__TEXT,__text", address: 0x2000, size: 12, fileOffset: 0x400, isExecutable: true)
        return loadedBinary(bytes: Data(bytes), sections: [
            BinarySection(name: "__TEXT,__swift5_proto", address: 0x1000, size: 4, fileOffset: 0, isExecutable: false),
            BinarySection(name: "__TEXT,__swift5_types", address: 0x1004, size: 4, fileOffset: 4, isExecutable: false),
            BinarySection(name: "__TEXT,__const", address: 0x1000, size: 0x400, fileOffset: 0, isExecutable: false), text,
        ], executableTextSection: text)
    }

    func testClassVTableRecoversPropertyAccessorsWhenDescriptorsNameThem() {
        let loaded = Self.classPropertyAccessorFixture()

        XCTAssertEqual(
            SwiftMetadataFunctionExtractor.functionCandidates(in: loaded),
            [0x2_000, 0x2_004, 0x2_008, 0x2_00c]
        )
    }

    func testCompiledFixtureMateriallyRaisesHeldOutCoverage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws9swift-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try WS9SwiftFunctionFixture.require(in: directory)
        let loaded = try MachOBinaryLoader().load(at: url)
        XCTAssertFalse(SwiftMetadataFunctionExtractor.functionCandidates(in: loaded).isEmpty)

        let report = try FunctionStartCoverage.measure(url: url)
        XCTAssertGreaterThan(
            report.coverage,
            0.60,
            "held-out recovery was \(report.recovered)/\(report.total); "
                + "missed \(report.missed.map(\.hexAddress))"
        )
        if report.total == 41 {
            XCTAssertGreaterThan(report.recovered, 22, "extractor did not improve the measured Phase A baseline")
        }

        print(
            "[WS-9] Swift fixture held-out coverage AFTER extractor: "
                + "\(report.recovered)/\(report.total) = "
                + String(format: "%.3f", report.coverage)
                + " (missed \(report.missed.count))"
        )
    }

    func testMalformedMetadataAndOverflowingSliceOffsetYieldNoCandidates() {
        let bytes = Data([
            0xff, 0xff, 0xff, 0x7f, // __swift5_types: dangling Int32.max relative pointer
            0x00, 0x00, 0x00, 0x80, // __swift5_proto: dangling Int32.min relative pointer
            0xc0, 0x03, 0x5f, 0xd6, // harmless arm64 `ret` in executable text
        ])
        let types = BinarySection(
            name: "__TEXT,__swift5_types", address: 0x1_000, size: 4,
            fileOffset: 0, isExecutable: false
        )
        let conformances = BinarySection(
            name: "__TEXT,__swift5_proto", address: 0x2_000, size: 4,
            fileOffset: 4, isExecutable: false
        )
        let text = BinarySection(
            name: "__TEXT,__text", address: 0x4_000, size: 4,
            fileOffset: 8, isExecutable: true
        )
        var loaded = Self.loadedBinary(
            bytes: bytes,
            sections: [types, conformances, text],
            executableTextSection: text
        )

        XCTAssertTrue(SwiftMetadataFunctionExtractor.functionCandidates(in: loaded).isEmpty)

        loaded.sliceOffset = UInt64.max - 1
        XCTAssertTrue(SwiftMetadataFunctionExtractor.functionCandidates(in: loaded).isEmpty)
    }

    func testNonSwiftBinaryYieldsNoCandidates() {
        let text = BinarySection(
            name: "__TEXT,__text", address: 0x4_000, size: 4,
            fileOffset: 0, isExecutable: true
        )
        let loaded = Self.loadedBinary(
            bytes: Data([0xc0, 0x03, 0x5f, 0xd6]),
            sections: [text],
            executableTextSection: text
        )

        XCTAssertTrue(SwiftMetadataFunctionExtractor.functionCandidates(in: loaded).isEmpty)
    }

    func testExtractionIsDeterministic() {
        let loaded = Self.classPropertyAccessorFixture()

        XCTAssertEqual(
            SwiftMetadataFunctionExtractor.functionCandidates(in: loaded),
            SwiftMetadataFunctionExtractor.functionCandidates(in: loaded)
        )
    }

    private func uniqueSymbolAddress(
        in loaded: LoadedBinary,
        label: String,
        matching predicate: (String) -> Bool
    ) throws -> UInt64 {
        let matches = Set(loaded.symbols.compactMap { symbol -> UInt64? in
            guard predicate(symbol.name) else { return nil }
            return symbol.address
        })
        return try XCTUnwrap(
            matches.count == 1 ? matches.first : nil,
            "\(label): expected one unique symbol address, got \(matches.map(\.hexAddress).sorted())"
        )
    }

    /// One non-generic class descriptor whose vtable contains getter, setter, and modify records.
    /// The common nominal prefix also names a metadata accessor. VAs and file offsets deliberately
    /// differ, so the test exercises VA-to-file mapping rather than relying on identity addressing.
    private static func classPropertyAccessorFixture() -> LoadedBinary {
        let metadataBase: UInt64 = 0x1_000
        let typesVA = metadataBase
        let descriptorVA: UInt64 = 0x1_020
        let typeNameVA: UInt64 = 0x1_080
        let textVA: UInt64 = 0x2_000
        let textFileOffset = 0x100
        var bytes = [UInt8](repeating: 0, count: textFileOffset + 16)

        writeRelativePointer(in: &bytes, fieldVA: typesVA, targetVA: descriptorVA, fileOffset: 0)
        // ContextDescriptorFlags: class (16), unique (0x40), class_hasVTable (kind bit 15).
        writeUInt32(0x8000_0050, in: &bytes, at: 0x20)
        writeRelativePointer(in: &bytes, fieldVA: descriptorVA + 8, targetVA: typeNameVA, fileOffset: 0x28)
        writeRelativePointer(in: &bytes, fieldVA: descriptorVA + 12, targetVA: textVA + 12, fileOffset: 0x2c)
        bytes[0x80...0x83] = [0x42, 0x6f, 0x78, 0x00] // "Box\0"

        // Fixed class descriptor size is 44 bytes. Vtable header: offset=0, count=3.
        writeUInt32(3, in: &bytes, at: 0x50)
        let methodRecords: [(flags: UInt32, target: UInt64)] = [
            (0x12, textVA),     // instance getter
            (0x13, textVA + 4), // instance setter
            (0x14, textVA + 8), // instance modify coroutine
        ]
        for (index, record) in methodRecords.enumerated() {
            let recordOffset = 0x54 + index * 8
            let recordVA = descriptorVA + 52 + UInt64(index * 8)
            writeUInt32(record.flags, in: &bytes, at: recordOffset)
            writeRelativePointer(
                in: &bytes,
                fieldVA: recordVA + 4,
                targetVA: record.target,
                fileOffset: recordOffset + 4
            )
        }
        for offset in stride(from: textFileOffset, to: textFileOffset + 16, by: 4) {
            bytes[offset...(offset + 3)] = [0xc0, 0x03, 0x5f, 0xd6]
        }

        let types = BinarySection(
            name: "__TEXT,__swift5_types", address: typesVA, size: 4,
            fileOffset: 0, isExecutable: false
        )
        let metadata = BinarySection(
            name: "__TEXT,__constg_swiftt", address: metadataBase, size: UInt64(textFileOffset),
            fileOffset: 0, isExecutable: false
        )
        let text = BinarySection(
            name: "__TEXT,__text", address: textVA, size: 16,
            fileOffset: UInt64(textFileOffset), isExecutable: true
        )
        return loadedBinary(
            bytes: Data(bytes),
            sections: [types, metadata, text],
            executableTextSection: text
        )
    }

    private static func loadedBinary(
        bytes: Data,
        sections: [BinarySection],
        executableTextSection: BinarySection?
    ) -> LoadedBinary {
        LoadedBinary(
            name: "swift-function-metadata-fixture",
            path: "/tmp/swift-function-metadata-fixture",
            isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64,
            fileTypeName: "fixture",
            architectureDisplayName: "arm64",
            metadata: .empty,
            bytes: bytes,
            sliceOffset: 0,
            sliceSize: UInt64(bytes.count),
            sections: sections,
            executableTextSection: executableTextSection,
            entryPointAddress: executableTextSection?.address,
            symbols: [],
            imports: [],
            indirectSymbols: [],
            exports: [],
            stringLiterals: [],
            functionStarts: [],
            objcSelectors: [:]
        )
    }

    private static func writeUInt32(_ value: UInt32, in bytes: inout [UInt8], at offset: Int) {
        for byte in 0..<4 {
            bytes[offset + byte] = UInt8(truncatingIfNeeded: value >> UInt32(byte * 8))
        }
    }

    private static func writeRelativePointer(
        in bytes: inout [UInt8],
        fieldVA: UInt64,
        targetVA: UInt64,
        fileOffset: Int
    ) {
        let delta = Int64(bitPattern: targetVA) - Int64(bitPattern: fieldVA)
        writeUInt32(UInt32(bitPattern: Int32(delta)), in: &bytes, at: fileOffset)
    }
}

private enum WS9SwiftFunctionFixture {
    private static let lock = NSLock()
    private static let source = """
    protocol Greeter { func greet() -> Int }
    class Base: Greeter { func greet() -> Int { 1 }; func other() -> Int { 2 } }
    final class Derived: Base { override func greet() -> Int { 3 }; func extra() -> Int { 4 } }
    struct Val { var x = 0; func compute() -> Int { x + 5 }; func more() -> Int { x + 6 } }
    enum E { case a, b; func kind() -> Int { self == .a ? 0 : 1 } }
    func freefloat(_ g: Greeter) -> Int { g.greet() }
    print(freefloat(Derived()) + Val().compute() + E.a.kind() + Base().other() + Derived().extra() + Val().more())
    """

    static func require(in directory: URL) throws -> URL {
        try lock.withLock {
            let fileManager = FileManager.default
            let sourceURL = directory.appendingPathComponent("ws9swift.swift")
            let binaryURL = directory.appendingPathComponent("ws9swift")
            let existingSource = try? String(contentsOf: sourceURL, encoding: .utf8)

            if existingSource != source || !fileManager.isReadableFile(atPath: binaryURL.path) {
                try source.write(to: sourceURL, atomically: true, encoding: .utf8)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = ["swiftc", "-O", "-o", binaryURL.path, sourceURL.path]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                } catch {
                    throw XCTSkip("xcrun swiftc unavailable: \(error.localizedDescription)")
                }
                let drain = CoreTestPipeDrain(output)
                process.waitUntilExit()
                let diagnostic = drain.text()
                guard process.terminationStatus == 0 else {
                    throw XCTSkip("could not compile \(binaryURL.path) (\(process.terminationStatus)): \(diagnostic)")
                }
            }

            try XCTSkipUnless(
                fileManager.isReadableFile(atPath: binaryURL.path),
                "\(binaryURL.path) is not readable"
            )
            return binaryURL
        }
    }
}
