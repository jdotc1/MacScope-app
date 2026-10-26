import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    mutating func executeNEONWiderMultiChannelReplicate(_ f:MacIRNEONWiderMultiChannelReplicate) throws {
        let old=try evaluate(f.oldBase)
        guard old.width == 64,old.kind != .float,old.bits <= UInt64.max-UInt64(f.byteCount-1) else {
            throw Failure.unsupported("replicate complete nonwrapping channel-byte span")
        }
        // Capture the exact small span before any vector/base definition.
        let captured=f.orderedReads.map { state.byte(at:old.bits+UInt64($0.offset)) }
        let payloads=(0..<f.channelCount).map { channel -> Scalar in
            var repeated: UInt64 = 0
            for byte in 0..<8 {
                repeated |= UInt64(captured[channel*f.elementBytes + byte%f.elementBytes]) << (byte*8)
            }
            return .init(bits:repeated,width:128,kind:.unsigned,high:f.activeBytes == 16 ? repeated:0)
        }
        let updated=old.bits &+ UInt64(f.fixedPostDelta)
        for n in 0..<f.channelCount { try writeNEONRegister(f.vectors[n],payloads[n]) }
        if let destination=f.baseDestination { try write(destination,.int(updated,width:64,signed:false)) }
    }
}
