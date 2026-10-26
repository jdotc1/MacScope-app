import Foundation
import XCTest
@testable import MacScope

final class LLDBVariableSnapshotDecoderTests: XCTestCase {
    private let token = Data(repeating: 0xab, count: 32)

    func testDecodesCanonicalTopLevelArgumentsLocalsAndStatics() throws {
        let snapshot = try LLDBVariableSnapshotDecoder().decodeCanonicalSnapshot(validBytes())

        XCTAssertEqual(snapshot.token, token)
        XCTAssertEqual(snapshot.observedProcessID, 812)
        XCTAssertEqual(snapshot.observedStopID, 19)
        XCTAssertEqual(snapshot.threadID, 0x1234)
        XCTAssertEqual(snapshot.frameIndex, 2)
        XCTAssertEqual(snapshot.programCounter, 0x1000_0040)
        XCTAssertEqual(snapshot.variables.map(\.scope), [.argument, .local, .staticVariable])
        XCTAssertEqual(snapshot.variables.map(\.ordinal), [0, 0, 0])
        XCTAssertEqual(snapshot.variables.map(\.name), ["argc", "counter", "globalFlag"])
        XCTAssertEqual(snapshot.variables[0].typeName, "int")
        XCTAssertEqual(snapshot.variables[0].value, "3")
        XCTAssertNil(snapshot.variables[0].summary)
        XCTAssertFalse(snapshot.variables[0].hasChildren)
        XCTAssertEqual(snapshot.variables[1].summary, "active")
        XCTAssertTrue(snapshot.variables[1].hasChildren)
        XCTAssertEqual(snapshot.variables[1].childCount, 2)
        XCTAssertFalse(snapshot.wasTruncated)
        XCTAssertEqual(snapshot.totalOmittedCount, 0)
    }

    func testDecodesExactlyOneSentinelFramedSnapshot() throws {
        let line = "MACSCOPE_LLDB_VARIABLE_SNAPSHOT_V1 "
            + String(decoding: validBytes(), as: UTF8.self) + "\n"
        XCTAssertEqual(
            try LLDBVariableSnapshotDecoder().decodeSemanticTranscript(line).programCounter,
            0x1000_0040
        )
        XCTAssertThrowsError(try LLDBVariableSnapshotDecoder().decodeSemanticTranscript(line + "noise\n")) {
            XCTAssertEqual(($0 as? LLDBVariableSnapshotFailure)?.code, .invalidFraming)
        }
    }

    func testRejectsNoncanonicalJSONUnknownKeysAndDuplicateKeys() throws {
        let decoder = LLDBVariableSnapshotDecoder()
        XCTAssertThrowsError(try decoder.decodeCanonicalSnapshot(Data(" {\"ok\":true}".utf8))) {
            XCTAssertEqual(($0 as? LLDBVariableSnapshotFailure)?.code, .noncanonicalJSON)
        }

        var root = validObject()
        root["surprise"] = .bool(true)
        assertFailure(Phase2ProductionJSONValue.object(root).canonicalJSONBytes(), .invalidSchema)

        let duplicate = Data("{\"ok\":true,\"ok\":true}".utf8)
        assertFailure(duplicate, .invalidJSON)
    }

    func testRejectsInvalidCoordinateAndVariableValues() {
        var root = validObject()
        root["observed_state"] = .string("running")
        assertFailure(Phase2ProductionJSONValue.object(root).canonicalJSONBytes(), .processNotStopped)

        root = validObject()
        root["observed_pid"] = .number("0")
        assertFailure(Phase2ProductionJSONValue.object(root).canonicalJSONBytes(), .invalidValue)

        root = validObject()
        root["variables"] = .array([.object([
            "child_count": .number("0"), "diagnostic": .null, "has_children": .bool(false),
            "name": .string("bad\nname"), "ordinal": .number("0"),
            "scope": .string("local"), "state": .string("available"), "summary": .null,
            "type": .string("int"), "value": .string("1"),
        ])])
        assertFailure(Phase2ProductionJSONValue.object(root).canonicalJSONBytes(), .invalidValue)

        root = validObject()
        root["variables"] = .array([.object([
            "child_count": .number("1"), "diagnostic": .null, "has_children": .bool(false),
            "name": .string("x"), "ordinal": .number("0"),
            "scope": .string("local"), "state": .string("available"), "summary": .null,
            "type": .string("int"), "value": .string("1"),
        ])])
        assertFailure(Phase2ProductionJSONValue.object(root).canonicalJSONBytes(), .invalidValue)
    }

