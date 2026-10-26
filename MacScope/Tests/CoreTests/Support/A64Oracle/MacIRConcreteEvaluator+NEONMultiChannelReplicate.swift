import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    mutating func executeNEONMultiChannelReplicate(_ f:MacIRNEONMultiChannelReplicate) throws {
        let old=try evaluate(f.oldBase)
        guard old.width == 64,old.kind != .float,old.bits <= UInt64.max-UInt64(f.byteCount-1) else {
            throw Failure.unsupported("replicate complete nonwrapping channel-byte span")
        }
        // Capture ALL channel bytes and old base before the first destination.
        // Only count bytes are read, independently of 8/16 active vector bytes.
        let captured=f.orderedReads.map { state.byte(at:old.bits+UInt64($0.offset)) }
        let payloads=captured.map { byte -> Scalar in
            let repeated=(0..<8).reduce(UInt64(0)) { $0 | UInt64(byte)<<($1*8) }
            return .init(bits:repeated,width:128,kind:.unsigned,high:f.activeBytes == 16 ? repeated:0)
        }
        let updated=old.bits &+ UInt64(f.fixedPostDelta)
        for n in 0..<f.channelCount { try writeNEONRegister(f.vectors[n],payloads[n]) }
        if let destination=f.baseDestination { try write(destination,.int(updated,width:64,signed:false)) }
    }
}
