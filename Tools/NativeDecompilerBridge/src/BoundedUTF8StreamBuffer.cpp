#include "BoundedUTF8StreamBuffer.hpp"

#include <algorithm>
#include <cstring>

namespace macscope::native_decompiler::detail {
namespace {

[[nodiscard]] std::size_t completeUtf8PrefixLength(const std::string& value) noexcept {
    if (value.empty()) return 0U;

    std::size_t leadIndex = value.size() - 1U;
    while (leadIndex > 0U &&
           (static_cast<unsigned char>(value[leadIndex]) & 0xc0U) == 0x80U) {
        --leadIndex;
    }
    const auto lead = static_cast<unsigned char>(value[leadIndex]);
    std::size_t scalarLength = 1U;
    if ((lead & 0xe0U) == 0xc0U) {
        scalarLength = 2U;
    } else if ((lead & 0xf0U) == 0xe0U) {
        scalarLength = 3U;
    } else if ((lead & 0xf8U) == 0xf0U) {
        scalarLength = 4U;
    }
    return value.size() - leadIndex < scalarLength ? leadIndex : value.size();
}

} // namespace

BoundedUTF8StreamBuffer::BoundedUTF8StreamBuffer(std::size_t capacity)
    : storage_(capacity) {}

std::string BoundedUTF8StreamBuffer::text() const {
    if (used_ == 0U) return {};
    std::string value(storage_.data(), used_);
    if (overflowed_) value.resize(completeUtf8PrefixLength(value));
    return value;
}

std::streamsize BoundedUTF8StreamBuffer::xsputn(
    const char* source,
    std::streamsize count
) {
    if (count <= 0) return 0;
    const auto requested = static_cast<std::size_t>(count);
    const auto available = storage_.size() - used_;
    const auto retained = std::min(requested, available);
    if (retained != 0U) {
        std::memcpy(storage_.data() + used_, source, retained);
        used_ += retained;
    }
    if (retained != requested) overflowed_ = true;
    return count;
}

BoundedUTF8StreamBuffer::int_type BoundedUTF8StreamBuffer::overflow(int_type character) {
    if (traits_type::eq_int_type(character, traits_type::eof())) {
        return traits_type::not_eof(character);
    }
    if (used_ < storage_.size()) {
        storage_[used_++] = traits_type::to_char_type(character);
    } else {
        overflowed_ = true;
    }
    return traits_type::not_eof(character);
}

} // namespace macscope::native_decompiler::detail
