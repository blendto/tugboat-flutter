// `evidence.externalEvent` and `evidence.networkCall` (docs/
// evidence-messages.md): host evidence the engine bounds and normalizes
// itself, as Flutter's `TugboatEvidenceRecorder` does.
#include <algorithm>
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "evidence.h"
#include "evidence_value.h"
#include "modules.h"
#include "recorder.h"

namespace tugboat {
namespace engine {

namespace {

// Dart `_finishNetworkCall` clamps durations to a day.
constexpr int64_t kMaxDurationMs = 24 * 60 * 60 * 1000;

// Records `data` as an evidence-stream event of `type` at `fact_mono_us`,
// without the action context (Dart `appendEvidence`).
void record_evidence(EngineState* state, Session& session, const char* type,
                     int64_t fact_mono_us, Value data, Output* out) {
  Event event = make_event(state, session, type, fact_mono_us);
  event.stream = EventStream::kEvidence;
  event.data = std::move(data);
  record_event(state, session, std::move(event), false, out);
}

// ------------------------------------------------- evidence.externalEvent

class RecordExternalEvent final : public Command {
 public:
  RecordExternalEvent(std::string name, std::optional<std::string> source,
                      ParameterPolicy policy, std::optional<Value> parameters,
                      int64_t fact_mono_us)
      : name_(std::move(name)),
        source_(std::move(source)),
        policy_(std::move(policy)),
        parameters_(std::move(parameters)),
        fact_mono_us_(fact_mono_us) {}

  void apply(const ModuleRegistry&, EngineState* state,
             Output* out) override {
    std::optional<Value> data = external_event_data(
        name_, source_, policy_, parameters_ ? &*parameters_ : nullptr);
    if (!data) {
      return;  // Dart `invalid_name`: nothing recorded
    }
    record_evidence(state, *state->live_session(), "external_event",
                    fact_mono_us_, std::move(*data), out);
  }

 private:
  std::string name_;
  std::optional<std::string> source_;
  ParameterPolicy policy_;
  std::optional<Value> parameters_;
  int64_t fact_mono_us_;
};

bool decode_policy(const ObjectReader& r, ParameterPolicy* policy,
                   Error* error) {
  const Value* json = nullptr;
  if (!r.req_object("policy", &json)) {
    return false;
  }
  const ObjectReader p(*json, r.child("policy"), error);
  std::string mode;
  const Value* keys = nullptr;
  if (!p.check_keys({"mode", "allowedKeys"}) || !p.req_string("mode", &mode)) {
    return false;
  }
  const std::optional<ParameterMode> parsed = parse_parameter_mode(mode);
  if (!parsed) {
    return p.reject("mode",
                    "expected names_only, allow_list, transform, or allow_all");
  }
  policy->mode = *parsed;
  if (*parsed != ParameterMode::kAllowList) {
    return reject_present(p, {"allowedKeys"}, "only with allow_list");
  }
  if (!p.req_array("allowedKeys", &keys)) {
    return false;
  }
  for (const Value& key : keys->items()) {
    if (!key.is_string()) {
      return p.reject("allowedKeys", "expected strings");
    }
    policy->allowed_keys.push_back(key.as_string());
  }
  std::sort(policy->allowed_keys.begin(), policy->allowed_keys.end());
  return true;
}

// The parameters `map` value: the top-level map is not a collection of any
// value (Dart's `seen` starts empty), and `omitted` needs 64 sent entries.
bool decode_parameters(const ObjectReader& r, const ParameterPolicy& policy,
                       std::optional<Value>* out, Error* error) {
  const Value* json = r.get("parameters");
  if (json == nullptr) {
    return true;
  }
  const std::string path = r.child("parameters");
  if (!json->is_object() || json->find("map") == nullptr ||
      json->members().size() != (json->find("omitted") ? 2u : 1u)) {
    return invalid(error, path, "expected a map value");
  }
  const bool transform = policy.mode == ParameterMode::kTransform;
  if (!validate_map(*json, 0, transform, path, error)) {
    return false;
  }
  if (const Value* omitted = json->find("omitted")) {
    if (!omitted->is_int() || omitted->as_int() < 1) {
      return invalid(error, path + ".omitted", "expected an integer >= 1");
    }
    if (entry_count(Node::encoded(*json)) <
        ParameterLimits::kMaxTopLevelKeys) {
      return invalid(error, path + ".omitted",
                     "only after the first 64 entries");
    }
  }
  *out = *json;
  return true;
}

std::unique_ptr<Command> decode_external_event(const CommandInput& in,
                                               Error* error) {
  const ObjectReader r(in.input, in.path, error);
  std::string name;
  std::optional<std::string> source;
  ParameterPolicy policy;
  std::optional<Value> parameters;
  std::optional<int64_t> fact_mono_us;
  if (!r.check_keys({"name", "source", "policy", "parameters", "atMonoUs"}) ||
      !r.req_string("name", &name) || !r.opt_string("source", &source) ||
      !decode_policy(r, &policy, error) ||
      !decode_parameters(r, policy, &parameters, error) ||
      !decode_mono_us(r, "atMonoUs", &fact_mono_us)) {
    return nullptr;
  }
  return std::make_unique<RecordExternalEvent>(
      std::move(name), std::move(source), std::move(policy),
      std::move(parameters), fact_mono_us.value_or(in.at->mono_us));
}

// --------------------------------------------------- evidence.networkCall

class RecordNetworkCall final : public Command {
 public:
  RecordNetworkCall(NetworkCall call, std::optional<Value> body,
                    int64_t start_mono_us, int64_t end_mono_us)
      : call_(std::move(call)),
        body_(std::move(body)),
        start_mono_us_(start_mono_us),
        end_mono_us_(end_mono_us) {}

