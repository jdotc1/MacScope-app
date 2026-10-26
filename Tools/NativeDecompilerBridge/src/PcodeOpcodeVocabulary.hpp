#pragma once

#include <ghidra/opcodes.hh>

namespace macscope::native_decompiler::detail {

// Private, header-only seam shared only by the provider and its linked binding test.
// It is not installed and does not widen the public native contract.
[[nodiscard]] inline constexpr const char* canonicalOpcodeName(
    ghidra::OpCode opcode
) noexcept {
    switch (opcode) {
#define MACSCOPE_PCODE_OPCODE(enumerator, canonical, wire) \
    case ghidra::enumerator: return canonical;
#include "MacScopeNativeDecompiler/PcodeOpcodeVocabulary.def"
#undef MACSCOPE_PCODE_OPCODE
    default: return nullptr;
    }
}

enum class PcodeOpcodeAdjudication {
    representable,
    invalid,
    unavailable,
};

[[nodiscard]] inline constexpr PcodeOpcodeAdjudication adjudicatePcodeOpcode(
    int rawOpcode,
    const char* canonicalName
) noexcept {
    if (rawOpcode < static_cast<int>(ghidra::CPUI_COPY) ||
        rawOpcode >= static_cast<int>(ghidra::CPUI_MAX) || rawOpcode == 45) {
        return PcodeOpcodeAdjudication::invalid;
    }
    return canonicalName == nullptr
        ? PcodeOpcodeAdjudication::unavailable
        : PcodeOpcodeAdjudication::representable;
}

} // namespace macscope::native_decompiler::detail
