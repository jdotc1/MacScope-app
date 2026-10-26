#include "GhidraRuntimeInternal.hpp"

#include "MacScopeNativeDecompiler/InputModel.hpp"

#include <ghidra/libdecomp.hh>
#include <ghidra/sleigh_arch.hh>

#include <algorithm>
#include <mutex>
#include <optional>
#include <utility>

namespace macscope::native_decompiler::detail {
namespace {

constexpr auto kAppleSiliconLanguageId = "AARCH64:LE:64:AppleSilicon";

struct RuntimeState final {
    std::mutex identityMutex;
    std::mutex executionMutex;
    std::optional<GhidraRuntimeIdentity> frozenIdentity;
    bool startupAttempted = false;
    bool started = false;
    bool initializationFailed = false;
    bool shutdownCalled = false;
    std::size_t liveLeaseCount = 0;
    std::size_t startupCallCount = 0;
};

// The state intentionally outlives ordinary C++ static destruction. The
// explicit process guard below remains the sole owner of native shutdown.
[[nodiscard]] RuntimeState& runtimeState() {
    static auto* state = new RuntimeState();
    return *state;
}

[[nodiscard]] bool isLowerHexDigest(const std::string& value) {
    return value.size() == 64 &&
           std::all_of(value.begin(), value.end(), [](unsigned char character) {
               return (character >= static_cast<unsigned char>('0') &&
                       character <= static_cast<unsigned char>('9')) ||
                      (character >= static_cast<unsigned char>('a') &&
                       character <= static_cast<unsigned char>('f'));
           });
}

void validateRuntimeIdentity(const GhidraRuntimeIdentity& identity) {
    validateGhidraLanguageAndCompiler(identity.languageId, identity.compilerSpecId);
    if (identity.materializationRoot.empty() || identity.packageRoot.empty() ||
        identity.globalSpecRoot.empty() || identity.processorSpecRoot.empty()) {
        throw ContractError("native-runtime-attested-path-missing");
    }
    if (!isLowerHexDigest(identity.manifestSha256) ||
        !isLowerHexDigest(identity.closedTreeSha256)) {
        throw ContractError("native-runtime-attested-digest-invalid");
    }
}

void requireExactNativeLanguage(const GhidraRuntimeIdentity& identity) {
    const auto& descriptions = ghidra::SleighArchitecture::getDescriptions();
    const ghidra::LanguageDescription* selectedLanguage = nullptr;
    for (const auto& description : descriptions) {
        if (description.getId() != identity.languageId) {
            continue;
        }
        if (selectedLanguage != nullptr) {
            throw ContractError("native-runtime-language-ambiguous");
        }
        selectedLanguage = &description;
    }
    if (selectedLanguage == nullptr) {
        throw ContractError("native-runtime-language-unavailable");
    }

    const ghidra::CompilerTag* selectedCompiler = nullptr;
    for (ghidra::int4 index = 0; index < selectedLanguage->numCompilers(); ++index) {
        const auto& compiler = selectedLanguage->getCompiler(index);
        if (compiler.getId() != identity.compilerSpecId) {
            continue;
        }
        if (selectedCompiler != nullptr) {
            throw ContractError("native-runtime-compiler-ambiguous");
        }
        selectedCompiler = &compiler;
    }
    if (selectedCompiler == nullptr) {
        throw ContractError("native-runtime-compiler-unavailable");
    }
}

class ProcessShutdownGuard final {
public:
    ~ProcessShutdownGuard() {
        auto& state = runtimeState();
        std::lock_guard identityGuard(state.identityMutex);
        if (!state.started || state.shutdownCalled) {
            return;
        }
        std::lock_guard executionGuard(state.executionMutex);
        try {
            ghidra::shutdownDecompilerLibrary();
        } catch (...) {
            // Process teardown cannot safely publish or recover an upstream
            // failure. The one-shot bookkeeping boundary still remains shut.
        }
        state.shutdownCalled = true;
    }
};

void ensureProcessShutdownGuard() {
    static ProcessShutdownGuard guard;
    static_cast<void>(guard);
}

} // namespace

std::string GhidraRuntimeIdentity::targetId() const {
    return languageId + ":" + compilerSpecId;
}

void validateGhidraLanguageAndCompiler(
    const std::string& languageId,
    const std::string& compilerSpecId
) {
    if (languageId != kAppleSiliconLanguageId) {
        throw ContractError("native-apple-profile-language-mismatch");
    }
    if (compilerSpecId != "default") {
        throw ContractError("native-apple-profile-compiler-mismatch");
    }
}

GhidraRuntimeLease::GhidraRuntimeLease(GhidraRuntimeIdentity identity)
    : identity_(std::move(identity)) {
    validateRuntimeIdentity(identity_);

    auto& state = runtimeState();
    std::lock_guard identityGuard(state.identityMutex);
    if (state.initializationFailed) {
        throw ContractError("native-runtime-initialization-latched");
    }
    if (state.frozenIdentity.has_value()) {
        if (*state.frozenIdentity != identity_) {
            throw ContractError("native-runtime-configuration-conflict");
        }
        ++state.liveLeaseCount;
        return;
    }
    if (state.startupAttempted) {
        // This is unreachable under the identity mutex unless native startup
        // failed. Keep the failure mode closed if state is ever extended.
        state.initializationFailed = true;
        throw ContractError("native-runtime-initialization-latched");
    }

    state.startupAttempted = true;
    try {
        std::lock_guard executionGuard(state.executionMutex);
        ++state.startupCallCount;
        ghidra::startDecompilerLibrary(identity_.globalSpecRoot.c_str());
        state.started = true;
        ensureProcessShutdownGuard();
        requireExactNativeLanguage(identity_);
    } catch (...) {
        state.initializationFailed = true;
        throw ContractError("native-runtime-initialization-failed");
    }

    state.frozenIdentity = identity_;
    state.liveLeaseCount = 1;
}

GhidraRuntimeLease::~GhidraRuntimeLease() {
    auto& state = runtimeState();
    std::lock_guard identityGuard(state.identityMutex);
    if (state.liveLeaseCount > 0) {
        --state.liveLeaseCount;
    }
}

const GhidraRuntimeIdentity& GhidraRuntimeLease::identity() const noexcept {
    return identity_;
}

struct GhidraExecutionLock::State final {
    explicit State(std::mutex& mutex) : lock(mutex) {}
    std::unique_lock<std::mutex> lock;
};

GhidraExecutionLock::GhidraExecutionLock() {
    auto& runtime = runtimeState();
    {
        std::lock_guard identityGuard(runtime.identityMutex);
        if (!runtime.started || runtime.initializationFailed) {
            throw ContractError("native-runtime-not-initialized");
        }
    }
    state_ = std::make_unique<State>(runtime.executionMutex);
}

GhidraExecutionLock::~GhidraExecutionLock() = default;
GhidraExecutionLock::GhidraExecutionLock(GhidraExecutionLock&&) noexcept = default;
GhidraExecutionLock& GhidraExecutionLock::operator=(GhidraExecutionLock&&) noexcept = default;

GhidraRuntimeSnapshot ghidraRuntimeSnapshot() {
    auto& state = runtimeState();
    std::lock_guard identityGuard(state.identityMutex);
    return {
        .started = state.started,
        .initializationFailed = state.initializationFailed,
        .liveLeaseCount = state.liveLeaseCount,
        .startupCallCount = state.startupCallCount,
        .identityFrozen = state.frozenIdentity.has_value(),
    };
}

} // namespace macscope::native_decompiler::detail
