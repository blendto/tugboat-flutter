#include "conformance_json.h"

#include <algorithm>
#include <cstdlib>
#include <string>

namespace conformance {

namespace {

class Reader {
 public:
  explicit Reader(const std::string& text) : s_(text) {}

  bool read(Json* out, std::string* error) {
    ws();
    if (!value(out, 0)) {
      *error = error_ + " at byte " + std::to_string(i_);
      return false;
    }
    ws();
    if (i_ != s_.size()) {
      *error = "trailing characters at byte " + std::to_string(i_);
      return false;
    }
    return true;
  }

 private:
  bool bad(const char* message) {
    error_ = message;
    return false;
  }
  void ws() {
    while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\n' ||
                              s_[i_] == '\r' || s_[i_] == '\t')) {
      ++i_;
    }
  }
  bool lit(const char* word) {
    const std::string w(word);
    if (s_.compare(i_, w.size(), w) != 0) {
      return bad("bad literal");
    }
    i_ += w.size();
    return true;
  }
  static void utf8(uint32_t cp, std::string* out) {
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
  bool hex4(uint32_t* out) {
    if (i_ + 4 > s_.size()) {
      return bad("short \\u escape");
    }
    *out = static_cast<uint32_t>(std::stoul(s_.substr(i_, 4), nullptr, 16));
    i_ += 4;
    return true;
  }
  bool escape(std::string* out) {
    const char c = s_[i_++];
    static const std::string kSimple = "\"\\/bfnrt";
    static const std::string kValue = "\"\\/\b\f\n\r\t";
    const size_t simple = kSimple.find(c);
    if (simple != std::string::npos) {
      out->push_back(kValue[simple]);
      return true;
    }
    if (c != 'u') {
      return bad("bad escape");
    }
    uint32_t unit = 0;
    if (!hex4(&unit)) {
      return false;
    }
    if (unit >= 0xD800 && unit < 0xDC00 && s_.compare(i_, 2, "\\u") == 0) {
      const size_t save = i_;
      i_ += 2;
      uint32_t low = 0;
      if (!hex4(&low)) {
        return false;
      }
      if (low >= 0xDC00 && low < 0xE000) {
        unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
      } else {
        i_ = save;
      }
    }
    utf8(unit, out);
    return true;
  }
  bool str(std::string* out) {
    ++i_;
    while (i_ < s_.size() && s_[i_] != '"') {
      if (s_[i_] != '\\') {
        out->push_back(s_[i_++]);
        continue;
      }
      ++i_;
      if (i_ >= s_.size()) {
        return bad("unterminated escape");
      }
      if (!escape(out)) {
        return false;
      }
    }
    if (i_ >= s_.size()) {
      return bad("unterminated string");
    }
    ++i_;
    return true;
  }
  bool number(Json* out) {
    const size_t start = i_;
    bool integral = true;
    if (s_[i_] == '-') {
      ++i_;
    }
    while (i_ < s_.size()) {
      const char c = s_[i_];
      if (c == '.' || c == 'e' || c == 'E') {
        integral = false;
      } else if (!((c >= '0' && c <= '9') || c == '+' || c == '-')) {
        break;
      }
      ++i_;
    }
    out->kind = integral ? Json::Kind::kInt : Json::Kind::kDouble;
    out->text = s_.substr(start, i_ - start);
    return i_ > start;
  }
  bool object(Json* out, int depth) {
    out->kind = Json::Kind::kObject;
    ++i_;
    ws();
    bool ok = true;
    while (ok && i_ < s_.size() && s_[i_] != '}') {
      std::string key;
      Json item;
      ok = s_[i_] == '"' && str(&key);
      ws();
      ok = ok && i_ < s_.size() && s_[i_++] == ':';
      ws();
      ok = ok && value(&item, depth + 1);
      out->members.emplace_back(std::move(key), std::move(item));
      ws();
      if (ok && i_ < s_.size() && s_[i_] == ',') {
        ++i_;
        ws();
      }
    }
    return ok && i_ < s_.size() && s_[i_++] == '}';
  }
  bool array(Json* out, int depth) {
    out->kind = Json::Kind::kArray;
    ++i_;
    ws();
    bool ok = true;
    while (ok && i_ < s_.size() && s_[i_] != ']') {
      Json item;
      ok = value(&item, depth + 1);
      out->items.push_back(std::move(item));
      ws();
      if (ok && i_ < s_.size() && s_[i_] == ',') {
        ++i_;
        ws();
      }
    }
    return ok && i_ < s_.size() && s_[i_++] == ']';
  }
  bool value(Json* out, int depth) {
    if (depth > 200 || i_ >= s_.size()) {
      return bad("unexpected end or too deep");
    }
    out->begin = i_;
    const char c = s_[i_];
    bool ok = true;
    if (c == '{') {
      ok = object(out, depth);
    } else if (c == '[') {
      ok = array(out, depth);
    } else if (c == '"') {
      out->kind = Json::Kind::kString;
      ok = str(&out->text);
    } else if (c == 't' || c == 'f') {
      out->kind = Json::Kind::kBool;
      out->boolean = c == 't';
      ok = lit(c == 't' ? "true" : "false");
    } else if (c == 'n') {
      ok = lit("null");
    } else {
      ok = number(out);
    }
    out->end = i_;
    return ok || bad(error_.empty() ? "syntax error" : error_.c_str());
  }

  const std::string& s_;
  size_t i_ = 0;
  std::string error_;
};

const char* kind_name(Json::Kind kind) {
  switch (kind) {
    case Json::Kind::kNull: return "null";
    case Json::Kind::kBool: return "bool";
    case Json::Kind::kInt: return "int";
    case Json::Kind::kDouble: return "double";
    case Json::Kind::kString: return "string";
    case Json::Kind::kArray: return "array";
    case Json::Kind::kObject: return "object";
  }
  return "?";
}

std::string describe(const Json& value, const std::string& source) {
  std::string text = source_of(value, source);
  if (text.size() > 80) {
    text = text.substr(0, 77) + "...";
  }
  return text + " (" + kind_name(value.kind) + ")";
}

}  // namespace

