#include <stdint.h>

#if defined(__clang__)
#define MACSCOPE_EXPORT __attribute__((visibility("default"), noinline, used))
#else
#define MACSCOPE_EXPORT
#endif

typedef uint64_t (*macscope_fixture_unary_function)(uint64_t);

MACSCOPE_EXPORT uint64_t macscope_fixture_direct_target(uint64_t value) {
    return (value * UINT64_C(5)) ^ UINT64_C(0x44);
}
MACSCOPE_EXPORT uint64_t macscope_fixture_direct_call(uint64_t value) {
    const uint64_t result = macscope_fixture_direct_target(value);
    return result + UINT64_C(3);
}

MACSCOPE_EXPORT uint64_t macscope_fixture_indirect_call(
    macscope_fixture_unary_function function,
    uint64_t value
) {
    if (function == 0) {
        return UINT64_C(0);
    }
    const uint64_t result = function(value);
    return result ^ UINT64_C(0x99);
}

MACSCOPE_EXPORT uint64_t macscope_fixture_call_chain(
    macscope_fixture_unary_function function,
    uint64_t value
) {
    const uint64_t direct = macscope_fixture_direct_call(value);
    return macscope_fixture_indirect_call(function, direct) + UINT64_C(1);
}
