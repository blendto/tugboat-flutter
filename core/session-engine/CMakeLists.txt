cmake_minimum_required(VERSION 3.22)
project(tugboat_session_engine LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(TB_SESSION_ENGINE_SANITIZE "Build tests with ASan and UBSan" OFF)
option(TB_SESSION_ENGINE_FUZZ "Build libFuzzer targets (Clang)" OFF)
option(TB_SESSION_ENGINE_BUILD_TESTS "Build CTest unit and conformance tests"
  ON)

set(_tb_sanitize_flags -fsanitize=address,undefined -fno-omit-frame-pointer)

# Vendored google/double-conversion (BSD-3-Clause), namespace renamed to
# tb_double_conversion so it cannot clash with another copy in the host app.
set(_tb_dc "${CMAKE_CURRENT_SOURCE_DIR}/third_party/double-conversion")
set(_tb_dc_sources
  ${_tb_dc}/double-conversion/bignum-dtoa.cc
  ${_tb_dc}/double-conversion/bignum.cc
  ${_tb_dc}/double-conversion/cached-powers.cc
  ${_tb_dc}/double-conversion/double-to-string.cc
  ${_tb_dc}/double-conversion/fast-dtoa.cc
  ${_tb_dc}/double-conversion/fixed-dtoa.cc
  ${_tb_dc}/double-conversion/string-to-double.cc
  ${_tb_dc}/double-conversion/strtod.cc)
set(_tb_engine_sources
  src/capture_budget.cpp
  src/capture_diagnostics.cpp
  src/capture_execution.cpp
  src/capture_facts.cpp
  src/capture_module.cpp
  src/capture_scheduler.cpp
  src/capture_seam.cpp
  src/capture_types.cpp
  src/clock.cpp
  src/collector.cpp
  src/collector_mapping.cpp
  src/config.cpp
  src/coordination.cpp
  src/coordination_module.cpp
  src/dart_time.cpp
  src/delivery.cpp
  src/delivery_gaps.cpp
  src/delivery_lanes.cpp
  src/delivery_module.cpp
  src/engine.cpp
  src/engine_module.cpp
  src/event_queue.cpp
  src/evidence_messages.cpp
  src/evidence_module.cpp
  src/evidence_network.cpp
  src/evidence_parameters.cpp
  src/evidence_value.cpp
  src/fingerprint.cpp
  src/flush_pass.cpp
  src/frame_lane.cpp
  src/frame_retention.cpp
  src/frame_retention_module.cpp
  src/frame_store.cpp
  src/gesture_classifier.cpp
  src/host.cpp
  src/identity_module.cpp
  src/input_observations.cpp
  src/interaction_claims.cpp
  src/interaction_facts.cpp
  src/interaction_module.cpp
  src/interaction_payload.cpp
  src/interaction_publish.cpp
  src/interaction_registry.cpp
  src/interaction_transaction.cpp
  src/json.cpp
  src/lifecycle.cpp
  src/lifecycle_lane.cpp
  src/models.cpp
  src/module_registry.cpp
  src/modules.cpp
  src/navigation_facts.cpp
  src/navigation_module.cpp
  src/navigation_view.cpp
  src/navigator_registry.cpp
  src/output.cpp
  src/pointer_interactions.cpp
  src/pointer_tracker.cpp
  src/reader.cpp
  src/recorder.cpp
  src/retry_after.cpp
  src/delivery_retry_after.cpp
  src/route_barrier.cpp
  src/route_capture.cpp
  src/route_change.cpp
  src/scene_inventory.cpp
  src/scene_inventory_module.cpp
  src/scroll_interactions.cpp
  src/session.cpp
  src/session_module.cpp
  src/stateless_module.cpp
  src/tap_evidence.cpp
  src/tap_settle.cpp
  src/tb_session_engine.cpp
  src/teardown.cpp
  src/text.cpp
  src/transport.cpp)

add_library(tugboat_session_engine STATIC ${_tb_engine_sources}
  ${_tb_dc_sources})
target_include_directories(tugboat_session_engine PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(tugboat_session_engine PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/src" "${_tb_dc}")
set_source_files_properties(${_tb_engine_sources} PROPERTIES
  COMPILE_OPTIONS "-Wall;-Wextra;-Wpedantic;-Werror")
set_source_files_properties(${_tb_dc_sources} PROPERTIES
  COMPILE_OPTIONS "-w")

if(TB_SESSION_ENGINE_SANITIZE)
  target_compile_options(tugboat_session_engine PRIVATE ${_tb_sanitize_flags})
  target_link_options(tugboat_session_engine PRIVATE ${_tb_sanitize_flags})
endif()

if(TB_SESSION_ENGINE_FUZZ)
  target_compile_options(tugboat_session_engine PRIVATE
    -fsanitize=fuzzer-no-link,address,undefined -fno-omit-frame-pointer)
  target_link_options(tugboat_session_engine PRIVATE
    -fsanitize=address,undefined)
endif()

enable_testing()
if(TB_SESSION_ENGINE_BUILD_TESTS AND NOT TB_SESSION_ENGINE_FUZZ)
  # Unit tests reach internal headers; the conformance runner uses only the
  # public C ABI.
  add_executable(tb_session_engine_test tests/tb_session_engine_test.cpp)
  add_executable(tb_session_engine_stateful_test
    tests/tb_session_engine_stateful_test.cpp)
  add_executable(tb_session_engine_interaction_test
    tests/tb_session_engine_interaction_test.cpp)
  add_executable(tb_session_engine_delivery_test
    tests/tb_session_engine_delivery_test.cpp)
  add_executable(tb_session_engine_capture_test
    tests/tb_session_engine_capture_test.cpp)
  add_executable(tb_session_engine_evidence_test
    tests/tb_session_engine_evidence_test.cpp)
  foreach(_tb_unit IN ITEMS tb_session_engine_test
                            tb_session_engine_stateful_test
                            tb_session_engine_interaction_test
                            tb_session_engine_delivery_test
                            tb_session_engine_capture_test
                            tb_session_engine_evidence_test)
    target_include_directories(${_tb_unit} PRIVATE
      "${CMAKE_CURRENT_SOURCE_DIR}/src")
    target_compile_definitions(${_tb_unit} PRIVATE
      TB_CONFORMANCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../conformance")
  endforeach()
  add_executable(tb_session_engine_conformance
    tests/tb_session_engine_conformance.cpp
    tests/conformance/conformance_json.cpp
    tests/conformance/evidence_runner.cpp
    tests/conformance/scenario_runner.cpp)
  target_include_directories(tb_session_engine_conformance PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/tests")
  target_compile_definitions(tb_session_engine_conformance PRIVATE
    TB_CONFORMANCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../conformance")
  foreach(_tb_test IN ITEMS tb_session_engine_test
                            tb_session_engine_stateful_test
                            tb_session_engine_interaction_test
                            tb_session_engine_delivery_test
                            tb_session_engine_capture_test
                            tb_session_engine_evidence_test
                            tb_session_engine_conformance)
    target_link_libraries(${_tb_test} PRIVATE tugboat_session_engine)
    target_compile_options(${_tb_test} PRIVATE -Wall -Wextra -Wpedantic -Werror)
    if(TB_SESSION_ENGINE_SANITIZE)
      target_compile_options(${_tb_test} PRIVATE ${_tb_sanitize_flags})
      target_link_options(${_tb_test} PRIVATE ${_tb_sanitize_flags})
    endif()
    add_test(NAME ${_tb_test} COMMAND ${_tb_test})
  endforeach()
endif()

if(TB_SESSION_ENGINE_FUZZ)
  foreach(_tb_fuzz IN ITEMS message_fuzz)
    add_executable(tb_${_tb_fuzz} fuzz/${_tb_fuzz}.cpp)
    target_link_libraries(tb_${_tb_fuzz} PRIVATE tugboat_session_engine)
    # The fuzzer reads the module registry to cover every message type.
    target_include_directories(tb_${_tb_fuzz} PRIVATE
      "${CMAKE_CURRENT_SOURCE_DIR}/src")
    target_compile_options(tb_${_tb_fuzz} PRIVATE
      -fsanitize=fuzzer,address,undefined -fno-omit-frame-pointer)
    target_link_options(tb_${_tb_fuzz} PRIVATE
      -fsanitize=fuzzer,address,undefined)
  endforeach()
endif()
