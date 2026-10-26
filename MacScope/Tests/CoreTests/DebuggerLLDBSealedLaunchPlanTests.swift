import Foundation
import XCTest

#if canImport(MacScope)
@testable import MacScope
#endif

@MainActor
final class DebuggerLLDBSealedLaunchPlanTests: XCTestCase {
    func testPersistentPlanIgnoresCompatibilityInitialBreakpointsAndEmitsNoStaticCommands() async throws {
        let breakpoints = [
            DebuggerBreakpoint(address: 0x3000, isEnabled: false, condition: " disabled "),
            DebuggerBreakpoint(address: 0x2000, condition: " x0 == `value` ", ignoreCount: 2),
            DebuggerBreakpoint(address: 0x1000),
        ]
        let configuration = DebuggerLaunchConfiguration(
            executablePath: " /bin/echo ",
            arguments: ["hello world", "`tick`"],
            environment: ["B_MODE": "two", "A_MODE": "one"],
            workingDirectory: " /tmp ",
            initialBreakpoints: breakpoints
        )

        let plan = try await makePlan(configuration)

        XCTAssertEqual(plan.normalizedDisplayName, "echo")
        XCTAssertEqual(plan.canonicalExecutablePath, "/bin/echo")
        XCTAssertEqual(plan.executableSeal.canonicalPath, plan.canonicalExecutablePath)
        XCTAssertGreaterThan(plan.executableSeal.deviceID, 0)
        XCTAssertGreaterThan(plan.executableSeal.fileID, 0)
        XCTAssertGreaterThan(plan.executableSeal.byteCount, 0)
        XCTAssertEqual(plan.executableSeal.sha256.count, 64)
        XCTAssertTrue(plan.normalizedBreakpoints.isEmpty)
        XCTAssertEqual(
            plan.semanticCommands,
            [
                "settings set use-color false",
                "settings set target.input-path /dev/null",
                "settings set thread-stop-format \"thread #${thread.index}: "
                    + "tid = ${thread.id%tid}{, stop reason = ${thread.stop-reason}}\\n\"",
                "settings set thread-format \"thread #${thread.index}: tid = ${thread.id%tid}"
                    + "{, ${frame.pc}}{ ${module.file.basename}`${function.name}}{, name = '${thread.name}'}"
                    + "{, stop reason = ${thread.stop-reason}}\\n\"",
                "target create \"/bin/echo\"",
                "settings set -- target.env-vars \"A_MODE=one\" \"B_MODE=two\"",
                "settings set -- target.run-args \"hello world\" \"\\`tick\\`\"",
                "process launch --stop-at-entry --no-stdio",
            ]
        )
        XCTAssertEqual(plan.sensitivityCatalog.environmentValues, ["one", "two"])
        XCTAssertEqual(plan.sensitivityCatalog.authoredArguments, ["hello world", "`tick`"])
        XCTAssertTrue(plan.sensitivityCatalog.breakpointConditions.isEmpty)
        XCTAssertFalse(plan.semanticCommands.contains { $0.hasPrefix("breakpoint ") })
        XCTAssertEqual(plan.timeout, .seconds(7))
        XCTAssertEqual(plan.processLaunchPlan.workingDirectory, "/tmp")
        XCTAssertEqual(
            plan.processLaunchPlan.arguments,
            [
                "--no-lldbinit",
                "--one-line",
                "settings set interpreter.echo-commands false",
                "--one-line",
                DebuggerLLDBSealedLaunchPlan.failClosedAsyncStartupCommand,
            ]
        )
        XCTAssertFalse(plan.semanticCommands.contains {
            $0.contains("SetAsync") || $0.contains("GetAsync")
        })
        XCTAssertFalse(plan.semanticCommands.contains {
            $0.contains("thread.info") || $0.contains("thread.queue")
                || $0.contains("thread.activity") || $0.contains("trace_messages")
        })
        XCTAssertEqual(plan.processLaunchPlan.environment["TERM"], "dumb")
        XCTAssertEqual(plan.processLaunchPlan.environment["NSUnbufferedIO"], "YES")
        XCTAssertEqual(
            plan.processLaunchPlan.environment["DEVELOPER_DIR"],
            selectedDeveloperDirectory
        )
        XCTAssertLessThanOrEqual(
            plan.encodedWireByteCount,
            DebuggerLLDBSealedLaunchPlan.maximumEncodedWireBytes
        )
    }

