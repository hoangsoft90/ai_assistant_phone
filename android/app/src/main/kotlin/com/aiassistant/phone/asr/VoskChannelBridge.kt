package com.aiassistant.phone.asr

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.vosk.LibVosk
import org.vosk.LogLevel
import org.vosk.Model
import org.vosk.Recognizer
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.ZipInputStream

private const val TAG = "VoskBridge"

/** Model tiếng Việt của Vosk train ở 16kHz (xem `spikes/p0_audio/tools/verify_vosk.py` của P0). */
private const val SAMPLE_RATE_HZ = 16000

/** PCM16 mono 16kHz → 1 giây = 32000 byte. */
private const val BYTES_PER_SECOND = SAMPLE_RATE_HZ * 2

/** Đánh dấu thư mục model đã giải nén xong (tránh nhận nhầm bản giải nén dở khi app bị kill). */
private const val UNPACK_MARKER = ".unpacked"

/**
 * Engine Vosk dạng **streaming** (khác PhoWhisper: whisper.cpp chạy một lượt cho cả đoạn).
 *
 * Vì sao thiết kế khác `WhisperChunkEngine`:
 * - Vosk tự có endpointing bên trong (`acceptWaveForm` trả `true` khi hết một câu) nên KHÔNG cần
 *   Dart gom 3–5s như PhoWhisper; nhận audio liên tục cho kết quả sớm hơn và không "cắt câu".
 * - Đổi lại, mỗi chunk đều phải chạy inference → nếu máy chậm hơn thời gian thực, hàng đợi sẽ dài
 *   ra. Hàng đợi ở đây có giới hạn, đầy thì bỏ chunk CŨ NHẤT (giữ audio gần hiện tại nhất — cùng
 *   triết lý với PhoWhisper) và đếm vào `dropped` để đo ở DoD.
 *
 * Inference chạy trên 1 thread riêng: `feed` chỉ chuyển byte→short và xếp hàng, KHÔNG bao giờ chặn
 * thread platform (nếu chặn sẽ treo UI vì Dart gọi qua MethodChannel trên main thread).
 *
 * KHÔNG gắn nhãn người nói, KHÔNG cloud (ràng buộc xuyên phase).
 */
