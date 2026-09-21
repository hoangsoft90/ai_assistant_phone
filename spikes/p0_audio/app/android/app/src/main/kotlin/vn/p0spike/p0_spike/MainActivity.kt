package vn.p0spike.p0_spike

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * App spike P0 — throwaway.
 *
 * Kiến trúc cố tình giống hướng của P1A/P1C: toàn bộ phần audio + ASR nằm ở tầng native/Kotlin,
 * Flutter chỉ là màn hình điều khiển + log. Nhờ vậy phần đã kiểm chứng được ở P0 (AudioRecord
 * source MIC, whisper.cpp JNI, Vosk streaming) có thể mang thẳng sang P1A/P1C.
 */
class MainActivity : FlutterActivity() {

    private lateinit var controller: SpikeController

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        controller = SpikeController.get(applicationContext)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    controller.setEmitter { event -> runOnUiThread { events?.success(event) } }
                }

                override fun onCancel(arguments: Any?) {
                    // UI không còn nghe -> vẫn ghi tiếp vào logcat, chỉ ngắt đẩy lên UI
                    controller.setEmitter(null)
                }
            },
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONTROL_CHANNEL)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                try {
                    when (call.method) {
                        "status" -> result.success(controller.status())
                        "start" -> result.success(
                            controller.start(
                                call.argument<String>("engine") ?: "vosk",
                                // Dart có thể gửi Integer hoặc Long -> đọc qua Number cho chắc
                                call.argument<Number>("chunkSeconds")?.toInt() ?: 3,
                            ),
                        )
                        "stop" -> result.success(controller.stop())
                        "speak" -> result.success(
                            controller.speak(call.argument<String>("text") ?: "Đây là câu kiểm tra phát ra tai nghe."),
                        )
                        "keepAlive" -> result.success(
                            controller.keepAlive(call.argument<Boolean>("start") ?: true),
                        )
                        else -> result.notImplemented()
                    }
                } catch (t: Throwable) {
                    result.error("P0_SPIKE", t.message, t.javaClass.simpleName)
                }
            }

        ensurePermissions()
    }

    private fun ensurePermissions() {
        val wanted = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            wanted.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        val missing = wanted.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) {
            requestPermissions(missing.toTypedArray(), REQUEST_CODE)
        }
    }

    override fun onDestroy() {
        // KHÔNG shutdown controller ở đây: nó là singleton để ghi âm vẫn sống khi Activity bị
        // hủy trong lúc test chạy nền (45-60 phút).
        controller.setEmitter(null)
        super.onDestroy()
    }

    companion object {
        private const val CONTROL_CHANNEL = "p0spike/control"
        private const val EVENTS_CHANNEL = "p0spike/events"
        private const val REQUEST_CODE = 101
    }
}
