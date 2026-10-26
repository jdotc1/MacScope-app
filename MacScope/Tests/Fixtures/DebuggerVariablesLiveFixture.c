#include <stdint.h>

struct MacScopeVariablePair {
    int32_t first;
    int32_t second;
};

__attribute__((noinline)) static void macscope_variables_live_stop(void) {
    __asm__ volatile("" ::: "memory");
}

__attribute__((noinline)) static int macscope_variables_live_checkpoint(int argument) {
    volatile int scalar_local = argument + 5;
    volatile struct MacScopeVariablePair aggregate_local = {
        .first = argument,
        .second = argument * 3,
    };
    static volatile int static_local = 91;

    macscope_variables_live_stop();
    return scalar_local + aggregate_local.first + aggregate_local.second + static_local;
}

__attribute__((noinline)) static void macscope_variables_empty_static_stop(void) {
    __asm__ volatile("" ::: "memory");
}

__attribute__((noinline)) static int macscope_variables_empty_static_checkpoint(int argument) {
    volatile struct MacScopeVariablePair aggregate_local = {
        .first = argument,
        .second = argument * 3,
    };

    macscope_variables_empty_static_stop();
    return aggregate_local.first + aggregate_local.second;
}

int main(int argc, char **argv) {
    if (argc > 1 && argv[1][0] == 'e') {
        return macscope_variables_empty_static_checkpoint(7) == 28 ? 0 : 1;
    }
    return macscope_variables_live_checkpoint(argc > 1 ? 7 : 1) == 131 ? 0 : 1;
}
