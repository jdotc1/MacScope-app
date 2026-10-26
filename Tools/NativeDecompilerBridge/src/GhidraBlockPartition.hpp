#pragma once

#include "MacScopeNativeDecompiler/OutputModel.hpp"

#include <span>

namespace ghidra { class AddrSpace; class Funcdata; }

namespace macscope::native_decompiler::detail {

class GhidraRequestCheckpoint;

struct DecodedInstruction final {
    InstructionRecord record;
    Address endAddressExclusive = 0;
};

// Decide which wire representation can describe the finalized graph. This
// read-only query never reruns analysis or removes optimization groups.
[[nodiscard]] bool legacyPartitionRepresentable(
    const AnalysisRequestView& request,
    ghidra::Funcdata& function,
    ghidra::AddrSpace* codeSpace,
    std::span<const DecodedInstruction> decoded,
    const GhidraRequestCheckpoint& budget
);

} // namespace macscope::native_decompiler::detail
