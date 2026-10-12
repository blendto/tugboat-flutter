// Unit tests for the interaction module's parts (docs/stateful-engine.md
// section 9): the pure gesture classifier, the pointer tracker's signals,
// the registry's claim and sweep rules, the payload rules, the capture
// seam, and the claim API phase 3d calls. End-to-end
// behaviour is pinned by conformance/engine/scenario/ instead.
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

#include "capture_seam.h"
#include "engine.h"
#include "gesture_classifier.h"
#include "interaction_claims.h"
#include "interaction_payload.h"
#include "interaction_registry.h"
#include "json.h"
#include "pointer_tracker.h"
#include "unit_support.h"

namespace {

using namespace tugboat::engine;  // NOLINT: test file

std::string to_json(const Value& value) {
  std::string out;
  write_json(value, &out, nullptr);
  return out;
}

// ------------------------------------------------------------ classifier

void test_classify_cluster_table() {
  const GestureConfig config;  // Flutter: 18 / 36 / 18 / 1.08
  struct Case {
    ClusterSample sample;
    std::optional<Gesture> expected;
  };
  const Case cases[] = {
      // Span grows by exactly scaleSlop: zoom in, even with travel.
      {{2, 100, 118, {0, 0}, {0, 50}}, Gesture::kZoomIn},
      {{2, 100, 82, {0, 0}, {0, 0}}, Gesture::kZoomOut},
      // Span change below the slop and travel below panSlop: nothing.
      {{2, 100, 117.9, {0, 0}, {0, 35.9}}, std::nullopt},
      {{2, 100, 100, {0, 0}, {0, 36}}, Gesture::kPan},
      {{3, 100, 100, {0, 0}, {36, 0}}, Gesture::kSwipe},
      // Without a start span only travel can classify.
      {{2, 0, 50, {0, 0}, {0, 0}}, std::nullopt},
  };
  for (const Case& c : cases) {
    CHECK(classify_cluster(config, c.sample) == c.expected);
  }
}

void test_classify_trackpad_and_slop() {
  GestureConfig config;
  CHECK(classify_trackpad(config, 1.08, {0, 0}) == Gesture::kZoomIn);
  CHECK(classify_trackpad(config, 1 / 1.08, {0, 0}) == Gesture::kZoomOut);
  CHECK(classify_trackpad(config, 0.95, {0, 35}) == std::nullopt);
  CHECK(classify_trackpad(config, 1.0, {0, 36}) == Gesture::kPan);
  CHECK(classify_trackpad(config, 0, {0, 0}) == std::nullopt);
  CHECK(!exceeds_touch_slop(config, {0, 0}, {17.9, 0}));
  CHECK(exceeds_touch_slop(config, {0, 0}, {0, 18}));
  // Thresholds are toolkit parameters.
  config.touch_slop = 8;
  CHECK(exceeds_touch_slop(config, {0, 0}, {8, 0}));
  CHECK(max_span({{0, 0}, {3, 4}, {1, 1}}) == 5);
  CHECK(centroid_of({{0, 0}, {2, 4}}) == (Point{1, 2}));
}

// --------------------------------------------------------- pointer tracker

std::string kinds(const PointerSignals& signals) {
  std::string out;
  for (const PointerSignal& signal : signals) {
    static const char* const kNames[] = {"down", "swipe", "cluster",
                                         "suppress", "up", "cancel"};
    out += (out.empty() ? "" : " ");
    out += kNames[signal.index()];
    if (const auto* cluster = std::get_if<MarkClusterSignal>(&signal)) {
      out += std::string(":") + gesture_name(cluster->gesture);
    }
  }
  return out;
}

void test_tracker_single_pointer() {
  const GestureConfig config;
  PointerTracker tracker;
  PointerSignals out;
  tracker.down(1, {0, 0}, std::nullopt, &out);
  tracker.move(config, 1, {0, 20}, &out);
  tracker.move(config, 1, {0, 40}, &out);  // marked once
  tracker.up(config, 1, {0, 40}, std::nullopt, &out);
  CHECK_EQ(kinds(out), "down swipe up");
  out.clear();
  tracker.move(config, 1, {0, 80}, &out);  // forgotten after up
  tracker.up(config, 9, {0, 0}, std::nullopt, &out);
  CHECK(out.empty());
}

void test_tracker_cluster_pan_and_late_finger() {
  const GestureConfig config;
  PointerTracker tracker;
  PointerSignals out;
  tracker.down(1, {100, 400}, std::nullopt, &out);
  tracker.down(2, {200, 400}, std::nullopt, &out);
  tracker.move(config, 1, {100, 450}, &out);
  tracker.move(config, 2, {200, 450}, &out);
  CHECK_EQ(kinds(out), "down down cluster:pan suppress");
  out.clear();
  // A finger joining a classified cluster is absorbed at once.
  tracker.down(3, {300, 450}, std::nullopt, &out);
  CHECK_EQ(kinds(out), "down suppress");
  out.clear();
  tracker.up(config, 1, {100, 450}, std::nullopt, &out);
  tracker.up(config, 2, {200, 450}, std::nullopt, &out);
  CHECK(out.empty());  // the gesture waits for every contact
  tracker.up(config, 3, {300, 460}, std::nullopt, &out);
  CHECK_EQ(kinds(out), "cluster:pan up");
  const auto& up = std::get<PointerUpSignal>(out.back());
  CHECK(up.pointer == 1);
  // The primary's last point plus active-centroid travel since it lifted.
  CHECK(up.position == (Point{100, 460}));
}

void test_tracker_cancel_and_pan_zoom() {
  const GestureConfig config;
  PointerTracker tracker;
  PointerSignals out;
  tracker.down(1, {0, 0}, std::nullopt, &out);
  tracker.down(2, {50, 0}, std::nullopt, &out);
  tracker.cancel(2, {50, 0}, &out);
  CHECK_EQ(kinds(out), "down down cancel suppress");
  CHECK(std::get<PointerCancelSignal>(out[2]).pointer == 1);
  out.clear();
  tracker.pan_zoom_start(7, {10, 10}, &out);
  tracker.pan_zoom_update(config, 8, {10, 10}, {0, 90}, 1, &out);  // other id
  tracker.pan_zoom_update(config, 7, {10, 10}, {0, 40}, 1, &out);
  tracker.pan_zoom_end(7, {10, 10}, &out);
  CHECK_EQ(kinds(out), "down cluster:pan up");
  CHECK(std::get<PointerUpSignal>(out.back()).position == (Point{10, 50}));
  out.clear();
  tracker.pan_zoom_start(7, {10, 10}, &out);
  tracker.reset();
  tracker.pan_zoom_end(7, {10, 10}, &out);
  CHECK_EQ(kinds(out), "down");
}

// ---------------------------------------------------------------- registry

TransactionPtr make_tx(const std::string& id, int64_t pointer,
                       const std::string& session = "s") {
  InteractionOrigin origin;
  origin.interaction_id = id;
  origin.session_id = session;
  return std::make_shared<Transaction>(std::move(origin), pointer);
}

void test_registry_claimable_and_sweep() {
  InteractionRegistry registry;
  const TransactionPtr pending = make_tx("event-1", 1);
  const TransactionPtr swipe = make_tx("event-2", 2);
  const TransactionPtr other_session = make_tx("event-3", 3, "old");
  registry.add_pending(pending);
  registry.add_pending(swipe);
  registry.add_pending(other_session);
  swipe->mark_swipe();
  CHECK(registry.claimable(0, "s").size() == 1);  // swipes and other sessions
  CHECK(registry.first_pending() == pending);
  registry.release(pending);
  pending->claim_deadline_ms = 1250;
  CHECK(pending->stage == TransactionStage::kReleased);
  CHECK(registry.claimable(1250, "s").size() == 1);  // inclusive, fact time
  CHECK(registry.claimable(1251, "s").empty());
  pending->claimed = true;
  CHECK(registry.claimable(0, "s").empty());
  // The sweep honours the fact grace, then the cap, oldest first.
  CHECK(registry.sweep(1299, 50, 8).empty());
  CHECK(registry.sweep(1300, 50, 8).size() == 1);
  CHECK(pending->stage == TransactionStage::kSettling);
  for (int64_t i = 10; i < 13; ++i) {
    const TransactionPtr tx = make_tx("event-" + std::to_string(i), i);
    registry.add_pending(tx);
    registry.release(tx);
    tx->claim_deadline_ms = 5000 + i;
  }
  CHECK(registry.earliest_claim_deadline() == 5010);
  const std::vector<TransactionPtr> evicted = registry.sweep(0, 0, 2);
  CHECK(evicted.size() == 1 && evicted[0]->id() == "event-10");
  CHECK(registry.released_count() == 2);
}

// ------------------------------------------------------------------ payload

void test_coordinate_and_payload() {
  FrameProvenance frame;
  frame.frame_id = "frame-1";
  frame.pixel_width = 100;
  frame.pixel_height = 200;
  frame.boundary = BoundaryRect{0, 100, 400, 800};
  CHECK(!sample_coordinate({10, 10}, nullptr).available);
  CHECK(!sample_coordinate({10, 50}, &frame).available);  // outside
  CHECK(sample_coordinate({400, 900}, &frame).available);  // edge inside
  FrameProvenance no_pixels = frame;
  no_pixels.pixel_width = 0;
  CHECK(!sample_coordinate({10, 150}, &no_pixels).available);

  InteractionOrigin origin;
  origin.interaction_id = "event-4";
  origin.coordinate = sample_coordinate({200, 500}, &frame);
  Transaction zoom(origin, 1);
  zoom.mark_cluster(Gesture::kZoomIn, 1.5, 2);
  zoom.end_position = Point{200, 1000};
  CHECK_EQ(to_json(interaction_data(zoom)),
           "{\"interactionSchema\":2,\"gesture\":\"zoom_in\",\"payload\":{"
           "\"position\":{\"xNorm\":0.5,\"yNorm\":0.5},\"endPosition\":{"
           "\"xNorm\":0.5,\"yNorm\":1.0},"
           "\"delta\":{\"xNorm\":0.0,\"yNorm\":0.5},"
           "\"pointerCount\":2,\"scale\":1.5}}");
  Transaction cancelled(origin, 2);
  cancelled.gesture = Gesture::kCancelled;
  CHECK_EQ(to_json(interaction_data(cancelled)),
           "{\"interactionSchema\":2,\"gesture\":\"cancelled\"}");
  Transaction scroll(origin, 3);
  scroll.gesture = Gesture::kScroll;
  scroll.target_anchor = Anchor{};
  scroll.target_anchor->fingerprint = "tap-fp";
  scroll.scroll = ScrollFacts{0, 120, 0, std::nullopt};
  const Event event = interaction_event(scroll);
  // Without a scrollable anchor the tap target's fingerprint stands in.
  CHECK_EQ(to_json(event.data),
           "{\"interactionSchema\":2,\"gesture\":\"scroll\","
           "\"targetFingerprint\":\"tap-fp\",\"payload\":{\"position\":{"
           "\"xNorm\":0.5,\"yNorm\":0.5},"
           "\"startOffset\":0.0,\"endOffset\":120.0}}");
  CHECK(event.anchor.has_value());
}

// ------------------------------------------------------------ capture seam

// Issues one request and answers it.
std::optional<CaptureAnswer> answer(CaptureSeam* seam, CaptureResult result,
                                    int64_t at_ms, IdCounter* ids,
                                    Session* session, Output* out) {
  result.request_id = seam->issue({CaptureOwner::Kind::kGesture, "event-1"},
                                  interaction_capture(0, {}), ids, out);
  tugboat::engine::FrameRetention retention;
  return seam->on_result(result, at_ms, 1, ids, session, &retention, out);
}

void test_capture_seam() {
  Session session(SessionHeader{});
  IdCounter ids;
  Output out;
  tugboat::engine::FrameRetention retention;
  CaptureSeam seam;
  CapturedFrame captured;
  captured.handle = "h";
  const CaptureResult with_frame{"", CaptureResultOutcome::kCaptured, captured};
  const std::optional<CaptureAnswer> first =
      answer(&seam, with_frame, 100, &ids, &session, &out);
  CHECK(first->owner.key == "event-1");
  CHECK(first->resolution.outcome == CaptureOutcome::kFreshAccepted);
  CHECK(first->accepted->handle == "h");
  CHECK(first->accepted->frame.id == *first->resolution.frame_id);
  CHECK(seam.sequence() == 1);
  // Unknown and already-answered ids are ignored.
  CHECK(!seam.on_result({"capture_request-0", CaptureResultOutcome::kFailed,
                         std::nullopt},
                        0, 1, &ids, &session, &retention, &out));
  const OptString first_id = first->resolution.frame_id;
  ObservationBoundary boundary{"", 100, std::nullopt};
  CHECK(seam.observed_after(first_id, boundary) == first_id);
  boundary.at_ms = 101;
  CHECK(!seam.observed_after(first_id, boundary));
  boundary.at_ms = 0;
  boundary.after_sequence = 1;
  CHECK(!seam.observed_after(first_id, boundary));
  boundary.session_id = "other";
  boundary.after_sequence.reset();
  CHECK(!seam.observed_after(first_id, boundary));
  // maxFrames 1: the next frame trims the first, which becomes a tombstone.
  const std::optional<CaptureAnswer> second =
      answer(&seam, with_frame, 200, &ids, &session, &out);
  CHECK(!seam.find(*first_id)->available);
  CHECK(!seam.observed_after(first_id, {"", 0, std::nullopt}));
  CHECK(session.truncated());
  const std::optional<CaptureAnswer> reused =
      answer(&seam, {"", CaptureResultOutcome::kPaintUnchanged, std::nullopt},
             300, &ids, &session, &out);
  CHECK(reused->resolution.frame_id == second->resolution.frame_id);
  CHECK(!reused->accepted);
  CHECK(out.records.size() == 2);  // two frame records, no reuse record
  // Teardown invalidates outstanding requests; a session start forgets all.
  const std::string late = seam.issue({CaptureOwner::Kind::kGesture, "x"},
                                      interaction_capture(0, {}), &ids, &out);
  seam.cancel_requests();
  CHECK(!seam.on_result({late, CaptureResultOutcome::kFailed, std::nullopt},
                        0, 1, &ids, &session, &retention, &out));
  seam.reset();
  CHECK(seam.latest("") == nullptr);
  CHECK(seam.sequence() == 0);
}

// --------------------------------------------------------------- claim API

const char kConfigure[] =
    "{\"type\":\"engine.configure\",\"input\":{\"host\":{\"app\":{\"name\":"
    "\"a\",\"version\":\"1\",\"buildNumber\":\"7\",\"installationId\":\"i\","
    "\"appId\":\"x\"},\"device\":{\"id\":\"d\",\"platform\":\"android\","
    "\"screenSize\":{\"width\":1,\"height\":1},\"screenDensity\":1,"
    "\"screenDpi\":1,\"screenPixelDensity\":1},\"ip\":{\"ip\":\"0\"},"
    "\"locale\":{}}}}";

bool send(Engine* engine, const std::string& text, std::string* json) {
  Value message;
  ParseError parse_error;
  Value response;
  Error error;
  if (!parse_json(text, 64, &message, &parse_error) ||
      !engine->handle(message, &response, &error)) {
    return false;
  }
  if (json != nullptr) write_json(response, json, nullptr);
  return true;
}

bool send(Engine* engine, const std::string& text) {
  return send(engine, text, nullptr);
}

std::string pointer(const char* phase, int pointer_id, int64_t mono_us) {
  return "{\"type\":\"input.pointer\",\"at\":{\"monoUs\":" +
         std::to_string(mono_us) + "},\"input\":{\"pointerId\":" +
         std::to_string(pointer_id) + ",\"phase\":\"" + phase +
         "\",\"x\":1,\"y\":1,\"device\":\"touch\"}}";
}

void test_claim_api() {
  Engine engine;
  CHECK(send(&engine, kConfigure));
  CHECK(send(&engine,
             "{\"type\":\"session.start\",\"at\":{\"monoUs\":0,\"wallUs\":0},"
             "\"input\":{\"viewport\":{\"width\":1,\"height\":1},\"platform\":"
             "\"android\",\"sessionEpoch\":0}}"));
  EngineState& state = engine.state();
  At at{50000, std::nullopt};
  CHECK(claim_interaction_cause(&state, at, std::nullopt).outcome ==
        ClaimOutcome::kNone);
  // A pointer still down is claimed directly.
  CHECK(send(&engine, pointer("down", 1, 10000)));
  InteractionClaim claim = claim_interaction_cause(&state, at, OptString("n"));
  CHECK(claim.outcome == ClaimOutcome::kClaimed);
  CHECK(claim.attribution == ClaimAttribution::kDirect);
  CHECK_EQ(claim.interaction_id, "event-1");
  // Single use.
  CHECK(claim_interaction_cause(&state, at, std::nullopt).outcome ==
        ClaimOutcome::kNone);
  // Two released taps compete; one in its window is delayed_likely.
  CHECK(send(&engine, pointer("up", 1, 20000)));
  CHECK(send(&engine, pointer("down", 2, 30000)));
  CHECK(send(&engine, pointer("up", 2, 40000)));
  CHECK(send(&engine, pointer("down", 3, 41000)));
  CHECK(send(&engine, pointer("up", 3, 42000)));
  CHECK(claim_interaction_cause(&state, at, std::nullopt).outcome ==
        ClaimOutcome::kCompeting);
  CHECK(send(&engine, pointer("cancel", 2, 43000)));
  claim = claim_interaction_cause(&state, at, std::nullopt);
  CHECK(claim.outcome == ClaimOutcome::kClaimed);
  CHECK(claim.attribution == ClaimAttribution::kDelayedLikely);
  CHECK_EQ(claim.interaction_id, "event-3");
  // Past the window (fact time) nothing is eligible.
  CHECK(send(&engine, pointer("down", 4, 50000)));
  CHECK(send(&engine, pointer("up", 4, 51000)));
  CHECK(claim_interaction_cause(&state, At{2000000, std::nullopt},
                                std::nullopt)
            .outcome == ClaimOutcome::kNone);
  // A navigator mismatch leaves the transaction unclaimed.
  InteractionOrigin origin;
  origin.interaction_id = "event-99";
  origin.session_id = state.session->id();
  origin.route.navigator_id = "nav-1";
  state.interactions.registry.clear();
  state.interactions.registry.add_pending(
      std::make_shared<Transaction>(std::move(origin), 9));
  CHECK(claim_interaction_cause(&state, at, OptString("nav-2")).outcome ==
        ClaimOutcome::kNavigatorMismatch);
  CHECK(claim_interaction_cause(&state, at, OptString("nav-1")).outcome ==
        ClaimOutcome::kClaimed);
}

void test_wake_claimed_tap() {
  Engine engine;
  CHECK(send(&engine, kConfigure));
  CHECK(send(&engine,
             "{\"type\":\"session.start\",\"at\":{\"monoUs\":0,\"wallUs\":0},"
             "\"input\":{\"viewport\":{\"width\":1,\"height\":1},\"platform\":"
             "\"android\",\"sessionEpoch\":0}}"));
  CHECK(send(&engine, pointer("down", 1, 10000)));
  CHECK(send(&engine, pointer("up", 1, 20000)));
  std::string json;
  CHECK(send(&engine,
             "{\"type\":\"timer.fired\",\"at\":{\"monoUs\":1020000},\"input\":"
             "{\"timerId\":\"interaction.settle.event-1\"}}",
             &json));
  CHECK(unit::contains(json, "\"atMonoUs\":1270000"));  // claim-window wait
  EngineState& state = engine.state();
  const At at{1100000, std::nullopt};
  CHECK(claim_interaction_cause(&state, at, std::nullopt).outcome ==
        ClaimOutcome::kClaimed);
  Output out;
  wake_claimed_tap(&state, "event-1", at, &out);
  const std::string effects = to_json(effects_json(out.effects));
  CHECK(unit::contains(effects, "\"timer.cancel\""));
  CHECK(unit::contains(effects, "\"capture.request\""));
  Output again;
  wake_claimed_tap(&state, "event-1", at, &again);  // already capturing
  CHECK(again.effects.empty());
}

}  // namespace

int main() {
  test_classify_cluster_table();
  test_classify_trackpad_and_slop();
  test_tracker_single_pointer();
  test_tracker_cluster_pan_and_late_finger();
  test_tracker_cancel_and_pan_zoom();
  test_registry_claimable_and_sweep();
  test_coordinate_and_payload();
  test_capture_seam();
  test_claim_api();
  test_wake_claimed_tap();
  return unit::finish("interaction");
}
