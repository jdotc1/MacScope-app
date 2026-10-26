#pragma once

#include "MacScopeNativeDecompiler/InputModel.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace macscope::native_decompiler::detail {

struct PacQualificationObservation final {
    TargetProfile target;
    std::vector<std::string> visibleOperations;
    std::vector<std::string> visibleDataflow;
    std::vector<std::string> hiddenOperations;
    std::vector<std::string> hiddenDataflow;
};

[[nodiscard]] PacQualificationObservation observeHiddenPacProfileForTesting(
    const AnalysisRequestView& request,
    std::uint32_t rawCpuSubtype
);

} // namespace macscope::native_decompiler::detail
