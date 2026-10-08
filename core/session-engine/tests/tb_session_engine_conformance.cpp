// Conformance runner: evaluates every fixture under <repo>/conformance/
// through the public C ABI only and compares the engine's result with the
// fixture's `expected` value using type-strict deep JSON equality (see
// conformance/README.md "Comparison").
//
// This file has its own small JSON reader on purpose, so a bug in the
// engine's parser cannot hide itself by being used on both sides of the
// comparison. It keeps each value's source span, so the fixture `input` is
// submitted byte-for-byte as written.
//
// Usage: tb_session_engine_conformance [fixture-dir] [path-substring]
#include "tugboat/tb_session_engine.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#ifndef TB_CONFORMANCE_DIR
#error "TB_CONFORMANCE_DIR must point at <repo>/conformance"
#endif

namespace fs = std::filesystem;

namespace {

constexpr int64_t kFixtureFormat = 1;

// ------------------------------------------------------------ JSON reader

struct Json {
  enum class Kind { kNull, kBool, kInt, kDouble, kString, kArray, kObject };
  Kind kind = Kind::kNull;
  bool boolean = false;
  std::string text;  // string value (UTF-8/WTF-8) or number lexeme
  std::vector<Json> items;
  std::vector<std::pair<std::string, Json>> members;
  size_t begin = 0;  // source span
  size_t end = 0;

