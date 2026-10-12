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
    "\"factGraceMs\":1,\"captureScrollScreenshots\":true},"
    "\"navigation\":{\"routeBarrierTimeoutMs\":4,\"routeStackLimit\":2},"
    "\"capture\":{\"budgetMs\":1,\"budgetWindowMs\":5},"
    "\"capabilities\":{\"sceneInventory\":true,\"focusChanges\":true,"
    "\"systemInput\":true,\"captureDiagnostics\":true}}}";

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

// A script of valid interaction, navigation, and capture messages. Each byte
// pair picks a message and its values; capture answers name request ids the
// engine actually issued, and timer fires name timers it armed.
class InteractionScript {
 public:
  explicit InteractionScript(tb_session_engine* engine) : engine_(engine) {}

  // Oracle: a valid message is always accepted.
  void step(uint8_t op, uint8_t value) {
    mono_us_ += (value % 8) * 1000;
    const std::string message = build(op, value);
    std::string response;
    if (submit_raw(engine_, message.data(), message.size(), &response) !=
        TB_SESSION_OK) {
      std::abort();
    }
    remember(response, "\"requestId\":\"", &issued_);
    remember(response, "\"timerId\":\"", &timers_);
  }

 private:
  std::string at() const {
    return "\"at\":{\"monoUs\":" + std::to_string(mono_us_) +
           ",\"wallUs\":" + std::to_string(mono_us_) + "}";
  }

  std::string fact(const char* type, const std::string& input) const {
    return std::string("{\"type\":\"") + type + "\"," + at() + ",\"input\":{" +
           input + "}}";
  }

  // Collects every string value of `key` in `response`.
  static void remember(const std::string& response, const std::string& key,
                       std::vector<std::string>* out) {
    for (size_t pos = response.find(key); pos != std::string::npos;
         pos = response.find(key, pos + 1)) {
      const size_t start = pos + key.size();
      const size_t end = response.find('"', start);
      out->push_back(response.substr(start, end - start));
    }
  }

  std::string timer(uint8_t value) const {
    if (!timers_.empty() && value % 4 != 0) {
      return timers_[value % timers_.size()];
    }
    static const char* const kTimer[] = {"interaction.settle.event-",
                                         "interaction.scrollEnd.event-",
                                         "navigation.deadline.",
                                         "navigation.timeout."};
    return value % 5 == 0 ? std::string("interaction.sweep")
                          : kTimer[value % 4] + std::to_string(value % 64);
  }

  std::string navigation(uint8_t value) const {
    static const char* const kKind[] = {"push", "pop", "replace", "remove"};
    static const char* const kOverlay[] = {"page", "dialog", "sheet"};
    std::string input = std::string("\"kind\":\"") + kKind[value % 4] +
                        "\",\"navigatorId\":\"" +
                        (value % 8 < 6 ? "root" : "inner") + "\"";
    if (value % 8 >= 6) input += ",\"parentNavigatorId\":\"root\"";
    if (value % 16 != 15) {
      input += ",\"route\":{\"instanceId\":\"r" + std::to_string(value % 5) +
               "\",\"name\":\"/" + std::to_string(value % 3) +
               "\",\"type\":\"T\",\"overlayKind\":\"" +
               kOverlay[value % 3] + "\",\"transitionMs\":" +
               std::to_string(value % 3) + "}";
    }
    if (value % 2 == 1) {
      input += ",\"departing\":{\"instanceId\":\"r" +
               std::to_string(value / 2 % 5) + "\"}";
    }
    return fact("navigation", input);
  }

  std::string request_id(uint8_t value) const {
    return issued_.empty() ? "capture-0" : issued_[value % issued_.size()];
  }

  std::string pointer(uint8_t value) const {
    static const char* const kPhase[] = {"down", "move", "up", "cancel"};
    const uint8_t phase = value % 4;
    std::string input = "\"pointerId\":" + std::to_string(value / 4 % 4) +
                        ",\"phase\":\"" + kPhase[phase] + "\",\"x\":" +
                        std::to_string(value * 7 % 400) + ",\"y\":" +
                        std::to_string(value * 13 % 900) +
                        ",\"device\":\"touch\"";
    if ((phase == 0 || phase == 2) && value >= 128) {  // tap evidence
      input += ",\"tap\":{\"anchor\":{\"fingerprint\":\"f\"},\"inventory\":"
               "{\"routeKey\":\"/\",\"inventoryHash\":\"h\"}}";
    }
    return fact("input.pointer", input);
  }

