// Minimal JSON emission for the parser-engine bridge. Strings are escaped
// byte-wise (non-ASCII as \u00XX of each byte) so hostile names can never
// produce invalid JSON; MacScope bounds and normalizes them afterwards.
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace macscope_parser_engines {

inline void AppendString(std::string &out, const std::string &value) {
  out.push_back('"');
  for (unsigned char c : value) {
    if (c == '"') {
      out += "\\\"";
    } else if (c == '\\') {
      out += "\\\\";
    } else if (c < 0x20 || c >= 0x7f) {
      char buffer[8];
      std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
      out += buffer;
    } else {
      out.push_back(static_cast<char>(c));
    }
  }
  out.push_back('"');
}

inline void AppendKey(std::string &out, const char *key) {
  if (!out.empty() && out.back() != '{' && out.back() != '[') out.push_back(',');
  AppendString(out, key);
  out.push_back(':');
}

inline void AppendNumber(std::string &out, uint64_t value) { out += std::to_string(value); }

inline void Separate(std::string &out) {
  if (!out.empty() && out.back() != '{' && out.back() != '[') out.push_back(',');
}

inline char *Detach(const std::string &document) {
  char *result = static_cast<char *>(std::malloc(document.size() + 1));
  if (result == nullptr) return nullptr;
  std::memcpy(result, document.data(), document.size());
  result[document.size()] = '\0';
  return result;
}

inline char *Rejected(const char *reason) {
  std::string out = "{";
  AppendKey(out, "status");
  AppendString(out, "rejected");
  AppendKey(out, "error");
  AppendString(out, reason);
  out.push_back('}');
  return Detach(out);
}

}  // namespace macscope_parser_engines
