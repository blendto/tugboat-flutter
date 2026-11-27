// Frame handle retention (docs/stateful-engine.md section 7.6). The host keeps
// an accepted frame's bytes under its handle; two owners reference the frame
// independently:
// - the in-memory session, until the frame is trimmed or the session ends;
// - collector delivery, until the frame is accepted, dropped, or evicted (or
//   its in-flight upload resolves after a reset).
// `frame.release {handle}` is emitted exactly once, when the last reference
// goes. A handle in a message the engine rejects never reaches the engine:
// the host keeps owning it. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_FRAME_RETENTION_H
#define TUGBOAT_SESSION_ENGINE_FRAME_RETENTION_H

#include <map>
#include <string>

#include "output.h"

namespace tugboat {
namespace engine {

enum class FrameOwner { kSession, kDelivery };

class FrameRetention {
 public:
  // Adds `owner`'s reference to frame `frame_id`, whose bytes are `handle`.
  void retain(const std::string& frame_id, const std::string& handle,
              FrameOwner owner);
  // Drops `owner`'s reference; emits `frame.release` when it was the last.
  // Dropping a reference that is not held does nothing.
  void release(const std::string& frame_id, FrameOwner owner, Output* out);

 private:
  struct Refs {
    std::string handle;
    bool session = false;
    bool delivery = false;
  };
  std::map<std::string, Refs> frames_;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_FRAME_RETENTION_H