  std::string build(uint8_t op, uint8_t value) const {
    static const char* const kScroll[] = {"start", "update", "end"};
    static const char* const kFocus[] = {"text_input", "other", "none"};
    static const char* const kOutcome[] = {"paintUnchanged", "failed",
                                           "cancelled"};
    static const char* const kLifecycle[] = {"paused", "resumed"};
    const std::string scrollable = "\"scrollableId\":\"s" +
                                   std::to_string(value % 3) + "\"";
    const std::string id = "\"requestId\":\"" + request_id(value) + "\"";
    switch (op % 18) {
      case 0: case 1: case 2:
        return pointer(value);
      case 3:
        return fact("input.panZoom", value % 2 == 0
            ? "\"pointerId\":9,\"phase\":\"start\",\"x\":1,\"y\":1"
            : "\"pointerId\":9,\"phase\":\"end\",\"x\":1,\"y\":1");
      case 4:
        return fact("input.panZoom",
                    "\"pointerId\":9,\"phase\":\"update\",\"x\":1,\"y\":1,"
                    "\"panX\":0,\"panY\":" + std::to_string(value % 64) +
                        ",\"scale\":" +
                        std::to_string(0.5 + value % 16 / 10.0));
      case 5:
        return fact("scroll", scrollable + ",\"phase\":\"" +
                                  kScroll[value % 3] + "\",\"offset\":" +
                                  std::to_string(value) +
                                  ",\"axis\":\"vertical\","
                                  "\"maxScrollExtent\":100");
      case 6:
        return fact("scroll", scrollable + ",\"phase\":\"overscroll\"");
      case 7:
        return fact("focus",
                    std::string("\"kind\":\"") + kFocus[value % 3] + "\"");
      case 8:
        return fact("systemInput", "\"input\":\"back\"");
      case 9:
        return fact("capture.result",
                    id + ",\"outcome\":\"captured\",\"frame\":{"
                         "\"handle\":\"h\",\"width\":4,\"height\":4,"
                         "\"contentHash\":\"c" + std::to_string(value % 3) +
                         "\",\"dHash\":\"d" + std::to_string(value % 2) +
                         "\",\"structureSignature\":\"s" +
                         std::to_string(value / 2 % 2) +
                         "\",\"masked\":true,"
                         "\"byteLength\":1,\"captureMicros\":1},"
                         "\"boundaryRect\":{\"x\":0,\"y\":0,\"width\":400,"
                         "\"height\":900},\"timings\":{\"readbackMicros\":" +
                         std::to_string(value * 10) + "}");
      case 10:
        return fact("capture.result", id + ",\"outcome\":\"" +
                                          kOutcome[value % 3] + "\"");
      case 11:
        return fact("timer.fired", "\"timerId\":\"" + timer(value) + "\"");
      case 12:
        return fact("app.lifecycle",
                    std::string("\"state\":\"") + kLifecycle[value % 2] + "\"");
      case 14:
      case 15:
        return navigation(value);
      case 16:
        return fact("surface",
                    "\"boundaryRect\":{\"x\":0,\"y\":0,\"width\":" +
                        std::to_string(300 + value % 2 * 100) +
                        ",\"height\":900},\"generation\":" +
                        std::to_string(value % 3));
      case 17:
        return fact("capture.result",
                    id + ",\"outcome\":\"failed\",\"failure\":\"" +
                        (value % 2 == 0 ? "paintTimedOut" : "boundaryDetached") +
                        "\",\"timings\":{\"frameWaitMicros\":" +
                        std::to_string(value) + "}");
      default:  // end the session, or replace it with a new one
        return value % 2 == 0
                   ? fact("session.end", "")
                   : fact("session.start",
                          "\"viewport\":{\"width\":1,\"height\":1},"
                          "\"platform\":\"android\",\"sessionEpoch\":0");
    }
  }

  tb_session_engine* engine_;
  int64_t mono_us_ = 0;
  std::vector<std::string> issued_;
  std::vector<std::string> timers_;
};

void run_interaction_script(const uint8_t* data, size_t size,
                            const tb_session_engine_config_v1& config) {
  tb_session_engine* engine = nullptr;
  if (tb_session_engine_create_v1(&config, &engine) != TB_SESSION_OK) {
    std::abort();
  }
  submit(engine, kInteractionConfigure);
  submit(engine, kStart);
  InteractionScript script(engine);
  // A short script keeps the fuzzer fast; the state it reaches is the point.
  const size_t script_bytes = size < 512 ? size : 512;
  for (size_t i = 0; i + 1 < script_bytes; i += 2) {
    script.step(data[i], data[i + 1]);
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

  // 3. A script of valid interaction and navigation facts, timers, and
  //    capture answers, so that logic is reached past the decoders.
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
