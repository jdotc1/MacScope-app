#pragma once

#include <cstddef>
#include <streambuf>
#include <string>
#include <vector>

namespace macscope::native_decompiler::detail {

class BoundedUTF8StreamBuffer final : public std::streambuf {
public:
    explicit BoundedUTF8StreamBuffer(std::size_t capacity);

    [[nodiscard]] std::string text() const;
    [[nodiscard]] bool overflowed() const noexcept { return overflowed_; }

protected:
    std::streamsize xsputn(const char* source, std::streamsize count) override;
    int_type overflow(int_type character) override;

private:
    std::vector<char> storage_;
    std::size_t used_ = 0U;
    bool overflowed_ = false;
};

} // namespace macscope::native_decompiler::detail
