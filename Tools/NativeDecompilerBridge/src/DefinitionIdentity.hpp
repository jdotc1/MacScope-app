#pragma once

#include <string>
#include <string_view>

namespace macscope::native_decompiler::detail {

// The provider verifies that each native definition owns exactly one output.
// Its already-unique operation identity therefore identifies that output and
// its SSA value without nesting storage/definition descriptions. Distinct
// domain prefixes prevent aliases with each other and with unchanged entry,
// constant, address, join and internal-special identities. Full operation IDs
// are retained (no hashes or truncation); explicit record fields retain truth.
inline std::string definedVarnodeIdentity(std::string_view operationId) {
    return "varnode:def:" + std::string(operationId);
}
inline std::string definedSsaIdentity(std::string_view operationId) {
    return "ssa:def:" + std::string(operationId);
}
inline std::string definedPhiIdentity(std::string_view operationId) {
    return "phi:def:" + std::string(operationId);
}

} // namespace macscope::native_decompiler::detail
