// Unit tests for collector delivery parts whose edge cases scenario fixtures
// do not reach cheaply: the lifecycle handshake parser, frame numbers, gap
// reporting thresholds, the identity debounce tie, frame retention, queue
// bounds, and multipart bodies. Delivery behaviour over time is pinned by
// conformance/engine/scenario/delivery-*.
#include <cstdint>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <utility>

#include "delivery_gaps.h"
#include "event_queue.h"
#include "frame_lane.h"
#include "frame_retention.h"
#include "lifecycle_lane.h"
#include "json.h"
#include "lifecycle_lane.h"
#include "output.h"
#include "retry_after.h"
#include "transport.h"
#include "conformance_files.h"
#include "unit_support.h"

namespace {

using tugboat::engine::apply_lifecycle_response;
using tugboat::engine::At;
using tugboat::engine::CollectorIds;
using tugboat::engine::EventDropReason;
using tugboat::engine::EventGaps;
using tugboat::engine::EventQueue;
using tugboat::engine::FrameGaps;
using tugboat::engine::FrameLane;
using tugboat::engine::FrameOwner;
using tugboat::engine::FrameRetention;
using tugboat::engine::FrameUploads;
using tugboat::engine::IdentityDebounce;
using tugboat::engine::LifecycleKind;
using tugboat::engine::Output;
using tugboat::engine::PendingFrame;
using tugboat::engine::Value;

const LifecycleKind kStart = LifecycleKind::kSessionStart;

CollectorIds start_ids(const std::string& body) {
  CollectorIds ids;
  apply_lifecycle_response(kStart, body, "local", &ids);
  return ids;
}

void test_handshake_session_id() {
  CHECK(start_ids("{\"sessionId\":\"srv\"}").session_id == "srv");
  // Dart `String.trim` whitespace, including BOM and NBSP, around the JSON.
  CHECK(start_ids("\xEF\xBB\xBF \t{\"sessionId\":\"srv\"}\n\xC2\xA0")
            .session_id == "srv");
  for (const char* fallback :
       {"", "  \n", "ok", "[]", "null", "{}", "{\"sessionId\":\"\"}",
        "{\"sessionId\":null}", "{\"sessionId\":7}",
        // Duplicate keys: the strict parser rejects the body (Dart keeps the
        // last key), so the start falls back. Documented in the README.
        "{\"sessionId\":\"a\",\"sessionId\":\"b\"}"}) {
    CHECK(start_ids(fallback).session_id == "local");
  }
}

void test_handshake_traits_id() {
  CollectorIds ids = start_ids("{\"sessionId\":\"srv\",\"traitsId\":\"t1\"}");
  CHECK(ids.traits_id == "t1");
  // A later response keeps the session id and replaces a non-empty traits id.
  apply_lifecycle_response(LifecycleKind::kUserChanged,
                           "{\"sessionId\":\"other\",\"traitsId\":\"t2\"}",
                           "local", &ids);
  CHECK(ids.session_id == "srv");
  CHECK(ids.traits_id == "t2");
  // An empty traits id and a failed cast leave the cached one.
  apply_lifecycle_response(LifecycleKind::kUserChanged, "{\"traitsId\":\"\"}",
                           "local", &ids);
  apply_lifecycle_response(LifecycleKind::kUserChanged, "{\"traitsId\":3}",
                           "local", &ids);
  CHECK(ids.traits_id == "t2");
  // Non-start posts never set the session id.
  CollectorIds fresh;
  apply_lifecycle_response(LifecycleKind::kSessionEnd, "", "local", &fresh);
  CHECK(!fresh.session_id);
  // A start whose traitsId cast fails keeps the session id it already read.
  CHECK(start_ids("{\"sessionId\":\"srv\",\"traitsId\":1}").session_id ==
        "srv");
}

void test_frame_number() {
  int64_t n = 0;
  CHECK(tugboat::engine::frame_number("frame-42", &n) && n == 42);
  CHECK(tugboat::engine::frame_number("007", &n) && n == 7);
  CHECK(!tugboat::engine::frame_number("frame-", &n));
  CHECK(!tugboat::engine::frame_number("frame-99999999999999999999", &n));
  CHECK(tugboat::engine::frame_number("f9223372036854775807", &n) &&
        n == INT64_MAX);
}

void test_frame_gaps() {
  FrameGaps gaps;
  std::optional<tugboat::engine::GapReport> failed = gaps.failed(503, 4);
  CHECK(failed && failed->id == "collector-frame-upload-0");
  CHECK(!gaps.failed(500, 1));          // latched
  CHECK(!gaps.flushed(true));           // a dropped chunk: no recovery
  CHECK(gaps.flushed(false));           // recovered, latch cleared
  CHECK(!gaps.flushed(false));
  CHECK(gaps.failed(std::nullopt, 1));  // reported again
  CHECK(gaps.evicted(1));               // 1
  CHECK(!gaps.evicted(2));              // 3
  CHECK(gaps.evicted(1));               // 4
  CHECK(!gaps.evicted(3));              // 7: Dart misses the crossing of 4..8
  CHECK(!gaps.evicted(0));
}

void test_event_gaps() {
  EventGaps gaps;
  CHECK(gaps.dropped(EventDropReason::kEvicted, 1, std::nullopt));   // 1
  CHECK(gaps.dropped(EventDropReason::kRejected, 1, 400));           // 2
  CHECK(!gaps.dropped(EventDropReason::kEvicted, 1, std::nullopt));  // 3
  CHECK(gaps.dropped(EventDropReason::kEvicted, 13, std::nullopt));  // 16
  CHECK(!gaps.dropped(EventDropReason::kEvicted, 0, std::nullopt));
}

void test_identity_debounce_tie() {
  IdentityDebounce debounce;
  CHECK(!debounce.take());
  debounce.mark_user_changed(At{10, 5000});
  debounce.mark_traits_changed(At{20, 5000});
  const auto post = debounce.take();
  CHECK(post && post->kind == LifecycleKind::kSessionIdentify);
  CHECK(post && post->triggered.mono_us == 20);  // a tie picks the traits
  CHECK(!debounce.dirty());
}

void test_frame_retention_exactly_once() {
  FrameRetention retention;
  Output out;
  retention.retain("frame-1", "h-1", FrameOwner::kSession);
  retention.retain("frame-1", "h-1", FrameOwner::kDelivery);
  retention.release("frame-1", FrameOwner::kDelivery, &out);
  CHECK(out.effects.empty());
  retention.release("frame-1", FrameOwner::kDelivery, &out);  // not held
  CHECK(out.effects.empty());
  retention.release("frame-1", FrameOwner::kSession, &out);
  CHECK(out.effects.size() == 1);
  retention.release("frame-1", FrameOwner::kSession, &out);  // gone
  CHECK(out.effects.size() == 1);
}

PendingFrame pending(int64_t n) {
  return PendingFrame{n, "frame-" + std::to_string(n), "h-" + std::to_string(n),
                      Value::object()};
}

void test_frame_lane_bounds() {
  FrameLane lane;
  CHECK(lane.push(pending(5), 2).empty());
  CHECK(lane.push(pending(3), 2).empty());
  FrameUploads evicted = lane.push(pending(4), 2);
  CHECK(evicted.size() == 1 && evicted[0].frame_no == 5);
  FrameUploads retry;
  retry.push_back(pending(1));
  evicted = lane.requeue_front(std::move(retry), 2);  // [1, 3, 4]
  CHECK(evicted.size() == 1 && evicted[0].frame_no == 1);
  const FrameUploads sorted = lane.take_sorted();
  CHECK(sorted.size() == 2 && sorted[0].frame_no == 3 &&
        sorted[1].frame_no == 4);
  CHECK(lane.empty());
}

void test_multipart_body() {
  FrameUploads uploads;
  uploads.push_back(pending(3));
  uploads.push_back(pending(10));
  const tugboat::engine::MultipartBody body =
      tugboat::engine::frame_upload_body("srv", uploads, 0, 2);
  CHECK(body.fields.size() == 3);
  CHECK(body.fields[0].first == "sessionId" && body.fields[0].second == "srv");
  CHECK(body.fields[1].first == "frameNos" &&
        body.fields[1].second == "3,10");
  CHECK(body.fields[2].first == "frameMetadata" &&
        body.fields[2].second == "[{},{}]");
  CHECK(body.frames.size() == 2 && body.frames[1].handle == "h-10" &&
        body.frames[1].filename == "10.jpg");
}

void test_event_queue_bounds_and_stamping() {
  EventQueue queue;
  for (int i = 0; i < 4; ++i) {
    Value event = Value::object();
    event.set("id", Value::string("e" + std::to_string(i)));
    CHECK(queue.push(std::move(event), 3) == (i == 3 ? 1u : 0u));
  }
  tugboat::engine::EventBatch batch = queue.take(2);
  CHECK(batch.size() == 2 && queue.pending() == 1);
  CHECK_EQ(tugboat::engine::stamp_event_batch(&batch, "s", std::string("t")),
           std::string("{\"events\":[{\"id\":\"e1\",\"sessionId\":\"s\","
                       "\"traitsId\":\"t\"},{\"id\":\"e2\",\"sessionId\":"
                       "\"s\",\"traitsId\":\"t\"}]}"));
  // A re-stamp replaces in place; an empty traits id is not stamped.
  CHECK_EQ(tugboat::engine::stamp_event_batch(&batch, "s2", std::string()),
           std::string("{\"events\":[{\"id\":\"e1\",\"sessionId\":\"s2\","
                       "\"traitsId\":\"t\"},{\"id\":\"e2\",\"sessionId\":"
                       "\"s2\",\"traitsId\":\"t\"}]}"));
  CHECK(queue.push_retry(batch, 1) == 0);
  CHECK(queue.push_retry(batch, 1) == 2);  // the older batch is evicted
  CHECK(queue.event_count() == 3);
}

void test_classify() {
  using tugboat::engine::TransportOutcome;
  using tugboat::engine::TransportResult;
  using tugboat::engine::Verdict;
  auto http = [](int64_t status) {
    TransportResult r;
    r.outcome = TransportOutcome::kHttp;
    r.status = status;
    return tugboat::engine::classify(r);
  };
  CHECK(http(202) == Verdict::kAccepted);
  for (int64_t status : {200, 201, 204, 400, 401, 404, 413, 499}) {
    CHECK(http(status) == Verdict::kDrop);
  }
  for (int64_t status : {408, 429, 500, 503, 599}) {
    CHECK(http(status) == Verdict::kRetry);
  }
  TransportResult error;
  error.outcome = TransportOutcome::kTimeout;
  CHECK(tugboat::engine::classify(error) == Verdict::kRetry);
}

void test_retry_after_parse() {
#ifndef TB_CONFORMANCE_DIR
#error "TB_CONFORMANCE_DIR must point at <repo>/conformance"
#endif
  using tugboat::engine::parse_retry_after_delay_ms;
  using tugboat::engine::parse_json;
  using tugboat::engine::ParseError;
  using tugboat::engine::Value;
  std::ifstream in(std::string(TB_CONFORMANCE_DIR) + "/" +
                  conformance::kRetryAfterVectorsFile);
  std::stringstream buffer;
  buffer << in.rdbuf();
  Value doc;
  ParseError parse_error;
  CHECK(parse_json(buffer.str(), 64, &doc, &parse_error));
  const Value* cap_value = doc.find("capMs");
  const Value* wall_value = doc.find("nowWallUs");
  const Value* vectors = doc.find("vectors");
  CHECK(cap_value && cap_value->is_int());
  CHECK(wall_value && wall_value->is_int());
  CHECK(vectors && vectors->is_array());
  const int64_t cap_ms = cap_value->as_int();
  const int64_t wall = wall_value->as_int();
  for (const Value& entry : vectors->items()) {
    const Value* raw = entry.find("raw");
    const Value* expected = entry.find("expectedMs");
    CHECK(raw && raw->is_string());
    const std::optional<int64_t> parsed =
        parse_retry_after_delay_ms(raw->as_string(), wall, cap_ms);
    if (expected->is_null()) {
      CHECK(!parsed);
    } else {
      CHECK(expected->is_int());
      CHECK(parsed.has_value() && *parsed == expected->as_int());
    }
  }
  CHECK(parse_retry_after_delay_ms("3", wall + 10'000'000, cap_ms) == 3'000);
  CHECK(parse_retry_after_delay_ms("Sun, 06 Nov 1994 08:49:37 GMT",
                                   std::nullopt, cap_ms) == std::nullopt);
}

void test_transport_retry_after_decode() {
  using tugboat::engine::decode_transport_result;
  using tugboat::engine::parse_json;
  using tugboat::engine::ParseError;
  using tugboat::engine::TransportResult;
  tugboat::engine::Error decode_error;
  ParseError parse_error;
  TransportResult result;
  Value ok;
  CHECK(parse_json(
      R"({"requestId":"http-1","outcome":"http","status":429,"retryAfter":"2"})",
      64, &ok, &parse_error));
  CHECK(decode_transport_result(ok, "$.input", &result, &decode_error));
  CHECK(result.retry_after == "2");
  Value bad;
  CHECK(parse_json(R"({"requestId":"http-1","outcome":"error","retryAfter":"2"})",
                   64, &bad, &parse_error));
  CHECK(!decode_transport_result(bad, "$.input", &result, &decode_error));
  const std::string long_retry(200, '9');
  std::string accepted_json =
      R"({"requestId":"http-2","outcome":"http","status":202,"retryAfter":")";
  accepted_json += long_retry;
  accepted_json += R"("})";
  Value accepted;
  CHECK(parse_json(accepted_json, 512, &accepted, &parse_error));
  CHECK(decode_transport_result(accepted, "$.input", &result, &decode_error));
  CHECK(result.status == 202);
  // Kept raw on decode; the one trim and length check is in the parser.
  CHECK(result.retry_after == long_retry);
  CHECK(!tugboat::engine::parse_retry_after_delay_ms(long_retry, std::nullopt,
                                                     60'000));
}

}  // namespace

int main() {
  test_handshake_session_id();
  test_handshake_traits_id();
  test_frame_number();
  test_frame_gaps();
  test_event_gaps();
  test_identity_debounce_tie();
  test_frame_retention_exactly_once();
  test_frame_lane_bounds();
  test_multipart_body();
  test_event_queue_bounds_and_stamping();
  test_classify();
  test_retry_after_parse();
  test_transport_retry_after_decode();
  return unit::finish("delivery");
}
