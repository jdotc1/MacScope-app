#include "GhidraArchitectureInternal.hpp"
#include "GhidraRuntimeInternal.hpp"

#include <array>
#include <exception>
#include <ostream>
#include <utility>

namespace macscope::native_decompiler::detail {
namespace {

[[nodiscard]] const std::string& checkedTarget(
    const AnalysisRequestView& request,
    const std::string& targetId
) {
    validateGhidraLanguageAndCompiler(request.languageId, request.compilerSpecId);
    if (targetId != request.languageId + ":" + request.compilerSpecId) {
        throw ContractError("native-architecture-target-mismatch");
    }
    return targetId;
}

const std::array<TargetContextValue, 4> kAppleContextProfile = {{
    TargetContextValue{"ShowPAC", 1},
    TargetContextValue{"PAC_clobber", 1},
    TargetContextValue{"ShowBTI", 0},
    TargetContextValue{"ShowMemTag", 0},
}};

} // namespace

GhidraArchitecture::GhidraArchitecture(
    const AnalysisRequestView& request,
    const CancellationToken& cancellation,
    const GhidraRequestCheckpoint& checkpoint,
    const GhidraExecutionLock& executionLock,
    std::string targetId,
    std::ostream& diagnosticStream,
    GhidraReadinessFault readinessFault
) : ghidra::SleighArchitecture(
        "macscope-effective-memory",
        checkedTarget(request, targetId),
        &diagnosticStream
    ),
    checkpoint_(&checkpoint),
    languageId_(request.languageId),
    pendingLoader_(std::make_unique<EffectiveByteLoadImage>(
        request.bytes,
        checkpoint,
        languageId_
    )),
    readinessFault_(readinessFault) {
    static_cast<void>(executionLock);
    cancellation.throwIfCancelled();
}

void GhidraArchitecture::initialize(ghidra::DocumentStorage& documentStorage) {
    checkpoint_->checkpoint();
    init(documentStorage);
    requireProfileHookComplete();
    checkpoint_->checkpoint();
}

void GhidraArchitecture::requireProfileHookComplete() const {
    if (!profileHookComplete_) {
        throw ContractError("native-apple-profile-hook-incomplete");
    }
}

std::array<TargetContextValue, 4> GhidraArchitecture::appliedContextProfile() const {
    requireProfileHookComplete();
    return appliedContextProfile_;
}

void GhidraArchitecture::throwIfUnavailableEffectiveByteRead() const {
    requireProfileHookComplete();
    if (effectiveLoader_ == nullptr) {
        throw ContractError("native-provider-effective-byte-loader-unavailable");
    }
    if (effectiveLoader_->hadUnavailableRead()) {
        throw ContractError("native-provider-effective-byte-read-unavailable");
    }
}

ghidra::TypeFactory& GhidraArchitecture::typeFactory() const {
    requireProfileHookComplete();
    if (types == nullptr) {
        throw ContractError("native-provider-type-factory-unavailable");
    }
    return *types;
}

void GhidraArchitecture::buildLoader(ghidra::DocumentStorage& documentStorage) {
    static_cast<void>(documentStorage);
    checkpoint_->checkpoint();
    if (pendingLoader_ == nullptr || effectiveLoader_ != nullptr || loader != nullptr) {
        throw ContractError("native-load-image-build-state-invalid");
    }
    effectiveLoader_ = pendingLoader_.get();
    loader = pendingLoader_.release();
}

void GhidraArchitecture::postSpecFile() {
    profileHookComplete_ = false;
    if (effectiveLoader_ == nullptr) {
        throw ContractError("native-load-image-build-state-invalid");
    }
    effectiveLoader_->attachToRamSpace(getDefaultCodeSpace());
    ghidra::Architecture::postSpecFile();

    if (readinessFault_ == GhidraReadinessFault::nullContext || context == nullptr) {
        throw ContractError("native-apple-profile-context-unavailable");
    }
    if (readinessFault_ == GhidraReadinessFault::nullTranslator || translate == nullptr) {
        throw ContractError("native-apple-profile-translator-unavailable");
    }
    if (readinessFault_ == GhidraReadinessFault::missingShowPac) {
        throw ContractError("native-apple-profile-context-missing");
    }

    try {
        context->setVariableDefault(kAppleContextProfile[0].name, kAppleContextProfile[0].value);
        context->setVariableDefault(
            kAppleContextProfile[1].name,
            readinessFault_ == GhidraReadinessFault::mismatchedPacClobber
                ? 0
                : kAppleContextProfile[1].value
        );
        context->setVariableDefault(kAppleContextProfile[2].name, kAppleContextProfile[2].value);
        context->setVariableDefault(kAppleContextProfile[3].name, kAppleContextProfile[3].value);

        for (std::size_t index = 0; index < kAppleContextProfile.size(); ++index) {
            appliedContextProfile_[index] = TargetContextValue{
                kAppleContextProfile[index].name,
                context->getDefaultValue(kAppleContextProfile[index].name),
            };
            if (appliedContextProfile_[index] != kAppleContextProfile[index]) {
                throw ContractError("native-apple-profile-context-mismatch");
            }
        }
    } catch (const ContractError&) {
        throw;
    } catch (const ghidra::LowlevelError&) {
        throw ContractError("native-apple-profile-context-missing");
    } catch (const std::exception&) {
        throw ContractError("native-apple-profile-context-missing");
    } catch (...) {
        throw ContractError("native-apple-profile-context-missing");
    }

    profileHookComplete_ = true;
}

} // namespace macscope::native_decompiler::detail
