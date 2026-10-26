#include <stdint.h>
#include <stdio.h>

typedef struct LargeAggregate {
    uint64_t first;
    uint64_t second;
    uint64_t third;
} LargeAggregate;

volatile int32_t mixed_w0;
volatile double mixed_d0;
volatile float mixed_s1;
volatile uintptr_t mixed_x1;

volatile double collision_d0;
volatile uintptr_t collision_x0;

volatile uint64_t ninth_stack0;
volatile uintptr_t ninth_x8_observation;
volatile uint8_t chars_stack0;
volatile uint8_t chars_stack1;

volatile uint8_t shared_stack0;
volatile double shared_stack8;
volatile uint8_t shared_stack16;
volatile double shared_d0;

volatile double independent_stack0;
volatile int32_t independent_w0;
volatile double independent_stack8;
volatile uintptr_t independent_x1;

volatile uint32_t returned_w0;
volatile uint64_t returned_x0;
volatile float returned_s0;
volatile double returned_d0;

volatile uintptr_t large_hidden_x8;
volatile uint64_t large_formal_x0;

extern void capture_mixed(
    int integer_value,
    double double_value,
    float float_value,
    void *pointer_value
);
extern void capture_bank_collision(double floating_value, void *pointer_value);
extern void capture_ninth_integer(
    uint64_t i0, uint64_t i1, uint64_t i2, uint64_t i3, uint64_t i4,
    uint64_t i5, uint64_t i6, uint64_t i7, uint64_t i8
);
extern void capture_packed_chars(
    char c0, char c1, char c2, char c3, char c4,
    char c5, char c6, char c7, char c8, char c9
);
extern void capture_shared_nsaa(
    char c0, char c1, char c2, char c3, char c4,
    char c5, char c6, char c7, char c8,
    double d0, double d1, double d2, double d3, double d4,
    double d5, double d6, double d7, double d8,
    char tail
);
extern void capture_scalar_returns(void);
extern LargeAggregate capture_large_return(uint64_t marker);
extern void capture_independent_bank_spill(
    double d0, double d1, double d2, double d3, double d4,
    double d5, double d6, double d7, double d8,
    int integer_value, double d9, void *pointer_value
);

__attribute__((noinline)) void mixed_scalars(
    int integer_value,
    double double_value,
    float float_value,
    void *pointer_value
) {
    capture_mixed(integer_value, double_value, float_value, pointer_value);
}

__attribute__((noinline)) void bank_collision(double floating_value, void *pointer_value) {
    capture_bank_collision(floating_value, pointer_value);
}

__attribute__((noinline)) void ninth_integer(
    uint64_t i0, uint64_t i1, uint64_t i2, uint64_t i3, uint64_t i4,
    uint64_t i5, uint64_t i6, uint64_t i7, uint64_t i8
) {
    capture_ninth_integer(i0, i1, i2, i3, i4, i5, i6, i7, i8);
}

__attribute__((noinline)) void packed_chars(
    char c0, char c1, char c2, char c3, char c4,
    char c5, char c6, char c7, char c8, char c9
) {
    capture_packed_chars(c0, c1, c2, c3, c4, c5, c6, c7, c8, c9);
}

__attribute__((noinline)) void shared_nsaa(
    char c0, char c1, char c2, char c3, char c4,
    char c5, char c6, char c7, char c8,
    double d0, double d1, double d2, double d3, double d4,
    double d5, double d6, double d7, double d8,
    char tail
) {
    capture_shared_nsaa(
        c0, c1, c2, c3, c4, c5, c6, c7, c8,
        d0, d1, d2, d3, d4, d5, d6, d7, d8, tail
    );
}

__attribute__((noinline)) void independent_bank_spill(
    double d0, double d1, double d2, double d3, double d4,
    double d5, double d6, double d7, double d8,
    int integer_value, double d9, void *pointer_value
) {
    capture_independent_bank_spill(
        d0, d1, d2, d3, d4, d5, d6, d7, d8,
        integer_value, d9, pointer_value
    );
}

__attribute__((noinline)) uint32_t return_w0(void) {
    return UINT32_C(0xa1b2c3d4);
}

__attribute__((noinline)) uint64_t return_x0(void) {
    return UINT64_C(0x1122334455667788);
}

__attribute__((noinline)) float return_s0(void) {
    return -6.25f;
}

__attribute__((noinline)) double return_d0(void) {
    return 19.5;
}

__attribute__((noinline)) LargeAggregate invoke_large_return(uint64_t marker) {
    return capture_large_return(marker);
}

static int verify_entry_parameters(void) {
    uint64_t pointer_storage = UINT64_C(0xfeedfacecafebeef);
    void *pointer = &pointer_storage;

    mixed_scalars(-1234567, 19.5, -6.25f, pointer);
    if (mixed_w0 != -1234567 || mixed_d0 != 19.5 || mixed_s1 != -6.25f
        || mixed_x1 != (uintptr_t)pointer) {
        return 11;
    }

    bank_collision(-41.25, pointer);
    if (collision_d0 != -41.25 || collision_x0 != (uintptr_t)pointer) {
        return 12;
    }

    ninth_integer(1, 2, 3, 4, 5, 6, 7, 8, UINT64_C(0x9091929394959697));
    // x8 is caller-saved scratch and is allowed to coincidentally hold the same
    // bits. The proof is that the callee reads the ninth formal from entry SP;
    // treating an observed x8 value as a formal would be the bug under test.
    if (ninth_stack0 != UINT64_C(0x9091929394959697)) {
        return 13;
    }

    packed_chars(1, 2, 3, 4, 5, 6, 7, 8, 0x51, 0x62);
    if (chars_stack0 != 0x51 || chars_stack1 != 0x62) {
        return 14;
    }

    shared_nsaa(
        1, 2, 3, 4, 5, 6, 7, 8, 0x35,
        10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 91.5,
        0x46
    );
    if (shared_stack0 != 0x35 || shared_d0 != 10.0
        || shared_stack8 != 91.5 || shared_stack16 != 0x46) {
        return 15;
    }

    independent_bank_spill(
        20.0, 21.0, 22.0, 23.0, 24.0, 25.0, 26.0, 27.0, 101.5,
        -7654321, -202.25, pointer
    );
    if (independent_stack0 != 101.5 || independent_w0 != -7654321
        || independent_stack8 != -202.25 || independent_x1 != (uintptr_t)pointer) {
        return 16;
    }

    return 0;
}

static int verify_returns_and_hidden_channel(void) {
    capture_scalar_returns();
    if (returned_w0 != UINT32_C(0xa1b2c3d4)
        || returned_x0 != UINT64_C(0x1122334455667788)
        || returned_s0 != -6.25f || returned_d0 != 19.5) {
        return 21;
    }

    const uint64_t marker = UINT64_C(0x7172737475767778);
    LargeAggregate aggregate = invoke_large_return(marker);
    if (large_hidden_x8 == 0 || large_formal_x0 != marker
        || aggregate.first != marker
        || aggregate.second != UINT64_C(0x2222)
        || aggregate.third != UINT64_C(0x3333)) {
        return 22;
    }
    return 0;
}

int main(void) {
    int status = verify_entry_parameters();
    if (status != 0) {
        return status;
    }
    status = verify_returns_and_hidden_channel();
    if (status != 0) {
        return status;
    }
    puts("parameter-binding-sentinels-ok");
    return 0;
}
