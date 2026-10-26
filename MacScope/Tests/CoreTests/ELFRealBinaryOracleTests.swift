import Foundation
import XCTest
@testable import MacScope

/// Real-binary oracle for the ELF loader. This builds linked ELF shared objects and executables
/// with clang + ld.lld, then checks ELFBinaryLoader against objdump instead of another synthetic
/// fixture that encodes the loader's own assumptions.
final class ELFRealBinaryOracleTests: XCTestCase {
    private struct Target {
        let name: String
        let triple: String
        let expectedArchitecture: String
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
    }

    private struct BuildUnavailable: Error, CustomStringConvertible {
        let description: String
    }

    private struct DynamicSymbol: Hashable {
        let name: String
        let decoratedName: String
        let address: UInt64
        let isUndefined: Bool
        let isFunction: Bool
        let isObject: Bool
    }

    private static let targets = [
        Target(name: "x86_64", triple: "x86_64-unknown-linux-gnu", expectedArchitecture: "x86_64"),
        Target(name: "aarch64", triple: "aarch64-unknown-linux-gnu", expectedArchitecture: "arm64")
    ]

    private func findLDLLD() -> String? {
        let candidates = ["/opt/homebrew/opt/llvm/bin/ld.lld", "/usr/local/opt/llvm/bin/ld.lld"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let base = "/opt/homebrew/Cellar/swift"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base) else {
            return nil
        }
        for version in versions.sorted().reversed() {
            let versionDirectory = "\(base)/\(version)"
            guard let toolchains = try? FileManager.default.contentsOfDirectory(atPath: versionDirectory) else {
                continue
            }
            for toolchain in toolchains.sorted().reversed() where toolchain.hasSuffix(".xctoolchain") {
                let path = "\(versionDirectory)/\(toolchain)/usr/bin/ld.lld"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    private func run(_ path: String, _ args: [String], cwd: URL) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = cwd
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw XCTSkip("could not launch \(path): \(error)")
        }
        let drain = CoreTestPipeDrain(pipe)
        process.waitUntilExit()
        let data = drain.data()
        return ProcessResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    private func runOrSkip(_ path: String, _ args: [String], cwd: URL, context: String) throws {
        let result = try run(path, args, cwd: cwd)
        guard result.status == 0 else {
            throw BuildUnavailable(description: "\(context) failed: \(result.output)")
        }
    }

    private func buildRealELF(target: Target, clang: String, lld: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScopeRealELF-\(target.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try """
        int exported_data = 41;
        static int hidden_twice(int x) { return x * 2; }
        __attribute__((visibility("default"))) int addnums(int a, int b) {
            return hidden_twice(a) + b + exported_data;
        }
        __attribute__((visibility("default"))) int subnums(int a, int b) {
            return a - b;
        }
        """
        .write(to: dir.appendingPathComponent("lib.c"), atomically: true, encoding: .utf8)

        try """
        extern int addnums(int, int);
        extern int exported_data;
        void _start(void) {
            (void)addnums(exported_data, 3);
        }
        """
        .write(to: dir.appendingPathComponent("main.c"), atomically: true, encoding: .utf8)

        try """
        VERS_1 {
          global: addnums; subnums; exported_data;
          local: *;
        };
        """
        .write(to: dir.appendingPathComponent("nums.ver"), atomically: true, encoding: .utf8)

        do {
            let compile = ["-target", target.triple, "-fno-stack-protector", "-ffreestanding", "-fPIC", "-c"]
            try runOrSkip(clang, compile + ["lib.c", "-o", "lib.o"], cwd: dir, context: "\(target.name) lib compile")
            try runOrSkip(clang, compile + ["main.c", "-o", "main.o"], cwd: dir, context: "\(target.name) main compile")
            try runOrSkip(
                lld,
                ["-shared", "lib.o", "-o", "libnums.so", "-soname", "libnums.so", "--version-script", "nums.ver"],
                cwd: dir,
                context: "\(target.name) shared link"
            )
            try runOrSkip(
                lld,
                ["main.o", "./libnums.so", "-o", "main.elf", "-e", "_start", "-rpath", "$ORIGIN"],
                cwd: dir,
                context: "\(target.name) executable link"
            )
            return dir
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    private func objdump(_ args: [String], cwd: URL) throws -> String {
        let result = try run("/usr/bin/objdump", args, cwd: cwd)
        XCTAssertEqual(result.status, 0, "objdump \(args.joined(separator: " ")) failed: \(result.output)")
        return result.output
    }

    private func parseDynamicSymbols(_ text: String) -> [DynamicSymbol] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split { $0 == " " || $0 == "\t" }.map(String.init)
            guard parts.count >= 5, UInt64(parts[0], radix: 16) != nil else { return nil }
            let name = parts.last ?? ""
            let previous = parts.dropLast().last ?? ""
            let version: String?
            if previous.hasPrefix("("), previous.hasSuffix(")") {
                version = String(previous.dropFirst().dropLast())
            } else if parts.count >= 7,
                      UInt64(previous, radix: 16) == nil,
                      previous != "*UND*",
                      !previous.hasPrefix(".") {
                version = previous
            } else {
                version = nil
            }
            let decorated = version.map { "\(name)@\($0)" } ?? name
            return DynamicSymbol(
                name: name,
                decoratedName: decorated,
                address: UInt64(parts[0], radix: 16) ?? 0,
                isUndefined: parts.contains("*UND*"),
                isFunction: parts.dropFirst().dropLast().contains { $0.contains("F") },
                isObject: parts.dropFirst().dropLast().contains { $0.contains("O") }
            )
        }
    }

    private func parseNeeded(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").compactMap { line in
            let parts = line.split { $0 == " " || $0 == "\t" }.map(String.init)
            return parts.count >= 2 && parts[0] == "NEEDED" ? parts[1] : nil
        })
    }

    private func parseStartAddress(_ text: String) -> UInt64? {
        for line in text.split(separator: "\n") where line.contains("start address:") {
            guard let raw = line.split(separator: " ").last else { continue }
            return UInt64(raw.replacingOccurrences(of: "0x", with: ""), radix: 16)
        }
        return nil
    }

    private func parseSectionHeaders(_ text: String) -> [String: (address: UInt64, size: UInt64)] {
        var sections: [String: (address: UInt64, size: UInt64)] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split { $0 == " " || $0 == "\t" }.map(String.init)
            guard parts.count >= 4,
                  Int(parts[0]) != nil,
                  !parts[1].allSatisfy({ $0.isHexDigit }),
                  let size = UInt64(parts[2], radix: 16),
                  let address = UInt64(parts[3], radix: 16) else { continue }
            sections[parts[1]] = (address, size)
        }
        return sections
    }

