package vn.p0spike.p0_spike

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File

/** Cả 2 engine đều ăn 16kHz mono PCM16 — đây cũng là mức mic điện thoại cần ghi (mục 4.2a). */
const val SAMPLE_RATE = 16000

/** Độ dài mỗi lần đọc từ AudioRecord: 100ms. */
private const val FRAME_MS = 100

private const val TAG = "P0Spike"

/**
 * Ghi âm từ **mic điện thoại** (AudioSource.MIC) — KHÔNG dùng VOICE_COMMUNICATION để tránh
 * kéo theo route SCO/HFP của tai nghe Bluetooth (đây chính là điều Task 2 của P0 muốn xác nhận).
 *
 * onFrame được gọi trên thread ghi âm, dùng lại cùng 1 mảng buffer -> bên nhận phải xử lý
 * ngay hoặc copy ra, không giữ tham chiếu.
 */
class AudioCapture(
    private val sampleRateWanted: Int = SAMPLE_RATE,
    private val onFrame: (ShortArray, Int) -> Unit,
    private val onError: (String) -> Unit,
) {
    @Volatile private var running = false
    private var thread: Thread? = null
    private var record: AudioRecord? = null

    var actualSampleRate = 0
        private set
    var minBufferBytes = 0
        private set

    fun start(): Boolean {
        if (running) return true
        val minBuf = AudioRecord.getMinBufferSize(
            sampleRateWanted,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            onError("getMinBufferSize trả về $minBuf (sampleRate=$sampleRateWanted)")
            return false
        }

        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRateWanted,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuf * 2,
            )
        } catch (t: Throwable) {
            onError("không tạo được AudioRecord: ${t.message}")
            return false
        }

        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            onError("AudioRecord STATE_UNINITIALIZED")
            return false
        }

        record = rec
        minBufferBytes = minBuf * 2
        actualSampleRate = rec.sampleRate
        rec.startRecording()
        running = true
        thread = Thread({ loop(rec) }, "p0-capture").also { it.start() }
        Log.i(TAG, "AudioCapture start: sampleRate=$actualSampleRate source=MIC minBuf=$minBufferBytes")
        return true
    }

    private fun loop(rec: AudioRecord) {
        val frameSamples = actualSampleRate * FRAME_MS / 1000
        val buf = ShortArray(frameSamples)
        while (running) {
            val n = rec.read(buf, 0, buf.size, AudioRecord.READ_BLOCKING)
            if (n < 0) {
                onError("AudioRecord.read lỗi code=$n")
                break
            }
            if (n > 0) onFrame(buf, n)
        }
    }

    fun stop() {
        if (!running) return
        running = false
        runCatching { thread?.join(1500) }
        thread = null
        record?.let {
            runCatching { it.stop() }
            runCatching { it.release() }
        }
        record = null
        Log.i(TAG, "AudioCapture stop")
    }
}

/**
 * Điều phối toàn bộ app spike. Singleton để ghi âm vẫn sống khi Activity bị hủy (chạy nền 45-60 phút).
 *
 * Mọi event đều được ghi vào logcat trước (tag P0Spike) rồi mới đẩy lên UI — nhờ vậy log
 * `adb logcat -s P0Spike:I` vẫn đầy đủ kể cả khi màn hình tắt.
 */
class SpikeController private constructor(private val ctx: Context) {

    private val probe = RouteProbe(ctx)
    private val tts = TtsTest(ctx) { msg -> emitLog(msg) }
    private val ui = Handler(Looper.getMainLooper())

    @Volatile private var emitter: ((Map<String, Any?>) -> Unit)? = null
    @Volatile private var mode = "idle"
    private var capture: AudioCapture? = null
    private var vosk: VoskEngine? = null
    private var whisper: WhisperEngine? = null
    private var chunkSeconds = 3

    /** Đọc/ghi từ 2 thread (thread ghi âm và UI thread) -> giữ volatile cho chắc. */
    @Volatile private var frames = 0L

    private val statusTick = object : Runnable {
        override fun run() {
            if (mode == "idle") return
            emitLog("ROUTE ${probe.brief()} | pin=${probe.batteryPct()}% | audio=${frames * 1000L / SAMPLE_RATE}ms")
            ui.postDelayed(this, STATUS_PERIOD_MS)
        }
    }

    fun setEmitter(e: ((Map<String, Any?>) -> Unit)?) {
        emitter = e
    }

    fun modelsDir(): File = File(ctx.getExternalFilesDir(null), "models")

    private fun resolveWhisperModel(): File? {
        val candidates = listOf(
            "ggml-phowhisper-base-q5_0.bin",
            "ggml-phowhisper-tiny-q5_0.bin",
            "ggml-phowhisper-base-f16.bin",
        )
        return candidates.map { File(modelsDir(), it) }.firstOrNull { it.isFile }
    }

    private fun resolveVoskModel(): File? =
        File(modelsDir(), "vosk-model-small-vn-0.4").let { if (it.isDirectory) it else null }

    fun status(): Map<String, Any?> {
        val m = LinkedHashMap<String, Any?>(probe.snapshot())
        m["mode"] = mode
        m["chunkSeconds"] = chunkSeconds
        m["threads"] = Runtime.getRuntime().availableProcessors()
        m["frames"] = frames
        m["audioMs"] = frames * 1000L / SAMPLE_RATE
        m["modelsDir"] = modelsDir().absolutePath
        m["whisperModel"] = resolveWhisperModel()?.name ?: "THIẾU"
        m["voskModel"] = if (resolveVoskModel() != null) "vosk-model-small-vn-0.4" else "THIẾU"
        m["captureSampleRate"] = capture?.actualSampleRate ?: 0
        m["droppedChunks"] = whisper?.dropped?.get() ?: 0
        m["keepAlive"] = SpikeService.isRunning
        return m
    }

