import Foundation
#if canImport(MacScope)
@testable import MacScope
#endif

extension MacIRConcreteEvaluator {
    /// Run before EVERY older preflight. Scan all interiors, including foreign
    /// frames. Dynamic groups are not an expansion of56 or59 compositions.
    func validateNEONContiguousRegisterPost(_ list: [MacIRInstruction]) throws {
        guard !list.contains(where: { $0.neonLaneCoefficientProduct != nil || $0.neonReplicatedIndexedProduct != nil }) else { throw Failure.unsupported("replicated product marker in standalone family") }
        guard list.contains(where: { $0.neonContiguousGroup?.frame.registerPost != nil }) else { return }
        // Formal authority is physical, not spelling-based: a Wn-bound formal
        // cannot be bypassed by a zero-version Xn register-shaped snapshot.
        // Existing55 validates argument projections and current versions below.
        func formalAuthority(_ value: MacIRValue, name: String) throws {
            guard case .register(_,0)=value,let n=A64MachineState.gprIndex(name) else { return }
            guard !function.parameters.contains(where: { parameter in
                if case let .gpr(index,_)=parameter.abiLocation { return index == n }
                return false
            }) else { throw Failure.unsupported("register post physical GPR formal alias") }
        }
        for i in list {
            guard i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonWiderMultiChannelLane == nil, i.neonWiderMultiChannelReplicate == nil, i.neonScalarShiftCompilerComposition == nil, i.neonScalarMaskSelection == nil, i.neonScalarIntegerComparison == nil, i.neonMultiChannelReplicate == nil else { throw Failure.unsupported("new82 complete interior exclusion") }
            if let f=i.neonContiguousGroup?.frame {
                try formalAuthority(f.oldBase,name:f.baseRegister)
                if let post=f.registerPost { try formalAuthority(post.oldIncrement,name:post.incrementRegister) }
            }
            guard i.neonFullWidthShift == nil, i.neonScalarVariableShift == nil, i.neonWiderChannelMemory == nil, i.neonMultiChannelLane == nil, i.neonFourChannelMemory == nil, i.neonMixedByteDotProduct == nil, i.neonByteMatrixAccumulate == nil, i.neonIndexedMixedByteDotProduct == nil, i.neonSelectedWideningAccumulate == nil, i.neonIndexedByteDotProduct == nil, i.neonThreeChannelMemory == nil,i.neonSignedLongMultiply == nil,
                  i.neonWideningAddSubtract == nil else {
                throw Failure.unsupported("register post competing newer metadata")
            }
        }
        // Actual55 full-list validator owns every ordinal, byte footprint, vector,
        // formal, base and return. Its narrow60 hook also validates oldIncrement.
        try validateNEONContiguousGroup(list)
    }
    mutating func capturedNEONContiguousPostDelta(_ f: MacIRNEONContiguousGroup) throws -> UInt64 {
        guard let post=f.registerPost else { return UInt64(f.fixedPostDelta) }
        let increment=try evaluate(post.oldIncrement)
        guard increment.width == post.carrierWidth,increment.kind != .float else {
            throw Failure.unsupported("register post complete64 increment snapshot")
        }
        return increment.bits
    }
}
