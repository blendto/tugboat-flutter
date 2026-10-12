// Unit tests for navigation and capture coordination (docs/stateful-engine.md
// section 8) that scenarios reach only indirectly: the scheduler queue's
// absorption rules, frame provenance and trim, the screenshot budget, the
// decision helpers, and the navigator registry. End-to-end behaviour is
// pinned by conformance/engine/scenario/ instead.
#include <cstdint>
#include <limits>
#include <optional>
#include <string>
#include <vector>

#include "capture_budget.h"
#include "capture_execution.h"
#include "capture_scheduler.h"
#include "frame_store.h"
#include "navigation_facts.h"
#include "navigator_registry.h"
#include "session.h"
#include "unit_support.h"

namespace {

using namespace tugboat::engine;  // NOLINT: test file

RequestContext context(int64_t epoch, int64_t boundary_generation = 0) {
  RequestContext out;
  out.session_id = "s";
  out.route_epoch = epoch;
  out.route = std::string("/home");
  out.boundary_generation = boundary_generation;
  return out;
}

ScheduledCapture scheduled(FrameTrigger trigger, const std::string& id,
                           int64_t not_before, int64_t epoch = 1) {
  ScheduledCapture capture;
  capture.trigger = trigger;
  capture.not_before_mono_us = not_before;
  capture.enqueued_mono_us = not_before;
  capture.context = context(epoch);
  capture.waiters.push_back(CaptureWaiter{id, capture.context, {}, {}, false});
  return capture;
}

CapturedFrame captured(const std::string& handle, const std::string& hash) {
  CapturedFrame frame;
  frame.handle = handle;
  frame.content_hash = hash;
  frame.width = 10;
  frame.height = 10;
  return frame;
}

// ------------------------------------------------------------ scheduler

void test_absorption() {
  ScheduledCapture route = scheduled(FrameTrigger::kRoute, "r", 100);
  route.force = true;
  route.freshness = CaptureFreshness::kFreshPaint;
  const ScheduledCapture manual = scheduled(FrameTrigger::kManual, "m", 900);
  CHECK(route.can_absorb(manual));
  route.absorb(manual);
  // Manual outranks route; force, freshness, the later not-before stick.
  CHECK(route.trigger == FrameTrigger::kManual);
  CHECK(route.force);
  CHECK(route.freshness == CaptureFreshness::kFreshPaint);
  CHECK(route.not_before_mono_us == 900);
  CHECK(route.enqueued_mono_us == 100);
  CHECK(route.waiters.size() == 2 && route.waiters[0].coalesced &&
        route.waiters[1].coalesced);
  // A lower priority never demotes; interaction captures never share.
  ScheduledCapture scroll = scheduled(FrameTrigger::kScroll, "s", 0);
  route.absorb(scroll);
  CHECK(route.trigger == FrameTrigger::kManual);
  CHECK(!route.can_absorb(scheduled(FrameTrigger::kInteraction, "i", 0)));
  CHECK(!route.can_absorb(scheduled(FrameTrigger::kManual, "e", 0, 2)));
}

void test_scheduler_queue() {
  CaptureScheduler scheduler;
  CHECK(!scheduler.busy());
  scheduler.enqueue(scheduled(FrameTrigger::kInteraction, "a", 0));
  scheduler.enqueue(scheduled(FrameTrigger::kManual, "b", 0));
  // Only the tail absorbs: c joins b, not a.
  scheduler.enqueue(scheduled(FrameTrigger::kManual, "c", 0));
  CHECK(scheduler.head()->waiters[0].request_id == "a");
  InFlightCapture flight;
  flight.capture = scheduler.take_head();
  scheduler.start(flight);
  CHECK(scheduler.busy());
  CHECK(scheduler.head()->waiters.size() == 2);
  // Removing the last waiter of a scheduled capture drops it from the queue;
  // the capture in flight keeps running for no one.
  CHECK(scheduler.remove_waiter("b").has_value());
  CHECK(scheduler.remove_waiter("c").has_value());
  CHECK(scheduler.head() == nullptr);
  CHECK(scheduler.remove_waiter("a").has_value());
  CHECK(scheduler.in_flight() != nullptr);
  CHECK(!scheduler.remove_waiter("a").has_value());
  scheduler.enqueue(scheduled(FrameTrigger::kManual, "d", 0));
  scheduler.in_flight()->capture.waiters.push_back(
      CaptureWaiter{"e", context(1), {}, {}, false});
  const std::vector<CaptureWaiter> all = scheduler.take_all_waiters(true);
  CHECK(all.size() == 2 && all[0].request_id == "e" &&
        all[1].request_id == "d");
  CHECK(!scheduler.busy());
  CHECK(scheduler.next_host_request_id() == "capture-0");
  CHECK(scheduler.next_host_request_id() == "capture-1");
}

// ---------------------------------------------------------- frame store

void test_frame_store_compatibility_and_trim() {
  Session session(SessionHeader{});
  IdCounter ids;
  Output out;
  FrameStore frames;
  FrameRetention retention;
  RequestContext ctx = context(1);
  ctx.session_id = session.id();
  CapturedFrame first = captured("h1", "x");
  first.dhash = std::string("d1");
  first.structure_signature = std::string("s1");
  const FrameRecord a =
      frames.accept(first, ctx, 10, 2, &ids, &session, &retention, &out);
  CHECK(frames.dhash_baseline()->dhash == "d1");
  CHECK(frames.compatible_latest(ctx)->frame_id == a.frame.id);
  RequestContext moved = ctx;
  moved.boundary_generation = 1;
  CHECK(frames.compatible_latest(moved) == nullptr);
  CHECK(frames.surface_compatible_latest(moved) != nullptr);
  // A frame without a structure signature offers no baseline.
  const FrameRecord b = frames.accept(captured("h2", "y"), ctx, 20, 2, &ids,
                                      &session, &retention, &out);
  CHECK(!frames.dhash_baseline());
  // Reuse makes an older compatible frame the latest.
  CHECK(frames.reuse(a.frame.id, ctx) == a.frame.id);
  CHECK(frames.latest(session.id())->frame_id == a.frame.id);
  // maxFrames 2: c trims a (the latest), which leaves a tombstone, frees
  // its content hash, and hands "latest" to the newest retained frame.
  const FrameRecord c = frames.accept(captured("h3", "z"), ctx, 30, 2, &ids,
                                      &session, &retention, &out);
  CHECK(!frames.frame_with_content("x"));
  CHECK(frames.find(a.frame.id) == nullptr);  // unreferenced: forgotten
  CHECK(frames.latest(session.id())->frame_id == c.frame.id);
  CHECK(*frames.frame_with_content("y") == b.frame.id);
  CHECK(frames.sequence() == 3);
  frames.reset();
  CHECK(frames.sequence() == 0 && !frames.has_latest());
}

void test_execution_helpers() {
  CHECK(failure_outcome(std::nullopt) ==
        CaptureOutcome::kCaptureProcessingFailed);
  CHECK(failure_outcome(CaptureFailure::kPaintNotAdvanced) ==
        CaptureOutcome::kPaintReadinessTimeout);
  CHECK(failure_outcome(CaptureFailure::kLayoutUnavailable) ==
        CaptureOutcome::kBoundaryUnavailable);
  CHECK(cancelled_execution(CancelReason::kSupersededRoute).outcome ==
        CaptureOutcome::kSupersededRoute);
  CHECK(cancelled_execution(CancelReason::kDispose).outcome ==
        CaptureOutcome::kCancelled);

  Session session(SessionHeader{});
  IdCounter ids;
  Output out;
  FrameStore frames;
  FrameRetention retention;
  RequestContext ctx = context(1);
  CapturedFrame first = captured("h1", "x");
  first.dhash = std::string("d");
  first.structure_signature = std::string("s");
  frames.accept(first, ctx, 10, 5, &ids, &session, &retention, &out);
  InFlightCapture flight;
  flight.capture = scheduled(FrameTrigger::kManual, "m", 0);
  flight.baseline = frames.dhash_baseline();
  CapturedFrame match = captured("h2", "new");
  match.dhash = std::string("d");
  match.structure_signature = std::string("s");
  CHECK(classify_captured(frames, flight, match) ==
        CapturedDisposition::kCoalesced);
  match.structure_signature = std::string("other");
  CHECK(classify_captured(frames, flight, match) ==
        CapturedDisposition::kAccepted);
  CHECK(classify_captured(frames, flight, captured("h3", "x")) ==
        CapturedDisposition::kContentReused);
  flight.capture.force = true;
  CHECK(classify_captured(frames, flight, captured("h3", "x")) ==
        CapturedDisposition::kAccepted);

  // A waiter keeps a frame only when it is compatible with its own context.
  ExecutionResult execution;
  execution.outcome = CaptureOutcome::kFreshAccepted;
  execution.frame_id = frames.latest(ctx.session_id)->frame_id;
  CHECK(for_waiter(frames, execution, ctx).frame_id == execution.frame_id);
  const ExecutionResult other = for_waiter(frames, execution, context(2));
  CHECK(!other.frame_id);
  CHECK(other.outcome == CaptureOutcome::kNoCompatibleFrame);
}

// --------------------------------------------------------------- budget

void test_budget() {
  CaptureBudget budget;
  budget.record(0, 40000, 5000000, 60000);
  CHECK(!budget.degraded());
  budget.record(1000000, 30000, 5000000, 60000);
  CHECK(budget.degraded());
  // Samples older than the window leave it on the next charge.
  budget.record(6500000, 1000, 5000000, 60000);
  CHECK(!budget.degraded());
  // Costs saturate instead of overflowing.
  const int64_t max = std::numeric_limits<int64_t>::max();
  budget.record(6500000, max, 5000000, 60000);
  budget.record(6500000, max, 5000000, 60000);
  CHECK(budget.degraded());
}

// ---------------------------------------------------- navigator registry

void test_navigator_registry() {
  NavigatorRegistry registry;
  // A navigator first named as a parent is numbered after its child; a
  // parent learned later fills in, and never changes.
  CHECK(registry.navigator("tabs", std::string("root")) == "nav-0");
  CHECK(registry.navigator("root", std::nullopt) == "nav-1");
  CHECK(registry.parent_of("nav-0") == std::string("nav-1"));
  CHECK(!registry.parent_of("nav-1"));
  CHECK(registry.navigator("modal", std::nullopt) == "nav-2");
  CHECK(registry.navigator("modal", std::string("root")) == "nav-2");
  CHECK(registry.parent_of("nav-2") == std::string("nav-1"));
  CHECK(registry.navigator("modal", std::string("tabs")) == "nav-2");
  CHECK(registry.parent_of("nav-2") == std::string("nav-1"));

  CHECK(registry.route_instance("a") == "route-0");
  CHECK(registry.route_instance("a") == "route-0");
  CHECK(!registry.peek_route_instance(std::string("b")));
  const auto page = [](const char* name) {
    RouteIdentity identity;
    identity.route = std::string(name);
    identity.route_named = true;
    return identity;
  };
  registry.remember("route-0", "nav-1", page("/home"), OverlayKind::kPage);
  registry.remember("route-1", "nav-1", page("/dialog"), OverlayKind::kDialog);
  CHECK(registry.push("nav-1", "route-0") == 1);
  CHECK(registry.push("nav-1", "route-1") == 2);
  const std::optional<RoutePresentation> over =
      registry.presentation("nav-1", "route-1", OverlayKind::kDialog, true);
  CHECK(over && over->presented_over->route == "/home" &&
        over->host_page->route == "/home");
  CHECK(!registry.presentation("nav-1", "route-1", OverlayKind::kPage, true));
  CHECK(!registry.presentation("nav-1", "route-1", OverlayKind::kDialog,
                               false));
  // The nested navigator's popup is hosted by the parent's page.
  registry.remember("route-2", "nav-2", page("/menu"), OverlayKind::kPopup);
  CHECK(registry.push("nav-2", "route-2") == 1);
  const std::optional<RoutePresentation> nested =
      registry.presentation("nav-2", "route-2", OverlayKind::kPopup, true);
  CHECK(nested && !nested->presented_over &&
        nested->host_page->instance_id == "route-0");
  CHECK(registry.stack_snapshot("nav-1", 1).size() == 1);
  CHECK(registry.stack_truncated("nav-1", 1));
  CHECK(!registry.stack_truncated("nav-1", 2));
  // A pop removes the departing route wherever it is, else the top.
  CHECK(registry.pop("nav-1", std::string("route-0")) == 1);
  CHECK(registry.top("nav-1") == std::string("route-1"));
  CHECK(registry.pop("nav-1", std::string("unknown")) == 0);
  CHECK(registry.pop("nav-1", std::nullopt) == 0);
  CHECK(registry.replace_top("nav-1", "route-0") == 1);
  registry.clear();
  CHECK(registry.navigator("root", std::nullopt) == "nav-0");
}

void test_route_identity() {
  CHECK(route_identity(std::nullopt).route_type == "unknown");
  CHECK(!route_identity(std::nullopt).route);
  FactRoute named;
  named.name = std::string("/home");
  named.type = "PageRoute";
  CHECK(route_identity(named).route == std::string("/home"));
  CHECK(route_identity(named).route_named);
  FactRoute empty_name = named;
  empty_name.name = std::string("");
  CHECK(route_identity(empty_name).route == std::string("PageRoute"));
  CHECK(!route_identity(empty_name).route_named);
  CHECK(!route_identity(empty_name).route_name);
}

// ---------------------------------------------------- answer deadline (C18)

void test_late_answer_after_deadline() {
  tb_session_engine* engine = unit::make_engine();
  CHECK(engine != nullptr);
  const std::string configure =
      "{\"type\":\"engine.configure\",\"input\":{\"host\":{\"app\":{"
      "\"name\":\"a\",\"version\":\"1\",\"buildNumber\":\"7\","
      "\"installationId\":\"i\",\"appId\":\"x\"},\"device\":{\"id\":"
      "\"d\",\"platform\":\"android\",\"screenSize\":{\"width\":1,"
      "\"height\":1},\"screenDensity\":1,\"screenDpi\":1,"
      "\"screenPixelDensity\":1},\"ip\":{\"ip\":\"0\"},\"locale\":{}},"
      "\"capture\":{\"answerTimeoutMs\":1}}}";
  CHECK(unit::submit(engine, configure).status == TB_SESSION_OK);
  const unit::Response started = unit::submit(
      engine,
      "{\"type\":\"session.start\",\"at\":{\"monoUs\":0,\"wallUs\":0},"
      "\"input\":{\"viewport\":{\"width\":1,\"height\":1},"
      "\"platform\":\"android\",\"sessionEpoch\":0}}");
  CHECK(unit::contains(started.json,
                       "\"timerId\":\"capture.answer.capture-0\","
                       "\"atMonoUs\":1000"));
  // The deadline resolves the initial capture and reports the timeout.
  const unit::Response expired = unit::submit(
      engine,
      "{\"type\":\"timer.fired\",\"at\":{\"monoUs\":1000},\"input\":"
      "{\"timerId\":\"capture.answer.capture-0\"}}");
  CHECK(unit::contains(expired.json, "\"failure\":\"answer_timeout\""));
  // The late answer is ignored: no frame, and its handle is released.
  const unit::Response late = unit::submit(
      engine,
      "{\"type\":\"capture.result\",\"at\":{\"monoUs\":2000},\"input\":"
      "{\"requestId\":\"capture-0\",\"outcome\":\"captured\",\"frame\":"
      "{\"handle\":\"h-late\",\"width\":1,\"height\":1,\"contentHash\":"
      "\"c\",\"masked\":true,\"byteLength\":1,\"captureMicros\":1}}}");
  CHECK(late.status == TB_SESSION_OK);
  CHECK_EQ(late.json,
           "{\"type\":\"capture.result\",\"records\":[],\"effects\":["
           "{\"type\":\"frame.release\",\"handle\":\"h-late\"}]}");
  tb_session_engine_destroy(engine);
}

}  // namespace

int main() {
  test_absorption();
  test_scheduler_queue();
  test_frame_store_compatibility_and_trim();
  test_execution_helpers();
  test_budget();
  test_navigator_registry();
  test_route_identity();
  test_late_answer_after_deadline();
  return unit::finish("capture and navigation");
}
