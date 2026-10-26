import Foundation
import XCTest
@testable import MacScope

final class SwiftMetadataCensusTests: XCTestCase {
    func testMetadataCensus() throws {
        guard let path = ProcessInfo.processInfo.environment["MACSCOPE_SWIFT_CENSUS_DIR"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set MACSCOPE_SWIFT_CENSUS_DIR to a directory containing inputs.txt")
        }
        try runCensus(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func runCensus(root: URL) throws {
        let inputs = try String(contentsOf: root.appendingPathComponent("inputs.txt"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard !inputs.isEmpty else { throw CensusInputError.emptyManifest }
        var processedInputs = 0
        let output = root.appendingPathComponent("../receipts/census", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for input in inputs {
            XCTAssertTrue(input.hasPrefix("/"), "Census inputs must be absolute paths")
            let start = Date()
            let data = try Data(contentsOf: URL(fileURLWithPath: input))
            let image = try MachOParser().parse(data, options: .init(
                recoverStringLiterals: false, recoverObjectiveCMetadata: false,
                recoverSwiftMetadata: false, parseCodeSignature: false))
            XCTAssertEqual(image.header.cpuType, MachOConstants.cpuTypeARM64)
            let offset = Int(image.selectedSliceOffset)
            let length = image.universalBinary?.selectedSlice.map { Int($0.size) } ?? data.count
            let thin = Data(data[offset..<(offset + length)])
            var rebases: [UInt64: UInt64] = [:]
            var binds: [UInt64: String] = [:]
            for fixup in image.dyldChainedFixups?.fixups ?? [] {
                if let target = fixup.rebaseTargetAddress { rebases[fixup.address] = target }
                else if let name = fixup.exactBoundSymbolName { binds[fixup.address] = name }
            }
            if image.dyldChainedFixups == nil,
               let command = image.loadCommands.first(where: {
                   $0.command == MachOConstants.loadCommandDyldInfo || $0.command == MachOConstants.loadCommandDyldInfoOnly
               }) {
                let base = Int(command.offset)
                let rebaseOffset = Int(try censusWord(in: thin, at: base + 8))
                let rebaseSize = Int(try censusWord(in: thin, at: base + 12))
                let bindOffset = Int(try censusWord(in: thin, at: base + 16))
                let bindSize = Int(try censusWord(in: thin, at: base + 20))
                let classic = MachODyldInfoFixups.decode(data: thin, streams: .init(
                    rebase: rebaseOffset..<(rebaseOffset + rebaseSize), bind: bindOffset..<(bindOffset + bindSize)),
                    segments: image.segments)
                rebases = classic.rebaseTargets
                binds = classic.bindNames
            }
            let sections = image.sections.map { section in
                SwiftMetadataParser.Section(name: section.sectionName, address: section.address,
                    fileOffset: UInt64(section.fileOffset), size: section.size,
                    isExecutable: section.isExecutableInstructions, isZeroFill: section.isZeroFill,
                    segmentName: section.segmentName)
            }
            let parser = SwiftMetadataParser(data: thin, sections: sections, rebaseTargets: rebases,
                bindNames: binds, metadataAddresses: image.symbols.compactMap {
                    $0.name.hasPrefix("_$s") && $0.name.hasSuffix("N") ? $0.address : nil
                })
            let opaque = parser.parseOpaqueTypeDescriptorsReport()
            let async = parser.parseAsyncFunctionsReport()
            let captures = parser.parseCaptureDescriptorsReport()
            let associated = parser.parseAssociatedTypesReport()
            let builtin = parser.parseBuiltinTypesReport()
            let enums = parser.parseMultiPayloadEnumsReport()
            let witnesses = parser.parseValueWitnessSummariesReport()
            let types2 = parser.parseTypes2TargetsReport()
            let diagnostics = ["opaque": opaque.diagnostics, "async": async.diagnostics,
                "capture": captures.diagnostics, "associated": associated.diagnostics,
                "builtin": builtin.diagnostics, "multiPayloadEnum": enums.diagnostics,
                "valueWitness": witnesses.diagnostics, "types2": types2.diagnostics]
            let counts = ["opaque": opaque.records.count, "asyncEntry": async.records.entries.count,
                "asyncResume": async.records.resumePartialAddresses.count,
                "asyncContinuation": async.records.continuationPartialAddresses.count,
                "asyncPointer": async.records.entryGroups.reduce(0) { $0 + $1.pointerRecords.count },
                "capture": captures.records.count, "associated": associated.records.count,
                "builtin": builtin.records.count, "multiPayloadEnum": enums.records.count,
                "valueWitness": witnesses.records.count, "types2": types2.records.count]
            let arrays = Dictionary(uniqueKeysWithValues: ["__swift_as_entry", "__swift_as_ret", "__swift_as_cont", "__swift5_types2"].map { name in
                (name, sections.filter { $0.name == name }.reduce(UInt64(0)) { $0 + $1.size / 4 })
            })
            let receipt = CensusReceipt(input: input, wallSeconds: Date().timeIntervalSince(start), crash: "none",
                counts: counts, arrayLengths: arrays, diagnostics: diagnostics,
                diagnosticCounts: diagnostics.mapValues(\.count), opaque: opaque.records,
                async: async.records, asyncEntryGroups: async.records.entryGroups,
                symbolicReferenceKinds: opaque.symbolicReferenceKinds, opaqueDescriptorAddresses: opaque.descriptorAddresses,
                accessorReferenceAddresses: opaque.accessorReferenceAddresses,
                opaqueCallSiteAddresses: opaque.callSiteDescriptorAddresses,
                opaqueStructuralAddresses: opaque.structuralDescriptorAddresses,
                valueWitnesses: witnesses.records, types2: types2.records)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let name = URL(fileURLWithPath: input).deletingPathExtension().lastPathComponent
            try encoder.encode(receipt).write(to: output.appendingPathComponent("census-\(name).json"))
            processedInputs += 1
            print("Swift metadata census: \(name), \(receipt.wallSeconds)s, counts \(counts)")
        }
        guard processedInputs > 0 else { throw CensusInputError.emptyManifest }
    }
    func testCensusRejectsEmptyInputsManifest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("census-empty-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for newlineCount in [0, 1, 3] {
            var image = ImageBuilder()
            for _ in 0..<newlineCount { image.byte(0x0a) }
            try Data(image.data).write(to: root.appendingPathComponent("inputs.txt"))
            XCTAssertThrowsError(try runCensus(root: root)) { error in
                XCTAssertEqual(error as? CensusInputError, .emptyManifest)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("receipts/census").path))
        }
    }

    private enum CensusInputError: Error, Equatable { case emptyManifest }

    private func censusWord(in data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count, data.count - offset >= 4 else {
            throw MachOParserError.truncated("census dyld-info command")
        }
        return (0..<4).reduce(UInt32(0)) { value, index in
            value | UInt32(data[data.startIndex + offset + index]) << (index * 8)
        }
    }

}

private struct CensusReceipt: Codable {
    var input: String
    var wallSeconds: Double
    var crash: String
    var counts: [String: Int]
    var arrayLengths: [String: UInt64]
    var diagnostics: [String: [MetadataParseDiagnostic]]
    var diagnosticCounts: [String: Int]
    var opaque: [SwiftOpaqueTypeDescriptor]
    var async: SwiftAsyncMetadata
    var asyncEntryGroups: [SwiftAsyncEntryGroup]
    var symbolicReferenceKinds: [UInt32]
    var opaqueDescriptorAddresses: [UInt64]
    var accessorReferenceAddresses: [UInt64]
    var opaqueCallSiteAddresses: [UInt64]
    var opaqueStructuralAddresses: [UInt64]
    var valueWitnesses: [SwiftValueWitnessSummary]
    var types2: [SwiftTypes2Target]
}