    func testRejectsWrongOrderingDuplicateScopeOrdinalAndOversizedInput() {
        var root = validObject()
        if case .array(let variables) = root["variables"] {
            root["variables"] = .array(Array(variables.reversed()))
        }
        assertFailure(Phase2ProductionJSONValue.object(root).canonicalJSONBytes(), .invalidOrdering)

        root = validObject()
        if case .array(let variables) = root["variables"], variables.count >= 2 {
            var duplicate = variables[1].objectValue!
            duplicate["scope"] = .string("argument")
            root["variables"] = .array([variables[0], .object(duplicate)])
        }
        assertFailure(Phase2ProductionJSONValue.object(root).canonicalJSONBytes(), .invalidOrdering)

        assertFailure(Data(repeating: 0x20, count: LLDBVariableSnapshotDecoder.maximumSnapshotBytes + 1), .capacity)
    }

    func testAllowsShadowedNamesWhenScopeOrdinalsRemainDistinct() throws {
        var root = validObject()
        guard case .array(var variables) = root["variables"] else {
            return XCTFail("Expected variable fixture array.")
        }
        variables.insert(
            variable(.local, ordinal: 1, name: "counter", type: "Int", value: "99"),
            at: 2
        )
        root["variables"] = .array(variables)

        let decoded = try LLDBVariableSnapshotDecoder().decodeCanonicalSnapshot(
            Phase2ProductionJSONValue.object(root).canonicalJSONBytes()
        )
        let locals = decoded.variables.filter { $0.scope == .local }
        XCTAssertEqual(locals.map(\.name), ["counter", "counter"])
        XCTAssertEqual(locals.map(\.ordinal), [0, 1])
        XCTAssertEqual(locals.compactMap(\.value), ["{...}", "99"])
    }

    func testAcceptsCanonicalPrefixWhenOneScopeHas129Variables() throws {
        var root = validObject()
        root["variables"] = .array((0..<128).map {
            variable(.argument, ordinal: UInt32($0), name: "arg\($0)", type: "int", value: "\($0)")
        })
        root["argument_omitted"] = .number("1")
        root["argument_truncated"] = .bool(true)
        root["omitted_count"] = .number("1")
        root["truncated"] = .bool(true)

        let decoded = try LLDBVariableSnapshotDecoder().decodeCanonicalSnapshot(
            Phase2ProductionJSONValue.object(root).canonicalJSONBytes()
        )
        XCTAssertEqual(decoded.variables.count, 128)
        XCTAssertEqual(decoded.argumentOmittedCount, 1)
        XCTAssertEqual(decoded.totalOmittedCount, 1)
        XCTAssertTrue(decoded.wasTruncated)
    }

    func testAcceptsCanonical256VariablePrefixWithLaterScopeOmission() throws {
        var root = validObject()
        let arguments = (0..<128).map {
            variable(.argument, ordinal: UInt32($0), name: "arg\($0)", type: "int", value: "\($0)")
        }
        let locals = (0..<128).map {
            variable(.local, ordinal: UInt32($0), name: "local\($0)", type: "int", value: "\($0)")
        }
        root["variables"] = .array(arguments + locals)
        root["static_omitted"] = .number("1")
        root["static_truncated"] = .bool(true)
        root["omitted_count"] = .number("1")
        root["truncated"] = .bool(true)

        let decoded = try LLDBVariableSnapshotDecoder().decodeCanonicalSnapshot(
            Phase2ProductionJSONValue.object(root).canonicalJSONBytes()
        )
        XCTAssertEqual(decoded.variables.count, 256)
        XCTAssertEqual(decoded.staticOmittedCount, 1)
        XCTAssertEqual(decoded.totalOmittedCount, 1)
        XCTAssertTrue(decoded.wasTruncated)
    }

