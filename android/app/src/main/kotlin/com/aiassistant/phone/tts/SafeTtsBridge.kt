package com.aiassistant.phone.tts

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

private const val TAG = "SafeTts"

/** Khoảng tốc độ đọc cho phép (P3 mục 4.8: 0.9x-1.2x) — kẹp ở native như lớp phòng thủ thứ hai. */
private const val MIN_SPEECH_RATE = 0.9
private const val MAX_SPEECH_RATE = 1.2

/**
 * Engine TTS AN TOÀN (P1F) — toàn bộ việc phát âm thanh của app đi qua đây.
 *
 * Vì sao phải tự phát PCM thay vì để TTS tự phát:
 * - `TextToSpeech.speak()` tự chọn route của hệ điều hành; khi không còn tai nghe, Android chuyển
 *   route media về **loa ngoài** ⇒ tiếng TTS lọt ra ngoài. Đó là rủi ro phá hỏng cả app.
 * - Cách làm ở đây: `synthesizeToFile` (chỉ TỔNG HỢP ra file, KHÔNG phát) → đọc PCM → tự phát bằng
 *   `AudioTrack` đã `setPreferredDevice(<tai nghe đang kết nối>)`. Không có tai nghe ⇒ không tạo
 *   `AudioTrack` ⇒ **không thể** phát gì.
 *
 * RÀNG BUỘC đã tuân thủ (`.project/overview.md` mục 3, `.project/architecture.md`):
 * - KHÔNG dùng `AudioAttributes.USAGE_VOICE_COMMUNICATION`/`voiceCommunicationSignalling` (kéo hệ
 *   thống sang HFP/SCO và hạ chất lượng audio). Ở đây `USAGE_MEDIA` + `CONTENT_TYPE_SPEECH`.
 * - KHÔNG dùng `AudioManager.setCommunicationDevice()` (API 31+): API đó chỉ có tác dụng với
 *   use-case đàm thoại ⇒ lại kéo về HFP/SCO.
 * - Mọi nhánh lỗi dẫn tới **không phát gì** (fail-safe), không "thử phát cho chắc".
 *
 * Trạng thái thiết bị **luôn đọc tươi** từ `AudioManager.getDevices()` ngay tại thời điểm quyết
 * định phát, không cache. `AudioDeviceCallback` chỉ dùng để BIẾT lúc nào phải dừng ngay.
 */
