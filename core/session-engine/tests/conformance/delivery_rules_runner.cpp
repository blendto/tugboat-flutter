#include "delivery_rules_runner.h"

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "engine_client.h"

namespace conformance {

namespace {

using Kind = Json::Kind;

constexpr char kHost[] =
    R"({"app":{"name":"Example App","version":"2.4.0","buildNumber":"240","installationId":"inst-0001","appId":"com.example.app"},"device":{"id":"device-0001","platform":"android","screenSize":{"width":412.0,"height":915.0},"screenDensity":2.625,"screenDpi":420,"screenPixelDensity":2.625},"ip":{"ip":"203.0.113.7"},"locale":{},"configuredUserId":null})";

constexpr int64_t kStartMonoUs = 5000000;
constexpr int64_t kStartWallUs = 1781827200000000;
constexpr int64_t kActionGapUs = 10000;

// The collector settings a rules fixture may set (README "delivery.rules").
const char* const kCollectorKeys[] = {
    "batchSize",        "maxPendingEvents",     "maxPendingBatches",
    "maxPendingFrames", "maxPendingFrameBytes"};

// The host's per-session `idSeed`: 64 lowercase hex digits, one digit value
// per session so every session of a fixture gets its own ids.
std::string id_seed(int64_t epoch) {
  return std::string(64, "0123456789abcdef"[epoch % 16]);
}

std::string quote(const std::string& text) {
  std::string out = "\"";
  for (const char c : text) {
    if (c == '"' || c == '\\') {
      out += '\\';
    }
    out += c;
  }
  return out + "\"";
}

const Json* member(const Json& object, const char* key) {
  return object.is(Kind::kObject) ? object.find(key) : nullptr;
}

// One delivery rules fixture on a fresh engine.
class Run {
 public:
  Run(const Json& fixture, const std::string& source,
      const std::string& relative)
      : fixture_(fixture), source_(source), relative_(relative) {}

  bool run();

 private:
  bool fail(const std::string& message) {
    std::printf("FAIL %s\n  %s\n", relative_.c_str(), message.c_str());
    return false;
  }

  std::string at_json() const {
    return "{\"monoUs\":" + std::to_string(mono_us_) + ",\"wallUs\":" +
           std::to_string(kStartWallUs + (mono_us_ - kStartMonoUs)) + "}";
  }

  // Submits one message; parses the reply into `*reply`.
  bool send(const std::string& message, Json* reply) {
    reply_text_ = engine_.submit(message).json;
    std::string error;
    *reply = Json();
    if (!parse(reply_text_, reply, &error)) {
      return fail("unreadable response (" + error + "): " + reply_text_);
    }
    if (reply->find("error") != nullptr) {
      return fail("engine rejected " + message + ": " + reply_text_);
    }
    return true;
  }

  bool act(const std::string& type, const std::string& input, Json* reply) {
    mono_us_ += kActionGapUs;
    return send("{\"type\":\"" + type + "\",\"at\":" + at_json() +
                    ",\"input\":" + input + "}",
                reply);
  }

  // Reads the effects of `reply`: the one request in flight (summarised into
  // `sent_`) and the latest capture request.
  bool read_effects(const Json& reply);
  std::string summarize_events(const std::string& json_body);

  bool answer(const Json& action, Json* reply);
  bool capture_frame(const std::string& request, int64_t bytes, Json* reply);
  bool swipe(Json* reply);
  bool run_action(const Json& action, Json* reply);
  bool new_session(Json* reply);
  bool lifecycle_frame(int64_t bytes, Json* reply);
  bool health(std::string* out);

