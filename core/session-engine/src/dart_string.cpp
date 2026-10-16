#include "dart_string.h"

namespace tugboat {
namespace engine {

namespace {

size_t sequence_length(unsigned char lead) {
  if (lead < 0x80) {
    return 1;
  }
  if (lead < 0xE0) {
    return 2;
  }
  return lead < 0xF0 ? 3 : 4;
}

bool is_dart_whitespace(uint32_t cp) {
  if ((cp >= 0x09 && cp <= 0x0D) || cp == 0x20 || cp == 0x85 ||
      cp == 0xA0 || cp == 0x1680 || (cp >= 0x2000 && cp <= 0x200A)) {
    return true;
  }
  return cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F ||
         cp == 0x3000 || cp == 0xFEFF;
}

// The start of the code point that ends at `end` (exclusive).
size_t previous_start(std::string_view wtf8, size_t end) {
  size_t start = end - 1;
  while (start > 0 &&
         (static_cast<unsigned char>(wtf8[start]) & 0xC0u) == 0x80u) {
    --start;
  }
  return start;
}

void append_unit(uint32_t unit, std::string* out) {
  out->push_back(static_cast<char>(0xE0 | (unit >> 12)));
  out->push_back(static_cast<char>(0x80 | ((unit >> 6) & 0x3F)));
  out->push_back(static_cast<char>(0x80 | (unit & 0x3F)));
}

}  // namespace

uint32_t wtf8_next(std::string_view wtf8, size_t* i) {
  const auto lead = static_cast<unsigned char>(wtf8[*i]);
  const size_t length = sequence_length(lead);
  uint32_t cp = length == 1   ? lead
                : length == 2 ? (lead & 0x1Fu)
                : length == 3 ? (lead & 0x0Fu)
                              : (lead & 0x07u);
  for (size_t k = 1; k < length && *i + k < wtf8.size(); ++k) {
    cp = (cp << 6) | (static_cast<unsigned char>(wtf8[*i + k]) & 0x3Fu);
  }
  *i += length;
  return cp;
}

size_t utf16_length(std::string_view wtf8) {
  size_t units = 0;
  for (const char c : wtf8) {
    const auto byte = static_cast<unsigned char>(c);
    if ((byte & 0xC0u) != 0x80u) {
      units += byte >= 0xF0 ? 2 : 1;
    }
  }
  return units;
}

bool utf16_longer_than(std::string_view wtf8, size_t units) {
  size_t counted = 0;
  size_t i = 0;
  while (i < wtf8.size()) {
    const auto lead = static_cast<unsigned char>(wtf8[i]);
    counted += lead >= 0xF0 ? 2 : 1;
    if (counted > units) {
      return true;
    }
    i += sequence_length(lead);
  }
  return false;
}

std::string utf16_prefix(std::string_view wtf8, size_t units) {
  size_t counted = 0;
  size_t i = 0;
  while (i < wtf8.size() && counted < units) {
    const auto lead = static_cast<unsigned char>(wtf8[i]);
    const size_t length = sequence_length(lead);
    if (length == 4 && counted + 1 == units) {
      // Only the high surrogate fits.
      size_t at = i;
      const uint32_t cp = wtf8_next(wtf8, &at);
      std::string out(wtf8.substr(0, i));
      append_unit(0xD800u + ((cp - 0x10000u) >> 10), &out);
      return out;
    }
    counted += length == 4 ? 2 : 1;
    i += length;
  }
  return std::string(wtf8.substr(0, i));
}

std::string_view dart_trim(std::string_view wtf8) {
  size_t start = 0;
  while (start < wtf8.size()) {
    size_t next = start;
    if (!is_dart_whitespace(wtf8_next(wtf8, &next))) {
      break;
    }
    start = next;
  }
  size_t end = wtf8.size();
  while (end > start) {
    const size_t begin = previous_start(wtf8, end);
    size_t at = begin;
    if (!is_dart_whitespace(wtf8_next(wtf8, &at))) {
      break;
    }
    end = begin;
  }
  return wtf8.substr(start, end - start);
}

std::string_view utf8_prefix(std::string_view wtf8, size_t max_bytes) {
  if (wtf8.size() <= max_bytes) {
    return wtf8;
  }
  size_t end = 0;
  while (end < wtf8.size()) {
    const size_t length = sequence_length(static_cast<unsigned char>(wtf8[end]));
    if (end + length > max_bytes) {
      break;
    }
    end += length;
  }
  return wtf8.substr(0, end);
}

}  // namespace engine
}  // namespace tugboat
