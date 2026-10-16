#include "navigator_registry.h"

#include <algorithm>
#include <iterator>

namespace tugboat {
namespace engine {

void NavigatorRegistry::clear() {
  navigator_ids_.clear();
  parents_.clear();
  stacks_.clear();
  route_ids_.clear();
  records_.clear();
  navigator_seq_ = 0;
  route_seq_ = 0;
}

std::string NavigatorRegistry::navigator(const std::string& adapter_id,
                                         const OptString& adapter_parent_id) {
  const auto known = navigator_ids_.find(adapter_id);
  std::string id;
  if (known != navigator_ids_.end()) {
    id = known->second;
  } else {
    id = "nav-" + std::to_string(navigator_seq_++);
    navigator_ids_[adapter_id] = id;
    stacks_[id];
    parents_[id];
  }
  OptString& parent = parents_[id];
  if (!parent && adapter_parent_id) {
    parent = navigator(*adapter_parent_id, std::nullopt);
  }
  return id;
}

OptString NavigatorRegistry::parent_of(const std::string& navigator_id) const {
  const auto it = parents_.find(navigator_id);
  return it == parents_.end() ? std::nullopt : it->second;
}

std::string NavigatorRegistry::route_instance(
    const std::string& adapter_instance_id) {
  const auto known = route_ids_.find(adapter_instance_id);
  if (known != route_ids_.end()) return known->second;
  const std::string id = "route-" + std::to_string(route_seq_++);
  route_ids_[adapter_instance_id] = id;
  return id;
}

OptString NavigatorRegistry::peek_route_instance(
    const OptString& adapter_instance_id) const {
  if (!adapter_instance_id) return std::nullopt;
  const auto it = route_ids_.find(*adapter_instance_id);
  return it == route_ids_.end() ? std::nullopt : OptString(it->second);
}

int64_t NavigatorRegistry::push(const std::string& navigator_id,
                                const std::string& instance_id) {
  std::vector<std::string>& stack = stacks_[navigator_id];
  stack.push_back(instance_id);
  return static_cast<int64_t>(stack.size());
}

int64_t NavigatorRegistry::replace_top(const std::string& navigator_id,
                                       const std::string& instance_id) {
  std::vector<std::string>& stack = stacks_[navigator_id];
  if (stack.empty()) {
    stack.push_back(instance_id);
  } else {
    stack.back() = instance_id;
  }
  return static_cast<int64_t>(stack.size());
}

int64_t NavigatorRegistry::pop(const std::string& navigator_id,
                               const OptString& departing) {
  std::vector<std::string>& stack = stacks_[navigator_id];
  if (departing) {
    const auto it = std::find(stack.rbegin(), stack.rend(), *departing);
    if (it != stack.rend()) {
      stack.erase(std::next(it).base());
      return static_cast<int64_t>(stack.size());
    }
  }
  if (!stack.empty()) stack.pop_back();
  return static_cast<int64_t>(stack.size());
}

OptString NavigatorRegistry::top(const std::string& navigator_id) const {
  const auto it = stacks_.find(navigator_id);
  if (it == stacks_.end() || it->second.empty()) return std::nullopt;
  return it->second.back();
}

void NavigatorRegistry::remember(const std::string& instance_id,
                                 const std::string& navigator_id,
                                 const RouteIdentity& identity,
                                 OverlayKind overlay_kind) {
  if (!identity.route || identity.route->empty()) return;
  records_[instance_id] = RouteSurfaceRecord{
      instance_id, *identity.route, identity.route_named, overlay_kind,
      navigator_id};
}

const RouteSurfaceRecord* NavigatorRegistry::record(
    const std::string& instance_id) const {
  const auto it = records_.find(instance_id);
  return it == records_.end() ? nullptr : &it->second;
}

std::optional<RoutePresentation> NavigatorRegistry::presentation(
    const std::string& navigator_id, const std::string& instance_id,
    OverlayKind overlay_kind, bool is_push) const {
  if (!is_push || overlay_kind == OverlayKind::kPage) return std::nullopt;
  RoutePresentation presentation;
  const auto stack = stacks_.find(navigator_id);
  if (stack != stacks_.end() && stack->second.size() >= 2 &&
      stack->second.back() == instance_id) {
    if (const RouteSurfaceRecord* below =
            record(stack->second[stack->second.size() - 2])) {
      presentation.presented_over = *below;
    }
  }
  if (const RouteSurfaceRecord* host = host_page(navigator_id)) {
    presentation.host_page = *host;
  }
  if (!presentation.presented_over && !presentation.host_page) {
    return std::nullopt;
  }
  return presentation;
}

const RouteSurfaceRecord* NavigatorRegistry::page_on_stack(
    const std::string& navigator_id, bool skip_top) const {
  const auto it = stacks_.find(navigator_id);
  if (it == stacks_.end()) return nullptr;
  const std::vector<std::string>& stack = it->second;
  const size_t skip = skip_top ? 1 : 0;
  for (size_t i = stack.size(); i > skip; --i) {
    const RouteSurfaceRecord* candidate = record(stack[i - 1 - skip]);
    if (candidate != nullptr &&
        candidate->overlay_kind == OverlayKind::kPage) {
      return candidate;
    }
  }
  return nullptr;
}

const RouteSurfaceRecord* NavigatorRegistry::host_page(
    const std::string& navigator_id) const {
  if (const RouteSurfaceRecord* local = page_on_stack(navigator_id, true)) {
    return local;
  }
  // A parent chain is acyclic: a navigator's parent is numbered when it is
  // first named, and a known parent never changes. The walk is bounded by
  // the number of navigators anyway.
  OptString parent = parent_of(navigator_id);
  for (size_t hops = 0; parent && hops <= parents_.size(); ++hops) {
    if (const RouteSurfaceRecord* page = page_on_stack(*parent, false)) {
      return page;
    }
    parent = parent_of(*parent);
  }
  return nullptr;
}

std::vector<RouteSurfaceRecord> NavigatorRegistry::stack_snapshot(
    const std::string& navigator_id, int64_t limit) const {
  std::vector<RouteSurfaceRecord> entries;
  const auto it = stacks_.find(navigator_id);
  if (it == stacks_.end()) return entries;
  const std::vector<std::string>& stack = it->second;
  const size_t keep = static_cast<size_t>(limit);
  const size_t start = stack.size() > keep ? stack.size() - keep : 0;
  for (size_t i = start; i < stack.size(); ++i) {
    if (const RouteSurfaceRecord* entry = record(stack[i])) {
      entries.push_back(*entry);
    }
  }
  return entries;
}

bool NavigatorRegistry::stack_truncated(const std::string& navigator_id,
                                        int64_t limit) const {
  const auto it = stacks_.find(navigator_id);
  return it != stacks_.end() &&
         static_cast<int64_t>(it->second.size()) > limit;
}

}  // namespace engine
}  // namespace tugboat
