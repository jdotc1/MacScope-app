#pragma once

#include "MacScopeNativeDecompiler/Backend.hpp"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace macscope::native_decompiler::detail {

enum class GhidraReadinessFault : std::uint8_t {
    none = 0,
    missingShowPac,
    mismatchedPacClobber,
    nullContext,
    nullTranslator,
    missingRequiredUserOp,
    duplicateRequiredUserOp,
    unexpectedSelectedProfile,
    decodeBeforeHook,
};

/// Exact package and native-language identity frozen by package attestation.
/// All path values are canonical, absolute paths produced by the attestation
/// layer before a lease is requested.
struct GhidraRuntimeIdentity final {
    std::string materializationRoot;
    std::string manifestSha256;
    std::string closedTreeSha256;
    std::string packageRoot;
    std::string globalSpecRoot;
    std::string processorSpecRoot;
    std::string languageId;
    std::string compilerSpecId;

    [[nodiscard]] std::string targetId() const;

    bool operator==(const GhidraRuntimeIdentity&) const = default;
};

/// Process-global lease for the native decompiler runtime. The first
/// successful identity is immutable for the life of the process. Releasing
/// the last live lease does not reset native global state.
class GhidraRuntimeLease final {
public:
    explicit GhidraRuntimeLease(GhidraRuntimeIdentity identity);
    ~GhidraRuntimeLease();

    GhidraRuntimeLease(const GhidraRuntimeLease&) = delete;
    GhidraRuntimeLease& operator=(const GhidraRuntimeLease&) = delete;
    GhidraRuntimeLease(GhidraRuntimeLease&&) = delete;
    GhidraRuntimeLease& operator=(GhidraRuntimeLease&&) = delete;

    [[nodiscard]] const GhidraRuntimeIdentity& identity() const noexcept;

private:
    GhidraRuntimeIdentity identity_;
};

/// Exclusive access to native architecture construction, action execution,
/// traversal, printing, and teardown. The upstream implementation shares
/// process-static translators, so provider-instance serialization is not
/// sufficient.
class GhidraExecutionLock final {
public:
    GhidraExecutionLock();
    ~GhidraExecutionLock();

    GhidraExecutionLock(const GhidraExecutionLock&) = delete;
    GhidraExecutionLock& operator=(const GhidraExecutionLock&) = delete;
    GhidraExecutionLock(GhidraExecutionLock&&) noexcept;
    GhidraExecutionLock& operator=(GhidraExecutionLock&&) noexcept;

private:
    struct State;
    std::unique_ptr<State> state_;
};

struct GhidraRuntimeSnapshot final {
    bool started = false;
    bool initializationFailed = false;
    std::size_t liveLeaseCount = 0;
    std::size_t startupCallCount = 0;
    bool identityFrozen = false;
};

/// Test/reporting observation only. There is deliberately no reset API.
[[nodiscard]] GhidraRuntimeSnapshot ghidraRuntimeSnapshot();

/// Reject unsupported values before any native global state is touched.
void validateGhidraLanguageAndCompiler(
    const std::string& languageId,
    const std::string& compilerSpecId
);

/// Package-backed test seam for the same bounded listener-readiness path used
/// by provider construction. Faults are injected before readiness can publish
/// a prepared identity and never alter request-owned assertions.
[[nodiscard]] PreparedGhidraRuntimeIdentity prepareGhidraRuntimeIdentityForTesting(
    const GhidraBackendConfiguration& configuration,
    const TargetProfile& selectedProfile,
    GhidraReadinessFault fault
);

} // namespace macscope::native_decompiler::detail
