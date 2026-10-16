// Session-local navigator and route-instance ownership (Dart
// `_NavigatorSurfaceRegistry`): the engine maps the adapter's opaque
// navigator and route ids onto `nav-N` and `route-N` (reset per session),
// keeps each navigator's route stack, and answers what a dialog or sheet is
// presented over and which page hosts it. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_NAVIGATOR_REGISTRY_H
#define TUGBOAT_SESSION_ENGINE_NAVIGATOR_REGISTRY_H

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "models.h"
#include "navigation_facts.h"

namespace tugboat {
namespace engine {

// Dart `_RouteSurfaceRecord`: one named-or-typed route on a stack.
struct RouteSurfaceRecord {
  std::string instance_id;
  std::string route;
  bool route_named = false;
  OverlayKind overlay_kind = OverlayKind::kPage;
  std::string navigator_id;
};

// Dart `_RoutePresentationParent`.
struct RoutePresentation {
  std::optional<RouteSurfaceRecord> presented_over;
  std::optional<RouteSurfaceRecord> host_page;
};

class NavigatorRegistry {
 public:
  void clear();

  // Dart `idForNavigator`: `nav-N` for the adapter navigator. On first sight
  // it is numbered first and then its parent, when the adapter names one
  // the engine has not seen. A parent learned later fills in a navigator
  // registered without one; a known parent never changes.
  std::string navigator(const std::string& adapter_id,
                        const OptString& adapter_parent_id);
  OptString parent_of(const std::string& navigator_id) const;

  // Dart `idForRoute`: `route-N` for the adapter route instance.
  std::string route_instance(const std::string& adapter_instance_id);
  // Dart `peekRouteId`: the id of an already-seen route instance.
  OptString peek_route_instance(const OptString& adapter_instance_id) const;

  // Stack edits; each returns the stack length (`stackRevision`).
  int64_t push(const std::string& navigator_id,
               const std::string& instance_id);
  int64_t replace_top(const std::string& navigator_id,
                      const std::string& instance_id);
  // Removes `departing` (its last occurrence) or else the top.
  int64_t pop(const std::string& navigator_id, const OptString& departing);
  OptString top(const std::string& navigator_id) const;

  // Dart `remember`: records a route for stack snapshots and presentation.
  void remember(const std::string& instance_id,
                const std::string& navigator_id, const RouteIdentity& identity,
                OverlayKind overlay_kind);

  // Dart `presentationParent`: for a non-page push only.
  std::optional<RoutePresentation> presentation(
      const std::string& navigator_id, const std::string& instance_id,
      OverlayKind overlay_kind, bool is_push) const;

  // The top `limit` remembered routes, bottom to top, and whether the stack
  // is deeper than that.
  std::vector<RouteSurfaceRecord> stack_snapshot(
      const std::string& navigator_id, int64_t limit) const;
  bool stack_truncated(const std::string& navigator_id, int64_t limit) const;

 private:
  const RouteSurfaceRecord* record(const std::string& instance_id) const;
  const RouteSurfaceRecord* page_on_stack(const std::string& navigator_id,
                                          bool skip_top) const;
  const RouteSurfaceRecord* host_page(const std::string& navigator_id) const;

  std::map<std::string, std::string> navigator_ids_;  // adapter id -> nav-N
  std::map<std::string, OptString> parents_;          // nav-N -> parent
  std::map<std::string, std::vector<std::string>> stacks_;
  std::map<std::string, std::string> route_ids_;      // adapter id -> route-N
  std::map<std::string, RouteSurfaceRecord> records_;
  int64_t navigator_seq_ = 0;
  int64_t route_seq_ = 0;
};

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_NAVIGATOR_REGISTRY_H
