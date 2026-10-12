// A tap after its pointer-up: the claim window and the tap-settle state
// machine.
//
// Claim window (Dart `_releaseInteractionClaim` and the reconciliation
// sweep): a released tap stays claimable as a navigation's cause until
// `claimWindowMs` after release, measured in fact time. The sweep timer fires
// `factGraceMs` late (design section 5) so a fact stamped inside the window
// that arrives late can still claim.
//
// Settle (Dart `_resolveTapSettle`):
//
//   settle delay ──timer──► claim window ──timer or wake──┬─► route barrier
//   (skipped when the tap                                 │   (it caused the
//    caused the route that                                │    route)
//    was active at pointer-up)                            └─► capturing
//                                                             (standalone
//        route barrier ──superseded by a route────┐            capture)
//              │        it did not cause           ▼              │
//              │                          successor barrier ◄─────┤ a later
//              ▼                                   │              │ route
//          observation ◄───────────────────────────┴──────────────┘
//              │
//              ├── degraded (no frame): published at once
//              └── otherwise: publishing (the publication queue)
//
// The observation is the tap's after-frame: the frame of the route it
// caused, a temporal frame of a later route, or its own capture.
// Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_TAP_SETTLE_H
#define TUGBOAT_SESSION_ENGINE_TAP_SETTLE_H

#include <optional>
#include <string>
#include <variant>

#include "capture_types.h"
#include "interaction_transaction.h"
#include "ordered_map.h"
#include "route_work.h"
#include "teardown.h"
#include "turn.h"

namespace tugboat {
namespace engine {

// ---------------------------------------------------------------- claim window

constexpr char kSweepTimerId[] = "interaction.sweep";

// Releases a tap into the claim window and arms the sweep if it is idle.
void release_for_claims(Turn& turn, const TransactionPtr& tx);

// The sweep timer: expires released taps past their window (and the oldest
// beyond `maxReleased`), then re-arms while any remain.
void sweep_released(Turn& turn);

// Teardown: disarms the sweep and finalizes every released tap.
void clear_released(EngineState* state, Output* out);

// ---------------------------------------------------------------------- settle

// Timer ids are `interaction.settle.<interaction id>`.
constexpr char kSettleTimerPrefix[] = "interaction.settle.";

// The settle's phases, each with the data only it needs.
struct SettleDelay {};
struct ClaimWindow {};
// Its standalone capture: the request and the route epoch it was made on.
struct Capturing {
  std::string request_id;
  int64_t requested_route_epoch = 0;
  // The route changed since pointer-down, or the route it caused was
  // superseded by one it did not cause.
  bool route_changed = false;
};
// Waiting for the route it caused (or a successor it also caused).
struct RouteBarrier {};
// Which later route a tap observes instead of its own.
enum class SuccessorKind {
  kAutomatic,    // replaced the route it caused (Dart: superseded route)
  kReplacement,  // started while its standalone capture ran
};
struct SuccessorBarrier {
  SuccessorKind kind = SuccessorKind::kAutomatic;
};
// The observed after-frame, waiting in the publication queue.
struct Publishing {
  OptString after_frame;
};

using SettlePhase = std::variant<SettleDelay, ClaimWindow, Capturing,
                                 RouteBarrier, SuccessorBarrier, Publishing>;

struct TapSettle {
  TransactionPtr tx;
  // The route this tap caused that was active at pointer-up (a direct
  // claim): the settle delay is skipped.
  RouteWorkPtr initial_route;
  SettlePhase phase;
};

// Active settles by interaction id, in start order (Dart `_activeTapSettles`).
using TapSettles = OrderedMap<std::string, TapSettle>;

// Starts settling a released tap.
void start_tap_settle(Turn& turn, const TransactionPtr& tx);

// The settle timer of `interaction_id` fired.
void advance_tap_settle(Turn& turn, const std::string& interaction_id);

// A navigation claimed the tap: a settle waiting out the claim window stops
// waiting (Dart `signalSuccessorClaimed`).
void wake_tap_settle(Turn& turn, const std::string& interaction_id);

// The settle's standalone capture resolved.
void finish_tap_settle(Turn& turn, const std::string& interaction_id,
                       const CaptureResolution& resolution);

// A route barrier the settle waits on is done.
void tap_route_barrier_done(Turn& turn, const BarrierWaiter& waiter,
                            const RouteWork& barrier);

// The publication queue reached the settled tap: publish it.
void publish_settled_tap(Turn& turn, const std::string& interaction_id);

// Teardown: cancels every settle and its standalone capture. A tap still
// released is finalized by the released-transaction stage; one already
// settling is dropped, as in Dart.
void cancel_tap_settles(EngineState* state, const At& at, Output* out,
                        TeardownCause cause);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_TAP_SETTLE_H
