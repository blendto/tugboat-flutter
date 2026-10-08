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
  src/collector.cpp
  src/dart_time.cpp
  src/fingerprint.cpp
  src/json.cpp
  src/reader.cpp
  src/tb_session_engine.cpp
  src/text.cpp)

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
  target_include_directories(tb_session_engine_test PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src")
  add_executable(tb_session_engine_conformance
    tests/tb_session_engine_conformance.cpp)
  target_compile_definitions(tb_session_engine_conformance PRIVATE
    TB_CONFORMANCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/../../conformance")
  foreach(_tb_test IN ITEMS tb_session_engine_test
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
    target_compile_options(tb_${_tb_fuzz} PRIVATE
      -fsanitize=fuzzer,address,undefined -fno-omit-frame-pointer)
    target_link_options(tb_${_tb_fuzz} PRIVATE
      -fsanitize=fuzzer,address,undefined)
  endforeach()
endif()
