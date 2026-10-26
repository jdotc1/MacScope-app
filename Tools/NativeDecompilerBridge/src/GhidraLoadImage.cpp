#include "GhidraArchitectureInternal.hpp"

#include <algorithm>
#include <cstddef>
#include <limits>
#include <utility>

namespace macscope::native_decompiler::detail {

EffectiveByteLoadImage::EffectiveByteLoadImage(
    const ByteProvider& bytes,
    const GhidraRequestCheckpoint& checkpoint,
    std::string languageId
) : ghidra::LoadImage("macscope-effective-memory"),
    checkpoint_(&checkpoint),
    languageId_(std::move(languageId)) {
    readableRegions_.reserve(bytes.regions().size());
    for (const auto& region : bytes.regions()) {
        checkpoint_->checkpoint();
        if (!region.readable()) {
            continue;
        }
        auto effectiveBytes = bytes.readEffective(region.startAddress, region.effectiveBytes.size());
        readableRegions_.push_back(EffectiveRegion{
            .startAddress = region.startAddress,
            .writable = region.writable(),
            .bytes = std::move(effectiveBytes),
        });
    }
}

Address EffectiveByteLoadImage::EffectiveRegion::endAddressExclusive() const noexcept {
    return startAddress + static_cast<Address>(bytes.size());
}

[[noreturn]] void EffectiveByteLoadImage::failUnavailable(const char* reason) {
    hadUnavailableRead_ = true;
    throw ghidra::DataUnavailError(reason);
}

void EffectiveByteLoadImage::loadFill(
    ghidra::uint1* destination,
    ghidra::int4 size,
    const ghidra::Address& address
) {
    if (destination == nullptr || size < 0) {
        failUnavailable("effective-byte-read-invalid");
    }
    if (size == 0) {
        return;
    }
    checkpoint_->checkpoint();
    if (address.isInvalid()) {
        failUnavailable("effective-byte-read-invalid-address");
    }
    const auto* addressSpace = address.getSpace();
    if (ramSpace_ == nullptr || addressSpace != ramSpace_) {
        failUnavailable("effective-byte-read-invalid-space");
    }

    const auto unsignedSize = static_cast<std::uint64_t>(size);
    const auto nativeOffset = address.getOffset();
    if (unsignedSize > std::numeric_limits<Address>::max() - nativeOffset) {
        failUnavailable("effective-byte-read-overflow");
    }

    const auto endAddress = static_cast<Address>(nativeOffset + unsignedSize);
    auto cursor = static_cast<Address>(nativeOffset);
    auto* output = destination;
    for (const auto& region : readableRegions_) {
        if (region.endAddressExclusive() <= cursor) {
            continue;
        }
        if (region.startAddress > cursor) {
            break;
        }
        const auto takeEnd = std::min(endAddress, region.endAddressExclusive());
        const auto offset = static_cast<std::size_t>(cursor - region.startAddress);
        const auto count = static_cast<std::size_t>(takeEnd - cursor);
        std::copy_n(region.bytes.begin() + static_cast<std::ptrdiff_t>(offset), count, output);
        output += count;
        cursor = takeEnd;
        if (cursor == endAddress) {
            checkpoint_->checkpoint();
            return;
        }
    }
    failUnavailable("effective-byte-read-unmapped");
}

std::string EffectiveByteLoadImage::getArchType() const {
    return languageId_;
}

void EffectiveByteLoadImage::getReadonly(ghidra::RangeList& ranges) const {
    if (ramSpace_ == nullptr) {
        throw ContractError("native-load-image-address-space-unavailable");
    }
    for (const auto& region : readableRegions_) {
        if (!region.writable) {
            ranges.insertRange(
                ramSpace_,
                static_cast<ghidra::uintb>(region.startAddress),
                static_cast<ghidra::uintb>(region.endAddressExclusive() - 1U)
            );
        }
    }
}

void EffectiveByteLoadImage::adjustVma(long adjustment) {
    if (adjustment != 0) {
        throw ContractError("effective-byte-vma-adjustment-unsupported");
    }
}

void EffectiveByteLoadImage::attachToRamSpace(ghidra::AddrSpace* addressSpace) {
    if (addressSpace == nullptr ||
        addressSpace->getType() != ghidra::IPTR_PROCESSOR ||
        addressSpace->getName() != "ram") {
        throw ContractError("native-load-image-address-space-invalid");
    }
    if (ramSpace_ != nullptr && ramSpace_ != addressSpace) {
        throw ContractError("native-load-image-address-space-changed");
    }
    ramSpace_ = addressSpace;
}

bool EffectiveByteLoadImage::hadUnavailableRead() const noexcept {
    return hadUnavailableRead_;
}

} // namespace macscope::native_decompiler::detail
