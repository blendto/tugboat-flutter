#include "messages.h"

#include <cstdlib>
#include <utility>

namespace tugboat {
namespace engine {

void MessageRegistry::add(const char* type, MessageSpec spec) {
  // Two modules registering one type is a programming error.
  if (!specs_.emplace(type, std::move(spec)).second) {
    std::abort();
  }
}

void MessageRegistry::add_stateless(const char* type,
                                    StatelessHandler handler) {
  add(type, MessageSpec(handler));
}

void MessageRegistry::add_query(const char* type, QueryHandler handler) {
  add(type, MessageSpec(handler));
}

void MessageRegistry::add_command(const char* type, AtRule at,
                                  CommandDecoder decode) {
  add(type, MessageSpec(CommandSpec{at, decode}));
}

const MessageSpec* MessageRegistry::find(std::string_view type) const {
  const auto it = specs_.find(type);
  return it == specs_.end() ? nullptr : &it->second;
}

}  // namespace engine
}  // namespace tugboat
