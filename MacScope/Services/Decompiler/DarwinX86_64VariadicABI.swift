import Foundation

/// Darwin x86_64 ordinary C variadics, which follow the System V AMD64 ABI and differ
/// from Darwin arm64 at every step:
///
/// - Caller: anonymous arguments use the same registers as named ones (INTEGER in
///   rdi, rsi, rdx, rcx, r8, r9; SSE in xmm0-xmm7), then the stack in source order.
///   `al` carries an upper bound (0...8) on the vector registers the call uses, named
///   ones included; the callee prologue skips saving xmm0-xmm7 when it is zero.
/// - Callee: `va_list` is `__va_list_tag[1]`, a 24-byte record of `gp_offset`,
///   `fp_offset`, `overflow_arg_area` and `reg_save_area`. The 176-byte register save
///   area holds the six GPRs (bytes 0..<48) then the eight xmm registers (48..<176,
///   16 bytes each). `va_copy` copies the record, not the save area.
/// - `long double` is the 80-bit x87 type in a 16-byte, 16-aligned memory slot, so a
///   `%Lf` argument never travels in a register (on arm64 it is binary64, like `%f`).
///
/// Argument classes are inputs; nothing here classifies records or guesses a tail.
public enum DarwinX86_64Variadic {
    public static let profileID = "darwin-x86_64-sysv-c17-varargs-v1"
    public static let generalRegisterNames = ["rdi", "rsi", "rdx", "rcx", "r8", "r9"]
    public static let generalRegisterCount = 6
    public static let vectorRegisterCount = 8
    public static let generalSaveAreaByteCount = 48
    public static let registerSaveAreaByteCount = 176
    public static let vaListByteCount = 24
    public static let vaListAlignment = 8
    public static let maximumArguments = FormatStringParser.maximumArguments
    public static let maximumStackByteCount: UInt64 = 8192

    public struct VaListField: Equatable, Sendable {
        public let name: String
        public let byteOffset: Int
        public let byteCount: Int
    }

    public static let vaListFields = [
        VaListField(name: "gp_offset", byteOffset: 0, byteCount: 4),
        VaListField(name: "fp_offset", byteOffset: 4, byteCount: 4),
        VaListField(name: "overflow_arg_area", byteOffset: 8, byteCount: 8),
        VaListField(name: "reg_save_area", byteOffset: 16, byteCount: 8),
    ]

    public enum Fault: Error, Equatable, Sendable {
        case invalidNamedState
        case tooManyArguments
        case stackBudgetExceeded
    }

    /// The scalar classes a promoted variadic argument can have.
    public enum ArgumentClass: Hashable, Sendable {
        /// One INTEGER eightbyte: promoted integers, `long`, pointers.
        case integer
        /// `__int128`: two INTEGER eightbytes, both registers or neither.
        case integerPair
        /// One SSE eightbyte: `double` (a `float` argument is promoted to it).
        case sse
        /// `long double`: always memory, 16 bytes at 16-byte alignment.
        case x87

        var stackByteCount: UInt64 { self == .integerPair || self == .x87 ? 16 : 8 }
        var stackAlignment: UInt64 { stackByteCount }
    }

    /// The class of an argument a constant format consumes. `FormatStringParser` maps
    /// `%Lf` to `double` because that is exact on arm64; here the `L` length makes it x87.
    public static func argumentClass(of argument: FormatStringParser.Argument) -> ArgumentClass {
        guard argument.isFloatingPoint else { return .integer }
        let scalars = Array(argument.directive.unicodeScalars)
        return scalars.count >= 2 && scalars[scalars.count - 2] == "L" ? .x87 : .sse
    }

    public enum CallLocation: Hashable, Sendable {
        case gpr(index: Int)
        case gprPair(firstIndex: Int)
        case xmm(index: Int)
        /// Offset from the caller's SP at the call instruction.
        case stack(byteOffset: UInt64, byteCount: UInt64)
    }

    public struct CallPlan: Equatable, Sendable {
        public let locations: [CallLocation]
        /// Vector registers the whole call uses, named ones included: the least `al`.
        public let vectorRegistersUsed: Int
        public let outgoingStackByteCount: UInt64

        /// An observed `al` above 8 is malformed; one below the used count cannot be
        /// the caller of this plan.
        public func admits(observedAL al: UInt8) -> Bool {
            Int(al) <= vectorRegisterCount && Int(al) >= vectorRegistersUsed
        }
    }

