#include <stdint.h>

#if defined(__clang__)
#define MACSCOPE_EXPORT __attribute__((visibility("default"), noinline, used))
#define MACSCOPE_NOINLINE __attribute__((noinline))
#else
#define MACSCOPE_EXPORT
#define MACSCOPE_NOINLINE
#endif

static MACSCOPE_NOINLINE int64_t macscope_control_mix(int64_t value, int64_t salt) {
    return (value * INT64_C(3)) ^ salt;
}
MACSCOPE_EXPORT int64_t macscope_fixture_straight_line(int64_t value) {
    const int64_t incremented = value + INT64_C(7);
    const int64_t shifted = incremented << 2;
    return shifted ^ INT64_C(0x55);
}

MACSCOPE_EXPORT int64_t macscope_fixture_conditional(int64_t value) {
    int64_t result;
    if (value < 0) {
        result = macscope_control_mix(value, INT64_C(0x31));
    } else {
        result = macscope_control_mix(value, INT64_C(0x73));
    }
    return result + INT64_C(5);
}

MACSCOPE_EXPORT uint64_t macscope_fixture_loop(uint32_t count, uint64_t seed) {
    uint64_t accumulator = seed;
    for (uint32_t index = 0; index < count; ++index) {
        accumulator = (accumulator ^ (uint64_t)index) + UINT64_C(0x9d);
    }
    return accumulator;
}

static MACSCOPE_NOINLINE int64_t macscope_case_0(int64_t value) { return value + INT64_C(0x10); }
static MACSCOPE_NOINLINE int64_t macscope_case_1(int64_t value) { return value ^ INT64_C(0x21); }
static MACSCOPE_NOINLINE int64_t macscope_case_2(int64_t value) { return value - INT64_C(0x32); }
static MACSCOPE_NOINLINE int64_t macscope_case_3(int64_t value) { return value * INT64_C(3); }
static MACSCOPE_NOINLINE int64_t macscope_case_4(int64_t value) { return value + INT64_C(0x54); }
static MACSCOPE_NOINLINE int64_t macscope_case_5(int64_t value) { return value ^ INT64_C(0x65); }
static MACSCOPE_NOINLINE int64_t macscope_case_6(int64_t value) { return value - INT64_C(0x76); }
static MACSCOPE_NOINLINE int64_t macscope_case_7(int64_t value) { return value * INT64_C(7); }

MACSCOPE_EXPORT int64_t macscope_fixture_switch(uint32_t selector, int64_t value) {
    int64_t result;
    switch (selector) {
        case 0: result = macscope_case_0(value); break;
        case 1: result = macscope_case_1(value); break;
        case 2: result = macscope_case_2(value); break;
        case 3: result = macscope_case_3(value); break;
        case 4: result = macscope_case_4(value); break;
        case 5: result = macscope_case_5(value); break;
        case 6: result = macscope_case_6(value); break;
        case 7: result = macscope_case_7(value); break;
        default: result = macscope_control_mix(value, INT64_C(0x7f)); break;
    }
    return result + INT64_C(1);
}