class SafeTtsEngine(
    context: Context,
    private val onEvent: (type: String, payload: Map<String, Any?>) -> Unit,
) : AudioDeviceCallback() {

    private val appContext: Context = context.applicationContext
    private val audioManager: AudioManager =
        appContext.getSystemService(AudioManager::class.java)

    /** Thread riêng cho việc block: đọc file WAV + ghi vào `AudioTrack`. */
    private val player: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "safe-tts-player")
    }

    /**
     * "Thế hệ" của mỗi lần phát, tăng mỗi khi `stop()` hoặc mất tai nghe.
     *
     * Callback `onDone` của TTS chỉ được phép PHÁT nếu thế hệ còn khớp: nếu không, một file tổng
     * hợp xong **sau** khi tai nghe đã bị rút sẽ bị phát ra loa ngoài — đúng mẫu lỗi race đã ghi
     * trong `LESSONS_LEARNED.md` (A33/K23).
     */
    private val generation = AtomicInteger(0)

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var ttsInitFailed = false
    private var listenerInstalled = false

    /** File WAV tạm của lần tổng hợp hiện tại (luôn bị xoá khi dừng/xong/lỗi). */
    private var tempWav: File? = null

    /** `AudioTrack` đang phát; `null` = không có gì đang phát. */
    private var track: AudioTrack? = null

    /**
     * Khoá chung giữa đường PHÁT (gán `track` + `play()`) và đường DỪNG (tăng thế hệ + `pause()`).
     * Không có khoá này thì lệnh dừng xen đúng giữa `track = ...` và `play()` sẽ bị "mất": code
     * phát vẫn gọi `play()` sau khi đã dừng ⇒ khe hở an toàn rất hẹp nhưng không được phép tồn tại.
     */
    private val playLock = Any()

    /** Đang chờ `synthesizeToFile` trả `onDone`. */
    @Volatile
    private var synthesizing = false

    private val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        appContext.getSystemService(VibratorManager::class.java)?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        appContext.getSystemService(Vibrator::class.java)
    }

    /**
     * Các loại thiết bị được coi là **riêng tư** — phát vào đây không thể lọt ra loa ngoài.
     *
     * Cố ý KHÔNG có `TYPE_BLUETOOTH_SCO` / `TYPE_BLE_SPEAKER` / `TYPE_BUILTIN_SPEAKER`:
     * - `TYPE_BLE_SPEAKER` là loa ⇒ phát vào đó là lọt ra phòng.
     * - SCO là chế độ đàm thoại (HFP) — app này không dùng; nếu một thiết bị CHỈ có SCO thì hướng
     *   an toàn là **không phát**.
     *
     * Hạn chế đã biết: `TYPE_BLUETOOTH_A2DP` không phân biệt được tai nghe với loa Bluetooth (việc
     * chọn thiết bị nào là do người dùng ở Cài đặt Bluetooth). Ghi ở `.project/modules/tts-safety.md`.
     */
    // TYPE_BLE_HEADSET là hằng của API 31 nhưng chỉ là hằng số int — dùng ở đây an toàn.
    @Suppress("InlinedApi")
    private val privateDeviceTypes: Set<Int> = setOf(
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_HEARING_AID,
    )

    /**
     * **Lớp dừng sớm nhất**: `ACTION_AUDIO_BECOMING_NOISY`.
     *
     * Hệ thống bắn broadcast này **trước khi** đổi route (đây là tín hiệu chuẩn của Android cho tình
     * huống rút tai nghe — app nhạc dùng nó để pause). Vì mục tiêu của P1F là "không lọt ra loa dù chỉ
     * một khoảnh khắc", ta dừng ở đây thay vì chờ `AudioDeviceCallback` cập nhật danh sách thiết bị
     * (muộn hơn, sau khi route đã đổi).
     *
     * Cảnh báo nhỏ: một số máy bắn broadcast này cả khi CẮM tai nghe vào. Hướng xử lý vẫn an toàn —
     * dừng phát + vào chế độ im lặng + đòi xác nhận trước lần đọc kế tiếp.
     */
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                return
            }
            Log.w(TAG, "becomingNoisy: thiết bị ra sắp đổi ⇒ dừng phát NGAY")
            val wasActive = stopPlaybackInternal()
            vibrate(VibrationPattern.HEADSET_LOST)
            onEvent(
                "headsetLost",
                mapOf(
                    "wasPlaying" to wasActive,
                    "reason" to "becomingNoisy",
                    "state" to outputState(),
                ),
            )
        }
    }

    /**
     * Theo dõi thiết bị ra/vào theo thời gian thực (không cần quyền Bluetooth, khác ACL broadcast)
     * + đăng ký lớp dừng sớm `becomingNoisy`. Chỉ gọi MỘT lần cho mỗi process.
     */
    fun start() {
        try {
            audioManager.registerAudioDeviceCallback(this, Handler(Looper.getMainLooper()))
        } catch (t: Throwable) {
            Log.e(TAG, "không đăng ký được AudioDeviceCallback", t)
        }
        try {
            val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // App target Android 14+ bắt buộc khai báo exported/not-exported cho receiver đăng ký động.
                appContext.registerReceiver(noisyReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                appContext.registerReceiver(noisyReceiver, filter)
            }
        } catch (t: Throwable) {
            // Lớp này là lớp dừng SỚM; AudioDeviceCallback (đã đăng ký ở trên) vẫn là lớp bảo hiểm.
            Log.e(TAG, "không đăng ký được becomingNoisy receiver", t)
        }
        // Làm ấm engine TTS ngay từ đầu để lần bấm đầu tiên không bị "chưa sẵn sàng".
        ensureTts()
        Log.i(TAG, "đã theo dõi thiết bị audio (output riêng tư: ${privateOutputDevices().size})")
    }

    // ---------------------------------------------------------------- trạng thái thiết bị

    /** Đọc TƯƠI danh sách thiết bị output đang kết nối thuộc nhóm riêng tư. */
    private fun privateOutputDevices(): List<AudioDeviceInfo> {
        val devices = try {
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList()
        } catch (t: Throwable) {
            Log.e(TAG, "không đọc được danh sách thiết bị output", t)
            return emptyList() // Fail-safe: không biết ⇒ coi như không có tai nghe ⇒ không phát.
        }
        return devices.filter { it.type in privateDeviceTypes }
    }

    /**
     * Thiết bị để route tường minh. Ưu tiên A2DP (đúng kịch bản app: tai nghe Bluetooth chỉ phát),
     * rồi tới các loại riêng tư khác. `null` ⇒ tuyệt đối không được phát.
     */
    private fun preferredOutputDevice(): AudioDeviceInfo? {
        val devices = privateOutputDevices()
        return devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP }
            ?: devices.firstOrNull()
    }

    private fun describe(device: AudioDeviceInfo): Map<String, Any?> = mapOf(
        "id" to device.id,
        "type" to device.type,
        "name" to device.productName?.toString(),
        "address" to device.address,
    )

    fun outputState(): Map<String, Any?> {
        val devices = privateOutputDevices()
        val preferred = preferredOutputDevice()
        return mapOf(
            "hasPrivateOutput" to (preferred != null),
            "preferred" to preferred?.let { describe(it) },
            "devices" to devices.map { describe(it) },
        )
    }

    // ---------------------------------------------------------------- callback thiết bị

    override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
        val privates = addedDevices.filter { it.type in privateDeviceTypes }
        if (privates.isEmpty()) {
            return
        }
        Log.i(TAG, "thiết bị riêng tư được thêm: ${privates.joinToString { it.type.toString() }}")
        onEvent("headsetFound", mapOf("state" to outputState()))
    }

    override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
        val privates = removedDevices.filter { it.type in privateDeviceTypes }
        if (privates.isEmpty()) {
            return
        }
        Log.w(TAG, "MẤT thiết bị riêng tư: ${privates.joinToString { it.type.toString() }}")
        // Dừng NGAY (kể cả đang phát — đây chính là khoảnh khắc Android có thể đổi route về loa
        // ngoài), rồi rung 2 nhịp báo "đang chuyển chế độ im lặng".
        val wasActive = stopPlaybackInternal()
        vibrate(VibrationPattern.HEADSET_LOST)
        onEvent(
            "headsetLost",
            mapOf(
                "wasPlaying" to wasActive,
                "state" to outputState(),
            ),
        )
    }

    // ---------------------------------------------------------------- phát TTS

    /**
     * Kết quả trả về Dart:
     * - `"noHeadset"` — không phát, đã rung báo (chuyển sang nudge chữ).
     * - `"synthesizing"` — đã bắt đầu tổng hợp; phát xong sẽ báo qua event `spoke`.
     * - `"error:<mô tả>"` — không phát gì.
     *
     * [rate] — tốc độ đọc (P3 mục 4.8). `null` ⇒ **không đụng** tới tốc độ (engine giữ giá trị đã đặt
     * ở lần trước, hoặc mặc định của engine nếu chưa từng đặt — `setSpeechRate` là cấu hình dính).
     * Giá trị ngoài khoảng bị kẹp. Đây chỉ là tham số chất lượng, **không** phải điều kiện an toàn,
     * nên không được phép làm hỏng việc phát (khác hẳn mọi nhánh fail-safe khác trong file này).
     *
     * Luôn gọi trên main thread (handler của MethodChannel).
     */
    fun speak(text: String, rate: Double?): String {
        if (text.isBlank()) {
            return "error:text rỗng"
        }

        // 1) Kiểm tra thiết bị NGAY LÚC NÀY (không dùng trạng thái cache).
        val device = preferredOutputDevice()
        if (device == null) {
            Log.w(TAG, "không có tai nghe ⇒ KHÔNG phát TTS, chuyển nudge chữ + rung")
            vibrate(VibrationPattern.SILENT_FALLBACK)
            return "noHeadset"
        }

        // 2) Engine phải đã sẵn sàng. Chưa sẵn sàng ⇒ KHÔNG phát (không đoán mò).
        if (!ttsReady) {
            ensureTts()
        }
        val engine = tts
        if (!ttsReady || engine == null) {
            Log.w(TAG, "TTS chưa sẵn sàng (initFailed=$ttsInitFailed) ⇒ KHÔNG phát")
            return "error:TTS chưa sẵn sàng, thử lại sau 1-2 giây"
        }

        // 3) Tốc độ đọc: đặt NGAY TRƯỚC khi tổng hợp (setSpeechRate là cấu hình của engine, áp cho
        //    cả `synthesizeToFile`). Kẹp về khoảng hợp lệ để một giá trị lạ từ Dart không tạo ra
        //    giọng đọc không hiểu được; lỗi ở đây chỉ log, KHÔNG chặn phát.
        if (rate != null && rate.isFinite()) {
            val clamped = rate.coerceIn(MIN_SPEECH_RATE, MAX_SPEECH_RATE)
            try {
                engine.setSpeechRate(clamped.toFloat())
                Log.i(TAG, "tốc độ đọc: $clamped")
            } catch (t: Throwable) {
                Log.w(TAG, "không đặt được tốc độ đọc (${t.message}) — dùng tốc độ mặc định")
            }
        }

        // 4) Chốt thế hệ để file tổng hợp xong muộn không bị phát oan.
        val gen = generation.incrementAndGet()
        stopPlaybackInternal(keepGeneration = true)
        synthesizing = true

        // Đường dẫn/tên file do `wavFor` quyết định (một nguồn duy nhất): `playSynthesized` và
        // `cleanTempOfGeneration` dựng lại file từ số thế hệ nên hai chỗ phải khớp nhau tuyệt đối.
        File(appContext.cacheDir, "tts").mkdirs()
        val wav = wavFor(gen)
        wav.delete()
        tempWav = wav

        val code = engine.synthesizeToFile(text, Bundle(), wav, "safe-tts-$gen")
        if (code != TextToSpeech.SUCCESS) {
            Log.e(TAG, "synthesizeToFile thất bại: code=$code")
            synthesizing = false
            cleanTemp(wav)
            return "error:synthesizeToFile code=$code"
        }
        Log.i(TAG, "đã yêu cầu tổng hợp (gen=$gen, device=${device.type})")
        return "synthesizing"
    }

    /**
     * Khởi tạo `TextToSpeech` (idempotent, gọi trên main thread). Trả `false` nếu engine không dùng
     * được ⇒ không phát. Thiếu giọng vi-VN **không** phải vấn đề an toàn nên chỉ log.
     */
    private fun ensureTts(): Boolean {
        if (ttsReady || ttsInitFailed) {
            return ttsReady
        }
        val created = TextToSpeech(
            appContext,
            object : TextToSpeech.OnInitListener {
                override fun onInit(status: Int) {
                    if (status != TextToSpeech.SUCCESS) {
                        ttsInitFailed = true
                        Log.e(TAG, "khởi tạo TTS thất bại: status=$status")
                        return
                    }
                    ttsReady = true
                    installListener()
                }
            },
        )
        tts = created
        // `onInit` có thể chạy ngay trong lúc khởi tạo (khi đó field `tts` còn null) — gọi lại ở đây
        // để chắc chắn listener được gắn.
        if (ttsReady) {
            installListener()
        }
        return ttsReady
    }

    private fun installListener() {
        if (listenerInstalled) {
            return
        }
        val engine = tts ?: return
        listenerInstalled = true
        val lang = engine.setLanguage(Locale("vi", "VN"))
        if (lang == TextToSpeech.LANG_MISSING_DATA || lang == TextToSpeech.LANG_NOT_SUPPORTED) {
            Log.w(TAG, "máy thiếu giọng vi-VN (code=$lang) — dùng giọng mặc định của engine")
        }
        engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) = Unit

            override fun onDone(utteranceId: String?) {
                val gen = generation.get()
                if (!synthesizing || gen != generationFromId(utteranceId)) {
                    Log.w(TAG, "bỏ qua file tổng hợp cũ/muộn (gen=$gen, utterance=$utteranceId)")
                    return
                }
                synthesizing = false
                playSynthesized(gen)
            }

            override fun onError(utteranceId: String?) =
                handleSynthesisFailure(utteranceId, errorCode = null)

            override fun onError(utteranceId: String?, errorCode: Int) =
                handleSynthesisFailure(utteranceId, errorCode = errorCode)

            override fun onStop(utteranceId: String?, interrupted: Boolean) {
                // Thế hệ CŨ bị dừng là **hệ quả mong đợi** của việc `speak()` mới gọi `engine.stop()`
                // (xem `stopPlaybackInternal`), nên không được đụng vào cờ dùng chung: nếu đặt
                // `synthesizing = false` ở đây thì `onDone` của thế hệ MỚI sẽ bị bỏ qua và câu mới
                // **im lặng** (cùng họ K45 — nợ A54).
                if (!isCurrentGeneration(utteranceId)) {
                    return
                }
                Log.w(TAG, "TTS bị dừng giữa chừng (interrupted=$interrupted)")
                synthesizing = false
            }
        })
    }

    private fun generationFromId(utteranceId: String?): Int =
        utteranceId?.substringAfterLast('-')?.toIntOrNull() ?: -1

    /** File WAV của một thế hệ — dựng lại theo tên, KHÔNG đọc field dùng chung [tempWav]. */
    private fun wavFor(gen: Int): File = File(File(appContext.cacheDir, "tts"), "tts_$gen.wav")

    /**
     * Callback của TTS engine có thể tới **muộn**, sau khi `speak()` mới đã chạy. Chỉ được để chúng
     * tác động lên state DÙNG CHUNG khi thuộc **thế hệ đang chạy**; nếu không:
     *  - (a) `synthesizing = false` của thế hệ cũ làm `onDone` của câu MỚI bị bỏ qua ⇒ **câu mới im
     *    lặng** — đúng triệu chứng K45, ở một call-site thứ ba;
     *  - (b) `onEvent("error")` của thế hệ cũ báo về Dart ⇒ `SafeTtsOutput` gọi `_setSpeaking(false)`
     *    ⇒ **mở lại cửa ASR trong lúc TTS đang đọc** (vi phạm half-duplex, DoD 2 của P4) kèm thông
     *    báo "Lỗi đọc TTS" sai.
     * `utteranceId` không đọc được (`-1`) thì coi như thuộc thế hệ hiện tại (hướng an toàn).
     */
    private fun isCurrentGeneration(utteranceId: String?): Boolean {
        val gen = generationFromId(utteranceId)
        val current = generation.get()
        if (gen < 0 || gen == current) {
            return true
        }
        Log.w(TAG, "bỏ qua callback của thế hệ CŨ (gen=$gen, hiện tại=$current)")
        return false
    }

    /**
     * Lỗi tổng hợp: **luôn** dọn file của thế hệ bị lỗi, nhưng **chỉ** thế hệ đang chạy mới được đổi
     * cờ trạng thái và báo `error` về Dart (xem [isCurrentGeneration] để biết vì sao).
     */
    private fun handleSynthesisFailure(utteranceId: String?, errorCode: Int?) {
        val isCurrent = isCurrentGeneration(utteranceId)
        cleanTempOfGeneration(utteranceId)
        if (!isCurrent) {
            return
        }
        synthesizing = false
        val suffix = if (errorCode != null) " (code=$errorCode)" else ""
        Log.e(TAG, "TTS báo lỗi khi tổng hợp (utterance=$utteranceId$suffix)")
        onEvent("error", mapOf("message" to "TTS tổng hợp lỗi$suffix"))
    }

    /**
     * Xoá file tạm của **thế hệ mà callback thuộc về** (suy từ `utteranceId`), không phải của thế hệ
     * đang chạy. Callback của thế hệ cũ có thể tới SAU khi `speak()` mới đã dựng file mới ⇒ xoá theo
     * field dùng chung sẽ làm câu mới im lặng (nợ K45, bài học A54).
     */
    private fun cleanTempOfGeneration(utteranceId: String?) {
        val gen = generationFromId(utteranceId)
        if (gen >= 0) {
            cleanTemp(wavFor(gen))
        } else {
            cleanTemp()
        }
    }

    /**
     * Đọc WAV đã tổng hợp và tự phát bằng `AudioTrack` route tường minh tới tai nghe.
     *
     * Chạy trên thread riêng (đọc file + `write` blocking). Trước khi tạo `AudioTrack`, kiểm tra lại
     * thiết bị **một lần nữa** — giữa lúc tổng hợp và lúc phát, tai nghe có thể đã bị rút.
     */
    private fun playSynthesized(gen: Int) {
        // File suy từ số thế hệ, KHÔNG đọc field dùng chung `tempWav`: lúc này `speak()` mới có thể
        // đã trỏ field sang file khác, và `finally` bên dưới sẽ xoá nhầm file của câu mới (K45/A54).
        val wav = wavFor(gen)
        player.execute {
            try {
                if (gen != generation.get()) {
                    Log.w(TAG, "bỏ qua phát: thế hệ đã đổi (gen=$gen)")
                    return@execute
                }
                if (!wav.exists()) {
                    Log.e(TAG, "không có file WAV để phát")
                    return@execute
                }
                val device = preferredOutputDevice()
                if (device == null) {
                    Log.w(TAG, "tai nghe đã mất trước khi phát ⇒ KHÔNG phát")
                    return@execute
                }

                val pcm = WavData.read(wav)
                val channelMask = if (pcm.channels == 1) {
                    AudioFormat.CHANNEL_OUT_MONO
                } else {
                    AudioFormat.CHANNEL_OUT_STEREO
                }
                val encoding = if (pcm.bitsPerSample == 8) {
                    AudioFormat.ENCODING_PCM_8BIT
                } else {
                    AudioFormat.ENCODING_PCM_16BIT
                }
                val minBuffer = AudioTrack.getMinBufferSize(pcm.sampleRate, channelMask, encoding)
                if (minBuffer <= 0) {
                    Log.e(TAG, "getMinBufferSize trả $minBuffer ⇒ không phát")
                    return@execute
                }

                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA) // KHÔNG dùng USAGE_VOICE_COMMUNICATION
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
                val format = AudioFormat.Builder()
                    .setSampleRate(pcm.sampleRate)
                    .setEncoding(encoding)
                    .setChannelMask(channelMask)
                    .build()

                val newTrack = AudioTrack.Builder()
                    .setAudioAttributes(attrs)
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(maxOf(minBuffer, pcm.data.size))
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()

                // Route tường minh. `setPreferredDevice` trả false ⇒ KHÔNG phát (fail-safe).
                if (!newTrack.setPreferredDevice(device)) {
                    Log.e(TAG, "setPreferredDevice bị từ chối ⇒ KHÔNG phát")
                    newTrack.release()
                    return@execute
                }
                synchronized(playLock) {
                    if (gen != generation.get()) {
                        Log.w(TAG, "thế hệ đổi trong lúc chuẩn bị phát ⇒ KHÔNG phát")
                        newTrack.release()
                        return@execute
                    }
                    track = newTrack
                    newTrack.play()
                }
                var offset = 0
                while (offset < pcm.data.size && gen == generation.get()) {
                    val written = newTrack.write(pcm.data, offset, pcm.data.size - offset)
                    if (written <= 0) {
                        Log.w(TAG, "AudioTrack.write trả $written — dừng phát")
                        break
                    }
                    offset += written
                }

                // `write()` blocking chỉ đảm bảo dữ liệu đã được ENQUEUE vào buffer, **không** phải đã
                // phát ra loa (tài liệu Android). Nếu release ngay, `flush()` trong `releaseTrack()` sẽ
                // vứt toàn bộ phần chưa phát — "discard audio data that hasn't been played back yet" —
                // tức là câu TTS gần như không nghe được gì. Vì vậy phải CHỜ đầu phát đi hết số frame
                // đã ghi, và vẫn kiểm `gen` mỗi 20ms để lúc mất tai nghe thì dừng tức thì.
                val bytesPerFrame = (pcm.bitsPerSample / 8) * pcm.channels
                val framesWritten = if (bytesPerFrame > 0) offset / bytesPerFrame else 0
                val durationMs =
                    if (pcm.sampleRate > 0) framesWritten * 1000L / pcm.sampleRate else 0L
                val deadline = System.currentTimeMillis() + durationMs + 2000L
                while (gen == generation.get() && newTrack.playbackHeadPosition < framesWritten) {
                    if (System.currentTimeMillis() > deadline) {
                        Log.w(TAG, "chờ phát xong quá hạn (${durationMs}ms) — dừng chờ")
                        break
                    }
                    try {
                        Thread.sleep(20)
                    } catch (interrupted: InterruptedException) {
                        Thread.currentThread().interrupt()
                        break
                    }
                }
                Log.i(TAG, "đã phát ${offset}/${pcm.data.size} byte (gen=$gen)")
                if (gen == generation.get()) {
                    onEvent("spoke", mapOf("bytes" to offset))
                }
            } catch (t: Throwable) {
                Log.e(TAG, "lỗi khi phát TTS tổng hợp", t)
                onEvent("error", mapOf("message" to (t.message ?: "lỗi không xác định khi phát")))
            } finally {
                releaseTrack()
                cleanTemp(wav) // file của CHÍNH lần chạy này, không phải `tempWav` hiện tại
            }
        }
    }

    /** Dừng mọi thứ đang phát/tổng hợp. Trả `true` nếu thực sự có gì đó đang phát/tổng hợp. */
    fun stop(): Boolean = stopPlaybackInternal()

    private fun stopPlaybackInternal(keepGeneration: Boolean = false): Boolean {
        val wasActive: Boolean
        synchronized(playLock) {
            wasActive = track != null || synthesizing
            if (!keepGeneration) {
                generation.incrementAndGet()
            }
            synthesizing = false
            // CHỈ `pause()` ở đây: nó tắt tiếng ngay lập tức và gọi được từ BẤT KỲ thread nào.
            // Việc `flush()/stop()/release()` để chính thread phát làm trong `finally` — tránh việc
            // release AudioTrack đúng lúc thread đó đang nằm trong `write()` (dễ ném
            // IllegalStateException, làm log rối và khó phân biệt với lỗi thật khi đo trên máy).
            val current = track
            if (current != null) {
                try {
                    current.pause()
                } catch (t: Throwable) {
                    Log.w(TAG, "pause AudioTrack lỗi: ${t.message}")
                }
            }
        }
        val engine = tts
        if (engine != null) {
            try {
                engine.stop()
            } catch (t: Throwable) {
                Log.w(TAG, "TTS stop lỗi: ${t.message}")
            }
        }
        cleanTemp()
        if (wasActive) {
            Log.w(TAG, "đã DỪNG phát TTS")
        }
        return wasActive
    }

    /**
     * Giải phóng `AudioTrack`. **Chỉ** gọi từ chính thread phát (`finally` của `playSynthesized`) —
     * đường dừng (`stopPlaybackInternal`) cố ý chỉ `pause()` để không release track trong lúc thread
     * phát còn đang nàm trong `write()`.
     */
    private fun releaseTrack() {
        val current = track
        track = null
        if (current != null) {
            try {
                current.pause()
                current.flush()
                current.stop()
            } catch (t: Throwable) {
                Log.w(TAG, "dừng AudioTrack lỗi: ${t.message}")
            }
            try {
                current.release()
            } catch (t: Throwable) {
                Log.w(TAG, "release AudioTrack lỗi: ${t.message}")
            }
        }
    }

    /**
     * Xoá file WAV tạm của **chính lần chạy đang gọi** (truyền [file] cục bộ của lần chạy đó).
     *
     * KHÔNG đọc lại field dùng chung [tempWav] để quyết định xoá gì: một `speak()` mới có thể đã
     * ghi `tempWav` sang file của thế hệ MỚI trong lúc thread của lần chạy cũ còn đang thoát ra ⇒
     * lần cũ xoá mất file của câu mới và câu mới **im lặng** (nợ K45, bài học A54). Field chỉ bị
     * null khi nó **vẫn đang trỏ vào đúng file** mà lần chạy này sở hữu.
     *
     * So sánh bằng `==` (so **đường dẫn**), KHÔNG phải `===`: các call-site (`playSynthesized`,
     * `cleanTempOfGeneration`) dựng lại `File` từ số thế hệ nên đối tượng khác nhau nhưng cùng
     * đường dẫn — dùng `===` sẽ bỏ sót và để field trỏ vào file đã xoá.
     */
    private fun cleanTemp(file: File? = tempWav) {
        if (file != null && tempWav == file) {
            tempWav = null
        }
        if (file != null && file.exists() && !file.delete()) {
            Log.w(TAG, "không xoá được file tạm ${file.name}")
        }
    }

    // ---------------------------------------------------------------- rung

    private enum class VibrationPattern { SILENT_FALLBACK, HEADSET_LOST }

    /**
     * Rung báo hiệu. Cố ý 2 nhịp KHÁC NHAU để phân biệt được bằng cảm giác:
     * - `SILENT_FALLBACK`: 1 nhịp ngắn — "không có tai nghe nên không đọc được".
     * - `HEADSET_LOST`: 2 nhịp — "tai nghe vừa mất, đang chuyển sang chế độ im lặng".
     */
    private fun vibrate(pattern: VibrationPattern) {
        val vib = vibrator
        if (vib == null) {
            Log.w(TAG, "máy không có Vibrator — bỏ qua rung")
            return
        }
        val effect = when (pattern) {
            VibrationPattern.SILENT_FALLBACK ->
                VibrationEffect.createOneShot(90, VibrationEffect.DEFAULT_AMPLITUDE)
            VibrationPattern.HEADSET_LOST ->
                VibrationEffect.createWaveform(longArrayOf(0, 120, 90, 120), -1)
        }
        try {
            vib.vibrate(effect)
            Log.i(TAG, "đã rung: $pattern")
        } catch (t: Throwable) {
            Log.w(TAG, "rung lỗi: ${t.message}")
        }
    }

    /**
     * Rung 1 nhịp "không đọc được vì không có tai nghe".
     *
     * Cần đường gọi riêng vì lớp Dart tự phát hiện mất tai nghe rồi **không** gọi `speak` (task 1
     * của prompt P1F) — khi đó native không có cơ hội tự rung.
     */
    fun vibrateFallback() = vibrate(VibrationPattern.SILENT_FALLBACK)
}