  void apply(const ModuleRegistry&, EngineState* state,
             Output* out) override {
    Session& session = *state->live_session();
    if (start_mono_us_ < session.header().start_mono_us) {
      return;  // begun before this session: Dart's no-op or stale token
    }
    std::optional<std::string> method = normalize_network_method(call_.method);
    std::optional<std::string> route = normalize_network_route(call_.route);
    if (!method || !route) {
      return;  // Dart `invalid_route`: a no-op token
    }
    NetworkCall call = call_;
    call.method = std::move(*method);
    call.route = std::move(*route);
    call.duration_ms = std::clamp<int64_t>(
        session.at_ms(end_mono_us_) - session.at_ms(start_mono_us_), 0,
        kMaxDurationMs);
    call.error_body = body_ ? &*body_ : nullptr;
    record_evidence(state, session, "network_call", start_mono_us_,
                    network_call_data(call), out);
  }

 private:
  NetworkCall call_;
  std::optional<Value> body_;
  int64_t start_mono_us_;
  int64_t end_mono_us_;
};

bool decode_error_body(const ObjectReader& r, std::optional<Value>* out,
                       Error* error) {
  const Value* json = nullptr;
  if (!r.opt_object("errorResponseBody", &json)) {
    return false;
  }
  if (json == nullptr) {
    return true;
  }
  const std::string path = r.child("errorResponseBody");
  const ObjectReader b(*json, path, error);
  if (!b.check_keys({"value", "jsonText"})) {
    return false;
  }
  const bool has_value = json->find("value") != nullptr;
  const Value* text = json->find("jsonText");
  if (has_value == (text != nullptr)) {
    return invalid(error, path, "expected exactly one of value or jsonText");
  }
  if (text != nullptr && !text->is_string()) {
    return b.reject("jsonText", "expected a string");
  }
  if (has_value && !validate_value(*json->find("value"), 0, false,
                                   b.child("value"), error)) {
    return false;
  }
  *out = *json;
  return true;
}

bool decode_outcome(const ObjectReader& r, std::string* outcome) {
  if (!r.req_string("outcome", outcome)) {
    return false;
  }
  if (*outcome != "response" && *outcome != "network_error" &&
      *outcome != "cancelled") {
    return r.reject("outcome", "expected response, network_error, or cancelled");
  }
  return true;
}

std::unique_ptr<Command> decode_network_call(const CommandInput& in,
                                             Error* error) {
  const ObjectReader r(in.input, in.path, error);
  NetworkCall call;
  std::optional<Value> body;
  std::optional<int64_t> start;
  std::optional<int64_t> end;
  if (!r.check_keys({"method", "route", "startMonoUs", "endMonoUs",
                     "statusCode", "outcome", "attemptCount",
                     "errorResponseBody"}) ||
      !r.req_string("method", &call.method) ||
      !r.req_string("route", &call.route) ||
      !decode_mono_us(r, "startMonoUs", &start) ||
      !decode_mono_us(r, "endMonoUs", &end) ||
      !r.opt_int("statusCode", &call.status_code) ||
      !decode_outcome(r, &call.outcome) ||
      !r.opt_int("attemptCount", &call.attempt_count) ||
      !decode_error_body(r, &body, error)) {
    return nullptr;
  }
  if (!start) {
    r.reject("startMonoUs", "required");
    return nullptr;
  }
  return std::make_unique<RecordNetworkCall>(
      std::move(call), std::move(body), *start, end.value_or(in.at->mono_us));
}

}  // namespace

void register_evidence_messages_module(ModuleRegistry* registry) {
  registry->add_command("evidence.externalEvent",
                        {AtRule::kMono, SessionPolicy::kEventProducing,
                         decode_external_event});
  registry->add_command("evidence.networkCall",
                        {AtRule::kMono, SessionPolicy::kEventProducing,
                         decode_network_call});
}

}  // namespace engine
}  // namespace tugboat
