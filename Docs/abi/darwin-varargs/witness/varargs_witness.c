// Darwin variadic witness: build with Apple clang for arm64 and x86_64 (-O0,
// frame pointers on), run natively and under Rosetta. Each callee prints the
// va_list state around every va_arg, relative to its entry stack pointer
// (frame address + 16 on both targets), plus the value it read.
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { double a, b, c, d; } HFA4D;      // 32-byte HFA
typedef struct { int64_t a, b, c, d; } A32;       // 32-byte non-HFA

static uintptr_t entry_sp(void *frame) { return (uintptr_t)frame + 16; }

#if defined(__aarch64__)
#define CUR(ap) ((uintptr_t)(ap))
#define STATE(tag, ap, sp) printf("%s cursor=%lu\n", tag, (unsigned long)(CUR(ap) - (sp)))
#elif defined(__x86_64__)
struct va_tag { unsigned gp_offset, fp_offset; char *overflow_arg_area, *reg_save_area; };
#define STATE(tag, ap, sp) do { struct va_tag *t = (struct va_tag *)(ap); \
    printf("%s gp=%u fp=%u overflow=%ld\n", tag, t->gp_offset, t->fp_offset, \
           (long)((uintptr_t)t->overflow_arg_area - (sp))); } while (0)
#endif

__attribute__((noinline)) void printf_tail(const char *fmt, ...) {
    uintptr_t sp = entry_sp(__builtin_frame_address(0));
    va_list ap; va_start(ap, fmt);
    STATE("printf_tail start", ap, sp);
    int i = va_arg(ap, int);            STATE("printf_tail int", ap, sp);
    double d = va_arg(ap, double);      STATE("printf_tail double", ap, sp);
    char *s = va_arg(ap, char *);       STATE("printf_tail ptr", ap, sp);
    long double ld = va_arg(ap, long double); STATE("printf_tail longdouble", ap, sp);
    double e = va_arg(ap, double);      STATE("printf_tail double", ap, sp);
    printf("printf_tail values %d %.1f %s %.1Lf %.3f\n", i, d, s, ld, e);
    va_end(ap);
}

__attribute__((noinline)) void named_int128(void *p, __int128 a, __int128 b, __int128 c,
                                            __int128 d, __int128 e, int k, ...) {
    uintptr_t sp = entry_sp(__builtin_frame_address(0));
    va_list ap; va_start(ap, k);
    STATE("named_int128 start", ap, sp);
    int x = va_arg(ap, int);            STATE("named_int128 int", ap, sp);
    printf("named_int128 values %d %d %d\n", (int)e, k, x);
    va_end(ap); (void)p; (void)a; (void)b; (void)c; (void)d;
}

__attribute__((noinline)) void int128_tail(int n, ...) {
    uintptr_t sp = entry_sp(__builtin_frame_address(0));
    va_list ap; va_start(ap, n);
    STATE("int128_tail start", ap, sp);
    int a = va_arg(ap, int);            STATE("int128_tail int", ap, sp);
    __int128 b = va_arg(ap, __int128);  STATE("int128_tail int128", ap, sp);
    int c = va_arg(ap, int);            STATE("int128_tail int", ap, sp);
    __int128 d = va_arg(ap, __int128);  STATE("int128_tail int128", ap, sp);
    printf("int128_tail values %d %lld %d %lld\n", a, (long long)b, c, (long long)d);
    va_end(ap);
}

__attribute__((noinline)) void records(int n, ...) {
    uintptr_t sp = entry_sp(__builtin_frame_address(0));
    va_list ap; va_start(ap, n);
    STATE("records start", ap, sp);
    int a = va_arg(ap, int);            STATE("records int", ap, sp);
    A32 r = va_arg(ap, A32);            STATE("records A32", ap, sp);
    int b = va_arg(ap, int);            STATE("records int", ap, sp);
    HFA4D h = va_arg(ap, HFA4D);        STATE("records HFA4D", ap, sp);
    int c = va_arg(ap, int);            STATE("records int", ap, sp);
    printf("records values %d %lld %d %.1f %d\n", a, (long long)r.d, b, h.d, c);
    va_end(ap);
}