const Json* Json::find(const std::string& key) const {
  for (const auto& member : members) {
    if (member.first == key) {
      return &member.second;
    }
  }
  return nullptr;
}

bool parse(const std::string& text, Json* out, std::string* error) {
  return Reader(text).read(out, error);
}

std::string source_of(const Json& value, const std::string& source) {
  return source.substr(value.begin, value.end - value.begin);
}

bool int_equals(const Json* value, int64_t expected) {
  return value != nullptr && value->kind == Json::Kind::kInt &&
         std::stoll(value->text) == expected;
}

void Diff::mismatch(const std::string& path, const Json& expected,
                    const Json& actual) {
  lines_.push_back(path + ": expected " + describe(expected, expected_source_) +
                   ", actual " + describe(actual, actual_source_));
}

// Integers and doubles never match each other; doubles compare by value
// (Dart `==`, so 0.0 equals -0.0); strings compare by code point.
bool Diff::same_scalar(const Json& e, const Json& a) const {
  if (e.kind != a.kind) {
    return false;
  }
  switch (e.kind) {
    case Json::Kind::kNull: return true;
    case Json::Kind::kBool: return e.boolean == a.boolean;
    case Json::Kind::kInt: return std::stoll(e.text) == std::stoll(a.text);
    case Json::Kind::kDouble:
      return std::strtod(e.text.c_str(), nullptr) ==
             std::strtod(a.text.c_str(), nullptr);
    case Json::Kind::kString: return e.text == a.text;
    default: return false;
  }
}

void Diff::compare(const Json& e, const Json& a, const std::string& path) {
  if (e.is(Json::Kind::kObject) && a.is(Json::Kind::kObject)) {
    for (const auto& member : e.members) {
      const Json* other = a.find(member.first);
      if (other == nullptr) {
        lines_.push_back(path + "." + member.first + ": missing in actual");
      } else {
        compare(member.second, *other, path + "." + member.first);
      }
    }
    for (const auto& member : a.members) {
      if (e.find(member.first) == nullptr) {
        lines_.push_back(path + "." + member.first + ": unexpected in actual");
      }
    }
    return;
  }
  if (e.is(Json::Kind::kArray) && a.is(Json::Kind::kArray)) {
    if (e.items.size() != a.items.size()) {
      lines_.push_back(path + ": expected " + std::to_string(e.items.size()) +
                       " items, actual " + std::to_string(a.items.size()));
    }
    const size_t common = std::min(e.items.size(), a.items.size());
    for (size_t i = 0; i < common; ++i) {
      compare(e.items[i], a.items[i], path + "[" + std::to_string(i) + "]");
    }
    return;
  }
  if (!same_scalar(e, a)) {
    mismatch(path, e, a);
  }
}

}  // namespace conformance