    private func parseRelocations(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n").compactMap { line in
            let parts = line.split { $0 == " " || $0 == "\t" }.map(String.init)
            guard parts.count >= 2,
                  UInt64(parts[0], radix: 16) != nil,
                  parts[1].hasPrefix("R_") else { return nil }
            return "\(parts[0])|\(parts[1])|\(parts.count >= 3 ? parts[2] : "")"
        })
    }

    private func loaderRelocations(_ loaded: LoadedBinary) -> Set<String> {
        Set(loaded.relocations.map { relocation in
            let offset = String(format: "%016llx", relocation.address)
            return "\(offset)|\(relocation.typeName ?? String(relocation.typeCode))|\(relocation.symbolName ?? "")"
        })
    }

    private func assertCorpus(at dir: URL, target: Target) throws {
        let sharedURL = dir.appendingPathComponent("libnums.so")
        let mainURL = dir.appendingPathComponent("main.elf")
        let shared = try ELFBinaryLoader.parse(bytes: try Data(contentsOf: sharedURL), name: "libnums.so", path: sharedURL.path)
        let main = try ELFBinaryLoader.parse(bytes: try Data(contentsOf: mainURL), name: "main.elf", path: mainURL.path)

        XCTAssertEqual(shared.architectureDisplayName, target.expectedArchitecture)
        XCTAssertEqual(main.architectureDisplayName, target.expectedArchitecture)
        XCTAssertEqual(shared.fileTypeName, "ELF shared object")
        XCTAssertEqual(main.fileTypeName, "ELF executable")

        let sharedSections = parseSectionHeaders(try objdump(["--section-headers", "libnums.so"], cwd: dir))
        let mainSections = parseSectionHeaders(try objdump(["--section-headers", "main.elf"], cwd: dir))
        let sharedText = try XCTUnwrap(sharedSections[".text"])
        let mainText = try XCTUnwrap(mainSections[".text"])
        XCTAssertEqual(shared.sections.first { $0.name == ".text" }?.address, sharedText.address)
        XCTAssertEqual(shared.sections.first { $0.name == ".text" }?.size, sharedText.size)
        XCTAssertEqual(main.sections.first { $0.name == ".text" }?.address, mainText.address)
        XCTAssertEqual(main.sections.first { $0.name == ".text" }?.size, mainText.size)

        let sharedDynamicSymbols = parseDynamicSymbols(try objdump(["-T", "libnums.so"], cwd: dir))
        let mainDynamicSymbols = parseDynamicSymbols(try objdump(["-T", "main.elf"], cwd: dir))
        let expectedSharedExports = Set(sharedDynamicSymbols
            .filter { !$0.isUndefined && ($0.isFunction || $0.isObject) }
            .map { "\($0.decoratedName)|\($0.address)" })
        let actualSharedExports = Set(shared.exports.map { "\($0.name)|\($0.address ?? 0)" })
        XCTAssertEqual(actualSharedExports, expectedSharedExports, "shared-object dynamic exports must match objdump -T for \(target.name)")

        XCTAssertEqual(shared.symbols.first { $0.name == "hidden_twice" }?.kind, "local")
        XCTAssertNotNil(shared.symbols.first { $0.name == "hidden_twice" }?.address)

        let expectedImports = Set(mainDynamicSymbols.filter(\.isUndefined).map(\.decoratedName))
        XCTAssertEqual(Set(main.imports.map(\.name)), expectedImports)
        let needed = parseNeeded(try objdump(["-p", "main.elf"], cwd: dir))
        XCTAssertEqual(needed, Set(main.imports.compactMap(\.libraryName)))

        XCTAssertEqual(parseRelocations(try objdump(["-R", "libnums.so"], cwd: dir)), loaderRelocations(shared))
        XCTAssertEqual(parseRelocations(try objdump(["-R", "main.elf"], cwd: dir)), loaderRelocations(main))

        let versionedImportNames = Dictionary(uniqueKeysWithValues: mainDynamicSymbols.map { ($0.name, $0.decoratedName) })
        let expectedPLT = Set(parseRelocations(try objdump(["-R", "main.elf"], cwd: dir)).compactMap { row -> String? in
            let parts = row.split(separator: "|").map(String.init)
            guard parts.count >= 3, parts[1].contains("JUMP_SLOT") else { return nil }
            return "\(parts[0])|\(versionedImportNames[parts[2]] ?? parts[2])"
        })
        let actualPLT = Set(main.indirectSymbols.map { indirect in
            "\(String(format: "%016llx", indirect.address))|\(indirect.symbolName ?? "")"
        })
        XCTAssertEqual(actualPLT, expectedPLT)

        XCTAssertEqual(main.entryPointAddress, parseStartAddress(try objdump(["-f", "main.elf"], cwd: dir)))
    }

    func testLoaderMatchesObjdumpOnRealLinkedELFCorpus() throws {
        let clang = "/usr/bin/clang"
        guard FileManager.default.isExecutableFile(atPath: clang) else { throw XCTSkip("clang unavailable") }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/objdump") else { throw XCTSkip("objdump unavailable") }
        guard let lld = findLDLLD() else { throw XCTSkip("ld.lld unavailable on this host") }

        var builtTargets: [String] = []
        var skippedTargets: [String] = []
        for target in Self.targets {
            do {
                let dir = try buildRealELF(target: target, clang: clang, lld: lld)
                defer { try? FileManager.default.removeItem(at: dir) }
                builtTargets.append(target.name)
                try assertCorpus(at: dir, target: target)
            } catch let unavailable as BuildUnavailable {
                skippedTargets.append("\(target.name): \(unavailable.description)")
            }
        }

        if builtTargets.isEmpty {
            throw XCTSkip("no ELF targets linked with this toolchain: \(skippedTargets.joined(separator: "; "))")
        }
        if !skippedTargets.isEmpty {
            XCTFail("some ELF targets did not link: \(skippedTargets.joined(separator: "; "))")
        }
    }
}
