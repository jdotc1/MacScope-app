#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace macscope::native_decompiler::detail {

/// Strict UTF-8 validation for text crossing the native-decompiler trust
/// boundary. Rejects overlong encodings, UTF-16 surrogate code points,
/// truncated sequences, and values above U+10FFFF.
[[nodiscard]] inline bool isValidUtf8(std::string_view value) noexcept {
    const auto* bytes = reinterpret_cast<const std::uint8_t*>(value.data());
    const std::size_t size = value.size();
    std::size_t index = 0;
    const auto continuation = [&](std::size_t position) noexcept {
        return position < size && (bytes[position] & 0xc0U) == 0x80U;
    };

    while (index < size) {
        const std::uint8_t lead = bytes[index];
        if (lead <= 0x7fU) {
            ++index;
            continue;
        }
        if (lead >= 0xc2U && lead <= 0xdfU) {
            if (!continuation(index + 1U)) return false;
            index += 2U;
            continue;
        }
        if (lead == 0xe0U) {
            if (index + 2U >= size || bytes[index + 1U] < 0xa0U || bytes[index + 1U] > 0xbfU ||
                !continuation(index + 2U)) {
                return false;
            }
            index += 3U;
            continue;
        }
        if ((lead >= 0xe1U && lead <= 0xecU) || (lead >= 0xeeU && lead <= 0xefU)) {
            if (!continuation(index + 1U) || !continuation(index + 2U)) return false;
            index += 3U;
            continue;
        }
        if (lead == 0xedU) {
            if (index + 2U >= size || bytes[index + 1U] < 0x80U || bytes[index + 1U] > 0x9fU ||
                !continuation(index + 2U)) {
                return false;
            }
            index += 3U;
            continue;
        }
        if (lead == 0xf0U) {
            if (index + 3U >= size || bytes[index + 1U] < 0x90U || bytes[index + 1U] > 0xbfU ||
                !continuation(index + 2U) || !continuation(index + 3U)) {
                return false;
            }
            index += 4U;
            continue;
        }
        if (lead >= 0xf1U && lead <= 0xf3U) {
            if (!continuation(index + 1U) || !continuation(index + 2U) || !continuation(index + 3U)) {
                return false;
            }
            index += 4U;
            continue;
        }
        if (lead == 0xf4U) {
            if (index + 3U >= size || bytes[index + 1U] < 0x80U || bytes[index + 1U] > 0x8fU ||
                !continuation(index + 2U) || !continuation(index + 3U)) {
                return false;
            }
            index += 4U;
            continue;
        }
        return false;
    }
    return true;
}

} // namespace macscope::native_decompiler::detail
