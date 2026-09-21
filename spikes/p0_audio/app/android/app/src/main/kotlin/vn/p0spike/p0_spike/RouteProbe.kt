package vn.p0spike.p0_spike

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.BatteryManager
import android.os.Build
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import java.util.Locale

private const val TAG = "P0Spike"

/**
 * Đọc trạng thái routing audio + pin để trả lời Task 2 của P0:
 * "mic điện thoại đang thu + tai nghe chỉ phát -> giữ A2DP hay bị ép chuyển HFP (SCO)?"
 *
 * isBluetoothA2dpOn/isBluetoothScoOn đã bị đánh dấu deprecated nhưng vẫn là cách đọc nhanh
 * trạng thái legacy; ngoài ra liệt kê danh sách thiết bị in/out thực tế để đối chiếu.
 */
class RouteProbe(private val ctx: Context) {

    private val am: AudioManager = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    fun batteryPct(): Int =
        (ctx.getSystemService(Context.BATTERY_SERVICE) as BatteryManager)
            .getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)

    @Suppress("DEPRECATION")
    fun snapshot(): Map<String, Any?> = linkedMapOf(
        "scoOn" to am.isBluetoothScoOn,
        "a2dpOn" to am.isBluetoothA2dpOn,
        "speakerphoneOn" to am.isSpeakerphoneOn,
        "audioMode" to am.mode,
        "musicVolume" to am.getStreamVolume(AudioManager.STREAM_MUSIC),
        "outputs" to listOf(*am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)).joinToString(", ") { describe(it) },
        "inputs" to listOf(*am.getDevices(AudioManager.GET_DEVICES_INPUTS)).joinToString(", ") { describe(it) },
        "batteryPct" to batteryPct(),
        "outputSampleRate" to am.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE),
        "wallClock" to System.currentTimeMillis(),
    )

    @Suppress("DEPRECATION")
    fun brief(): String {
        val outs = listOf(*am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)).joinToString(",") { describe(it) }
        return "sco=${am.isBluetoothScoOn} a2dp=${am.isBluetoothA2dpOn} mode=${am.mode} out=[$outs]"
    }

    private fun describe(d: AudioDeviceInfo): String {
        val type = when (d.type) {
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "BT_A2DP"
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "BT_SCO"
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "LOA_NGOAI"
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "EARPIECE"
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> "MIC_DIENTHOAI"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "TAI_NGHE_DAY"
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> "USB"
            else -> "TYPE_${d.type}"
        }
        return "$type:${d.productName}"
    }
}

/**
 * Phát TTS thô để test Task 2/3 (TTS ra tai nghe, rút tai nghe giữa chừng có lọt ra loa ngoài không).
 *
 * CHÚ Ý: đây là code THĂM DÒ của P0. Từ P1F trở đi, toàn bộ dự án chỉ được phát âm thanh
 * qua SafeTtsOutput — không dùng lại cách gọi TextToSpeech trực tiếp này.
 */
class TtsTest(private val ctx: Context, private val log: (String) -> Unit) {

    private var tts: TextToSpeech? = null
    private var ready = false

    fun init() {
        if (tts != null) return
        tts = TextToSpeech(ctx) { status ->
            ready = status == TextToSpeech.SUCCESS
            log("TTS init status=$status (SUCCESS=0)")
        }
    }

    fun speak(text: String) {
        init()
        val engine = tts ?: return
        if (!ready) {
            log("TTS chưa sẵn sàng — thử lại sau 1-2 giây")
            return
        }

        val locale = Locale("vi", "VN")
        val avail = engine.isLanguageAvailable(locale)
        val setResult = engine.setLanguage(locale)
        val voice = engine.voice?.name ?: "?"
        log("TTS language vi-VN: avail=$avail set=$setResult voice=$voice (TextToSpeech.LANG_MISSING_DATA=-1, LANG_NOT_SUPPORTED=-2)")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            log("TTS audioSessionId=${engine.audioSessionId}")
        }

        engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) = log("TTS onStart ($utteranceId)")
            override fun onDone(utteranceId: String?) = log("TTS onDone ($utteranceId)")
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) = log("TTS onError ($utteranceId)")
        })

        val id = "p0-" + System.currentTimeMillis()
        val rc = engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, id)
        log("TTS speak() rc=$rc — nếu lọt ra loa ngoài thì đây là bằng chứng vi phạm")
    }

    // Cố ý không có close(): engine TTS sống theo vòng đời tiến trình. App spike không có điểm
    // nào cần giải phóng TTS mà lại không phải là lúc tắt hẳn cả app (unbind/màn hình tắt vẫn phải
    // giữ ghi âm chạy tiếp), nên thêm close() chỉ tạo code không ai gọi.
}
