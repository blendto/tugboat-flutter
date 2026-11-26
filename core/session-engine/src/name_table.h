// Closed wire vocabularies as tables: one table per enum gives both the wire
// name of a value and the strict decoding of a field.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_NAME_TABLE_H
#define TUGBOAT_SESSION_ENGINE_NAME_TABLE_H

#include <cstddef>
#include <optional>
#include <string>

#include "reader.h"

namespace tugboat {
namespace engine {

template <typename E>
struct NamedValue {
  const char* name;
  E value;
};

template <typename E, size_t N>
const char* name_of(const NamedValue<E> (&table)[N], E value) {
  for (const NamedValue<E>& entry : table) {
    if (entry.value == value) return entry.name;
  }
  return table[0].name;
}

template <typename E, size_t N>
std::optional<E> parse_name(const NamedValue<E> (&table)[N],
                            const std::string& name) {
  for (const NamedValue<E>& entry : table) {
    if (name == entry.name) return entry.value;
  }
  return std::nullopt;
}

// Reads the required string field `key` and maps it through `table`.
template <typename E, size_t N>
bool read_named(const ObjectReader& r, const char* key,
                const NamedValue<E> (&table)[N], E* out) {
  std::string name;
  if (!r.req_string(key, &name)) return false;
  const std::optional<E> value = parse_name(table, name);
  if (!value) {
    std::string expected = "expected one of";
    for (size_t i = 0; i < N; ++i) {
      expected += (i == 0 ? " " : ", ");
      expected += table[i].name;
    }
    return r.reject(key, expected);
  }
  *out = *value;
  return true;
}

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_NAME_TABLE_H