/** PCM thô đọc từ file WAV do TTS sinh ra. */
internal class WavData(
    val sampleRate: Int,
    val channels: Int,
    val bitsPerSample: Int,
    val data: ByteArray,
) {
    companion object {
        /**
         * Đọc PCM từ file WAV (RIFF). Chỉ chấp nhận PCM không nén (`audioFormat == 1`).
         * Ném `IllegalArgumentException` nếu file không đúng dạng ⇒ nhánh gọi sẽ KHÔNG phát.
         */
        fun read(file: File): WavData {
            val bytes = file.readBytes()
            if (bytes.size < 44) {
                throw IllegalArgumentException("file WAV quá ngắn")
            }
            if (text(bytes, 0) != "RIFF" || text(bytes, 8) != "WAVE") {
                throw IllegalArgumentException("không phải file RIFF/WAVE")
            }
            var pos = 12
            var sampleRate = 0
            var channels = 0
            var bits = 0
            var audioFormat = 0
            var payload: ByteArray? = null
            while (pos + 8 <= bytes.size) {
                val id = text(bytes, pos)
                val size = le32(bytes, pos + 4)
                if (size < 0) {
                    throw IllegalArgumentException("kích thước chunk âm")
                }
                val body = pos + 8
                if (id == "fmt " && body + 16 <= bytes.size) {
                    audioFormat = le16(bytes, body)
                    channels = le16(bytes, body + 2)
                    sampleRate = le32(bytes, body + 4)
                    bits = le16(bytes, body + 14)
                } else if (id == "data") {
                    payload = bytes.copyOfRange(body, minOf(body + size, bytes.size))
                    break
                }
                // Chunk lẻ được đệm 1 byte cho chẵn.
                pos = body + size + (size % 2)
            }
            val pcm = payload ?: throw IllegalArgumentException("WAV không có chunk data")
            if (audioFormat != 1) {
                throw IllegalArgumentException("WAV không phải PCM (format=$audioFormat)")
            }
            if (sampleRate <= 0 || bits <= 0) {
                throw IllegalArgumentException("header WAV thiếu thông tin")
            }
            return WavData(sampleRate, maxOf(channels, 1), bits, pcm)
        }

        private fun text(bytes: ByteArray, offset: Int): String =
            String(bytes, offset, 4, Charsets.US_ASCII)

        private fun le16(bytes: ByteArray, index: Int): Int =
            (bytes[index].toInt() and 0xFF) or ((bytes[index + 1].toInt() and 0xFF) shl 8)

        private fun le32(bytes: ByteArray, index: Int): Int =
            (bytes[index].toInt() and 0xFF) or
                ((bytes[index + 1].toInt() and 0xFF) shl 8) or
                ((bytes[index + 2].toInt() and 0xFF) shl 16) or
                ((bytes[index + 3].toInt() and 0xFF) shl 24)
    }
}

