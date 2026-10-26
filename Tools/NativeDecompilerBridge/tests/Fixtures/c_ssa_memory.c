#include <stdint.h>

#if defined(__clang__)
#define MACSCOPE_EXPORT __attribute__((visibility("default"), noinline, used))
#define MACSCOPE_NOINLINE __attribute__((noinline))
#else
#define MACSCOPE_EXPORT
#define MACSCOPE_NOINLINE
#endif

volatile uint64_t macscope_fixture_global_word = UINT64_C(0x1122334455667788);

static MACSCOPE_NOINLINE uint64_t macscope_phi_left(uint64_t value) {
    return value + UINT64_C(0x101);
}
static MACSCOPE_NOINLINE uint64_t macscope_phi_right(uint64_t value) {
    return value ^ UINT64_C(0x202);
}

MACSCOPE_EXPORT uint64_t macscope_fixture_register_widths(uint32_t narrow, uint64_t wide) {
    const uint32_t narrow_result = narrow + UINT32_C(0x17);
    const uint64_t wide_result = wide + UINT64_C(0x1f1f1f1f);
    return ((uint64_t)narrow_result << 32) ^ wide_result;
}

MACSCOPE_EXPORT uint64_t macscope_fixture_zero_register(uint64_t value) {
    return value & UINT64_C(0);
}

MACSCOPE_EXPORT uint64_t macscope_fixture_join_phi(int32_t selector, uint64_t value) {
    uint64_t joined;
    if (selector < 0) {
        joined = macscope_phi_left(value);
    } else {
        joined = macscope_phi_right(value);
    }
    return (joined << 1) | UINT64_C(1);
}

MACSCOPE_EXPORT uint64_t macscope_fixture_stack_local(uint64_t first, uint64_t second) {
    volatile uint64_t words[3];
    words[0] = first;
    words[1] = second;
    words[2] = words[0] ^ words[1];
    return words[2] + words[0];
}

MACSCOPE_EXPORT uint64_t macscope_fixture_global_access(uint64_t replacement) {
    const uint64_t previous = macscope_fixture_global_word;
    macscope_fixture_global_word = replacement;
    return previous ^ macscope_fixture_global_word;
}

MACSCOPE_EXPORT uint64_t macscope_fixture_memory_alias(
    uint64_t *first,
    uint64_t *second,
    uint64_t value
) {
    *first = value;
    *second = value + UINT64_C(1);
    return *first;
}
