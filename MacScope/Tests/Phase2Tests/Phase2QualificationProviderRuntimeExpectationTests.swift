import XCTest
@testable import MacScope

final class Phase2QualificationProviderRuntimeExpectationTests: XCTestCase {
    private typealias Observation = Phase2QualificationProviderRuntimePinObservation

    func testExecutableRoleSetRejectsMissingDuplicateAndExtraMembers() {
        var value = fixture()
        value.executables.removeLast()
        XCTAssertTrue(mismatches(value).contains(.executableRoles))
        value = fixture()
        value.executables.append(value.executables[0])
        XCTAssertTrue(mismatches(value).contains(.executableRoles))
        value = fixture()
        value.executables[2] = value.executables[0]
        XCTAssertTrue(mismatches(value).contains(.executableRoles))
        value = fixture()
        value.executables.reverse()
        XCTAssertEqual(mismatches(value), [])
    }

    func testEachExecutableFieldIsExactAndNodeHasIndependentAuthority() {
        let expectation = Phase2QualificationProviderRuntimeExpectation.candidate
        let node = expectation.executable(for: .node)
        XCTAssertEqual(node.homeRelativePath, ".lmstudio/.internal/utils/node")
        XCTAssertEqual(node.teamIdentifier, "HX7739G8FX")
        XCTAssertNotEqual(node.teamIdentifier, expectation.executable(for: .daemon).teamIdentifier)
        for role in Phase2QualificationProviderExecutableRole.allCases {
            let expected = expectation.executable(for: role)
            for field in 0..<5 {
                let changed = Phase2QualificationProviderExecutableExpectation(
                    role: role,
                    homeRelativePath: field == 0 ? ".lmstudio/other" : expected.homeRelativePath,
                    sha256: field == 1 ? String(repeating: "0", count: 64) : expected.sha256,
                    identifier: field == 2 ? "other" : expected.identifier,
                    teamIdentifier: field == 3 ? "OTHER" : expected.teamIdentifier,
                    cdHash: field == 4 ? String(repeating: "0", count: 40) : expected.cdHash
                )
                var value = fixture()
                value.executables = value.executables.map { $0.role == role ? changed : $0 }
                XCTAssertEqual(mismatches(value), [.executable(role)])
            }
        }
    }

    func testEveryClosureAndTemplateDigestIsComparedAgainstSourcePins() {
        let cases: [(WritableKeyPath<Observation, String>, Phase2QualificationProviderRuntimePinMismatch)] = [
            (\.daemonClosureSHA256, .daemonClosure), (\.engineClosureSHA256, .engineClosure),
            (\.embeddedTemplateSHA256, .embeddedTemplate), (\.effectiveTemplateSHA256, .effectiveTemplate),
            (\.effectiveTemplateObjectSHA256, .effectiveTemplateObject),
            (\.templateTransformSourceSHA256, .templateTransform), (\.templateTransformID, .templateTransform),
        ]
        for (path, failure) in cases {
            var value = fixture()
            value[keyPath: path] = "unreviewed"
            XCTAssertEqual(mismatches(value), [failure])
        }
    }

    func testEmbeddedTemplateCannotStandInForEffectiveTemplate() {
        var value = fixture()
        value.effectiveTemplateSHA256 = value.embeddedTemplateSHA256
        value.effectiveTemplateBytes = value.embeddedTemplateBytes
        XCTAssertEqual(mismatches(value), [.effectiveTemplate])
        value = fixture()
        value.embeddedTemplateBytes += 1
        XCTAssertEqual(mismatches(value), [.embeddedTemplate])
        value = fixture()
        value.effectiveTemplateBytes += 1
        XCTAssertEqual(mismatches(value), [.effectiveTemplate])
    }

    func testLoadedConfigurationAndReasoningOverrideMustBeExplicit() {
        for context in [nil, 262_144, 0] as [Int?] {
            var value = fixture(); value.contextLength = context
            XCTAssertEqual(mismatches(value), [.loadedConfiguration])
        }
        for parallel in [nil, 0, 2] as [Int?] {
            var value = fixture(); value.parallelPredictions = parallel
            XCTAssertEqual(mismatches(value), [.loadedConfiguration])
        }
        for reasoning in [nil, true] as [Bool?] {
            var value = fixture(); value.providerBaseEnableThinking = reasoning
            XCTAssertEqual(mismatches(value), [.reasoningOverride])
        }
    }

    private func mismatches(_ value: Observation) -> [Phase2QualificationProviderRuntimePinMismatch] {
        Phase2QualificationProviderRuntimePinValidator.mismatches(in: value)
    }

    private func fixture() -> Observation {
        let value = Phase2QualificationProviderRuntimeExpectation.candidate
        return .init(
            executables: Phase2QualificationProviderExecutableRole.allCases.map { value.executable(for: $0) },
            daemonClosureSHA256: value.daemonClosureSHA256, engineClosureSHA256: value.engineClosureSHA256,
            embeddedTemplateSHA256: value.embeddedTemplateSHA256,
            effectiveTemplateSHA256: value.effectiveTemplateSHA256,
            effectiveTemplateObjectSHA256: value.effectiveTemplateObjectSHA256,
            templateTransformSourceSHA256: value.templateTransformSourceSHA256,
            templateTransformID: value.templateTransformID,
            embeddedTemplateBytes: value.embeddedTemplateBytes, effectiveTemplateBytes: value.effectiveTemplateBytes,
            contextLength: 32_768, parallelPredictions: 1, providerBaseEnableThinking: false
        )
    }
}
