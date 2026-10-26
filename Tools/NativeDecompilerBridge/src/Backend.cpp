#include "MacScopeNativeDecompiler/Backend.hpp"
#if defined(MACSCOPE_ENABLE_GHIDRA_PROVIDER)
#include "MacScopeNativeDecompiler/GhidraProvider.hpp"
#endif
#include "TextValidation.hpp"

#include <algorithm>
#include <cstdint>
#include <chrono>
#include <filesystem>
#include <functional>
#include <mutex>
#include <string>
#include <string_view>
#include <utility>

namespace macscope::native_decompiler {
namespace {

constexpr std::size_t kMaximumAvailabilityText = 1024;
constexpr std::size_t kMaximumSuppressedReasonText = 96;

thread_local std::string suppressedProviderFailureReason;

[[nodiscard]] bool isMacScopeReasonCode(std::string_view value) noexcept {
    if (value.empty() || value.size() > kMaximumSuppressedReasonText) return false;
    return std::all_of(value.begin(), value.end(), [](char character) {
        return (character >= 'a' && character <= 'z') ||
            (character >= '0' && character <= '9') || character == '-';
    });
}

// Non-code provider text is never retained; only its FNV-1a fingerprint, so a
// failure can be matched offline against the provider's own message literals.
[[nodiscard]] std::string unclassifiedProviderReason(std::string_view text) {
    std::uint64_t fingerprint = 14695981039346656037ULL;
    for (std::size_t i = 0; i < text.size() && i < 1024U; ++i) {
        fingerprint ^= static_cast<unsigned char>(text[i]);
        fingerprint *= 1099511628211ULL;
    }
    static constexpr char kHex[] = "0123456789abcdef";
    std::string reason = "provider-error-unclassified-";
    for (int shift = 60; shift >= 0; shift -= 4) {
        reason.push_back(kHex[(fingerprint >> shift) & 0xFU]);
    }
    return reason;
}

void recordSuppressedProviderFailure(std::string_view reason) noexcept {
    try {
        suppressedProviderFailureReason.assign(reason);
    } catch (...) {
        suppressedProviderFailureReason.clear();
    }
}
constexpr std::string_view kAppleLanguageId = "AARCH64:LE:64:AppleSilicon";
constexpr std::string_view kAppleCompilerSpecId = "default";
constexpr std::string_view kAppleTargetProfileId =
    "apple-aarch64-pac-visible-clobber-v1";
constexpr std::string_view kAppleContextProfileSha256 =
    "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5";

void requireAvailabilityText(
    std::string_view value,
    std::string_view label,
    bool allowEmpty = false
) {
    if ((!allowEmpty && value.empty()) || value.size() > kMaximumAvailabilityText) {
        throw ContractError(std::string(label) + " must be bounded text");
    }
    if (!detail::isValidUtf8(value)) {
        throw ContractError(std::string(label) + " must be valid UTF-8");
    }
    for (const unsigned char character : value) {
        if (character < 0x20U || character == 0x7fU) {
            throw ContractError(std::string(label) + " contains unsupported control text");
        }
    }
}

void requireReasonCode(std::string_view value) {
    if (value.empty() || value.size() > 128U ||
        !std::all_of(value.begin(), value.end(), [](const unsigned char character) {
            return (character >= 'a' && character <= 'z') ||
                   (character >= '0' && character <= '9') || character == '-';
        })) {
        throw ContractError("unavailable-provider reason code must use lowercase slug syntax");
    }
}

void validateGhidraConfiguration(const GhidraBackendConfiguration& configuration) {
    requireAvailabilityText(configuration.packageRoot, "native package root");
    requireAvailabilityText(configuration.processorSpecRoot, "processor-spec root");
    requireAvailabilityText(configuration.languageId, "language ID");
    requireAvailabilityText(configuration.compilerSpecId, "compiler-spec ID");
    if (configuration.packageManifestSha256.size() != 64U ||
        !std::all_of(
            configuration.packageManifestSha256.begin(),
            configuration.packageManifestSha256.end(),
            [](const unsigned char character) {
                return (character >= '0' && character <= '9') ||
                       (character >= 'a' && character <= 'f');
            }
        )) {
        throw ContractError("native package manifest SHA-256 must be lowercase hexadecimal");
    }

    const auto packageRoot = std::filesystem::path(configuration.packageRoot).lexically_normal();
    const auto processorSpecRoot = std::filesystem::path(configuration.processorSpecRoot).lexically_normal();
    if (!packageRoot.is_absolute() || !processorSpecRoot.is_absolute()) {
        throw ContractError("native package and processor-spec roots must be absolute paths");
    }

    if (packageRoot == processorSpecRoot) {
        throw ContractError("processor-spec root must be a child of the governed native package root");
    }

    auto packageIterator = packageRoot.begin();
    auto processorIterator = processorSpecRoot.begin();
    while (packageIterator != packageRoot.end() && processorIterator != processorSpecRoot.end() &&
           *packageIterator == *processorIterator) {
        ++packageIterator;
        ++processorIterator;
    }
    if (packageIterator != packageRoot.end()) {
        throw ContractError("processor-spec root must remain inside the governed native package root");
    }
    if (configuration.languageId != kAppleLanguageId) {
        throw ContractError("native backend accepts only the governed Apple-Silicon language");
    }
    if (configuration.compilerSpecId != kAppleCompilerSpecId) {
        throw ContractError("native backend accepts only the governed default compiler specification");
    }
}

[[nodiscard]] bool allCapabilitiesFalse(const BackendCapabilities& capabilities) noexcept {
    return !capabilities.nativeDecompilerHeritage && !capabilities.completeRegisterSsa &&
           !capabilities.memorySsa && !capabilities.recoveredVariables &&
           !capabilities.recoveredTypes && !capabilities.structuredControlFlow &&
           !capabilities.tokenizedPseudocode && !capabilities.imageQualifiedSourceRanges;
}

void validateRevision(std::string_view revision, std::string_view label) {
    if ((revision.size() != 40 && revision.size() != 64) ||
        !std::all_of(revision.begin(), revision.end(), [](unsigned char character) {
            return (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f');
        })) {
        throw ContractError(std::string(label) + " must be a 40- or 64-character lowercase hexadecimal revision");
    }
}

void validateSha256(std::string_view digest, std::string_view label) {
    if (digest.size() != 64U ||
        !std::all_of(digest.begin(), digest.end(), [](unsigned char character) {
            return (character >= '0' && character <= '9') ||
                   (character >= 'a' && character <= 'f');
        })) {
        throw ContractError(std::string(label) + " must be a 64-character lowercase hexadecimal SHA-256");
    }
}

void validatePreparedRuntimeIdentity(
    const PreparedGhidraRuntimeIdentity& runtimeIdentity,
    const BackendIdentity& legacyIdentity
) {
    requireAvailabilityText(runtimeIdentity.backendId, "prepared runtime backend ID");
    requireAvailabilityText(runtimeIdentity.engineVersion, "prepared runtime engine version");
    requireAvailabilityText(runtimeIdentity.wrapperVersion, "prepared runtime wrapper version");
    validateRevision(runtimeIdentity.engineRevision, "prepared runtime engine revision");
    validateRevision(runtimeIdentity.wrapperRevision, "prepared runtime wrapper revision");
    validateSha256(
        runtimeIdentity.packageManifestSha256,
        "prepared runtime package-manifest SHA-256"
    );
    validateSha256(runtimeIdentity.packageTreeSha256, "prepared runtime package-tree SHA-256");
    requireAvailabilityText(runtimeIdentity.languageId, "prepared runtime language ID");
    requireAvailabilityText(runtimeIdentity.compilerSpecId, "prepared runtime compiler-spec ID");
    requireAvailabilityText(runtimeIdentity.targetProfileId, "prepared runtime target-profile ID");
    validateSha256(
        runtimeIdentity.contextProfileSha256,
        "prepared runtime context-profile SHA-256"
    );

    if (runtimeIdentity.languageId != kAppleLanguageId ||
        runtimeIdentity.compilerSpecId != kAppleCompilerSpecId ||
        runtimeIdentity.targetProfileId != kAppleTargetProfileId ||
        runtimeIdentity.contextProfileSha256 != kAppleContextProfileSha256) {
        throw ContractError("prepared runtime identity does not match the sealed Apple profile");
    }

    if (runtimeIdentity.backendId != legacyIdentity.backendId ||
        runtimeIdentity.engineVersion != legacyIdentity.ghidraVersion ||
        runtimeIdentity.engineRevision != legacyIdentity.ghidraGitRevision ||
        runtimeIdentity.wrapperVersion != legacyIdentity.wrapperVersion ||
        runtimeIdentity.wrapperRevision != legacyIdentity.wrapperGitRevision) {
        throw ContractError("prepared runtime identity conflicts with the legacy compiled identity");
    }
}

[[nodiscard]] BackendAvailability sanitizedInvalidAvailability() {
    BackendAvailability unavailable;
    unavailable.available = false;
    unavailable.reasonCode = "provider-availability-invalid";
    return unavailable;
}

void requireNoTypeReferences(const StructuredResult& result) {
    if (!result.types.empty()) {
        throw ContractError("provider returned type records without the recovered-types capability");
    }
    for (const auto& varnode : result.varnodes) {
        if (varnode.typeId) {
            throw ContractError("provider returned a varnode type without the recovered-types capability");
        }
    }
    for (const auto& variable : result.variables) {
        if (variable.typeId) {
            throw ContractError("provider returned a variable type without the recovered-types capability");
        }
    }
    for (const auto& call : result.calls) {
        if (call.prototypeTypeId) {
            throw ContractError("provider returned a call prototype without the recovered-types capability");
        }
    }
}

void validateCapabilityTruth(
    const BackendCapabilities& capabilities,
    const StructuredResult& result
) {
    if (!capabilities.nativeDecompilerHeritage || !capabilities.imageQualifiedSourceRanges) {
        throw ContractError("available structured provider lacks mandatory native capability claims");
    }
    if (result.instructions.empty() || result.addressSpaces.empty() || result.varnodes.empty() ||
        result.operations.empty() || result.blocks.empty()) {
        throw ContractError("native heritage capability requires structured instruction and p-code foundations");
    }

    if (capabilities.completeRegisterSsa) {
        if (result.ssaValues.empty() || result.ssaBindings.size() != result.operations.size()) {
            throw ContractError("complete-register-SSA capability lacks register SSA foundations");
        }
    }

    if (!capabilities.memorySsa &&
        (!result.memoryVersions.empty() || !result.memoryPhis.empty() || !result.memoryEffects.empty())) {
        throw ContractError("provider returned MemorySSA records without the MemorySSA capability");
    }
    if (capabilities.memorySsa && result.memoryVersions.empty()) {
        throw ContractError("MemorySSA capability requires at least a function-entry memory version");
    }

    if (!capabilities.recoveredVariables && !result.variables.empty()) {
        throw ContractError("provider returned variables without the variable-recovery capability");
    }
    if (!capabilities.recoveredVariables) {
        for (const auto& call : result.calls) {
            if (!call.argumentVariableIds.empty() || call.resultVariableId) {
                throw ContractError("provider returned call-variable references without variable recovery");
            }
        }
    }

    if (!capabilities.recoveredTypes) {
        requireNoTypeReferences(result);
    } else if (result.types.empty()) {
        throw ContractError("recovered-types capability requires at least one type record");
    }

    if (!capabilities.structuredControlFlow && !result.regions.empty()) {
        throw ContractError("provider returned regions without structured-control-flow capability");
    }
    if (capabilities.structuredControlFlow && result.regions.empty()) {
        throw ContractError("structured-control-flow capability requires at least one region");
    }

    if (!capabilities.tokenizedPseudocode && !result.tokens.empty()) {
        throw ContractError("provider returned tokens without tokenized-pseudocode capability");
    }
    if (capabilities.tokenizedPseudocode && result.tokens.empty() &&
        std::none_of(result.warnings.begin(), result.warnings.end(), [](const auto& warning) {
            return warning.code == "native-pseudocode-token-metadata-omitted";
        })) {
        throw ContractError("tokenized-pseudocode capability requires at least one token");
    }

    const auto requireRanges = [](const auto& values, auto selector, std::string_view label) {
        for (const auto& value : values) {
            if (std::invoke(selector, value).empty()) {
                throw ContractError(std::string(label) + " requires an image-qualified source range");
            }
        }
    };
    requireRanges(result.instructions, &InstructionRecord::sourceRanges, "instruction");
    requireRanges(result.operations, &OperationRecord::sourceRanges, "operation");
    requireRanges(result.variables, &VariableRecord::liveRanges, "variable");
    requireRanges(result.calls, &CallRecord::sourceRanges, "call");
    requireRanges(result.regions, &RegionRecord::sourceRanges, "region");
    requireRanges(result.tokens, &PseudocodeTokenRecord::sourceRanges, "token");
}

void enforceResultBudgets(
    const AnalysisRequestView& request,
    const StructuredResult& result,
    const CancellationToken& cancellation
) {
    if (result.instructions.size() > request.budgets.maxInstructions) {
        throw ContractError("structured result exceeds the instruction-count budget");
    }
    if (result.operations.size() > request.budgets.maxOperations) {
        throw ContractError("structured result exceeds the operation-count budget");
    }
    if (structuredResultEncodedSizeUpperBound(
            result, [&cancellation] { cancellation.throwIfCancelled(); }
        ) > request.budgets.maxOutputBytes) {
        throw ContractError("structured result exceeds the publication-size budget");
    }
}

void enforceElapsedBudget(
    const AnalysisRequestView& request,
    std::chrono::steady_clock::time_point started
) {
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started
    );
    if (elapsed.count() < 0 ||
        static_cast<std::uint64_t>(elapsed.count()) > request.budgets.maxWallTimeMilliseconds) {
        throw ContractError("native structured provider exceeded the wall-time publication budget");
    }
}

class ValidatedProviderBackend final : public StructuredDecompilerBackend {
public:
    explicit ValidatedProviderBackend(std::unique_ptr<NativeStructuredProvider> provider)
        : provider_(std::move(provider)) {
        if (!provider_) {
            throw ContractError("validated provider backend requires a non-null provider");
        }
    }

