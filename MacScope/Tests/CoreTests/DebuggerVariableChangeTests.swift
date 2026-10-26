import Foundation
import XCTest
@testable import MacScope

/// "Changed since the last stop" for variables (U6c), matched by frame, scope and path as registers
/// are matched by name.
final class DebuggerVariableChangeTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)

    private func coordinate(stop revision: UInt64, epoch: DebuggerSessionEpoch? = nil, frameIndex: Int = 0,
                            function: String = "main", programCounter: UInt64 = 0x2000) throws -> DebuggerInspectionCoordinate {
        let stop = DebuggerStopCoordinate(
            session: DebuggerSessionCoordinate(epoch: epoch ?? self.epoch, lifecycleRevision: DebuggerLifecycleRevision(rawValue: 3)),
            stopRevision: DebuggerStopRevision(rawValue: revision)
        )
        let identity = try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: 123,
            startTime: try XCTUnwrap(DebuggerProcessStartIdentity(seconds: 1_700_000_000, microseconds: 42)),
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture",
            executableDeviceID: 10,
            executableFileID: 1_123,
            executableByteCount: 4096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: nil,
            codeIdentity: nil
        ))
        let thread = try XCTUnwrap(DebuggerThreadIdentity(index: 1, tid: 0xabc))
        let frame = try XCTUnwrap(DebuggerFrameIdentity(thread: thread, frameIndex: frameIndex,
                                                         programCounter: programCounter, canonicalFunctionName: function))
        return try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: stop, targetAuthority: try DebuggerSessionTargetAuthority(origin: .attached(identity)),
            thread: thread, frame: frame
        ))
    }

    /// A locals scope: `count`, and `point` with `x` loaded as its child (paths are names).
    private func locals(_ coordinate: DebuggerInspectionCoordinate, count: String, x: String? = nil) throws -> DebuggerVariableScopeSnapshot {
        let child = try x.map { value in
            try XCTUnwrap(DebuggerVariableNode(
                id: try XCTUnwrap(DebuggerVariablePathToken(coordinate: coordinate, components: ["local", "1", "x"])),
                name: "x", typeName: "Int", value: .value(value), childCount: 0, pathComponents: ["point", "x"]
            ))
        }
        let nodes = [
            try XCTUnwrap(DebuggerVariableNode(
                id: try XCTUnwrap(DebuggerVariablePathToken(coordinate: coordinate, components: ["local", "0"])),
                name: "count", typeName: "Int", value: .value(count), childCount: 0
            )),
            try XCTUnwrap(DebuggerVariableNode(
                id: try XCTUnwrap(DebuggerVariablePathToken(coordinate: coordinate, components: ["local", "1"])),
                name: "point", typeName: "Point", value: .value("{...}"), childCount: 1,
                children: child.map { [$0] } ?? [], childExpansion: child == nil ? .notLoaded : .loaded
            )),
        ]
        return DebuggerVariableScopeSnapshot(coordinate: coordinate, scope: .locals, nodes: nodes, wasTruncated: false)
    }

    private func key(_ coordinate: DebuggerInspectionCoordinate, _ path: [String]) -> String {
        DebuggerVariableChanges.key(frame: coordinate.frame, scope: .locals, pathComponents: path)
    }

    func testAValueThatChangesBetweenStopsIsMarkedAndANewOneIsNot() throws {
        var changes = DebuggerVariableChanges()
        let first = try coordinate(stop: 1)
        changes.record([try locals(first, count: "1")])
        XCTAssertEqual(changes.changedKeys, [], "Nothing is marked at the first stop")

        let second = try coordinate(stop: 2, programCounter: 0x2010)
        changes.record([try locals(second, count: "2", x: "5")])
        XCTAssertEqual(changes.changedKeys, [key(second, ["count"])],
                       "count changed even though the program counter moved; x is new, so not marked")

        let third = try coordinate(stop: 3, programCounter: 0x2020)
        changes.record([try locals(third, count: "2", x: "6")])
        XCTAssertEqual(changes.changedKeys, [key(third, ["point", "x"])])
    }

    func testExpandingAChildAtTheSameStopComparesItWithThePreviousStop() throws {
        var changes = DebuggerVariableChanges()
        changes.record([try locals(try coordinate(stop: 1), count: "1", x: "5")])
        let second = try coordinate(stop: 2)
        changes.record([try locals(second, count: "2")])
        XCTAssertEqual(changes.changedKeys, [key(second, ["count"])])
        changes.record([try locals(second, count: "2", x: "9")])
        XCTAssertEqual(changes.changedKeys, [key(second, ["count"]), key(second, ["point", "x"])],
                       "A child loaded later is still compared with the previous stop, and earlier marks stay")
    }

    func testAnotherFrameOrSessionIsNeverComparedWithThisOne() throws {
        var changes = DebuggerVariableChanges()
        changes.record([try locals(try coordinate(stop: 1), count: "1")])
        changes.record([try locals(try coordinate(stop: 2, function: "helper"), count: "2")])
        XCTAssertEqual(changes.changedKeys, [], "A different function's count is a different variable")

        changes.record([try locals(try coordinate(stop: 3, function: "helper"), count: "3")])
        XCTAssertEqual(changes.changedKeys.count, 1)
        let otherSession = DebuggerSessionEpoch(rawValue: UUID())
        changes.record([try locals(try coordinate(stop: 1, epoch: otherSession, function: "helper"), count: "4")])
        XCTAssertEqual(changes.changedKeys, [], "A new debug session starts over")
    }

    func testRunningWithoutScopesKeepsTheMarks() throws {
        var changes = DebuggerVariableChanges()
        changes.record([try locals(try coordinate(stop: 1), count: "1")])
        changes.record([try locals(try coordinate(stop: 2), count: "2")])
        let marked = changes.changedKeys
        changes.record([])
        XCTAssertEqual(changes.changedKeys, marked)
        XCTAssertEqual(marked.count, 1)
    }

    func testThePresentationMarksChangedRows() throws {
        let coordinate = try coordinate(stop: 2)
        let presentation = DebuggerVariablesInspectionPresentation(
            inspectionCoordinate: coordinate,
            selectedFrame: nil,
            variableScopes: [try locals(coordinate, count: "2", x: "5")],
            changedVariableKeys: [key(coordinate, ["point", "x"])]
        )
        let rows = try XCTUnwrap(presentation.groups.first).rows
        XCTAssertEqual(rows.map(\.name), ["count", "point", "x"])
        XCTAssertEqual(rows.map(\.isChanged), [false, false, true])
    }
}
