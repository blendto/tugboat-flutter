#include "capture_requests.h"

#include <utility>

namespace tugboat {
namespace engine {

CaptureAsk interaction_capture(int64_t now_mono_us, CaptureContext context) {
  CaptureAsk ask;
  ask.trigger = FrameTrigger::kInteraction;
  ask.force = true;
  // Dart `_captureFreshnessFor`: interaction captures need a fresh paint.
  ask.require_fresh_paint = true;
  ask.not_before_mono_us = now_mono_us;
  ask.context = std::move(context);
  return ask;
}

std::string CaptureRequests::issue(const CaptureOwner& owner,
                                   const CaptureAsk& ask, IdCounter* ids,
                                   Output* out) {
  CaptureRequest request;
  request.request_id = ids->next("capture_request");
  request.trigger = ask.trigger;
  request.force = ask.force;
  request.require_fresh_paint = ask.require_fresh_paint;
  request.drop_when_busy = false;
  request.not_before_mono_us = ask.not_before_mono_us;
  request.context = ask.context;
  request.scale = 1.0;
  pending_[request.request_id] = Pending{owner, ask.trigger};
  out->effects.push_back(request);
  return request.request_id;
}

std::optional<CaptureRequests::Pending> CaptureRequests::take(
    const std::string& request_id) {
  const auto it = pending_.find(request_id);
  if (it == pending_.end()) return std::nullopt;
  Pending pending = std::move(it->second);
  pending_.erase(it);
  return pending;
}

}  // namespace engine
}  // namespace tugboat
