#pragma once

#include "MacScopeNativeDecompiler/InputModel.hpp"

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace macscope::native_decompiler {

/// Borrowed semantic inputs for canonical request stream v2. Correlation and
/// self-digest envelope fields are deliberately absent from this view.
struct CanonicalRequestV2View final {
    std::reference_wrapper<const TargetProfile> target;
    std::reference_wrapper<const ImageIdentity> image;
    std::reference_wrapper<const FunctionIdentity> function;
    std::reference_wrapper<const ByteProvider> bytes;
    std::reference_wrapper<const SymbolProvider> symbols;
    std::reference_wrapper<const AuthoredInputs> authoredInputs;
    std::reference_wrapper<const ProfiledAnalysisBudgets> budgets;
    std::uint32_t schemaVersion = 3;
    /// `decompile` or `decompile-document`; bound into the digest.
    std::string_view operation = "decompile";
};

[[nodiscard]] std::vector<std::uint8_t>
canonicalRequestV2(const CanonicalRequestV2View& request);

[[nodiscard]] std::string
canonicalRequestSha256V2(const CanonicalRequestV2View& request);

[[nodiscard]] std::vector<std::uint8_t> canonicalContextProfileV1(
    ArchitectureVariant variant = ArchitectureVariant::arm64
);

} // namespace macscope::native_decompiler
