// The in-memory session (TugboatSession) and the engine's id counter
// (docs/stateful-engine.md section 4.1). Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_SESSION_H
#define TUGBOAT_SESSION_ENGINE_SESSION_H

#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <utility>

#include "host.h"
#include "json.h"
#include "models.h"

namespace tugboat {
namespace engine {

// One counter per engine handle for `event-N`, `frame-N`,
// `capture_request-N`, and `capture_execution-N`, starting at 0. Never reset
// per session (change C7: kept as Dart has it).
class IdCounter {
 public:
  std::string next(const char* prefix);

 private:
  int64_t next_ = 0;
};

// What `session.start` fixes for the session's lifetime.
struct SessionHeader {
  std::string id;  // `session-<wallUs>`
  int64_t started_at_wall_us = 0;
  int64_t start_mono_us = 0;
  std::string platform;
  double viewport_width = 0;
  double viewport_height = 0;
  AppInfo app;
  OptString activation_request_id;
  OptString exploration_run_id;
  int64_t session_epoch = 0;
};

class Session {
 public:
  explicit Session(SessionHeader header) : header_(std::move(header)) {}

  const SessionHeader& header() const { return header_; }
  const std::string& id() const { return header_.id; }
  const std::optional<LocaleInfo>& locale() const { return locale_; }
  void set_locale(std::optional<LocaleInfo> locale) {
    locale_ = std::move(locale);
  }
  const std::deque<Event>& events() const { return events_; }
  bool truncated() const { return truncated_; }

  // Event `atMs` for a fact at `mono_us`.
  int64_t at_ms(int64_t mono_us) const;

  // Appends, then drops the oldest events beyond `max_events`; dropping
  // makes `truncated` true for the rest of the session (Dart `_trim`).
  void append(Event event, int64_t max_events);

 private:
  SessionHeader header_;
  std::optional<LocaleInfo> locale_;
  std::deque<Event> events_;
  bool truncated_ = false;
};

// TugboatSession.toJson (session schema 10). Frames and scroll samples are
// empty until later phases record them.
Value session_snapshot_json(const Session& session);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_SESSION_H