  const Json& fixture_;
  const std::string& source_;
  const std::string& relative_;
  EngineClient engine_;
  std::string reply_text_;
  int64_t mono_us_ = kStartMonoUs;
  std::string in_flight_;
  std::string capture_request_;
  int64_t next_frame_ = 1;
  int64_t epoch_ = 0;
  std::vector<std::string> sent_;
};

std::string Run::summarize_events(const std::string& json_body) {
  Json body;
  std::string error;
  if (!parse(json_body, &body, &error)) {
    return "\"unreadable\"";
  }
  const Json* events = member(body, "events");
  std::string out;
  if (events == nullptr) {
    return out;
  }
  for (const Json& event : events->items) {
    const Json* type = member(event, "eventType");
    const Json* payload = member(event, "payload");
    std::string name = type == nullptr ? "?" : type->text;
    if (name == "external_event" && payload != nullptr &&
        member(*payload, "name") != nullptr) {
      name = member(*payload, "name")->text;
    } else if (name == "capture_diagnostic" && payload != nullptr) {
      const Json* component = member(*payload, "component");
      const Json* result = member(*payload, "result");
      name = "diag:" + (component == nullptr ? "?" : component->text) + ":" +
             (result == nullptr ? "?" : result->text);
    }
    out += (out.empty() ? "" : ",") + quote(name);
  }
  return out;
}

bool Run::read_effects(const Json& reply) {
  const Json* effects = reply.find("effects");
  if (effects == nullptr) {
    return true;
  }
  for (const Json& effect : effects->items) {
    const Json* type = effect.find("type");
    if (type == nullptr) {
      continue;
    }
    if (type->text == "capture.request") {
      capture_request_ = effect.find("requestId")->text;
    } else if (type->text == "http.send") {
      in_flight_ = effect.find("requestId")->text;
      const std::string lane = effect.find("lane")->text;
      if (lane == "events") {
        sent_.push_back("{\"lane\":\"events\",\"events\":[" +
                        summarize_events(effect.find("jsonBody")->text) +
                        "]}");
      } else if (lane == "frames") {
        std::string frames;
        const Json* files = member(*effect.find("multipart"), "frames");
        for (const Json& file : files->items) {
          // The handle is `h-<ordinal>`.
          frames += (frames.empty() ? "" : ",") + file.find("handle")->text.substr(2);
        }
        sent_.push_back("{\"lane\":\"frames\",\"frames\":[" + frames + "]}");
      } else {
        Json body;
        std::string error;
        std::string event_type = "?";
        if (parse(effect.find("jsonBody")->text, &body, &error) &&
            member(body, "eventType") != nullptr) {
          event_type = member(body, "eventType")->text;
        }
        sent_.push_back("{\"lane\":\"lifecycle\",\"eventType\":" +
                        quote(event_type) + "}");
      }
    }
  }
  return true;
}

bool Run::answer(const Json& action, Json* reply) {
  if (in_flight_.empty()) {
    return fail("answer: no request is in flight");
  }
  const Json* outcome = member(action, "outcome");
  const Json* status = member(action, "status");
  std::string input = "{\"requestId\":" + quote(in_flight_) + ",\"outcome\":" +
                      quote(outcome == nullptr ? "http" : outcome->text);
  if (status != nullptr) {
    input += ",\"status\":" + status->text;
  }
  input += "}";
  in_flight_.clear();
  mono_us_ += kActionGapUs;
  return send("{\"type\":\"transport.result\",\"at\":" + at_json() +
                  ",\"input\":" + input + "}",
              reply) &&
         read_effects(*reply);
}

bool Run::capture_frame(const std::string& request, int64_t bytes,
                        Json* reply) {
  const std::string handle = "h-" + std::to_string(next_frame_++);
  return act("capture.result",
             "{\"requestId\":" + quote(request) +
                 ",\"outcome\":\"captured\",\"frame\":{\"handle\":" +
                 quote(handle) + ",\"width\":1080,\"height\":2400," +
                 "\"contentHash\":" + quote("hash-" + handle) +
                 ",\"masked\":true,\"byteLength\":" + std::to_string(bytes) +
                 ",\"captureMicros\":12000}}",
             reply) &&
         read_effects(*reply);
}

// A swipe: the interaction event that follows its capture references the
// frame.
bool Run::swipe(Json* reply) {
  capture_request_.clear();
  for (const char* phase : {"down", "move", "up"}) {
    const char* y = std::string(phase) == "down" ? "100.0" : "300.0";
    if (!act("input.pointer",
             std::string("{\"pointerId\":1,\"phase\":\"") + phase +
                 "\",\"x\":100.0,\"y\":" + y + ",\"device\":\"touch\"}",
             reply) ||
        !read_effects(*reply)) {
      return false;
    }
  }
  if (capture_request_.empty()) {
    return fail("a swipe did not ask for a capture");
  }
  return true;
}

// The app goes to the background and returns: the engine asks for a lifecycle
// capture, whose frame no event references.
bool Run::lifecycle_frame(int64_t bytes, Json* reply) {
  capture_request_.clear();
  for (const char* state : {"paused", "resumed"}) {
    if (!act("app.lifecycle", std::string("{\"state\":\"") + state + "\"}",
             reply) ||
        !read_effects(*reply)) {
      return false;
    }
  }
  if (capture_request_.empty()) {
    return fail("resuming did not ask for a capture");
  }
  return capture_frame(capture_request_, bytes, reply);
}

// A new session replaces the live one; its collector handshake is the next
// lifecycle answer.
bool Run::new_session(Json* reply) {
  capture_request_.clear();
  ++epoch_;
  if (!act("session.start",
           "{\"viewport\":{\"width\":412.0,\"height\":915.0},"
           "\"platform\":\"android\",\"sessionEpoch\":" +
               std::to_string(epoch_) + ",\"idSeed\":" +
               quote(id_seed(epoch_)) + "}",
           reply) ||
      !read_effects(*reply)) {
    return false;
  }
  return capture_request_.empty() ||
         (act("capture.result",
              "{\"requestId\":" + quote(capture_request_) +
                  ",\"outcome\":\"failed\"}",
              reply) &&
          read_effects(*reply));
}

bool Run::run_action(const Json& action, Json* reply) {
  if (member(action, "newSession") != nullptr) {
    return new_session(reply);
  }
  if (const Json* frame = member(action, "lifecycleFrame")) {
    const Json* bytes = member(*frame, "bytes");
    return lifecycle_frame(bytes == nullptr ? 48000 : std::stoll(bytes->text),
                           reply);
  }
  if (const Json* name = member(action, "event")) {
    return act("event.record",
               "{\"eventType\":\"external_event\",\"stream\":\"evidence\","
               "\"attachActionContext\":false,\"data\":{\"name\":" +
                   quote(name->text) + "}}",
               reply) &&
           read_effects(*reply);
  }
  if (const Json* frame = member(action, "frame")) {
    const Json* bytes = member(*frame, "bytes");
    const int64_t size = bytes == nullptr ? 48000 : std::stoll(bytes->text);
    return swipe(reply) && capture_frame(capture_request_, size, reply);
  }
  if (const Json* frame = member(action, "initialFrame")) {
    const Json* bytes = member(*frame, "bytes");
    const int64_t size = bytes == nullptr ? 48000 : std::stoll(bytes->text);
    return capture_frame("capture-0", size, reply);
  }
  if (member(action, "flush") != nullptr) {
    return act("transport.flush", "{}", reply) && read_effects(*reply);
  }
  if (const Json* answer_action = member(action, "answer")) {
    return answer(*answer_action, reply);
  }
  return fail("unknown action");
}

bool Run::health(std::string* out) {
  Json reply;
  if (!send("{\"type\":\"engine.health\",\"input\":{}}", &reply)) {
    return false;
  }
  const Json* result = reply.find("result");
  const Json* health = result == nullptr ? nullptr : member(*result, "health");
  const Json* sinks = health == nullptr ? nullptr : member(*health, "sinks");
  if (sinks == nullptr) {
    return fail("engine.health has no result: " + reply_text_);
  }
  *out = "{\"pending\":" + member(*sinks, "pending")->text +
         ",\"accepted\":" + member(*sinks, "accepted")->text +
         ",\"dropped\":" + member(*sinks, "dropped")->text + "}";
  return true;
}

bool Run::run() {
  const Json& input = *fixture_.find("input");
  const Json& expected = *fixture_.find("expected");
  const Json* collector = member(input, "collector");
  const Json* steps = member(input, "steps");
  const Json* expected_steps = member(expected, "steps");
  if (collector == nullptr || !collector->is(Kind::kObject) ||
      steps == nullptr || !steps->is(Kind::kArray) || steps->items.empty() ||
      expected_steps == nullptr || !expected_steps->is(Kind::kArray) ||
      expected_steps->items.size() != steps->items.size()) {
    return fail("input.collector, input.steps and expected.steps (one per "
                "step) are required");
  }
  std::string settings = "\"enabled\":true";
  for (const auto& setting : collector->members) {
    bool known = false;
    for (const char* key : kCollectorKeys) {
      known = known || setting.first == key;
    }
    if (!known) {
      return fail("unknown collector setting " + setting.first);
    }
    settings += ",\"" + setting.first + "\":" + source_of(setting.second, source_);
  }
  Json reply;
  if (!send("{\"type\":\"engine.configure\",\"input\":{\"host\":" +
                std::string(kHost) + ",\"collector\":{" + settings + "}}}",
            &reply)) {
    return false;
  }
  // Setup: start the session and complete the collector handshake. Only a
  // fixture whose first action is `initialFrame` leaves the initial capture
  // for it to answer.
  mono_us_ = kStartMonoUs;
  if (!send("{\"type\":\"session.start\",\"at\":" + at_json() +
                ",\"input\":{\"viewport\":{\"width\":412.0,\"height\":915.0},"
                "\"platform\":\"android\",\"sessionEpoch\":0,\"idSeed\":" +
                quote(id_seed(0)) + "}}",
            &reply) ||
      !read_effects(reply)) {
    return false;
  }
  const bool initial_frame =
      member(*member(steps->items[0], "do"), "initialFrame") != nullptr;
  if (!initial_frame &&
      (!act("capture.result",
            "{\"requestId\":\"capture-0\",\"outcome\":\"failed\"}", &reply) ||
       !read_effects(reply))) {
    return false;
  }
  mono_us_ += kActionGapUs;
  const std::string handshake = in_flight_;
  in_flight_.clear();
  if (!send("{\"type\":\"transport.result\",\"at\":" + at_json() +
                ",\"input\":{\"requestId\":" + quote(handshake) +
                ",\"outcome\":\"http\",\"status\":202,\"body\":\"{\\\"sessionId\\\":\\\"srv-1\\\"}\"}}",
            &reply) ||
      !read_effects(reply)) {
    return false;
  }
  sent_.clear();

  for (size_t i = 0; i < steps->items.size(); ++i) {
    const Json* action = member(steps->items[i], "do");
    if (action == nullptr) {
      return fail("step " + std::to_string(i) + " has no do");
    }
    sent_.clear();
    if (!run_action(*action, &reply)) {
      return false;
    }
    std::string sent;
    for (const std::string& request : sent_) {
      sent += (sent.empty() ? "" : ",") + request;
    }
    std::string counts;
    if (!health(&counts)) {
      return false;
    }
    const std::string actual_text =
        "{\"sent\":[" + sent + "],\"health\":" + counts + "}";
    Json actual;
    std::string error;
    if (!parse(actual_text, &actual, &error)) {
      return fail("internal: " + error);
    }
    Diff diff(source_, actual_text);
    diff.compare(expected_steps->items[i], actual,
                 "$.expected.steps[" + std::to_string(i) + "]");
    if (!diff.empty()) {
      std::printf("FAIL %s step %zu does not match the engine:\n",
                  relative_.c_str(), i);
      for (const std::string& line : diff.lines()) {
        std::printf("  %s\n", line.c_str());
      }
      std::printf("  actual: %s\n", actual_text.c_str());
      return false;
    }
  }
  std::printf("ok   %s\n", relative_.c_str());
  return true;
}

}  // namespace

bool run_delivery_rules(const Json& fixture, const std::string& source,
                        const std::string& relative) {
  return Run(fixture, source, relative).run();
}

}  // namespace conformance
