#include "frame_retention.h"

namespace tugboat {
namespace engine {

void FrameRetention::retain(const std::string& frame_id,
                            const std::string& handle, FrameOwner owner) {
  Refs& refs = frames_[frame_id];
  refs.handle = handle;
  (owner == FrameOwner::kSession ? refs.session : refs.delivery) = true;
}

void FrameRetention::release(const std::string& frame_id, FrameOwner owner,
                             Output* out) {
  const auto it = frames_.find(frame_id);
  if (it == frames_.end()) {
    return;
  }
  (owner == FrameOwner::kSession ? it->second.session
                                 : it->second.delivery) = false;
  if (!it->second.session && !it->second.delivery) {
    out->effects.push_back(FrameRelease{it->second.handle});
    frames_.erase(it);
  }
}

}  // namespace engine
}  // namespace tugboat
