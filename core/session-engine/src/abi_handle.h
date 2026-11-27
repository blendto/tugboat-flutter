// The handle behind the C ABI (`tb_session_engine`). Internal: hosts see only
// the opaque pointer. Unit tests build a handle around a test registry to
// reach the ABI's failure paths. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_ABI_HANDLE_H
#define TUGBOAT_SESSION_ENGINE_ABI_HANDLE_H

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>

#include "engine.h"
#include "modules.h"
#include "tugboat/tb_session_engine.h"

struct tb_session_engine {
  explicit tb_session_engine(
      const tugboat::engine::ModuleRegistry& modules =
          tugboat::engine::module_registry())
      : engine(modules) {}

  // Handles one message; the response or error document is in `output`.
  // Throws only what the engine throws (allocation, a bug); the C ABI
  // catches it and poisons the handle.
  tb_session_status submit(const char* message, size_t length);

  uint32_t max_depth = TB_SESSION_ENGINE_DEFAULT_MAX_DEPTH;
  size_t max_message_bytes = TB_SESSION_ENGINE_DEFAULT_MAX_MESSAGE_BYTES;
  std::atomic<bool> busy{false};
  // Set when an exception left a call partway through: the engine state may
  // be partly written, so every later call answers `internal_error`.
  bool poisoned = false;
  tugboat::engine::Engine engine;
  // Last response; borrowed by the host until the next call.
  std::string output;
};

#endif  // TUGBOAT_SESSION_ENGINE_ABI_HANDLE_H
