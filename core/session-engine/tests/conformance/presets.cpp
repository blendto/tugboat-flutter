#include "presets.h"

#include <utility>

namespace conformance {

namespace {

using Kind = Json::Kind;

constexpr char kPresetKey[] = "$preset";

// Configure group names and preset member names are plain identifiers, so
// they are written back without escaping; anything else is refused.
bool plain_key(const std::string& key) {
  if (key.empty()) {
    return false;
  }
  for (char c : key) {
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '_')) {
      return false;
    }
  }
  return true;
}

std::string member(const std::string& key, const std::string& value) {
  return "\"" + key + "\":" + value;
}

}  // namespace

std::string Presets::load(std::string source) {
  source_ = std::move(source);
  std::string error;
  if (!parse(source_, &root_, &error)) {
    return "unreadable: " + error;
  }
  const Json* format = root_.find("presetFormat");
  const Json* description = root_.find("description");
  const Json* presets = root_.find("presets");
  if (!root_.is(Kind::kObject) || root_.members.size() != 3 ||
      !int_equals(format, 1) || description == nullptr ||
      !description->is(Kind::kString) || presets == nullptr ||
      !presets->is(Kind::kObject) || presets->members.empty()) {
    return "must be {presetFormat: 1, description, presets: {name: object}}";
  }
  for (const auto& preset : presets->members) {
    if (!preset.second.is(Kind::kObject)) {
      return "preset " + preset.first + " must be an object";
    }
    for (const auto& field : preset.second.members) {
      if (!plain_key(field.first)) {
        return "preset " + preset.first + " has a key that is not plain";
      }
    }
  }
  return std::string();
}

std::string Presets::resolve_configure(const Json& configure,
                                       const std::string& source,
                                       std::string* out) const {
  const Json* presets = root_.find("presets");
  std::string text = "{";
  for (const auto& group : configure.members) {
    if (!plain_key(group.first)) {
      return "input.configure." + group.first + ": key is not plain";
    }
    const Json& value = group.second;
    const Json* name =
        value.is(Kind::kObject) ? value.find(kPresetKey) : nullptr;
    std::string resolved;
    if (name == nullptr) {
      resolved = source_of(value, source);
    } else {
      const Json* preset = name->is(Kind::kString) && presets != nullptr
                               ? presets->find(name->text)
                               : nullptr;
      if (preset == nullptr) {
        return "input.configure." + group.first +
               ".$preset: names no preset in " + kPresetsFile;
      }
      resolved = "{";
      for (const auto& field : preset->members) {
        const Json* override_value = value.find(field.first);
        resolved += (resolved.size() > 1 ? "," : "") +
                    member(field.first,
                           override_value != nullptr
                               ? source_of(*override_value, source)
                               : source_of(field.second, source_));
      }
      for (const auto& field : value.members) {
        if (field.first == kPresetKey || preset->find(field.first) != nullptr) {
          continue;
        }
        if (!plain_key(field.first)) {
          return "input.configure." + group.first + "." + field.first +
                 ": key is not plain";
        }
        resolved += (resolved.size() > 1 ? "," : "") +
                    member(field.first, source_of(field.second, source));
      }
      resolved += "}";
    }
    text += (text.size() > 1 ? "," : "") + member(group.first, resolved);
  }
  *out = text + "}";
  return std::string();
}

}  // namespace conformance
