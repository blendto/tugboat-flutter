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
    "engine.configure",
    "session.snapshot",
    "session.start",
    "session.end",
    "app.lifecycle",
    "identity.set",
    "locale.set",
    "event.record",
    "timer.fired",
};
constexpr size_t kTypeCount = sizeof(kTypes) / sizeof(kTypes[0]);

// Puts the engine in a live session so stateful messages reach session
// logic, not only the "no session" paths.
const char kConfigure[] =
    "{\"type\":\"engine.configure\",\"input\":{\"host\":{\"app\":{\"name\":"
    "\"a\",\"version\":\"1\",\"buildNumber\":\"1\",\"installationId\":\"i\","
    "\"appId\":\"x\"},\"device\":{\"id\":\"d\",\"platform\":\"android\","
    "\"screenSize\":{\"width\":1,\"height\":1},\"screenDensity\":1,"
    "\"screenDpi\":1,\"screenPixelDensity\":1},\"ip\":{\"ip\":\"0\"},"
    "\"locale\":{}},\"limits\":{\"maxEvents\":4}}}";
const char kStart[] =
    "{\"type\":\"session.start\",\"at\":{\"monoUs\":0,\"wallUs\":0},"
    "\"input\":{\"viewport\":{\"width\":1,\"height\":1},\"platform\":"
    "\"android\",\"sessionEpoch\":0}}";

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

void submit(tb_session_engine* engine, const std::string& message) {
  submit(engine, message.data(), message.size());
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

  // 1. Raw bytes as a whole message (envelopes and batches).
  submit(engine, text, size);

  // 2. The first byte picks a message type; the rest is its `input`. It is
  //    sent with and without `at`, before and during a session.
  if (size > 0) {
    const std::string type = kTypes[data[0] % kTypeCount];
    const std::string input(text + 1, size - 1);
    const std::string bare =
        "{\"type\":\"" + type + "\",\"input\":" + input + "}";
    const std::string timed = "{\"type\":\"" + type +
                              "\",\"at\":{\"monoUs\":" +
                              std::to_string(data[0]) +
                              ",\"wallUs\":1},\"input\":" + input + "}";
    submit(engine, bare);
    submit(engine, kConfigure);
    submit(engine, kStart);
    submit(engine, timed);
    submit(engine, "{\"type\":\"batch\",\"messages\":[" + timed + "," +
                       timed + "]}");
    submit(engine, "{\"type\":\"session.snapshot\",\"input\":{}}");
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
