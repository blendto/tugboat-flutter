#include "output.h"

namespace tugboat {
namespace engine {

namespace {

Value str(const std::string& s) { return Value::string(s); }

struct RecordJson {
  Value operator()(const EventRecord& record) const {
    Value out = Value::object();
    out.set("kind", str("event"));
    out.set("event", event_json(record.event));
    out.set("userId", record.user_id ? str(*record.user_id) : Value::null());
    return out;
  }
  Value operator()(const FrameRecord& record) const {
    Value out = Value::object();
    out.set("kind", str("frame"));
    out.set("handle", str(record.handle));
    out.set("frame", frame_json(record.frame));
    return out;
  }
  Value operator()(const HealthRecord& record) const {
    Value counters = Value::object();
    for (const auto& counter : record.counters) {
      counters.set(counter.first, Value::integer(counter.second));
    }
    Value out = Value::object();
    out.set("kind", str("health"));
    out.set("component", str(record.component));
    out.set("counters", std::move(counters));
    return out;
  }
};

Value effect_head(const char* type) {
  Value out = Value::object();
  out.set("type", str(type));
  return out;
}

Value multipart_json(const MultipartBody& body) {
  Value fields = Value::array();
  for (const auto& field : body.fields) {
    Value pair = Value::array();
    pair.push(str(field.first));
    pair.push(str(field.second));
    fields.push(std::move(pair));
  }
  Value frames = Value::array();
  for (const MultipartFrame& frame : body.frames) {
    Value part = Value::object();
    part.set("handle", str(frame.handle));
    part.set("filename", str(frame.filename));
    frames.push(std::move(part));
  }
  Value out = Value::object();
  out.set("fields", std::move(fields));
  out.set("frames", std::move(frames));
  return out;
}

Value capture_context_json(const CaptureContext& context) {
  Value out = Value::object();
  out.set("routeEpoch", Value::integer(context.route_epoch));
  put_opt(&out, "navigatorId", context.navigator_id);
  put_opt(&out, "routeInstanceId", context.route_instance_id);
  out.set("boundaryGeneration", Value::integer(context.boundary_generation));
  return out;
}

struct EffectJson {
  Value operator()(const TimerSchedule& effect) const {
    Value out = effect_head("timer.schedule");
    out.set("timerId", str(effect.timer_id));
    out.set("atMonoUs", Value::integer(effect.at_mono_us));
    return out;
  }
  Value operator()(const TimerCancel& effect) const {
    Value out = effect_head("timer.cancel");
    out.set("timerId", str(effect.timer_id));
    return out;
  }
  Value operator()(const HttpSend& effect) const {
    Value out = effect_head("http.send");
    out.set("requestId", str(effect.request_id));
    out.set("lane", str(http_lane_name(effect.lane)));
    out.set("path", str(effect.path));
    out.set("timeoutMs", Value::integer(effect.timeout_ms));
    if (const JsonBody* json = std::get_if<JsonBody>(&effect.body)) {
      out.set("jsonBody", str(json->text));
    } else {
      out.set("multipart",
              multipart_json(std::get<MultipartBody>(effect.body)));
    }
    return out;
  }
  Value operator()(const FrameRelease& effect) const {
    Value out = effect_head("frame.release");
    out.set("handle", str(effect.handle));
    return out;
  }
  Value operator()(const CaptureRequest& effect) const {
    Value out = effect_head("capture.request");
    out.set("requestId", str(effect.request_id));
    out.set("trigger", str(frame_trigger_name(effect.trigger)));
    out.set("force", Value::boolean(effect.force));
    out.set("requireFreshPaint", Value::boolean(effect.require_fresh_paint));
    out.set("dropWhenBusy", Value::boolean(effect.drop_when_busy));
    out.set("notBeforeMonoUs", Value::integer(effect.not_before_mono_us));
    out.set("context", capture_context_json(effect.context));
    if (effect.dhash_baseline) {
      Value baseline = Value::object();
      baseline.set("dHash", str(effect.dhash_baseline->dhash));
      baseline.set("structureSignature",
                   str(effect.dhash_baseline->structure_signature));
      out.set("dHashBaseline", std::move(baseline));
    }
    out.set("scale", Value::number(effect.scale));
    return out;
  }
};

}  // namespace

const char* http_lane_name(HttpLane lane) {
  switch (lane) {
    case HttpLane::kLifecycle: return "lifecycle";
    case HttpLane::kEvents: return "events";
    case HttpLane::kFrames: return "frames";
  }
  return "events";
}

Value records_json(const std::vector<Record>& records) {
  Value out = Value::array();
  for (const Record& record : records) {
    out.push(std::visit(RecordJson{}, record));
  }
  return out;
}

Value effects_json(const std::vector<Effect>& effects) {
  Value out = Value::array();
  for (const Effect& effect : effects) {
    out.push(std::visit(EffectJson{}, effect));
  }
  return out;
}

}  // namespace engine
}  // namespace tugboat
