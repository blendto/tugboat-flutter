cmake_minimum_required(VERSION 3.22)
project(tugboat_engine_jni LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT TB_SESSION_ENGINE_DIR)
  message(FATAL_ERROR "TB_SESSION_ENGINE_DIR must point at core/session-engine")
endif()

# Built only through the engine's own target, never by listing its sources.
add_subdirectory("${TB_SESSION_ENGINE_DIR}" "${CMAKE_BINARY_DIR}/session-engine")

add_library(tugboat_engine SHARED engine_jni.cpp)
target_link_libraries(tugboat_engine PRIVATE tugboat_session_engine)
target_compile_options(tugboat_engine PRIVATE -Wall -Wextra -Wpedantic -Werror)
# Keep the static engine's symbols (C ABI, vendored double-conversion) out of
# the dynamic symbol table: only the JNI entry points are exported.
target_link_options(tugboat_engine PRIVATE "-Wl,--exclude-libs,ALL")
