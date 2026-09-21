package com.aiassistant.phone.audio

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

private const val TAG = "AudioCapture"

/**
 * Toàn bộ kênh platform đã đăng ký cho **MỘT** FlutterEngine.
 *
 * Sống chết theo engine: được tạo trong [CaptureChannelBridge.register] và **bắt buộc** gỡ bằng
 * [CaptureChannelBridge.unregister] khi engine bị destroy — nếu không:
 * - rò channel handler + sink holder vĩnh viễn (map phình theo mỗi lần service bật/tắt);
 * - sink của engine chết còn non-null ⇒ `hasVadListener()` mãi true ⇒ VAD chạy vô ích và chunk
 *   PCM tiếp tục được copy + post vào messenger của engine đã destroy.
 */
private class EngineChannels(val messenger: BinaryMessenger) {
  val control: MethodChannel = MethodChannel(messenger, CaptureChannelBridge.CONTROL_CHANNEL)
  val pcmHolder: CaptureChannelBridge.SinkHolder = CaptureChannelBridge.SinkHolder()
  val vadHolder: CaptureChannelBridge.SinkHolder = CaptureChannelBridge.SinkHolder()

  /** EventChannel giữ tham chiếu để gỡ handler khi unregister (nếu không sẽ rò handler). */
  lateinit var pcmChannel: EventChannel
  lateinit var vadChannel: EventChannel
}

/**
 * Cầu nối kênh native cho tầng audio capture (P1A) + VAD (P1B).
 *
 * Kiến trúc (quan trọng — đọc trước khi sửa):
 * - **Một** [MicCaptureEngine] duy nhất cho cả process (một [AudioRecord]). Việc đăng ký kênh
 *   xảy ra cho **nhiều** FlutterEngine: engine của UI (MainActivity) và engine của foreground
 *   service (do `flutter_foreground_task` tạo — engine MỚI mỗi lần task start, bị destroy khi
 *   task kết thúc, xem `ForegroundTask.kt` của plugin).
 * - Đăng ký được lưu trong **map theo [BinaryMessenger]**, và `MainActivity` gọi [unregister]
 *   trong `onEngineWillDestroy` (service) + `cleanUpFlutterEngine` (UI). Không bao giờ để lại
 *   phần dư sau khi engine chết.
 * - Chunk PCM chỉ gửi tới sink **đang lắng nghe**; không ai nghe thì **bỏ** chunk (không buffer,
 *   không ghi file) — đúng ràng buộc "không lưu audio ra đĩa mặc định".
 * - Lỗi giữa lúc ghi: engine tự dừng sạch, bridge gọi method `error` trên kênh control của mọi
 *   engine còn đăng ký (Dart bắt bằng `setMethodCallHandler`, xem `NativeCaptureClient`).
 *
 * Hợp đồng kênh (phải khớp `CaptureChannels`/`VadChannels` phía Dart):
 * - control `com.aiassistant.phone/audio_capture`: Dart→native `start`/`stop`/`dispose`;
 *   native→Dart `error` (map `{code, message}`).
 * - pcm `com.aiassistant.phone/audio_capture_pcm`: native→Dart `ByteArray` (PCM16 mono).
 * - vad `com.aiassistant.phone/vad`: native→Dart map
 *   `{speechFrames, totalFrames, frameMs, elapsedMs}` (P1B) — chỉ phát khi có listener.
 */
object CaptureChannelBridge {
  const val CONTROL_CHANNEL = "com.aiassistant.phone/audio_capture"
  const val PCM_CHANNEL = "com.aiassistant.phone/audio_capture_pcm"
  const val VAD_CHANNEL = "com.aiassistant.phone/vad"

  /** Sink của MỘT EventChannel (null = không ai nghe). @Volatile: thread đọc ghi, main thread đọc. */
  class SinkHolder {
    @Volatile var sink: EventChannel.EventSink? = null
  }

  private val mainHandler = Handler(Looper.getMainLooper())

  /** Map engine → kênh. Guard: `this` (bridge). Được đụng từ main thread và thread đọc (đọc list). */
  private val engines = mutableMapOf<BinaryMessenger, EngineChannels>()

  private var engine: MicCaptureEngine? = null

  private fun existingEngine(): MicCaptureEngine? = synchronized(this) { engine }

  private fun engine(context: Context): MicCaptureEngine = synchronized(this) {
    engine ?: MicCaptureEngine(
      context = context.applicationContext,
      onChunk = { bytes -> dispatchChunk(bytes) },
      onFailure = { code, message -> dispatchFailure(code, message) },
      onVad = { result, elapsedMs -> dispatchVad(result, elapsedMs) },
    ).also { engine = it }
  }

  private fun hasListener(): Boolean = synchronized(engines) {
    engines.values.any { it.pcmHolder.sink != null }
  }

  private fun hasVadListener(): Boolean = synchronized(engines) {
    engines.values.any { it.vadHolder.sink != null }
  }

  /**
   * Đăng ký kênh capture cho một FlutterEngine.
   *
   * Gọi cho engine UI trong `MainActivity.configureFlutterEngine`, và cho engine của service
   * qua `ForegroundService.addTaskLifecycleListener { onEngineCreate(...) }`.
   * Idempotent: đăng ký lại cùng messenger là no-op (log để biết).
   */
  fun register(messenger: BinaryMessenger, context: Context) {
    if (synchronized(engines) { engines.containsKey(messenger) }) {
      Log.w(TAG, "register gọi lại cho cùng engine — bỏ qua")
      return
    }
    val created = EngineChannels(messenger)
    synchronized(engines) { engines[messenger] = created }

    created.control.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
      try {
        when (call.method) {
          "start" -> result.success(handleStart(call, context))
          "stop" -> {
            engine(context).stop()
            result.success(null)
          }
          "dispose" -> {
            engine(context).release()
            result.success(null)
          }
          else -> result.notImplemented()
        }
      } catch (e: CaptureStartException) {
        // Lỗi mở mic: trả code riêng để Dart map sang CapturePermissionDenied/CaptureUnavailable.
        Log.w(TAG, "start thất bại: ${e.code} — ${e.message}")
        result.error(e.code, e.message, null)
      } catch (t: Throwable) {
        Log.e(TAG, "lỗi xử lý ${call.method}", t)
        result.error("CAPTURE_FAILED", t.message, t.javaClass.simpleName)
      }
    }