    BackendAvailability availability() const override {
        // Availability is a status query, not permission to block behind an
        // untrusted analysis call. Return a truthful transient state when the
        // serialized provider is occupied; production execution will move to
        // a separately killable process boundary.
        std::unique_lock<std::timed_mutex> lock(providerMutex_, std::defer_lock);
        if (!lock.try_lock()) {
            BackendAvailability busy;
            busy.available = false;
            busy.reasonCode = "provider-busy";
            return busy;
        }
        try {
            auto result = provider_->availability();
            validateBackendAvailability(result);
            return result;
        } catch (...) {
            return sanitizedInvalidAvailability();
        }
    }

    StructuredResult decompile(
        const AnalysisRequestView& request,
        const CancellationToken& cancellation
    ) override {
        const auto started = std::chrono::steady_clock::now();
        suppressedProviderFailureReason.clear();
        cancellation.throwIfCancelled();

        std::unique_lock<std::timed_mutex> lock(providerMutex_, std::defer_lock);
        while (!lock.try_lock_for(std::chrono::milliseconds(1))) {
            cancellation.throwIfCancelled();
            enforceElapsedBudget(request, started);
        }
        cancellation.throwIfCancelled();
        enforceElapsedBudget(request, started);

        BackendAvailability initial;
        try {
            initial = provider_->availability();
            validateBackendAvailability(initial);
        } catch (...) {
            throw ContractError("structured provider availability is invalid");
        }
        if (!initial.available) {
            throw ContractError("native structured provider is unavailable");
        }
        cancellation.throwIfCancelled();
        enforceElapsedBudget(request, started);

        StructuredResult result;
        try {
            result = provider_->produce(request, cancellation);
        } catch (const ContractError& error) {
            if (isMacScopeReasonCode(error.what())) {
                recordSuppressedProviderFailure(error.what());
            } else {
                try {
                    recordSuppressedProviderFailure(unclassifiedProviderReason(error.what()));
                } catch (...) {
                    recordSuppressedProviderFailure("provider-error-unclassified");
                }
            }
            cancellation.throwIfCancelled();
            if (std::string_view(error.what()) == "authoring-input-unsupported") {
                throw ContractError("authoring-input-unsupported");
            }
            if (std::string_view(error.what()) == "native-provider-operation-opcode-unavailable") {
                throw ContractError("native-provider-operation-opcode-unavailable");
            }
            // Preserve numeric-only budget evidence without exposing provider
            // text or changing the stable generic error and suppressed reason.
            if (error.outputBudgetDiagnostics()) {
                throw ContractError("structured provider execution failed",
                                    *error.outputBudgetDiagnostics());
            }
            throw ContractError("structured provider execution failed");
        } catch (...) {
            recordSuppressedProviderFailure("provider-exception-unclassified");
            cancellation.throwIfCancelled();
            throw ContractError("structured provider execution failed");
        }
        cancellation.throwIfCancelled();
        enforceElapsedBudget(request, started);

        // Reject over-budget raw collections before any provider-controlled
        // ordering can trigger sorting or additional validation allocations.
        enforceResultBudgets(request, result, cancellation);
        result = canonicalizedStructuredResult(std::move(result));
        validateStructuredResult(request, result);
        // A document-only reply has no graph to hold to the capability claims.
        if (!request.documentOnly) validateCapabilityTruth(initial.capabilities, result);
        enforceResultBudgets(request, result, cancellation);
        cancellation.throwIfCancelled();
        enforceElapsedBudget(request, started);

        BackendAvailability finalAvailability;
        try {
            finalAvailability = provider_->availability();
            validateBackendAvailability(finalAvailability);
        } catch (...) {
            throw ContractError("structured provider availability changed to an invalid record");
        }
        if (!(finalAvailability == initial)) {
            throw ContractError("native structured provider identity or capabilities changed during analysis");
        }

        cancellation.throwIfCancelled();
        enforceElapsedBudget(request, started);
        return result;
    }

private:
    std::unique_ptr<NativeStructuredProvider> provider_;
    mutable std::timed_mutex providerMutex_;
};

class UnavailableGhidraBackend final : public StructuredDecompilerBackend {
public:
    explicit UnavailableGhidraBackend(GhidraBackendConfiguration configuration)
        : configuration_(std::move(configuration)) {}

