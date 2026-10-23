#ifndef TUGBOAT_TB_SESSION_ENGINE_H
#define TUGBOAT_TB_SESSION_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Tugboat session engine (ADR 0009). Public surface is this C ABI only — do
 * not expose C++ types from this header.
 *
 * The engine is I/O-free and single-threaded. A platform host creates one
 * engine handle, submits UTF-8 JSON messages, and receives one UTF-8 JSON
 * response per message. Message and response formats are documented in
 * core/session-engine/README.md.
 *
 * Ownership:
 * - The caller owns `message`. The engine reads it during the call only and
 *   never retains the pointer.
 * - The engine owns every response buffer. `*out_json` stays valid until the
 *   next tb_session_engine_submit_v1 or tb_session_engine_destroy call on the
 *   same handle. The caller must not free or write it; copy it to keep it.
 * - tb_session_engine_create_v1 allocates the handle;
 *   tb_session_engine_destroy frees it and every buffer it owns.
 *
 * Threading: one handle is never used concurrently. The host serializes every
 * call on a handle (one queue). Different handles are independent and may be
 * used from different threads. A concurrent submit on the same handle is
 * best-effort detected and rejected with TB_SESSION_BUSY; it is still a host
 * bug.
 *
 * Errors: exceptions never cross this ABI and the engine never aborts on bad
 * input. Every failure is a status code. When `engine`, `out_json`, and
 * `out_len` are valid, `*out_json` is always a NUL-terminated JSON document:
 * the response on TB_SESSION_OK, otherwise an error document
 * {"error":{"status":...,"message":...}}.
 */

#define TB_SESSION_ENGINE_ABI_VERSION 1

/* Contract versions this engine produces. They match the Dart SDK constants
 * `tugboatSessionSchemaVersion` and `tugboatFingerprintSchemaVersion`. */
#define TB_SESSION_ENGINE_SESSION_SCHEMA_VERSION 10
#define TB_SESSION_ENGINE_FINGERPRINT_SCHEMA_VERSION 6

/* Limits applied when the matching config field is 0. */
#define TB_SESSION_ENGINE_DEFAULT_MAX_MESSAGE_BYTES 1048576u
#define TB_SESSION_ENGINE_DEFAULT_MAX_DEPTH 64u
/* Largest values a config may request. */
#define TB_SESSION_ENGINE_MAX_MESSAGE_BYTES 67108864u
#define TB_SESSION_ENGINE_MAX_DEPTH 512u

typedef enum tb_session_status {
  TB_SESSION_OK = 0,
  /* NULL pointer, NULL message with non-zero length, or a config limit out of
   * range. */
  TB_SESSION_INVALID_ARGUMENT = 1,
  /* config->abi_version is not TB_SESSION_ENGINE_ABI_VERSION. */
  TB_SESSION_ABI_MISMATCH = 2,
  /* Not UTF-8 JSON, or nested deeper than the configured depth. */
  TB_SESSION_MALFORMED_MESSAGE = 3,
  /* Valid JSON whose envelope or input breaks the message schema: unknown
   * key, wrong type, missing required field, value out of range, or a value
   * that cannot be encoded in the response (non-finite number). */
  TB_SESSION_INVALID_MESSAGE = 4,
  /* Unknown message `type`. */
  TB_SESSION_UNSUPPORTED_MESSAGE = 5,
  /* The message pins contract versions other than this engine's. */
  TB_SESSION_CONTRACT_MISMATCH = 6,
  /* The message is longer than the configured maximum. */
  TB_SESSION_MESSAGE_TOO_LARGE = 7,
  /* Another call is in progress on the same handle. */
  TB_SESSION_BUSY = 8,
  TB_SESSION_OUT_OF_MEMORY = 9,
  TB_SESSION_INTERNAL_ERROR = 10,
} tb_session_status;

typedef struct tb_session_engine tb_session_engine;

typedef struct tb_session_engine_config_v1 {
  /* Must be TB_SESSION_ENGINE_ABI_VERSION. */
  uint32_t abi_version;
  /* Maximum JSON nesting depth of a message. 0 uses the default. */
  uint32_t max_depth;
  /* Maximum message length in bytes. 0 uses the default. */
  size_t max_message_bytes;
} tb_session_engine_config_v1;

/* Semantic version of this static library, e.g. "0.1.0". */
const char* tb_session_engine_version(void);

uint32_t tb_session_engine_abi_version(void);

/* Contract versions of the linked library (may differ from the header
 * macros when the header and library are out of sync). */
uint32_t tb_session_engine_session_schema_version(void);
uint32_t tb_session_engine_fingerprint_schema_version(void);

/* Stable lowercase name for `status`, e.g. "invalid_message". Unknown values
 * return "unknown". The string is static. */
const char* tb_session_status_name(tb_session_status status);

/*
 * Creates an engine. On TB_SESSION_OK, `*out_engine` is a new handle the
 * caller must release with tb_session_engine_destroy. On failure,
 * `*out_engine` is set to NULL when `out_engine` is not NULL.
 */
tb_session_status tb_session_engine_create_v1(
    const tb_session_engine_config_v1* config, tb_session_engine** out_engine);

/* Frees the handle and every buffer it owns. NULL is a no-op. */
void tb_session_engine_destroy(tb_session_engine* engine);

/*
 * Submits one UTF-8 JSON message of `message_len` bytes (no NUL terminator
 * required) and returns the engine's JSON response in `*out_json` /
 * `*out_len` (length excludes the NUL terminator).
 *
 * If `engine`, `out_json`, or `out_len` is NULL the call returns
 * TB_SESSION_INVALID_ARGUMENT and writes nothing through the NULL pointers
 * (any non-NULL output pointer is set to NULL / 0).
 */
tb_session_status tb_session_engine_submit_v1(tb_session_engine* engine,
                                              const char* message,
                                              size_t message_len,
                                              const char** out_json,
                                              size_t* out_len);

#ifdef __cplusplus
}
#endif

#endif /* TUGBOAT_TB_SESSION_ENGINE_H */
