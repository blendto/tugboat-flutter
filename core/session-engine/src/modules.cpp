#include "modules.h"

namespace tugboat {
namespace engine {

namespace {

MessageRegistry build_registry() {
  MessageRegistry registry;
  register_stateless_messages(&registry);
  register_engine_messages(&registry);
  register_session_messages(&registry);
  register_evidence_messages(&registry);
  return registry;
}

}  // namespace

const MessageRegistry& message_registry() {
  static const MessageRegistry registry = build_registry();
  return registry;
}

}  // namespace engine
}  // namespace tugboat
