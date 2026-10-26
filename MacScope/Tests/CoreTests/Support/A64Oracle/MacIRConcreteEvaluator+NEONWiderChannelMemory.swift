import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    mutating func executeNEONWiderChannelMemory(_ f:MacIRNEONWiderChannelMemory) throws {
        let oldBase=try evaluate(f.oldBase)
        guard oldBase.width == 64,oldBase.kind != .float,oldBase.bits <= UInt64.max - UInt64(f.byteCount - 1) else {
            throw Failure.unsupported("wider channels complete nonwrapping span")
        }
        // Snapshot ALL old full128 destinations or store sources before any payload.
        let sources=try f.oldVectors.map { try readNEONRegister($0) }
        guard sources.allSatisfy({ $0.width == 128 }) else { throw Failure.unsupported("wider channels full128 captures") }
        let sourceBytes=sources.map { value in (0..<16).map { n in
            UInt8(truncatingIfNeeded:(n < 8 ? value.bits : value.high) >> ((n % 8) * 8))
        } }
        let transfers=f.orderedTransfers
        // All channel-element bytes are captured before ANY destination/store definition.
        let captured=transfers.map { b in f.effect == .load ? state.byte(at:oldBase.bits + UInt64(b.offset)) : sourceBytes[b.channel][b.vectorByte] }
        if f.effect == .load {
            var payloads=[[UInt8]](repeating:[UInt8](repeating:0,count:16),count:f.channelCount)
            for (index,b) in transfers.enumerated() { payloads[b.channel][b.vectorByte]=captured[index] }
            // Zero-initialized high half gives Q0 full128 replacement, not lane insertion.
            for channel in 0..<f.channelCount {
                func half(_ start:Int)->UInt64 { (0..<8).reduce(0) { $0 | (UInt64(payloads[channel][start + $1]) << ($1 * 8)) } }
                try writeNEONRegister(f.destinations[channel],.init(bits:half(0),width:128,kind:.unsigned,high:half(8)))
            }
        } else {
            for (index,b) in transfers.enumerated() { state.setByte(captured[index],at:oldBase.bits + UInt64(b.offset)) }
        }
        if let destination=f.baseDestination { try write(destination,.int(oldBase.bits &+ UInt64(f.fixedPostDelta),width:64,signed:false)) }
    }
}
