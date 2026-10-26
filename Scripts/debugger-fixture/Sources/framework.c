#include <stdint.h>

__attribute__((used, visibility("default")))
volatile uint64_t macscope_fixture_framework_counter = 0;

__attribute__((noinline, used, visibility("default")))
uint64_t macscope_fixture_framework_checkpoint(void) {
    return ++macscope_fixture_framework_counter;
}

__attribute__((section("__MACSCOPE,__probe"), used, visibility("default")))
const uint64_t macscope_fixture_preferred_probe = UINT64_C(0x4d414353434f5045);
