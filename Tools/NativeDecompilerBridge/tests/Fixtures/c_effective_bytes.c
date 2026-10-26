#include <stdint.h>

#if defined(__clang__)
#define MACSCOPE_EXPORT __attribute__((visibility("default"), noinline, used))
#define MACSCOPE_NOINLINE __attribute__((noinline))
#else
#define MACSCOPE_EXPORT
#define MACSCOPE_NOINLINE
#endif

static MACSCOPE_NOINLINE uint64_t macscope_effective_even(uint64_t value) {
    return (value * UINT64_C(3)) + UINT64_C(0x11);
}
static MACSCOPE_NOINLINE uint64_t macscope_effective_odd(uint64_t value) {
    return (value ^ UINT64_C(0x5a5a)) + UINT64_C(0x29);
}

// The provider harness patches a branch or call in this function's effective
// byte view while retaining the original raw bytes as provenance.
MACSCOPE_EXPORT uint64_t macscope_fixture_effective_bytes(uint64_t value) {
    uint64_t selected;
    if ((value & UINT64_C(1)) == 0) {
        selected = macscope_effective_even(value);
    } else {
        selected = macscope_effective_odd(value);
    }
    return selected ^ UINT64_C(0x1357);
}
