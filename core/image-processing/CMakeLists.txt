cmake_minimum_required(VERSION 3.22)
project(tugboat_image_core LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(tugboat_image_core STATIC src/tb_image_core.cpp)
target_include_directories(tugboat_image_core PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_compile_options(tugboat_image_core PRIVATE
  -Wall -Wextra -Wpedantic -Werror)

option(TB_IMAGE_CORE_SANITIZE "Build tests with ASan and UBSan" OFF)
option(TB_IMAGE_CORE_FUZZ "Build libFuzzer targets (Clang)" OFF)
option(TB_IMAGE_CORE_BUILD_TESTS "Build CTest unit tests" ON)

set(_tb_sanitize_flags -fsanitize=address,undefined -fno-omit-frame-pointer)

if(TB_IMAGE_CORE_SANITIZE)
  target_compile_options(tugboat_image_core PRIVATE ${_tb_sanitize_flags})
  target_link_options(tugboat_image_core PRIVATE ${_tb_sanitize_flags})
endif()

if(TB_IMAGE_CORE_FUZZ)
  target_compile_options(tugboat_image_core PRIVATE
    -fsanitize=fuzzer-no-link,address,undefined -fno-omit-frame-pointer)
  target_link_options(tugboat_image_core PRIVATE
    -fsanitize=address,undefined)
endif()

enable_testing()
if(TB_IMAGE_CORE_BUILD_TESTS AND NOT TB_IMAGE_CORE_FUZZ)
  add_executable(tb_image_core_test tests/tb_image_core_test.cpp)
  target_link_libraries(tb_image_core_test PRIVATE tugboat_image_core)
  target_compile_options(tb_image_core_test PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
  if(TB_IMAGE_CORE_SANITIZE)
    target_compile_options(tb_image_core_test PRIVATE ${_tb_sanitize_flags})
    target_link_options(tb_image_core_test PRIVATE ${_tb_sanitize_flags})
  endif()
  add_test(NAME tb_image_core_test COMMAND tb_image_core_test)
endif()

if(TB_IMAGE_CORE_FUZZ)
  foreach(_tb_fuzz IN ITEMS mask_fuzz metadata_fuzz)
    add_executable(tb_${_tb_fuzz} fuzz/${_tb_fuzz}.cpp)
    target_link_libraries(tb_${_tb_fuzz} PRIVATE tugboat_image_core)
    target_compile_options(tb_${_tb_fuzz} PRIVATE
      -fsanitize=fuzzer,address,undefined -fno-omit-frame-pointer)
    target_link_options(tb_${_tb_fuzz} PRIVATE
      -fsanitize=fuzzer,address,undefined)
  endforeach()
endif()
