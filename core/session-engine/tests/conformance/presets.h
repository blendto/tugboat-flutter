// Shared `engine.scenario` configuration presets (conformance/README.md
// "Presets"): `conformance/engine/presets.json` names objects that a
// scenario's `input.configure` group can stand for, so the same `host` block
// is written once. A group written as `{"$preset": name, …overrides}` is the
// preset object with each override replacing the preset member of the same
// key in place, or appended when the preset has none. Only the groups of
// `input.configure` are resolved; steps are sent byte for byte.
#ifndef TUGBOAT_SESSION_ENGINE_TESTS_PRESETS_H
#define TUGBOAT_SESSION_ENGINE_TESTS_PRESETS_H

#include <string>

#include "conformance_json.h"

namespace conformance {

// The presets file under conformance/. It is not a fixture.
constexpr char kPresetsFile[] = "engine/presets.json";

class Presets {
 public:
  // Reads `{presetFormat: 1, description, presets: {name: object}}`.
  // Returns an empty string on success.
  std::string load(std::string source);

  // The `engine.configure` input text for `configure` (a value parsed from
  // `source`): every group taken byte for byte, except preset references,
  // which become the preset's text with the overrides' text spliced in, so
  // numbers keep their lexemes. Returns an empty string on success.
  std::string resolve_configure(const Json& configure,
                                const std::string& source,
                                std::string* out) const;

 private:
  std::string source_;
  Json root_;
};

}  // namespace conformance

#endif  // TUGBOAT_SESSION_ENGINE_TESTS_PRESETS_H
