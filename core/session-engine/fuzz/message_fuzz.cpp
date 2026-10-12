#include "tugboat/tb_session_engine.h"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "modules.h"

namespace {

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
const char kSnapshot[] = "{\"type\":\"session.snapshot\",\"input\":{}}";
// The interaction script runs with every interaction capability on and
// short windows, so its timers and captures resolve within a script.
const char kInteractionConfigure[] =
    "{\"type\":\"engine.configure\",\"input\":{\"host\":{\"app\":{\"name\":"
    "\"a\",\"version\":\"1\",\"buildNumber\":\"1\",\"installationId\":\"i\","
    "\"appId\":\"x\"},\"device\":{\"id\":\"d\",\"platform\":\"android\","
    "\"screenSize\":{\"width\":1,\"height\":1},\"screenDensity\":1,"
    "\"screenDpi\":1,\"screenPixelDensity\":1},\"ip\":{\"ip\":\"0\"},"
    "\"locale\":{}},\"limits\":{\"maxEvents\":16,\"maxFrames\":2,"
    "\"maxScrollSamples\":2},\"interaction\":{\"claimWindowMs\":3,"
    "\"settleDelayMs\":2,\"maxReleased\":2,\"scrollEndCaptureDelayMs\":1,"
    "\"captureScrollSamples\":true,\"scrollCaptureIntervalMs\":1,"
    "\"factGraceMs\":1},\"capabilities\":{\"sceneInventory\":true,"
    "\"focusChanges\":true,\"systemInput\":true}}}";

tb_session_status submit_raw(tb_session_engine* engine, const char* data,
                             size_t size, std::string* response) {
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
  if (response != nullptr) {
    response->assign(out, len);
  }
  return status;
}

std::string snapshot(tb_session_engine* engine) {
  std::string json;
  if (submit_raw(engine, kSnapshot, sizeof(kSnapshot) - 1, &json) !=
      TB_SESSION_OK) {
    std::abort();
  }
  return json;
}

// Oracle: a rejected message leaves the session unchanged.
void submit(tb_session_engine* engine, const char* data, size_t size) {
  const std::string before = snapshot(engine);
  if (submit_raw(engine, data, size, nullptr) != TB_SESSION_OK &&
      snapshot(engine) != before) {
    std::abort();
  }
}

void submit(tb_session_engine* engine, const std::string& message) {
  submit(engine, message.data(), message.size());
}

// One valid interaction message chosen by `op`, with values from `value`.
std::string interaction_fact(uint8_t op, uint8_t value, int64_t mono_us) {
  const std::string head = "\",\"at\":{\"monoUs\":" + std::to_string(mono_us) +
                           "},\"input\":{";
  const std::string id = std::to_string(value % 4);
  const std::string xy = ",\"x\":" + std::to_string(value * 7 % 400) +
                         ",\"y\":" + std::to_string(value * 13 % 900);
  static const char* const kPointer[] = {"down", "move", "up", "cancel"};
  static const char* const kPanZoom[] = {"start", "end"};
  static const char* const kScroll[] = {"start", "update", "end"};
  static const char* const kFocus[] = {"text_input", "other", "none"};
  static const char* const kOutcome[] = {"paintUnchanged", "failed",
                                         "cancelled"};
  static const char* const kTimer[] = {"interaction.sweep",
                                       "interaction.settle.event-",
                                       "interaction.scrollEnd.event-"};
  const std::string n = std::to_string(value % 48);
  switch (op % 10) {
    case 0:
      return "{\"type\":\"input.pointer" + head + "\"pointerId\":" + id +
             ",\"phase\":\"" + kPointer[value % 4] + "\"" + xy +
             ",\"device\":\"touch\"}}";
    case 1:
      return "{\"type\":\"input.panZoom" + head + "\"pointerId\":9,\"phase\":\"" +
             kPanZoom[value % 2] + "\"" + xy + "}}";
    case 2:
      return "{\"type\":\"input.panZoom" + head +
             "\"pointerId\":9,\"phase\":\"update\",\"x\":1,\"y\":1,\"panX\":0,"
             "\"panY\":" + std::to_string(value % 64) + ",\"scale\":" +
             std::to_string(0.5 + (value % 16) / 10.0) + "}}";
    case 3:
      return "{\"type\":\"scroll" + head + "\"scrollableId\":\"s" + id +
             "\",\"phase\":\"" + kScroll[value % 3] + "\",\"offset\":" +
             std::to_string(value) + ",\"axis\":\"vertical\",\"maxScrollExtent\":"
             "100}}";
    case 4:
      return "{\"type\":\"scroll" + head + "\"scrollableId\":\"s" + id +
             "\",\"phase\":\"overscroll\"}}";
    case 5:
      return "{\"type\":\"focus" + head + "\"kind\":\"" + kFocus[value % 3] +
             "\"}}";
    case 6:
      return "{\"type\":\"systemInput" + head + "\"input\":\"back\"}}";
    case 7:
      return "{\"type\":\"capture.result" + head +
             "\"requestId\":\"capture_request-" + n +
             "\",\"outcome\":\"captured\",\"frame\":{\"handle\":\"h\",\"width\":"
             "4,\"height\":4,\"contentHash\":\"c\",\"masked\":true,\"byteLength\":"
             "1,\"captureMicros\":1},\"boundaryRect\":{\"x\":0,\"y\":0,\"width\":"
             "400,\"height\":900}}}";
    case 8:
      return "{\"type\":\"capture.result" + head +
             "\"requestId\":\"capture_request-" + n + "\",\"outcome\":\"" +
             kOutcome[value % 3] + "\"}}";
    default: {
      const std::string timer = value % 3 == 0
                                    ? std::string(kTimer[0])
                                    : kTimer[value % 3] + n;
      return "{\"type\":\"timer.fired" + head + "\"timerId\":\"" + timer +
             "\"}}";
    }
  }
}

// Oracle: valid interaction messages are always accepted.
void run_interaction_script(const uint8_t* data, size_t size,
                            const tb_session_engine_config_v1& config) {
  tb_session_engine* engine = nullptr;
  if (tb_session_engine_create_v1(&config, &engine) != TB_SESSION_OK) {
    std::abort();
  }
  submit(engine, kInteractionConfigure);
  submit(engine, kStart);
  int64_t mono_us = 0;
  // A short script keeps the fuzzer fast; the state it reaches is the point.
  const size_t script_bytes = size < 512 ? size : 512;
  for (size_t i = 0; i + 1 < script_bytes; i += 2) {
    mono_us += (data[i + 1] % 8) * 1000;
    const std::string message = interaction_fact(data[i], data[i + 1], mono_us);
    if (submit_raw(engine, message.data(), message.size(), nullptr) !=
        TB_SESSION_OK) {
      std::abort();
    }
    if (data[i] >= 0xfe) {  // background and foreground the app
      submit(engine, "{\"type\":\"app.lifecycle\",\"at\":{\"monoUs\":" +
                         std::to_string(mono_us) + "},\"input\":{\"state\":\"" +
                         (data[i] == 0xff ? "paused" : "resumed") + "\"}}");
    }
  }
  snapshot(engine);
  tb_session_engine_destroy(engine);
}

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  // Every registered message type, so new modules are fuzzed too.
  static const std::vector<std::string> types =
      tugboat::engine::module_registry().types();
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
    const std::string& type = types[data[0] % types.size()];
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
  }

  // 3. A script of valid interaction facts, timers, and capture answers,
  //    so the interaction logic is reached past the decoders.
  run_interaction_script(data, size, config);

  // 4. NULL / zero-length edge cases on the same handle.
  submit(engine, nullptr, 0);
  const char* out = nullptr;
  size_t len = 0;
  tb_session_engine_submit_v1(engine, text, size, nullptr, &len);
  tb_session_engine_submit_v1(engine, text, size, &out, nullptr);
  tb_session_engine_submit_v1(nullptr, text, size, &out, &len);

  tb_session_engine_destroy(engine);
  return 0;
}
