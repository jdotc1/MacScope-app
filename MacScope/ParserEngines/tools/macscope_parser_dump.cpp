// Developer CLI over the same bridge the analysis worker links (RX-03 goldens).
// usage: macscope-parser-dump identity
//        macscope-parser-dump <lief|pe-parse|go-macho> <macho|pe|types|go-functions> <file>
// Reads the file into memory and prints the engine's raw JSON facts. It never
// executes, maps or loads the input.
#include "MacScopeParserEngines.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <vector>

int main(int argc, char **argv) {
  if (argc == 2 && std::strcmp(argv[1], "identity") == 0) {
    std::puts(macscope_parser_engines_identity());
    return 0;
  }
  if (argc != 4) {
    std::fprintf(stderr, "usage: macscope-parser-dump <lief|pe-parse|go-macho> <macho|pe|types|go-functions> <file>\n");
    return 2;
  }
  std::ifstream stream(argv[3], std::ios::binary);
  if (!stream) {
    std::fprintf(stderr, "cannot read %s\n", argv[3]);
    return 2;
  }
  std::vector<uint8_t> bytes;
  if (std::strcmp(argv[1], "go-macho") == 0 && (std::strcmp(argv[2], "types") == 0 || std::strcmp(argv[2], "go-functions") == 0)) {
    stream.seekg(0, std::ios::end);
    const auto length = stream.tellg();
    if (length < 0 || length > 64LL * 1024 * 1024) { std::fprintf(stderr, "inventory input exceeds bound\n"); return 2; }
    stream.seekg(0, std::ios::beg);
    bytes.resize(static_cast<size_t>(length));
    stream.read(reinterpret_cast<char *>(bytes.data()), length);
    if (stream.gcount() != length || stream.peek() != std::char_traits<char>::eof()) { std::fprintf(stderr, "inventory input changed while reading\n"); return 2; }
  } else {
    bytes.assign(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>());
  }
  const bool macho = std::strcmp(argv[2], "macho") == 0;
  const bool pe = std::strcmp(argv[2], "pe") == 0;
  char *document = nullptr;
  if (std::strcmp(argv[1], "lief") == 0 && macho) document = macscope_lief_macho_facts(bytes.data(), bytes.size());
  else if (std::strcmp(argv[1], "lief") == 0 && pe) document = macscope_lief_pe_facts(bytes.data(), bytes.size());
  else if (std::strcmp(argv[1], "pe-parse") == 0 && pe) document = macscope_peparse_pe_facts(bytes.data(), bytes.size());
  else if (std::strcmp(argv[1], "go-macho") == 0 && macho) document = macscope_gomacho_macho_facts(bytes.data(), bytes.size());
  else if (std::strcmp(argv[1], "go-macho") == 0 && std::strcmp(argv[2], "types") == 0) document = macscope_gomacho_type_inventory(bytes.data(), bytes.size());
  else if (std::strcmp(argv[1], "go-macho") == 0 && std::strcmp(argv[2], "go-functions") == 0) document = macscope_gomacho_go_functions(bytes.data(), bytes.size());
  else {
    std::fprintf(stderr, "unsupported engine/format pair\n");
    return 2;
  }
  if (document == nullptr) return 1;
  std::fputs(document, stdout);
  macscope_parser_engines_free(document);
  return 0;
}
