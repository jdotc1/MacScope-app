import Foundation
@testable import MacScope

extension MacIRConcreteEvaluator {
    /// Executes the actual typed .load/.store IR, using oracle memory only as
    /// seeded concrete state. This is not an image loader or fault simulator.
    /// Validate everything and collect all bytes before changing any payload.
    mutating func executeNEONBufferMemory(_ descriptor: MacIRNEONBufferMemory, operation: MacIROperation,
                                         memoryAccess: MacIRMemoryAccess?) throws {
        guard memoryAccess == MacIRMemoryAccess(byteWidth: 16) else {
            throw Failure.unsupported("NEON buffer access width")
        }
        let carrier: MacIRValue
        switch (descriptor.effect, operation) {
        case let (.load, .load(destination, address)) where address == descriptor.address: carrier = destination
        case let (.store, .store(source, address)) where address == descriptor.address: carrier = source
        default: throw Failure.unsupported("NEON buffer effect/address shape")
        }
        guard case let .register(name, version) = carrier, let index = A64MachineState.vectorIndex(name),
              name == "v\(index)", version >= (descriptor.effect == .load ? 1 : 0) else {
            throw Failure.unsupported("NEON buffer carrier")
        }
        let base = try evaluate(descriptor.base)
        guard base.width == 64, base.kind != .float else { throw Failure.unsupported("NEON buffer base") }
        let (address, overflow) = base.bits.addingReportingOverflow(descriptor.byteOffset)
        guard !overflow, address <= UInt64.max - 15 else { throw Failure.unsupported("NEON buffer address span") }
        let addresses = (0..<16).map { address + UInt64($0) }
        switch descriptor.effect {
        case .load:
            let bytes = addresses.map { state.byte(at: $0) }
            func half(_ start: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[start + $1]) << ($1 * 8) } }
            try writeNEONRegister(carrier, .init(bits: half(0), width: 128, kind: .unsigned, high: half(8)))
        case .store:
            let value = try readNEONRegister(carrier)
            let bytes = (0..<16).map { UInt8(truncatingIfNeeded: ($0 < 8 ? value.bits : value.high) >> (($0 % 8) * 8)) }
            for (address, byte) in zip(addresses, bytes) { state.setByte(byte, at: address) }
        }
    }
}
