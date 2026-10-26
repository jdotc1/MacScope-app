/*
 * Repository-controlled Mach-O fixture for the native Python client suite
 * (MacScope/python/tests/test_macscope.py). It is compiled at test setup with
 * `xcrun clang -arch arm64`; expected function names and addresses are read
 * back from the built image with `nm`, never hard-coded.
 */
#include <stdlib.h>

/* Zero-initialized static storage: emitted as zero-fill (__DATA,__bss/__common). */
static volatile int macscope_fixture_zero[64];

__attribute__((noinline)) int macscope_fixture_add(int a, int b) {
    return a + b + macscope_fixture_zero[a & 63];
}

__attribute__((noinline)) int macscope_fixture_twice(int a) {
    return macscope_fixture_add(a, a) + 1;
}

int main(int argc, char **argv) {
    (void)argv;
    /* One import from libSystem so the imports table is non-empty. */
    if (getenv("MACSCOPE_FIXTURE_UNSET_VARIABLE") != NULL) {
        return 2;
    }
    return macscope_fixture_twice(argc) == 3 ? 0 : 1;
}
