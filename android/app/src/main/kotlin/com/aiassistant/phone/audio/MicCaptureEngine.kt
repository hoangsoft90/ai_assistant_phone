package com.aiassistant.phone.audio

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process
import android.os.SystemClock
import android.util.Log

private const val TAG = "AudioCapture"

/** Cấu hình capture, phải khớp `CaptureConfig` phía Dart. */
data class CaptureConfig(
  val sampleRate: Int = 16000,
  val numChannels: Int = 1,
  val bitsPerSample: Int = 16,
  val chunkMs: Int = 100,
) {
  val frameBytes: Int
    get() = sampleRate * chunkMs / 1000 * numChannels * (bitsPerSample / 8)

  /** Map trả về cho Dart qua kênh control. */
  fun toMap(): Map<String, Any> = mapOf(
    "sampleRate" to sampleRate,
    "numChannels" to numChannels,
    "bitsPerSample" to bitsPerSample,
    "chunkMs" to chunkMs,
  )
}

/** Lỗi khi mở mic, mang `code` để Dart map sang CaptureError tương ứng. */
class CaptureStartException(val code: String, message: String) : Exception(message)

/**
 * Engine ghi âm thô từ **mic của điện thoại** (P1A).
 *
 * Quyết định kiến trúc bắt buộc (kế hoạch mục 4.2a):
 * - `MediaRecorder.AudioSource.MIC` — **KHÔNG** dùng `VOICE_COMMUNICATION`/`VOICE_RECOGNITION`:
 *   hai nguồn đó kéo hệ thống sang chế độ đàm thoại (SCO/HFP), hạ chất lượng và buộc dùng
 *   kênh Bluetooth khi tai nghe đang kết nối.
 * - Engine này **không** đụng `AudioManager`/SCO → tắt/bật tai nghe Bluetooth không ảnh hưởng
 *   luồng thu. Việc đó là điều kiện DoD P1A và cần đo lại trên máy thật.
 * - Phase này **không** ghi file, không VAD, không ASR — chỉ đẩy chunk PCM lên Dart.
 *
 * `onChunk` được gọi trên **thread ghi âm** (không phải main thread) với `ByteArray` đã copy
 * riêng cho từng khung — bên nhận an toàn khi giữ tham chiếu.
 */
