// LIEF engine adapter: raw Mach-O and PE facts as bounded JSON.
#include "MacScopeParserEngines.h"
#include "JSONWriter.hpp"

#include <LIEF/MachO.hpp>
#include <LIEF/PE.hpp>

#include <exception>
#include <memory>
#include <vector>

using namespace macscope_parser_engines;

namespace {

constexpr size_t kMaximumInputBytes = size_t(1) << 31;

template <typename E>
uint64_t Raw(E value) {
  return static_cast<uint64_t>(value);
}

void AppendMachOSlice(std::string &out, const LIEF::MachO::Binary &binary) {
  const auto &header = binary.header();
  out.push_back('{');
  AppendKey(out, "cputype");
  AppendNumber(out, static_cast<uint32_t>(static_cast<int32_t>(header.cpu_type())));
  AppendKey(out, "cpusubtype");
  AppendNumber(out, header.cpu_subtype());
  AppendKey(out, "filetype");
  AppendNumber(out, Raw(header.file_type()));
  AppendKey(out, "ncmds");
  AppendNumber(out, header.nb_cmds());
  AppendKey(out, "sizeofcmds");
  AppendNumber(out, header.sizeof_cmds());
  AppendKey(out, "flags");
  AppendNumber(out, header.flags());
  AppendKey(out, "fat_offset");
  AppendNumber(out, binary.fat_offset());

  AppendKey(out, "commands");
  out.push_back('[');
  std::string id_dylib;
  bool has_id_dylib = false;
  std::vector<std::string> dylibs;
  for (const LIEF::MachO::LoadCommand &command : binary.commands()) {
    Separate(out);
    const uint64_t type = Raw(command.command());
    AppendNumber(out, type);
    if (const auto *dylib = command.cast<LIEF::MachO::DylibCommand>()) {
      if (type == 0xD) {
        id_dylib = dylib->name();
        has_id_dylib = true;
      } else if (type == 0xC || type == 0x80000018 || type == 0x8000001F) {
        dylibs.push_back(dylib->name());
      }
    }
  }
  out.push_back(']');

  AppendKey(out, "segments");
  out.push_back('[');
  for (const LIEF::MachO::SegmentCommand &segment : binary.segments()) {
    Separate(out);
    out.push_back('{');
    AppendKey(out, "name");
    AppendString(out, segment.name());
    AppendKey(out, "vmaddr");
    AppendNumber(out, segment.virtual_address());
    AppendKey(out, "vmsize");
    AppendNumber(out, segment.virtual_size());
    AppendKey(out, "fileoff");
    AppendNumber(out, segment.file_offset());
    AppendKey(out, "filesize");
    AppendNumber(out, segment.file_size());
    AppendKey(out, "maxprot");
    AppendNumber(out, segment.max_protection());
    AppendKey(out, "initprot");
    AppendNumber(out, segment.init_protection());
    AppendKey(out, "sections");
    out.push_back('[');
    for (const LIEF::MachO::Section &section : segment.sections()) {
      Separate(out);
      out.push_back('{');
      AppendKey(out, "name");
      AppendString(out, section.name());
      AppendKey(out, "segment");
      AppendString(out, section.segment_name());
      AppendKey(out, "addr");
      AppendNumber(out, section.virtual_address());
      AppendKey(out, "size");
      AppendNumber(out, section.size());
      AppendKey(out, "offset");
      AppendNumber(out, section.offset());
      out.push_back('}');
    }
    out += "]}";
  }
  out.push_back(']');

  AppendKey(out, "uuid");
  if (const auto *uuid = binary.uuid()) {
    std::string hex;
    static const char digits[] = "0123456789abcdef";
    for (uint8_t byte : uuid->uuid()) {
      hex.push_back(digits[byte >> 4]);
      hex.push_back(digits[byte & 0xF]);
    }
    AppendString(out, hex);
  } else {
    out += "null";
  }
  AppendKey(out, "dylibs");
  out.push_back('[');
  for (const auto &name : dylibs) {
    Separate(out);
    AppendString(out, name);
  }
  out.push_back(']');
  AppendKey(out, "id_dylib");
  if (has_id_dylib) AppendString(out, id_dylib); else out += "null";
  AppendKey(out, "entry_offset");
  if (const auto *main = binary.main_command()) AppendNumber(out, main->entrypoint()); else out += "null";
  AppendKey(out, "build_version");
  if (const auto *build = binary.build_version()) {
    out.push_back('{');
    AppendKey(out, "platform");
    AppendNumber(out, Raw(build->platform()));
    AppendKey(out, "minos");
    out.push_back('[');
    for (uint32_t part : build->minos()) { Separate(out); AppendNumber(out, part); }
    out.push_back(']');
    AppendKey(out, "sdk");
    out.push_back('[');
    for (uint32_t part : build->sdk()) { Separate(out); AppendNumber(out, part); }
    out += "]}";
  } else {
    out += "null";
  }
  out.push_back('}');
}

}  // namespace

