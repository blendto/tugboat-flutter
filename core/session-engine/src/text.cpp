#include "text.h"

#include <cstring>

namespace tugboat {
namespace engine {

namespace {

constexpr uint32_t kRoundConstants[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

inline uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

void compress(uint32_t state[8], const uint8_t block[64]) {
  uint32_t w[64];
  for (int i = 0; i < 16; ++i) {
    w[i] = (static_cast<uint32_t>(block[i * 4]) << 24) |
           (static_cast<uint32_t>(block[i * 4 + 1]) << 16) |
           (static_cast<uint32_t>(block[i * 4 + 2]) << 8) |
           static_cast<uint32_t>(block[i * 4 + 3]);
  }
  for (int i = 16; i < 64; ++i) {
    const uint32_t s0 =
        rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
    const uint32_t s1 =
        rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
  uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
  for (int i = 0; i < 64; ++i) {
    const uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
    const uint32_t ch = (e & f) ^ (~e & g);
    const uint32_t t1 = h + s1 + ch + kRoundConstants[i] + w[i];
    const uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
    const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    const uint32_t t2 = s0 + maj;
    h = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  state[0] += a;
  state[1] += b;
  state[2] += c;
  state[3] += d;
  state[4] += e;
  state[5] += f;
  state[6] += g;
  state[7] += h;
}

bool is_dart_whitespace(uint32_t cp) {
  return (cp >= 0x09 && cp <= 0x0D) || cp == 0x20 || cp == 0x85 ||
         cp == 0xA0 || cp == 0x1680 || (cp >= 0x2000 && cp <= 0x200A) ||
         cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F ||
         cp == 0x3000 || cp == 0xFEFF;
}

// Byte length of the sequence a lead byte starts (input is valid WTF-8).
size_t sequence_length(unsigned char lead) {
  if (lead < 0x80) {
    return 1;
  }
  if (lead < 0xE0) {
    return 2;
  }
  return lead < 0xF0 ? 3 : 4;
}

void append_unit(uint32_t unit, std::string* out) {
  out->push_back(static_cast<char>(0xE0 | (unit >> 12)));
  out->push_back(static_cast<char>(0x80 | ((unit >> 6) & 0x3F)));
  out->push_back(static_cast<char>(0x80 | (unit & 0x3F)));
}

}  // namespace

std::array<uint8_t, 32> sha256(std::string_view bytes) {
  uint32_t state[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                       0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  const auto* data = reinterpret_cast<const uint8_t*>(bytes.data());
  const size_t size = bytes.size();
  size_t offset = 0;
  while (size - offset >= 64) {
    compress(state, data + offset);
    offset += 64;
  }
  uint8_t tail[128] = {};
  const size_t rest = size - offset;
  if (rest > 0) {
    std::memcpy(tail, data + offset, rest);
  }
  tail[rest] = 0x80;
  const size_t tail_blocks = rest + 1 + 8 <= 64 ? 1 : 2;
  const uint64_t bit_length = static_cast<uint64_t>(size) * 8u;
  for (int i = 0; i < 8; ++i) {
    tail[tail_blocks * 64 - 1 - static_cast<size_t>(i)] =
        static_cast<uint8_t>(bit_length >> (8 * i));
  }
  for (size_t b = 0; b < tail_blocks; ++b) {
    compress(state, tail + b * 64);
  }
  std::array<uint8_t, 32> digest{};
  for (int i = 0; i < 8; ++i) {
    digest[static_cast<size_t>(i) * 4] = static_cast<uint8_t>(state[i] >> 24);
    digest[static_cast<size_t>(i) * 4 + 1] =
        static_cast<uint8_t>(state[i] >> 16);
    digest[static_cast<size_t>(i) * 4 + 2] =
        static_cast<uint8_t>(state[i] >> 8);
    digest[static_cast<size_t>(i) * 4 + 3] = static_cast<uint8_t>(state[i]);
  }
  return digest;
}

std::string sha256_hex(std::string_view bytes) {
  static const char kHex[] = "0123456789abcdef";
  const std::array<uint8_t, 32> digest = sha256(bytes);
  std::string out;
  out.reserve(64);
  for (uint8_t byte : digest) {
    out.push_back(kHex[byte >> 4]);
    out.push_back(kHex[byte & 0xF]);
  }
  return out;
}

uint32_t wtf8_next(std::string_view s, size_t* i) {
  const auto lead = static_cast<unsigned char>(s[*i]);
  size_t length = 1;
  uint32_t cp = lead;
  if (lead >= 0xF0 && lead <= 0xF4) {
    length = 4;
    cp = lead & 0x07u;
  } else if (lead >= 0xE0) {
    length = 3;
    cp = lead & 0x0Fu;
  } else if (lead >= 0xC0) {
    length = 2;
    cp = lead & 0x1Fu;
  } else if (lead >= 0x80) {
    *i += 1;
    return 0xFFFD;
  }
  if (length > 1) {
    if (s.size() - *i < length) {
      *i += 1;
      return 0xFFFD;
    }
    for (size_t k = 1; k < length; ++k) {
      const auto byte = static_cast<unsigned char>(s[*i + k]);
      if ((byte & 0xC0u) != 0x80u) {
        *i += 1;
        return 0xFFFD;
      }
      cp = (cp << 6) | (byte & 0x3Fu);
    }
  }
  *i += length;
  return cp;
}

bool utf16_longer_than(std::string_view wtf8, size_t units) {
  size_t counted = 0;
  size_t i = 0;
  while (i < wtf8.size()) {
    counted += wtf8_next(wtf8, &i) >= 0x10000 ? 2 : 1;
    if (counted > units) {
      return true;
    }
  }
  return false;
}

std::string utf16_prefix(std::string_view wtf8, size_t units) {
  size_t counted = 0;
  size_t i = 0;
  while (i < wtf8.size() && counted < units) {
    size_t next = i;
    const uint32_t cp = wtf8_next(wtf8, &next);
    if (cp >= 0x10000 && counted + 1 == units) {
      // Only the high surrogate fits.
      std::string out(wtf8.substr(0, i));
      append_unit(0xD800u + ((cp - 0x10000u) >> 10), &out);
      return out;
    }
    counted += cp >= 0x10000 ? 2 : 1;
    i = next;
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
    size_t begin = end - 1;
    while (begin > start &&
           (static_cast<unsigned char>(wtf8[begin]) & 0xC0u) == 0x80u) {
      --begin;
    }
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
    const size_t length =
        sequence_length(static_cast<unsigned char>(wtf8[end]));
    if (end + length > max_bytes) {
      break;
    }
    end += length;
  }
  return wtf8.substr(0, end);
}

std::string wtf8_to_utf8(std::string_view wtf8) {
  std::string out;
  out.reserve(wtf8.size());
  size_t i = 0;
  while (i < wtf8.size()) {
    const size_t start = i;
    const uint32_t cp = wtf8_next(wtf8, &i);
    if ((cp >= 0xD800 && cp <= 0xDFFF) || cp == 0xFFFD) {
      // Lone surrogate (or an undecodable byte): U+FFFD, as utf8.encode does.
      out.append("\xEF\xBF\xBD");
    } else {
      out.append(wtf8.data() + start, i - start);
    }
  }
  return out;
}

int compare_utf16(std::string_view a, std::string_view b) {
  size_t ia = 0;
  size_t ib = 0;
  // Pending low surrogate of an astral code point already half-compared.
  uint32_t pending_a = 0;
  uint32_t pending_b = 0;
  while (true) {
    const bool end_a = pending_a == 0 && ia >= a.size();
    const bool end_b = pending_b == 0 && ib >= b.size();
    if (end_a || end_b) {
      return end_a == end_b ? 0 : (end_a ? -1 : 1);
    }
    uint32_t unit_a = pending_a;
    if (unit_a != 0) {
      pending_a = 0;
    } else {
      const uint32_t cp = wtf8_next(a, &ia);
      if (cp >= 0x10000) {
        unit_a = 0xD800 + ((cp - 0x10000) >> 10);
        pending_a = 0xDC00 + ((cp - 0x10000) & 0x3FF);
      } else {
        unit_a = cp;
      }
    }
    uint32_t unit_b = pending_b;
    if (unit_b != 0) {
      pending_b = 0;
    } else {
      const uint32_t cp = wtf8_next(b, &ib);
      if (cp >= 0x10000) {
        unit_b = 0xD800 + ((cp - 0x10000) >> 10);
        pending_b = 0xDC00 + ((cp - 0x10000) & 0x3FF);
      } else {
        unit_b = cp;
      }
    }
    if (unit_a != unit_b) {
      return unit_a < unit_b ? -1 : 1;
    }
  }
}

std::string label_hash(std::string_view wtf8) {
  if (wtf8.empty()) {
    return std::string();
  }
  return sha256_hex(wtf8_to_utf8(wtf8)).substr(0, 16);
}

}  // namespace engine
}  // namespace tugboat
