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
  # KHÔNG dùng DOWNLOAD_EXTRACT_TIMESTAMP: cmake 3.22.1 (mặc định NDK) không nhận keyword này
  # trong FetchContent_Declare (chỉ thêm ở 3.24) — parser gộp nó vào URL_HASH và fail configure.
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

# ---------------------------------------------------------------------------------------------
# TỐC ĐỘ — bắt buộc phải đọc trước khi sửa (bài học A36, đo trên máy thật 2026-09-22)
#
# Hiện tượng: APK debug 1 chunk 4s mất ~160s (RTF ≈ 39, CPU 236%); bản host P0 (Release) là 0.29.
# Nguyên nhân:
#  1) AGP configure CMake theo variant build (`> Task :app:configureCMakeDebug[abi]`) mà project
#     KHÔNG set CMAKE_BUILD_TYPE ⇒ NDK dùng cờ debug của nó, tức **-O0** cho toàn bộ whisper.cpp
#     + ggml. Host P0 thì build `-DCMAKE_BUILD_TYPE=Release`.
#  2) `GGML_NATIVE=OFF` (ở trên) nên không có -march nào ⇒ kernel dotprod/fp16 của ggml KHÔNG được
#     biên dịch, dù CPU máy thật (Pixel 3a: Cortex-A75 + A55) có cả hai.
#
# Cách sửa: dùng add_compile_options (KHÔNG phải CMAKE_CXX_FLAGS) — vì cờ của thư mục/target được
# chèn SAU cờ của build type, mới thắng được -O0 mà AGP truyền vào. Đặt trước FetchContent_MakeAvailable
# để mọi target con (whisper, ggml, ggml-base, ggml-cpu) đều thừa hưởng.
add_compile_options(-O3)

# dotprod/fp16 là phần tăng tốc lớn nhất cho q5_0/q8_0 (kernel quantize).
# ⚠ Đánh đổi đã biết: cờ này biên dịch cứng theo armv8.2 ⇒ máy arm64 đời cũ (Cortex-A53,
# Snapdragon 625/660) KHÔNG có dotprod sẽ SIGILL. Chấp nhận ở giai đoạn đo máy test; TRƯỚC KHI
# phân phối rộng phải chuyển sang nhiều biến thể ABI (armv8-a / armv8.2) hoặc để ggml dispatch
# theo CPU lúc chạy.
if(ANDROID_ABI STREQUAL "arm64-v8a")
  add_compile_options(-march=armv8.2-a+dotprod+fp16)
endif()

FetchContent_MakeAvailable(whisper)

add_library(ai_assistant_jni SHARED whisper_jni.cpp)
target_link_libraries(ai_assistant_jni PRIVATE whisper log)
