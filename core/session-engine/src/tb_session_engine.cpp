// C ABI of the session engine. Every entry point converts failures to status
// codes; no exception escapes and nothing aborts on bad input.
#include "tugboat/tb_session_engine.h"

#include <atomic>
#include <new>
#include <string>
#include <utility>

#include "json.h"
#include "operations.h"
#include "reader.h"

namespace {

using tugboat::engine::Error;
using tugboat::engine::ObjectReader;
using tugboat::engine::Value;

constexpr char kVersion[] = "0.1.0";

// Returned when the engine cannot allocate its own error document.
constexpr char kOutOfMemoryJson[] =
    "{\"error\":{\"status\":\"out_of_memory\",\"message\":\"out of memory\"}}";
constexpr char kBusyJson[] =
    "{\"error\":{\"status\":\"busy\",\"message\":\"another call is in "
    "progress on this handle\"}}";
constexpr char kInternalJson[] =
    "{\"error\":{\"status\":\"internal_error\",\"message\":\"internal "
    "error\"}}";

using Handler = bool (*)(const Value&, Value*, Error*);

struct MessageType {
  const char* name;
  Handler handler;
};

const MessageType kMessageTypes[] = {
    {"fingerprint.identityParts", tugboat::engine::run_identity_parts},
    {"fingerprint.labelHash", tugboat::engine::run_label_hash},
    {"collector.event", tugboat::engine::run_collector_event},
    {"collector.sessionLifecycle", tugboat::engine::run_session_lifecycle},
};

std::string error_document(const Error& error, const size_t* offset) {
  Value body = Value::object();
  body.set("status", Value::string(tb_session_status_name(error.status)));
  body.set("message", Value::string(error.message));
  if (!error.path.empty()) {
    body.set("path", Value::string(error.path));
  }
  if (offset != nullptr) {
    body.set("offset", Value::integer(static_cast<int64_t>(*offset)));
  }
  Value doc = Value::object();
  doc.set("error", std::move(body));
  std::string out;
  tugboat::engine::write_json(doc, &out, nullptr);
  return out;
}

bool check_contract(const ObjectReader& envelope, Error* error) {
  const Value* contract = nullptr;
  if (!envelope.opt_object("contract", &contract)) {
    return false;
  }
  if (contract == nullptr) {
    return true;
  }
  const ObjectReader r(*contract, envelope.child("contract"), error);
  int64_t session_schema = 0;
  int64_t fingerprint_schema = 0;
  if (!r.check_keys({"sessionSchemaVersion", "fingerprintSchemaVersion"}) ||
      !r.req_int("sessionSchemaVersion", &session_schema) ||
      !r.req_int("fingerprintSchemaVersion", &fingerprint_schema)) {
    return false;
  }
  if (session_schema != TB_SESSION_ENGINE_SESSION_SCHEMA_VERSION ||
      fingerprint_schema != TB_SESSION_ENGINE_FINGERPRINT_SCHEMA_VERSION) {
    return tugboat::engine::fail(
        error, TB_SESSION_CONTRACT_MISMATCH, envelope.child("contract"),
        "engine implements sessionSchemaVersion " +
            std::to_string(TB_SESSION_ENGINE_SESSION_SCHEMA_VERSION) +
            " and fingerprintSchemaVersion " +
            std::to_string(TB_SESSION_ENGINE_FINGERPRINT_SCHEMA_VERSION));
  }
  return true;
}

// Dispatches one parsed message. On success `*response` is the response
// document.
bool handle_message(const Value& message, Value* response, Error* error) {
  if (!message.is_object()) {
    return tugboat::engine::invalid(error, "$", "expected object");
  }
  const ObjectReader envelope(message, "$", error);
  std::string type;
  const Value* input = nullptr;
  if (!envelope.check_keys({"type", "contract", "input"}) ||
      !envelope.req_string("type", &type) || !check_contract(envelope, error) ||
      !envelope.req_object("input", &input)) {
    return false;
  }
  for (const MessageType& entry : kMessageTypes) {
    if (type != entry.name) {
      continue;
    }
    Value result;
    if (!entry.handler(*input, &result, error)) {
      return false;
    }
    *response = Value::object();
    response->set("type", Value::string(type));
    response->set("result", std::move(result));
    response->set("effects", Value::array());
    return true;
  }
  return tugboat::engine::fail(error, TB_SESSION_UNSUPPORTED_MESSAGE, "$.type",
                               "unknown message type");
}

}  // namespace

struct tb_session_engine {
  uint32_t max_depth = TB_SESSION_ENGINE_DEFAULT_MAX_DEPTH;
  size_t max_message_bytes = TB_SESSION_ENGINE_DEFAULT_MAX_MESSAGE_BYTES;
  std::atomic<bool> busy{false};
  // Last response; borrowed by the host until the next call.
  std::string output;