  const Json* find(const std::string& key) const {
    for (const auto& member : members) {
      if (member.first == key) {
        return &member.second;
      }
    }
    return nullptr;
  }
};

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
      const char c = s_[i_++];
      static const std::string kSimple = "\"\\/bfnrt";
      static const std::string kValue = "\"\\/\b\f\n\r\t";
      const size_t simple = kSimple.find(c);
      if (simple != std::string::npos) {
        out->push_back(kValue[simple]);
        continue;
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
  bool value(Json* out, int depth) {
    if (depth > 200 || i_ >= s_.size()) {
      return bad("unexpected end or too deep");
    }
    out->begin = i_;
    const char c = s_[i_];
    bool ok = true;
    if (c == '{') {
      out->kind = Json::Kind::kObject;
      ++i_;
      ws();
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
      ok = ok && i_ < s_.size() && s_[i_++] == '}';
    } else if (c == '[') {
      out->kind = Json::Kind::kArray;
      ++i_;
      ws();
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
      ok = ok && i_ < s_.size() && s_[i_++] == ']';
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

// ------------------------------------------------------------- comparison

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
  std::string text = source.substr(value.begin, value.end - value.begin);
  if (text.size() > 80) {
    text = text.substr(0, 77) + "...";
  }
  return text + " (" + kind_name(value.kind) + ")";
}

struct Diff {
  const std::string& expected_source;
  const std::string& actual_source;
  std::vector<std::string> lines;

  void mismatch(const std::string& path, const Json& expected,
                const Json& actual) {
    lines.push_back(path + ": expected " + describe(expected, expected_source) +
                    ", actual " + describe(actual, actual_source));
  }

  // Integers and doubles never match each other; doubles compare by value
  // (Dart `==`, so 0.0 equals -0.0); strings compare by code point.
  bool same_scalar(const Json& e, const Json& a) const {
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

  void compare(const Json& e, const Json& a, const std::string& path) {
    if (e.kind == Json::Kind::kObject && a.kind == Json::Kind::kObject) {
      for (const auto& member : e.members) {
        const Json* other = a.find(member.first);
        if (other == nullptr) {
          lines.push_back(path + "." + member.first + ": missing in actual");
        } else {
          compare(member.second, *other, path + "." + member.first);
        }
      }
      for (const auto& member : a.members) {
        if (e.find(member.first) == nullptr) {
          lines.push_back(path + "." + member.first + ": unexpected in actual");
        }
      }
      return;
    }
    if (e.kind == Json::Kind::kArray && a.kind == Json::Kind::kArray) {
      if (e.items.size() != a.items.size()) {
        lines.push_back(path + ": expected " + std::to_string(e.items.size()) +
                        " items, actual " + std::to_string(a.items.size()));
        return;
      }
      for (size_t i = 0; i < e.items.size(); ++i) {
        compare(e.items[i], a.items[i], path + "[" + std::to_string(i) + "]");
      }
      return;
    }
    if (!same_scalar(e, a)) {
      mismatch(path, e, a);
    }
  }
};

// ---------------------------------------------------------------- fixtures

const std::map<std::string, std::string> kKindDirectories = {
    {"fingerprint.identityParts", "fingerprint/identity_parts"},
    {"fingerprint.labelHash", "fingerprint/label_hash"},
    {"collector.event", "collector/event"},
    {"collector.sessionLifecycle", "collector/session_lifecycle"},
};

const std::set<std::string> kEnvelopeKeys = {
    "fixtureFormat", "kind", "name", "description",
    "contract", "input", "expected"};

std::string read_file(const fs::path& path) {
  std::ifstream in(path, std::ios::binary);
  std::ostringstream text;
  text << in.rdbuf();
  return text.str();
}

struct Engine {
  tb_session_engine* handle = nullptr;
  Engine() {
    tb_session_engine_config_v1 config{};
    config.abi_version = TB_SESSION_ENGINE_ABI_VERSION;
    if (tb_session_engine_create_v1(&config, &handle) != TB_SESSION_OK) {
      std::fprintf(stderr, "tb_session_engine_create_v1 failed\n");
      std::exit(2);
    }
  }
  ~Engine() { tb_session_engine_destroy(handle); }
};

bool int_equals(const Json* value, int64_t expected) {
  return value != nullptr && value->kind == Json::Kind::kInt &&
         std::stoll(value->text) == expected;
}

// Checks the envelope; returns an empty string when valid.
std::string check_envelope(const Json& fixture, const std::string& relative) {
  if (fixture.kind != Json::Kind::kObject) {
    return "fixture is not an object";
  }
  for (const auto& member : fixture.members) {
    if (kEnvelopeKeys.count(member.first) == 0) {
      return "unknown envelope key " + member.first;
    }
  }
  if (!int_equals(fixture.find("fixtureFormat"), kFixtureFormat)) {
    return "unsupported fixtureFormat (runner reads 1)";
  }
  const Json* kind = fixture.find("kind");
  const Json* name = fixture.find("name");
  const Json* description = fixture.find("description");
  const Json* input = fixture.find("input");
  const Json* expected = fixture.find("expected");
  if (kind == nullptr || kind->kind != Json::Kind::kString ||
      kKindDirectories.count(kind->text) == 0) {
    return "unknown kind";
  }
  if (name == nullptr || name->kind != Json::Kind::kString ||
      fs::path(relative).filename().string() != name->text + ".json") {
    return "name must equal the file name stem";
  }
  if (relative.rfind(kKindDirectories.at(kind->text) + "/", 0) != 0) {
    return "kind " + kind->text + " lives in " +
           kKindDirectories.at(kind->text);
  }
  if (description == nullptr || description->kind != Json::Kind::kString) {
    return "description must be a string";
  }
  if (input == nullptr || input->kind != Json::Kind::kObject ||
      expected == nullptr || expected->kind != Json::Kind::kObject) {
    return "input and expected must be objects";
  }
  const Json* contract = fixture.find("contract");
  if (contract == nullptr || contract->kind != Json::Kind::kObject ||
      contract->members.size() != 2 ||
      !int_equals(contract->find("sessionSchemaVersion"),
                  tb_session_engine_session_schema_version()) ||
      !int_equals(contract->find("fingerprintSchemaVersion"),
                  tb_session_engine_fingerprint_schema_version())) {
    return "fixture is pinned to other contract versions than the engine "
           "(sessionSchemaVersion " +
           std::to_string(tb_session_engine_session_schema_version()) +
           ", fingerprintSchemaVersion " +
           std::to_string(tb_session_engine_fingerprint_schema_version()) +
           "); review and re-pin";
  }
  return std::string();
}

// Runs one fixture; prints and returns false on failure.
bool run_fixture(Engine& engine, const fs::path& path,
                 const std::string& relative, std::set<std::string>* kinds) {
  const std::string source = read_file(path);
  Json fixture;
  std::string error;
  if (!Reader(source).read(&fixture, &error)) {
    std::printf("FAIL %s\n  unreadable fixture: %s\n", relative.c_str(),
                error.c_str());
    return false;
  }
  error = check_envelope(fixture, relative);
  if (!error.empty()) {
    std::printf("FAIL %s\n  %s\n", relative.c_str(), error.c_str());
    return false;
  }
  const Json& kind = *fixture.find("kind");
  const Json& contract = *fixture.find("contract");
  const Json& input = *fixture.find("input");
  kinds->insert(kind.text);

  // Fixture kind == message type; input is passed through verbatim.
  const std::string message =
      "{\"type\":\"" + kind.text + "\",\"contract\":" +
      source.substr(contract.begin, contract.end - contract.begin) +
      ",\"input\":" + source.substr(input.begin, input.end - input.begin) +
      "}";
  const char* out = nullptr;
  size_t out_len = 0;
  const tb_session_status status = tb_session_engine_submit_v1(
      engine.handle, message.data(), message.size(), &out, &out_len);
  const std::string response(out == nullptr ? "" : out, out_len);
  if (status != TB_SESSION_OK) {
    std::printf("FAIL %s\n  engine status %s: %s\n", relative.c_str(),
                tb_session_status_name(status), response.c_str());
    return false;
  }
  Json parsed;
  if (!Reader(response).read(&parsed, &error) ||
      parsed.find("result") == nullptr) {
    std::printf("FAIL %s\n  unreadable response (%s): %s\n", relative.c_str(),
                error.c_str(), response.c_str());
    return false;
  }
  const Json* effects = parsed.find("effects");
  if (effects == nullptr || effects->kind != Json::Kind::kArray ||
      !effects->items.empty()) {
    std::printf("FAIL %s\n  expected an empty effects array: %s\n",
                relative.c_str(), response.c_str());
    return false;
  }
  Diff diff{source, response, {}};
  diff.compare(*fixture.find("expected"), *parsed.find("result"),
               "$.expected");
  if (diff.lines.empty()) {
    std::printf("ok   %s\n", relative.c_str());
    return true;
  }
  std::printf("FAIL %s does not match the engine:\n", relative.c_str());
  for (const std::string& line : diff.lines) {
    std::printf("  %s\n", line.c_str());
  }
  const Json& result = *parsed.find("result");
  std::printf("  actual result: %s\n",
              response.substr(result.begin, result.end - result.begin).c_str());
  return false;
}

}  // namespace

int main(int argc, char** argv) {
  const fs::path root = argc > 1 ? fs::path(argv[1]) : fs::path(TB_CONFORMANCE_DIR);
  const std::string filter = argc > 2 ? argv[2] : "";
  if (!fs::exists(root / "README.md")) {
    std::fprintf(stderr, "conformance directory not found: %s\n",
                 root.string().c_str());
    return 2;
  }
  std::vector<std::pair<std::string, fs::path>> files;
  for (const auto& entry : fs::recursive_directory_iterator(root)) {
    if (entry.is_regular_file() && entry.path().extension() == ".json") {
      std::string relative = fs::relative(entry.path(), root).generic_string();
      if (relative.find(filter) != std::string::npos) {
        files.emplace_back(std::move(relative), entry.path());
      }
    }
  }
  std::sort(files.begin(), files.end());

  Engine engine;
  std::set<std::string> kinds;
  int failures = 0;
  for (const auto& file : files) {
    if (!run_fixture(engine, file.second, file.first, &kinds)) {
      ++failures;
    }
  }
  if (filter.empty() && kinds.size() != kKindDirectories.size()) {
    std::printf("FAIL conformance/ must hold fixtures for every kind (%zu of "
                "%zu present)\n",
                kinds.size(), kKindDirectories.size());
    ++failures;
  }
  if (files.empty()) {
    std::printf("FAIL no fixtures found under %s\n", root.string().c_str());
    ++failures;
  }
  std::printf("%zu fixtures, %d failed\n", files.size(), failures);
  return failures == 0 ? 0 : 1;
}
