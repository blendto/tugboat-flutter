#include "frame_store.h"

#include <algorithm>
#include <iterator>
#include <set>
#include <utility>
#include <vector>

namespace tugboat {
namespace engine {

bool RequestContext::surface_compatible_with(
    const RequestContext& other) const {
  return session_id == other.session_id && route_epoch == other.route_epoch &&
         route == other.route && navigator_id == other.navigator_id &&
         route_instance_id == other.route_instance_id;
}

bool RequestContext::compatible_with(const RequestContext& other) const {
  return surface_compatible_with(other) &&
         boundary_generation == other.boundary_generation;
}

CaptureContext RequestContext::effect_context() const {
  CaptureContext context;
  context.route_epoch = route_epoch;
  context.navigator_id = navigator_id;
  context.route_instance_id = route_instance_id;
  context.boundary_generation = boundary_generation;
  return context;
}

void FrameStore::reset() {
  provenance_.clear();
  frame_by_content_.clear();
  latest_frame_id_.reset();
  sequence_ = 0;
  last_dhash_.reset();
  last_structure_.reset();
}

FrameRecord FrameStore::accept(const CapturedFrame& captured,
                               const RequestContext& context, int64_t at_ms,
                               int64_t max_frames, IdCounter* ids,
                               Session* session, FrameRetention* retention,
                               Output* out) {
  Frame frame;
  frame.id = ids->next("frame");
  frame.at_ms = at_ms;
  frame.width = captured.width;
  frame.height = captured.height;
  frame.content_hash = captured.content_hash;
  frame.masked = captured.masked;
  frame.trigger = context.trigger;
  frame.byte_length = captured.byte_length;
  frame.capture_micros = captured.capture_micros;
  frame.capture_session_id = session->id();
  frame.requested_backend = captured.requested_backend;
  frame.resolved_backend = captured.resolved_backend;
  frame.fallback_reason = captured.fallback_reason;

  FrameProvenance provenance;
  provenance.frame_id = frame.id;
  provenance.context = context;
  provenance.context.boundary = captured.boundary;
  provenance.completed_at_ms = at_ms;
  provenance.sequence = ++sequence_;
  provenance.pixel_width = captured.width;
  provenance.pixel_height = captured.height;
  provenance_[frame.id] = std::move(provenance);
  frame_by_content_[captured.content_hash] = frame.id;
  latest_frame_id_ = frame.id;
  commit_baselines(captured);

  const FrameRecord record{captured.handle, frame};
  out->records.push_back(record);
  retention->retain(record.frame.id, captured.handle, FrameOwner::kSession);
  const std::vector<std::string> dropped =
      session->append_frame(std::move(frame), max_frames);
  for (const std::string& id : dropped) {
    trim(id, *session);
    // The session no longer references the trimmed frame's bytes.
    retention->release(id, FrameOwner::kSession, out);
  }
  if (!dropped.empty()) forget_unreferenced(*session);
  return record;
}

void FrameStore::trim(const std::string& dropped, const Session& session) {
  // A trimmed frame keeps a tombstone so it can never be attached again.
  const auto it = provenance_.find(dropped);
  if (it == provenance_.end()) return;
  it->second.available = false;
  const auto& frames = session.frames();
  // The content index names the dropped frame only when it was the newest
  // with its pixels; a newer retained duplicate takes over the entry.
  for (auto content = frame_by_content_.begin();
       content != frame_by_content_.end(); ++content) {
    if (content->second != dropped) continue;
    const auto retained = std::find_if(
        frames.rbegin(), frames.rend(), [&](const Frame& frame) {
          return frame.content_hash == content->first;
        });
    if (retained == frames.rend()) {
      frame_by_content_.erase(content);
    } else {
      content->second = retained->id;
    }
    break;
  }
  if (latest_frame_id_ && *latest_frame_id_ == dropped) {
    latest_frame_id_ = frames.empty() ? OptString() : frames.back().id;
  }
}

void FrameStore::forget_unreferenced(const Session& session) {
  // Dart `_trimFrameMetadata`: provenance stays only for retained frames
  // and for frames an event or scroll sample still names.
  std::set<std::string> referenced;
  for (const Frame& frame : session.frames()) referenced.insert(frame.id);
  for (const Event& event : session.events()) {
    if (event.before_frame) referenced.insert(*event.before_frame);
    if (event.after_frame) referenced.insert(*event.after_frame);
  }
  for (const ScrollSample& sample : session.scroll_samples()) {
    if (sample.before_frame) referenced.insert(*sample.before_frame);
    if (sample.after_frame) referenced.insert(*sample.after_frame);
  }
  for (auto it = provenance_.begin(); it != provenance_.end();) {
    it = referenced.count(it->first) != 0 ? std::next(it)
                                          : provenance_.erase(it);
  }
}

const FrameProvenance* FrameStore::compatible_latest(
    const RequestContext& context) const {
  if (!latest_frame_id_) return nullptr;
  const FrameProvenance* frame = find(*latest_frame_id_);
  return frame != nullptr && frame->available &&
                 frame->context.compatible_with(context)
             ? frame
             : nullptr;
}

const FrameProvenance* FrameStore::surface_compatible_latest(
    const RequestContext& context) const {
  if (!latest_frame_id_) return nullptr;
  const FrameProvenance* frame = find(*latest_frame_id_);
  return frame != nullptr && frame->available &&
                 frame->context.surface_compatible_with(context)
             ? frame
             : nullptr;
}

bool FrameStore::is_compatible(const std::string& frame_id,
                               const RequestContext& context) const {
  const FrameProvenance* frame = find(frame_id);
  return frame != nullptr && frame->available &&
         frame->context.compatible_with(context);
}

OptString FrameStore::reuse(const std::string& frame_id,
                            const RequestContext& context) {
  if (!is_compatible(frame_id, context)) return std::nullopt;
  latest_frame_id_ = frame_id;
  return frame_id;
}

OptString FrameStore::frame_with_content(
    const std::string& content_hash) const {
  const auto it = frame_by_content_.find(content_hash);
  if (it == frame_by_content_.end()) return std::nullopt;
  return it->second;
}

std::optional<DHashBaseline> FrameStore::dhash_baseline() const {
  if (!last_dhash_ || !last_structure_) return std::nullopt;
  return DHashBaseline{*last_dhash_, *last_structure_};
}

void FrameStore::commit_baselines(const CapturedFrame& captured) {
  if (captured.dhash && !captured.dhash->empty()) last_dhash_ = captured.dhash;
  last_structure_ = captured.structure_signature;
}

const FrameProvenance* FrameStore::find(const std::string& frame_id) const {
  const auto it = provenance_.find(frame_id);
  return it == provenance_.end() ? nullptr : &it->second;
}

const FrameProvenance* FrameStore::latest(
    const std::string& session_id) const {
  if (!latest_frame_id_) return nullptr;
  const FrameProvenance* frame = find(*latest_frame_id_);
  if (frame == nullptr || !frame->available ||
      frame->context.session_id != session_id) {
    return nullptr;
  }
  return frame;
}

OptString FrameStore::observed_after(
    const OptString& frame_id, const ObservationBoundary& boundary) const {
  if (!frame_id) return std::nullopt;
  const FrameProvenance* frame = find(*frame_id);
  if (frame == nullptr || !frame->available ||
      frame->context.session_id != boundary.session_id ||
      frame->completed_at_ms < boundary.at_ms) {
    return std::nullopt;
  }
  if (boundary.after_sequence && frame->sequence <= *boundary.after_sequence) {
    return std::nullopt;
  }
  return frame_id;
}

void FrameStore::restamp_initial_route(const VisibleRoute& visible) {
  for (auto& entry : provenance_) {
    FrameProvenance& frame = entry.second;
    if (!frame.available || frame.context.trigger != FrameTrigger::kInitial) {
      continue;
    }
    frame.context.route = visible.route;
    frame.context.navigator_id = visible.navigator_id;
    frame.context.route_instance_id = visible.route_instance_id;
  }
}

}  // namespace engine
}  // namespace tugboat
