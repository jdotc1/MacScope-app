import CryptoKit
import Foundation
@testable import MacScope

/// Developer-only R9 vertical slice. Candidates and oracle are controlled fixtures,
/// not model-provided execution instructions or an app reconstruction capability.
final class ReconstructionSourceRepairFixture {
    enum Failure: Error, Equatable {
        case unsafePath, oversizedInput, staleParent, sourceTampered
        case outputLimit, deadline, cancelled, cleanupFailed, malformedExit
        case toolchainUnavailable, binaryLimit, repairBudgetExhausted
    }
    struct Revision: Codable, Equatable {
        let id: String
        let parentID: String?
        let objectiveSHA256: String
        let files: [String: String]
        let treeSHA256: String
    }
    struct Receipt: Codable {
        let revisionID: String
        let objectiveSHA256: String
        let sourceTreeSHA256: String
        let stage: String
        let executable: String
        let executableSHA256: String
        let arguments: [String]
        let output: String
        let exitCode: Int
        let ownedProcessID: Int32
        let cleanupObservedAbsent: Bool
    }
    static let compiler = "/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
    static let sdk = "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    static let broken = "#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x + 1; }\n"
    static let repaired = "#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x == UINT32_MAX ? x : x + 1; }\n"
    static let oracle = """
    #include <stdint.h>
    #include <stdio.h>
    uint32_t reconstructed(uint32_t);
    int main(void) {
      const uint32_t inputs[] = {0, 41, UINT32_MAX-1, UINT32_MAX};
      const uint32_t expected[] = {1, 42, UINT32_MAX, UINT32_MAX};
      int failures = 0;
      for (unsigned i = 0; i < 4; ++i) {
        uint32_t actual = reconstructed(inputs[i]);
        printf("CASE:%u:%s\\n", i, actual == expected[i] ? "PASS" : "FAIL");
        failures += actual != expected[i];
      }
      return failures ? 1 : 0;
    }
    """
    let root: URL
    let objectiveSHA256: String
    private(set) var current: Revision?
    private(set) var lastCleanupProof: Phase2ShellBrokerCleanupProof?
    private var revisionCount = 0

