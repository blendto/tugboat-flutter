#include "tugboat/tb_session_engine.h"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

// Message types the fuzzer can wrap raw input in, so most inputs reach the
// field decoders instead of failing at the envelope.
const char* const kTypes[] = {
    "fingerprint.identityParts",
    "fingerprint.labelHash",
    "collector.event",
    "collector.sessionLifecycle",
};

void submit(tb_session_engine* engine, const char* data, size_t size) {
  const char* out = nullptr;
  size_t len = 0;
  const tb_session_status status =
      tb_session_engine_submit_v1(engine, data, size, &out, &len);
  // Contract: with valid pointers the response is always a NUL-terminated
  // JSON object, success or not.
  if (out == nullptr || out[len] != '\0' || len < 2 || out[0] != '{' ||
      out[len - 1] != '}') {
    std::abort();
  }
  if (status != TB_SESSION_OK && std::strstr(out, "\"error\"") == nullptr) {
    std::abort();
  }
}

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  tb_session_engine_config_v1 config{};
  config.abi_version = TB_SESSION_ENGINE_ABI_VERSION;
  config.max_depth = 32;
  tb_session_engine* engine = nullptr;
  if (tb_session_engine_create_v1(&config, &engine) != TB_SESSION_OK) {
    std::abort();
  }
  const char* text = reinterpret_cast<const char*>(data);

  // 1. Raw bytes as a whole message.
  submit(engine, text, size);

  // 2. The first byte picks a message type; the rest is its `input`.
  if (size > 0) {
    const std::string message =
        std::string("{\"type\":\"") + kTypes[data[0] % 4] +
        "\",\"input\":" + std::string(text + 1, size - 1) + "}";
    submit(engine, message.data(), message.size());
  }

  // 3. NULL / zero-length edge cases on the same handle.
  submit(engine, nullptr, 0);
  const char* out = nullptr;
  size_t len = 0;
  tb_session_engine_submit_v1(engine, text, size, nullptr, &len);
  tb_session_engine_submit_v1(engine, text, size, &out, nullptr);
  tb_session_engine_submit_v1(nullptr, text, size, &out, &len);

  tb_session_engine_destroy(engine);
  return 0;
}
