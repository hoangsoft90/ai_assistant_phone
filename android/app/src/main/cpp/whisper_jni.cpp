// JNI wrapper cho whisper.cpp — port từ spike P0 (đã compile sạch bằng g++ host đối chiếu
// whisper.h thật), đổi symbol JNI sang package app thật + thêm callback trả kết quả cho Kotlin.
//
// LƯU Ý SYMBOL JNI: Kotlin class nằm ở package `com.aiassistant.phone.asr` — ký tự `.` đổi thành
// `_` là đủ, nhưng đoạn `asr` của package PHẢI escape thành `_asr_` (một `_` trong package đổi
// thành `_1`, còn `asr` không phải chunk bắt đầu bằng số nên được giữ nguyên; dẫu vậy JNI decode
// tên runtime dùng `_` làm dấu phân tách — nếu thiếu `_` ở biên `phone`/`asr` thì khớp sai tên
// class và UnresolvedDefinitionException xảy ra khi System.loadLibrary + lần gọi đầu). Thực tế:
// `_` của `asr` được chèn thủ công thành `_asr_` để phân tách rõ ràng.
//
// Model phải là GGML convert từ whisper.cpp commit đang pin (xem CMakeLists.txt) — file
// ggml-phowhisper-tiny-q5_0.bin đã convert đúng bản đó ở P0.

#include <android/log.h>
#include <jni.h>

#include <string>
#include <vector>

#include "whisper.h"

#define LOG_TAG "AsrJni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

whisper_context *as_ctx(jlong ptr) {
    return reinterpret_cast<whisper_context *>(ptr);
}

}  // namespace

extern "C" {

// Tên hàm phải khớp package: com.aiassistant.phone.asr.AsrNative — `.` -> `_`, đoạn `asr` -> `_asr_`.
JNIEXPORT jlong JNICALL
Java_com_aiassistant_phone__asr_AsrNative_nativeLoadModel(JNIEnv *env, jobject /*thiz*/,
                                                     jstring jpath, jint jthreads) {
    const char *path = env->GetStringUTFChars(jpath, nullptr);
    if (path == nullptr) {
        return 0;
    }

    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;  // CPU-only: đo pin/throttle được, tránh phụ thuộc GPU vendor.
    whisper_context *ctx = whisper_init_from_file_with_params(path, cparams);

    LOGI("load model: %s (threads=%d) -> %p", path, jthreads, static_cast<void *>(ctx));
    env->ReleaseStringUTFChars(jpath, path);

    if (ctx == nullptr) {
        LOGE("không load được model (file sai định dạng GGML/GGUF hoặc hết RAM?)");
    }
    return reinterpret_cast<jlong>(ctx);
}

JNIEXPORT void JNICALL Java_com_aiassistant_phone__asr_AsrNative_nativeFreeModel(JNIEnv * /*env*/,
                                                                            jobject /*thiz*/,
                                                                            jlong jctx) {
    if (jctx != 0) {
        whisper_free(as_ctx(jctx));
        LOGI("đã giải phóng model");
    }
}

// Nhận dạng một chunk PCM float 16kHz. Trả về text (rỗng nếu không có tiếng nói) hoặc
// "ERR:<code>" khi whisper_full thất bại — Kotlin phía trên log rõ ràng.
JNIEXPORT jstring JNICALL Java_com_aiassistant_phone__asr_AsrNative_nativeTranscribe(
    JNIEnv *env, jobject /*thiz*/, jlong jctx, jfloatArray jsamples, jint n_threads) {
    whisper_context *ctx = as_ctx(jctx);
    if (ctx == nullptr) {
        return env->NewStringUTF("ERR:nocontext");
    }

    const jsize n_samples = env->GetArrayLength(jsamples);
    if (n_samples <= 0) {
        return env->NewStringUTF("");
    }

    std::vector<float> pcm(static_cast<size_t>(n_samples));
    env->GetFloatArrayRegion(jsamples, 0, n_samples, pcm.data());

    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.language = "vi";  // PhoWhisper: chỉ tiếng Việt.
    params.detect_language = false;
    params.translate = false;
    params.n_threads = n_threads > 0 ? n_threads : 2;
    params.no_context = true;  // mỗi chunk độc lập — tránh hallucination lây giữa các chunk.
    params.no_timestamps = true;
    params.single_segment = false;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;

    const int rc = whisper_full(ctx, params, pcm.data(), n_samples);
    if (rc != 0) {
        LOGE("whisper_full lỗi, code=%d", rc);
        return env->NewStringUTF(("ERR:" + std::to_string(rc)).c_str());
    }

    std::string text;
    const int n_segments = whisper_full_n_segments(ctx);
    for (int i = 0; i < n_segments; ++i) {
        const char *seg = whisper_full_get_segment_text(ctx, i);
        if (seg != nullptr) {
            text += seg;
        }
    }

    return env->NewStringUTF(text.c_str());
}

}  // extern "C"
