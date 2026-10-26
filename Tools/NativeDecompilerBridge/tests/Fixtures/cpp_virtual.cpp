#include <cstdint>

#if defined(__clang__)
#define MACSCOPE_EXPORT __attribute__((visibility("default"), noinline, used))
#else
#define MACSCOPE_EXPORT
#endif

class MacScopeDCPBase {
public:
    virtual std::uint64_t combine(std::uint64_t first, std::uint64_t second) const;
};

class MacScopeDCPDerived final : public MacScopeDCPBase {
public:
    std::uint64_t combine(std::uint64_t first, std::uint64_t second) const override;
};

std::uint64_t MacScopeDCPBase::combine(
    std::uint64_t first,
    std::uint64_t second
) const {
    return first + second;
}
std::uint64_t MacScopeDCPDerived::combine(
    std::uint64_t first,
    std::uint64_t second
) const {
    return (first * UINT64_C(7)) ^ second;
}

extern "C" MACSCOPE_EXPORT std::uint64_t macscope_fixture_cpp_virtual_dispatch(
    const MacScopeDCPBase *receiver,
    std::uint64_t first,
    std::uint64_t second
) {
    const std::uint64_t result = receiver->combine(first, second);
    return result + UINT64_C(1);
}

extern "C" MACSCOPE_EXPORT std::uint64_t macscope_fixture_cpp_direct_dispatch(
    std::uint64_t first,
    std::uint64_t second
) {
    MacScopeDCPDerived receiver;
    return receiver.combine(first, second) ^ UINT64_C(0x3c);
}
