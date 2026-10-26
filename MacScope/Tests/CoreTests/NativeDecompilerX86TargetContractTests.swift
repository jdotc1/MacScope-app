import CryptoKit
import Foundation
import XCTest
#if !MACSCOPE_X86_TARGET_CONTRACT_STANDALONE
@testable import MacScope
#endif

final class NativeDecompilerX86TargetContractTests: XCTestCase {
    private let requestID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let sliceDigest = String(repeating: "a", count: 64)

    // Run under the normal build/test heavy-gate lock. Only the two new C++
    // contract cases execute; no package materialization or runtime is started.
    func testSealedSysVProfileCrossLanguageParity() throws {
        let target = try x86Target()
        XCTAssertEqual(target.rawCPUType, "01000007")
        XCTAssertEqual(target.rawCPUSubtype, "00000003")
        XCTAssertEqual(target.normalizedVariant, .x86_64)
        XCTAssertEqual(target.recognizedCapabilityBits, "00000000")
        XCTAssertNil(target.pointerAuthABIVersion)
        XCTAssertEqual(target.profileID, "apple-x86_64-sysv-v1")
        XCTAssertEqual(target.languageID, "x86:LE:64:default")
        XCTAssertEqual(target.compilerSpecID, "gcc")
        XCTAssertEqual(target.context, [
            .init(name: "addrsize", value: 2), .init(name: "opsize", value: 1),
            .init(name: "rexprefix", value: 0), .init(name: "longMode", value: 1),
        ])
        XCTAssertThrowsError(try NativeDecompilerSealedTargetProfile.normalizedTarget(
            rawCPUType: 0x0100_0007, rawCPUSubtype: 3,
            selectedSliceSHA256: sliceDigest, selectedSliceByteCount: 16
        ), "production request construction must remain disabled")
        for subtype in [UInt32(0), 2, 8, 0x8000_0003, 0x0100_0003, 0xffff_ffff] {
            XCTAssertThrowsError(try x86Target(subtype: subtype))
        }
        XCTAssertThrowsError(try x86Target(digest: String(repeating: "A", count: 64)))
        XCTAssertThrowsError(try NativeDecompilerSealedTargetProfile.normalizedTarget(
            rawCPUType: 0x0100_0007, rawCPUSubtype: 3,
            selectedSliceSHA256: sliceDigest, selectedSliceByteCount: 0,
            allowDisabledProfiles: true
        ))
        XCTAssertThrowsError(try NativeDecompilerSealedTargetProfile.normalizedTarget(
            rawCPUType: 7, rawCPUSubtype: 3,
            selectedSliceSHA256: sliceDigest, selectedSliceByteCount: 16,
            allowDisabledProfiles: true
        ), "i386 remains excluded")

        let context = NativeDecompilerWireCanonicalRequest.contextProfilePreimage(variant: .x86_64)
        XCTAssertEqual(sha256(context), "5fd328d91f7f3a0f815136362f1fe60ba5749f1a72c2337b30c7b7765edf9deb")
        XCTAssertEqual(sha256(context), target.contextProfileSHA256)
        let request = try makeRequest(target: target)
        let codec = NativeDecompilerWireCodec()
        let encoded = try codec.encodeRequest(request, matching: requestID)
        XCTAssertEqual(try codec.decodeRequest(encoded, matching: requestID), request)

        let arm = try NativeDecompilerSealedTargetProfile.normalizedTarget(
            rawCPUType: 0x0100_000c, rawCPUSubtype: 0,
            selectedSliceSHA256: sliceDigest, selectedSliceByteCount: 16
        )
        let armRequest = try makeRequest(target: arm)
        XCTAssertThrowsError(try codec.encodeRequest(armRequest, matching: requestID),
                             "A64 sparse range alignment remains four bytes")
        XCTAssertNotEqual(request.body.requestSHA256, armRequest.body.requestSHA256)
        XCTAssertNotEqual(request.body.requestSHA256,
                          try makeRequest(target: x86Target(digest: String(repeating: "b", count: 64))).body.requestSHA256)

        var object = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: encoded, options: [], format: nil
        ) as? [String: Any])
        var body = try XCTUnwrap(object["body"] as? [String: Any])
        var targetObject = try XCTUnwrap(body["target"] as? [String: Any])
        for compiler in ["clangwindows", "windows", "swift", "default"] {
            targetObject["compilerSpecID"] = compiler
            body["target"] = targetObject
            object["body"] = body
            let invalid = try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
            XCTAssertThrowsError(try codec.decodeRequest(invalid, matching: requestID))
        }
        let invalidRanges: [[NativeDecompilerWireCodeRange]] = [
            [.init(startAddress: .init(0x1001), endAddressExclusive: .init(0x1007)),
             .init(startAddress: .init(0x1006), endAddressExclusive: .init(0x1008))],
            [.init(startAddress: .init(0x1001), endAddressExclusive: .init(0x1003)),
             .init(startAddress: .init(0x1006), endAddressExclusive: .init(0x1009))],
        ]
        for ranges in invalidRanges {
            XCTAssertThrowsError(try codec.encodeRequest(
                makeRequest(target: target, ranges: ranges), matching: requestID
            ), "overlap and unmapped x86 ranges remain invalid")
        }

        let native = try runNativeContractCases()
        XCTAssertEqual(native["context"], context.map { String(format: "%02x", $0) }.joined(),
                       "C++ and Swift context preimages must be byte-identical")
        let preimage = try NativeDecompilerWireCanonicalRequest.preimage(
            schemaVersion: request.schemaVersion, operation: request.operation, target: target,
            image: request.body.image, function: request.body.function,
            memoryRegions: request.body.memoryRegions, symbols: request.body.symbols,
            authoredInputs: request.body.authoredInputs, budgets: NativeDecompilerProductBudgetProfile.v1
        )
        XCTAssertEqual(native["request"], preimage.map { String(format: "%02x", $0) }.joined(),
                       "C++ and Swift sparse x86 request preimages must be byte-identical")
        XCTAssertEqual(native["digest"], request.body.requestSHA256)
    }

    private func x86Target(subtype: UInt32 = 3, digest: String? = nil) throws -> NativeDecompilerWireTarget {
        try NativeDecompilerSealedTargetProfile.normalizedTarget(
            rawCPUType: 0x0100_0007, rawCPUSubtype: subtype,
            selectedSliceSHA256: digest ?? sliceDigest, selectedSliceByteCount: 16,
            allowDisabledProfiles: true
        )
    }

    private func makeRequest(
        target: NativeDecompilerWireTarget,
        ranges: [NativeDecompilerWireCodeRange] = [
            .init(startAddress: .init(0x1001), endAddressExclusive: .init(0x1003)),
            .init(startAddress: .init(0x1006), endAddressExclusive: .init(0x1008)),
        ]
    ) throws -> NativeDecompilerWireRequestEnvelope {
        let image = NativeDecompilerWireImageIdentity(
            imageID: "image.main", uuid: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!, preferredLoadAddress: .init(0x1000)
        )
        let function = NativeDecompilerWireFunctionIdentity(
            functionID: "function.entry", name: "entry", entryAddress: .init(0x1001),
            endAddressExclusive: ranges.last?.endAddressExclusive ?? .init(0x1008), codeRanges: ranges
        )
        let code = Data([0x90, 0x90, 0xc3, 0x90, 0x90, 0x90, 0x90, 0xc3])
        let regions: [NativeDecompilerWireMemoryRegion] = [.init(
            name: "__text", startAddress: .init(0x1000), permissions: .readExecute,
            rawBytes: code, effectiveBytes: code, appliedPatchIDs: []
        )]
        let authored = NativeDecompilerWireAuthoredInputs.empty
        let budgets = NativeDecompilerProductBudgetProfile.v1
        let digest = try NativeDecompilerWireCanonicalRequest.sha256(
            schemaVersion: 4, operation: .decompile, target: target, image: image,
            function: function, memoryRegions: regions, symbols: [], authoredInputs: authored, budgets: budgets
        )
        return .init(schemaVersion: 4, requestID: requestID, body: .init(
            requestID: requestID, requestSHA256: digest, target: target, image: image,
            function: function, memoryRegions: regions, symbols: [], authoredInputs: authored, budgets: budgets.wireValue
        ))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func runNativeContractCases() throws -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        let output = environment["MACSCOPE_X86_CONTRACT_OUTPUT_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent("NativeX86Contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bridge = TestSourceRoot.url.appendingPathComponent("Tools/NativeDecompilerBridge")
        let cmake = try cmakeExecutable()
        _ = try run(cmake, ["-S", bridge.path, "-B", output.path,
                            "-DBUILD_TESTING=ON", "-DCMAKE_BUILD_TYPE=Debug",
                            "-DMACSCOPE_ENABLE_GHIDRA_PROVIDER=OFF"],
                    output: output, name: "configure-contract")
        let targets = ["macscope_native_decompiler_contract_tests",
                       "macscope_native_decompiler_canonical_request_tests"]
        _ = try run(cmake, ["--build", output.path, "--target"] + targets + ["--parallel", "2"],
                    output: output, name: "build-contract")
        var canonicalOutput = Data()
        for name in targets {
            let executable = output.appendingPathComponent(name)
            let result = try run(executable.path, ["--x86-contract"], output: output, name: "run-\(name)")
            if name == targets.last { canonicalOutput = result }
        }
        let text = try XCTUnwrap(String(data: canonicalOutput, encoding: .utf8))
        return Dictionary(uniqueKeysWithValues: text.split(separator: "\n").map {
            let pair = $0.split(separator: "=", maxSplits: 1)
            return (String(pair[0]), pair.count == 2 ? String(pair[1]) : "")
        })
    }

    // Test hosts inherit a minimal PATH, so look for cmake where it is
    // normally installed before falling back to the inherited PATH.
    private func cmakeExecutable() throws -> String {
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let directories = ["/opt/homebrew/bin", "/usr/local/bin"] + inherited
        let candidate = directories.map { "\($0)/cmake" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        return try XCTUnwrap(candidate, "cmake not found in /opt/homebrew/bin, /usr/local/bin or PATH")
    }

    private func run(_ executable: String, _ arguments: [String], output: URL, name: String) throws -> Data {
        let stdoutURL = output.appendingPathComponent("\(name).stdout")
        let stderrURL = output.appendingPathComponent("\(name).stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(data: try Data(contentsOf: stderrURL), encoding: .utf8) ?? ""
            throw NSError(domain: "NativeX86Contract", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(name) failed: \(detail)"])
        }
        return try Data(contentsOf: stdoutURL)
    }
}

#if MACSCOPE_X86_TARGET_CONTRACT_STANDALONE
@main
private struct NativeX86TargetContractMain {
    static func main() {
        let suite = NativeDecompilerX86TargetContractTests.defaultTestSuite
        suite.run()
        guard let run = suite.testRun, run.executionCount == 1 else {
            print("FAIL: expected exactly one x86 contract test")
            exit(1)
        }
        print("x86 contract: executed=\(run.executionCount), failures=\(run.totalFailureCount)")
        exit(run.hasSucceeded ? 0 : 1)
    }
}
#endif
