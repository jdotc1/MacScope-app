import XCTest
@testable import MacScope

final class NativeDecompilerRuntimeIdentityTests: XCTestCase {
    private let expected = NativeDecompilerRuntimeIdentity(
        backendID: "ghidra-native-decompiler",
        engineVersion: "12.1.2",
        engineRevision: "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
        wrapperVersion: "dcp05c-v1",
        wrapperRevision: String(repeating: "a", count: 40),
        packageManifestSHA256: String(repeating: "b", count: 64),
        packageTreeSHA256: "9cc94c918e6af5659a211330561a7fed7099a00fa3ea05c54698051827498460",
        languageID: "AARCH64:LE:64:AppleSilicon",
        compilerSpecID: "default",
        targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
        contextProfileSHA256: "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5"
    )

    func testRuntimeIdentityPreservesEveryFrozenField() throws {
        XCTAssertEqual(expected.backendID, "ghidra-native-decompiler")
        XCTAssertEqual(expected.engineVersion, "12.1.2")
        XCTAssertEqual(expected.engineRevision, "c0f584bf229fffba61b36431f3ce30c0c3e4e682")
        XCTAssertEqual(expected.wrapperVersion, "dcp05c-v1")
        XCTAssertEqual(expected.wrapperRevision, String(repeating: "a", count: 40))
        XCTAssertEqual(expected.packageManifestSHA256, String(repeating: "b", count: 64))
        XCTAssertEqual(
            expected.packageTreeSHA256,
            "9cc94c918e6af5659a211330561a7fed7099a00fa3ea05c54698051827498460"
        )
        XCTAssertEqual(expected.languageID, "AARCH64:LE:64:AppleSilicon")
        XCTAssertEqual(expected.compilerSpecID, "default")
        XCTAssertEqual(expected.targetProfileID, "apple-aarch64-pac-visible-clobber-v1")
        XCTAssertEqual(
            expected.contextProfileSHA256,
            "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5"
        )

        let data = try JSONEncoder().encode(expected)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            [
                "backendID", "engineVersion", "engineRevision", "wrapperVersion",
                "wrapperRevision", "packageManifestSHA256", "packageTreeSHA256",
                "languageID", "compilerSpecID", "targetProfileID", "contextProfileSHA256",
            ]
        )
        XCTAssertNil(object["engineGitRevision"])
        XCTAssertNil(object["wrapperGitRevision"])
        XCTAssertEqual(try JSONDecoder().decode(NativeDecompilerRuntimeIdentity.self, from: data), expected)
    }

    func testRuntimeIdentityEqualityAndHashIncludeEveryField() {
        let mutations = [
            identity(backendID: "other-backend"),
            identity(engineVersion: "12.1.3"),
            identity(engineRevision: String(repeating: "c", count: 40)),
            identity(wrapperVersion: "dcp05c-v2"),
            identity(wrapperRevision: String(repeating: "d", count: 40)),
            identity(packageManifestSHA256: String(repeating: "e", count: 64)),
            identity(packageTreeSHA256: String(repeating: "f", count: 64)),
            identity(languageID: "AARCH64:LE:64:v8A"),
            identity(compilerSpecID: "swift"),
            identity(targetProfileID: "other-profile"),
            identity(contextProfileSHA256: String(repeating: "0", count: 64)),
        ]

        XCTAssertEqual(Set([expected, expected]).count, 1)
        XCTAssertEqual(Set(mutations).count, mutations.count)
        XCTAssertTrue(mutations.allSatisfy { $0 != expected })
        XCTAssertFalse(Set(mutations).contains(expected))
    }

    private func identity(
        backendID: String? = nil,
        engineVersion: String? = nil,
        engineRevision: String? = nil,
        wrapperVersion: String? = nil,
        wrapperRevision: String? = nil,
        packageManifestSHA256: String? = nil,
        packageTreeSHA256: String? = nil,
        languageID: String? = nil,
        compilerSpecID: String? = nil,
        targetProfileID: String? = nil,
        contextProfileSHA256: String? = nil
    ) -> NativeDecompilerRuntimeIdentity {
        NativeDecompilerRuntimeIdentity(
            backendID: backendID ?? expected.backendID,
            engineVersion: engineVersion ?? expected.engineVersion,
            engineRevision: engineRevision ?? expected.engineRevision,
            wrapperVersion: wrapperVersion ?? expected.wrapperVersion,
            wrapperRevision: wrapperRevision ?? expected.wrapperRevision,
            packageManifestSHA256: packageManifestSHA256 ?? expected.packageManifestSHA256,
            packageTreeSHA256: packageTreeSHA256 ?? expected.packageTreeSHA256,
            languageID: languageID ?? expected.languageID,
            compilerSpecID: compilerSpecID ?? expected.compilerSpecID,
            targetProfileID: targetProfileID ?? expected.targetProfileID,
            contextProfileSHA256: contextProfileSHA256 ?? expected.contextProfileSHA256
        )
    }
}
