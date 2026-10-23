// Collector delivery (docs/stateful-engine.md section 7): registers the
// transport messages, the lifecycle hooks, the `delivery.` timers, and the
// event record observer. Behaviour is in delivery.h; state is
// `EngineState::delivery` (delivery_state.h).
#include <memory>
#include <string>
#include <utility>

#include "delivery.h"
#include "delivery_context.h"
#include "modules.h"
#include "transport.h"

namespace tugboat {
namespace engine {

namespace {

// `transport.result {requestId, outcome, status?, body?}`: the host's answer
// to an `http.send`. Unknown and stale request ids are ignored.
class TransportResultCommand final : public Command {
 public:
  TransportResultCommand(TransportResult result, At at)
      : result_(std::move(result)), at_(at) {}

  void apply(const ModuleRegistry&, EngineState* state,
             Output* out) override {
    delivery_transport_result(result_, at_, state, out);
  }

 private:
  TransportResult result_;
  At at_;
};

std::unique_ptr<Command> decode_transport_result_command(
    const CommandInput& in, Error* error) {
  TransportResult result;
  if (!decode_transport_result(in.input, in.path, &result, error)) {
    return nullptr;
  }
  return std::make_unique<TransportResultCommand>(std::move(result), *in.at);
}

// `transport.flush {}`: a flush trigger from the host (for example before
// the process exits).
class TransportFlush final : public Command {
 public:
  explicit TransportFlush(At at) : at_(at) {}

  void apply(const ModuleRegistry&, EngineState* state,
             Output* out) override {
    delivery_flush_requested(at_, state, out);
  }

 private:
  At at_;
};

std::unique_ptr<Command> decode_transport_flush(const CommandInput& in,
                                                Error* error) {
  const ObjectReader r(in.input, in.path, error);
  if (!r.check_keys({})) {
    return nullptr;
  }
  return std::make_unique<TransportFlush>(*in.at);
}

}  // namespace

void register_delivery_module(ModuleRegistry* registry) {
  registry->add_command("transport.result",
                        {AtRule::kMonoAndWall, SessionPolicy::kAny,
                         decode_transport_result_command});
  registry->add_command("transport.flush",
                        {AtRule::kMono, SessionPolicy::kAny,
                         decode_transport_flush});
  registry->add_timers(kDeliveryTimerPrefix, delivery_timer_fired);
  registry->on_session_started(delivery_session_started);
  registry->on_backgrounded(delivery_backgrounded);
  registry->on_foregrounded(delivery_foregrounded);
  registry->on_session_ending(delivery_session_ending);
  registry->on_event_recorded(delivery_event_recorded);
  registry->on_frame_accepted(delivery_frame_accepted);
}

}  // namespace engine
}  // namespace tugboat