    func testAdapterEnvironmentCarriesOnlyReviewedBenignHostBaseline() async throws {
        let plan = try await makePlan(
            configuration(),
            environment: [
                "HOME": "/Users/tester",
                "USER": "tester",
                "LOGNAME": "tester",
                "PATH": "/usr/bin:/bin",
                "TMPDIR": "/tmp/",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "SHELL": "/bin/zsh",
                "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
                "SSH_AUTH_SOCK": "/tmp/private-agent",
                "API_SECRET": "must-not-cross",
                "TERM": "xterm-secret",
                "NSUnbufferedIO": "NO",
            ]
        )

        XCTAssertEqual(plan.processLaunchPlan.environment["HOME"], "/Users/tester")
        XCTAssertEqual(plan.processLaunchPlan.environment["USER"], "tester")
        XCTAssertEqual(plan.processLaunchPlan.environment["LOGNAME"], "tester")
        XCTAssertEqual(plan.processLaunchPlan.environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(plan.processLaunchPlan.environment["TMPDIR"], "/tmp/")
        XCTAssertEqual(plan.processLaunchPlan.environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(plan.processLaunchPlan.environment["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(plan.processLaunchPlan.environment["SHELL"], "/bin/zsh")
        XCTAssertEqual(plan.processLaunchPlan.environment["TERM"], "dumb")
        XCTAssertEqual(plan.processLaunchPlan.environment["NSUnbufferedIO"], "YES")
        XCTAssertEqual(
            plan.processLaunchPlan.environment["DEVELOPER_DIR"],
            selectedDeveloperDirectory
        )
        XCTAssertNil(plan.processLaunchPlan.environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(plan.processLaunchPlan.environment["SSH_AUTH_SOCK"])
        XCTAssertNil(plan.processLaunchPlan.environment["API_SECRET"])
    }

    func testExecutableSealingGrantCannotBeReusedForAnotherCanonicalTarget() async throws {
        let echoConfiguration = configuration(executablePath: "/bin/echo")
        let echoPath = try DebuggerLLDBSealedLaunchPlan.prepareCanonicalExecutablePath(
            configuration: echoConfiguration
        )
        let echoGrant = try await DebuggerExecutableSealer.seal(
            canonicalExecutablePath: echoPath,
            timeout: .seconds(7)
        )

        XCTAssertThrowsError(try DebuggerLLDBSealedLaunchPlan.make(
            configuration: configuration(executablePath: "/bin/cat"),
            executableSealingGrant: echoGrant,
            toolchain: DebuggerLLDBToolchain(
                executablePath: selectedDeveloperDirectory + "/usr/bin/lldb",
                developerDirectory: selectedDeveloperDirectory,
                discoverySource: "test",
                candidatePaths: []
            ),
            environment: [:],
            fallbackWorkingDirectory: "/tmp",
            timeout: .seconds(7)
        ))
    }

    func testExecutableSealerHonorsBoundedDeadline() async throws {
        let path = try DebuggerLLDBSealedLaunchPlan.prepareCanonicalExecutablePath(
            configuration: configuration()
        )
        do {
            _ = try await DebuggerExecutableSealer.seal(
                canonicalExecutablePath: path,
                timeout: .nanoseconds(1)
            )
            XCTFail("Expected a one-nanosecond executable sealing deadline to fail closed.")
        } catch {
            // The bounded sealer must not turn deadline expiry into an incomplete grant.
        }
    }

    func testRejectsInvalidAuthoredInputsBeforeNormalization() async {
        let cases: [(String, DebuggerLaunchConfiguration)] = [
            (
                "environment key grammar",
                configuration(environment: ["9MODE": "fast"])
            ),
            (
                "environment key control",
                configuration(environment: ["SAFE\u{0007}KEY": "fast"])
            ),
            (
                "environment value control",
                configuration(environment: ["SAFE": "line\nvalue"])
            ),
            (
                "argument control",
                configuration(arguments: ["line\nvalue"])
            ),
            (
                "executable path control",
                configuration(executablePath: "/bin/echo\n")
            ),
            (
                "working directory control",
                configuration(workingDirectory: "/tmp\n")
            ),
        ]

        for (name, configuration) in cases {
            await assertPlanThrows(configuration, name)
        }
    }

    func testRejectsInvalidExecutableAndWorkingDirectory() async {
        await assertPlanThrows(configuration(executablePath: "relative/tool"))
        await assertPlanThrows(configuration(
            executablePath: "/tmp/MacScopeMissingSealedTarget"
        ))
        await assertPlanThrows(configuration(
            workingDirectory: "/tmp/MacScopeMissingSealedDirectory"
        ))
    }

    func testRejectsIndividualUTF8BoundsAndCollectionCounts() async {
        let limits = DebuggerLLDBSealedLaunchPlan.self
        let cases: [(String, DebuggerLaunchConfiguration)] = [
            (
                "argument bytes",
                configuration(arguments: [
                    String(repeating: "a", count: limits.maximumArgumentBytes + 1)
                ])
            ),
            (
                "argument count",
                configuration(arguments: Array(
                    repeating: "a",
                    count: limits.maximumArgumentCount + 1
                ))
            ),
            (
                "environment key bytes",
                configuration(environment: [
                    String(repeating: "K", count: limits.maximumEnvironmentKeyBytes + 1): "v"
                ])
            ),
            (
                "environment value bytes",
                configuration(environment: [
                    "KEY": String(repeating: "v", count: limits.maximumEnvironmentValueBytes + 1)
                ])
            ),
            (
                "environment entry count",
                configuration(environment: Dictionary(uniqueKeysWithValues: (0...limits.maximumEnvironmentEntryCount)
                    .map { ("KEY_\($0)", "v") }))
            ),
            (
                "executable path bytes",
                configuration(executablePath: "/" + String(
                    repeating: "x",
                    count: limits.maximumPathBytes
                ))
            ),
            (
                "working directory bytes",
                configuration(workingDirectory: "/" + String(
                    repeating: "x",
                    count: limits.maximumPathBytes
                ))
            ),
        ]

        for (name, configuration) in cases {
            await assertPlanThrows(configuration, name)
        }
    }

    func testRejectsAggregateWireOverflowEvenWhenEveryInputIsIndividuallyBounded() async {
        let arguments = (0..<16).map { index in
            "arg\(index)-" + String(repeating: "a", count: 240)
        }
        XCTAssertTrue(arguments.allSatisfy {
            $0.utf8.count <= DebuggerLLDBSealedLaunchPlan.maximumArgumentBytes
        })

        await assertPlanThrows(configuration(arguments: arguments))
    }

    func testIgnoredCompatibilityBreakpointsCannotBlockOrExpandPersistentLaunch() async throws {
        let conditions = (0..<5).map { index in
            "x\(index) == " + String(repeating: "a", count: 800)
        }
        XCTAssertTrue(conditions.allSatisfy {
            $0.utf8.count <= DebuggerLLDBSealedLaunchPlan.maximumBreakpointConditionBytes
        })
        var breakpoints = conditions.enumerated().map { index, condition in
            DebuggerBreakpoint(address: 0x1000 + UInt64(index * 4), condition: condition)
        }
        breakpoints.append(DebuggerBreakpoint(
            address: 0x9000,
            condition: "x0\ncontinue" + String(
                repeating: "x",
                count: DebuggerLLDBSealedLaunchPlan.maximumBreakpointConditionBytes + 1
            ),
            ignoreCount: -1
        ))

        let plan = try await makePlan(configuration(initialBreakpoints: breakpoints))

        XCTAssertTrue(plan.normalizedBreakpoints.isEmpty)
        XCTAssertTrue(plan.sensitivityCatalog.breakpointConditions.isEmpty)
        XCTAssertFalse(plan.semanticCommands.contains { $0.hasPrefix("breakpoint ") })
        XCTAssertLessThanOrEqual(
            plan.encodedWireByteCount,
            DebuggerLLDBSealedLaunchPlan.maximumEncodedWireBytes
        )
    }

    private let selectedDeveloperDirectory = "/Applications/Xcode-beta.app/Contents/Developer"

    private func makePlan(
        _ configuration: DebuggerLaunchConfiguration,
        environment: [String: String] = [:]
    ) async throws -> DebuggerLLDBSealedLaunchPlan {
        let canonicalExecutablePath = try DebuggerLLDBSealedLaunchPlan
            .prepareCanonicalExecutablePath(configuration: configuration)
        let grant = try await DebuggerExecutableSealer.seal(
            canonicalExecutablePath: canonicalExecutablePath,
            timeout: .seconds(7)
        )
        return try DebuggerLLDBSealedLaunchPlan.make(
            configuration: configuration,
            executableSealingGrant: grant,
            toolchain: DebuggerLLDBToolchain(
                executablePath: selectedDeveloperDirectory + "/usr/bin/lldb",
                developerDirectory: selectedDeveloperDirectory,
                discoverySource: "test",
                candidatePaths: []
            ),
            environment: environment,
            fallbackWorkingDirectory: "/tmp",
            timeout: .seconds(7)
        )
    }

    private func assertPlanThrows(
        _ configuration: DebuggerLaunchConfiguration,
        _ message: String = "Expected plan construction to fail.",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await makePlan(configuration)
            XCTFail(message, file: file, line: line)
        } catch {
            // Expected fail-closed validation or sealing rejection.
        }
    }

    private func configuration(
        executablePath: String = "/bin/echo",
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = "/tmp",
        initialBreakpoints: [DebuggerBreakpoint] = []
    ) -> DebuggerLaunchConfiguration {
        DebuggerLaunchConfiguration(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            initialBreakpoints: initialBreakpoints
        )
    }
}
