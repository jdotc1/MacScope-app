import Foundation

enum Phase2DebuggerReadOperationID: String, CaseIterable, Equatable, Hashable, Sendable {
    case summary = "debugger.summary"
    case frames = "debugger.frames"
    case registers = "debugger.registers"
    case variables = "debugger.variables"
    case memory = "debugger.memory"
}
