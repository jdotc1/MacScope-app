// SPDX-License-Identifier: GPL-2.0-only
// Narrow adaptation of the IHDR record/enums in WerWolv/ImHex-Patterns,
// patterns/png.hexpat at e07e98adc810f0c052035ee1fdabae7ec65110e2.
// Upstream notice/license and exact source are in pattern_context.
// The adapter accepts this flattened, self-contained prefix only.
// This interprets 33 bytes; it does not validate PNG CRCs or decode an image.
enum PNGColorType : u8 {
    Grayscale = 0,
    RGBTriple = 2,
    Palette = 3,
    GrayscaleAlpha = 4,
    RGBA = 6
};
enum PNGInterlacing : u8 {
    None = 0,
    Adam7 = 1
};
struct IHDR {
    be u32 width;
    be u32 height;
    u8 bit_depth;
    PNGColorType color_type;
    u8 compression_method;
    u8 filter_method;
    PNGInterlacing interlacing;
};
struct PNGPrefix {
    u8 signature[8];
    be u32 length;
    u8 chunk_type[4];
    IHDR ihdr;
    be u32 crc;
};
PNGPrefix png @ 0;