    created.pcmChannel = EventChannel(messenger, PCM_CHANNEL)
    created.pcmChannel.setStreamHandler(
      object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
          created.pcmHolder.sink = events
          Log.i(TAG, "Dart bắt đầu nghe chunk PCM")
        }

        override fun onCancel(arguments: Any?) {
          created.pcmHolder.sink = null // Chỉ nhả sink của engine này.
          Log.i(TAG, "Dart ngừng nghe chunk PCM")
        }
      },
    )

    // P1B: kênh VAD. VAD chỉ chạy khi có ít nhất một listener (tiết kiệm CPU khi UI không xem).
    created.vadChannel = EventChannel(messenger, VAD_CHANNEL)
    created.vadChannel.setStreamHandler(
      object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
          created.vadHolder.sink = events
          engine(context).setVadEnabled(true)
          Log.i(TAG, "Dart bắt đầu nghe VAD")
        }

        override fun onCancel(arguments: Any?) {
          created.vadHolder.sink = null
          if (!hasVadListener()) {
            existingEngine()?.setVadEnabled(false)
          }
          Log.i(TAG, "Dart ngừng nghe VAD")
        }
      },
    )
    Log.i(TAG, "đã đăng ký kênh capture cho engine (tổng ${countEngines()})")
  }

  /**
   * Gỡ sạch mọi kênh của một FlutterEngine **bắt buộc gọi khi engine bị destroy**
   * (`onEngineWillDestroy` của service / `cleanUpFlutterEngine` của Activity). Không gọi thì:
   * rò handler + sink holder, và sink chết giữ `hasVadListener()` = true vĩnh viễn.
   */
  fun unregister(messenger: BinaryMessenger) {
    val removed = synchronized(engines) { engines.remove(messenger) } ?: return
    runCatching { removed.control.setMethodCallHandler(null) }
    runCatching { removed.pcmChannel.setStreamHandler(null) }
    runCatching { removed.vadChannel.setStreamHandler(null) }
    removed.pcmHolder.sink = null
    removed.vadHolder.sink = null
    // Engine service vừa chết: nếu không còn ai nghe VAD thì tắt VAD cho đỡ tốn CPU.
    if (!hasVadListener()) {
      existingEngine()?.setVadEnabled(false)
    }
    Log.i(TAG, "đã gỡ kênh capture của engine (còn ${countEngines()})")
  }

  private fun countEngines(): Int = synchronized(engines) { engines.size }

  private fun handleStart(call: MethodCall, context: Context): Map<String, Any> {
    val requested = CaptureConfig(
      sampleRate = (call.argument<Number>("sampleRate"))?.toInt() ?: 16000,
      numChannels = (call.argument<Number>("numChannels"))?.toInt() ?: 1,
      bitsPerSample = (call.argument<Number>("bitsPerSample"))?.toInt() ?: 16,
      chunkMs = (call.argument<Number>("chunkMs"))?.toInt() ?: 100,
    )
    return engine(context).start(requested).toMap()
  }

  private fun dispatchChunk(bytes: ByteArray) {
    val targets = synchronized(engines) { engines.values.toList() }
    if (targets.none { it.pcmHolder.sink != null }) return // Không ai nghe -> bỏ chunk ngay.
    mainHandler.post {
      for (holder in targets) {
        val sink = holder.pcmHolder.sink ?: continue
        val ok = runCatching { sink.success(bytes) }.isSuccess
        if (!ok) {
          // Sink hỏng (engine đã chết mà chưa kịp unregister) — tự nhả để hasListener() đúng.
          holder.pcmHolder.sink = null
          Log.w(TAG, "sink PCM lỗi khi gửi — đã nhả sink")
        }
      }
    }
  }

  private fun dispatchVad(result: VadResult, elapsedMs: Long) {
    val targets = synchronized(engines) { engines.values.toList() }
    if (targets.none { it.vadHolder.sink != null }) return
    val payload = mapOf(
      "speechFrames" to result.speechFrames,
      "totalFrames" to result.totalFrames,
      "frameMs" to result.frameMs, // F3: do VadDetector quyết định, không hardcode ở đây.
      "elapsedMs" to elapsedMs,
    )
    mainHandler.post {
      for (holder in targets) {
        val sink = holder.vadHolder.sink ?: continue
        val ok = runCatching { sink.success(payload) }.isSuccess
        if (!ok) {
          holder.vadHolder.sink = null
          Log.w(TAG, "sink VAD lỗi khi gửi — đã nhả sink")
        }
      }
    }
  }

  private fun dispatchFailure(code: String, message: String) {
    // Native -> Dart: phải chạy trên main thread (Dart bắt bằng setMethodCallHandler).
    val entries = synchronized(engines) { engines.values.toList() }
    mainHandler.post {
      for (entry in entries) {
        val ok = runCatching {
          entry.control.invokeMethod("error", mapOf("code" to code, "message" to message))
        }.isSuccess
        if (!ok) {
          Log.w(TAG, "gửi lỗi về engine thất bại — unregister engine này")
          unregister(entry.messenger)
        }
      }
    }
  }
}
