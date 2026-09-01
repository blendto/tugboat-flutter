cmake_minimum_required(VERSION 3.22)
project(tugboat_image_jni LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT TB_IMAGE_CORE_DIR)
  message(FATAL_ERROR "TB_IMAGE_CORE_DIR must point at core/image-processing")
endif()

add_subdirectory("${TB_IMAGE_CORE_DIR}" "${CMAKE_BINARY_DIR}/image-core")

add_library(tugboat_image_jni SHARED image_core_jni.cpp)
target_link_libraries(tugboat_image_jni PRIVATE tugboat_image_core jnigraphics log)
target_compile_options(tugboat_image_jni PRIVATE -Wall -Wextra -Wpedantic -Werror)
