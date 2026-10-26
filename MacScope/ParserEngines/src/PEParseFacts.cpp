// pe-parse engine adapter: raw PE facts as bounded JSON.
//
// pe-parse keeps its last error in process-global state, so every parse is
// serialized behind one mutex. The input is copied into a private buffer that
// outlives the parsed_pe object (pe-parse does not copy pointer inputs).
#include "MacScopeParserEngines.h"
#include "JSONWriter.hpp"

#include <pe-parse/parse.h>

#include <exception>
#include <mutex>
#include <vector>

using namespace macscope_parser_engines;

namespace {

std::mutex &EngineMutex() {
  static std::mutex mutex;
  return mutex;
}

struct Accumulator {
  std::string items;
};

int OnSection(void *context, const peparse::VA &base, const std::string &name,
              const peparse::image_section_header &header, const peparse::bounded_buffer *) {
  auto &out = static_cast<Accumulator *>(context)->items;
  Separate(out);
  out.push_back('{');
  AppendKey(out, "name");
  AppendString(out, name);
  AppendKey(out, "va");
  AppendNumber(out, base);
  AppendKey(out, "virtual_size");
  AppendNumber(out, header.Misc.VirtualSize);
  AppendKey(out, "raw_pointer");
  AppendNumber(out, header.PointerToRawData);
  AppendKey(out, "raw_size");
  AppendNumber(out, header.SizeOfRawData);
  AppendKey(out, "characteristics");
  AppendNumber(out, header.Characteristics);
  out.push_back('}');
  return 0;
}

int OnImport(void *context, const peparse::VA &, const std::string &module, const std::string &function) {
  auto &out = static_cast<Accumulator *>(context)->items;
  Separate(out);
  out.push_back('{');
  AppendKey(out, "module");
  AppendString(out, module);
  AppendKey(out, "function");
  AppendString(out, function);
  out.push_back('}');
  return 0;
}

int OnExport(void *context, const peparse::VA &, std::uint16_t ordinal, const std::string &,
             const std::string &function, const std::string &) {
  auto &out = static_cast<Accumulator *>(context)->items;
  Separate(out);
  out.push_back('{');
  AppendKey(out, "name");
  AppendString(out, function);
  AppendKey(out, "ordinal");
  AppendNumber(out, ordinal);
  out.push_back('}');
  return 0;
}

}  // namespace

extern "C" char *macscope_peparse_pe_facts(const uint8_t *bytes, size_t length) {
  if (bytes == nullptr || length == 0 || length > UINT32_MAX) return Rejected("input is empty or exceeds the bound");
  try {
    std::lock_guard<std::mutex> guard(EngineMutex());
    std::vector<uint8_t> copy(bytes, bytes + length);
    peparse::parsed_pe *pe = peparse::ParsePEFromPointer(copy.data(), static_cast<std::uint32_t>(copy.size()));
    if (pe == nullptr) return Rejected(peparse::GetPEErrString().c_str());
    const auto &nt = pe->peHeader.nt;
    const bool is64 = nt.OptionalMagic == peparse::NT_OPTIONAL_64_MAGIC;
    peparse::VA entry = 0;
    const bool has_entry = peparse::GetEntryPoint(pe, entry);
    Accumulator sections, imports, exports;
    peparse::IterSec(pe, OnSection, &sections);
    peparse::IterImpVAString(pe, OnImport, &imports);
    peparse::IterExpFull(pe, OnExport, &exports);
    std::string out = "{";
    AppendKey(out, "status");
    AppendString(out, "parsed");
    AppendKey(out, "machine");
    AppendNumber(out, nt.FileHeader.Machine);
    AppendKey(out, "optional_magic");
    AppendNumber(out, nt.OptionalMagic);
    AppendKey(out, "number_of_sections");
    AppendNumber(out, nt.FileHeader.NumberOfSections);
    AppendKey(out, "image_base");
    AppendNumber(out, is64 ? nt.OptionalHeader64.ImageBase : nt.OptionalHeader.ImageBase);
    AppendKey(out, "entry_point_va");
    if (has_entry) AppendNumber(out, entry); else out += "null";
    AppendKey(out, "sections");
    out += "[" + sections.items + "]";
    AppendKey(out, "imports");
    out += "[" + imports.items + "]";
    AppendKey(out, "exports");
    out += "[" + exports.items + "]";
    out.push_back('}');
    peparse::DestructParsedPE(pe);
    return Detach(out);
  } catch (const std::exception &) {
    return Rejected("pe-parse raised an exception");
  } catch (...) {
    return Rejected("pe-parse raised an exception");
  }
}
