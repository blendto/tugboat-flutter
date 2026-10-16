// Fingerprint hashing (fingerprint schema v6).
#include <algorithm>
#include <string>
#include <utility>
#include <vector>

#include "operations.h"
#include "text.h"

namespace tugboat {
namespace engine {

namespace {

using Part = std::pair<std::string, std::string>;

bool read_parts(const Value& input, std::vector<Part>* parts, Error* error) {
  const ObjectReader reader(input, "$.input", error);
  if (!reader.check_keys({"parts"})) {
    return false;
  }
  const Value* raw_parts = nullptr;
  if (!reader.req_array("parts", &raw_parts)) {
    return false;
  }
  const std::string where = reader.child("parts");
  size_t index = 0;
  for (const Value& raw : raw_parts->items()) {
    const std::string item = where + "[" + std::to_string(index++) + "]";
    if (!raw.is_array() || raw.items().size() != 2 ||
        !raw.items()[0].is_string() || !raw.items()[1].is_string()) {
      return invalid(error, item, "expected [key, value] string pair");
    }
    parts->emplace_back(raw.items()[0].as_string(),
                        raw.items()[1].as_string());
  }
  std::vector<const std::string*> keys;
  keys.reserve(parts->size());
  for (const Part& part : *parts) {
    keys.push_back(&part.first);
  }
  std::sort(keys.begin(), keys.end(),
            [](const std::string* a, const std::string* b) { return *a < *b; });
  for (size_t i = 1; i < keys.size(); ++i) {
    if (*keys[i - 1] == *keys[i]) {
      return invalid(error, where, "duplicate key");
    }
  }
  return true;
}

}  // namespace

bool run_identity_parts(const Value& input, Value* result, Error* error) {
  std::vector<Part> parts;
  if (!read_parts(input, &parts, error)) {
    return false;
  }
  // Dart String.compareTo: UTF-16 code units, not UTF-8 bytes. Separators
  // are not escaped (fingerprint schema v6).
  std::sort(parts.begin(), parts.end(), [](const Part& a, const Part& b) {
    return compare_utf16(a.first, b.first) < 0;
  });
  std::string canonical;
  for (size_t i = 0; i < parts.size(); ++i) {
    if (i > 0) {
      canonical.push_back('|');
    }
    canonical.append(parts[i].first);
    canonical.push_back('=');
    canonical.append(parts[i].second);
  }
  // No parts is "" rather than the hash of "".
  std::string fingerprint = parts.empty() ? std::string() : label_hash(canonical);
  *result = Value::object();
  result->set("canonicalString", Value::string(std::move(canonical)));
  result->set("fingerprint", Value::string(std::move(fingerprint)));
  return true;
}

bool run_label_hash(const Value& input, Value* result, Error* error) {
  const ObjectReader reader(input, "$.input", error);
  std::string value;
  if (!reader.check_keys({"value"}) || !reader.req_string("value", &value)) {
    return false;
  }
  *result = Value::object();
  result->set("hash", Value::string(label_hash(value)));
  return true;
}

}  // namespace engine
}  // namespace tugboat
