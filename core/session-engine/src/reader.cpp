#include "reader.h"

#include <cstring>

namespace tugboat {
namespace engine {

bool ObjectReader::check_keys(std::initializer_list<const char*> allowed) const {
  for (const Member& member : object_.members()) {
    bool known = false;
    for (const char* key : allowed) {
      if (member.key == key) {
        known = true;
        break;
      }
    }
    if (!known) {
      return invalid(error_, path_ + "." + member.key, "unknown key");
    }
  }
  return true;
}

const Value* ObjectReader::get(const char* key) const {
  const Value* value = object_.find(key);
  if (value == nullptr || value->is_null()) {
    return nullptr;
  }
  return value;
}

bool ObjectReader::type_error(const char* key, const char* expected) const {
  return invalid(error_, child(key), std::string("expected ") + expected);
}

bool ObjectReader::opt_string(const char* key,
                              std::optional<std::string>* out) const {
  const Value* value = get(key);
  out->reset();
  if (value == nullptr) {
    return true;
  }
  if (!value->is_string()) {
    return type_error(key, "string");
  }
  *out = value->as_string();
  return true;
}

bool ObjectReader::req_string(const char* key, std::string* out) const {
  std::optional<std::string> value;
  if (!opt_string(key, &value)) {
    return false;
  }
  if (!value) {
    return invalid(error_, child(key), "required");
  }
  *out = std::move(*value);
  return true;
}

bool ObjectReader::opt_int(const char* key, std::optional<int64_t>* out) const {
  const Value* value = get(key);
  out->reset();
  if (value == nullptr) {
    return true;
  }
  if (!value->is_int()) {
    return type_error(key, "integer");
  }
  *out = value->as_int();
  return true;
}

bool ObjectReader::req_int(const char* key, int64_t* out) const {
  std::optional<int64_t> value;
  if (!opt_int(key, &value)) {
    return false;
  }
  if (!value) {
    return invalid(error_, child(key), "required");
  }
  *out = *value;
  return true;
}

bool ObjectReader::opt_bool(const char* key, std::optional<bool>* out) const {
  const Value* value = get(key);
  out->reset();
  if (value == nullptr) {
    return true;
  }
  if (!value->is_bool()) {
    return type_error(key, "boolean");
  }
  *out = value->as_bool();
  return true;
}

bool ObjectReader::req_double(const char* key, double* out) const {
  const Value* value = get(key);
  if (value == nullptr) {
    return invalid(error_, child(key), "required");
  }
  if (!value->is_number()) {
    return type_error(key, "number");
  }
  *out = value->to_double();
  return true;
}

bool ObjectReader::opt_object(const char* key, const Value** out) const {
  const Value* value = get(key);
  *out = nullptr;
  if (value == nullptr) {
    return true;
  }
  if (!value->is_object()) {
    return type_error(key, "object");
  }
  *out = value;
  return true;
}

bool ObjectReader::req_object(const char* key, const Value** out) const {
  if (!opt_object(key, out)) {
    return false;
  }
  if (*out == nullptr) {
    return type_error(key, "object");
  }
  return true;
}

bool ObjectReader::req_array(const char* key, const Value** out) const {
  const Value* value = get(key);
  *out = nullptr;
  if (value == nullptr || !value->is_array()) {
    return type_error(key, "array");
  }
  *out = value;
  return true;
}

}  // namespace engine
}  // namespace tugboat
