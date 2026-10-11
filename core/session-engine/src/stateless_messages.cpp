// Registers the slice 2 stateless operations (operations.h).
#include "modules.h"
#include "operations.h"

namespace tugboat {
namespace engine {

void register_stateless_messages(MessageRegistry* registry) {
  registry->add_stateless("fingerprint.identityParts", run_identity_parts);
  registry->add_stateless("fingerprint.labelHash", run_label_hash);
  registry->add_stateless("collector.event", run_collector_event);
  registry->add_stateless("collector.sessionLifecycle", run_session_lifecycle);
}

}  // namespace engine
}  // namespace tugboat
