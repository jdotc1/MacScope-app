import Foundation

// Typed MacIR facts drive semantic rendering independently of source diagnostics.
extension PseudocodePrinter {
    /// Semantic rendering consults typed IR fields, never assembly diagnostics.
    /// The fallback remains byte-identical for legacy instructions without these facts.
    func render(instruction: MacIRInstruction, names: PseudocodeNameContext) -> String {
        let operation = instruction.operation
        if let cell = instruction.fpArchitecturalClobber {
            guard case let .assign(destination, .unknown(reason)) = operation,
                  destination == .symbol(cell.rawValue), reason == "architectural_state_clobber" else {
                return "__unknown_architectural_state_effect()"
            }
            return "\(cell.rawValue) = __unknown_architectural_state()"
        }
        if let qc = instruction.neonQC {
            guard case let .intrinsic(destination?, name, arguments) = operation,
                  destination == qc.output, name == "a64_neon_sticky_qc",
                  arguments == [qc.input] + qc.arguments else { return "__unknown_qc_effect()" }
            let inputs = qc.arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "__neon_qc |= __\(qc.lane.intrinsicName)_saturates(\(inputs)); /* entry QC unknown; sticky */"
        }
        if let effect = instruction.vectorFP {
            guard case let .intrinsic(destination?, name, arguments) = operation,
                  destination == effect.numericOutput, name == effect.semantics.intrinsicName,
                  arguments == effect.numericArguments else { return "__unknown_vector_fp_effect()" }
            let inputs = effect.arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            let control: String
            if case .immediate = effect.fpcrInput { control = valueText(for: effect.fpcrInput, names: names) }
            else { control = "__fpcr" }
            let rounding = effect.semantics.rounding == .instructionTowardZero
                ? "instruction_toward_zero" : "__fpcr.RMode"
            return "\(valueText(for: destination, names: names)) = __\(name)(\(inputs), \(control), __fp_execution_context, __fpsr_exceptions); /* normal completion; FPCR/FPSR entry unknown; rounding=\(rounding); FZ/DN/AH/enables symbolic; may trap on access or enabled IEEE exception */"
        }
        if let effect = instruction.vectorFPStatus {
            guard case let .assign(destination, value) = operation,
                  destination == effect.exceptionOutput, value == effect.normalExceptionResult else {
                return "__unknown_vector_fp_status_effect()"
            }
            let prior: String
            if case .immediate = effect.exceptionInput { prior = valueText(for: effect.exceptionInput, names: names) }
            else { prior = "__fpsr_exceptions" }
            return "__fpsr_exceptions = (\(prior) | __unknown_fp_raised_exceptions()) & 0x9f; /* normal completion only; QC unchanged */"
        }
        if let blocked = instruction.fpBlockedEffect {
            guard case .unknown = operation else { return "__unknown_fp_environment_effect()" }
            let rounding = blocked.requestedRounding == .instructionTowardZero
                ? "instruction_toward_zero" : "unknown_fpcr_rounding"
            // Do not turn conditional normal-completion state into a definition.
            return "__unknown_fp_environment(\(blocked.requestedOperation.rawValue), \(rounding), fpcr=\(valueText(for: blocked.fpcrInput, names: names)), fpsr_exceptions=\(valueText(for: blocked.exceptionInput, names: names))); /* invalid encoding or unsupported vector shape; controls remain unknown */"
        }
        if names.ordinarySSAMemoryEffects,
           case let .assign(destination, source) = operation,
           case let .register(register, _) = destination,
           MacIRBuilder.integerRegisterView(register)?.width == 64,
           emittedPointerType(for: destination, names: names) == nil,
           emittedRecordPointer(source, names: names) != nil {
            return "\(valueText(for: destination, names: names)) = (uint64_t)(\(valueText(for: source, names: names)))"
        }
        if names.ordinarySSAMemoryEffects, case let .assign(destination, source) = operation,
           case let .register(register, _) = destination, case .register = source,
           names.addressBaseRegisters.contains(destination),
           MacIRBuilder.integerRegisterView(register)?.width == 64 {
            return "\(valueText(for: destination, names: names)) = (uint64_t)(\(valueText(for: source, names: names)))"
        }
        // A PC-relative address is a 64-bit pointer value, not an int literal.
        // The same holds for a MOV immediate: the register keeps its own width.
        if names.ordinarySSAMemoryEffects, ["adr", "mov", "movz"].contains(instruction.source.mnemonic),
           case let .assign(destination, .immediate(constant)) = operation, constant >= 0,
           case let .register(register, _) = destination,
           let width = MacIRBuilder.integerRegisterView(register)?.width, width == 32 || width == 64,
           width == 64 || constant <= Int64(UInt32.max) {
            return "\(valueText(for: destination, names: names)) = (uint\(width)_t)\(valueText(for: .immediate(constant), names: names))"
        }
        if !names.unsignedSelectorDestinations.isEmpty,
           case let .binary(destination, "-", left, right) = operation,
           names.unsignedSelectorDestinations.contains(destination),
           case let .register(register, _) = destination,
           MacIRBuilder.integerRegisterView(register)?.width == 32 {
            return "\(valueText(for: destination, names: names)) = (uint32_t)((uint32_t)(\(valueText(for: left, names: names))) - \(valueText(for: right, names: names)))"
        }
        if case .call = operation, !names.resolvedIndirectCalls.isEmpty,
           names.renderingCallAddress != instruction.source.address {
            var scoped = names
            scoped.renderingCallAddress = instruction.source.address
            return render(instruction: instruction, names: scoped)
        }
        // A QC-setting lane op keeps its sticky effect in the IR; the update is
        // printed only when FPSR is read later, like other dead flag writes.
        if let lane = instruction.neonLaneOp, lane.setsQC, names.observesFPSR, !instruction.neonQCIsSeparate,
           case let .intrinsic(destination?, name, arguments) = operation {
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __\(name)(\(inputs)); __neon_qc |= __\(name)_saturates(\(inputs))"
        }
        if let effect = instruction.fpEnvironment {
            guard case let .intrinsic(destination?, name, arguments) = operation,
                  destination == effect.numericResult,
                  name == effect.intrinsicName,
                  arguments == [effect.left, effect.right, effect.fpcrInput, effect.fpsrInput] else {
                return "__unknown_fp_environment_effect()"
            }
            let output = valueText(for: effect.numericResult, names: names)
            let status = valueText(for: effect.fpsrOutput, names: names)
            let inputs = arguments.map { valueText(for: $0, names: names) }
            return "__\(name)(&\(output), &\(status), \(inputs.joined(separator: ", ")))"
        }
        if let comparison = instruction.neonScalarIntegerComparison,
           MacIRNEONScalarIntegerComparison(encodedWord: comparison.encodedWord) == comparison,
           instruction.memoryAccess == nil, instruction.returnTarget == nil,
           case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 2,
           case let .register(destinationName, _) = destination, destinationName == "v\(comparison.destination)",
           case let .register(leftName, _) = arguments[0], leftName == "v\(comparison.lhs)",
           case let .register(rightName, _) = arguments[1], rightName == "v\(comparison.rhs)" {
            let left = valueText(for: arguments[0], names: names)
            let right = valueText(for: arguments[1], names: names)
            let predicate: String
            switch comparison.kind {
            case .cmeq: predicate = "equal_low64_bits"
            case .cmgt: predicate = "signed_low64_greater"
            case .cmge: predicate = "signed_low64_greater_equal"
            case .cmhi: predicate = "unsigned_low64_greater"
            case .cmhs: predicate = "unsigned_low64_greater_equal"
            case .cmtst: predicate = "low64_bitwise_and_nonzero"
            }
            // The helper captures both full128 SSA operands before any aliased
            // destination write, tests only their low64, and returns a full128
            // value: low64 is UINT64_MAX or zero; high64 is always zero.
            return "\(valueText(for: destination, names: names)) = __neon_\(comparison.kind.rawValue)_\(predicate)_captured_full128_mask64_zero_high64(\(left), \(right))"
        }
        if let shift = instruction.neonScalarVariableShift,
           case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 2 {
            let value = valueText(for: arguments[0], names: names)
            let count = valueText(for: arguments[1], names: names)
            let rounding = shift.isRounded ? "rounded_ties_positive_infinity" : "unrounded"
            let sign = shift.isSigned ? "signed" : "unsigned"
            return "\(valueText(for: destination, names: names)) = __neon_\(shift.kind.rawValue)_\(sign)64_signed_low8_count_\(rounding)_zero_high64(\(value), \(count))"
        }
        if let step = instruction.neonWiderChannelMemory,
           step.frame.matches(operation, ordinal: step.ordinal) {
            let frame = step.frame
            let base = valueText(for: .unary(op: "(uint64_t)", value: frame.oldBase), names: names)
            let shape = "u\(frame.elementBytes * 8)_frame\(frame.frameSequence)"
            if step.ordinal == frame.baseOrdinal, let destination = frame.baseDestination {
                return "\(valueText(for: destination, names: names)) = \(base) + 0x\(String(frame.fixedPostDelta, radix: 16))"
            }
            if step.ordinal < frame.byteCount {
                let transfer = frame.orderedTransfers[step.ordinal]
                let address = "\(base) + 0x\(String(transfer.offset, radix: 16))"
                let part = "channel_\(transfer.channel)_lane\(transfer.lane)_element_byte\(transfer.elementByte)"
                if frame.effect == .load {
                    return "__neon_ld\(frame.channelCount)_\(shape)_capture_\(part)(\(address))"
                }
                let old = valueText(for: frame.oldVectors[transfer.channel], names: names)
                return "__neon_st\(frame.channelCount)_\(shape)_\(part)(\(address), __vector_byte(\(old), \(transfer.vectorByte)))"
            }
            let channel = step.ordinal - frame.byteCount
            let destination = valueText(for: frame.destinations[channel], names: names)
            let upper = frame.activeBytes == 8 ? "zero_high64" : "full128"
            return "\(destination) = __neon_ld\(frame.channelCount)_\(shape)_commit_captured_channel_\(channel)_\(upper)()"
        }
        if let step = instruction.neonWiderMultiChannelLane,
           step.frame.matches(operation, ordinal: step.ordinal) {
            let frame = step.frame
            let base = valueText(for: .unary(op: "(uint64_t)", value: frame.oldBase), names: names)
            if step.ordinal == frame.channelCount, let destination = frame.baseDestination {
                // Architectural UInt64 addition follows all captured channel payloads.
                return "\(valueText(for: destination, names: names)) = \(base) + 0x\(String(frame.fixedPostDelta, radix: 16))"
            }
            let channel = step.ordinal
            let old = valueText(for: frame.oldVectors[channel], names: names)
            let shape = "u\(frame.elementBytes * 8)_frame\(frame.frameSequence)_channel_\(channel)_byteoffset\(channel * frame.elementBytes)_lane\(frame.laneIndex)_span\(frame.byteCount)"
            // Q selects a lane, never an active width. Each helper uses the
            // frame's captured old base, all OLD full128 vectors and source bytes.
            // Channel c accesses elementBytes at oldBase + c * elementBytes.
            if frame.effect == .load {
                let destination = valueText(for: frame.destinations[channel], names: names)
                return "\(destination) = __neon_ld\(frame.channelCount)_\(shape)_little_endian_captured_preserve_other\(128 - frame.elementBytes * 8)(\(base), \(old))"
            }
            return "__neon_st\(frame.channelCount)_\(shape)_little_endian_captured_element(\(base), \(old))"
        }
        if let step = instruction.neonWiderMultiChannelReplicate,
           step.frame.matches(operation, ordinal: step.ordinal) {
            let frame = step.frame
            let base = valueText(for: .unary(op: "(uint64_t)", value: frame.oldBase), names: names)
            if step.ordinal == frame.channelCount, let destination = frame.baseDestination {
                return "\(valueText(for: destination, names: names)) = \(base) + 0x\(String(frame.fixedPostDelta, radix: 16))"
            }
            let channel = step.ordinal
            let destination = valueText(for: frame.vectors[channel], names: names)
            let upper = frame.activeBytes == 8 ? "zero_high64" : "full128"
            // Capture the complete scalar span before any vector/base commit;
            // repeat channel c's intact little-endian element, not each byte.
            let shape = "u\(frame.elementBytes * 8)_frame\(frame.frameSequence)_channel_\(channel)_byteoffset\(channel * frame.elementBytes)_readspan\(frame.byteCount)"
            return "\(destination) = __neon_ld\(frame.channelCount)r_\(shape)_captured_little_endian_element_broadcast_active\(frame.activeBytes)_\(upper)(\(base))"
        }
        if let step = instruction.neonMultiChannelLane,
           step.frame.matches(operation, ordinal: step.ordinal) {
            let frame = step.frame
            let base = valueText(for: .unary(op: "(uint64_t)", value: frame.oldBase), names: names)
            if step.ordinal == frame.channelCount, let destination = frame.baseDestination {
                return "\(valueText(for: destination, names: names)) = \(base) + 0x\(String(frame.fixedPostDelta, radix: 16))"
            }
            let old = valueText(for: frame.oldVectors[step.ordinal], names: names)
            let shape = "u8_channel_\(step.ordinal)_lane\(frame.laneIndex)_span\(frame.byteCount)"
            if frame.effect == .load {
                let destination = valueText(for: frame.destinations[step.ordinal], names: names)
                return "\(destination) = __neon_ld\(frame.channelCount)_\(shape)_preserve_other120(\(base), \(old))"
            }
            return "__neon_st\(frame.channelCount)_\(shape)(\(base), \(old))"
        }
        if let step = instruction.neonMultiChannelReplicate,
           step.frame.matches(operation, ordinal: step.ordinal) {
            let frame = step.frame
            let base = valueText(for: .unary(op: "(uint64_t)", value: frame.oldBase), names: names)
            if step.ordinal == frame.channelCount, let destination = frame.baseDestination {
                return "\(valueText(for: destination, names: names)) = \(base) + 0x\(String(frame.fixedPostDelta, radix: 16))"
            }
            let vector = valueText(for: frame.vectors[step.ordinal], names: names)
            let upper = frame.activeBytes == 8 ? "zero_high64" : "full128"
            // One source byte at channel offset c; total read span is count,
            // independent of the active width of each resulting vector.
            return "\(vector) = __neon_ld\(frame.channelCount)r_u8_channel_\(step.ordinal)_readspan\(frame.byteCount)_broadcast_active\(frame.activeBytes)_\(upper)(\(base))"
        }
        if let step = instruction.neonFourChannelMemory,
           step.frame.matches(operation, ordinal: step.ordinal) {
            let frame = step.frame
            let base = valueText(for: .unary(op: "(uint64_t)", value: frame.oldBase), names: names)
            if step.ordinal == frame.groupCount, let destination = frame.baseDestination {
                return "\(valueText(for: destination, names: names)) = \(base) + 0x\(String(frame.fixedPostDelta, radix: 16))"
            }
            // Channel c accesses only bytes base + 4*lane + c. A channel is
            // neither a contiguous Q access nor a second memory transfer.
            let channel = step.ordinal
            let vector = valueText(for: frame.vectors[channel], names: names)
            let shape = "u8_stride4_channel_\(channel)_active\(frame.activeBytes)_footprint\(frame.byteCount)"
            if frame.effect == .load {
                let upper = frame.activeBytes == 8 ? "zero_high64" : "full128"
                return "\(vector) = __neon_gather4_\(shape)_\(upper)(\(base))"
            }
            return "__neon_scatter4_\(shape)(\(base), \(vector))"
        }
        if let step = instruction.neonThreeChannelMemory,
           step.frame.matches(operation, ordinal: step.ordinal) {
            let frame = step.frame
            let base = valueText(for: .unary(op: "(uint64_t)", value: frame.oldBase), names: names)
            if step.ordinal == frame.groupCount, let destination = frame.baseDestination {
                return "\(valueText(for: destination, names: names)) = \(base) + 0x\(String(frame.fixedPostDelta, radix: 16))"
            }
            // Channel c accesses only bytes base + 3*lane + c. A channel is
            // neither a contiguous Q access nor a second memory transfer.
            let channel = step.ordinal
            let vector = valueText(for: frame.vectors[channel], names: names)
            let shape = "u8_stride3_channel_\(channel)_active\(frame.activeBytes)_footprint\(frame.byteCount)"
            if frame.effect == .load {
                let upper = frame.activeBytes == 8 ? "zero_high64" : "full128"
                return "\(vector) = __neon_gather3_\(shape)_\(upper)(\(base))"
            }
            return "__neon_scatter3_\(shape)(\(base), \(vector))"
        }
        if let matrix = instruction.neonByteMatrixAccumulate,
           case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 3 {
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_matrix2x8_8x2_first_\(matrix.firstExtension.rawValue)8_second_\(matrix.secondExtension.rawValue)8_rowmajor_old32_accumulate_mod32_full128(\(inputs))"
        }
        if let dot = instruction.neonIndexedMixedByteDotProduct,
           case let .intrinsic(destination?, _, arguments) = operation, arguments.count == 3 {
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            let upper = dot.activeBytes == 8 ? "zero_high64" : "full128"
            return "\(valueText(for: destination, names: names)) = __neon_indexed_\(dot.kind.rawValue)_first_\(dot.firstRole.rawValue)8_coefficient_\(dot.coefficientRole.rawValue)8_full128_group\(dot.selectedGroup)_old32_accumulate_mod32_active\(dot.activeBytes)_\(upper)(\(inputs))"
        }
        if let dot = instruction.neonMixedByteDotProduct,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == 3 {
            let upper = dot.activeBytes == 8 ? "zero_high64" : "full128"
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_usdot_first_unsigned8_second_signed8_groups4_old32_accumulate_mod32_active\(dot.activeBytes)_\(upper)(\(inputs))"
        }
        if let shift = instruction.neonFullWidthShift,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == 1 {
            let half = shift.sourceHighHalf ? "high64" : "low64"
            let source = valueText(for: arguments[0], names: names)
            return "\(valueText(for: destination, names: names)) = __neon_shll_unsigned\(shift.narrowBits)_first_\(half)_zero_extend_shift\(shift.shift)_full128(\(source))"
        }
        if let polynomial = instruction.neonBytePolynomialMultiply,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == 2 {
            let upper = polynomial.activeBytes == 8 ? "zero_high64" : "full128"
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_pmul_gf2_coefficient_xor_truncate_low8_active\(polynomial.activeBytes)_\(upper)(\(inputs))"
        }
        if let product = instruction.neonSelectedWideningAccumulate,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == 3 {
            let half = product.sourceHighHalf ? "high64" : "low64"
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_selected_\(product.signedness.rawValue)\(product.narrowBits)_first_\(half)_coefficient_lane\(product.selectedLane)_full128_oldwide_\(product.kind.rawValue)_product_mod\(product.outputLaneBits)(\(inputs))"
        }
        if let dot = instruction.neonIndexedByteDotProduct,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == 3 {
            let sign = dot.isSigned ? "signed" : "unsigned"
            let upper = dot.activeBytes == 8 ? "zero_high64" : "full128"
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_\(dot.kind.rawValue)_\(sign)8_selected4bytegroup\(dot.selectedGroup)_from_full128_old32_accumulate_mod32_active\(dot.activeBytes)_\(upper)(\(inputs))"
        }
        if let dot = instruction.neonByteDotProduct,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == 3 {
            let sign = dot.isSigned ? "signed" : "unsigned"
            let upper = dot.activeBytes == 8 ? "zero_high64" : "full128"
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_\(dot.kind.rawValue)_\(sign)8_groups4_old32_accumulate_mod32_active\(dot.activeBytes)_\(upper)(\(inputs))"
        }
        if let selected = instruction.neonSelectedUnsignedMultiply,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == 2 {
            let half = selected.sourceHighHalf ? "high64" : "low64"
            let kind = selected.sourceHighHalf ? "umull2" : "umull"
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_\(kind)_first_unsigned\(selected.narrowBits)_\(half)_coefficient_unsigned\(selected.narrowBits)_lane\(selected.selectedLane)_full128_zero_extend_then_multiply_mod\(selected.outputLaneBits)(\(inputs))"
        }
        if let selected = instruction.neonSelectedSignedMultiply,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == 2 {
            let half = selected.sourceHighHalf ? "high64" : "low64"
            let kind = selected.sourceHighHalf ? "smull2" : "smull"
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_\(kind)_first_signed\(selected.narrowBits)_\(half)_coefficient_signed\(selected.narrowBits)_lane\(selected.selectedLane)_full128_sign_extend_then_multiply_mod\(selected.outputLaneBits)(\(inputs))"
        }
        if let rounded = instruction.neonRoundedShift,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == 1 {
            // Each lane is floor((x + 2^(shift-1)) / 2^shift) in extended
            // precision, then reduced to its original width. Signed ties go
            // toward +infinity; unsigned64 retains the rounding carry. At the
            // width endpoint, signed lanes yield zero and unsigned lanes their
            // original top bit, without a host shift by 64.
            let signedness = rounded.isSigned ? "signed" : "unsigned"
            let upper = rounded.activeBytes == 8 ? "zero_high64" : "full128"
            let rounding = rounded.isSigned ? "extended_precision_ties_positive_infinity" : "extended_precision_preserve_carry"
            let source = valueText(for: arguments[0], names: names)
            return "\(valueText(for: destination, names: names)) = __neon_\(rounded.kind.rawValue)_\(signedness)\(rounded.elementBits)_shift\(rounded.shift)_active\(rounded.activeBytes)_\(rounding)_\(upper)(\(source))"
        }
        if let product = instruction.neonSignedLongMultiply,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == 2 {
            let half = product.sourceHighHalf ? "high64" : "low64"
            let kind = product.sourceHighHalf ? "smull2" : "smull"
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_\(kind)_both_sources_signed\(product.narrowBits)_\(half)_sign_extend_to\(product.outputLaneBits)_then_multiply_mod\(product.outputLaneBits)_full128(\(inputs))"
        }
        if let widened = instruction.neonWideningAddSubtract,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == 2 {
            let half = widened.sourceHighHalf ? "high64" : "low64"
            let kind = widened.kind.rawValue + (widened.sourceHighHalf ? "2" : "")
            let roles: String
            if widened.kind == .uaddw {
                // The first argument is already wide; only the second selects
                // a narrow source half and zero-extends before addition.
                roles = "first_unsigned\(widened.outputLaneBits)_full128_second_unsigned\(widened.narrowBits)_\(half)_zero_extend_to\(widened.outputLaneBits)_then_add"
            } else {
                let arithmetic = widened.kind == .ssubl ? "subtract" : "add"
                roles = "both_sources_signed\(widened.narrowBits)_\(half)_sign_extend_to\(widened.outputLaneBits)_then_\(arithmetic)"
            }
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_\(kind)_\(roles)_mod\(widened.outputLaneBits)_full128(\(inputs))"
        }
        if let step = instruction.neonContiguousGroup,
           step.frame.matches(operation, ordinal: step.ordinal) {
            let frame = step.frame
            let base = valueText(for: .unary(op: "(uint64_t)", value: frame.oldBase), names: names)
            if step.ordinal == frame.groupCount, let destination = frame.baseDestination {
                // Captured old base advances once, after every payload commit.
                if let post = frame.registerPost {
                    let increment = valueText(for: .unary(op: "(uint64_t)", value: post.oldIncrement), names: names)
                    // Unsigned addition wraps at 64 bits. This captured value
                    // never changes the payload address or byte footprint.
                    return "\(valueText(for: destination, names: names)) = \(base) + \(increment)"
                }
                return "\(valueText(for: destination, names: names)) = \(base) + 0x\(String(frame.fixedPostDelta, radix: 16))"
            }
            let offset = step.ordinal * frame.activeBytes
            let address = offset == 0 ? base : "(\(base) + 0x\(String(offset, radix: 16)))"
            let vector = valueText(for: frame.vectors[step.ordinal], names: names)
            // Block ordinal selects a contiguous active-byte payload, unlike LD2.
            // SSA vector/base operands retain the frame's pre-commit captures.
            let elementType = frame.activeBytes == 8 ? "uint64_t" : "__uint128_t"
            let memory = "*(\(elementType) *)(\(address))"
            if frame.effect == .load {
                // Widening the unsigned64 payload explicitly clears Q0 high64.
                let payload = frame.activeBytes == 8 ? "(__uint128_t)(\(memory))" : memory
                return "\(vector) = \(payload)"
            }
            return "\(memory) = (\(elementType))\(vector)"
        }
        if let narrow = instruction.neonShiftNarrow,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == narrow.arity {
            let kind = narrow.destinationHighHalf ? "shrn2" : "shrn"
            let mode = narrow.destinationHighHalf ? "destination_high64_preserve_old_low64" : "destination_low64_zero_high64"
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_\(kind)_source128_\(narrow.sourceLaneBits)_to_\(narrow.narrowBits)_logical_shift_right_\(narrow.shift)_then_truncate_\(mode)(\(inputs))"
        }
        if let predicate = instruction.neonPredicate,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == predicate.arity {
            let suffix = [1: "b", 2: "h", 4: "s", 8: "d"][predicate.elementBytes]!
            let mode = predicate.comparesZero
                ? (predicate.kind == .cmeq ? "bits_equal_literal_zero" : "signed_literal_zero")
                : "unsigned_two_sources"
            var inputs = arguments.map { valueText(for: $0, names: names) }
            if predicate.comparesZero { inputs.append("0") }
            let upper = predicate.activeBytes == 8 ? "zero_high64" : "full128"
            return "\(valueText(for: destination, names: names)) = __neon_\(predicate.kind.rawValue)_\(predicate.laneCount)\(suffix)_\(mode)_mask\(predicate.elementBytes * 8)_\(upper)(\(inputs.joined(separator: ", ")))"
        }
        if let widening = instruction.neonWideningPairwise,
           case let .intrinsic(destination?, _, arguments) = operation,
           arguments.count == widening.arity {
            let suffixes = [1: "b", 2: "h", 4: "s", 8: "d"]
            let source = "\(widening.sourceLaneCount)\(suffixes[widening.sourceElementBytes]!)"
            let result = "\(widening.destinationLaneCount)\(suffixes[widening.destinationElementBytes]!)"
            let extensionMode = widening.isSigned ? "sign_extend_each" : "zero_extend_each"
            let accumulation = widening.accumulates ? "_add_old_destination" : ""
            let upper = widening.activeBytes == 8 ? "zero_high64" : "full128"
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_\(widening.kind.rawValue)_\(source)_to_\(result)_\(extensionMode)_then_adjacent_pair_sum\(accumulation)_mod\(widening.destinationElementBytes * 8)_\(upper)(\(inputs))"
        }
        if let magnitude = instruction.neonMagnitudeClamp,
           case let .intrinsic(destination?, name, arguments) = operation,
           name == "integer_magnitude_clamp", arguments.count == magnitude.arity {
            let suffix = [1: "b", 2: "h", 4: "s", 8: "d"][magnitude.elementBytes]!
            let mode = magnitude.arity == 1 ? "wrap_lane_width" : "per_lane"
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_\(magnitude.kind.rawValue)_\(magnitude.laneCount)\(suffix)_\(mode)_zero_upper(\(inputs))"
        }
        if let pairwise = instruction.neonPairwise,
           case let .intrinsic(destination?, name, arguments) = operation,
           name == "integer_pairwise", arguments.count == 2 {
            let suffix = [1: "b", 2: "h", 4: "s", 8: "d"][pairwise.elementBytes]!
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_\(pairwise.kind.rawValue)_\(pairwise.laneCount)\(suffix)_lhs_pairs_then_rhs_pairs_zero_upper(\(inputs))"
        }
        if let step = instruction.neonStructureLaneMemory,
           step.frame.matches(operation, ordinal: step.ordinal) {
            let frame = step.frame
            let base = valueText(for: .unary(op: "(uint64_t)", value: frame.oldBase), names: names)
            if step.ordinal == frame.structureCount, let destination = frame.baseDestination {
                let increment = frame.registerPost.map { valueText(for: $0.oldIncrement, names: names) }
                    ?? "0x\(String(frame.fixedPostDelta, radix: 16))"
                return "\(valueText(for: destination, names: names)) = \(base) + \(increment)"
            }
            let offset = step.ordinal * frame.elementBytes
            let address = offset == 0 ? base : "\(base) + 0x\(String(offset, radix: 16))"
            let scalar = "*(uint\(frame.elementBytes * 8)_t *)(\(address))"
            let oldVector = valueText(for: frame.oldVectors[step.ordinal], names: names)
            if frame.effect == .load {
                let destination = valueText(for: frame.destinations[step.ordinal], names: names)
                return "\(destination) = __neon_insert_lane_\(frame.elementBytes * 8)_at_\(frame.laneIndex)_preserve_other_bytes(\(oldVector), \(scalar))"
            }
            return "\(scalar) = __neon_extract_lane_\(frame.elementBytes * 8)_at_\(frame.laneIndex)(\(oldVector))"
        }
        if let step = instruction.neonLaneMemory,
           step.frame.matches(operation, ordinal: step.ordinal) {
            let frame = step.frame
            let base = valueText(for: .unary(op: "(uint64_t)", value: frame.oldBase), names: names)
            if step.ordinal == 1, let destination = frame.baseDestination {
                return "\(valueText(for: destination, names: names)) = \(base) + 0x\(String(frame.fixedPostDelta, radix: 16))"
            }
            let vector = valueText(for: frame.oldVector, names: names)
            let scalar = "*(uint\(frame.elementBytes * 8)_t *)(\(base))"
            if frame.effect == .load, let destination = frame.destination {
                return "\(valueText(for: destination, names: names)) = __neon_insert_lane_\(frame.elementBytes * 8)_at_\(frame.laneIndex)_preserve_other_bytes(\(vector), \(scalar))"
            }
            return "\(scalar) = __neon_extract_lane_\(frame.elementBytes * 8)_at_\(frame.laneIndex)(\(vector))"
        }
        if let step = instruction.neonBroadcastMemory,
           step.frame.matches(operation, ordinal: step.ordinal) {
            let frame = step.frame
            let base = valueText(for: .unary(op: "(uint64_t)", value: frame.oldBase), names: names)
            if step.ordinal == 1, let destination = frame.baseDestination {
                return "\(valueText(for: destination, names: names)) = \(base) + 0x\(String(frame.fixedPostDelta, radix: 16))"
            }
            let suffix = [1: "b", 2: "h", 4: "s", 8: "d"][frame.elementBytes]!
            let scalar = "*(uint\(frame.elementBytes * 8)_t *)(\(base))"
            return "\(valueText(for: frame.destination, names: names)) = __neon_broadcast_\(frame.laneCount)\(suffix)_zero_upper(\(scalar))"
        }
        if let count = instruction.neonBitCount,
           case let .intrinsic(destination?, name, arguments) = operation,
           name == "integer_bit_count", arguments.count == 1 {
            let suffix = [1: "b", 2: "h", 4: "s"][count.elementBytes]!
            let arrangement = "\(count.activeBytes / count.elementBytes)\(suffix)"
            return "\(valueText(for: destination, names: names)) = __neon_\(count.kind.rawValue)_\(arrangement)_per_lane_zero_upper(\(valueText(for: arguments[0], names: names)))"
        }
        if let conversion = instruction.neonOrderConversion,
           case let .intrinsic(destination?, name, arguments) = operation,
           name == "integer_order_conversion", arguments.count == 1 {
            let suffix = [1: "b", 2: "h", 4: "s"][conversion.elementBytes]!
            let arrangement = "\(conversion.activeBytes / conversion.elementBytes)\(suffix)"
            let mode = conversion.kind == .rbit ? "bits_within_each_byte" : "elements_within_\(conversion.groupBytes)byte_groups"
            return "\(valueText(for: destination, names: names)) = __neon_\(conversion.kind.rawValue)_\(arrangement)_\(mode)_zero_upper(\(valueText(for: arguments[0], names: names)))"
        }
        if let step = instruction.neonInterleavedMemory,
           step.frame.matches(operation, ordinal: step.ordinal) {
            let frame = step.frame
            let base = valueText(for: .unary(op: "(uint64_t)", value: frame.oldBase), names: names)
            if step.ordinal == frame.groupCount, let destination = frame.baseDestination {
                let increment = frame.registerPost.map { valueText(for: $0.oldIncrement, names: names) }
                    ?? "0x\(String(frame.fixedPostDelta, radix: 16))"
                return "\(valueText(for: destination, names: names)) = \(base) + \(increment)"
            }
            let vector = valueText(for: frame.vectors[step.ordinal], names: names)
            if frame.structureCount == 2 && frame.elementBytes == 1 {
                // Keep the established byte LD2/ST2 spelling and golden output.
                let parity = step.ordinal == 0 ? "even" : "odd"
                if frame.effect == .load {
                    let upper = frame.activeBytes == 8 ? "_zero_high64" : ""
                    return "\(vector) = __neon_ld2_\(frame.activeBytes)b_gather_\(parity)_bytes_stride2\(upper)(\(base))"
                }
                return "__neon_st2_\(frame.activeBytes)b_scatter_\(parity)_bytes_stride2(\(base), \(vector))"
            }
            let suffix = [1: "b", 2: "h", 4: "s", 8: "d"][frame.elementBytes]!
            let arrangement = "\(frame.activeBytes / frame.elementBytes)\(suffix)"
            let layout = frame.structureCount == 1 ? "contiguous_list" : "interleaved_elements"
            let shape = "\(arrangement)_\(layout)_channel\(step.ordinal)_span\(frame.byteCount)"
            if frame.effect == .load {
                let upper = frame.activeBytes == 8 ? "_zero_high64" : ""
                return "\(vector) = __neon_ld\(frame.structureCount)_\(shape)\(upper)(\(base))"
            }
            return "__neon_st\(frame.structureCount)_\(shape)(\(base), \(vector))"
        }
        if let indexed = instruction.neonIndexedMemory,
           instruction.memoryAccess?.byteWidth == indexed.byteWidth {
            // Zero-register indexes are architectural zero, never an SSA input.
            let address = indexed.indexRegister.hasSuffix("zr")
                ? MacIRValue.unary(op: "(uint64_t)", value: indexed.base) : indexed.address
            let memory = "*(__uint128_t *)(\(valueText(for: address, names: names)))"
            switch operation {
            case let .load(destination, actual) where indexed.effect == .load && actual == indexed.address:
                return "\(valueText(for: destination, names: names)) = \(memory)"
            case let .store(source, actual) where indexed.effect == .store && actual == indexed.address:
                return "\(memory) = \(valueText(for: source, names: names))"
            default: break
            }
        }
        if let packing = instruction.neonPacking,
           case let .intrinsic(destination?, name, arguments) = operation,
           name == "integer_unpack_pack", arguments.count == (packing.readsDestination ? 2 : 1) {
            let mode: String
            if packing.kind == .narrow {
                mode = packing.destinationHighHalf ? "destination_high_preserve_low64" : "destination_low_zero_high64"
            } else {
                mode = "source_\(packing.sourceHighHalf ? "high" : "low")_shift_\(packing.shift)"
            }
            let inputs = arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")
            return "\(valueText(for: destination, names: names)) = __neon_\(packing.kind.rawValue)_\(packing.sourceLaneBits)_to_\(packing.destinationLaneBits)_\(mode)(\(inputs))"
        }
        if let reduction = instruction.neonReduction,
           case let .intrinsic(destination?, name, arguments) = operation,
           name == "integer_horizontal_output", arguments.count == 1 {
            let laneSuffix = [8: "b", 16: "h", 32: "s", 64: "d"][reduction.elementBits]!
            let input = "\(reduction.inputLanes)\(laneSuffix)"
            let output: String
            if reduction.isExtraction {
                output = "\(input)_lane_\(reduction.lane)_to_\(reduction.gprBits == 32 ? "w" : "x")_zero_upper"
            } else {
                let resultSuffix = [8: "b", 16: "h", 32: "s", 64: "d"][reduction.outputBits]!
                output = "\(input)_to_\(resultSuffix)_zero_upper"
            }
            let invocation = "__neon_\(reduction.kind.rawValue)_\(output)(\(valueText(for: arguments[0], names: names)))"
            if reduction.isExtraction, case let .register(register, _) = destination,
               register == "wzr" || register == "xzr" { return invocation }
            return "\(valueText(for: destination, names: names)) = \(invocation)"
        }
        if let immediate = instruction.neonImmediate,
           case let .intrinsic(destination?, name, arguments) = operation,
           name == "neon_integer_constant", arguments.isEmpty {
            let low = "0x" + String(immediate.low, radix: 16) + "ULL"
            let high = "0x" + String(immediate.high, radix: 16) + "ULL"
            let value = immediate.high == 0 ? "(__uint128_t)\(low)"
                : "(((__uint128_t)\(high) << 64) | \(low))"
            return "\(valueText(for: destination, names: names)) = \(value)"
        }
        if let bitView = instruction.neonBitView,
           case let .intrinsic(destination, name, arguments) = operation,
           name == bitView.intrinsicName {
            let inputs = arguments.enumerated().map { index, value in
                if index == 0, bitView.sourceIsGPR,
                   case let .register(register, _) = value,
                   register == "wzr" || register == "xzr" { return "0" }
                return valueText(for: value, names: names)
            }
            let invocation = "__\(name)(\(inputs.joined(separator: ", ")))"
            if bitView.resultIsGPR, let destination, case let .register(register, _) = destination,
               register == "wzr" || register == "xzr" { return invocation }
            return destination.map { "\(valueText(for: $0, names: names)) = \(invocation)" } ?? invocation
        }
        if let target = instruction.returnTarget, case let .returnValue(value) = operation {
            let arguments = [target] + (value.map { [$0] } ?? [])
            return "__a64_ret_to(\(arguments.map { valueText(for: $0, names: names) }.joined(separator: ", ")))"
        }
        if let fp = instruction.scalarFP, fp.operation == .convert,
           fp.inputType == .binary32, fp.resultType == .binary64,
           case let .intrinsic(destination?, name, arguments) = operation, name == fp.intrinsicName,
           arguments.count == 1 {
            // float -> double is exact; on A64 the C cast lowers to this same FCVT
            // (NaNs are quieted with their payload either way), so it reads as a cast.
            // Narrowing keeps the helper: it depends on the FPCR rounding mode.
            return "\(valueText(for: destination, names: names)) = (double)\(valueText(for: arguments[0], names: names))"
        }
        if let fp = instruction.scalarFP,
           case let .intrinsic(destination?, name, arguments) = operation, name == fp.intrinsicName {
            // Helpers retain A64 NaN propagation and saturation, which ordinary C
            // arithmetic/casts and fmin/fmax are not required to reproduce.
            let suffix: String
            switch fp.operation {
            case .toInteger, .fromInteger:
                suffix = "\(fp.inputType.rawValue)_\(fp.resultType.rawValue)_\(fp.rounding.rawValue)_\(fp.fractionalBits)"
            case .convert:
                suffix = "\(fp.inputType.rawValue)_\(fp.resultType.rawValue)"
            case .round:
                suffix = "\(fp.inputType.rawValue)_\(fp.rounding.rawValue)" + (fp.raisesInexact ? "_exact" : "")
            default:
                suffix = fp.resultType.rawValue
            }
            var inputs = arguments.map { valueText(for: $0, names: names) }
            if fp.integerCarrier == .scalarSIMDBits, fp.operation == .fromInteger, !inputs.isEmpty {
                inputs[0] = "__bitcast_\(fp.inputType.rawValue)(\(inputs[0]))"
            }
            var result = "__a64_\(fp.operation.rawValue)_\(suffix)(\(inputs.joined(separator: ", ")))"
            if fp.integerCarrier == .scalarSIMDBits, fp.operation == .toInteger {
                result = "__bitcast_\(fp.storageResultType.rawValue)(\(result))"
            }
            return "\(valueText(for: destination, names: names)) = \(result)"
        }
        guard let access = instruction.memoryAccess else { return render(operation: operation, names: names) }
        func type(_ carrier: MacIRValue) -> String {
            let floating: Bool
            switch carrier {
            case let .register(name, _): floating = name.hasPrefix("s") || name.hasPrefix("d")
            case let .argument(binding): floating = binding.kind == .simd
            default: floating = false
            }
            if floating, access.byteWidth == 4 { return "float" }
            if floating, access.byteWidth == 8 { return "double" }
            if access.byteWidth == 16 { return "__uint128_t" }
            let signed = access.extensionKind == .sign
                || (names.ordinarySSAMemoryEffects && access.extensionKind == .none
                    && [4, 8].contains(access.byteWidth) && names.signedCompareLoadDestinations.contains(carrier))
            return "\(signed ? "int" : "uint")\(access.byteWidth * 8)_t"
        }
        func memberTarget(_ address: MacIRValue) -> (base: MacIRValue, offset: Int)? {
            if case let .binaryExpression(op, base, .immediate(offset)) = address,
               op == "+", offset == 0 { return (base, 0) }
            return PseudocodeNameContext.dereferenceTarget(address)
        }
        func memberCarrierMatches(_ carrier: MacIRValue, isStore: Bool) -> Bool {
            switch carrier {
            case let .register(name, _):
                if let integer = MacIRBuilder.integerRegisterView(name) {
                    if isStore { return access.byteWidth <= integer.width / 8 }
                    return access.extensionKind == .none
                        ? access.byteWidth == integer.width / 8
                        : access.byteWidth < integer.width / 8
                }
                return access.extensionKind == .none &&
                    ((name.hasPrefix("s") && access.byteWidth == 4) ||
                     (name.hasPrefix("d") && access.byteWidth == 8))
            case let .argument(binding):
                return isStore && (binding.kind == .gpr ||
                    (binding.kind == .simd && [4, 8].contains(access.byteWidth)))
            case .immediate:
                return isStore
            default:
                return false
            }
        }
        func memory(_ address: MacIRValue, _ carrier: MacIRValue, memberStore: Bool? = nil, isStore: Bool = false) -> String {
            let elementType = type(carrier)
            if let record = recordMemoryText(address: address, carrier: carrier, access: access,
                isStore: memberStore ?? isStore, names: names, allowField: memberStore != nil) { return record }
            // Only ordinary load/store arms opt in. Pair and writeback forms
            // continue through the exact existing typed-dereference renderer.
            if let isStore = memberStore, memberCarrierMatches(carrier, isStore: isStore),
               let (base, offset) = memberTarget(address),
               let field = names.structFieldName(forBase: base, offset: offset, access: access,
                   floating: elementType == "float" || elementType == "double", isStore: isStore) {
                return "\(valueText(for: base, names: names))->\(field)"
            }
            if case let .stackSlot(offset) = address {
                if let local = names.localsByOffset[offset], local.byteWidth == access.byteWidth,
                   local.type == elementType || (access.extensionKind == .none && access.byteWidth == 8) {
                    return local.name
                }
                return "*(\(elementType) *)&(\(valueText(for: address, names: names)))"
            }
            return "*(\(elementType) *)(\(valueText(for: address, names: names)))"
        }
        func storeValue(_ source: MacIRValue, at address: MacIRValue) -> String {
            if case .stackSlot = address { return valueText(for: source, names: names) }
            return emittedRecordPointer(address, names: names) == nil ? valueText(for: source, names: names)
                : recordStoreValueText(source, names: names, access: access)
        }
        func secondAddress(_ address: MacIRValue) -> MacIRValue {
            if case let .stackSlot(offset) = address {
                let (next, overflow) = offset.addingReportingOverflow(Int64(access.byteWidth))
                if !overflow { return .stackSlot(offset: next) }
            }
            return .binaryExpression(op: "+", left: address, right: .immediate(Int64(access.byteWidth)))
        }
        func sequential(_ destinations: [MacIRValue], reading values: [MacIRValue], address: MacIRValue) -> Bool {
            guard names.ordinarySSAMemoryEffects, [1, 2, 4, 8].contains(access.byteWidth),
                  !ssaRecoveryFrameAddress(address) else { return false }
            return ssaRecoveryIndependentDestinations(destinations, reading: values, names: names)
        }
        switch operation {
        case let .load(destination, address):
            // An SSA LDRSW carries a signed word into X, not a narrow C call argument.
            // Keep the four-byte memory read, but make its signed64 transport explicit.
            if names.ordinarySSAMemoryEffects, access.extensionKind == .sign, access.byteWidth == 4,
               case let .register(register, _) = destination,
               MacIRBuilder.integerRegisterView(register)?.width == 64 {
                return "\(valueText(for: destination, names: names)) = (int64_t)(\(memory(address, destination, memberStore: false)))"
            }
            if let record = recordMemoryText(address: address, carrier: destination, access: access,
                                             isStore: false, names: names) {
                return "\(valueText(for: destination, names: names)) = \(record)"
            }
            if access.byteWidth == 8, access.extensionKind == .none, type(destination) == "uint64_t" {
                return render(operation: operation, names: names)
            }
            return "\(valueText(for: destination, names: names)) = \(memory(address, destination, memberStore: false))"
        case let .store(source, address):
            if let record = recordMemoryText(address: address, carrier: source, access: access,
                                             isStore: true, names: names) {
                return "\(record) = \(recordStoreValueText(source, names: names, access: access))"
            }
            if access.byteWidth == 8, access.extensionKind == .none, type(source) == "uint64_t" {
                return render(operation: operation, names: names)
            }
            return "\(memory(address, source, memberStore: true)) = \(valueText(for: source, names: names))"
        case let .loadWriteback(destination, baseDestination, baseSource, delta, preIndex):
            let updated = MacIRValue.binaryExpression(op: "+", left: baseSource, right: .immediate(delta))
            let address = preIndex ? updated : baseSource
            if sequential([destination, baseDestination], reading: [baseSource], address: address) {
                return "\(valueText(for: destination, names: names)) = \(memory(address, destination)); \(valueText(for: baseDestination, names: names)) = \(writebackUpdateText(baseSource: baseSource, delta: delta, names: names))"
            }
            return "\(valueText(for: destination, names: names)), \(valueText(for: baseDestination, names: names)) = \(memory(address, destination)), \(writebackUpdateText(baseSource: baseSource, delta: delta, names: names))"
        case let .storeWriteback(source, baseDestination, baseSource, delta, preIndex):
            let updated = MacIRValue.binaryExpression(op: "+", left: baseSource, right: .immediate(delta))
            let address = preIndex ? updated : baseSource
            if sequential([baseDestination], reading: [source, baseSource], address: address) {
                return "\(memory(address, source, isStore: true)) = \(storeValue(source, at: address)); \(valueText(for: baseDestination, names: names)) = \(writebackUpdateText(baseSource: baseSource, delta: delta, names: names))"
            }
            return "\(memory(address, source, isStore: true)), \(valueText(for: baseDestination, names: names)) = \(storeValue(source, at: address)), \(writebackUpdateText(baseSource: baseSource, delta: delta, names: names))"
        case let .intrinsic(_, name, arguments) where (name == "restore_pair" || name == "save_pair") && arguments.count >= 3:
            // The untyped form exists for stack-local pair names; a pair at
            // an ordinary address keeps its typed two-element memory text.
            if access.byteWidth == 8, access.extensionKind == .none, type(arguments[0]) == "uint64_t",
               case .stackSlot = arguments[2] {
                return render(operation: operation, names: names)
            }
            let first = name == "save_pair" ? storeValue(arguments[0], at: arguments[2]) : valueText(for: arguments[0], names: names)
            let second = name == "save_pair" ? storeValue(arguments[1], at: secondAddress(arguments[2])) : valueText(for: arguments[1], names: names)
            let firstMemory = memory(arguments[2], arguments[0], isStore: name == "save_pair")
            let secondMemory = memory(secondAddress(arguments[2]), arguments[1], isStore: name == "save_pair")
            let loading = name == "restore_pair"
            if sequential(loading ? Array(arguments.prefix(2)) : [],
                          reading: loading ? [arguments[2]] : Array(arguments.prefix(3)), address: arguments[2]) {
                return loading ? "\(first) = \(firstMemory); \(second) = \(secondMemory)"
                    : "\(firstMemory) = \(first); \(secondMemory) = \(second)"
            }
            return name == "restore_pair" ? "\(first), \(second) = \(firstMemory), \(secondMemory)" : "\(firstMemory), \(secondMemory) = \(first), \(second)"
        case let .intrinsic(_, name, arguments) where (name == "restore_pair_writeback" || name == "save_pair_writeback") && arguments.count == 6:
            guard case let .immediate(delta) = arguments[4], case let .immediate(preIndex) = arguments[5] else { break }
            let updated = MacIRValue.binaryExpression(op: "+", left: arguments[2], right: .immediate(delta))
            let address = preIndex == 0 ? arguments[2] : updated
            let first = name == "save_pair_writeback" ? storeValue(arguments[0], at: address) : valueText(for: arguments[0], names: names)
            let second = name == "save_pair_writeback" ? storeValue(arguments[1], at: secondAddress(address)) : valueText(for: arguments[1], names: names)
            let firstMemory = memory(address, arguments[0], isStore: name == "save_pair_writeback")
            let secondMemory = memory(secondAddress(address), arguments[1], isStore: name == "save_pair_writeback")
            let base = valueText(for: arguments[3], names: names)
            let update = writebackUpdateText(baseSource: arguments[2], delta: delta, names: names)
            let loading = name == "restore_pair_writeback"
            if sequential(loading ? [arguments[0], arguments[1], arguments[3]] : [arguments[3]],
                          reading: loading ? [arguments[2]] : Array(arguments.prefix(3)), address: address) {
                return loading ? "\(first) = \(firstMemory); \(second) = \(secondMemory); \(base) = \(update)"
                    : "\(firstMemory) = \(first); \(secondMemory) = \(second); \(base) = \(update)"
            }
            return name == "restore_pair_writeback" ? "\(first), \(second), \(base) = \(firstMemory), \(secondMemory), \(update)" : "\(firstMemory), \(secondMemory), \(base) = \(first), \(second), \(update)"
        default: break
        }
        return render(operation: operation, names: names)
    }

