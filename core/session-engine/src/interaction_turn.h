// What every interaction step works on: the engine state, the live session,
// the fact's time, and the output it appends to. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_INTERACTION_TURN_H
#define TUGBOAT_SESSION_ENGINE_INTERACTION_TURN_H

#include <cstdint>

#include "clock.h"
#include "output.h"
#include "session.h"

namespace tugboat {
namespace engine {

struct EngineState;

struct InteractionTurn {
  EngineState* state;
  Session* session;  // the live session
  At at;             // when the fact (or timer) happened
  Output* out;

  // The fact's `atMs` in the live session (the Dart controller's `atMs`).
  int64_t now_ms() const { return session->at_ms(at.mono_us); }
  // The host monotonic time of session `atMs` `ms`, for timer deadlines.
  int64_t mono_at_ms(int64_t ms) const {
    return session->header().start_mono_us + ms * 1000;
  }
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_INTERACTION_TURN_H
