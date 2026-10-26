#include <stdint.h>
#include <stdio.h>

typedef void (*FixedCapture)(uint64_t, double, const void *);
typedef void (*VariadicCapture)(uint64_t, double, ...);

volatile uint64_t fixed_direct_x0;
volatile double fixed_direct_d0;
volatile uintptr_t fixed_direct_x1;

volatile uint64_t fixed_indirect_x0;
volatile double fixed_indirect_d0;
volatile uintptr_t fixed_indirect_x1;
volatile uintptr_t fixed_indirect_x8;

volatile uint64_t variadic_direct_x0;
volatile double variadic_direct_d0;
volatile int32_t variadic_direct_stack0;
volatile double variadic_direct_stack8;
volatile uintptr_t variadic_direct_stack16;

volatile uint64_t variadic_indirect_x0;
volatile double variadic_indirect_d0;
volatile int32_t variadic_indirect_stack0;
volatile double variadic_indirect_stack8;
volatile uintptr_t variadic_indirect_stack16;
volatile uintptr_t variadic_indirect_x8;

extern void capture_fixed_direct(uint64_t, double, const void *);
extern void capture_fixed_indirect(uint64_t, double, const void *);
extern void capture_variadic_direct(uint64_t, double, ...);
extern void capture_variadic_indirect(uint64_t, double, ...);

__attribute__((noinline)) void callsite_fixed_direct(const void *pointer_value) {
    capture_fixed_direct(
        UINT64_C(0x1112131415161718),
        19.5,
        pointer_value
    );
}

__attribute__((noinline)) void callsite_fixed_indirect(
    FixedCapture target,
    const void *pointer_value
) {
    target(
        UINT64_C(0x2122232425262728),
        -41.25,
        pointer_value
    );
}

__attribute__((noinline)) void callsite_variadic_direct(const void *pointer_value) {
    const signed char promoted_integer = -91;
    const float promoted_floating = -6.25f;
    capture_variadic_direct(
        UINT64_C(0x3132333435363738),
        91.5,
        promoted_integer,
        promoted_floating,
        pointer_value
    );
}

__attribute__((noinline)) void callsite_variadic_indirect(
    VariadicCapture target,
    const void *pointer_value
) {
    const signed char promoted_integer = 73;
    const float promoted_floating = 12.75f;
    target(
        UINT64_C(0x4142434445464748),
        -202.25,
        promoted_integer,
        promoted_floating,
        pointer_value
    );
}

static int verify_fixed(const void *pointer_value) {
    callsite_fixed_direct(pointer_value);
    if (fixed_direct_x0 != UINT64_C(0x1112131415161718)
        || fixed_direct_d0 != 19.5
        || fixed_direct_x1 != (uintptr_t)pointer_value) {
        return 11;
    }

    callsite_fixed_indirect(capture_fixed_indirect, pointer_value);
    if (fixed_indirect_x0 != UINT64_C(0x2122232425262728)
        || fixed_indirect_d0 != -41.25
        || fixed_indirect_x1 != (uintptr_t)pointer_value
        || fixed_indirect_x8 != (uintptr_t)capture_fixed_indirect) {
        return 12;
    }
    return 0;
}

static int verify_variadic(const void *pointer_value) {
    callsite_variadic_direct(pointer_value);
    if (variadic_direct_x0 != UINT64_C(0x3132333435363738)
        || variadic_direct_d0 != 91.5
        || variadic_direct_stack0 != -91
        || variadic_direct_stack8 != -6.25
        || variadic_direct_stack16 != (uintptr_t)pointer_value) {
        return 21;
    }

    callsite_variadic_indirect(capture_variadic_indirect, pointer_value);
    if (variadic_indirect_x0 != UINT64_C(0x4142434445464748)
        || variadic_indirect_d0 != -202.25
        || variadic_indirect_stack0 != 73
        || variadic_indirect_stack8 != 12.75
        || variadic_indirect_stack16 != (uintptr_t)pointer_value
        || variadic_indirect_x8 != (uintptr_t)capture_variadic_indirect) {
        return 22;
    }
    return 0;
}

int main(void) {
    uint64_t pointer_storage = UINT64_C(0xfeedfacecafebeef);
    const void *pointer_value = &pointer_storage;

    int status = verify_fixed(pointer_value);
    if (status != 0) {
        return status;
    }
    status = verify_variadic(pointer_value);
    if (status != 0) {
        return status;
    }
    puts("call-argument-sentinels-ok");
    return 0;
}