class MicCaptureEngine(
  private val context: Context,
  private val onChunk: (ByteArray) -> Unit,
  private val onFailure: (code: String, message: String) -> Unit,
  /** Gọi trên thread đọc với kết quả VAD của từng buffer (chỉ khi VAD được bật). */
  private val onVad: ((result: VadResult, elapsedRealtimeMs: Long) -> Unit)? = null,
) {
  @Volatile private var running = false
  private var thread: Thread? = null
  private var record: AudioRecord? = null
  private var config: CaptureConfig = CaptureConfig()

  /** VAD chỉ chạy khi có ai đó nghe (bật qua `setVadEnabled`) — không tốn CPU vô ích. */
  @Volatile private var vadEnabled = false
  private var vadDetector: VadDetector? = null

  /** Bật/tắt VAD. Bật lần đầu sẽ tạo detector (lazy). */
  @Synchronized
  fun setVadEnabled(enabled: Boolean) {
    if (enabled && vadDetector == null) {
      vadDetector = VadDetector().also { it.logConfig() }
    }
    if (vadEnabled != enabled) {
      vadEnabled = enabled
      Log.i(TAG, "VAD ${if (enabled) "bật" else "tắt"}")
    }
  }

  /** Cấu hình thực tế đang dùng (sau khi mở mic thành công). */
  val activeConfig: CaptureConfig get() = config

  val isRunning: Boolean get() = running

  /**
   * Mở mic và bắt đầu vòng đọc. Idempotent: đang chạy thì trả về cấu hình hiện tại.
   *
   * @throws CaptureStartException với code `PERMISSION_DENIED` hoặc `UNAVAILABLE`.
   */
  @SuppressLint("MissingPermission")
  @Synchronized
  fun start(requested: CaptureConfig): CaptureConfig {
    if (running) return config

    if (context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) !=
      PackageManager.PERMISSION_GRANTED
    ) {
      throw CaptureStartException("PERMISSION_DENIED", "Ứng dụng chưa được cấp quyền RECORD_AUDIO")
    }

    val minBufferBytes = AudioRecord.getMinBufferSize(
      requested.sampleRate,
      AudioFormat.CHANNEL_IN_MONO,
      AudioFormat.ENCODING_PCM_16BIT,
    )
    if (minBufferBytes <= 0) {
      throw CaptureStartException(
        "UNAVAILABLE",
        "Thiết bị không hỗ trợ ${requested.sampleRate}Hz mono PCM16 (getMinBufferSize=$minBufferBytes)",
      )
    }

    val recorder = try {
      AudioRecord(
        MediaRecorder.AudioSource.MIC,
        requested.sampleRate,
        AudioFormat.CHANNEL_IN_MONO,
        AudioFormat.ENCODING_PCM_16BIT,
        // Buffer 2 lần mức tối thiểu: đủ để không bị overrun khi ASR/VAD bận ở phase sau.
        minBufferBytes * 2,
      )
    } catch (t: Throwable) {
      throw CaptureStartException("UNAVAILABLE", "Không tạo được AudioRecord: ${t.message}")
    }

    if (recorder.state != AudioRecord.STATE_INITIALIZED) {
      recorder.release()
      throw CaptureStartException("UNAVAILABLE", "AudioRecord không khởi tạo được (STATE_UNINITIALIZED)")
    }

    // Sample rate thực tế thiết bị chấp nhận có thể khác yêu cầu.
    config = requested.copy(sampleRate = recorder.sampleRate)
    record = recorder
    running = true
    try {
      recorder.startRecording()
    } catch (t: Throwable) {
      running = false
      recorder.release()
      record = null
      throw CaptureStartException("UNAVAILABLE", "startRecording lỗi: ${t.message}")
    }

    thread = Thread({ loop(recorder) }, "ai-capture").also { it.start() }
    Log.i(TAG, "bắt đầu thu: $config (minBuffer=$minBufferBytes, frame=${config.frameBytes} byte)")
    return config
  }

  private fun loop(recorder: AudioRecord) {
    // Ưu tiên cao cho thread thu âm: tránh mất mẫu khi hệ thống bận (DoD: chạy 60 phút ổn định).
    Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
    val frameBytes = config.frameBytes.coerceAtLeast(2)
    val buffer = ByteArray(frameBytes)
    while (running) {
      val read = recorder.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
      if (read < 0) {
        if (running) {
          // Lỗi giữa lúc ghi: dừng sạch rồi báo lên Dart (không ném qua thread).
          // LƯU Ý: KHÔNG gọi stop() ở đây — stop() join chính thread này; gọi từ đây sẽ chờ
          // hết timeout join một cách vô ích. Dừng tại chỗ rồi nhả recorder.
          running = false
          releaseRecorder()
          Log.e(TAG, "AudioRecord.read lỗi code=$read — đã dừng capture")
          onFailure("CAPTURE_FAILED", "AudioRecord.read trả mã lỗi $read")
        }
        return
      }
      if (read > 0) {
        // Copy: buffer được tái sử dụng cho khung sau, bên nhận phải giữ dữ liệu riêng.
        onChunk(if (read == buffer.size) buffer.copyOf() else buffer.copyOf(read))
        // VAD chạy ngay trên thread đọc (cùng dữ liệu, không cần copy thêm) — P1B.
        if (vadEnabled) {
          val detector = vadDetector
          val handler = onVad
          if (detector != null && handler != null) {
            handler(detector.analyze(buffer, read), SystemClock.elapsedRealtime())
          }
        }
      }
    }
  }

  /** Dừng ghi và giải phóng AudioRecord. No-op nếu chưa chạy. */
  @Synchronized
  fun stop() {
    if (!running) return
    running = false
    // Chờ thread đọc thoát (nó là thread khác, không phải thread đang gọi).
    thread?.let { runCatching { it.join(1500) } }
    thread = null
    releaseRecorder()
    Log.i(TAG, "đã dừng thu (không release engine — có thể start lại)")
  }

  /** Nhả AudioRecord. Không join thread — dùng được cả từ trong thread đọc. */
  @Synchronized
  private fun releaseRecorder() {
    record?.let { recorder ->
      runCatching { recorder.stop() }
      runCatching { recorder.release() }
    }
    record = null
  }

  /** Giải phóng hoàn toàn (chỉ gọi khi không dùng lại). */
  @Synchronized
  fun release() {
    stop()
    vadDetector?.let { runCatching { it.close() } }
    vadDetector = null
    vadEnabled = false
    Log.i(TAG, "engine đã release")
  }
}
