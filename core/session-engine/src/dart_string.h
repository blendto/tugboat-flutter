// Dart `String` operations on WTF-8 text (json.h), where the evidence
// messages need Dart's exact lengths and cuts. Dart strings are UTF-16, so
// `length` counts code units and a cut can leave a lone surrogate, which
// WTF-8 keeps. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_DART_STRING_H
#define TUGBOAT_SESSION_ENGINE_DART_STRING_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace tugboat {
namespace engine {

// Dart `String.length`: UTF-16 code units (a code point above U+FFFF is 2).
size_t utf16_length(std::string_view wtf8);

// Whether `utf16_length(wtf8) > units`, reading at most `units + 1` code
// points.
bool utf16_longer_than(std::string_view wtf8, size_t units);

// Dart `substring(0, units)`. A cut inside a surrogate pair keeps the high
// surrogate as a lone surrogate.
std::string utf16_prefix(std::string_view wtf8, size_t units);

// Dart `String.trim()`: strips Dart's whitespace code points (U+0009–U+000D,
// U+0020, U+0085, U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F,
// U+205F, U+3000, U+FEFF) from both ends.
std::string_view dart_trim(std::string_view wtf8);

// The longest prefix of whole code points within `max_bytes` bytes. WTF-8
// bytes equal Dart's `utf8.encode` length (a lone surrogate is 3 either way),
// so this is Dart's rune-by-rune bounded prefix.
std::string_view utf8_prefix(std::string_view wtf8, size_t max_bytes);

// Decodes the code point at `*i` (a lone surrogate decodes to itself) and
// advances `*i` past it.
uint32_t wtf8_next(std::string_view wtf8, size_t* i);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_DART_STRING_H
