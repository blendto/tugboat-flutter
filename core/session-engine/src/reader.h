// Strict field readers for engine input messages. They mirror the reference
// fixture loader (`test/helpers/conformance_fixture.dart`): absent and null
// mean the same thing, a present value of the wrong type is an error, and
// unknown keys are an error. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_READER_H
#define TUGBOAT_SESSION_ENGINE_READER_H

#include <cstdint>
#include <initializer_list>
#include <optional>
#include <string>

#include "json.h"
#include "tugboat/tb_session_engine.h"

namespace tugboat {
namespace engine {

struct Error {
  tb_session_status status = TB_SESSION_OK;
  std::string path;
  std::string message;
};

inline bool fail(Error* error, tb_session_status status, std::string path,
                 std::string message) {
  error->status = status;
  error->path = std::move(path);
  error->message = std::move(message);
  return false;
}

inline bool invalid(Error* error, std::string path, std::string message) {
  return fail(error, TB_SESSION_INVALID_MESSAGE, std::move(path),
              std::move(message));
}

// Reads fields of one JSON object. `path` is the JSON path of the object
// (for example `$.input.host`), used in error messages.
class ObjectReader {
 public:
  ObjectReader(const Value& object, std::string path, Error* error)
      : object_(object), path_(std::move(path)), error_(error) {}

  const std::string& path() const { return path_; }
  std::string child(const char* key) const { return path_ + "." + key; }

  // Fails when the object has a key outside `allowed`.
  bool check_keys(std::initializer_list<const char*> allowed) const;

  // nullptr when absent or null.
  const Value* get(const char* key) const;

  bool opt_string(const char* key, std::optional<std::string>* out) const;
  bool req_string(const char* key, std::string* out) const;
  bool opt_int(const char* key, std::optional<int64_t>* out) const;
  bool req_int(const char* key, int64_t* out) const;
  bool opt_bool(const char* key, std::optional<bool>* out) const;
  // Any JSON number, converted to double (Dart `num.toDouble()`).
  bool req_double(const char* key, double* out) const;
  // `*out` is nullptr when absent or null; otherwise it must be an object.
  bool opt_object(const char* key, const Value** out) const;
  bool req_object(const char* key, const Value** out) const;
  bool req_array(const char* key, const Value** out) const;

 private:
  bool type_error(const char* key, const char* expected) const;

  const Value& object_;
  std::string path_;
  Error* error_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_READER_H
