// Hashing and Dart-string helpers. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_TEXT_H
#define TUGBOAT_SESSION_ENGINE_TEXT_H

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace tugboat {
namespace engine {

// SHA-256 (FIPS 180-4) of `bytes`.
std::array<uint8_t, 32> sha256(std::string_view bytes);

// Lowercase hex of a SHA-256 digest.
std::string sha256_hex(std::string_view bytes);

// Dart `utf8.encode` of a WTF-8 string: lone surrogates become U+FFFD.
std::string wtf8_to_utf8(std::string_view wtf8);

// Dart `String.compareTo`: lexicographic over UTF-16 code units. Negative,
// zero, or positive.
int compare_utf16(std::string_view a, std::string_view b);

// Decodes the WTF-8 code point at `*i` (a lone surrogate decodes to itself)
// and advances `*i` past it. Malformed bytes decode as U+FFFD one byte at a
// time. The one WTF-8 decoder: json.cpp and every Dart-string helper use it.
uint32_t wtf8_next(std::string_view wtf8, size_t* i);

// Dart `String.length > units`: UTF-16 code units (a code point above
// U+FFFF is 2), reading at most `units + 1` code points.
bool utf16_longer_than(std::string_view wtf8, size_t units);

// Dart `substring(0, units)`. A cut inside a surrogate pair keeps the high
// surrogate as a lone surrogate.
std::string utf16_prefix(std::string_view wtf8, size_t units);

// Dart `String.trim()`: strips Dart's whitespace code points (U+0009-U+000D,
// U+0020, U+0085, U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F,
// U+205F, U+3000, U+FEFF) from both ends.
std::string_view dart_trim(std::string_view wtf8);

// The longest prefix of whole code points within `max_bytes` bytes. WTF-8
// bytes equal Dart's `utf8.encode` length (a lone surrogate is 3 either way),
// so this is Dart's rune-by-rune bounded prefix.
std::string_view utf8_prefix(std::string_view wtf8, size_t max_bytes);

// Dart `tugboatLabelHash`: first 16 hex chars of SHA-256 over the UTF-8
// bytes, or "" for "".
std::string label_hash(std::string_view wtf8);

// Dart `tugboatInventoryHash`: `label_hash` of the fingerprints sorted by
// UTF-16 code units (`compare_utf16`) and joined by `|`.
std::string inventory_hash_from_fingerprints(
    std::vector<std::string> fingerprints);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_TEXT_H
