#include "output.h"

namespace tugboat {
namespace engine {

namespace {

struct RecordJson {
  Value operator()(const EventRecord& record) const {
    Value out = Value::object();
    out.set("kind", Value::string("event"));
    out.set("event", event_json(record.event));
    out.set("userId", record.user_id ? Value::string(*record.user_id)
                                     : Value::null());
    return out;
  }
};

struct EffectJson {
  Value operator()(const TimerSchedule& effect) const {
    Value out = Value::object();
    out.set("type", Value::string("timer.schedule"));
    out.set("timerId", Value::string(effect.timer_id));
    out.set("atMonoUs", Value::integer(effect.at_mono_us));
    return out;
  }
  Value operator()(const TimerCancel& effect) const {
    Value out = Value::object();
    out.set("type", Value::string("timer.cancel"));
    out.set("timerId", Value::string(effect.timer_id));
    return out;
  }
};

}  // namespace

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
