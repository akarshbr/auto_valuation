# Builds whisper.cpp together with the Dart FFI shim into one shared library.
cmake_minimum_required(VERSION 3.18)
project(audio_valuation_native CXX C)

set(CMAKE_CXX_STANDARD 17)

# Force Release build optimizations even for Debug builds
set(CMAKE_BUILD_TYPE "Release" CACHE STRING "Choose the type of build." FORCE)

if(MSVC)
  add_compile_options(/O2 /Ob2 /Oi /Ot)
else()
  add_compile_options(-O3 -DNDEBUG -fno-finite-math-only)
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -O3 -DNDEBUG -fno-finite-math-only")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 -DNDEBUG -fno-finite-math-only")
  set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} -O3 -DNDEBUG -fno-finite-math-only")
  set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -O3 -DNDEBUG -fno-finite-math-only")
  set(CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE} -O3 -DNDEBUG -fno-finite-math-only")
  set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -DNDEBUG -fno-finite-math-only")
endif()

set(WHISPER_BUILD_TESTS   OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)

add_subdirectory(whisper.cpp)

add_library(audio_valuation_native SHARED whisper_shim.cpp)
target_link_libraries(audio_valuation_native PRIVATE whisper)
target_include_directories(audio_valuation_native PRIVATE
  whisper.cpp/include
  whisper.cpp/ggml/include
)
