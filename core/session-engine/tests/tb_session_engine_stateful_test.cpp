// Unit tests for the stateful engine internals that scenario fixtures cannot
// reach: timer routing to an owning module, the teardown extension point and
// its stage order, the lifecycle transition table, configuration across
// sessions, and the stateful response shape. Behaviour visible through the
// public protocol is pinned by conformance/engine/scenario/ instead.
#include <string>
#include <utility>
#include <vector>

#include "clock.h"
#include "engine.h"
#include "json.h"
#include "lifecycle.h"
#include "teardown.h"
#include "unit_support.h"

namespace {

using tugboat::engine::Admission;
using tugboat::engine::AppState;
using tugboat::engine::At;
using tugboat::engine::Engine;
using tugboat::engine::EngineState;
using tugboat::engine::Error;
using tugboat::engine::LifecycleSignal;
using tugboat::engine::LifecycleState;
using tugboat::engine::Output;
using tugboat::engine::TeardownCause;
using tugboat::engine::TeardownStage;
using tugboat::engine::TimerCancel;
using tugboat::engine::TimerOwner;
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

bool handle(Engine* engine, const std::string& text, Value* response,
            Error* error) {
  Value message;
  tugboat::engine::ParseError parse_error;
  if (!tugboat::engine::parse_json(text, 64, &message, &parse_error)) {
    return false;
  }
  return engine->handle(message, response, error);
}

bool handle(Engine* engine, const std::string& text) {
  Value response;
  Error error;
  return handle(engine, text, &response, &error);
}

// ------------------------------------------------------------------ timers

class RecordingOwner final : public TimerOwner {
 public:
  void on_timer_fired(const std::string& timer_id, const At& at, EngineState*,
                      Output* out) override {
    fired.emplace_back(timer_id, at.mono_us);
    out->effects.push_back(TimerCancel{"echo." + timer_id});
  }
  std::vector<std::pair<std::string, int64_t>> fired;
};

void test_timers_registry() {
  Timers timers;
  RecordingOwner owner;
  Output out;
  timers.schedule("a", 100, &owner, &out);
  timers.schedule("a", 300, &owner, &out);  // replaces
  CHECK(out.effects.size() == 2);
  CHECK(std::get<TimerSchedule>(out.effects[1]).at_mono_us == 300);
  // A fire stamped before the current deadline is stale.
  CHECK(timers.take_due("a", 200) == nullptr);
  CHECK(timers.armed("a"));
  CHECK(timers.take_due("unknown", 1000) == nullptr);
  CHECK(timers.take_due("a", 300) == &owner);
  CHECK(!timers.armed("a"));
  CHECK(timers.take_due("a", 400) == nullptr);  // fires once

  Output cancel;
  timers.cancel("never-armed", &cancel);
  CHECK(cancel.effects.empty());
  timers.schedule("b", 10, &owner, &cancel);
  timers.cancel("b", &cancel);
  CHECK(cancel.effects.size() == 2);
  CHECK(std::get<TimerCancel>(cancel.effects[1]).timer_id == "b");
  CHECK(!timers.armed("b"));
}

void test_timer_fired_routes_to_owner() {
  Engine engine;
  RecordingOwner owner;
  Output scheduled;
  engine.state().timers.schedule("collector.flush", 1000, &owner, &scheduled);

  Value response;
  Error error;
  CHECK(handle(&engine,
               "{\"type\":\"timer.fired\",\"at\":{\"monoUs\":1500},"
               "\"input\":{\"timerId\":\"collector.flush\"}}",
               &response, &error));
  CHECK(owner.fired.size() == 1 && owner.fired[0].first == "collector.flush" &&
        owner.fired[0].second == 1500);
  std::string json;
  tugboat::engine::write_json(response, &json, nullptr);
  CHECK_EQ(json,
           "{\"type\":\"timer.fired\",\"records\":[],\"effects\":[{\"type\":"
           "\"timer.cancel\",\"timerId\":\"echo.collector.flush\"}]}");

  // A second fire of the same timer is ignored.
  CHECK(handle(&engine,
               "{\"type\":\"timer.fired\",\"at\":{\"monoUs\":1600},"
               "\"input\":{\"timerId\":\"collector.flush\"}}"));
  CHECK(owner.fired.size() == 1);
}

void test_effects_json_shape() {
  Output out;
  out.effects.push_back(TimerSchedule{"t", 42});
  out.effects.push_back(TimerCancel{"t"});
  std::string json;
  tugboat::engine::write_json(tugboat::engine::effects_json(out.effects),
                              &json, nullptr);
  CHECK_EQ(json,
           "[{\"type\":\"timer.schedule\",\"timerId\":\"t\",\"atMonoUs\":42},"
           "{\"type\":\"timer.cancel\",\"timerId\":\"t\"}]");
}

// ---------------------------------------------------------------- teardown

std::vector<std::string>* g_trace = nullptr;

void register_tracing(EngineState* state) {
  const std::pair<TeardownStage, const char*> stages[] = {
      {TeardownStage::kTapSettles, "tap"},
      {TeardownStage::kRouteCaptures, "route"},
      {TeardownStage::kCaptureWork, "capture"},
      {TeardownStage::kPendingPointers, "pointers"},
      {TeardownStage::kReleasedTransactions, "released"},
      {TeardownStage::kGestureAndScroll, "gestures"},
      {TeardownStage::kInputObservations, "input"},
  };
  for (const auto& stage : stages) {
    const std::string name = stage.second;
    state->teardown.on(stage.first, [name](TeardownCause cause, Output*) {
      const char* why = cause == TeardownCause::kLifecycle      ? "L"
                        : cause == TeardownCause::kSessionEnd   ? "E"
                        : cause == TeardownCause::kDispose      ? "D"
                                                                : "R";
      g_trace->push_back(std::string(why) + ":" + name);
    });
  }
}

std::string joined(const std::vector<std::string>& trace) {
  std::string out;
  for (const std::string& item : trace) {
    out += (out.empty() ? "" : " ") + item;
  }
  return out;
}

void test_teardown_order() {
  std::vector<std::string> trace;
  g_trace = &trace;
  Engine engine;
  register_tracing(&engine.state());
  CHECK(handle(&engine, configure("null")));

  CHECK(handle(&engine, start_message(0)));
  CHECK_EQ(joined(trace),
           "R:tap R:route R:capture R:gestures R:pointers R:released R:input");
  trace.clear();
  CHECK(handle(&engine, fact("app.lifecycle", 10, "{\"state\":\"hidden\"}")));
  CHECK_EQ(joined(trace),
           "L:tap L:route L:capture L:pointers L:released L:gestures L:input");
  trace.clear();
  // inactive and resumed tear nothing down.
  CHECK(handle(&engine, fact("app.lifecycle", 20, "{\"state\":\"inactive\"}")));
  CHECK(handle(&engine, fact("app.lifecycle", 30, "{\"state\":\"resumed\"}")));
  CHECK(trace.empty());
  // detached: lifecycle teardown, then the end sequence.
  CHECK(handle(&engine, fact("app.lifecycle", 40, "{\"state\":\"detached\"}")));
  CHECK_EQ(joined(trace),
           "L:tap L:route L:capture L:pointers L:released L:gestures L:input "
           "E:tap E:route E:capture E:pointers E:released E:gestures E:input");
  trace.clear();
  // A replacing start ends the live session first (C10).
  CHECK(handle(&engine, start_message(100)));
  CHECK(handle(&engine, start_message(200)));
  CHECK(contains(joined(trace), "E:input R:tap"));
  trace.clear();
  CHECK(handle(&engine, fact("session.end", 300, "{\"reason\":\"dispose\"}")));
  CHECK_EQ(joined(trace),
           "D:tap D:route D:capture D:pointers D:released D:gestures D:input");
  g_trace = nullptr;
}

// --------------------------------------------------------------- lifecycle

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
  Admission ended;
  ended.lifecycle = S::kEnded;
  Error error;
  CHECK(!tugboat::engine::reject_after_end(ended, "$.messages[3]", &error));
  CHECK(error.path == "$.messages[3].type");
}

