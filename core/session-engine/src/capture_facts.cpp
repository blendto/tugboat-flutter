#include "capture_facts.h"

#include <optional>
#include <utility>

#include "name_table.h"

namespace tugboat {
namespace engine {

namespace {

constexpr NamedValue<CaptureResultOutcome> kOutcomes[] = {
    {"captured", CaptureResultOutcome::kCaptured},
    {"paintUnchanged", CaptureResultOutcome::kPaintUnchanged},
    {"failed", CaptureResultOutcome::kFailed},
    {"cancelled", CaptureResultOutcome::kCancelled},
};

bool decode_rect(const Value& json, const std::string& path,
                 BoundaryRect* out, Error* error) {
  const ObjectReader r(json, path, error);
  return r.check_keys({"x", "y", "width", "height"}) &&
         r.req_double("x", &out->x) && r.req_double("y", &out->y) &&
         r.req_double("width", &out->width) &&
         r.req_double("height", &out->height);
}

bool decode_frame(const Value& json, const std::string& path,
                  CapturedFrame* out, Error* error) {
  const ObjectReader r(json, path, error);
  std::optional<bool> masked;
  if (!r.check_keys({"handle", "width", "height", "contentHash", "dHash",
                     "structureSignature", "masked", "byteLength",
                     "captureMicros", "requestedBackend", "resolvedBackend",
                     "fallbackReason"}) ||
      !read_non_empty(r, "handle", &out->handle) ||
      !read_non_negative(r, "width", &out->width) ||
      !read_non_negative(r, "height", &out->height) ||
      !r.req_string("contentHash", &out->content_hash) ||
      !r.opt_string("dHash", &out->dhash) ||
      !r.opt_string("structureSignature", &out->structure_signature) ||
      !r.opt_bool("masked", &masked) ||
      !read_non_negative(r, "byteLength", &out->byte_length) ||
      !read_non_negative(r, "captureMicros", &out->capture_micros) ||
      !r.opt_string("requestedBackend", &out->requested_backend) ||
      !r.opt_string("resolvedBackend", &out->resolved_backend) ||
      !r.opt_string("fallbackReason", &out->fallback_reason)) {
    return false;
  }
  if (!masked) return r.reject("masked", "required");
  out->masked = *masked;
  return true;
}

// A day: the bound of every engine duration, so sums never overflow.
constexpr int64_t kMaxMicros = 86400000000;

bool read_micros(const ObjectReader& r, const char* key, int64_t* out) {
  std::optional<int64_t> value;
  if (!r.opt_int(key, &value)) return false;
  if (value && *value < 0) return r.reject(key, "must not be negative");
  if (value && *value > kMaxMicros) {
    return r.reject(key, "must be at most 86400000000");
  }
  *out = value.value_or(0);
  return true;
}

bool decode_timings(const ObjectReader& parent,
                    std::optional<CaptureTimings>* out, Error* error) {
  const Value* json = nullptr;
  if (!parent.opt_object("timings", &json)) return false;
  if (json == nullptr) return true;
  const ObjectReader r(*json, parent.child("timings"), error);
  CaptureTimings timings;
  if (!r.check_keys({"frameWaitMicros", "readbackMicros", "maskMicros",
                     "encodeMicros"}) ||
      !read_micros(r, "frameWaitMicros", &timings.frame_wait_us) ||
      !read_micros(r, "readbackMicros", &timings.readback_us) ||
      !read_micros(r, "maskMicros", &timings.mask_us) ||
      !read_micros(r, "encodeMicros", &timings.encode_us)) {
    return false;
  }
  *out = timings;
  return true;
}

bool decode_failure(const ObjectReader& r, CaptureResult* out) {
  std::optional<std::string> name;
  if (!r.opt_string("failure", &name)) return false;
  if (!name) return true;
  if (out->outcome != CaptureResultOutcome::kFailed) {
    return r.reject("failure", "only allowed when failed");
  }
  out->failure = parse_capture_failure(*name);
  return out->failure.has_value() ||
         r.reject("failure", "unknown capture failure");
}

bool decode_captured(const ObjectReader& r, CaptureResult* out,
                     Error* error) {
  const Value* frame = nullptr;
  if (!r.opt_object("frame", &frame)) return false;
  if (out->outcome != CaptureResultOutcome::kCaptured) {
    return reject_present(r, {"frame", "boundaryRect"},
                          "only allowed when captured");
  }
  if (frame == nullptr) return r.reject("frame", "required when captured");
  CapturedFrame captured;
  const Value* rect = nullptr;
  if (!decode_frame(*frame, r.child("frame"), &captured, error) ||
      !r.opt_object("boundaryRect", &rect)) {
    return false;
  }
  if (rect != nullptr) {
    BoundaryRect boundary;
    if (!decode_rect(*rect, r.child("boundaryRect"), &boundary, error)) {
      return false;
    }
    captured.boundary = boundary;
  }
  out->frame = std::move(captured);
  return true;
}

}  // namespace

bool decode_capture_result(const Value& input, const std::string& path,
                           CaptureResult* out, Error* error) {
  const ObjectReader r(input, path, error);
  return r.check_keys({"requestId", "outcome", "frame", "boundaryRect",
                       "failure", "timings"}) &&
         read_non_empty(r, "requestId", &out->request_id) &&
         read_named(r, "outcome", kOutcomes, &out->outcome) &&
         decode_failure(r, out) && decode_timings(r, &out->timings, error) &&
         decode_captured(r, out, error);
}

bool decode_surface_fact(const Value& input, const std::string& path,
                         SurfaceFact* out, Error* error) {
  const ObjectReader r(input, path, error);
  const Value* rect = nullptr;
  return r.check_keys({"boundaryRect", "generation"}) &&
         r.req_object("boundaryRect", &rect) &&
         decode_rect(*rect, r.child("boundaryRect"), &out->boundary, error) &&
         read_non_negative(r, "generation", &out->generation);
}

}  // namespace engine
}  // namespace tugboat
