package com.aiassistant.phone.asr

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

private const val TAG = "AsrBridge"

/**
 * Cầu nối JNI tới whisper.cpp (port từ spike P0, đã compile sạch bằng g++ host).
 * Library name phải khớp `add_library(ai_assistant_jni ...)` trong CMakeLists.txt.
 */
object AsrNative {
    init {
        System.loadLibrary("ai_assistant_jni")
    }

    external fun nativeLoadModel(path: String, threads: Int): Long
    external fun nativeFreeModel(ctx: Long)
    external fun nativeTranscribe(ctx: Long, samples: FloatArray, nThreads: Int): String?
}

/**
 * Whisper engine dạng chunk (KHÔNG streaming — whisper.cpp chạy một lượt mỗi đoạn).
 *
 * Port từ `WhisperEngine` của spike P0 với 2 thay đổi cho app thật:
 * 1. Drop policy đổi thành "giữ chunk MỚI NHẤT": engine bận mà tới chunk mới thì chunk chờ cũ
 *    bị thay thế (thay vì bỏ chunk mới như spike) — vì transcript cần audio gần hiện tại nhất;
 *    chunk chờ cũ chỉ là audio đã lag. Số chunk bị bỏ vẫn được đếm vào `dropped`.
 * 2. Kết quả đẩy về Dart qua [AsrChannelBridge] (method `transcript`), không giữ trong Kotlin.
 *
 * KHÔNG gắn nhãn người nói — transcript dạng thô (ràng buộc 4.2b). KHÔNG cloud (ràng buộc thu
 * offline). Inference chạy trên executor 1 thread riêng — không block main thread.
 */
class WhisperChunkEngine(
    private val threads: Int,
    private val onResult: (text: String, latencyMs: Long, audioMs: Long, dropped: Int) -> Unit,
) : AutoCloseable {
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    private val dropped = AtomicInteger(0)

    /** Chunk chờ khi engine bận (tối đa 1 — chunk mới nhất thắng). */
    private var pending: FloatArray? = null

    private var ctx = 0L

    fun load(modelPath: String) {
        ctx = AsrNative.nativeLoadModel(modelPath, threads)
        if (ctx == 0L) {
            throw IllegalStateException("Không load được model PhoWhisper: $modelPath")
        }
        Log.i(TAG, "model loaded: $modelPath (threads=$threads)")
    }

    val isLoaded: Boolean get() = ctx != 0L

    /**
     * Nhận PCM16 (byte, 16kHz mono), chuyển float và chạy nhận dạng.
     * Gọi từ Dart qua MethodChannel — đẩy sang executor để không block platform thread.
     */
    fun feed(pcm16: ByteArray, audioMs: Long, maxQueue: Int) {
        if (!isLoaded) {
            throw IllegalStateException("model chưa load — gọi loadModel trước")
        }
        val floats = FloatArray(pcm16.size / 2)
        for (i in floats.indices) {
            val lo = pcm16[2 * i].toInt() and 0xFF
            val hi = pcm16[2 * i + 1].toInt()
            floats[i] = ((hi shl 8) or lo).toShort() / 32768.0f
        }
        if (!busy.compareAndSet(false, true)) {
            // Engine bận: chunk này trở thành chunk chờ (chunk mới nhất thắng) — nếu đã có
            // chunk chờ thì chunk chờ cũ bị bỏ và đếm vào dropped.
            val replaced = pending != null
            pending = floats
            if (replaced && maxQueue <= 1) {
                val n = dropped.incrementAndGet()
                Log.w(TAG, "chunk chờ cũ bị thay thế (tổng bỏ=$n)")
            }
            return
        }
        submit(floats, audioMs)
    }

    private fun submit(chunk: FloatArray, audioMs: Long) {
        executor.execute {
            val t0 = System.currentTimeMillis()
            var text = ""
            try {
                text = AsrNative.nativeTranscribe(ctx, chunk, threads) ?: ""
            } catch (t: Throwable) {
                Log.e(TAG, "transcribe lỗi", t)
                text = ""
            } finally {
                busy.set(false)
                // Chunk chờ (nếu có) trở thành việc kế tiếp.
                val next = pending
                pending = null
                if (next != null) {
                    if (!busy.compareAndSet(false, true)) {
                        // Hiếm: thread khác vừa chiếm — nhả lại (vẫn giữ chunk mới nhất).
                        pending = next
                    } else {
                        submit(next, audioMs)
                    }
                }
            }
            if (text.startsWith("ERR:")) {
                Log.w(TAG, "whisper trả lỗi: $text")
                text = ""
            }
            onResult(text.trim(), System.currentTimeMillis() - t0, audioMs, dropped.get())
        }
    }

    override fun close() {
        executor.shutdownNow()
        if (ctx != 0L) {
            AsrNative.nativeFreeModel(ctx)
            ctx = 0L
        }
    }
}

