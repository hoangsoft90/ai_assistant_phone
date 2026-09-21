package com.aiassistant.phone

import com.aiassistant.phone.asr.AsrChannelBridge
import com.aiassistant.phone.audio.CaptureChannelBridge
import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import com.pravera.flutter_foreground_task.service.ForegroundService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger

/**
 * Activity duy nhất của app.
 *
 * Ngoài việc khởi động Flutter, Activity này đăng ký **kênh audio capture** (P1A) cho 2 nơi:
 * 1. Engine của UI (dưới đây) — để UI bật/tắt thu và hiện trạng thái.
 * 2. Engine của foreground service — qua `ForegroundService.addTaskLifecycleListener`, vì
 *    `flutter_foreground_task` tạo một FlutterEngine **mới mỗi lần task start** và destroy nó khi
 *    task kết thúc (xem `ForegroundTask.kt` của plugin). Không đăng ký thì isolate của service
 *    không gọi được kênh capture (MissingPluginException).
 *
 * F1 (review P1B): mỗi lần đăng ký PHẢI đi kèm một lần gỡ — nếu không, kênh + sink của engine
 * chết còn treo trong bridge: rò bộ nhớ và giữ VAD bật vĩnh viễn dù không ai nghe. Interface
 * listener của plugin không truyền engine vào `onEngineWillDestroy`, nên messenger của engine
 * service được **nhớ lại từ `onEngineCreate`** để gỡ đúng engine đó.
 *
 * Phần audio/ASR native sẽ còn được thêm dần ở các phase sau (P1C: whisper.cpp JNI).
 */
class MainActivity : FlutterActivity() {

  /** Messenger của engine service hiện tại (null = chưa đăng ký / đã gỡ). Guard: main thread. */
  private var serviceEngineMessenger: BinaryMessenger? = null

  private val captureEngineListener = object : FlutterForegroundTaskLifecycleListener {
    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
      val engine = flutterEngine ?: return
      serviceEngineMessenger = engine.dartExecutor.binaryMessenger
      CaptureChannelBridge.register(engine.dartExecutor.binaryMessenger, applicationContext)
      // P1C: kênh ASR cho isolate của service (P2 sẽ chạy ASR trong service engine).
      AsrChannelBridge.register(engine.dartExecutor.binaryMessenger, applicationContext)
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) = Unit

    override fun onTaskRepeatEvent() = Unit

    override fun onTaskDestroy() = Unit

    override fun onEngineWillDestroy() {
      // Engine service sắp bị plugin destroy: gỡ sạch kênh của đúng engine đó (F1).
      serviceEngineMessenger?.let { CaptureChannelBridge.unregister(it) }
      serviceEngineMessenger = null
    }
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    // Engine UI: cho phép UI bật/tắt capture và nhận trạng thái/lỗi.
    CaptureChannelBridge.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    // P1C: kênh ASR cho engine UI (loadModel/feed từ Dart).
    AsrChannelBridge.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    // Engine của service: cho phép isolate nền subscribe chunk PCM (P1B dùng để chạy VAD).
    ForegroundService.addTaskLifecycleListener(captureEngineListener)
  }

  override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
    // Engine UI bị hủy cùng Activity: gỡ kênh trước khi super phá engine (F1).
    CaptureChannelBridge.unregister(flutterEngine.dartExecutor.binaryMessenger)
    super.cleanUpFlutterEngine(flutterEngine)
  }
}
