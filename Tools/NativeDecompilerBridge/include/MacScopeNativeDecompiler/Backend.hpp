#pragma once

#include "MacScopeNativeDecompiler/InputModel.hpp"
#include "MacScopeNativeDecompiler/OutputModel.hpp"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace macscope::native_decompiler {

struct BackendIdentity final {
    std::string backendId;
    std::string ghidraVersion;
    std::string ghidraGitRevision;
    std::string wrapperVersion;
    std::string wrapperGitRevision;

    bool operator==(const BackendIdentity&) const = default;
};

struct BackendCapabilities final {
    bool nativeDecompilerHeritage = false;
    bool completeRegisterSsa = false;
    bool memorySsa = false;
    bool recoveredVariables = false;
    bool recoveredTypes = false;
    bool structuredControlFlow = false;
    bool tokenizedPseudocode = false;
    bool imageQualifiedSourceRanges = false;

    bool operator==(const BackendCapabilities&) const = default;
};

struct PreparedGhidraRuntimeIdentity final {
    std::string backendId;
    std::string engineVersion;
    std::string engineRevision;
    std::string wrapperVersion;
    std::string wrapperRevision;
    std::string packageManifestSha256;
    std::string packageTreeSha256;
    std::string languageId;
    std::string compilerSpecId;
    std::string targetProfileId;
    std::string contextProfileSha256;

    bool operator==(const PreparedGhidraRuntimeIdentity&) const = default;
};

struct BackendAvailability final {
    bool available = false;
    std::string reasonCode;
    BackendIdentity identity;
    BackendCapabilities capabilities;
    std::optional<PreparedGhidraRuntimeIdentity> runtimeIdentity;

    bool operator==(const BackendAvailability&) const = default;
};

class StructuredDecompilerBackend {
public:
    virtual ~StructuredDecompilerBackend() = default;

    [[nodiscard]] virtual BackendAvailability availability() const = 0;
    [[nodiscard]] virtual StructuredResult decompile(
        const AnalysisRequestView& request,
        const CancellationToken& cancellation
    ) = 0;
};

/// Untrusted structured-output producer. A direct `sleigh::decomp` adapter may
/// implement this interface, but callers must always wrap it with
/// `makeValidatedProviderBackend` before accepting output. Third-party objects
/// are not part of this contract; bounded rendered pseudocode is presentation
/// only and must never be reparsed to manufacture structured semantics.
class NativeStructuredProvider {
public:
    virtual ~NativeStructuredProvider() = default;

    [[nodiscard]] virtual BackendAvailability availability() const = 0;
    [[nodiscard]] virtual StructuredResult produce(
        const AnalysisRequestView& request,
        const CancellationToken& cancellation
    ) = 0;
};

/// Validate one availability record. Available providers require complete
/// immutable identity plus native-heritage and image-qualified-range claims;
/// unavailable providers require a bounded reason and may claim no capability.
void validateBackendAvailability(const BackendAvailability& availability);

/// Construct the fail-closed MacScope validation boundary around an untrusted
/// native structured provider. The wrapper independently checks availability,
/// identity/capability stability, cancellation, elapsed time, result budgets,
/// canonical ordering, graph integrity, and capability truth before returning
/// any result. Access to one provider instance is serialized.
[[nodiscard]] std::unique_ptr<StructuredDecompilerBackend> makeValidatedProviderBackend(
    std::unique_ptr<NativeStructuredProvider> provider
);

/// Sanitized reason code for the most recent provider execution failure that
/// the validated backend suppressed on the calling thread, or an empty view when
/// the latest `decompile` call on this thread did not hit that path. Only
/// MacScope-shaped codes (lowercase ASCII letters, digits and hyphens, at most
/// 96 characters) are retained; anything else, including third-party exception
/// text, becomes "provider-error-unclassified-<FNV-1a 64-bit hex of the text>"
/// (the text itself is never retained) or "provider-exception-unclassified".
/// The thrown message is unchanged.
[[nodiscard]] std::string_view lastSuppressedProviderFailureReason() noexcept;

struct GhidraProviderObserver final {
    struct SignatureReadback final {
        bool variadic = false;
        bool noReturn = false;
        bool inputLocked = false;
        bool outputLocked = false;
        std::string outputTypeName;
        std::int32_t outputTypeSize = 0;
        std::vector<std::string> parameterNames;
        std::vector<std::string> parameterTypeNames;
        std::vector<std::int32_t> parameterTypeSizes;
        std::vector<std::string> parameterStorage;
        std::string outputStorage;
        bool afterAnalysis = false;
    };

    std::function<void()> architectureConstructed;
    std::function<void()> architectureDestroyed;
    std::function<void(std::string_view, std::size_t)> authoredCheckpoint;
    std::function<void(Address, std::string_view, bool)> authoredNameReadback;
    std::function<void(const SignatureReadback&)> authoredSignatureReadback;
    std::function<void(const SignatureReadback&)> authoredSignatureReadbackAfterAnalysis;
    std::function<void(std::string_view, std::string_view)> authoredTypeReadback;
    std::function<void(Address, std::uint64_t, std::string_view, bool)> authoredAppliedReadback;
    std::function<void(Address, Address)> followFlowRange;
    std::function<void()> followFlowEntered;
    std::function<void()> decompileActionEntered;
    /// Retained for source compatibility with existing observers. CP4 always
    /// runs the complete action list and never calls this retired retry hook.
    std::function<void(std::string_view, std::string_view)> actionProfileFallback;
};

struct GhidraBackendConfiguration final {
    std::string packageRoot;
    std::string packageManifestSha256;
    std::string processorSpecRoot;
    std::string languageId;
    std::string compilerSpecId;
    std::shared_ptr<GhidraProviderObserver> observer;
};

[[nodiscard]] std::unique_ptr<StructuredDecompilerBackend> makeGhidraBackend(
    GhidraBackendConfiguration configuration
);

} // namespace macscope::native_decompiler