extern "C" char *macscope_lief_macho_facts(const uint8_t *bytes, size_t length) {
  if (bytes == nullptr || length == 0 || length > kMaximumInputBytes) return Rejected("input is empty or exceeds the bound");
  try {
    std::vector<uint8_t> data(bytes, bytes + length);
    std::unique_ptr<LIEF::MachO::FatBinary> fat =
        LIEF::MachO::Parser::parse(data, LIEF::MachO::ParserConfig::quick());
    if (!fat || fat->size() == 0) return Rejected("LIEF returned no binary");
    std::string out = "{";
    AppendKey(out, "status");
    AppendString(out, "parsed");
    AppendKey(out, "slices");
    out.push_back('[');
    for (size_t index = 0; index < fat->size(); ++index) {
      const LIEF::MachO::Binary *binary = fat->at(index);
      if (binary == nullptr) continue;
      Separate(out);
      AppendMachOSlice(out, *binary);
    }
    out += "]}";
    return Detach(out);
  } catch (const std::exception &) {
    return Rejected("LIEF raised an exception");
  } catch (...) {
    return Rejected("LIEF raised an exception");
  }
}

extern "C" char *macscope_lief_pe_facts(const uint8_t *bytes, size_t length) {
  if (bytes == nullptr || length == 0 || length > kMaximumInputBytes) return Rejected("input is empty or exceeds the bound");
  try {
    std::unique_ptr<LIEF::PE::Binary> binary = LIEF::PE::Parser::parse(bytes, length);
    if (!binary) return Rejected("LIEF returned no binary");
    const auto &header = binary->header();
    const auto &optional = binary->optional_header();
    const uint64_t image_base = optional.imagebase();
    std::string out = "{";
    AppendKey(out, "status");
    AppendString(out, "parsed");
    AppendKey(out, "machine");
    AppendNumber(out, Raw(header.machine()));
    AppendKey(out, "optional_magic");
    AppendNumber(out, Raw(optional.magic()));
    AppendKey(out, "number_of_sections");
    AppendNumber(out, header.numberof_sections());
    AppendKey(out, "image_base");
    AppendNumber(out, image_base);
    AppendKey(out, "entry_point_va");
    AppendNumber(out, image_base + optional.addressof_entrypoint());
    AppendKey(out, "sections");
    out.push_back('[');
    for (const LIEF::PE::Section &section : binary->sections()) {
      Separate(out);
      out.push_back('{');
      AppendKey(out, "name");
      AppendString(out, section.name());
      AppendKey(out, "va");
      AppendNumber(out, image_base + section.virtual_address());
      AppendKey(out, "virtual_size");
      AppendNumber(out, section.virtual_size());
      AppendKey(out, "raw_pointer");
      AppendNumber(out, section.pointerto_raw_data());
      AppendKey(out, "raw_size");
      AppendNumber(out, section.sizeof_raw_data());
      AppendKey(out, "characteristics");
      AppendNumber(out, section.characteristics());
      out.push_back('}');
    }
    out.push_back(']');
    AppendKey(out, "imports");
    out.push_back('[');
    for (const LIEF::PE::Import &import : binary->imports()) {
      for (const LIEF::PE::ImportEntry &entry : import.entries()) {
        Separate(out);
        out.push_back('{');
        AppendKey(out, "module");
        AppendString(out, import.name());
        AppendKey(out, "function");
        AppendString(out, entry.is_ordinal() ? "#" + std::to_string(entry.ordinal()) : entry.name());
        out.push_back('}');
      }
    }
    out.push_back(']');
    AppendKey(out, "exports");
    out.push_back('[');
    if (const LIEF::PE::Export *exported = binary->get_export()) {
      for (const LIEF::PE::ExportEntry &entry : exported->entries()) {
        Separate(out);
        out.push_back('{');
        AppendKey(out, "name");
        AppendString(out, entry.name());
        AppendKey(out, "ordinal");
        AppendNumber(out, entry.ordinal());
        out.push_back('}');
      }
    }
    out += "]}";
    return Detach(out);
  } catch (const std::exception &) {
    return Rejected("LIEF raised an exception");
  } catch (...) {
    return Rejected("LIEF raised an exception");
  }
}