void test_elapsed_ms() {
  CHECK(tugboat::engine::elapsed_ms(1000, 1000) == 0);
  CHECK(tugboat::engine::elapsed_ms(1000, 1999) == 0);
  CHECK(tugboat::engine::elapsed_ms(1000, 2000) == 1);
  CHECK(tugboat::engine::elapsed_ms(5000, 10) == 0);  // C1: never negative
  CHECK(tugboat::engine::elapsed_ms(0, INT64_MAX) == INT64_MAX / 1000);
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
                            "\"legacy_projection\",\"attachActionContext\":"
                            "false}"));
  CHECK(record.status == TB_SESSION_OK);
  CHECK(contains(record.json, "\"userId\":\"u-set\""));
  // The collector's closed stream set includes legacy_projection.
  CHECK(contains(record.json, "\"stream\":\"legacy_projection\""));
  auto snapshot =
      submit(engine, "{\"type\":\"session.snapshot\",\"input\":{}}");
  CHECK(contains(snapshot.json, "\"truncated\":true"));
  CHECK(contains(snapshot.json,
                 "\"events\":[{\"id\":\"event-3\",\"atMs\":0,\"type\":"
                 "\"external_event\",\"stream\":\"legacy_projection\""));
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
  tb_session_engine_destroy(engine);
}

}  // namespace

int main() {
  test_timers_registry();
  test_timer_fired_routes_to_owner();
  test_effects_json_shape();
  test_teardown_order();
  test_transition_table();
  test_elapsed_ms();
  test_configure_between_sessions();
  test_configure_in_batch();
  return unit::finish("stateful engine");
}
