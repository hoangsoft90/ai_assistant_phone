package vn.p0spike.p0_spike

import android.util.Log
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

private const val TAG = "P0Spike"

/** Cầu nối tới whisper_jni.cpp (whisper.cpp build tĩnh trong cùng .so). */
object WhisperNative {
    init {
        System.loadLibrary("p0spike_jni")
    }

    external fun nativeLoadModel(path: String): Long
    external fun nativeFreeModel(ctx: Long)
    external fun nativeTranscribe(ctx: Long, samples: FloatArray, nThreads: Int): String?
}

/**
 * Vosk: streaming thật (trả kết quả từng phần), độ trễ thấp, chạy 100% offline.
 * Không truyền nhãn người nói — transcript giữ dạng thô (theo mục 4.2b của kế hoạch).
 */
class VoskEngine(modelDir: String) : AutoCloseable {
    private val model = Model(modelDir)
    private val recognizer = Recognizer(model, SAMPLE_RATE.toFloat())

    /** @return (text, đã là kết quả cuối của một câu chưa?) hoặc null nếu chưa có gì mới. */
    fun feed(buf: ShortArray, len: Int): Pair<String, Boolean>? {
        if (recognizer.acceptWaveForm(buf, len)) {
            val text = JSONObject(recognizer.result).optString("text", "")
            return if (text.isBlank()) null else text to true
        }
        val partial = JSONObject(recognizer.partialResult).optString("partial", "")
        return if (partial.isBlank()) null else partial to false
    }

    /** Chốt câu cuối cùng khi dừng ghi âm. */
    fun finish(): String = JSONObject(recognizer.finalResult).optString("text", "")

    override fun close() {
        runCatching { recognizer.close() }
        runCatching { model.close() }
    }
}

/**
 * PhoWhisper (whisper.cpp): không streaming được — gom audio thành chunk 3-5 giây rồi
 * chạy một lượt. Đo độ trễ mỗi chunk để trả lời DoD "độ trễ" của P0.
 *
 * Nếu engine còn đang xử lý chunk trước thì chunk mới bị BỎ (đếm lại vào `dropped`)
 * thay vì xếp hàng vô hạn — hành vi này cần ghi nhận khi đo độ trễ/bỏ sót transcript.
 */
class WhisperEngine(
    private val modelPath: String,
    private val chunkSeconds: Int,
    private val threads: Int,
) : AutoCloseable {
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    val dropped = AtomicInteger(0)

    private val chunkSamples = chunkSeconds * SAMPLE_RATE
    private val chunkBuf = ShortArray(chunkSamples)
    private var filled = 0
    private var ctx = 0L

    fun load() {
        ctx = WhisperNative.nativeLoadModel(modelPath)
        if (ctx == 0L) {
            throw IllegalStateException("Không load được model: $modelPath")
        }
    }

    /**
     * @param onResult (text, độ trễ xử lý ms, độ dài audio ms, có bị bỏ chunk nào không)
     */
    fun feed(buf: ShortArray, len: Int, onResult: (String, Long, Long, Int) -> Unit) {
        var i = 0
        while (i < len) {
            val take = minOf(chunkSamples - filled, len - i)
            System.arraycopy(buf, i, chunkBuf, filled, take)
            filled += take
            i += take
            if (filled == chunkSamples) {
                val chunk = chunkBuf.copyOf()
                filled = 0
                submit(chunk, onResult)
            }
        }
    }

    private fun submit(chunk: ShortArray, onResult: (String, Long, Long, Int) -> Unit) {
        if (!busy.compareAndSet(false, true)) {
            val n = dropped.incrementAndGet()
            Log.w(TAG, "chunk bị bỏ: engine còn đang xử lý (tổng bỏ=$n)")
            return
        }
        executor.execute {
            val t0 = System.currentTimeMillis()
            val audioMs = chunk.size * 1000L / SAMPLE_RATE
            var text = ""
            try {
                val floats = FloatArray(chunk.size) { chunk[it] / 32768.0f }
                text = WhisperNative.nativeTranscribe(ctx, floats, threads) ?: ""
            } catch (t: Throwable) {
                text = "ERR:${t.javaClass.simpleName}:${t.message}"
                Log.e(TAG, "transcribe lỗi", t)
            } finally {
                busy.set(false)
            }
            onResult(text, System.currentTimeMillis() - t0, audioMs, dropped.get())
        }
    }

    override fun close() {
        executor.shutdownNow()
        if (ctx != 0L) {
            WhisperNative.nativeFreeModel(ctx)
            ctx = 0L
        }
    }
}