    @Synchronized
    fun start(engine: String, requestedChunkSeconds: Int): Map<String, Any?> {
        stopInternal()
        chunkSeconds = requestedChunkSeconds.coerceIn(2, 10)

        when (engine) {
            "vosk" -> {
                val dir = resolveVoskModel()
                    ?: return failure("Chưa có model Vosk. Cần: ${modelsDir()}/vosk-model-small-vn-0.4/")
                emitLog("nạp Vosk từ ${dir.absolutePath}")
                vosk = try {
                    VoskEngine(dir.absolutePath)
                } catch (t: Throwable) {
                    return failure("load Vosk lỗi: ${t.message}")
                }
            }

            "whisper" -> {
                val file = resolveWhisperModel()
                    ?: return failure("Chưa có model PhoWhisper. Cần: ${modelsDir()}/ggml-phowhisper-base-q5_0.bin")
                emitLog("nạp PhoWhisper ${file.name} (chunk ${chunkSeconds}s, ${Runtime.getRuntime().availableProcessors()} threads, ${file.length() / 1048576}MB)")
                whisper = try {
                    WhisperEngine(file.absolutePath, chunkSeconds, Runtime.getRuntime().availableProcessors()).also { it.load() }
                } catch (t: Throwable) {
                    whisper = null
                    return failure("load PhoWhisper lỗi: ${t.message}")
                }
            }

            else -> return failure("engine không hợp lệ: $engine")
        }

        val cap = AudioCapture(SAMPLE_RATE, ::onFrame) { msg -> emitLog("LỖI MIC: $msg") }
        if (!cap.start()) {
            stopInternal()
            return failure("không mở được mic — kiểm tra quyền RECORD_AUDIO")
        }
        capture = cap
        mode = engine
        frames = 0
        ui.postDelayed(statusTick, STATUS_PERIOD_MS)
        emitLog("BẮT ĐẦU engine=$engine mic=${cap.actualSampleRate}Hz | ${probe.brief()}")
        emit(status())
        return status()
    }

    @Synchronized
    fun stop(): Map<String, Any?> {
        stopInternal()
        emitLog("ĐÃ DỪNG")
        emit(status())
        return status()
    }

    private fun stopInternal() {
        ui.removeCallbacks(statusTick)
        capture?.stop()
        capture = null
        vosk?.let {
            val tail = runCatching { it.finish() }.getOrDefault("")
            if (tail.isNotBlank()) {
                emit(mapOf("type" to "transcript", "engine" to "vosk", "text" to tail, "final" to true))
            }
            runCatching { it.close() }
        }
        vosk = null
        whisper?.let { w ->
            emitLog("PhoWhisper kết thúc: bỏ ${w.dropped.get()} chunk vì xử lý không kịp")
            runCatching { w.close() }
        }
        whisper = null
        mode = "idle"
    }

    private fun onFrame(buf: ShortArray, n: Int) {
        frames += n
        when (mode) {
            "vosk" -> {
                val r = vosk?.feed(buf, n) ?: return
                emit(
                    mapOf(
                        "type" to "transcript",
                        "engine" to "vosk",
                        "text" to r.first,
                        "final" to r.second,
                    ),
                )
            }

            "whisper" -> whisper?.feed(buf, n) { text, latencyMs, audioMs, dropped ->
                when {
                    text.startsWith("ERR:") -> emitLog("whisper lỗi: $text")
                    text.isBlank() -> Unit // chunk im lặng, không cần log rác
                    else -> emit(
                        mapOf(
                            "type" to "transcript",
                            "engine" to "whisper",
                            "text" to text.trim(),
                            "final" to true,
                            "latencyMs" to latencyMs,
                            "audioMs" to audioMs,
                            "dropped" to dropped,
                        ),
                    )
                }
            }
        }
    }

    fun speak(text: String): Map<String, Any?> {
        emitLog("TTS test | ${probe.brief()}")
        tts.speak(text)
        return status()
    }

    fun keepAlive(start: Boolean): Map<String, Any?> {
        if (start) {
            SpikeService.start(ctx)
            emitLog("bật foreground service (giữ tiến trình khi màn hình tắt)")
        } else {
            SpikeService.stop(ctx)
            emitLog("tắt foreground service")
        }
        ui.postDelayed({ emit(status()) }, 400)
        return status()
    }

    private fun failure(message: String): Map<String, Any?> {
        emitLog("LỖI: $message")
        return status() + mapOf("error" to message)
    }

    private fun emitLog(line: String) {
        Log.i(TAG, line)
        emit(mapOf("type" to "log", "text" to line))
    }

    private fun emit(event: Map<String, Any?>) {
        if (event["type"] == "transcript") {
            val text = event["text"] as? String ?: ""
            Log.i(TAG, "TRANSCRIPT[${event["engine"]}] $text (latency=${event["latencyMs"] ?: "-"}ms)")
        }
        emitter?.invoke(event)
    }

    companion object {
        private const val STATUS_PERIOD_MS = 5000L

        @Volatile private var instance: SpikeController? = null

        fun get(ctx: Context): SpikeController =
            instance ?: synchronized(this) {
                instance ?: SpikeController(ctx.applicationContext).also { instance = it }
            }
    }
}