class VoskStreamingEngine(
    private val maxQueuedChunks: Int,
    private val onResult: (text: String, latencyMs: Long, audioMs: Long, dropped: Int) -> Unit,
) : AutoCloseable {

    private val pending = LinkedBlockingQueue<ShortArray>(maxQueuedChunks.coerceAtLeast(1))
    private val dropped = AtomicInteger(0)

    /** Bảo vệ các field vòng đời (model/recognizer/worker/generation) khi nạp/giải phóng từ thread khác. */
    private val lifecycleLock = Any()

    private var model: Model? = null

    /** Ghi dưới [lifecycleLock], nhưng `feed`/`isLoaded` đọc từ platform thread ⇒ `@Volatile`. */
    @Volatile
    private var recognizer: Recognizer? = null
    private var worker: Thread? = null

    @Volatile
    private var closed = true

    /**
     * Số "thế hệ" — tăng ở MỌI lần nạp/giải phóng. Worker giữ số của mình lúc start; thấy số đổi
     * là tự thoát. Nhờ vậy worker cũ KHÔNG thể "sống lại" sau một lần `release()` bị kẹt (lỗi F2 của
     * review P1D: nếu chỉ dựa vào `closed`, `load()` đặt lại `closed = false` sẽ làm thread cũ chạy
     * tiếp và dùng chung recognizer với thread mới — Vosk native không thread-safe).
     */
    @Volatile
    private var generation = 0

    @Volatile
    private var audioMs = 0L

    val isLoaded: Boolean get() = recognizer != null

    /**
     * Nạp model từ **thư mục** (Vosk C API không đọc được zip/asset trực tiếp — xem
     * [unpackModelIfNeeded]). Ném IOException nếu model sai/thiếu file.
     *
     * LÀ VIỆC NẶNG (có thể vài giây) — bridge gọi hàm này từ thread riêng, không phải main thread
     * (lỗi F1 của review P1D).
     */
    fun load(modelDir: String) {
        release()
        LibVosk.setLogLevel(LogLevel.WARNINGS)
        val loadedModel = Model(modelDir)
        val loadedRecognizer = Recognizer(loadedModel, SAMPLE_RATE_HZ.toFloat())
        synchronized(lifecycleLock) {
            model = loadedModel
            recognizer = loadedRecognizer
            closed = false
            generation++
            val myGeneration = generation
            // Truyền recognizer RIÊNG của thread này vào: worker không bao giờ chạm recognizer mới.
            worker = Thread({ consume(loadedRecognizer, myGeneration) }, "vosk-asr").also { it.start() }
        }
        Log.i(TAG, "model Vosk đã load: $modelDir")
    }

    /** Nhận PCM16 little-endian mono 16kHz; không chặn caller. */
    fun feed(pcm16: ByteArray) {
        if (recognizer == null) {
            throw IllegalStateException("model chưa load — gọi loadModel trước")
        }
        val samples = ShortArray(pcm16.size / 2)
        for (i in samples.indices) {
            val lo = pcm16[2 * i].toInt() and 0xFF
            val hi = pcm16[2 * i + 1].toInt()
            samples[i] = ((hi shl 8) or lo).toShort()
        }
        if (!pending.offer(samples)) {
            pending.poll() // Bỏ chunk cũ nhất.
            pending.offer(samples)
            val total = dropped.incrementAndGet()
            Log.w(TAG, "hàng đợi đầy — bỏ chunk cũ (tổng bỏ=$total, chờ=${pending.size})")
        }
    }

    /** Còn là worker hiện hành không (chưa bị đóng VÀ chưa bị thế hệ mới thay). */
    private fun isCurrent(myGeneration: Int): Boolean = !closed && myGeneration == generation

    private fun consume(rec: Recognizer, myGeneration: Int) {
        while (isCurrent(myGeneration)) {
            val chunk: ShortArray = try {
                pending.poll(100, TimeUnit.MILLISECONDS)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                return
            } ?: continue
            if (!isCurrent(myGeneration)) {
                return
            }
            try {
                val started = System.currentTimeMillis()
                audioMs += chunk.size * 1000L / SAMPLE_RATE_HZ
                val endpointReached = rec.acceptWaveForm(chunk, chunk.size)
                if (endpointReached) {
                    // `result` chỉ có nghĩa khi acceptWaveForm trả true (hết một câu).
                    val text = extractText(rec.result)
                    if (text.isNotEmpty()) {
                        onResult(
                            text,
                            System.currentTimeMillis() - started,
                            audioMs,
                            dropped.get(),
                        )
                    }
                }
            } catch (t: Throwable) {
                Log.e(TAG, "acceptWaveForm lỗi", t)
            }
        }
    }

    private fun extractText(json: String?): String = try {
        JSONObject(json ?: "").optString("text", "").trim()
    } catch (t: Throwable) {
        Log.w(TAG, "JSON kết quả Vosk không đọc được: ${t.message}")
        ""
    }

    /**
     * Giải phóng model + thread. An toàn khi gọi nhiều lần.
     *
     * Flush (F4 của review): audio đã nhận nhưng chưa tới endpoint VẪN được nhận dạng nốt bằng
     * `getFinalResult()` trước khi đóng — nếu không thì tắt ASR giữa câu sẽ mất đúng câu đang nói.
     * Flush là best-effort: khi worker chưa dừng thì bỏ qua (không đụng native đang chạy).
     */
    fun release() {
        val thread: Thread?
        synchronized(lifecycleLock) {
            closed = true
            generation++ // Vô hiệu hoá worker hiện tại, kể cả khi nó đang kẹt trong acceptWaveForm.
            thread = worker
            worker = null
        }
        if (thread != null) {
            try {
                thread.join(5000)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            if (thread.isAlive) {
                // Vẫn đang chạy inference: KHÔNG flush/đóng native (đóng khi đang gọi native có thể
                // crash tiến trình). Chấp nhận giữ lại tới khi tiến trình chết, và báo rõ trong log.
                Log.e(TAG, "thread Vosk chưa dừng sau 5s — bỏ qua flush + đóng model (tránh crash native)")
                pending.clear()
                return
            }
        }
        val current: Recognizer? = synchronized(lifecycleLock) {
            val rec = recognizer
            recognizer = null
            rec
        }
        if (current != null) {
            try {
                val started = System.currentTimeMillis()
                val text = extractText(current.finalResult)
                if (text.isNotEmpty()) {
                    onResult(text, System.currentTimeMillis() - started, audioMs, dropped.get())
                }
            } catch (t: Throwable) {
                Log.w(TAG, "flush kết quả cuối lỗi: ${t.message}")
            }
            try {
                current.close()
            } catch (t: Throwable) {
                Log.w(TAG, "đóng recognizer lỗi: ${t.message}")
            }
        }
        val loadedModel = synchronized(lifecycleLock) {
            val m = model
            model = null
            m
        }
        try {
            loadedModel?.close()
        } catch (t: Throwable) {
            Log.w(TAG, "đóng model lỗi: ${t.message}")
        }
        pending.clear()
        audioMs = 0L
        dropped.set(0)
    }

    override fun close() = release()
}

/**
 * Giải nén model Vosk từ asset `.zip` ra `filesDir/vosk-models/<tên-model>` — Vosk C API chỉ nhận
 * đường dẫn THƯ MỤC (chứa `am/`, `conf/`, `graph/`, `ivector/`), không đọc được zip hay asset.
 *
 * Bỏ qua nếu thư mục đích đã có marker hoàn tất (đổi tên model = đổi tên thư mục → tự giải nén lại).
 *
 * Asset này là **Android asset** (`android/app/src/main/assets/models/…`), KHÔNG phải asset khai
 * báo trong pubspec như model PhoWhisper — lý do ở `pubspec.yaml` mục `assets:` và
 * `lib/audio/asr/README.md` (chủ yếu: model không commit được nên nếu khai trong pubspec thì
 * `flutter test` fail ở bước build asset bundle).
 */
internal fun unpackModelIfNeeded(context: Context, assetPath: String): File {
    val modelName = assetPath.substringAfterLast('/').removeSuffix(".zip")
    val target = File(File(context.filesDir, "vosk-models"), modelName)
    val marker = File(target, UNPACK_MARKER)
    val assetsRoot = File(target, "am")
    if (marker.isFile && assetsRoot.isDirectory) {
        Log.i(TAG, "model đã có sẵn: ${target.path}")
        return target
    }
    if (target.exists()) {
        target.deleteRecursively() // Bản giải nén dở từ lần trước.
    }
    target.mkdirs()

    val started = System.currentTimeMillis()
    var entries = 0
    context.assets.open(assetPath).use { raw ->
        ZipInputStream(raw.buffered()).use { zip ->
            var entry = zip.nextEntry
            while (entry != null) {
                // Zip của alphacephei có 1 thư mục gốc (vd `vosk-model-vn-0.4/`) → bỏ đoạn đầu để
                // thư mục đích chứa thẳng am/conf/graph/ivector.
                val relative = entry.name.substringAfter('/', entry.name)
                if (relative.isNotEmpty()) {
                    if (relative.contains("..")) {
                        throw IllegalStateException("entry zip không hợp lệ: ${entry.name}")
                    }
                    val out = File(target, relative)
                    if (entry.isDirectory) {
                        out.mkdirs()
                    } else {
                        out.parentFile?.mkdirs()
                        out.outputStream().use { sink -> zip.copyTo(sink) }
                        entries++
                    }
                }
                zip.closeEntry()
                entry = zip.nextEntry
            }
        }
    }
    marker.writeText("${entries} entries")
    Log.i(
        TAG,
        "đã giải nén model: ${target.path} ($entries file, " +
            "${System.currentTimeMillis() - started}ms)",
    )
    return target
}

/**
 * Đăng ký kênh ASR dự phòng `com.aiassistant.phone/vosk`.
 *
 * Hợp đồng (khớp `VoskAsrEngine`/`VoskChannels` phía Dart):
 * - Dart→native: `loadModel {asset, maxQueue}`, `feed {pcm16 (Uint8List)}`, `releaseModel`.
 * - native→Dart: method `transcript` {text, latencyMs, audioMs, dropped}.
 *
 * Mỗi messenger chỉ đăng ký 1 lần; PHẢI gỡ bằng [unregister] khi engine Flutter bị destroy
 * (đối xứng với `AsrChannelBridge`/`CaptureChannelBridge` — xem F1 của review P1B).
 */
object VoskChannelBridge {
    const val VOSK_CHANNEL = "com.aiassistant.phone/vosk"

    private val registered = mutableSetOf<BinaryMessenger>()

    /**
     * Ghi từ thread `vosk-loader`, nhưng **đọc từ platform thread** trong nhánh `feed` (không cùng
     * lock) ⇒ cần `@Volatile`, nếu không có thể đọc phải giá trị cũ và `feed` vào engine đã release
     * (chunk xếp vào hàng đợi không ai lấy).
     */
    @Volatile
    private var engine: VoskStreamingEngine? = null

    /**
     * Thread riêng cho các việc NẶNG: giải nén model (51MB) + nạp/giải phóng model Vosk.
     *
     * Handler của MethodChannel chạy trên main (platform) thread — làm việc nặng ở đó sẽ treo UI và
     * có thể vào vùng ANR 5s ở lần nạp đầu (lỗi F1 của review P1D). Một thread đơn cũng giúp các lần
     * nạp/giải phóng không chạy chồng lên nhau.
     */
    private val loader: java.util.concurrent.ExecutorService =
        java.util.concurrent.Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "vosk-loader")
        }

    @Synchronized
    fun register(messenger: BinaryMessenger, context: Context) {
        if (!registered.add(messenger)) {
            Log.w(TAG, "kênh Vosk đã đăng ký cho messenger này — bỏ qua")
            return
        }
        val appContext = context.applicationContext
        val channel = MethodChannel(messenger, VOSK_CHANNEL)
        channel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            try {
                when (call.method) {
                    "loadModel" -> {
                        // Đường dẫn Android asset (vd `models/vosk-model-small-vn-0.4.zip`).
                        val asset = call.argument<String>("asset")
                            ?: throw IllegalArgumentException("thiếu asset")
                        val maxQueue = call.argument<Number>("maxQueue")?.toInt() ?: 25
                        // Giải nén + nạp model ở thread riêng; chỉ trả kết quả về main thread.
                        loader.execute {
                            try {
                                val dir = unpackModelIfNeeded(appContext, asset)
                                synchronized(this) {
                                    if (engine?.isLoaded != true) {
                                        engine?.close()
                                        engine = VoskStreamingEngine(maxQueue) { text, latencyMs, audioMs, dropped ->
                                            val payload = mapOf(
                                                "text" to text,
                                                "latencyMs" to latencyMs,
                                                "audioMs" to audioMs,
                                                "dropped" to dropped,
                                            )
                                            invokeOnMain {
                                                channel.invokeMethod("transcript", payload)
                                            }
                                        }
                                    }
                                    engine?.load(dir.path)
                                }
                                invokeOnMain { result.success(null) }
                            } catch (t: Throwable) {
                                Log.e(TAG, "loadModel lỗi", t)
                                invokeOnMain {
                                    result.error("VOSK_FAILED", t.message, t.javaClass.simpleName)
                                }
                            }
                        }
                    }
                    "feed" -> {
                        val pcm = call.argument<ByteArray>("pcm16")
                            ?: throw IllegalArgumentException("thiếu pcm16")
                        engine?.feed(pcm)
                        result.success(null)
                    }
                    "releaseModel" -> {
                        // `close()` có flush kết quả cuối (F4) → vẫn là việc nặng, chạy ở thread riêng.
                        loader.execute {
                            try {
                                synchronized(this) {
                                    engine?.close()
                                    engine = null
                                }
                                invokeOnMain { result.success(null) }
                            } catch (t: Throwable) {
                                Log.e(TAG, "releaseModel lỗi", t)
                                invokeOnMain {
                                    result.error("VOSK_FAILED", t.message, t.javaClass.simpleName)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                Log.e(TAG, "lỗi xử lý ${call.method}", t)
                result.error("VOSK_FAILED", t.message, t.javaClass.simpleName)
            }
        }
        Log.i(TAG, "đã đăng ký kênh Vosk")
    }

    /** Gỡ handler kênh Vosk của một engine Flutter (đối xứng F1). */
    @Synchronized
    fun unregister(messenger: BinaryMessenger) {
        if (registered.remove(messenger)) {
            MethodChannel(messenger, VOSK_CHANNEL).setMethodCallHandler(null)
            Log.i(TAG, "đã gỡ kênh Vosk cho engine")
        }
    }

    /**
     * Chạy [invoke] trên main thread (nơi `invokeMethod` của MethodChannel bắt buộc phải chạy).
     *
     * Trước đây hàm này có thêm tham số `messenger` nhưng KHÔNG hề dùng tới — đã bỏ (dead param,
     * cùng loại với F5 của review P1D). Đây cũng là chỗ làm CI fail 1 lần: gọi hàm thiếu tham số
     * chỉ lộ khi Kotlin được compile (máy dev không compile được Kotlin).
     */
    private fun invokeOnMain(invoke: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post(invoke)
    }
}
