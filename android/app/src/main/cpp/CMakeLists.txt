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
#  1) AGP configure CMake theo variant build (`> Task :app:configureCMakeDebug[abi]`) và đặt
#     `CMAKE_BUILD_TYPE=debug` (**chữ thường**) — bước CI "Kiểm chứng native" in ra đúng dòng đó,
#     đồng thời cache KHÔNG có `CMAKE_C_FLAGS_DEBUG`/`CMAKE_CXX_FLAGS_DEBUG` ⇒ **không có cờ -O nào
#     được truyền** ⇒ clang biên dịch ở mức mặc định `-O0` cho toàn bộ whisper.cpp + ggml.
#     Host P0 thì build `-DCMAKE_BUILD_TYPE=Release` ⇒ hai bên chênh nhau cả chục lần tốc độ.
#  2) `GGML_NATIVE=OFF` (ở trên) nên không có -march nào ⇒ ggml chỉ dùng kernel NEON cơ bản (kernel
#     dotprod không được biên dịch). Lưu ý: KHÔNG thể bật đại bằng `-march=...dotprod...` cho máy này
#     — xem cảnh báo ⛔ ngay dưới, đã thử và crash thật.
#
# Cách sửa: dùng add_compile_options (KHÔNG phải CMAKE_CXX_FLAGS) — vì cờ của thư mục/target được
# chèn SAU cờ của build type, mới thắng được -O0 mà AGP truyền vào. Đặt trước FetchContent_MakeAvailable
# để mọi target con (whisper, ggml, ggml-base, ggml-cpu) đều thừa hưởng.
add_compile_options(-O3)

# ⛔ KHÔNG THÊM `-march` CÓ dotprod Ở ĐÂY — ĐÃ GÂY CRASH THẬT TRÊN MÁY (2026-09-22).
#
# Tôi từng thêm `-march=armv8.2-a+dotprod+fp16` cho arm64-v8a (giả định "CPU đời mới thì có dotprod").
# Kết quả trên Pixel 3a (Snapdragon 670): app **crash ngay chunk ASR đầu tiên**:
#   signal 4 (SIGILL), code 1 (ILL_ILLOPC) tại libggml-cpu.so (ggml_vec_dot_q5_0_q8_0+256)
#   → ggml_compute_forward_mul_mat → ggml_graph_compute → whisper_full
# Bằng chứng CPU (lấy từ chính máy, KHÔNG suy đoán):
#   Features: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp **asimdhp**   (không có `asimddp`)
#   CPU part: 0x803 (Cortex-A75) ×6 + 0x802 (Cortex-A55) ×2
# ⇒ Cortex-A75 trên máy này KHÔNG có extension dot product ⇒ mọi cặp lệnh SDOT/UDOT của kernel
#    quantize đều là lệnh cấm. Cờ biên dịch theo -march là biên dịch CỨNG cho cả file ⇒ không có
#    đường dispatch lúc chạy để cứu.
#
# Muốn lấy tốc độ dotprod mà không crash thì phải: build 2 biến thể (armv8-a và armv8.2+dotprod) rồi
# CHỌN LÚC CHẠY theo HWCAP (cách ggml mới làm với GGML_BACKEND_DL/GGML_CPU_ALL_VARIANTS), hoặc dùng
# `getauxval(AT_HWCAP)` để tự kiểm trước. Kiểm CPU bằng `adb shell grep Features /proc/cpuinfo`
# TRƯỚC khi bật bất kỳ cờ kiến trúc nào.

FetchContent_MakeAvailable(whisper)

add_library(ai_assistant_jni SHARED whisper_jni.cpp)
target_link_libraries(ai_assistant_jni PRIVATE whisper log)
