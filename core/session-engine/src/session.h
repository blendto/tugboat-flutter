// The in-memory session (TugboatSession) and the engine's id counter
// (docs/stateful-engine.md section 4.1). Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_SESSION_H
#define TUGBOAT_SESSION_ENGINE_SESSION_H

#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <utility>
#include <vector>

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

// TugboatScrollSample: one sampled offset of a scrolling scrollable.
struct ScrollSample {
  int64_t at_ms = 0;
  double offset = 0;
  OptString before_frame;
  OptString after_frame;
  OptString scrollable_fingerprint;
  OptString axis;
  std::optional<double> offset_norm;
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
  const std::deque<Frame>& frames() const { return frames_; }
  const std::deque<ScrollSample>& scroll_samples() const {
    return scroll_samples_;
  }
  bool truncated() const { return truncated_; }

  // Event `atMs` for a fact at `mono_us`.
  int64_t at_ms(int64_t mono_us) const;

  // Appends, then drops the oldest events beyond `max_events`; dropping
  // makes `truncated` true for the rest of the session (Dart `_trim`).
  void append(Event event, int64_t max_events);

  // Appends an accepted frame, then drops the oldest beyond `max_frames`
  // (sticky `truncated`). Returns the ids of the dropped frames.
  std::vector<std::string> append_frame(Frame frame, int64_t max_frames);

  // Appends a scroll sample, then drops the oldest beyond `max_samples`
  // (sticky `truncated`, Dart `_trimScrollSamples`).
  void append_scroll_sample(ScrollSample sample, int64_t max_samples);
  // The newest scroll sample, or nullptr (Dart `scrollSamples.last`).
  ScrollSample* last_scroll_sample() {
    return scroll_samples_.empty() ? nullptr : &scroll_samples_.back();
  }

 private:
  SessionHeader header_;
  std::optional<LocaleInfo> locale_;
  std::deque<Event> events_;
  std::deque<Frame> frames_;
  std::deque<ScrollSample> scroll_samples_;
  bool truncated_ = false;
};

// TugboatSession.toJson (session schema 10). `scrollSamples` is written only
// when there are any.
Value session_snapshot_json(const Session& session);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_SESSION_H
