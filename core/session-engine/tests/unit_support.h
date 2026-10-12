// Minimal check macros and C ABI helpers shared by the unit test binaries.
#ifndef TUGBOAT_SESSION_ENGINE_TESTS_UNIT_SUPPORT_H
#define TUGBOAT_SESSION_ENGINE_TESTS_UNIT_SUPPORT_H

#include <cstdint>
#include <cstdio>
#include <string>

#include "tugboat/tb_session_engine.h"

namespace unit {

inline int g_failures = 0;

inline void check(bool cond, const char* expr, const char* file, int line) {
  if (!cond) {
    std::fprintf(stderr, "FAIL %s:%d %s\n", file, line, expr);
    ++g_failures;
  }
}

inline void check_eq(const std::string& actual, const std::string& expected,
                     const char* expr, const char* file, int line) {
  if (actual != expected) {
    std::fprintf(stderr, "FAIL %s:%d %s\n  expected: %s\n  actual:   %s\n",
                 file, line, expr, expected.c_str(), actual.c_str());
    ++g_failures;
  }
}

inline tb_session_engine* make_engine(uint32_t max_depth = 0,
                                      size_t max_message_bytes = 0) {
  tb_session_engine_config_v1 config{};
  config.abi_version = TB_SESSION_ENGINE_ABI_VERSION;
  config.max_depth = max_depth;
  config.max_message_bytes = max_message_bytes;
  tb_session_engine* engine = nullptr;
  if (tb_session_engine_create_v1(&config, &engine) != TB_SESSION_OK) {
    return nullptr;
  }
  return engine;
}

struct Response {
  tb_session_status status;
  std::string json;
};

inline Response submit(tb_session_engine* engine, const std::string& message) {
  const char* out = nullptr;
  size_t len = 0;
  const tb_session_status status = tb_session_engine_submit_v1(
      engine, message.data(), message.size(), &out, &len);
  Response response{status, std::string()};
  if (out != nullptr) {
    response.json.assign(out, len);
  }
  return response;
}

inline bool contains(const std::string& haystack, const std::string& needle) {
  return haystack.find(needle) != std::string::npos;
}

// Exit code for a test binary's main.
inline int finish(const char* suite) {
  if (g_failures != 0) {
    std::fprintf(stderr, "%d failure(s)\n", g_failures);
    return 1;
  }
  std::printf("all %s tests passed\n", suite);
  return 0;
}

}  // namespace unit

#define CHECK(cond) \
  unit::check(static_cast<bool>(cond), #cond, __FILE__, __LINE__)
#define CHECK_EQ(actual, expected) \
  unit::check_eq((actual), (expected), #actual, __FILE__, __LINE__)

#endif  // TUGBOAT_SESSION_ENGINE_TESTS_UNIT_SUPPORT_H
