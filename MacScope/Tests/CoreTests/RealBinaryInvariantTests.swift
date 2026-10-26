import Foundation
import XCTest
@testable import MacScope

/// Product-behavior gate over REAL Mach-O binaries (roadmap P5-01).
///
/// Every defect fixed by the 2026-10-03 P0 series (ObjC selrefs unresolved on every chained-fixup
/// binary, zero ObjC classes recovered from every Xcode-built dylib/framework, offset-valued export
/// addresses) passed the existing synthetic-fixture suites. These invariants run the real parser
/// over binaries present on every macOS 27 host plus freshly compiled fixtures, and compare with
/// external oracles (`nm`, section sizes) rather than with MacScope's own earlier output.
final class RealBinaryInvariantTests: XCTestCase {
    /// System executables shipped outside the dyld shared cache on every macOS install.
    static let systemCorpus = [
        "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit",
        "/System/Applications/Calculator.app/Contents/MacOS/Calculator",
        "/System/Applications/Chess.app/Contents/MacOS/Chess",
        "/usr/bin/say",
        "/usr/bin/plutil",
    ]

    private func corpus() throws -> [URL] {
        var urls = Self.systemCorpus.map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
        urls.append(try RoadmapFixtureBinary.build(.objcExecutable, arch: "arm64"))
        urls.append(try RoadmapFixtureBinary.build(.objcExecutable, arch: "arm64e"))
        urls.append(try RoadmapFixtureBinary.build(.objcDylib, arch: "arm64"))
        return urls
    }

    func testObjectiveCReferencesResolveOnRealBinaries() throws {
        for url in try corpus() {
            let machO = try MachOParser().parse(Data(contentsOf: url))
            let selrefs = machO.objectiveCMetadata.selectorReferences
            guard !selrefs.isEmpty else { continue }
            let resolved = selrefs.filter { $0.resolvedName != nil }.count
            XCTAssertGreaterThanOrEqual(Double(resolved) / Double(selrefs.count), 0.99,
                                        "\(url.lastPathComponent): \(resolved)/\(selrefs.count) selrefs resolved")
        }
    }

    func testObjectiveCClassListIsRecoveredWithImpsInCode() throws {
        for url in try corpus() {
            let machO = try MachOParser().parse(Data(contentsOf: url))
            guard let classList = machO.sections.first(where: { $0.sectionName == "__objc_classlist" }),
                  classList.size >= 8 else { continue }
            let declared = Int(classList.size / 8)
            let classes = machO.objectiveCMetadata.classes
            XCTAssertGreaterThanOrEqual(classes.count * 10, declared * 9,
                                        "\(url.lastPathComponent): \(classes.count)/\(declared) classes recovered")
            let code = machO.sections.filter { $0.flags & 0x8000_0400 != 0 } // S_ATTR_{PURE,SOME}_INSTRUCTIONS
            for method in classes.flatMap({ $0.instanceMethods + $0.classMethods }) {
                guard let imp = method.implementation else { continue }
                XCTAssertTrue(code.contains { imp >= $0.address && imp < $0.address + $0.size },
                              "\(url.lastPathComponent): IMP 0x\(String(imp, radix: 16)) of \(method.selector) outside code")
            }
        }
    }

    func testExportAddressesMatchNm() throws {
        let nm = URL(fileURLWithPath: "/usr/bin/nm")
        guard FileManager.default.isExecutableFile(atPath: nm.path) else { throw XCTSkip("nm unavailable") }
        for url in try corpus() {
            let machO = try MachOParser().parse(Data(contentsOf: url))
            let oracle = try Self.nmDefinedGlobals(url, arch: Self.nmArchitecture(machO.header))
            guard !oracle.isEmpty else { continue }
            for export in machO.exports {
                guard let address = export.address, let expected = oracle[export.name] else { continue }
                XCTAssertEqual(address, expected, "\(url.lastPathComponent): \(export.name) [\(export.source)]")
            }
        }
    }

    static func nmArchitecture(_ header: MachOHeader) -> String? {
        switch header.cpuType {
        case MachOConstants.cpuTypeARM64: return header.cpuSubtype & 0xFF == 2 ? "arm64e" : "arm64"
        case 0x0100_0007: return "x86_64"
        default: return nil
        }
    }

    /// `nm -gU -arch <arch>` → name → address.
    static func nmDefinedGlobals(_ url: URL, arch: String?) throws -> [String: UInt64] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-gU"] + (arch.map { ["-arch", $0] } ?? []) + [url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [:] }
        var result: [String: UInt64] = [:]
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 3, let address = UInt64(fields[0], radix: 16) else { continue }
            result[String(fields[2])] = address
        }
        return result
    }
}