    /// Caller-side locations of the anonymous `tail`, after the named prefix used
    /// `namedGPRs` GPRs, `namedVectorRegisters` xmm registers and `namedStackByteCount`
    /// bytes of outgoing stack. An argument that does not fit the remaining registers
    /// goes to the stack whole, and later smaller arguments may still use registers.
    public static func callPlan(
        namedGPRs: Int,
        namedVectorRegisters: Int,
        namedStackByteCount: UInt64 = 0,
        tail: [ArgumentClass]
    ) throws -> CallPlan {
        guard (0...generalRegisterCount).contains(namedGPRs),
              (0...vectorRegisterCount).contains(namedVectorRegisters),
              namedStackByteCount <= maximumStackByteCount else { throw Fault.invalidNamedState }
        guard tail.count <= maximumArguments else { throw Fault.tooManyArguments }
        var gpr = namedGPRs
        var xmm = namedVectorRegisters
        var stack = aligned(namedStackByteCount, to: 8)
        var locations: [CallLocation] = []
        for argumentClass in tail {
            switch argumentClass {
            case .integer where gpr < generalRegisterCount:
                locations.append(.gpr(index: gpr))
                gpr += 1
                continue
            case .integerPair where gpr + 2 <= generalRegisterCount:
                locations.append(.gprPair(firstIndex: gpr))
                gpr += 2
                continue
            case .sse where xmm < vectorRegisterCount:
                locations.append(.xmm(index: xmm))
                xmm += 1
                continue
            default:
                break
            }
            let offset = aligned(stack, to: argumentClass.stackAlignment)
            stack = offset + argumentClass.stackByteCount
            guard stack <= maximumStackByteCount else { throw Fault.stackBudgetExceeded }
            locations.append(.stack(byteOffset: offset, byteCount: argumentClass.stackByteCount))
        }
        return CallPlan(locations: locations, vectorRegistersUsed: xmm, outgoingStackByteCount: stack)
    }

    public enum VaArgSource: Hashable, Sendable {
        /// Offset into the callee's register save area (`reg_save_area`).
        case registerSaveArea(byteOffset: Int, byteCount: Int)
        /// Offset into the incoming argument area, which starts at callee-entry RSP + 8
        /// (past the return address) and is 16-byte aligned. It is the same offset the
        /// caller's `CallLocation.stack` gives from its SP at the call.
        case overflowArea(byteOffset: UInt64, byteCount: UInt64)
    }

    /// The `va_list` record's state, as `va_start` sets it and `va_arg` advances it.
    /// Value semantics make a copy an independent `va_copy`.
    public struct VaListState: Equatable, Sendable {
        public private(set) var gpOffset: Int
        public private(set) var fpOffset: Int
        /// `overflow_arg_area` as an offset into the incoming argument area.
        public private(set) var overflowAreaByteOffset: UInt64

        public init(namedGPRs: Int, namedVectorRegisters: Int, namedStackByteCount: UInt64 = 0) throws {
            guard (0...generalRegisterCount).contains(namedGPRs),
                  (0...vectorRegisterCount).contains(namedVectorRegisters),
                  namedStackByteCount <= maximumStackByteCount else { throw Fault.invalidNamedState }
            gpOffset = namedGPRs * 8
            fpOffset = generalSaveAreaByteCount + namedVectorRegisters * 16
            overflowAreaByteOffset = aligned(namedStackByteCount, to: 8)
        }

        /// `va_arg` for one argument of `argumentClass`.
        public mutating func next(_ argumentClass: ArgumentClass) throws -> VaArgSource {
            switch argumentClass {
            case .integer where gpOffset <= generalSaveAreaByteCount - 8:
                defer { gpOffset += 8 }
                return .registerSaveArea(byteOffset: gpOffset, byteCount: 8)
            case .integerPair where gpOffset <= generalSaveAreaByteCount - 16:
                defer { gpOffset += 16 }
                return .registerSaveArea(byteOffset: gpOffset, byteCount: 16)
            case .sse where fpOffset <= registerSaveAreaByteCount - 16:
                defer { fpOffset += 16 }
                return .registerSaveArea(byteOffset: fpOffset, byteCount: 8)
            default:
                let offset = aligned(overflowAreaByteOffset, to: argumentClass.stackAlignment)
                let end = offset + argumentClass.stackByteCount
                guard end <= maximumStackByteCount else { throw Fault.stackBudgetExceeded }
                overflowAreaByteOffset = end
                return .overflowArea(byteOffset: offset, byteCount: argumentClass.stackByteCount)
            }
        }
    }

    /// Operands here are bounded by `maximumStackByteCount`, so this cannot overflow.
    static func aligned(_ value: UInt64, to alignment: UInt64) -> UInt64 {
        (value + alignment - 1) & ~(alignment - 1)
    }
}
