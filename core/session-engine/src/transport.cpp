#include "transport.h"

#include "retry_after.h"

namespace tugboat {
namespace engine {

namespace {

bool decode_outcome(const ObjectReader& r, TransportOutcome* out) {
  std::string name;
  if (!r.req_string("outcome", &name)) {
    return false;
  }
  if (name == "http") {
    *out = TransportOutcome::kHttp;
  } else if (name == "error") {
    *out = TransportOutcome::kError;
  } else if (name == "timeout") {
    *out = TransportOutcome::kTimeout;
  } else {
    return r.reject("outcome", "expected http, error, or timeout");
  }
  return true;
}

bool check_http_fields(const ObjectReader& r, const TransportResult& result,
                       bool has_body, bool has_retry_after) {
  if (result.outcome != TransportOutcome::kHttp) {
    if (result.status) {
      return r.reject("status", "only allowed with outcome http");
    }
    if (has_body) {
      return r.reject("body", "only allowed with outcome http");
    }
    return !has_retry_after ||
           r.reject("retryAfter", "only allowed with outcome http");
  }
  if (!result.status) {
    return r.reject("status", "required with outcome http");
  }
  if (*result.status < 100 || *result.status > 599) {
    return r.reject("status", "expected an HTTP status in [100, 599]");
  }
  if (result.body.size() > kMaxResponseBodyBytes) {
    return r.reject("body", "longer than 64 KiB");
  }
  return true;
}

}  // namespace

bool decode_transport_result(const Value& input, const std::string& path,
                             TransportResult* out, Error* error) {
  const ObjectReader r(input, path, error);
  std::optional<std::string> body;
  std::optional<std::string> retry_after;
  if (!r.check_keys({"requestId", "outcome", "status", "body", "retryAfter"}) ||
      !r.req_string("requestId", &out->request_id) ||
      !decode_outcome(r, &out->outcome) || !r.opt_int("status", &out->status) ||
      !r.opt_string("body", &body) ||
      !r.opt_string("retryAfter", &retry_after)) {
    return false;
  }
  out->body = body.value_or(std::string());
  if (retry_after) {
    out->retry_after = trim_retry_after_field(*retry_after);
  }
  return check_http_fields(r, *out, body.has_value(), retry_after.has_value());
}

Verdict classify(const TransportResult& result) {
  if (result.outcome != TransportOutcome::kHttp) {
    return Verdict::kRetry;
  }
  const int64_t status = *result.status;
  if (status == 202) {
    return Verdict::kAccepted;
  }
  if (status == 408 || status == 429 || status >= 500) {
    return Verdict::kRetry;
  }
  return Verdict::kDrop;
}

}  // namespace engine
}  // namespace tugboat
