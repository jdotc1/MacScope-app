/* Fixture target configuration, not an upstream generated configuration.
 * The scored target is arm64 Mach-O with the LP64 ABI and 8-bit SIMD DCTs.
 */
#pragma once
#include "simd/jsimdconst.h"
/* src/jdhuff.h:76-83 selects a 64-bit bit buffer for LP64 size_t. */
#define SIZEOF_SIZE_T 8
/* simd/jsimd.h:87 enables the ARM family declarations. ARM64 is 2 in
 * simd/jsimdconst.h:30. Accepted truth: _jsimd_h1v2_fancy_upsample,
 * start 0x580d8, declared at simd/jsimd.h:89, precision 8.
 */
#define SIMD_ARCHITECTURE ARM64
/* src/jdct.h:41-50 selects short DCTELEM for the target's SIMD build. */
#define WITH_SIMD 1
/* src/jsamplecomp.h:19,105,221 selects the 8-bit symbol/type context. */
#define BITS_IN_JSAMPLE 8
/* jpeglib.h:498 and subsequent ABI guards match public-layout.c's ABI8. */
#define JPEG_LIB_VERSION 80
