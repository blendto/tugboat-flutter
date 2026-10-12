// Unit tests for the stateful engine internals that scenario fixtures cannot
// reach: the module registry (timer routing, teardown stages, lifecycle
// hooks), the lifecycle transition table, record and effect JSON, and
// configuration across sessions. Behaviour visible through the public
// protocol is pinned by conformance/engine/scenario/ instead.
#include <string>
#include <utility>
#include <vector>

#include "clock.h"
#include "engine.h"
#include "json.h"
#include "lifecycle.h"
#include "module_registry.h"
#include "modules.h"
#include "output.h"
#include "teardown.h"
#include "unit_support.h"

namespace {

using tugboat::engine::At;
using tugboat::engine::CaptureRequest;
using tugboat::engine::Engine;
using tugboat::engine::EngineState;
using tugboat::engine::Error;
using tugboat::engine::EventRecord;
using tugboat::engine::Frame;
using tugboat::engine::FrameRecord;
using tugboat::engine::FrameRelease;
using tugboat::engine::FrameTrigger;
using tugboat::engine::HealthRecord;
using tugboat::engine::HttpLane;
using tugboat::engine::HttpSend;
using tugboat::engine::LifecycleSignal;
using tugboat::engine::LifecycleState;
using tugboat::engine::ModuleRegistry;
using tugboat::engine::MultipartBody;
using tugboat::engine::Output;
using tugboat::engine::TeardownCause;
using tugboat::engine::TeardownStage;
using tugboat::engine::TimerCancel;
using tugboat::engine::TimerSchedule;
using tugboat::engine::Timers;
using tugboat::engine::Value;
using unit::contains;
using unit::make_engine;
using unit::submit;

const char kHost[] =
    "{\"app\":{\"name\":\"a\",\"version\":\"1\",\"buildNumber\":\"7\","
    "\"installationId\":\"i\",\"appId\":\"x\"},\"device\":{\"id\":\"d\","
    "\"platform\":\"android\",\"screenSize\":{\"width\":1,\"height\":1},"
    "\"screenDensity\":1,\"screenDpi\":1,\"screenPixelDensity\":1},"
    "\"ip\":{\"ip\":\"0\"},\"locale\":{}";

std::string configure(const std::string& configured_user_id) {
  return std::string("{\"type\":\"engine.configure\",\"input\":{\"host\":") +
         kHost + ",\"configuredUserId\":" + configured_user_id + "}}}";
}

std::string start_message(int64_t mono_us) {
  return "{\"type\":\"session.start\",\"at\":{\"monoUs\":" +
         std::to_string(mono_us) + ",\"wallUs\":" + std::to_string(mono_us) +
         "},\"input\":{\"viewport\":{\"width\":1,\"height\":2},"
         "\"platform\":\"android\",\"sessionEpoch\":0}}";
}

std::string fact(const std::string& type, int64_t mono_us,
                 const std::string& input) {
  return "{\"type\":\"" + type + "\",\"at\":{\"monoUs\":" +
         std::to_string(mono_us) + ",\"wallUs\":" + std::to_string(mono_us) +
         "},\"input\":" + input + "}";
}

bool handle(Engine* engine, const std::string& text, std::string* json) {
  Value message;
  tugboat::engine::ParseError parse_error;
  if (!tugboat::engine::parse_json(text, 64, &message, &parse_error)) {
    return false;
  }
  Value response;
  Error error;
  if (!engine->handle(message, &response, &error)) {
    if (json != nullptr) {
      *json = error.path + ": " + error.message;
    }
    return false;
  }
  if (json != nullptr) {
    tugboat::engine::write_json(response, json, nullptr);
  }
  return true;
}

bool handle(Engine* engine, const std::string& text) {
  return handle(engine, text, nullptr);
}

std::string to_json(const Value& value) {
  std::string out;
  tugboat::engine::write_json(value, &out, nullptr);
  return out;
}

// --------------------------------------------------------- tracing modules

std::vector<std::string> g_trace;

const char* cause_letter(TeardownCause cause) {
  switch (cause) {
    case TeardownCause::kLifecycle: return "L";
    case TeardownCause::kSessionEnd: return "E";
    case TeardownCause::kDispose: return "D";
    case TeardownCause::kSessionReplacement: return "R";
  }
  return "?";
}

template <TeardownStage kStage>
void trace_stage(TeardownCause cause, EngineState*, Output*) {
  static const char* const kNames[] = {"tap",      "route",    "capture",
                                       "pointers", "released", "gestures",
                                       "input"};
  g_trace.push_back(std::string(cause_letter(cause)) + ":" +
                    kNames[static_cast<size_t>(kStage)]);
}

void hook_started(const At&, EngineState*, Output*) {
  g_trace.push_back("started");
}
void hook_backgrounded(const At&, EngineState*, Output*) {
  g_trace.push_back("backgrounded");
}
void hook_foregrounded(const At&, EngineState*, Output*) {
  g_trace.push_back("foregrounded");
}
void hook_ending(const At&, EngineState*, Output*) {
  g_trace.push_back("ending");
}

void fired_short(const std::string& id, const At& at, EngineState*,
                 Output* out) {
  g_trace.push_back("short:" + id + "@" + std::to_string(at.mono_us));
  out->effects.push_back(TimerCancel{"echo"});
}
void fired_long(const std::string& id, const At&, EngineState*, Output*) {
  g_trace.push_back("long:" + id);
}

ModuleRegistry tracing_registry() {
  ModuleRegistry registry = tugboat::engine::build_module_registry();
  registry.add_teardown(TeardownStage::kTapSettles,
                        trace_stage<TeardownStage::kTapSettles>);
  registry.add_teardown(TeardownStage::kRouteCaptures,
                        trace_stage<TeardownStage::kRouteCaptures>);
  registry.add_teardown(TeardownStage::kCaptureWork,
                        trace_stage<TeardownStage::kCaptureWork>);
  registry.add_teardown(TeardownStage::kPendingPointers,
                        trace_stage<TeardownStage::kPendingPointers>);
  registry.add_teardown(TeardownStage::kReleasedTransactions,
                        trace_stage<TeardownStage::kReleasedTransactions>);
  registry.add_teardown(TeardownStage::kGestureAndScroll,
                        trace_stage<TeardownStage::kGestureAndScroll>);
  registry.add_teardown(TeardownStage::kInputObservations,
                        trace_stage<TeardownStage::kInputObservations>);
  registry.on_session_started(hook_started);
  registry.on_backgrounded(hook_backgrounded);
  registry.on_foregrounded(hook_foregrounded);
  registry.on_session_ending(hook_ending);
  registry.add_timers("test.", fired_short);
  registry.add_timers("test.long.", fired_long);
  return registry;
}

std::string take_trace() {
  std::string out;
  for (const std::string& item : g_trace) {
    out += (out.empty() ? "" : " ") + item;
  }
  g_trace.clear();
  return out;
}

// ------------------------------------------------------------------ timers

void test_timers_deadlines() {
  Timers timers;
  Output out;
  timers.schedule("a", 100, &out);
  timers.schedule("a", 300, &out);  // replaces
  CHECK(out.effects.size() == 2);
  CHECK(std::get<TimerSchedule>(out.effects[1]).at_mono_us == 300);
  // A fire stamped before the current deadline is stale.
  CHECK(!timers.take_due("a", 200));
  CHECK(timers.armed("a"));
  CHECK(!timers.take_due("unknown", 1000));
  CHECK(timers.take_due("a", 300));
  CHECK(!timers.armed("a"));
  CHECK(!timers.take_due("a", 400));  // fires once

  Output cancel;
  timers.cancel("never-armed", &cancel);
  CHECK(cancel.effects.empty());
  timers.schedule("b", 10, &cancel);
  timers.cancel("b", &cancel);
  CHECK(cancel.effects.size() == 2);
  CHECK(std::get<TimerCancel>(cancel.effects[1]).timer_id == "b");
}

void test_timer_fired_routes_by_prefix() {
  const ModuleRegistry registry = tracing_registry();
  Engine engine(registry);
  Output scheduled;
  engine.state().timers.schedule("test.flush", 1000, &scheduled);
  engine.state().timers.schedule("test.long.drain", 1000, &scheduled);
  engine.state().timers.schedule("other.timer", 1000, &scheduled);

  std::string json;
  CHECK(handle(&engine,
               "{\"type\":\"timer.fired\",\"at\":{\"monoUs\":1500},"
               "\"input\":{\"timerId\":\"test.flush\"}}",
               &json));
  CHECK_EQ(json,
           "{\"type\":\"timer.fired\",\"records\":[],\"effects\":[{\"type\":"
           "\"timer.cancel\",\"timerId\":\"echo\"}]}");
  CHECK(handle(&engine,
               "{\"type\":\"timer.fired\",\"at\":{\"monoUs\":1500},"
               "\"input\":{\"timerId\":\"test.long.drain\"}}"));
  // A timer no module owns, and a second fire of a fired timer, do nothing.
  CHECK(handle(&engine,
               "{\"type\":\"timer.fired\",\"at\":{\"monoUs\":1500},"
               "\"input\":{\"timerId\":\"other.timer\"}}"));
  CHECK(handle(&engine,
               "{\"type\":\"timer.fired\",\"at\":{\"monoUs\":1600},"
               "\"input\":{\"timerId\":\"test.flush\"}}"));
  CHECK_EQ(take_trace(), "short:test.flush@1500 long:test.long.drain");
}

// ------------------------------------------------- teardown and lifecycle

void test_teardown_and_hooks_order() {
  const ModuleRegistry registry = tracing_registry();
  Engine engine(registry);
  CHECK(handle(&engine, configure("null")));

  CHECK(handle(&engine, start_message(0)));
  CHECK_EQ(take_trace(),
           "R:tap R:route R:capture R:gestures R:pointers R:released R:input "
           "started");
  CHECK(handle(&engine, fact("app.lifecycle", 10, "{\"state\":\"hidden\"}")));
  CHECK_EQ(take_trace(),
           "L:tap L:route L:capture L:pointers L:released L:gestures L:input "
           "backgrounded");
  CHECK(handle(&engine, fact("app.lifecycle", 20, "{\"state\":\"inactive\"}")));
  CHECK_EQ(take_trace(), "");
  CHECK(handle(&engine, fact("app.lifecycle", 30, "{\"state\":\"resumed\"}")));
  CHECK_EQ(take_trace(), "foregrounded");
  // detached: lifecycle teardown, then the end sequence.
  CHECK(handle(&engine, fact("app.lifecycle", 40, "{\"state\":\"detached\"}")));
  CHECK_EQ(take_trace(),
           "L:tap L:route L:capture L:pointers L:released L:gestures L:input "
           "E:tap E:route E:capture E:pointers E:released E:gestures E:input "
           "ending");
  // Facts without a live session are dropped before any module sees them.
  CHECK(handle(&engine, fact("app.lifecycle", 50, "{\"state\":\"hidden\"}")));
  CHECK_EQ(take_trace(), "");
  // A replacing start ends the live session first (C10).
  CHECK(handle(&engine, start_message(100)));
  take_trace();
  CHECK(handle(&engine, start_message(200)));
  CHECK(contains(take_trace(), "E:input ending R:tap"));
  CHECK(handle(&engine, fact("session.end", 300, "{\"reason\":\"dispose\"}")));
  CHECK_EQ(take_trace(),
           "D:tap D:route D:capture D:pointers D:released D:gestures D:input "
           "ending");
}

void test_transition_table() {
  using S = LifecycleState;
  using G = LifecycleSignal;
  struct Case {
    S from;
    G signal;
    S to;
  };
  const Case cases[] = {
      {S::kIdle, G::kSessionStart, S::kActive},
      {S::kIdle, G::kSessionEnd, S::kIdle},
      {S::kIdle, G::kBackgrounded, S::kIdle},
      {S::kIdle, G::kDetached, S::kIdle},
      {S::kActive, G::kBackgrounded, S::kBackground},
      {S::kActive, G::kInactive, S::kActive},
      {S::kActive, G::kForegrounded, S::kActive},
      {S::kActive, G::kSessionEnd, S::kEnded},
      {S::kActive, G::kDetached, S::kEnded},
      {S::kActive, G::kSessionStart, S::kActive},
      {S::kBackground, G::kInactive, S::kBackground},
      {S::kBackground, G::kForegrounded, S::kActive},
      {S::kBackground, G::kBackgrounded, S::kBackground},
      {S::kBackground, G::kSessionEnd, S::kEnded},
      {S::kBackground, G::kSessionStart, S::kActive},
      {S::kEnded, G::kSessionEnd, S::kEnded},
      {S::kEnded, G::kForegrounded, S::kEnded},
      {S::kEnded, G::kSessionStart, S::kActive},
  };
  for (const Case& c : cases) {
    CHECK(tugboat::engine::transition(c.from, c.signal) == c.to);
  }
}

void test_elapsed_ms() {
  CHECK(tugboat::engine::elapsed_ms(1000, 1000) == 0);
  CHECK(tugboat::engine::elapsed_ms(1000, 1999) == 0);
  CHECK(tugboat::engine::elapsed_ms(1000, 2000) == 1);
  CHECK(tugboat::engine::elapsed_ms(5000, 10) == 0);  // C13
  CHECK(tugboat::engine::elapsed_ms(0, INT64_MAX) == INT64_MAX / 1000);
}

void test_registry_types() {
  const std::vector<std::string> types =
      tugboat::engine::module_registry().types();
  CHECK(types.size() == 19);
  CHECK(types.front() == "app.lifecycle");
  CHECK(tugboat::engine::module_registry().is_engine_event_type(
      "session_start"));
  CHECK(!tugboat::engine::module_registry().is_engine_event_type(
      "network_call"));
}

// ------------------------------------------------------- record and effect

void test_records_json() {
  std::vector<tugboat::engine::Record> records;
  tugboat::engine::Event event;
  event.id = "event-1";
  event.type = "network_call";
  records.push_back(EventRecord{event, std::nullopt});
  Frame frame;
  frame.id = "frame-2";
  frame.at_ms = 5;
  frame.width = 3;
  frame.height = 4;
  frame.content_hash = "abc";
  frame.trigger = FrameTrigger::kTap;
  frame.resolved_backend = "flutterRepaintBoundary";
  records.push_back(FrameRecord{"h-2", frame});
  records.push_back(HealthRecord{"collector_frame_upload", {{"dropped", 2}}});
  CHECK_EQ(to_json(tugboat::engine::records_json(records)),
           "[{\"kind\":\"event\",\"event\":{\"id\":\"event-1\",\"atMs\":0,"
           "\"type\":\"network_call\",\"stream\":\"semantic\"},\"userId\":"
           "null},{\"kind\":\"frame\",\"handle\":\"h-2\",\"frame\":{\"id\":"
           "\"frame-2\",\"atMs\":5,\"width\":3,\"height\":4,\"contentHash\":"
           "\"abc\",\"masked\":false,\"trigger\":\"tap\",\"byteLength\":0,"
           "\"captureMicros\":0,\"resolvedBackend\":\"flutterRepaintBoundary\""
           "}},{\"kind\":\"health\",\"component\":\"collector_frame_upload\","
           "\"counters\":{\"dropped\":2}}]");
}

void test_effects_json() {
  std::vector<tugboat::engine::Effect> effects;
  effects.push_back(TimerSchedule{"t", 42});
  effects.push_back(TimerCancel{"t"});
  Value body = Value::object();
  body.set("sessionId", Value::string("s"));
  effects.push_back(HttpSend{"r-1", HttpLane::kLifecycle, "/v1/sessions",
                             15000, body});
  MultipartBody multipart;
  multipart.fields.emplace_back("frameNos", "[\"2\"]");
  multipart.frames.push_back({"h-2", "2.jpg"});
  effects.push_back(
      HttpSend{"r-2", HttpLane::kFrames, "/v1/frames", 15000, multipart});
  effects.push_back(FrameRelease{"h-2"});
  CaptureRequest capture;
  capture.request_id = "capture_request-3";
  capture.trigger = FrameTrigger::kRoute;
  capture.require_fresh_paint = true;
  capture.not_before_mono_us = 900;
  capture.context.route_epoch = 2;
  capture.context.navigator_id = "nav-1";
  capture.scale = 0.75;
  effects.push_back(capture);
  CHECK_EQ(
      to_json(tugboat::engine::effects_json(effects)),
      "[{\"type\":\"timer.schedule\",\"timerId\":\"t\",\"atMonoUs\":42},"
      "{\"type\":\"timer.cancel\",\"timerId\":\"t\"},"
      "{\"type\":\"http.send\",\"requestId\":\"r-1\",\"lane\":\"lifecycle\","
      "\"path\":\"/v1/sessions\",\"timeoutMs\":15000,\"json\":{\"sessionId\":"
      "\"s\"}},{\"type\":\"http.send\",\"requestId\":\"r-2\",\"lane\":"
      "\"frames\",\"path\":\"/v1/frames\",\"timeoutMs\":15000,\"multipart\":"
      "{\"fields\":{\"frameNos\":\"[\\\"2\\\"]\"},\"frames\":[{\"handle\":"
      "\"h-2\",\"filename\":\"2.jpg\"}]}},{\"type\":\"frame.release\","
      "\"handle\":\"h-2\"},{\"type\":\"capture.request\",\"requestId\":"
      "\"capture_request-3\",\"trigger\":\"route\",\"force\":false,"
      "\"requireFreshPaint\":true,\"dropWhenBusy\":false,\"notBeforeMonoUs\":"
      "900,\"context\":{\"routeEpoch\":2,\"navigatorId\":\"nav-1\","
      "\"boundaryGeneration\":0},\"scale\":0.75}]");
}

// ------------------------------------------------------------ configuration

void test_configure_between_sessions() {
  tb_session_engine* engine = make_engine();
  CHECK(submit(engine, configure("\"u-config\"")).status == TB_SESSION_OK);
  auto started = submit(engine, start_message(0));
  CHECK(contains(started.json, "\"userId\":\"u-config\""));
  // Stateful responses carry records and effects instead of `result`.
  const std::string head =
      "{\"type\":\"session.start\",\"records\":[{\"kind\":\"event\",";
  CHECK(started.json.rfind(head, 0) == 0);
  CHECK(contains(started.json, "],\"effects\":[]}"));
  // Not while a session is live.
  auto rejected = submit(engine, configure("null"));
  CHECK(rejected.status == TB_SESSION_INVALID_MESSAGE &&
        contains(rejected.json, "\"path\":\"$.type\""));
  CHECK(submit(engine, fact("identity.set", 10, "{\"userId\":\"u-set\"}"))
            .status == TB_SESSION_OK);
  CHECK(submit(engine, fact("session.end", 20, "{}")).status == TB_SESSION_OK);
  // Between sessions it replaces the configuration; an explicit identity
  // survives it.
  const std::string limits =
      std::string("{\"type\":\"engine.configure\",\"input\":{\"host\":") +
      kHost +
      ",\"configuredUserId\":\"u-other\"},\"limits\":{\"maxEvents\":1}}}";
  CHECK(submit(engine, limits).status == TB_SESSION_OK);
  CHECK(submit(engine, start_message(100)).status == TB_SESSION_OK);
  auto record = submit(engine,
                       fact("event.record", 110,
                            "{\"eventType\":\"external_event\",\"stream\":"
                            "\"evidence\",\"attachActionContext\":false}"));
  CHECK(record.status == TB_SESSION_OK);
  CHECK(contains(record.json, "\"userId\":\"u-set\""));
  // Session schema 10 has no `legacy_projection` stream.
  auto legacy = submit(engine,
                       fact("event.record", 120,
                            "{\"eventType\":\"external_event\",\"stream\":"
                            "\"legacy_projection\",\"attachActionContext\":"
                            "false}"));
  CHECK(legacy.status == TB_SESSION_INVALID_MESSAGE &&
        contains(legacy.json, "\"path\":\"$.input.stream\""));
  auto snapshot =
      submit(engine, "{\"type\":\"session.snapshot\",\"input\":{}}");
  CHECK(contains(snapshot.json, "\"truncated\":true"));
  CHECK(contains(snapshot.json,
                 "\"events\":[{\"id\":\"event-3\",\"atMs\":0,\"type\":"
                 "\"external_event\",\"stream\":\"evidence\""));
  tb_session_engine_destroy(engine);
}

void test_configure_in_batch() {
  tb_session_engine* engine = make_engine();
  // Admission sees the host configured earlier in the same batch.
  const std::string batch =
      std::string("{\"type\":\"batch\",\"messages\":[") +
      "{\"type\":\"engine.configure\",\"input\":{\"host\":" + kHost + "}}}," +
      start_message(0) + "]}";
  auto response = submit(engine, batch);
  CHECK(response.status == TB_SESSION_OK);
  CHECK(contains(response.json, "\"type\":\"session_start\""));
  // And a configure after the session ends in the same batch is accepted.
  const std::string next =
      std::string("{\"type\":\"batch\",\"messages\":[") +
      fact("session.end", 10, "{}") +
      ",{\"type\":\"engine.configure\",\"input\":{}}]}";
  CHECK(submit(engine, next).status == TB_SESSION_OK);
  // Without a host, session.start is rejected.
  auto no_host = submit(engine, start_message(20));
  CHECK(no_host.status == TB_SESSION_INVALID_MESSAGE &&
        contains(no_host.json, "\"path\":\"$\""));
  // Queries accept an `at`, which is validated and not used.
  CHECK(submit(engine,
               "{\"type\":\"session.snapshot\",\"at\":{\"monoUs\":30},"
               "\"input\":{}}")
            .status == TB_SESSION_OK);
  CHECK(submit(engine,
               "{\"type\":\"session.snapshot\",\"at\":{\"wallUs\":30},"
               "\"input\":{}}")
            .status == TB_SESSION_INVALID_MESSAGE);
  tb_session_engine_destroy(engine);
}

}  // namespace

int main() {
  test_timers_deadlines();
  test_timer_fired_routes_by_prefix();
  test_teardown_and_hooks_order();
  test_transition_table();
  test_elapsed_ms();
  test_registry_types();
  test_records_json();
  test_effects_json();
  test_configure_between_sessions();
  test_configure_in_batch();
  return unit::finish("stateful engine");
}
