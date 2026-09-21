# Build whisper.cpp + JNI wrapper cho app thật (P1C).
#
# Port từ spike P0 (đã biên dịch sạch bằng g++ host đối chiếu whisper.h thật) — giữ nguyên
# version pin của whisper.cpp vì model GGML đã convert theo đúng bản đó; đổi version là có
# nguy cơ không load được file GGML (GGML version/ndim/… khác).
#
# Run CI #1/#2 cho thấy: FetchContent tải whisper.cpp từ GitHub OK trên runner.

cmake_minimum_required(VERSION 3.22.1)
project(ai_assistant_jni C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

FetchContent_Declare(
  whisper
  URL https://github.com/ggml-org/whisper.cpp/archive/307869af285d7f6f689ba100b3515e2d1b3feb05.tar.gz
  URL_HASH SHA256=96a734e909ba97f4a413e16aa3abd21a9100f4ac5e95cd9b3ea6f4f4d27e836f
  DOWNLOAD_EXTRACT_TIMESTAMP OFF
)

# Các cờ dưới đây là những chỗ hay làm fail build Android lần đầu:
#  - GGML_OPENMP=OFF: NDK không tự link libomp.
#  - GGML_NATIVE=OFF: không dùng -march=native (CPU build khác CPU chạy).
#  - GGML_LLAMAFILE=OFF: tắt đường sgemm tuỳ biến để giảm rủi ro biên dịch trên NDK.
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(whisper)

add_library(ai_assistant_jni SHARED whisper_jni.cpp)
target_link_libraries(ai_assistant_jni PRIVATE whisper log)
