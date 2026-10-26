import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    mutating func executeNEONWiderMultiChannelLane(_ f:MacIRNEONWiderMultiChannelLane) throws {
        let oldBase=try evaluate(f.oldBase)
        guard oldBase.width == 64,oldBase.kind != .float,oldBase.bits <= UInt64.max-UInt64(f.byteCount-1) else {
            throw Failure.unsupported("lane complete nonwrapping count-byte span")
        }
        // Capture ALL full128 old destinations or store sources before any effect.
        let oldVectors=try f.oldVectors.map { try readNEONRegister($0) }
        guard oldVectors.allSatisfy({ $0.width == 128 }) else { throw Failure.unsupported("lane full128 snapshots") }
        let sourceBytes=oldVectors.map { value in (0..<16).map { n in UInt8(truncatingIfNeeded:(n < 8 ? value.bits:value.high) >> ((n%8)*8)) } }
        let updated=oldBase.bits &+ UInt64(f.fixedPostDelta)
        if f.effect == .load {
            let captured=f.orderedTransfers.map { state.byte(at:oldBase.bits+UInt64($0.offset)) }
            let payloads=sourceBytes.enumerated().map { channel,old -> Scalar in
                var bytes=old
                for n in 0..<f.elementBytes { bytes[f.laneIndex*f.elementBytes+n]=captured[channel*f.elementBytes+n] }
                func half(_ start:Int)->UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[start+$1]) << ($1*8) } }
                return .init(bits:half(0),width:128,kind:.unsigned,high:half(8))
            }
            for n in 0..<f.channelCount { try writeNEONRegister(f.destinations[n],payloads[n]) }
        } else {
            let captured=sourceBytes.flatMap { Array($0[f.laneIndex*f.elementBytes..<(f.laneIndex+1)*f.elementBytes]) }
            for n in 0..<f.byteCount { state.setByte(captured[n],at:oldBase.bits+UInt64(n)) }
        }
        if let destination=f.baseDestination { try write(destination,.int(updated,width:64,signed:false)) }
    }
}
