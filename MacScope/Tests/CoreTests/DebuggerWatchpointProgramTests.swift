import Foundation
import XCTest
@testable import MacScope

final class DebuggerWatchpointProgramTests: XCTestCase {
    private let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func testRangeValidationAndBoundedSingleLineCommands() throws {
        for size in [1, 2, 4, 8] {
            let command = try LLDBWatchpointProgram.command(
                for: .upsert(id: first, address: 0x1000, size: size, access: .readWrite, isEnabled: true),
                processID: 42, stopID: 7
            )
            XCTAssertFalse(command.contains("\n"))
            XCTAssertLessThan(command.utf8.count, 2_048)
        }
        for size in [-1, 0, 3, 16] {
            XCTAssertThrowsError(try DebuggerWatchpointRequest.validate(address: 0x1000, size: size))
        }
        XCTAssertThrowsError(try DebuggerWatchpointRequest.validate(address: 0x1001, size: 8))
        XCTAssertNoThrow(try DebuggerWatchpointRequest.validate(address: UInt64.max, size: 1))
        XCTAssertThrowsError(try DebuggerWatchpointRequest.validate(address: UInt64.max, size: 8))
        XCTAssertThrowsError(try LLDBWatchpointProgram.command(for: .refresh, processID: 0, stopID: 7))
        for command in LLDBWatchpointProgram.installCommands {
            XCTAssertFalse(command.contains("\n"))
            XCTAssertLessThan(command.utf8.count, 2_048)
        }
    }

    func testFakeBackendCreatesAllAccessModesAndPreservesLedgerAcrossInstall() throws {
        for access in DebuggerWatchpointAccess.allCases {
            let updates = try run([
                command(.upsert(id: first, address: 0x1000, size: 8, access: access, isEnabled: true)),
                "exec(source, globals())",
                command(.refresh),
                command(.setEnabled(id: first, isEnabled: false)),
                command(.setEnabled(id: first, isEnabled: true)),
                command(.remove(id: first)),
            ])
            XCTAssertEqual(updates.count, 5)
            XCTAssertTrue(updates.allSatisfy { $0.error == nil })
            XCTAssertEqual(updates[0].watchpoints.first?.access, access)
            XCTAssertEqual(updates[0], updates[1])
            XCTAssertEqual(updates[2].watchpoints.first?.isEnabled, false)
            XCTAssertEqual(updates[3].watchpoints.first?.isEnabled, true)
            XCTAssertTrue(updates[4].watchpoints.isEmpty)
        }
    }

    func testHardwareLimitIncludesForeignWatchpointsAndPreservesOriginalOnEdit() throws {
        let updates = try run([
            command(.upsert(id: first, address: 0x1000, size: 8, access: .write, isEnabled: true)),
            "target.capacity = 1",
            command(.upsert(id: second, address: 0x2000, size: 8, access: .read, isEnabled: true)),
            command(.upsert(id: first, address: 0x3000, size: 8, access: .readWrite, isEnabled: true)),
            "assert target.created == 1 and target.deleted == []",
            "target.capacity = 2; target.add_foreign(0x9000)",
            command(.upsert(id: second, address: 0x2000, size: 8, access: .read, isEnabled: true)),
            "assert target.created == 1 and target.deleted == []",
        ])
        XCTAssertNil(updates[0].error)
        for update in updates.dropFirst() {
            XCTAssertTrue(update.error?.contains("limit reached") == true)
            XCTAssertEqual(update.watchpoints, updates[0].watchpoints)
        }
    }

    func testProcessStopAndOwnershipChecksPreventMutation() throws {
        let updates = try run([
            command(.upsert(id: first, address: 0x1000, size: 4, access: .write, isEnabled: true)),
            "process.stop = 8",
            command(.remove(id: first)),
            "assert target.deleted == []; process.stop = 7; process.state = 6",
            command(.remove(id: first)),
            "assert target.deleted == []; process.state = 5; process.pid = 43",
            command(.remove(id: first)),
            "assert target.deleted == []; process.pid = 42; process.unique = 2",
            command(.remove(id: first)),
            "assert target.deleted == []",
        ])
        XCTAssertNil(updates[0].error)
        XCTAssertTrue(updates.dropFirst().allSatisfy { $0.error != nil })
        XCTAssertTrue(updates.last!.watchpoints.isEmpty)
    }

    func testSafeReplacementOverlapRefusalAndStaleIDRefresh() throws {
        let updates = try run([
            command(.upsert(id: first, address: 0x1000, size: 8, access: .write, isEnabled: true)),
            command(.upsert(id: first, address: 0x1000, size: 4, access: .read, isEnabled: true)),
            "assert target.created == 1 and target.deleted == []",
            command(.upsert(id: first, address: 0x2000, size: 4, access: .read, isEnabled: false)),
            "assert target.deleted == [1]; target.items.clear()",
            command(.refresh),
        ])
        XCTAssertNotNil(updates[1].error)
        XCTAssertEqual(updates[0].watchpoints, updates[1].watchpoints)
        XCTAssertNil(updates[2].error)
        XCTAssertEqual(updates[2].watchpoints.first?.id, first)
        XCTAssertEqual(updates[2].watchpoints.first?.backendID, 2)
        XCTAssertEqual(updates[2].watchpoints.first?.address, 0x2000)
        XCTAssertEqual(updates[2].watchpoints.first?.isEnabled, false)
        XCTAssertTrue(updates[3].watchpoints.isEmpty)
    }

