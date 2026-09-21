// JNI wrapper tối giản cho whisper.cpp — CHỈ phục vụ P0 (throwaway).
//
// Lưu ý bàn giao cho P1C: đây là bản tối giản, chưa có các thứ mà app thật sẽ cần
// (beam search, VAD, callback realtime, xử lý lỗi chi tiết, đọc model từ assets).

#include <android/log.h>
#include <jni.h>

#include <string>
#include <vector>

#include "whisper.h"

#define LOG_TAG "P0SpikeJni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

whisper_context *as_ctx(jlong ptr) {
    return reinterpret_cast<whisper_context *>(ptr);
}

}  // namespace

extern "C" {

// Tên hàm phải khớp package: vn.p0spike.p0_spike -> phần "_" được escape thành "_1".
JNIEXPORT jlong JNICALL
Java_vn_p0spike_p0_1spike_WhisperNative_nativeLoadModel(JNIEnv *env, jobject /*thiz*/,
                                                       jstring jpath) {
    const char *path = env->GetStringUTFChars(jpath, nullptr);
    if (path == nullptr) {
        return 0;
    }

    whisper_context_params cparams = whisper_context_default_params();
    whisper_context *ctx = whisper_init_from_file_with_params(path, cparams);

    LOGI("load model: %s -> %p", path, static_cast<void *>(ctx));
    env->ReleaseStringUTFChars(jpath, path);

    if (ctx == nullptr) {
        LOGE("không load được model (file sai định dạng GGML/GGUF hoặc hết RAM?)");
    }
    return reinterpret_cast<jlong>(ctx);
}

JNIEXPORT void JNICALL Java_vn_p0spike_p0_1spike_WhisperNative_nativeFreeModel(JNIEnv * /*env*/,
                                                                              jobject /*thiz*/,
                                                                              jlong jctx) {
    if (jctx != 0) {
        whisper_free(as_ctx(jctx));
        LOGI("đã giải phóng model");
    }
}

// Trả về text đã nhận dạng. Trả về chuỗi rỗng nếu chunk không có tiếng nói,
// hoặc "ERR:<code>" nếu whisper_full thất bại (để Kotlin log rõ ràng).
JNIEXPORT jstring JNICALL Java_vn_p0spike_p0_1spike_WhisperNative_nativeTranscribe(
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
    params.language = "vi";  // model PhoWhisper chỉ dùng cho tiếng Việt
    params.detect_language = false;
    params.translate = false;
    params.n_threads = n_threads > 0 ? n_threads : 2;
    params.no_context = true;  // mỗi chunk độc lập, tránh lây hallucination giữa các chunk
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
