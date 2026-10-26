#pragma once

#include "MacScopeNativeDecompiler/InputModel.hpp"

#include <ghidra/loadimage.hh>
#include <ghidra/sleigh_arch.hh>

#include <array>
#include <cstdint>
#include <iosfwd>
#include <memory>
#include <string>
#include <vector>

namespace macscope::native_decompiler::detail {

class GhidraExecutionLock;
enum class GhidraReadinessFault : std::uint8_t;

class GhidraRequestCheckpoint {
public:
    virtual ~GhidraRequestCheckpoint() = default;
    virtual void checkpoint() const = 0;
};

class EffectiveByteLoadImage final : public ghidra::LoadImage {
public:
    EffectiveByteLoadImage(
        const ByteProvider& bytes,
        const GhidraRequestCheckpoint& checkpoint,
        std::string languageId
    );

    void loadFill(ghidra::uint1* destination, ghidra::int4 size, const ghidra::Address& address) override;
    [[nodiscard]] std::string getArchType() const override;
    void getReadonly(ghidra::RangeList& ranges) const override;
    void adjustVma(long adjustment) override;

    void attachToRamSpace(ghidra::AddrSpace* addressSpace);
    [[nodiscard]] bool hadUnavailableRead() const noexcept;

private:
    struct EffectiveRegion final {
        Address startAddress = 0;
        bool writable = false;
        std::vector<std::uint8_t> bytes;

        [[nodiscard]] Address endAddressExclusive() const noexcept;
    };

    [[noreturn]] void failUnavailable(const char* reason);

    const GhidraRequestCheckpoint* checkpoint_;
    std::string languageId_;
    std::vector<EffectiveRegion> readableRegions_;
    ghidra::AddrSpace* ramSpace_ = nullptr;
    bool hadUnavailableRead_ = false;
};

/// Synchronous native architecture. The load image owns a snapshot produced
/// through ByteProvider::readEffective; the checkpoint is borrowed only until
/// the synchronous provider call returns.
class GhidraArchitecture final : public ghidra::SleighArchitecture {
public:
    GhidraArchitecture(
        const AnalysisRequestView& request,
        const CancellationToken& cancellation,
        const GhidraRequestCheckpoint& checkpoint,
        const GhidraExecutionLock& executionLock,
        std::string targetId,
        std::ostream& diagnosticStream,
        GhidraReadinessFault readinessFault
    );

    void initialize(ghidra::DocumentStorage& documentStorage);
    void requireProfileHookComplete() const;
    [[nodiscard]] std::array<TargetContextValue, 4> appliedContextProfile() const;
    void throwIfUnavailableEffectiveByteRead() const;
    [[nodiscard]] ghidra::TypeFactory& typeFactory() const;

protected:
    void buildLoader(ghidra::DocumentStorage& documentStorage) override;
    void postSpecFile() override;

private:
    const GhidraRequestCheckpoint* checkpoint_;
    std::string languageId_;
    std::unique_ptr<EffectiveByteLoadImage> pendingLoader_;
    EffectiveByteLoadImage* effectiveLoader_ = nullptr;
    GhidraReadinessFault readinessFault_;
    bool profileHookComplete_ = false;
    std::array<TargetContextValue, 4> appliedContextProfile_{};
};

} // namespace macscope::native_decompiler::detail