    func testBackendFailuresReportActualSurvivorsWithoutRollbackClaims() throws {
        let updates = try run([
            "target.fail_create = True",
            command(.upsert(id: first, address: 0x1000, size: 8, access: .write, isEnabled: true)),
            "target.fail_create = False",
            command(.upsert(id: first, address: 0x1000, size: 8, access: .write, isEnabled: true)),
            "target.fail_delete = True",
            command(.upsert(id: first, address: 0x2000, size: 8, access: .read, isEnabled: true)),
        ])
        XCTAssertNotNil(updates[0].error)
        XCTAssertTrue(updates[0].watchpoints.isEmpty)
        XCTAssertNil(updates[1].error)
        XCTAssertTrue(updates[2].error?.contains("both are shown") == true)
        XCTAssertEqual(Set(updates[2].watchpoints.map(\.address)), [0x1000, 0x2000])
    }

    func testDecoderRejectsUncorrelatedExtraOutputDuplicateIDsAndOversizedResponse() throws {
        let update = DebuggerWatchpointUpdate(watchpoints: [
            DebuggerWatchpoint(id: first, address: 0x1000, size: 8, access: .write, isEnabled: true, backendID: 1),
        ], error: nil)
        let json = String(decoding: try JSONEncoder().encode(update), as: UTF8.self)
        let record = LLDBWatchpointProgram.marker + json + "\n"
        XCTAssertEqual(try LLDBWatchpointProgram.decode(transcript: record), update)
        for invalid in ["inferior output\n" + record, record + record, String(repeating: "x", count: 32_769)] {
            XCTAssertThrowsError(try LLDBWatchpointProgram.decode(transcript: invalid))
        }
        let duplicate = DebuggerWatchpointUpdate(watchpoints: update.watchpoints + update.watchpoints, error: nil)
        XCTAssertThrowsError(try LLDBWatchpointProgram.decode(
            transcript: LLDBWatchpointProgram.marker + String(decoding: JSONEncoder().encode(duplicate), as: UTF8.self)
        ))
    }

    private func command(_ request: DebuggerWatchpointRequest) throws -> String {
        String(try LLDBWatchpointProgram.command(for: request, processID: 42, stopID: 7).dropFirst("script ".count))
    }

    private func run(_ statements: [String]) throws -> [DebuggerWatchpointUpdate] {
        let source64 = Data(LLDBWatchpointProgram.source.utf8).base64EncodedString()
        let script = Self.fakeBackend + "\nsource = base64.b64decode('\(source64)').decode('utf-8')\nexec(source, globals())\n"
            + statements.joined(separator: "\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = CoreTestPipeDrain(stdout)
        let err = CoreTestPipeDrain(stderr)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: err.data(), as: UTF8.self))
        return try String(decoding: out.data(), as: UTF8.self).split(separator: "\n").map {
            try LLDBWatchpointProgram.decode(transcript: String($0))
        }
    }

    private static let fakeBackend = #"""
import sys, types, base64
class Error:
    def __init__(self): self.failed = False
    def Fail(self): return self.failed
    def GetCString(self): return 'fake refusal' if self.failed else None
class Watch:
    def __init__(self, ident=0, address=0, size=8, reads=False, writes=True):
        self.ident, self.address, self.size = ident, address, size
        self.reads, self.writes, self.enabled = reads, writes, True
    def IsValid(self): return self.ident > 0
    def GetID(self): return self.ident
    def GetWatchAddress(self): return self.address
    def GetWatchSize(self): return self.size
    def IsWatchingReads(self): return self.reads
    def IsWatchingWrites(self): return self.writes
    def IsEnabled(self): return self.enabled
    def SetEnabled(self, value): self.enabled = value
    def GetError(self): return Error()
class FakeProcess:
    def __init__(self): self.pid, self.stop, self.state, self.unique = 42, 7, 5, 1
    def IsValid(self): return True
    def GetProcessID(self): return self.pid
    def GetStopID(self): return self.stop
    def GetState(self): return self.state
    def GetUniqueID(self): return self.unique
    def GetNumSupportedHardwareWatchpoints(self, error): return target.capacity
class Target:
    def __init__(self):
        self.items, self.deleted, self.created, self.next_id = {}, [], 0, 1
        self.capacity, self.fail_create, self.fail_delete = 4, False, False
    def IsValid(self): return True
    def GetProcess(self): return process
    def GetNumWatchpoints(self): return len(self.items)
    def GetWatchpointAtIndex(self, index): return list(self.items.values())[index]
    def FindWatchpointByID(self, ident): return self.items.get(ident, Watch())
    def WatchAddress(self, address, size, reads, writes, error):
        if self.fail_create:
            error.failed = True
            return Watch()
        self.created += 1
        w = Watch(self.next_id, address, size, reads, writes)
        self.items[self.next_id] = w
        self.next_id += 1
        return w
    def DeleteWatchpoint(self, ident):
        if self.fail_delete: return False
        self.deleted.append(ident)
        return self.items.pop(ident, None) is not None
    def add_foreign(self, address):
        self.items[99] = Watch(99, address)
process, target = FakeProcess(), Target()
lldb = types.ModuleType('lldb')
lldb.SBError = Error
lldb.eStateStopped = 5
lldb.debugger = types.SimpleNamespace(GetSelectedTarget=lambda: target)
sys.modules['lldb'] = lldb
"""#
}
