#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>

#define SEC1_EXPORT __attribute__((visibility("default"), noinline, used))

static char sec1_r1_destination[16]
    __attribute__((section("__DATA,__sec1_buf"), used)) = {1};

SEC1_EXPORT int sec1_r1_positive_memcpy(const char *src, size_t n) {
    char dst[16];
    memcpy(dst, src, n);
    return dst[0];
}

SEC1_EXPORT int sec1_r1_positive_memmove(const char *src, size_t n) {
    char dst[16];
    memmove(dst, src, n);
    return dst[0];
}

SEC1_EXPORT int sec1_r1_positive_strcpy(const char *src) {
    char dst[16];
    strcpy(dst, src);
    return dst[0];
}

SEC1_EXPORT int sec1_r1_safe_constant(const char *src) {
    memcpy(sec1_r1_destination, src, 8);
    return sec1_r1_destination[0];
}

SEC1_EXPORT int sec1_r1_safe_guard(const char *src, size_t n) {
    if (n > 16) return -1;
    memcpy(sec1_r1_destination, src, n);
    return sec1_r1_destination[0];
}

SEC1_EXPORT int sec1_r1_safe_fortify(const char *src, size_t n) {
    char dst[16];
    __builtin___memcpy_chk(dst, src, n, sizeof(dst));
    return dst[0];
}

SEC1_EXPORT void *sec1_r2_positive_multiply(size_t count, size_t width) {
    void *result = malloc(count * width);
    __asm__ volatile("" : "+r"(result));
    return result;
}

SEC1_EXPORT void *sec1_r2_positive_shift(size_t count) {
    void *result = malloc(count << 4);
    __asm__ volatile("" : "+r"(result));
    return result;
}

SEC1_EXPORT void *sec1_r2_positive_aligned(size_t count, size_t width) {
    void *result = aligned_alloc(16, count * width);
    __asm__ volatile("" : "+r"(result));
    return result;
}

SEC1_EXPORT void *sec1_r2_safe_constant(void) {
    void *result = malloc(64);
    __asm__ volatile("" : "+r"(result));
    return result;
}

SEC1_EXPORT void *sec1_r2_safe_calloc(size_t count, size_t width) {
    void *result = calloc(count, width);
    __asm__ volatile("" : "+r"(result));
    return result;
}

SEC1_EXPORT void *sec1_r2_safe_checked(size_t count, size_t width) {
    size_t total;
    if (__builtin_mul_overflow(count, width, &total)) return NULL;
    void *result = malloc(total);
    __asm__ volatile("" : "+r"(result));
    return result;
}

SEC1_EXPORT int sec1_r3_positive_printf(const char *format) {
    int result = printf(format);
    __asm__ volatile("" : "+r"(result));
    return result;
}

SEC1_EXPORT int sec1_r3_positive_fprintf(const char *format) {
    int result = fprintf(stderr, format);
    __asm__ volatile("" : "+r"(result));
    return result;
}

SEC1_EXPORT int sec1_r3_positive_snprintf(const char *format) {
    char buffer[32];
    return snprintf(buffer, sizeof(buffer), format);
}

SEC1_EXPORT int sec1_r3_safe_printf(const char *text) {
    return printf("%s", text);
}

SEC1_EXPORT int sec1_r3_safe_fprintf(const char *text) {
    return fprintf(stderr, "%s", text);
}

SEC1_EXPORT int sec1_r3_safe_snprintf(const char *text) {
    char buffer[32];
    return snprintf(buffer, sizeof(buffer), "%s", text);
}

SEC1_EXPORT int sec1_r4_positive_store(size_t n) {
    unsigned char *p = malloc(n);
    p[0] = 7;
    return p[0];
}

SEC1_EXPORT int sec1_r4_positive_copy(const char *src, size_t n) {
    char *p = malloc(n);
    memcpy(p, src, n);
    return p[0];
}

SEC1_EXPORT int sec1_r4_positive_realloc(char *old, size_t n) {
    char *p = realloc(old, n);
    p[0] = 9;
    return p[0];
}

SEC1_EXPORT int sec1_r4_safe_store(size_t n) {
    unsigned char *p = malloc(n);
    if (p == NULL) return -1;
    p[0] = 7;
    return p[0];
}

SEC1_EXPORT int sec1_r4_safe_copy(const char *src, size_t n) {
    char *p = malloc(n);
    if (p == NULL) return -1;
    memcpy(p, src, n);
    return p[0];
}

SEC1_EXPORT int sec1_r4_safe_realloc(char *old, size_t n) {
    char *p = realloc(old, n);
    if (p == NULL) return -1;
    p[0] = 9;
    return p[0];
}
