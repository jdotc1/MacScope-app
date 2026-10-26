#include "PcodeOpcodeVocabulary.hpp"

#include <ghidra/opcodes.hh>

#include <cstddef>
#include <iostream>

using namespace macscope::native_decompiler::detail;

namespace {

constexpr std::size_t manifestRowCount = 0
#define MACSCOPE_PCODE_OPCODE(enumerator, canonical, wire) + 1
#include "MacScopeNativeDecompiler/PcodeOpcodeVocabulary.def"
#undef MACSCOPE_PCODE_OPCODE
;

static_assert(static_cast<int>(ghidra::CPUI_COPY) == 1);
static_assert(static_cast<int>(ghidra::CPUI_FLOAT_LESSEQUAL) == 44);
static_assert(static_cast<int>(ghidra::CPUI_FLOAT_NAN) == 46);
static_assert(static_cast<int>(ghidra::CPUI_LZCOUNT) == 73);
static_assert(static_cast<int>(ghidra::CPUI_SPULL) == 74);
// Bound to SLEIGH_GIT_REVISION bfd38a983b4aa53dd386365e1df5ed5499b7e2fb.
static_assert(static_cast<int>(ghidra::CPUI_MAX) == 75);
static_assert(manifestRowCount ==
    static_cast<std::size_t>(ghidra::CPUI_MAX - ghidra::CPUI_COPY - 1));

} // namespace

int main() {
    int failures = 0;
    for (int raw = static_cast<int>(ghidra::CPUI_COPY);
         raw < static_cast<int>(ghidra::CPUI_MAX);
         ++raw) {
        if (raw == 45) continue;
        const auto opcode = static_cast<ghidra::OpCode>(raw);
        if (canonicalOpcodeName(opcode) == nullptr) {
            ++failures;
            std::cerr << "opcode " << raw << " is not bound to the manifest\n";
        }
    }
    if (adjudicatePcodeOpcode(45, "forged") != PcodeOpcodeAdjudication::invalid) {
        ++failures;
        std::cerr << "the raw opcode hole at 45 was admitted\n";
    }
    if (adjudicatePcodeOpcode(
            static_cast<int>(ghidra::CPUI_SPULL),
            canonicalOpcodeName(ghidra::CPUI_SPULL)
        ) != PcodeOpcodeAdjudication::representable) {
        ++failures;
        std::cerr << "CPUI_SPULL was not admitted as representable\n";
    }
    if (adjudicatePcodeOpcode(
            static_cast<int>(ghidra::CPUI_COPY), nullptr
        ) != PcodeOpcodeAdjudication::unavailable) {
        ++failures;
        std::cerr << "a valid but unrepresentable opcode was not typed unavailable\n";
    }
    return failures == 0 ? 0 : 1;
}
