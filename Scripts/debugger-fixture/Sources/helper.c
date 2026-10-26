#include "fixture_runtime.h"

#include <stdint.h>

__attribute__((used, visibility("default")))
volatile uint64_t macscope_fixture_helper_counter = 0;

__attribute__((noinline, used, visibility("default")))
uint64_t macscope_fixture_helper_checkpoint(void) {
    return ++macscope_fixture_helper_counter;
}

int main(int argc, char *argv[]) {
    return macscope_fixture_run("helper", argc, argv, macscope_fixture_helper_checkpoint);
}