  tb_session_status submit(const char* message, size_t length) {
    Error error;
    if (length > max_message_bytes) {
      error.status = TB_SESSION_MESSAGE_TOO_LARGE;
      error.message = "message exceeds " + std::to_string(max_message_bytes) +
                      " bytes";
      output = error_document(error, nullptr);
      return error.status;
    }
    Value parsed;
    tugboat::engine::ParseError parse_error;
    const std::string_view text(message == nullptr ? "" : message,
                                message == nullptr ? 0 : length);
    if (!tugboat::engine::parse_json(text, max_depth, &parsed, &parse_error)) {
      error.status = TB_SESSION_MALFORMED_MESSAGE;
      error.message = parse_error.message;
      output = error_document(error, &parse_error.offset);
      return error.status;
    }
    Value response;
    if (!handle_message(parsed, &response, &error)) {
      output = error_document(error, nullptr);
      return error.status;
    }
    std::string json;
    std::string bad_path;
    if (!tugboat::engine::write_json(response, &json, &bad_path)) {
      // Dart jsonEncode throws on NaN and infinities.
      error.status = TB_SESSION_INVALID_MESSAGE;
      error.path = bad_path;
      error.message = "non-finite number cannot be encoded";
      output = error_document(error, nullptr);
      return error.status;
    }
    output = std::move(json);
    return TB_SESSION_OK;
  }
};

extern "C" {

const char* tb_session_engine_version(void) { return kVersion; }

uint32_t tb_session_engine_abi_version(void) {
  return TB_SESSION_ENGINE_ABI_VERSION;
}

uint32_t tb_session_engine_session_schema_version(void) {
  return TB_SESSION_ENGINE_SESSION_SCHEMA_VERSION;
}

uint32_t tb_session_engine_fingerprint_schema_version(void) {
  return TB_SESSION_ENGINE_FINGERPRINT_SCHEMA_VERSION;
}

const char* tb_session_status_name(tb_session_status status) {
  switch (status) {
    case TB_SESSION_OK: return "ok";
    case TB_SESSION_INVALID_ARGUMENT: return "invalid_argument";
    case TB_SESSION_ABI_MISMATCH: return "abi_mismatch";
    case TB_SESSION_MALFORMED_MESSAGE: return "malformed_message";
    case TB_SESSION_INVALID_MESSAGE: return "invalid_message";
    case TB_SESSION_UNSUPPORTED_MESSAGE: return "unsupported_message";
    case TB_SESSION_CONTRACT_MISMATCH: return "contract_mismatch";
    case TB_SESSION_MESSAGE_TOO_LARGE: return "message_too_large";
    case TB_SESSION_BUSY: return "busy";
    case TB_SESSION_OUT_OF_MEMORY: return "out_of_memory";
    case TB_SESSION_INTERNAL_ERROR: return "internal_error";
  }
  return "unknown";
}

tb_session_status tb_session_engine_create_v1(
    const tb_session_engine_config_v1* config, tb_session_engine** out_engine) {
  if (out_engine == nullptr) {
    return TB_SESSION_INVALID_ARGUMENT;
  }
  *out_engine = nullptr;
  if (config == nullptr) {
    return TB_SESSION_INVALID_ARGUMENT;
  }
  if (config->abi_version != TB_SESSION_ENGINE_ABI_VERSION) {
    return TB_SESSION_ABI_MISMATCH;
  }
  if (config->max_depth > TB_SESSION_ENGINE_MAX_DEPTH ||
      config->max_message_bytes > TB_SESSION_ENGINE_MAX_MESSAGE_BYTES) {
    return TB_SESSION_INVALID_ARGUMENT;
  }
  auto* engine = new (std::nothrow) tb_session_engine();
  if (engine == nullptr) {
    return TB_SESSION_OUT_OF_MEMORY;
  }
  if (config->max_depth != 0) {
    engine->max_depth = config->max_depth;
  }
  if (config->max_message_bytes != 0) {
    engine->max_message_bytes = config->max_message_bytes;
  }
  *out_engine = engine;
  return TB_SESSION_OK;
}

void tb_session_engine_destroy(tb_session_engine* engine) { delete engine; }

tb_session_status tb_session_engine_submit_v1(tb_session_engine* engine,
                                              const char* message,
                                              size_t message_len,
                                              const char** out_json,
                                              size_t* out_len) {
  if (out_json != nullptr) {
    *out_json = nullptr;
  }
  if (out_len != nullptr) {
    *out_len = 0;
  }
  if (engine == nullptr || out_json == nullptr || out_len == nullptr) {
    return TB_SESSION_INVALID_ARGUMENT;
  }
  if (engine->busy.exchange(true, std::memory_order_acquire)) {
    *out_json = kBusyJson;
    *out_len = sizeof(kBusyJson) - 1;
    return TB_SESSION_BUSY;
  }
  tb_session_status status = TB_SESSION_INTERNAL_ERROR;
  const char* fallback = nullptr;
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS)
  try {
#endif
    if (message == nullptr && message_len != 0) {
      Error error;
      error.status = TB_SESSION_INVALID_ARGUMENT;
      error.message = "message is NULL but message_len is not 0";
      engine->output = error_document(error, nullptr);
      status = error.status;
    } else {
      status = engine->submit(message, message_len);
    }
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS)
  } catch (const std::bad_alloc&) {
    status = TB_SESSION_OUT_OF_MEMORY;
    fallback = kOutOfMemoryJson;
  } catch (...) {
    status = TB_SESSION_INTERNAL_ERROR;
    fallback = kInternalJson;
  }
#endif
  if (fallback != nullptr) {
    engine->output.clear();
    engine->output.shrink_to_fit();
    *out_json = fallback;
    *out_len = std::char_traits<char>::length(fallback);
  } else {
    *out_json = engine->output.c_str();
    *out_len = engine->output.size();
  }
  engine->busy.store(false, std::memory_order_release);
  return status;
}

}  // extern "C"