    /// Frame/exterior text has its own frozen observation contract. No source
    /// mnemonic or rendered text is used to identify these address values.
    private func ssaRecoveryFrameAddress(_ value: MacIRValue) -> Bool {
        switch value {
        case .stackSlot: return true
        case let .register(name, _): return ["sp", "wsp", "fp", "x29", "w29"].contains(name.lowercased())
        case let .unary(_, inner), let .bitTest(inner, _): return ssaRecoveryFrameAddress(inner)
        case let .binaryExpression(_, left, right): return ssaRecoveryFrameAddress(left) || ssaRecoveryFrameAddress(right)
        default: return false
        }
    }

    /// Sequential statements are equivalent only when every RHS is pure and
    /// no earlier scalar write can change a later RHS or address. Compare the
    /// emitted scalar identities as well as IR identities, since user names can alias.
    private func ssaRecoveryIndependentDestinations(_ destinations: [MacIRValue], reading values: [MacIRValue],
                                                   names: PseudocodeNameContext) -> Bool {
        func leaves(_ value: MacIRValue) -> Set<String>? {
            switch value {
            case .register, .temporary, .argument:
                return [valueText(for: value, names: names)]
            case .immediate: return []
            case let .binaryExpression(op, left, right) where ["+", "-", "*", "&", "|", "^", "<<", ">>"].contains(op):
                guard let a = leaves(left), let b = leaves(right) else { return nil }
                return a.union(b)
            case let .unary(op, inner) where ["(uint8_t)", "(uint16_t)", "(uint32_t)", "(uint64_t)", "(int8_t)", "(int16_t)", "(int32_t)", "(int64_t)", "+", "-", "~"].contains(op):
                return leaves(inner)
            default: return nil
            }
        }
        var outputs: Set<String> = []
        for destination in destinations {
            switch destination { case .register, .temporary: break; default: return false }
            guard outputs.insert(valueText(for: destination, names: names)).inserted else { return false }
        }
        for value in values {
            guard let inputs = leaves(value), outputs.isDisjoint(with: inputs) else { return false }
        }
        return true
    }

}