    func testExtractorCommandValidatesIdentityInputsAndSourceContainsSBValueAPIOnly() throws {
        let program = try LLDBVariableExtractorProgram(source: "def extract(*args):\n    return None\n")
        XCTAssertThrowsError(try program.snapshotCommand(
            token: Data(repeating: 0, count: 31), expectedProcessID: 1,
            expectedStopID: 1, threadID: 1, frameIndex: 0, programCounter: 1
        ))
        XCTAssertThrowsError(try program.snapshotCommand(
            token: token, expectedProcessID: 0, expectedStopID: 1,
            threadID: 1, frameIndex: 0, programCounter: 1
        ))
        XCTAssertThrowsError(try program.childSnapshotCommand(
            token: Data(repeating: 0, count: 31), expectedProcessID: 1,
            expectedStopID: 1, threadID: 1, frameIndex: 0, programCounter: 1,
            pathComponents: ["locals", "0", "aggregate"]
        ))
        XCTAssertThrowsError(try program.childSnapshotCommand(
            token: token, expectedProcessID: 1, expectedStopID: 1,
            threadID: 1, frameIndex: 0, programCounter: 1,
            pathComponents: ["locals", "bad\nindex", "aggregate"]
        ))
        XCTAssertThrowsError(try program.childSnapshotCommand(
            token: token, expectedProcessID: 1, expectedStopID: 1,
            threadID: 1, frameIndex: 0, programCounter: 1,
            pathComponents: ["locals", "0"]
        ))
        XCTAssertNoThrow(try program.childSnapshotCommand(
            token: token, expectedProcessID: 1, expectedStopID: 1,
            threadID: 1, frameIndex: 0, programCounter: 1,
            pathComponents: ["locals", "0", "aggregate"]
        ))

        let source = LLDBVariableExtractorProgram.current.source
        XCTAssertTrue(source.contains("GetVariables(True, False, False, True)"))
        XCTAssertTrue(source.contains("GetVariables(False, True, False, True)"))
        XCTAssertTrue(source.contains("GetVariables(False, False, True, True)"))
        XCTAssertTrue(source.contains("extract_children"))
        XCTAssertTrue(source.contains("GetChildAtIndex"))
        XCTAssertTrue(source.contains("GetStopID"))
        XCTAssertTrue(source.contains("GetThreadByID"))
        XCTAssertTrue(source.contains("GetFrameAtIndex"))
        XCTAssertFalse(source.contains("frame variable"))
        XCTAssertFalse(source.contains("GetDescription"))
    }

    private func validBytes() -> Data { Phase2ProductionJSONValue.object(validObject()).canonicalJSONBytes() }

    private func validObject() -> [String: Phase2ProductionJSONValue] {
        [
            "argument_omitted": .number("0"),
            "argument_truncated": .bool(false),
            "frame_index": .number("2"),
            "local_omitted": .number("0"),
            "local_truncated": .bool(false),
            "observed_pid": .number("812"),
            "observed_state": .string("stopped"),
            "observed_stop_id": .number("19"),
            "ok": .bool(true),
            "omitted_count": .number("0"),
            "pc": .number("268435520"),
            "schema": .number("1"),
            "static_omitted": .number("0"),
            "static_truncated": .bool(false),
            "thread_id": .number("4660"),
            "token": .string(token.map { String(format: "%02x", $0) }.joined()),
            "truncated": .bool(false),
            "variables": .array([
                variable(.argument, ordinal: 0, name: "argc", type: "int", value: "3"),
                variable(.local, ordinal: 0, name: "counter", type: "Counter", value: "{...}", summary: "active", children: 2),
                variable(.staticVariable, ordinal: 0, name: "globalFlag", type: "bool", value: "true"),
            ]),
        ]
    }

    private func variable(
        _ scope: LLDBVariableScope, ordinal: UInt32, name: String,
        type: String, value: String, summary: String? = nil, children: UInt32 = 0
    ) -> Phase2ProductionJSONValue {
        .object([
            "child_count": .number(String(children)),
            "diagnostic": .null,
            "has_children": .bool(children > 0),
            "name": .string(name),
            "ordinal": .number(String(ordinal)),
            "scope": .string(scope.rawValue),
            "state": .string("available"),
            "summary": summary.map(Phase2ProductionJSONValue.string) ?? .null,
            "type": .string(type),
            "value": .string(value),
        ])
    }

    private func assertFailure(
        _ data: Data,
        _ code: LLDBVariableSnapshotDiagnosticCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try LLDBVariableSnapshotDecoder().decodeCanonicalSnapshot(data), file: file, line: line) {
            XCTAssertEqual(($0 as? LLDBVariableSnapshotFailure)?.code, code, file: file, line: line)
        }
    }
}
