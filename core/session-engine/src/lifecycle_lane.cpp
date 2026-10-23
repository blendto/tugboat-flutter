#include "lifecycle_lane.h"

#include <string_view>
#include <utility>

#include "json.h"
#include "text.h"

namespace tugboat {
namespace engine {

namespace {

// Response bodies are at most 64 KiB, so this only bounds pathological
// nesting; Dart's `jsonDecode` has no depth limit.
constexpr uint32_t kResponseMaxDepth = 512;

// `decoded[key] as String?`: false when the value is present, not null, and
// not a string (Dart's cast throws).
bool read_optional_string(const Value& decoded, const char* key,
                          OptString* out) {
  const Value* value = decoded.find(key);
  if (value == nullptr || value->is_null()) {
    return true;
  }
  if (!value->is_string()) {
    return false;
  }
  *out = value->as_string();
  return true;
}

void use_local_id_for_start(LifecycleKind kind, const std::string& local_id,
                            CollectorIds* ids) {
  if (kind == LifecycleKind::kSessionStart && !ids->session_id) {
    ids->session_id = local_id;
  }
}

}  // namespace

const char* lifecycle_kind_name(LifecycleKind kind) {
  switch (kind) {
    case LifecycleKind::kSessionStart: return "session_start";
    case LifecycleKind::kSessionIdentify: return "session_identify";
    case LifecycleKind::kTraitsUpdated: return "traits_updated";
    case LifecycleKind::kUserChanged: return "user_changed";
    case LifecycleKind::kSessionEnd: return "session_end";
  }
  return "session_start";
}

void LifecycleLane::push(LifecycleKind kind, const At& triggered,
                         std::optional<LocaleInfo> active_locale) {
  entries_.push_back(
      LifecycleEntry{next_seq_++, kind, triggered, std::move(active_locale)});
}

bool LifecycleLane::has_session_start() const {
  for (const LifecycleEntry& entry : entries_) {
    if (entry.kind == LifecycleKind::kSessionStart) {
      return true;
    }
  }
  return false;
}

std::optional<IdentityPost> IdentityDebounce::take() {
  std::optional<IdentityPost> post;
  if (user_at_ && traits_at_) {
    // Identity facts always carry a wall time (`identity.set`, `traits.set`).
    const bool user_later = user_at_->wall_us > traits_at_->wall_us;
    post = IdentityPost{LifecycleKind::kSessionIdentify,
                        user_later ? *user_at_ : *traits_at_};
  } else if (user_at_) {
    post = IdentityPost{LifecycleKind::kUserChanged, *user_at_};
  } else if (traits_at_) {
    post = IdentityPost{LifecycleKind::kTraitsUpdated, *traits_at_};
  }
  reset();
  return post;
}

void apply_lifecycle_response(LifecycleKind kind, const std::string& body,
                              const std::string& local_session_id,
                              CollectorIds* ids) {
  const std::string_view raw = dart_trim(body);
  Value decoded;
  ParseError parse_error;
  if (raw.empty() ||
      !parse_json(raw, kResponseMaxDepth, &decoded, &parse_error) ||
      !decoded.is_object()) {
    use_local_id_for_start(kind, local_session_id, ids);
    return;
  }
  if (kind == LifecycleKind::kSessionStart) {
    OptString server_id;
    if (!read_optional_string(decoded, "sessionId", &server_id)) {
      use_local_id_for_start(kind, local_session_id, ids);
      return;
    }
    ids->session_id =
        server_id && !server_id->empty() ? *server_id : local_session_id;
  }
  OptString traits_id;
  if (!read_optional_string(decoded, "traitsId", &traits_id)) {
    use_local_id_for_start(kind, local_session_id, ids);
    return;
  }
  if (traits_id && !traits_id->empty()) {
    ids->traits_id = traits_id;
  }
}

}  // namespace engine
}  // namespace tugboat
