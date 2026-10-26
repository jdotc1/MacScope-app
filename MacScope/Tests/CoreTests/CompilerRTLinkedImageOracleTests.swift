import Foundation
import XCTest
@testable import MacScope

/// End-to-end proof that the generated compiler-rt signatures survive the real Mach-O linker.
///
/// Source-object round trips cannot prove this contract because PAGE/PAGEOFF/BRANCH26 relocations
/// are realized during linking and ordinary function names can disappear during stripping. This
/// oracle links a bounded, stratified four-function sample from the exact archive that generated
/// the corpus, removes those four public names, and analyzes the resulting image through the
/// production loader, decoder, discovery, matcher, persistence, and rehydration paths.
final class CompilerRTLinkedImageOracleTests: XCTestCase {
    private struct Sample: Hashable {
        let name: String
        let exactLength: UInt64
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
    }

    private struct OracleFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static let pinnedArchiveSHA256 =
        "5f20304aa257ed57bcba9f64287497d0be09b8cc7a5a91479b6a274294a22dfe"

    /// Long exact-checksum atom; imported-reference atom; paired relocation / near-threshold atom;
    /// and local-helper / early relocation atom, respectively.
    private static let samples = [
        Sample(name: "___divdc3", exactLength: 1_412),
        Sample(name: "___clear_cache", exactLength: 20),
        Sample(name: "___fe_getround", exactLength: 24),
        Sample(name: "___isPlatformVersionAtLeast", exactLength: 276),
    ]

    private static let requiredRuntimeImports: Set<String> = [
        "_sys_icache_invalidate",
        "_dispatch_once_f",
        "__availability_version_check",
        "___stack_chk_fail",
    ]

