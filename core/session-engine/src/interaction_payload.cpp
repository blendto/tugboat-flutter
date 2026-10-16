#include "interaction_payload.h"

#include <algorithm>
#include <optional>
#include <string>
#include <utility>

namespace tugboat {
namespace engine {

namespace {

struct Normalized {
  double x = 0;
  double y = 0;
};

Value normalized_json(const Normalized& point) {
  Value out = Value::object();
  out.set("xNorm", Value::number(point.x));
  out.set("yNorm", Value::number(point.y));
  return out;
}

double clamp_unit(double value) { return std::min(1.0, std::max(0.0, value)); }

// Dart `interactionNormalizedPosition`.
std::optional<Normalized> start_position(const CaptureCoordinate& coordinate) {
  if (!coordinate.available || coordinate.normalized_x < 0 ||
      coordinate.normalized_x > 1 || coordinate.normalized_y < 0 ||
      coordinate.normalized_y > 1) {
    return std::nullopt;
  }
  return Normalized{coordinate.normalized_x, coordinate.normalized_y};
}

// Dart `interactionNormalizedPoint`: clamped onto the origin's boundary.
std::optional<Normalized> end_point(Point point,
                                    const CaptureCoordinate& reference) {
  if (!reference.available || reference.boundary_width <= 0 ||
      reference.boundary_height <= 0) {
    return std::nullopt;
  }
  return Normalized{
      clamp_unit((point.x - reference.boundary_x) / reference.boundary_width),
      clamp_unit((point.y - reference.boundary_y) / reference.boundary_height)};
}

bool non_empty(const OptString& value) { return value && !value->empty(); }

const std::optional<Anchor>& publication_anchor(const Transaction& tx) {
  if (tx.gesture == Gesture::kScroll && tx.scroll && tx.scroll->anchor) {
    return tx.scroll->anchor;
  }
  return tx.target_anchor;
}

// Dart `_interactionFingerprint`.
OptString target_fingerprint(const Transaction& tx) {
  if (tx.gesture == Gesture::kScroll && tx.scroll && tx.scroll->anchor &&
      tx.scroll->anchor->fingerprint) {
    return tx.scroll->anchor->fingerprint;
  }
  return tx.target_anchor ? tx.target_anchor->fingerprint : std::nullopt;
}

// Dart `_writeTapResolutionPayload`.
void put_tap_resolution(const Transaction& tx, const OptString& fingerprint,
                        Value* envelope) {
  const OptString confidence =
      tx.target_anchor ? tx.target_anchor->fingerprint_confidence
                       : std::nullopt;
  if (tx.pre_tap_evidence && non_empty(fingerprint) && non_empty(confidence)) {
    envelope->set("fingerprintConfidence", Value::string(*confidence));
  }
  if (!non_empty(fingerprint) && tx.failure_reason) {
    envelope->set("targetResolutionFailureReason",
                  Value::string(tap_failure_reason_name(*tx.failure_reason)));
  }
}

// Dart `_writeTravelGesturePayload`.
void put_travel(const Transaction& tx, const std::optional<Normalized>& start,
                Value* payload) {
  if (tx.end_position) {
    if (const std::optional<Normalized> end =
            end_point(*tx.end_position, tx.origin.coordinate)) {
      payload->set("endPosition", normalized_json(*end));
      if (start) {
        payload->set("delta",
                     normalized_json({end->x - start->x, end->y - start->y}));
      }
    }
  }
  if (tx.pointer_count > 1) {
    payload->set("pointerCount", Value::integer(tx.pointer_count));
  }
  if (is_zoom(tx.gesture) && tx.scale) {
    payload->set("scale", Value::number(*tx.scale));
  }
}

// Dart `_writeScrollGesturePayload`.
void put_scroll(const Transaction& tx, Value* payload) {
  if (!tx.scroll) return;
  payload->set("startOffset", Value::number(tx.scroll->start_offset));
  payload->set("endOffset", Value::number(tx.scroll->end_offset));
  if (tx.scroll->overscroll_count > 0) {
    payload->set("overscrollCount",
                 Value::integer(tx.scroll->overscroll_count));
  }
}

Value gesture_payload(const Transaction& tx) {
  Value payload = Value::object();
  const std::optional<Normalized> start = start_position(tx.origin.coordinate);
  if (start) payload.set("position", normalized_json(*start));
  if (tx.gesture == Gesture::kScroll) {
    put_scroll(tx, &payload);
  } else if (tx.gesture != Gesture::kTap) {
    put_travel(tx, start, &payload);
  }
  return payload;
}

}  // namespace

CaptureCoordinate sample_coordinate(Point position,
                                    const FrameProvenance* frame,
                                    const RequestContext& context) {
  CaptureCoordinate coordinate;
  if (!context.boundary || frame == nullptr || frame->pixel_width <= 0 ||
      frame->pixel_height <= 0 ||
      frame->context.boundary_generation != context.boundary_generation) {
    return coordinate;
  }
  const BoundaryRect& boundary = frame->context.boundary
                                     ? *frame->context.boundary
                                     : *context.boundary;
  if (boundary.width <= 0 || boundary.height <= 0) return coordinate;
  const Point local = position - Point{boundary.x, boundary.y};
  if (local.x < 0 || local.y < 0 || local.x > boundary.width ||
      local.y > boundary.height) {
    return coordinate;  // outside_boundary: never clamped
  }
  coordinate.available = true;
  coordinate.boundary_x = boundary.x;
  coordinate.boundary_y = boundary.y;
  coordinate.boundary_width = boundary.width;
  coordinate.boundary_height = boundary.height;
  coordinate.normalized_x = clamp_unit(local.x / boundary.width);
  coordinate.normalized_y = clamp_unit(local.y / boundary.height);
  return coordinate;
}

Value interaction_data(const Transaction& tx) {
  Value envelope = Value::object();
  envelope.set("interactionSchema", Value::integer(kInteractionSchemaVersion));
  envelope.set("gesture", Value::string(gesture_name(tx.gesture)));
  if (non_empty(tx.origin.route.route)) {
    envelope.set("route", Value::string(*tx.origin.route.route));
  }
  const OptString fingerprint = target_fingerprint(tx);
  if (non_empty(fingerprint)) {
    envelope.set("targetFingerprint", Value::string(*fingerprint));
  }
  if (tx.gesture == Gesture::kTap) {
    put_tap_resolution(tx, fingerprint, &envelope);
  }
  if (tx.gesture == Gesture::kCancelled) return envelope;
  Value payload = gesture_payload(tx);
  if (!payload.members().empty()) envelope.set("payload", std::move(payload));
  return envelope;
}

Event interaction_event(const Transaction& tx) {
  Event event;
  event.id = tx.id();
  event.at_ms = tx.origin.at_ms;
  event.type = "interaction";
  event.stream = EventStream::kSemantic;
  event.before_frame = tx.origin.before_frame;
  event.after_frame = tx.after_frame;
  // Dart `interactionPublicationTargetAnchor`: only an anchor with identity.
  const std::optional<Anchor>& anchor = publication_anchor(tx);
  if (anchor && (non_empty(anchor->fingerprint) ||
                 non_empty(anchor->canonical_path))) {
    event.anchor = anchor;
  }
  event.data = interaction_data(tx);
  event.locale = tx.origin.locale;
  return event;
}

}  // namespace engine
}  // namespace tugboat
