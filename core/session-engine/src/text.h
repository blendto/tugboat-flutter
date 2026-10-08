// Hashing and Dart-string helpers. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_TEXT_H
#define TUGBOAT_SESSION_ENGINE_TEXT_H

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

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

// Dart `tugboatLabelHash`: first 16 hex chars of SHA-256 over the UTF-8
// bytes, or "" for "".
std::string label_hash(std::string_view wtf8);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_TEXT_H