    init() throws {
        root = TestWorkRoot.authorityURL("reconstruction-source-repair-fixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let objective = [
            "objective": "Recover uint32 saturating increment: min(x+1, UINT32_MAX).",
            "selectedImage": "developer-controlled portable C fixture; no original binary identity claimed",
            "selectedFunction": "reconstructed(uint32_t) -> uint32_t",
            "ABI": "local arm64 C ABI; uint32_t input and return",
            "inputDomain": "uint32_t; oracle cases 0, 41, UINT32_MAX-1, UINT32_MAX",
            "evidenceFrontierSHA256": Self.sha(Data(Self.oracle.utf8)),
            "unknowns": "Four cases are not exhaustive equivalence. Scripted repair does not establish autonomous model quality or original-binary reconstruction.",
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let objectiveBytes = try encoder.encode(objective)
        objectiveSHA256 = Self.sha(objectiveBytes)
        try objectiveBytes.write(to: root.appendingPathComponent("objective.json"), options: .withoutOverwriting)
    }

    func propose(files: [String: String], parentID: String?) throws -> Revision {
        guard parentID == current?.id else { throw Failure.staleParent }
        guard revisionCount < 2 else { throw Failure.repairBudgetExhausted }
        guard files.count <= 4, files.values.reduce(0, { $0 + $1.utf8.count }) <= 65_536 else {
            throw Failure.oversizedInput
        }
        for path in files.keys {
            guard ["candidate.c", "oracle.c"].contains(path) else { throw Failure.unsafePath }
        }
        guard Set(files.keys) == Set(["candidate.c", "oracle.c"]) else { throw Failure.unsafePath }
        // The objective's evidence frontier is immutable across candidate repairs.
        // Reject an easier replacement oracle before creating any revision state.
        guard let oracle = files["oracle.c"], Data(oracle.utf8) == Data(Self.oracle.utf8) else {
            throw Failure.sourceTampered
        }
        let hashes = files.mapValues { Self.sha(Data($0.utf8)) }
        let tree = Self.sha(Data(hashes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)\n" }.joined().utf8))
        let revision = Revision(id: UUID().uuidString.lowercased(), parentID: parentID, objectiveSHA256: objectiveSHA256,
                                files: hashes, treeSHA256: tree)
        let directory = directory(for: revision)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for (name, text) in files { try Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .withoutOverwriting) }
        try JSONEncoder().encode(revision).write(to: directory.appendingPathComponent("revision.json"), options: .withoutOverwriting)
        current = revision
        revisionCount += 1
        return revision
    }

    func directory(for revision: Revision) -> URL { root.appendingPathComponent(revision.id, isDirectory: true) }

    func validate(_ revision: Revision) throws {
        guard current == revision else { throw Failure.staleParent }
        guard revision.objectiveSHA256 == objectiveSHA256,
              Self.sha(try Data(contentsOf: root.appendingPathComponent("objective.json"))) == objectiveSHA256 else {
            throw Failure.sourceTampered
        }
        let directory = directory(for: revision)
        for (name, digest) in revision.files {
            let url = directory.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65_536,
                  Self.sha(try Data(contentsOf: url)) == digest else { throw Failure.sourceTampered }
        }
        guard try JSONDecoder().decode(Revision.self, from: Data(contentsOf: directory.appendingPathComponent("revision.json"))) == revision else {
            throw Failure.sourceTampered
        }
    }

    func build(_ revision: Revision, cancel: () -> Bool = { false }) throws -> Receipt {
        guard FileManager.default.isExecutableFile(atPath: Self.compiler),
              FileManager.default.fileExists(atPath: Self.sdk) else { throw Failure.toolchainUnavailable }
        let receipt = try run(revision, stage: "build", executable: Self.compiler,
            arguments: ["-std=c11", "-O0", "-Wall", "-Wextra", "-Werror", "-isysroot", Self.sdk,
                        "candidate.c", "oracle.c", "-o", "candidate"], cancel: cancel)
        if receipt.exitCode == 0 {
            let size = try FileManager.default.attributesOfItem(atPath: directory(for: revision).appendingPathComponent("candidate").path)[.size] as? NSNumber
            guard let size, size.intValue <= 1_048_576 else { throw Failure.binaryLimit }
        }
        return receipt
    }

    func behavior(_ revision: Revision) throws -> Receipt {
        try run(revision, stage: "behavior", executable: directory(for: revision).appendingPathComponent("candidate").path, arguments: [])
    }

    func toolchain(_ revision: Revision) throws -> Receipt {
        try run(revision, stage: "toolchain", executable: Self.compiler, arguments: ["--version"])
    }

    func run(_ revision: Revision, stage: String, executable: String, arguments: [String],
             cancel: () -> Bool = { false }, deadline: TimeInterval = 10) throws -> Receipt {
        try validate(revision)
        let toolHash = try Self.fileSHA(URL(fileURLWithPath: executable))
        // Waiting for a fixed gate prevents a short command from exiting before
        // the broker observes its shell identity. No candidate text becomes shell syntax.
        let script = "IFS= read -r gate; \"$@\"; status=$?; printf '\\nR9_EXIT:%d\\n' \"$status\"; IFS= read -r finish"
        let plan = Phase2HumanPTYLaunchPlan(sessionID: UUID(), requestID: UUID(), executablePath: "/bin/sh",
            arguments: ["-c", script, "r9-fixture", executable] + arguments,
            workingDirectoryPath: directory(for: revision).path, initialSize: .defaultInteractive)
        let lease = try Phase2ShellBrokerProcessAdapter().launch(plan)
        defer { lastCleanupProof = lease.cleanup(timeout: 1) }
        _ = try lease.writeInput(Array("go\n".utf8))
        let end = Date().addingTimeInterval(min(10, max(0.01, deadline)))
        var bytes = Data()
        var exitCode: Int?
        while Date() < end {
            if cancel() { throw Failure.cancelled }
            bytes.append(contentsOf: lease.readAvailablePTYOutput(maxBytes: 4_096, timeout: 0.05))
            guard bytes.count <= 16_384 else { throw Failure.outputLimit }
            let output = String(decoding: bytes, as: UTF8.self)
            let exits = output.components(separatedBy: "\n").filter { $0.hasPrefix("R9_EXIT:") }
            if let last = exits.last { exitCode = Int(last.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)); break }
        }
        guard let exitCode else { throw Failure.deadline }
        let proof = lease.cleanup(timeout: 1)
        guard proof.observedProcessAbsent else { throw Failure.cleanupFailed }
        try validate(revision)
        guard try Self.fileSHA(URL(fileURLWithPath: executable)) == toolHash else { throw Failure.sourceTampered }
        let receipt = Receipt(revisionID: revision.id, objectiveSHA256: objectiveSHA256, sourceTreeSHA256: revision.treeSHA256,
            stage: stage, executable: executable, executableSHA256: toolHash, arguments: arguments,
            output: String(decoding: bytes, as: UTF8.self), exitCode: exitCode,
            ownedProcessID: lease.ownedProcess.processIdentifier, cleanupObservedAbsent: proof.observedProcessAbsent)
        try JSONEncoder().encode(receipt).write(to: directory(for: revision).appendingPathComponent("\(stage)-\(UUID().uuidString).json"), options: .withoutOverwriting)
        return receipt
    }

    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func fileSHA(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