/**
 * Đăng ký kênh ASR `com.aiassistant.phone/asr` cho một FlutterEngine.
 *
 * Hợp đồng (phải khớp `AsrChannels`/`PhoWhisperAsrEngine` phía Dart):
 * - Dart→native: `loadModel {path, threads}`, `feed {pcm16 (Uint8List), maxQueue}`,
 *   `releaseModel`.
 * - native→Dart: method `transcript` {text, latencyMs, audioMs, dropped}.
 *
 * Engine là singleton của bridge (1 model trong RAM); Dart phía nào gọi `loadModel` cũng dùng
 * chung. Chỉ đăng ký 1 lần mỗi messenger (idempotent).
 */
object AsrChannelBridge {
    const val ASR_CHANNEL = "com.aiassistant.phone/asr"

    private val registered = mutableSetOf<BinaryMessenger>()
    private var engine: WhisperChunkEngine? = null

    /**
     * Thread riêng cho việc NẶNG: nạp/giải phóng model whisper.cpp (đọc + map 29MB model vào RAM).
     * Handler MethodChannel chạy trên main thread — nạp model ở đó làm treo UI (lỗi F1 của review
     * P1D, đã sửa cho cả 2 bridge để không còn chỗ nào vi phạm quy tắc trong SKILL.md).
     */
    private val loader: java.util.concurrent.ExecutorService =
        java.util.concurrent.Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "asr-loader")
        }

    @Synchronized
    fun register(messenger: BinaryMessenger, context: Context) {
        if (!registered.add(messenger)) {
            Log.w(TAG, "kênh ASR đã đăng ký cho messenger này — bỏ qua")
            return
        }
        val appContext = context.applicationContext
        val channel = MethodChannel(messenger, ASR_CHANNEL)
        channel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            try {
                when (call.method) {
                    "loadModel" -> {
                        val path = call.argument<String>("path")
                            ?: throw IllegalArgumentException("thiếu path")
                        val threads = call.argument<Number>("threads")?.toInt() ?: 2
                        // Nạp model ở thread riêng; chỉ trả kết quả về main thread.
                        loader.execute {
                            try {
                                synchronized(this) {
                                    if (engine?.isLoaded != true) {
                                        engine?.close()
                                        engine = WhisperChunkEngine(threads) { text, latencyMs, audioMs, dropped ->
                                            val payload = mapOf(
                                                "text" to text,
                                                "latencyMs" to latencyMs,
                                                "audioMs" to audioMs,
                                                "dropped" to dropped,
                                            )
                                            mainInvoke { channel.invokeMethod("transcript", payload) }
                                        }
                                    }
                                    engine?.load(path)
                                }
                                mainInvoke { result.success(null) }
                            } catch (t: Throwable) {
                                Log.e(TAG, "loadModel lỗi", t)
                                mainInvoke {
                                    result.error("ASR_FAILED", t.message, t.javaClass.simpleName)
                                }
                            }
                        }
                    }
                    "feed" -> {
                        val pcm = call.argument<ByteArray>("pcm16")
                            ?: throw IllegalArgumentException("thiếu pcm16")
                        val maxQueue = call.argument<Number>("maxQueue")?.toInt() ?: 1
                        // audioMs = độ dài audio của chunk (PCM16 mono 16kHz → byte/16 = ms).
                        engine?.feed(pcm, pcm.size / 32L, maxQueue)
                        result.success(null)
                    }
                    "releaseModel" -> {
                        loader.execute {
                            try {
                                synchronized(this) {
                                    engine?.close()
                                    engine = null
                                }
                                mainInvoke { result.success(null) }
                            } catch (t: Throwable) {
                                Log.e(TAG, "releaseModel lỗi", t)
                                mainInvoke {
                                    result.error("ASR_FAILED", t.message, t.javaClass.simpleName)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                Log.e(TAG, "lỗi xử lý ${call.method}", t)
                result.error("ASR_FAILED", t.message, t.javaClass.simpleName)
            }
        }
        Log.i(TAG, "đã đăng ký kênh ASR")
    }

    /**
     * Gỡ handler kênh ASR của một engine (đối xứng F1 của capture).
     * Gọi khi engine Flutter sắp bị destroy — nếu không, callback `transcript` sẽ được invoke
     * vào messenger của engine đã chết, và engine Dart-side sẽ không đăng ký lại được sạch.
     */
    @Synchronized
    fun unregister(messenger: BinaryMessenger) {
        if (registered.remove(messenger)) {
            val channel = MethodChannel(messenger, ASR_CHANNEL)
            channel.setMethodCallHandler(null)
            Log.i(TAG, "đã gỡ kênh ASR cho engine")
        }
    }

    /**
     * Chạy [invoke] trên main thread (nơi `invokeMethod` của MethodChannel bắt buộc phải chạy).
     *
     * Trước đây hàm này có thêm tham số `messenger` nhưng KHÔNG hề dùng tới — đã bỏ (dead param,
     * cùng loại với F5 của review P1D). Đây cũng là chỗ làm CI fail 1 lần: gọi hàm thiếu tham số
     * chỉ lộ khi Kotlin được compile (máy dev không compile được Kotlin).
     */
    private fun mainInvoke(invoke: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post(invoke)
    }
}
