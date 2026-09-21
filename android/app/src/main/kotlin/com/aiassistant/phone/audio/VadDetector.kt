package com.aiassistant.phone.audio

import android.util.Log
import com.konovalov.vad.webrtc.VadWebRTC
import com.konovalov.vad.webrtc.config.FrameSize
import com.konovalov.vad.webrtc.config.Mode
import com.konovalov.vad.webrtc.config.SampleRate

private const val TAG = "VadDetector"

/** Sample rate VAD cố định của repo (16kHz, trùng capture) — dùng để suy frameMs. */
private const val SAMPLE_RATE_HZ = 16000

/**
 * Kết quả VAD cho một buffer PCM (đã chia thành các khung VAD).
 *
 * F3: `frameMs` do [VadDetector] tính từ cấu hình **thật** rồi mang theo trong kết quả — Dart
 * tính `durationMs = totalFrames * frameMs` từ giá trị này, không còn hằng số chép tay ở bridge.
 */
data class VadResult(
  val speechFrames: Int,
  val totalFrames: Int,
  val frameMs: Int,
) {
  /** Tỉ lệ khung được coi là có tiếng nói trong buffer này (0.0–1.0). */
  val speechRatio: Double get() = if (totalFrames == 0) 0.0 else speechFrames.toDouble() / totalFrames
}

/**
 * VAD chạy on-device bằng **WebRTC VAD (GMM)** — bản nhẹ nhất đủ dùng (158KB, không model, không
 * ONNX runtime). Quyết định ở P1B: chọn WebRTC thay vì Silero vì mục tiêu chỉ là "có tiếng nói sát
 * mic hay không" để tránh AI chen ngang, không cần độ chính xác ngữ nghĩa (đúng gợi ý kỹ thuật của
 * `prompt_P1B.md`: chọn phương án nhẹ nhất đủ dùng trước).

 * Hợp đồng quan trọng:
 * - **KHÔNG** phân biệt người nói (không diarization) — ràng buộc của phase: chỉ biết "có tiếng nói
 *   gần mic hay không".
 * - WebRTC VAD chỉ nhận PCM16 mono và **chỉ** các cặp (sampleRate, frameSize) hợp lệ; ở 16kHz dùng
 *   320 mẫu/khung = **20ms** (`FrameSize.FRAME_SIZE_320`). Buffer dài hơn sẽ được chia nhỏ.
 * - `isSpeech` của thư viện **phải** nhận đúng `frameSize` mẫu; truyền sai độ dài là lỗi lập trình.
 *
 * Thread-safety: `analyze` chỉ được gọi từ **một** thread (thread đọc capture) — thư viện không
 * được thiết kế cho gọi song song.
 */
class VadDetector(
  private val frameSize: FrameSize = FrameSize.FRAME_SIZE_320,
  private val mode: Mode = Mode.VERY_AGGRESSIVE,
) : AutoCloseable {

  private val frameBytes: Int = frameSize.value * 2 // PCM16 -> 2 byte/mẫu

  /** F3: độ dài khung ms suy từ cấu hình thật (320 mẫu @ 16kHz = 20ms) — nguồn duy nhất. */
  val frameMs: Int get() = frameSize.value * 1000 / SAMPLE_RATE_HZ

  private val vad: VadWebRTC = VadWebRTC(
    sampleRate = SampleRate.SAMPLE_RATE_16K,
    frameSize = frameSize,
    mode = mode,
    // Để 0: thư viện trả kết quả THÔ cho từng khung, còn việc gộp theo thời gian (attack/release)
    // do tầng state machine ở Dart quyết định — tránh hai lớp smoothing chồng nhau khó tinh chỉnh.
    speechDurationMs = 0,
    silenceDurationMs = 0,
  )

  /** Số byte mỗi khung VAD (640 byte ở cấu hình 16kHz / 320 mẫu). */
  val frameByteSize: Int get() = frameBytes

  /**
   * Phân tích một buffer PCM16 bất kỳ độ dài.
   *
   * Phần dư không đủ một khung (length % frameBytes != 0) **bị bỏ** cho lần này — khung đầy đủ
   * mới đáng tin với WebRTC VAD; trạng thái dư không được giữ lại giữa các lần gọi (buffer đọc từ
   * `AudioRecord` với cùng kích thước nên trên thực tế luôn chia hết).
   */
  fun analyze(buffer: ByteArray, length: Int): VadResult {
    val usableLength = length - (length % frameBytes)
    var speechFrames = 0
    var totalFrames = 0
    var offset = 0
    val frame = ByteArray(frameBytes)
    while (offset + frameBytes <= usableLength) {
      System.arraycopy(buffer, offset, frame, 0, frameBytes)
      if (vad.isSpeech(frame)) {
        speechFrames++
      }
      totalFrames++
      offset += frameBytes
    }
    return VadResult(
      speechFrames = speechFrames,
      totalFrames = totalFrames,
      frameMs = frameMs,
    )
  }

  /** Ghi log cấu hình đang dùng (để đối chiếu khi đo trên máy thật) — mode từ chính `this`. */
  fun logConfig() {
    Log.i(TAG, "WebRTC VAD: 16kHz, frame=${frameSize.value} mẫu ($frameBytes byte), mode=$mode")
  }

  override fun close() {
    runCatching { vad.close() }
  }
}
