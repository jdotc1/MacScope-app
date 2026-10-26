// MacScope parser-engine bridge (RX-03).
//
// A small C ABI over the vendored, natively built LIEF, pe-parse and go-macho
// engines. The analysis worker calls these functions with the exact captured
// image bytes (never a path), and receives a bounded JSON document of raw
// parse facts that MacScope normalizes and compares with its own loaders.
// The engines are cross-check evidence only; they never become image,
// address or byte authority.
#ifndef MACSCOPE_PARSER_ENGINES_H
#define MACSCOPE_PARSER_ENGINES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Each function parses `length` bytes at `bytes` in memory and returns a
/// NUL-terminated UTF-8 JSON document allocated with malloc. A rejected or
/// malformed input yields {"status":"rejected",...}; NULL means only that the
/// document could not be allocated. Release every result with
/// macscope_parser_engines_free. All functions are safe to call concurrently.
char *macscope_lief_macho_facts(const uint8_t *bytes, size_t length);
char *macscope_lief_pe_facts(const uint8_t *bytes, size_t length);
char *macscope_peparse_pe_facts(const uint8_t *bytes, size_t length);
char *macscope_gomacho_macho_facts(const uint8_t *bytes, size_t length);
/// Developer-only ObjC/Swift inventory of one thin Mach-O; 64 MiB input, 8 MiB JSON.
/// Invoke in a subprocess with a wall-time deadline; readers are synchronous.
char *macscope_gomacho_type_inventory(const uint8_t *bytes, size_t length);
/// Compiler-recorded Go function metadata; isolated worker only; 16 MiB JSON.
/// Zero text headers require embedded go1.27.1/go1.27.2 and explicit provenance.
char *macscope_gomacho_go_functions(const uint8_t *bytes, size_t length);
void macscope_parser_engines_free(char *document);

/// Static JSON naming each linked engine's pinned version and revision.
const char *macscope_parser_engines_identity(void);

#ifdef __cplusplus
}
#endif

#endif
