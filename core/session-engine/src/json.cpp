#include "json.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>

#include "double-conversion/double-to-string.h"
#include "double-conversion/string-to-double.h"

namespace tugboat {
namespace engine {

// ------------------------------------------------------------------ Value

Value Value::boolean(bool v) {
  Value out;
  out.kind_ = Kind::kBool;
  out.bool_ = v;
  return out;
}

Value Value::integer(int64_t v) {
  Value out;
  out.kind_ = Kind::kInt;
  out.int_ = v;
  return out;
}

Value Value::number(double v) {
  Value out;
  out.kind_ = Kind::kDouble;
  out.double_ = v;
  return out;
}

Value Value::string(std::string v) {
  Value out;
  out.kind_ = Kind::kString;
  out.string_ = std::move(v);
  return out;
}

Value Value::array() {
  Value out;
  out.kind_ = Kind::kArray;
  return out;
}

Value Value::object() {
  Value out;
  out.kind_ = Kind::kObject;
  return out;
}

double Value::to_double() const {
  return is_int() ? static_cast<double>(int_) : double_;
}

const Value* Value::find(std::string_view key) const {
  for (const Member& member : members_) {
    if (member.key == key) {
      return &member.value;
    }
  }
  return nullptr;
}

void Value::set(std::string_view key, Value value) {
  for (Member& member : members_) {
    if (member.key == key) {
      member.value = std::move(value);
      return;
    }
  }
  members_.push_back(Member{std::string(key), std::move(value)});
}

void Value::remove(std::string_view key) {
  for (auto it = members_.begin(); it != members_.end(); ++it) {
    if (it->key == key) {
      members_.erase(it);
      return;
    }
  }
}

// ----------------------------------------------------------------- Parser

namespace {

bool is_digit(char c) { return c >= '0' && c <= '9'; }

void append_utf8(uint32_t cp, std::string* out) {
  // Also encodes lone surrogates (WTF-8), which only escapes can produce.
  if (cp < 0x80) {
    out->push_back(static_cast<char>(cp));
  } else if (cp < 0x800) {
    out->push_back(static_cast<char>(0xC0 | (cp >> 6)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp < 0x10000) {
    out->push_back(static_cast<char>(0xE0 | (cp >> 12)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else {
    out->push_back(static_cast<char>(0xF0 | (cp >> 18)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out->push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

class Parser {
 public:
  Parser(std::string_view text, uint32_t max_depth, ParseError* error)
      : text_(text), max_depth_(max_depth), error_(error) {}

  bool parse_document(Value* out) {
    skip_whitespace();
    if (!parse_value(out, 0)) {
      return false;
    }
    skip_whitespace();
    if (pos_ != text_.size()) {
      return fail("unexpected trailing characters");
    }
    return true;
  }

 private:
  bool fail(const char* message) {
    error_->offset = pos_;
    error_->message = message;
    return false;
  }

  bool at_end() const { return pos_ >= text_.size(); }
  char peek() const { return text_[pos_]; }

  void skip_whitespace() {
    while (!at_end()) {
      const char c = peek();
      if (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
        return;
      }
      ++pos_;
    }
  }

  bool parse_value(Value* out, uint32_t depth) {
    if (at_end()) {
      return fail("unexpected end of input");
    }
    switch (peek()) {
      case '{':
        return parse_object(out, depth + 1);
      case '[':
        return parse_array(out, depth + 1);
      case '"': {
        std::string s;
        if (!parse_string(&s)) {
          return false;
        }
        *out = Value::string(std::move(s));
        return true;
      }
      case 't':
        return parse_literal("true", Value::boolean(true), out);
      case 'f':
        return parse_literal("false", Value::boolean(false), out);
      case 'n':
        return parse_literal("null", Value::null(), out);
      default:
        if (peek() == '-' || is_digit(peek())) {
          return parse_number(out);
        }
        return fail("unexpected character");
    }
  }

  bool parse_literal(const char* word, Value value, Value* out) {
    const size_t len = std::strlen(word);
    if (text_.size() - pos_ < len || text_.compare(pos_, len, word) != 0) {
      return fail("invalid literal");
    }
    pos_ += len;
    *out = std::move(value);
    return true;
  }

  bool enter(uint32_t depth) {
    if (depth > max_depth_) {
      return fail("nesting exceeds maximum depth");
    }
    ++pos_;  // '{' or '['
    skip_whitespace();
    return true;
  }

  bool parse_object(Value* out, uint32_t depth) {
    if (!enter(depth)) {
      return false;
    }
    *out = Value::object();
    if (!at_end() && peek() == '}') {
      ++pos_;
      return true;
    }
    while (true) {
      if (at_end() || peek() != '"') {
        return fail("expected object key");
      }
      std::string key;
      if (!parse_string(&key)) {
        return false;
      }
      skip_whitespace();
      if (at_end() || peek() != ':') {
        return fail("expected ':'");
      }
      ++pos_;
      skip_whitespace();
      Value value;
      if (!parse_value(&value, depth)) {
        return false;
      }
      out->members().push_back(Member{std::move(key), std::move(value)});
      skip_whitespace();
      if (at_end()) {
        return fail("unterminated object");
      }
      if (peek() == ',') {
        ++pos_;
        skip_whitespace();
        continue;
      }
      if (peek() == '}') {
        ++pos_;
        return check_unique_keys(*out);
      }
      return fail("expected ',' or '}'");
    }
  }

  // O(n log n) so a message with many keys cannot stall the host queue.
  bool check_unique_keys(const Value& object) {
    const std::vector<Member>& members = object.members();
    std::vector<const std::string*> keys;
    keys.reserve(members.size());
    for (const Member& member : members) {
      keys.push_back(&member.key);
    }
    std::sort(keys.begin(), keys.end(),
              [](const std::string* a, const std::string* b) { return *a < *b; });
    for (size_t i = 1; i < keys.size(); ++i) {
      if (*keys[i - 1] == *keys[i]) {
        --pos_;  // report at the closing brace
        return fail("duplicate object key");
      }
    }
    return true;
  }

  bool parse_array(Value* out, uint32_t depth) {
    if (!enter(depth)) {
      return false;
    }
    *out = Value::array();
    if (!at_end() && peek() == ']') {
      ++pos_;
      return true;
    }
    while (true) {
      Value value;
      if (!parse_value(&value, depth)) {
        return false;
      }
      out->push(std::move(value));
      skip_whitespace();
      if (at_end()) {
        return fail("unterminated array");
      }
      if (peek() == ',') {
        ++pos_;
        skip_whitespace();
        continue;
      }
      if (peek() == ']') {
        ++pos_;
        return true;
      }
      return fail("expected ',' or ']'");
    }
  }

  bool read_hex4(uint32_t* out) {
    if (text_.size() - pos_ < 4) {
      return fail("truncated \\u escape");
    }
    uint32_t value = 0;
    for (int i = 0; i < 4; ++i) {
      const char c = text_[pos_ + static_cast<size_t>(i)];
      value <<= 4;
      if (c >= '0' && c <= '9') {
        value |= static_cast<uint32_t>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        value |= static_cast<uint32_t>(c - 'a' + 10);
      } else if (c >= 'A' && c <= 'F') {
        value |= static_cast<uint32_t>(c - 'A' + 10);
      } else {
        return fail("invalid \\u escape");
      }
    }
    pos_ += 4;
    *out = value;
    return true;
  }

  // At a backslash. Appends the escaped character, pairing a high-surrogate
  // escape with a directly following low-surrogate escape.
  bool parse_escape(std::string* out) {
    ++pos_;
    if (at_end()) {
      return fail("unterminated string");
    }
    const char c = peek();
    ++pos_;
    switch (c) {
      case '"': out->push_back('"'); return true;
      case '\\': out->push_back('\\'); return true;
      case '/': out->push_back('/'); return true;
      case 'b': out->push_back('\b'); return true;
      case 'f': out->push_back('\f'); return true;
      case 'n': out->push_back('\n'); return true;
      case 'r': out->push_back('\r'); return true;
      case 't': out->push_back('\t'); return true;
      case 'u': break;
      default:
        --pos_;
        return fail("invalid escape");
    }
    uint32_t unit = 0;
    if (!read_hex4(&unit)) {
      return false;
    }
    if (unit >= 0xD800 && unit <= 0xDBFF && text_.size() - pos_ >= 6 &&
        text_[pos_] == '\\' && text_[pos_ + 1] == 'u') {
      const size_t save = pos_;
      pos_ += 2;
      uint32_t low = 0;
      if (!read_hex4(&low)) {
        return false;
      }
      if (low >= 0xDC00 && low <= 0xDFFF) {
        append_utf8(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00), out);
        return true;
      }
      pos_ = save;  // Not a pair: keep the lone high surrogate.
    }
    append_utf8(unit, out);
    return true;
  }

  // Copies one raw UTF-8 sequence, rejecting overlong forms, encoded
  // surrogates, and code points above U+10FFFF.
  bool copy_utf8(std::string* out) {
    const auto lead = static_cast<unsigned char>(peek());
    size_t length = 0;
    uint32_t min = 0;
    uint32_t cp = 0;
    if (lead >= 0xC2 && lead <= 0xDF) {
      length = 2;
      min = 0x80;
      cp = lead & 0x1Fu;
    } else if (lead >= 0xE0 && lead <= 0xEF) {
      length = 3;
      min = 0x800;
      cp = lead & 0x0Fu;
    } else if (lead >= 0xF0 && lead <= 0xF4) {
      length = 4;
      min = 0x10000;
      cp = lead & 0x07u;
    } else {
      return fail("invalid UTF-8");
    }
    if (text_.size() - pos_ < length) {
      return fail("invalid UTF-8");
    }
    for (size_t i = 1; i < length; ++i) {
      const auto byte = static_cast<unsigned char>(text_[pos_ + i]);
      if ((byte & 0xC0u) != 0x80u) {
        return fail("invalid UTF-8");
      }
      cp = (cp << 6) | (byte & 0x3Fu);
    }
    if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
      return fail("invalid UTF-8");
    }
    out->append(text_.data() + pos_, length);
    pos_ += length;
    return true;
  }

  bool parse_string(std::string* out) {
    ++pos_;  // opening quote
    while (true) {
      if (at_end()) {
        return fail("unterminated string");
      }
      const auto c = static_cast<unsigned char>(peek());
      if (c == '"') {
        ++pos_;
        return true;
      }
      if (c == '\\') {
        if (!parse_escape(out)) {
          return false;
        }
      } else if (c < 0x20) {
        return fail("control character in string");
      } else if (c < 0x80) {
        out->push_back(static_cast<char>(c));
        ++pos_;
      } else if (!copy_utf8(out)) {
        return false;
      }
    }
  }

  size_t scan_digits() {
    const size_t start = pos_;
    while (!at_end() && is_digit(peek())) {
      ++pos_;
    }
    return pos_ - start;
  }

  bool parse_number(Value* out) {
    const size_t start = pos_;
    if (peek() == '-') {
      ++pos_;
    }
    if (at_end() || !is_digit(peek())) {
      return fail("invalid number");
    }
    if (peek() == '0') {
      ++pos_;
      if (!at_end() && is_digit(peek())) {
        return fail("leading zero in number");
      }
    } else {
      scan_digits();
    }
    bool integral = true;
    if (!at_end() && peek() == '.') {
      ++pos_;
      integral = false;
      if (scan_digits() == 0) {
        return fail("invalid number");
      }
    }
    if (!at_end() && (peek() == 'e' || peek() == 'E')) {
      ++pos_;
      integral = false;
      if (!at_end() && (peek() == '+' || peek() == '-')) {
        ++pos_;
      }
      if (scan_digits() == 0) {
        return fail("invalid number");
      }
    }
    const std::string_view lexeme = text_.substr(start, pos_ - start);
    if (integral && parse_int64(lexeme, out)) {
      return true;
    }
    return parse_double(lexeme, out);
  }

  // Dart keeps integer literals that fit in int64 as `int`; "-0" is int 0.
  static bool parse_int64(std::string_view lexeme, Value* out) {
    const bool negative = lexeme[0] == '-';
    const uint64_t limit = negative
                               ? uint64_t{1} << 63
                               : static_cast<uint64_t>(
                                     std::numeric_limits<int64_t>::max());
    uint64_t magnitude = 0;
    for (size_t i = negative ? 1 : 0; i < lexeme.size(); ++i) {
      const auto digit = static_cast<uint64_t>(lexeme[i] - '0');
      if (magnitude > (limit - digit) / 10) {
        return false;
      }
      magnitude = magnitude * 10 + digit;
    }
    int64_t value = 0;
    if (negative) {
      value = magnitude == (uint64_t{1} << 63)
                  ? std::numeric_limits<int64_t>::min()
                  : -static_cast<int64_t>(magnitude);
    } else {
      value = static_cast<int64_t>(magnitude);
    }
    *out = Value::integer(value);
    return true;
  }

  // Correctly rounded and locale-independent. Overflow gives an infinity,
  // which Dart also produces; the writer rejects it if it reaches output.
  bool parse_double(std::string_view lexeme, Value* out) {
    if (lexeme.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
      return fail("number too long");
    }
    using tb_double_conversion::StringToDoubleConverter;
    const StringToDoubleConverter converter(StringToDoubleConverter::NO_FLAGS,
                                            0.0, 0.0, nullptr, nullptr);
    int processed = 0;
    const double value = converter.StringToDouble(
        lexeme.data(), static_cast<int>(lexeme.size()), &processed);
    if (processed != static_cast<int>(lexeme.size())) {
      return fail("invalid number");
    }
    *out = Value::number(value);
    return true;
  }

  std::string_view text_;
  uint32_t max_depth_;
  ParseError* error_;
  size_t pos_ = 0;
};

// ----------------------------------------------------------------- Writer

const char kHex[] = "0123456789abcdef";

void append_unit_escape(uint32_t unit, std::string* out) {
  out->append("\\u");
  out->push_back(kHex[(unit >> 12) & 0xF]);
  out->push_back(kHex[(unit >> 8) & 0xF]);
  out->push_back(kHex[(unit >> 4) & 0xF]);
  out->push_back(kHex[unit & 0xF]);
}

void append_path_key(std::string* path, std::string_view key) {
  path->push_back('.');
  path->append(key.data(), key.size());
}

class Writer {
 public:
  Writer(std::string* out, std::string* error_path)
      : out_(out), error_path_(error_path) {}

  bool write(const Value& value) {
    switch (value.kind()) {
      case Value::Kind::kNull:
        out_->append("null");
        return true;
      case Value::Kind::kBool:
        out_->append(value.as_bool() ? "true" : "false");
        return true;
      case Value::Kind::kInt:
        out_->append(std::to_string(value.as_int()));
        return true;
      case Value::Kind::kDouble:
        if (!std::isfinite(value.as_double())) {
          if (error_path_ != nullptr) {
            *error_path_ = path_;
          }
          return false;
        }
        out_->append(format_double(value.as_double()));
        return true;
      case Value::Kind::kString:
        write_json_string(value.as_string(), out_);
        return true;
      case Value::Kind::kArray:
        return write_array(value);
      case Value::Kind::kObject:
        return write_object(value);
    }
    return false;
  }

 private:
  bool write_array(const Value& value) {
    out_->push_back('[');
    const size_t path_size = path_.size();
    size_t index = 0;
    for (const Value& item : value.items()) {
      if (index > 0) {
        out_->push_back(',');
      }
      path_.append("[" + std::to_string(index) + "]");
      if (!write(item)) {
        return false;
      }
      path_.resize(path_size);
      ++index;
    }
    out_->push_back(']');
    return true;
  }

  bool write_object(const Value& value) {
    out_->push_back('{');
    const size_t path_size = path_.size();
    bool first = true;
    for (const Member& member : value.members()) {
      if (!first) {
        out_->push_back(',');
      }
      first = false;
      write_json_string(member.key, out_);
      out_->push_back(':');
      append_path_key(&path_, member.key);
      if (!write(member.value)) {
        return false;
      }
      path_.resize(path_size);
    }
    out_->push_back('}');
    return true;
  }

  std::string* out_;
  std::string* error_path_;
  std::string path_ = "$";
};

}  // namespace

bool parse_json(std::string_view text, uint32_t max_depth, Value* out,
                ParseError* error) {
  Parser parser(text, max_depth, error);
  return parser.parse_document(out);
}

bool write_json(const Value& value, std::string* out, std::string* error_path) {
  Writer writer(out, error_path);
  return writer.write(value);
}

std::string format_double(double value) {
  // The converter Dart's VM uses for double.toString() (runtime/vm/
  // double_conversion.cc): shortest round-trip digits, decimal notation for
  // decimal exponents in [-6, 21), "e+N" otherwise, and a trailing ".0" on
  // integral values.
  using tb_double_conversion::DoubleToStringConverter;
  static const DoubleToStringConverter converter(
      DoubleToStringConverter::EMIT_POSITIVE_EXPONENT_SIGN |
          DoubleToStringConverter::EMIT_TRAILING_DECIMAL_POINT |
          DoubleToStringConverter::EMIT_TRAILING_ZERO_AFTER_POINT,
      "Infinity", "NaN", 'e', -6, 21, 0, 0);
  char buffer[64];
  tb_double_conversion::StringBuilder builder(buffer, sizeof(buffer));
  converter.ToShortest(value, &builder);
  return std::string(builder.Finalize());
}

void write_json_string(std::string_view wtf8, std::string* out) {
  out->push_back('"');
  size_t i = 0;
  while (i < wtf8.size()) {
    const auto c = static_cast<unsigned char>(wtf8[i]);
    if (c == '"' || c == '\\') {
      out->push_back('\\');
      out->push_back(static_cast<char>(c));
      ++i;
    } else if (c < 0x20) {
      switch (c) {
        case '\b': out->append("\\b"); break;
        case '\f': out->append("\\f"); break;
        case '\n': out->append("\\n"); break;
        case '\r': out->append("\\r"); break;
        case '\t': out->append("\\t"); break;
        default: append_unit_escape(c, out); break;
      }
      ++i;
    } else if (c == 0xED && i + 2 < wtf8.size() &&
               static_cast<unsigned char>(wtf8[i + 1]) >= 0xA0) {
      // WTF-8 lone surrogate: Dart escapes unpaired surrogates.
      const uint32_t unit =
          0xD000u |
          ((static_cast<unsigned char>(wtf8[i + 1]) & 0x3Fu) << 6) |
          (static_cast<unsigned char>(wtf8[i + 2]) & 0x3Fu);
      append_unit_escape(unit, out);
      i += 3;
    } else {
      out->push_back(static_cast<char>(c));
      ++i;
    }
  }
  out->push_back('"');
}

}  // namespace engine
}  // namespace tugboat
