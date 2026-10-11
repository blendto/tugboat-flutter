// The message dispatcher behind `tb_session_engine_submit_v1`: envelope
// validation, registry lookup, `batch`, and the response document.
// See README.md "Messages". Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_ENGINE_H
#define TUGBOAT_SESSION_ENGINE_ENGINE_H

#include "engine_state.h"
#include "json.h"
#include "reader.h"

namespace tugboat {
namespace engine {

class Engine {
 public:
  // Handles one parsed message. On success `*response` is the response
  // document; on failure `*error` says why and the engine state is
  // unchanged (a rejected batch applies none of its messages).
  bool handle(const Value& message, Value* response, Error* error);

  EngineState& state() { return state_; }
  const EngineState& state() const { return state_; }

 private:
  EngineState state_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_ENGINE_H