__attribute__((noinline)) void promotions(int n, ...) {
    uintptr_t sp = entry_sp(__builtin_frame_address(0));
    va_list ap; va_start(ap, n);
    STATE("promotions start", ap, sp);
    int a = va_arg(ap, int);            STATE("promotions int", ap, sp);
    int b = va_arg(ap, int);            STATE("promotions int", ap, sp);
    double c = va_arg(ap, double);      STATE("promotions double", ap, sp);
    unsigned d = va_arg(ap, unsigned);  STATE("promotions unsigned", ap, sp);
    printf("promotions values %d %d %.7f %u\n", a, b, c, d);
    va_end(ap);
}

__attribute__((noinline)) void five_named(long a, long b, long c, long d, long e, ...) {
    uintptr_t sp = entry_sp(__builtin_frame_address(0));
    va_list ap; va_start(ap, e);
    STATE("five_named start", ap, sp);
    __int128 x = va_arg(ap, __int128);  STATE("five_named int128", ap, sp);
    long y = va_arg(ap, long);          STATE("five_named long", ap, sp);
    __int128 z = va_arg(ap, __int128);  STATE("five_named int128", ap, sp);
    printf("five_named values %lld %ld %lld\n", (long long)x, y, (long long)z);
    va_end(ap); (void)a; (void)b; (void)c; (void)d;
}

__attribute__((noinline)) void nine_doubles(const char *f, ...) {
    uintptr_t sp = entry_sp(__builtin_frame_address(0));
    va_list ap; va_start(ap, f);
    double sum = 0;
    STATE("nine_doubles start", ap, sp);
    for (int i = 0; i < 9; i++) { sum += va_arg(ap, double); STATE("nine_doubles double", ap, sp); }
    printf("nine_doubles values %.1f\n", sum);
    va_end(ap);
}

__attribute__((noinline)) void seven_named(long a, long b, long c, long d, long e, long f, long g, ...) {
    uintptr_t sp = entry_sp(__builtin_frame_address(0));
    va_list ap; va_start(ap, g);
    STATE("seven_named start", ap, sp);
    int x = va_arg(ap, int);            STATE("seven_named int", ap, sp);
    long double y = va_arg(ap, long double); STATE("seven_named longdouble", ap, sp);
    int z = va_arg(ap, int);            STATE("seven_named int", ap, sp);
    printf("seven_named values %ld %d %.1Lf %d\n", g, x, y, z);
    va_end(ap); (void)a; (void)b; (void)c; (void)d; (void)e; (void)f;
}

__attribute__((noinline)) void named_double(double v, ...) {
    uintptr_t sp = entry_sp(__builtin_frame_address(0));
    va_list ap; va_start(ap, v);
    STATE("named_double start", ap, sp);
    int x = va_arg(ap, int);            STATE("named_double int", ap, sp);
    printf("named_double values %.1f %d\n", v, x);
    va_end(ap);
}

int main(void) {
    printf_tail("%d %f %s %Lf %.3lf", 7, 2.5, "s", (long double)4.5, 1.125);
    named_int128(0, 1, 2, 3, 4, 5, 6, 7);
    int128_tail(0, 11, (__int128)12, 13, (__int128)14);
    A32 r = {1, 2, 3, 40}; HFA4D h = {1, 2, 3, 4.5};
    records(0, 21, r, 22, h, 23);
    promotions(0, (signed char)-128, (unsigned short)65535, 1.1f, 4294967295u);
    five_named(1, 2, 3, 4, 5, (__int128)31, 32L, (__int128)33);
    nine_doubles("f", 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0);
    seven_named(1, 2, 3, 4, 5, 6, 77, 41, (long double)42.5, 43);
    named_double(1.5, 9);
    return 0;
}
