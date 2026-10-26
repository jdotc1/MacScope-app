#include <stdint.h>

#if defined(__clang__)
#define MACSCOPE_EXPORT __attribute__((visibility("default"), noinline, used))
#else
#define MACSCOPE_EXPORT
#endif

#define MACSCOPE_BUDGET_STEP(seed) do { \
    accumulator += UINT64_C(0x10001) + (uint64_t)(seed); \
    accumulator ^= (accumulator << 7) | (accumulator >> 57); \
    accumulator *= UINT64_C(0x100000001b3); \
} while (0)

#define MACSCOPE_BUDGET_BLOCK(base) do { \
    MACSCOPE_BUDGET_STEP((base) + 0);  MACSCOPE_BUDGET_STEP((base) + 1); \
    MACSCOPE_BUDGET_STEP((base) + 2);  MACSCOPE_BUDGET_STEP((base) + 3); \
    MACSCOPE_BUDGET_STEP((base) + 4);  MACSCOPE_BUDGET_STEP((base) + 5); \
    MACSCOPE_BUDGET_STEP((base) + 6);  MACSCOPE_BUDGET_STEP((base) + 7); \
    MACSCOPE_BUDGET_STEP((base) + 8);  MACSCOPE_BUDGET_STEP((base) + 9); \
    MACSCOPE_BUDGET_STEP((base) + 10); MACSCOPE_BUDGET_STEP((base) + 11); \
    MACSCOPE_BUDGET_STEP((base) + 12); MACSCOPE_BUDGET_STEP((base) + 13); \
    MACSCOPE_BUDGET_STEP((base) + 14); MACSCOPE_BUDGET_STEP((base) + 15); \
} while (0)

// Volatile storage prevents the compiler from collapsing the 256 source-level
// steps, yielding a bounded but deliberately operation-heavy function.
MACSCOPE_EXPORT uint64_t macscope_fixture_large_budget(uint64_t seed) {
    volatile uint64_t accumulator = seed;
    MACSCOPE_BUDGET_BLOCK(0);
    MACSCOPE_BUDGET_BLOCK(16);
    MACSCOPE_BUDGET_BLOCK(32);
    MACSCOPE_BUDGET_BLOCK(48);
    MACSCOPE_BUDGET_BLOCK(64);
    MACSCOPE_BUDGET_BLOCK(80);
    MACSCOPE_BUDGET_BLOCK(96);
    MACSCOPE_BUDGET_BLOCK(112);
    MACSCOPE_BUDGET_BLOCK(128);
    MACSCOPE_BUDGET_BLOCK(144);
    MACSCOPE_BUDGET_BLOCK(160);
    MACSCOPE_BUDGET_BLOCK(176);
    MACSCOPE_BUDGET_BLOCK(192);
    MACSCOPE_BUDGET_BLOCK(208);
    MACSCOPE_BUDGET_BLOCK(224);
    MACSCOPE_BUDGET_BLOCK(240);
    return accumulator;
}