/**
 * Đăng ký kênh TTS `com.aiassistant.phone/tts` cho một FlutterEngine.
 *
 * Hợp đồng (khớp `TtsChannels`/`NativeTtsClient` phía Dart):
 * - Dart→native: `outputState` · `speak {text, rate?}` · `stop` · `vibrateFallback`.
 * - native→Dart: method `event` {type, ...} với `type` ∈
 *   `headsetFound` · `headsetLost` · `spoke` · `error`.
 *
 * Engine là singleton của cả process (1 `TextToSpeech` + 1 `AudioTrack`), giống `AsrChannelBridge`.
 * Sự kiện native→Dart đi qua **messenger đăng ký đầu tiên** (engine UI): ở P1F chỉ UI phát TTS. Khi
 * P3/P4 cần phát từ isolate của service thì phải đổi cách chọn messenger (đã ghi ở `.project/`).
 */
object SafeTtsChannelBridge {
    const val TTS_CHANNEL = "com.aiassistant.phone/tts"

    private val registered = mutableSetOf<BinaryMessenger>()
    private var engine: SafeTtsEngine? = null
    private var eventMessenger: BinaryMessenger? = null

    @Synchronized
    fun register(messenger: BinaryMessenger, context: Context) {
        if (!registered.add(messenger)) {
            Log.w(TAG, "kênh TTS đã đăng ký cho messenger này — bỏ qua")
            return
        }
        val appContext = context.applicationContext
        if (eventMessenger == null) {
            eventMessenger = messenger
        }
        if (engine == null) {
            engine = SafeTtsEngine(appContext) { type, payload ->
                val message = HashMap<String, Any?>(payload)
                message["type"] = type
                mainInvoke { eventMessenger?.let { MethodChannel(it, TTS_CHANNEL).invokeMethod("event", message) } }
            }.also { it.start() }
        }
        val channel = MethodChannel(messenger, TTS_CHANNEL)
        channel.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            val current = engine
            if (current == null) {
                result.error("TTS_UNAVAILABLE", "engine TTS chưa sẵn sàng", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "outputState" -> result.success(current.outputState())
                    "speak" -> {
                        val text = call.argument<String>("text") ?: ""
                        // Khoá `rate` là TUỲ CHỌN (P3): thiếu ⇒ giữ tốc độ đang đặt của engine.
                        // Đọc qua `Number` thay vì `Double`: nếu phía Dart lỡ gửi số nguyên (1 thay vì
                        // 1.0) thì `argument<Double>` sẽ ném ClassCastException ⇒ Dart coi như lỗi
                        // kênh ⇒ **không đọc được gì cả**. Sai kiểu một tham số chất lượng không đáng
                        // đánh đổi cả việc đọc.
                        val rate = (call.argument<Any>("rate") as? Number)?.toDouble()
                        result.success(current.speak(text, rate))
                    }
                    "stop" -> result.success(current.stop())
                    "vibrateFallback" -> {
                        current.vibrateFallback()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                // Fail-safe: lỗi ở đây ⇒ Dart coi như không phát được, tuyệt đối không thử phát lại.
                Log.e(TAG, "lỗi xử lý ${call.method}", t)
                result.error("TTS_FAILED", t.message, t.javaClass.simpleName)
            }
        }
        Log.i(TAG, "đã đăng ký kênh TTS")
    }

    /** Gỡ handler kênh TTS của một engine (đối xứng với lúc đăng ký — bài học F1 của P1B). */
    @Synchronized
    fun unregister(messenger: BinaryMessenger) {
        if (registered.remove(messenger)) {
            MethodChannel(messenger, TTS_CHANNEL).setMethodCallHandler(null)
            if (eventMessenger === messenger) {
                eventMessenger = null
            }
            Log.i(TAG, "đã gỡ kênh TTS cho engine")
        }
    }

    private fun mainInvoke(invoke: () -> Unit) {
        Handler(Looper.getMainLooper()).post(invoke)
    }
}
