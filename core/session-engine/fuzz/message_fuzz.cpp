#include "tugboat/tb_session_engine.h"

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "modules.h"

namespace {

// Puts the engine in a live session with collector delivery on (tight
// bounds, so eviction and gap paths run) so stateful messages reach session
// and delivery logic, not only the "no session" paths.
const char kConfigure[] =
    "{\"type\":\"engine.configure\",\"input\":{\"host\":{\"app\":{\"name\":"
    "\"a\",\"version\":\"1\",\"buildNumber\":\"1\",\"installationId\":\"i\","
    "\"appId\":\"x\"},\"device\":{\"id\":\"d\",\"platform\":\"android\","
    "\"screenSize\":{\"width\":1,\"height\":1},\"screenDensity\":1,"
    "\"screenDpi\":1,\"screenPixelDensity\":1},\"ip\":{\"ip\":\"0\"},"
    "\"locale\":{}},\"limits\":{\"maxEvents\":4,\"maxFrames\":2},"
    "\"collector\":{\"enabled\":true,\"batchSize\":2,\"maxPendingEvents\":3,"
    "\"maxPendingBatches\":1,\"maxPendingFrames\":2,\"frameChunk\":2,"
    "\"reportEventLaneGaps\":true}}}";
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

// Answers delivery request `http-<n>` with a status picked by `seed`, so
// the fuzzed messages that follow run against accepted, retried, and dropped
// deliveries.
std::string transport_result(int n, uint8_t seed) {
  static const int kStatuses[] = {202, 202, 400, 401, 408, 429, 500, 200};
  return "{\"type\":\"transport.result\",\"at\":{\"monoUs\":1,"
         "\"wallUs\":1},\"input\":{\"requestId\":\"http-" +
         std::to_string(n) + "\",\"outcome\":\"http\",\"status\":" +
         std::to_string(kStatuses[seed % 8]) +
         ",\"body\":\"{\\\"sessionId\\\":\\\"s\\\"}\"}}";
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

// A script of valid interaction messages. Each byte pair picks a message and
// its values; capture answers name request ids the engine actually issued.
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
    remember_requests(response);
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

  void remember_requests(const std::string& response) {
    static const std::string kKey = "\"requestId\":\"";
    for (size_t pos = response.find(kKey); pos != std::string::npos;
         pos = response.find(kKey, pos + 1)) {
      const size_t start = pos + kKey.size();
      const size_t end = response.find('"', start);
      issued_.push_back(response.substr(start, end - start));
    }
  }

  std::string request_id(uint8_t value) const {
    return issued_.empty() ? "capture_request-0"
                           : issued_[value % issued_.size()];
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
    switch (op % 14) {
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
                         "\"contentHash\":\"c\",\"masked\":true,"
                         "\"byteLength\":1,\"captureMicros\":1},"
                         "\"boundaryRect\":{\"x\":0,\"y\":0,\"width\":400,"
                         "\"height\":900}");
      case 10:
        return fact("capture.result", id + ",\"outcome\":\"" +
                                          kOutcome[value % 3] + "\"");
      case 11: {
        static const char* const kTimer[] = {"interaction.settle.event-",
                                             "interaction.scrollEnd.event-"};
        const std::string timer =
            value % 3 == 0 ? std::string("interaction.sweep")
                           : kTimer[value % 2] + std::to_string(value % 64);
        return fact("timer.fired", "\"timerId\":\"" + timer + "\"");
      }
      case 12:
        return fact("app.lifecycle",
                    std::string("\"state\":\"") + kLifecycle[value % 2] + "\"");
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
    submit(engine, transport_result(0, 0));
    submit(engine, timed);
    submit(engine, transport_result(1, data[0]));
    submit(engine, "{\"type\":\"batch\",\"messages\":[" + timed + "," +
                       timed + "]}");
    submit(engine, transport_result(2, data[0] >> 3));
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