    func testStrippedLinkedImageMatchesAndSurvivesReanalysisPersistenceAndRehydration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MacScopeCompilerRTLinkedImage-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let resourceDirectory = try requireXcrun(
            ["clang", "--print-resource-dir"],
            currentDirectory: directory,
            context: "locate the active Xcode clang resource directory"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let archiveURL = URL(fileURLWithPath: resourceDirectory, isDirectory: true)
            .appendingPathComponent("lib/darwin/libclang_rt.osx.a")
        XCTAssertTrue(
            FileManager.default.isReadableFile(atPath: archiveURL.path),
            "the active Xcode compiler-rt archive must be readable at \(archiveURL.path)"
        )

        let archiveSHA = try requireProcess(
            executable: "/usr/bin/shasum",
            arguments: ["-a", "256", archiveURL.path],
            currentDirectory: directory,
            context: "hash the compiler-rt archive"
        ).split(whereSeparator: \.isWhitespace).first.map(String.init)
        XCTAssertEqual(
            archiveSHA,
            Self.pinnedArchiveSHA256,
            "archive drift invalidates the checked-in signatures and must be refreshed explicitly"
        )
        guard archiveSHA == Self.pinnedArchiveSHA256 else { return }

        let sourceURL = directory.appendingPathComponent("main.c")
        let objectURL = directory.appendingPathComponent("main.o")
        let orderFileURL = directory.appendingPathComponent("sample.order")
        let linkedURL = directory.appendingPathComponent("linked-sample")
        let strippedURL = directory.appendingPathComponent("linked-sample.stripped")

        try write(
            """
            extern unsigned char sample_divdc3 asm("___divdc3");
            extern unsigned char sample_clear_cache asm("___clear_cache");
            extern unsigned char sample_fe_getround asm("___fe_getround");
            extern unsigned char sample_is_platform_version_at_least
                asm("___isPlatformVersionAtLeast");
            static void *volatile samples[] = {
                &sample_divdc3,
                &sample_clear_cache,
                &sample_fe_getround,
                &sample_is_platform_version_at_least,
            };
            int main(void) { return samples[0] == 0; }
            """ + "\n",
            to: sourceURL
        )
        let linkerSymbolLines = Self.samples.map(\.name).joined(separator: "\n") + "\n"
        try write(linkerSymbolLines, to: orderFileURL)

        _ = try requireXcrun(
            [
                "clang", "-arch", "arm64", "-mmacosx-version-min=26.4",
                "-O0", "-fno-stack-protector", "-c", sourceURL.path,
                "-o", objectURL.path,
            ],
            currentDirectory: directory,
            context: "compile the linked-image harness"
        )

        var linkArguments = [
            "clang", "-arch", "arm64", "-mmacosx-version-min=26.4",
            objectURL.path,
            archiveURL.path,
            "-Wl,-order_file,\(orderFileURL.path)",
        ]
        linkArguments.append(contentsOf: ["-o", linkedURL.path])
        _ = try requireXcrun(
            linkArguments,
            currentDirectory: directory,
            context: "link the ordered four-function compiler-rt sample"
        )

        let unstrippedNM = try requireXcrun(
            ["nm", "-arch", "arm64", "-n", linkedURL.path],
            currentDirectory: directory,
            context: "read linker-assigned sample addresses"
        )
        let startsByName = symbolAddresses(
            in: unstrippedNM,
            requiredNames: Set(Self.samples.map(\.name))
        )
        XCTAssertEqual(
            Set(startsByName.keys),
            Set(Self.samples.map(\.name)),
            "every forced sample must have one linker-assigned address before stripping"
        )
        guard startsByName.count == Self.samples.count else { return }

        _ = try requireXcrun(
            [
                "strip", "-x", "-S",
                "-o", strippedURL.path, linkedURL.path,
            ],
            currentDirectory: directory,
            context: "remove ordinary function names while retaining runtime imports"
        )
        let strippedNM = try requireXcrun(
            ["nm", "-arch", "arm64", strippedURL.path],
            currentDirectory: directory,
            context: "verify the sample names were stripped"
        )
        let strippedNames = Set(strippedNM.split(separator: "\n").compactMap { line in
            line.split(whereSeparator: \.isWhitespace).last.map(String.init)
        })
        XCTAssertTrue(
            Set(Self.samples.map(\.name)).isDisjoint(with: strippedNames),
            "the linked-image oracle is invalid if an ordinary sample name remains in the nlist"
        )
        let missingNMImports = Self.requiredRuntimeImports.subtracting(strippedNames).sorted()
        XCTAssertTrue(
            missingNMImports.isEmpty,
            "stripping must preserve required undefined runtime imports: \(missingNMImports)"
        )

        let baseline = try AnalysisEngine(
            functionSignatureMatcher: .empty
        ).analyze(url: strippedURL)
        let baselineImportNames = Set(baseline.imports.map(\.name))
        let missingLoaderImports = Self.requiredRuntimeImports
            .subtracting(baselineImportNames)
            .sorted()
        XCTAssertTrue(
            missingLoaderImports.isEmpty,
            "the production loader must project required runtime imports: \(missingLoaderImports)"
        )
        let productionEngine = AnalysisEngine(functionSignatureMatcher: .standard)
        let recognized = try productionEngine.analyze(url: strippedURL)

        assertLinkedImage(
            baseline: baseline,
            recognized: recognized,
            startsByName: startsByName
        )

        // A fresh analysis must reproduce names and boundaries; no hidden state or first-run cache
        // is allowed to participate in a signature decision.
        let reanalyzed = try productionEngine.analyze(url: strippedURL)
        XCTAssertEqual(
            recognizedFunctionFacts(in: reanalyzed),
            recognizedFunctionFacts(in: recognized),
            "reanalysis must reproduce the same library-signature function boundaries and names"
        )
        XCTAssertEqual(
            recognizedSymbolFacts(in: reanalyzed),
            recognizedSymbolFacts(in: recognized),
            "reanalysis must reproduce the same synthetic library-signature symbols"
        )

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceName: "compiler-rt linked-image oracle",
            snapshot: recognized
        )
        let reopened = try XCTUnwrap(
            database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id))
        )
        XCTAssertEqual(
            recognizedFunctionFacts(in: reopened),
            recognizedFunctionFacts(in: recognized),
            "database persistence must preserve recognized function names and exact boundaries"
        )
        XCTAssertEqual(
            recognizedSymbolFacts(in: reopened),
            recognizedSymbolFacts(in: recognized),
            "database persistence must preserve the paired library-signature symbols"
        )

        let persisted = try XCTUnwrap(reopened.analysis(in: reopened.primarySlot))
        let rehydrated = try productionEngine.rehydrate(
            imageBytes: persisted.imageBytes,
            requestedSliceIndex: nil,
            preserving: persisted,
            cancellation: .never
        )
        XCTAssertEqual(
            recognizedFunctionFacts(in: rehydrated),
            recognizedFunctionFacts(in: persisted),
            "rehydration must preserve persisted library-signature function products"
        )
        XCTAssertEqual(
            recognizedSymbolFacts(in: rehydrated),
            recognizedSymbolFacts(in: persisted),
            "rehydration must preserve persisted library-signature symbol products"
        )
    }

    // MARK: - Assertions

    private func assertLinkedImage(
        baseline: WorkspaceSnapshot,
        recognized: WorkspaceSnapshot,
        startsByName: [String: UInt64]
    ) {
        let sampleNames = Set(Self.samples.map(\.name))
        XCTAssertTrue(
            baseline.symbols.allSatisfy { !sampleNames.contains($0.name) },
            "the baseline loader must not recover any stripped sample name"
        )
        XCTAssertTrue(
            baseline.exports.allSatisfy { !sampleNames.contains($0.name) },
            "the baseline export parser must not recover any stripped sample name"
        )

        for sample in Self.samples {
            guard let start = startsByName[sample.name] else { continue }
            let baselineAtStart = baseline.functions.filter { $0.startAddress == start }
            let recognizedAtStart = recognized.functions.filter { $0.startAddress == start }
            XCTAssertEqual(
                baselineAtStart.count,
                1,
                "the stripped image must retain exactly one discovered boundary at \(sample.name)"
            )
            XCTAssertEqual(
                recognizedAtStart.count,
                1,
                "matching must not create or remove the existing \(sample.name) boundary"
            )
            guard let before = baselineAtStart.first, let after = recognizedAtStart.first else {
                continue
            }

            XCTAssertEqual(before.name, "sub_\(start.hexAddress)")
            XCTAssertEqual(before.endAddress, start + sample.exactLength)
            XCTAssertEqual(after.startAddress, before.startAddress)
            XCTAssertEqual(after.endAddress, before.endAddress)
            XCTAssertEqual(after.confidence, before.confidence)
            XCTAssertEqual(after.name, sample.name)

            let symbolsAtStart = recognized.symbols.filter {
                $0.address == start && $0.kind == "library-signature"
            }
            XCTAssertEqual(symbolsAtStart.count, 1)
            XCTAssertEqual(symbolsAtStart.first?.name, sample.name)
            XCTAssertEqual(symbolsAtStart.first?.libraryName, "compiler-rt")
        }

        XCTAssertEqual(
            recognized.functions.filter { sampleNames.contains($0.name) }.count,
            Self.samples.count,
            "no additional function may receive a sampled compiler-rt identity"
        )
        XCTAssertEqual(
            recognized.symbols.filter {
                $0.kind == "library-signature" && sampleNames.contains($0.name)
            }.count,
            Self.samples.count,
            "each sampled identity must project exactly one paired synthetic symbol"
        )
    }

    private func recognizedFunctionFacts(
        in snapshot: WorkspaceSnapshot
    ) -> [String] {
        let names = Set(Self.samples.map(\.name))
        return snapshot.functions
            .filter { names.contains($0.name) }
            .map { "\($0.startAddress)|\($0.endAddress)|\($0.name)|\($0.confidence)" }
            .sorted()
    }

    private func recognizedFunctionFacts(
        in analysis: ImageAnalysis
    ) -> [String] {
        let names = Set(Self.samples.map(\.name))
        return analysis.functions
            .filter { names.contains($0.name) }
            .map { "\($0.startAddress)|\($0.endAddress)|\($0.name)|\($0.confidence)" }
            .sorted()
    }

    private func recognizedSymbolFacts(
        in snapshot: WorkspaceSnapshot
    ) -> [String] {
        recognizedSymbolFacts(in: snapshot.analysis(in: snapshot.primarySlot) ?? ImageAnalysis())
    }

    private func recognizedSymbolFacts(
        in analysis: ImageAnalysis
    ) -> [String] {
        let names = Set(Self.samples.map(\.name))
        return analysis.symbols
            .filter { $0.kind == "library-signature" && names.contains($0.name) }
            .map { "\($0.address ?? 0)|\($0.name)|\($0.kind)|\($0.libraryName ?? "")" }
            .sorted()
    }

    // MARK: - Tooling

    private func symbolAddresses(
        in nmOutput: String,
        requiredNames: Set<String>
    ) -> [String: UInt64] {
        var addresses: [String: UInt64] = [:]
        for line in nmOutput.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let rawAddress = fields.first,
                  let rawName = fields.last,
                  requiredNames.contains(String(rawName)),
                  let address = UInt64(rawAddress, radix: 16) else {
                continue
            }
            let name = String(rawName)
            XCTAssertNil(
                addresses[name],
                "the linked sample must expose exactly one nlist address for \(name)"
            )
            addresses[name] = address
        }
        return addresses
    }

    private func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url, options: .atomic)
    }

    private func requireXcrun(
        _ arguments: [String],
        currentDirectory: URL,
        context: String
    ) throws -> String {
        try requireProcess(
            executable: "/usr/bin/xcrun",
            arguments: arguments,
            currentDirectory: currentDirectory,
            context: context
        )
    }

    private func requireProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        context: String
    ) throws -> String {
        let result = try runProcess(
            executable: executable,
            arguments: arguments,
            currentDirectory: currentDirectory
        )
        XCTAssertEqual(
            result.status,
            0,
            "\(context) failed (status \(result.status)):\n\(result.output)"
        )
        guard result.status == 0 else {
            throw OracleFailure(
                description: "\(context) failed (status \(result.status)): \(result.output)"
            )
        }
        return result.output
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}
