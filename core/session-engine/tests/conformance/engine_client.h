// A session engine handle driven through the public C ABI only.
#ifndef TUGBOAT_SESSION_ENGINE_TESTS_ENGINE_CLIENT_H
#define TUGBOAT_SESSION_ENGINE_TESTS_ENGINE_CLIENT_H

#include <cstdio>
#include <cstdlib>
#include <string>

#include "tugboat/tb_session_engine.h"

namespace conformance {

struct Response {
  tb_session_status status = TB_SESSION_INTERNAL_ERROR;
  std::string json;
};

class EngineClient {
 public:
  EngineClient() {
    tb_session_engine_config_v1 config{};
    config.abi_version = TB_SESSION_ENGINE_ABI_VERSION;
    if (tb_session_engine_create_v1(&config, &handle_) != TB_SESSION_OK) {
      std::fprintf(stderr, "tb_session_engine_create_v1 failed\n");
      std::exit(2);
    }
  }
  ~EngineClient() { tb_session_engine_destroy(handle_); }
  EngineClient(const EngineClient&) = delete;
  EngineClient& operator=(const EngineClient&) = delete;

  Response submit(const std::string& message) {
    const char* out = nullptr;
    size_t out_len = 0;
    Response response;
    response.status = tb_session_engine_submit_v1(
        handle_, message.data(), message.size(), &out, &out_len);
    response.json.assign(out == nullptr ? "" : out, out_len);
    return response;
  }

 private:
  tb_session_engine* handle_ = nullptr;
};

}  // namespace conformance

#endif  // TUGBOAT_SESSION_ENGINE_TESTS_ENGINE_CLIENT_H
