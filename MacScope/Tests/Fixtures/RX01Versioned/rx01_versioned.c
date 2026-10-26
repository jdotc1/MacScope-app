/*
 * RX-01 two-version fixture source (v1 by default, v2 with -DRX01_V2).
 *
 * Built by Scripts/version-matching/generate_rx01_versioned_fixture.py into the binaries and
 * manifest beside this file. Every function except the two helpers is a distinct, non-inlined,
 * exported definition, so the named build keeps one symbol per function; the helpers are static
 * (local symbols) so the linker may fold them in the merged variant. The bodies are chosen so each
 * pair exercises one matcher phase. The expected pairing per variant is asserted in
 * MacScope/Tests/CoreTests/AnnotationTransferRealBinaryTests.swift.
 */
#include <stddef.h>
#include <stdint.h>

#define RX01_KEEP __attribute__((noinline, used, visibility("default")))
#ifndef RX01_LEAF_ATTR
#define RX01_LEAF_ATTR RX01_KEEP
#endif

volatile uint32_t rx01_sink;

#ifdef RX01_V2
/* New in v2. Defined first so every v1 function moves to a new address. */
RX01_KEEP uint32_t added_fn(const uint8_t *bytes, size_t count) {
    uint32_t hash = 0x811c9dc5u;
    for (size_t index = 0; index < count; index++) {
        hash ^= bytes[index];
        hash *= 0x01000193u;
    }
    return hash;
}
#endif

/* Called only from parse_header. v2 changes its body but keeps a single block. */
RX01_LEAF_ATTR uint32_t leaf_called_once(uint32_t value) {
#ifdef RX01_V2
    return (value ^ 0x5au) * 7u + 3u;
#else
    return value * 5u + 1u;
#endif
}

/* Identical in both versions; moves in v2. */
RX01_KEEP int parse_header(const uint8_t *bytes, size_t count) {
    if (count < 4 || bytes[0] != 0x7f) {
        return -1;
    }
    uint32_t total = 0;
    for (size_t index = 1; index < count; index++) {
        total += bytes[index];
    }
    rx01_sink = leaf_called_once(total);
    return (int)(total & 0xffu);
}

/* v2 changes one constant only. */
RX01_KEEP uint32_t checksum(const uint8_t *bytes, size_t count) {
    uint32_t sum = 0;
    for (size_t index = 0; index < count; index++) {
#ifdef RX01_V2
        sum = (sum << 5) + sum + bytes[index] + 0x1du;
#else
        sum = (sum << 5) + sum + bytes[index] + 0x11u;
#endif
    }
    return sum;
}

/* Same body in both versions; only the exported name changes. */
#ifdef RX01_V2
RX01_KEEP int64_t new_name(int64_t left, int64_t right) {
#else
RX01_KEEP int64_t old_name(int64_t left, int64_t right) {
#endif
    int64_t product = left * right;
    if (product < 0) {
        product = -product;
    }
    return product % 1009;
}

/* Two identical tiny bodies: identical-code-folding candidates (folded by -Wl,-deduplicate). */
#ifndef RX01_HELPER_ATTR
#define RX01_HELPER_ATTR static __attribute__((noinline))
#endif
RX01_HELPER_ATTR uint32_t helper_a(uint32_t value) { return (value << 3) ^ 0x9e3779b9u; }
RX01_HELPER_ATTR uint32_t helper_b(uint32_t value) { return (value << 3) ^ 0x9e3779b9u; }

#ifndef RX01_V2
/* Present only in v1. */
RX01_KEEP uint64_t removed_fn(uint64_t value) {
    uint64_t result = 1;
    while (value > 1) {
        result *= value--;
        if (result > 0xffffffffull) {
            break;
        }
    }
    return result;
}
#endif

int main(int argc, char **argv) {
    const uint8_t *bytes = (const uint8_t *)argv[0];
    size_t count = (size_t)argc;
    int status = parse_header(bytes, count);
    status += (int)checksum(bytes, count);
#ifdef RX01_V2
    status += (int)new_name(argc, 3);
    status += (int)added_fn(bytes, count);
#else
    status += (int)old_name(argc, 3);
    status += (int)removed_fn((uint64_t)argc);
#endif
    status += (int)(helper_a((uint32_t)argc) + helper_b((uint32_t)status));
    return status & 0x7f;
}
