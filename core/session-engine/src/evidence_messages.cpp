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
                      ParameterPolicy policy,
                      std::optional<EvidenceValue> parameters,
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
  std::optional<EvidenceValue> parameters_;
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

bool decode_parameters(const ObjectReader& r, const ParameterPolicy& policy,
                       std::optional<EvidenceValue>* out, Error* error) {
  const Value* json = r.get("parameters");
  if (json == nullptr) {
    return true;
  }
  EvidenceValue parameters;
  if (!decode_parameters_map(*json, policy.mode == ParameterMode::kTransform,
                             r.child("parameters"), &parameters, error)) {
    return false;
  }
  *out = std::move(parameters);
  return true;
}

std::unique_ptr<Command> decode_external_event(const CommandInput& in,
                                               Error* error) {
  const ObjectReader r(in.input, in.path, error);
  std::string name;
  std::optional<std::string> source;
  ParameterPolicy policy;
  std::optional<EvidenceValue> parameters;
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
  RecordNetworkCall(NetworkCall call, int64_t start_mono_us,
                    int64_t end_mono_us)
      : call_(std::move(call)),
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
    const int64_t duration_ms = std::clamp<int64_t>(
        session.at_ms(end_mono_us_) - session.at_ms(start_mono_us_), 0,
        kMaxDurationMs);
    record_evidence(state, session, "network_call", start_mono_us_,
                    network_call_data(call_, std::move(*method),
                                      std::move(*route), duration_ms),
                    out);
  }

 private:
  NetworkCall call_;
  int64_t start_mono_us_;
  int64_t end_mono_us_;
};

// `{"value": v}` or `{"jsonText": t}`, validated whatever the status.
bool decode_error_body(const ObjectReader& r, std::optional<ErrorBody>* out,
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
  std::optional<std::string> text;
  if (!b.check_keys({"value", "jsonText"}) ||
      !b.opt_string("jsonText", &text)) {
    return false;
  }
  const Value* value = json->find("value");
  if ((value != nullptr) == text.has_value()) {
    return invalid(error, path, "expected exactly one of value or jsonText");
  }
  ErrorBody body;
  if (value != nullptr) {
    body.value.emplace();
    if (!decode_evidence_value(*value, EvidenceContext::kErrorBody,
                               b.child("value"), &*body.value, error)) {
      return false;
    }
  } else {
    body.json_text = std::move(*text);
  }
  *out = std::move(body);
  return true;
}

bool decode_outcome(const ObjectReader& r, NetworkOutcome* outcome) {
  std::string name;
  if (!r.req_string("outcome", &name)) {
    return false;
  }
  const std::optional<NetworkOutcome> parsed = parse_network_outcome(name);
  if (!parsed) {
    return r.reject("outcome",
                    "expected response, network_error, or cancelled");
  }
  *outcome = *parsed;
  return true;
}

std::unique_ptr<Command> decode_network_call(const CommandInput& in,
                                             Error* error) {
  const ObjectReader r(in.input, in.path, error);
  NetworkCall call;
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
      !decode_error_body(r, &call.error_body, error)) {
    return nullptr;
  }
  if (!start) {
    r.reject("startMonoUs", "required");
    return nullptr;
  }
  return std::make_unique<RecordNetworkCall>(std::move(call), *start,
                                             end.value_or(in.at->mono_us));
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