    BackendAvailability availability() const override {
        BackendAvailability result;
        result.available = false;
        result.reasonCode = "native-ghidra-adapter-not-linked";
        result.identity.backendId = "ghidra-native-decompiler";
        result.runtimeIdentity.reset();
        return result;
    }

    StructuredResult decompile(const AnalysisRequestView&, const CancellationToken&) override {
        throw ContractError("native Ghidra adapter is not linked in DCP-03B4 qualification mode");
    }

private:
    [[maybe_unused]] GhidraBackendConfiguration configuration_;
};

} // namespace

void validateBackendAvailability(const BackendAvailability& availability) {
    if (!availability.available) {
        requireReasonCode(availability.reasonCode);
        if (!allCapabilitiesFalse(availability.capabilities)) {
            throw ContractError("unavailable structured provider cannot claim capabilities");
        }
        if (!availability.identity.backendId.empty()) {
            requireAvailabilityText(availability.identity.backendId, "unavailable backend ID");
        }
        if (!availability.identity.ghidraVersion.empty() ||
            !availability.identity.ghidraGitRevision.empty() ||
            !availability.identity.wrapperVersion.empty() ||
            !availability.identity.wrapperGitRevision.empty()) {
            throw ContractError("unavailable structured provider cannot claim a versioned backend identity");
        }
        if (availability.runtimeIdentity) {
            throw ContractError("unavailable structured provider cannot claim a prepared runtime identity");
        }
        return;
    }

    if (!availability.reasonCode.empty()) {
        throw ContractError("available structured provider cannot carry an unavailability reason");
    }
    requireAvailabilityText(availability.identity.backendId, "backend ID");
    requireAvailabilityText(availability.identity.ghidraVersion, "Ghidra version");
    requireAvailabilityText(availability.identity.wrapperVersion, "wrapper version");
    validateRevision(availability.identity.ghidraGitRevision, "Ghidra Git revision");
    validateRevision(availability.identity.wrapperGitRevision, "wrapper Git revision");
    if (!availability.runtimeIdentity) {
        throw ContractError("available structured provider must carry a prepared runtime identity");
    }
    validatePreparedRuntimeIdentity(*availability.runtimeIdentity, availability.identity);
    if (!availability.capabilities.nativeDecompilerHeritage ||
        !availability.capabilities.imageQualifiedSourceRanges) {
        throw ContractError(
            "available structured provider must claim native heritage and image-qualified source ranges"
        );
    }
}

std::string_view lastSuppressedProviderFailureReason() noexcept {
    return suppressedProviderFailureReason;
}

std::unique_ptr<StructuredDecompilerBackend> makeValidatedProviderBackend(
    std::unique_ptr<NativeStructuredProvider> provider
) {
    return std::make_unique<ValidatedProviderBackend>(std::move(provider));
}

std::unique_ptr<StructuredDecompilerBackend> makeGhidraBackend(GhidraBackendConfiguration configuration) {
    validateGhidraConfiguration(configuration);
#if defined(MACSCOPE_ENABLE_GHIDRA_PROVIDER)
    return makeValidatedProviderBackend(makeGhidraProvider(std::move(configuration)));
#else
    return std::make_unique<UnavailableGhidraBackend>(std::move(configuration));
#endif
}

} // namespace macscope::native_decompiler
