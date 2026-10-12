// The in-memory session's reference to its frames (frame_retention.h). The
// capture seam takes it when a frame is accepted and drops it when the
// session trims the frame (`limits.maxFrames`); this module drops it for
// every frame when the session ends. Collector delivery holds its own
// reference (delivery_lanes.cpp).
#include "modules.h"

namespace tugboat {
namespace engine {

namespace {

void session_lets_go(const At& /*at*/, EngineState* state, Output* out) {
  if (const Session* session = state->live_session()) {
    for (const Frame& frame : session->frames()) {
      state->frame_retention.release(frame.id, FrameOwner::kSession, out);
    }
  }
}

}  // namespace

void register_frame_retention_module(ModuleRegistry* registry) {
  registry->on_session_ending(session_lets_go);
}

}  // namespace engine
}  // namespace tugboat
