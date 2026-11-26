#include "delivery_keys.h"

#include <algorithm>
#include <vector>

#include "text.h"

namespace tugboat {
namespace engine {

std::string lifecycle_delivery_key(const std::string& session_id,
                                   const std::string& event_type,
                                   const std::string& triggered_at) {
  return session_id + "/l/" + event_type + "/" + triggered_at;
}

std::string event_batch_delivery_key(const std::string& session_id,
                                     const EventBatch& batch) {
  std::vector<std::string> ids;
  ids.reserve(batch.size());
  for (const Value& event : batch) {
    const Value* id = event.find("id");
    ids.push_back(id != nullptr && id->is_string() ? id->as_string()
                                                   : std::string());
  }
  std::sort(ids.begin(), ids.end(),
            [](const std::string& a, const std::string& b) {
              return compare_utf16(a, b) < 0;
            });
  std::string joined;
  for (size_t i = 0; i < ids.size(); ++i) {
    joined += (i == 0 ? "" : "\n") + ids[i];
  }
  return session_id + "/e/" + sha256_hex(wtf8_to_utf8(joined)).substr(0, 16);
}

std::string frame_delivery_key(const std::string& session_id,
                               int64_t frame_no) {
  return session_id + "/f/" + std::to_string(frame_no);
}

}  // namespace engine
}  // namespace tugboat
