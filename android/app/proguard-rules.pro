# ═══════════════════════════════════════════════════════════════════════════
# R8/ProGuard cho bản release (P7 mục 5). Bật cùng `isMinifyEnabled = true`
# trong build.gradle.kts — file này KHÔNG có tác dụng ở bản debug.
#
# Nguyên tắc: chỉ giữ những gì reflection/JNI thật sự cần. Mọi keep rule ở đây
# phải có lý do ghi ngay cạnh — rule tràn lan = mất cả tác dụng minify.
# ═══════════════════════════════════════════════════════════════════════════

# ── JNA (net.java.dev.jna:jna:5.18.1@aar — dependency của vosk-android) ──────
# JNA map interface Java ↔ native bằng reflection (Structure/Library mapping),
# nên nếu minify mà không giữ lại các class này thì app crash ngay lần gọi
# native đầu tiên (UnsatisfiedLinkError / ClassNotFoundException) — lỗi CHỈ lộ
# ở bản release, không lộ ở debug. Nguồn: hướng dẫn chính thức của
# vosk_flutter_service (cùng dùng vosk-android):
# https://pub.dev/packages/vosk_flutter_service
-keep class com.sun.jna.* { *; }
-keepclassmembers class * extends com.sun.jna.* { public *; }

# JNA có sẵn lớp tích hợp desktop (`Native$AWT`) tham chiếu `java.awt.*` — package KHÔNG tồn tại
# trên Android (chỉ Java SE). Đường code này là dead code thực sự trên Android: không thể được
# thực thi, chỉ là tham chiếu nằm trong AAR. Đây là CA DUY NHẤT được phép -dontwarn ở repo này
# (CI run 35821096343: `Missing class java.awt.{Component,GraphicsEnvironment,HeadlessException,
# Window}` — tất cả đều từ Native$AWT, không phải từ code của app). KHÔNG thêm -dontwarn khác.
-dontwarn java.awt.**

# ── vosk-android 0.3.75 (AAR chính chủ, package org.vosk — đã xác minh bằng
#    import thật trong VoskChannelBridge.kt: LibVosk/LogLevel/Model/Recognizer,
#    KHÔNG phải org.kaldi của bản AAR cũ) ────────────────────────────────────
# Model/Recognizer là Structure/Library của JNA: JNA đọc field + sinh proxy qua
# reflection trên chính các class này, nên keep toàn bộ org.vosk.** (lib nhỏ,
# chi phí size không đáng kể so với rủi ro native im lặng hỏng).
-keep class org.vosk.** { *; }

# ── JNI wrapper của whisper.cpp (AsrChannelBridge.kt > object AsrNative) ────
# `external fun` được JVM resolve theo TÊN class + tên hàm + chữ ký. Class này
# là entry point của System.loadLibrary("ai_assistant_jni") — nếu R8 đổi tên/
# xoá thì UnsatisfiedLinkError ngay lần loadModel đầu tiên. Đã kiểm bằng grep:
# đây là object JNI DUY NHẤT trong repo (native fun nằm ở lớp Kotlin riêng,
# các bridge MethodChannel gọi qua nó, không tự khai external fun).
-keep class com.aiassistant.phone.asr.AsrNative { *; }

# ── Không cần keep thêm ─────────────────────────────────────────────────────
# - flutter_foreground_task / flutter_secure_storage / sqflite /
#   permission_handler: không dùng reflection lên class của app (plugin tự có
#   consumer rules); ListeningTaskHandler được dựng từ Dart callback, không qua
#   reflection Android.
# - Bridge MethodChannel (SafeTts/Capture/Asr/Vosk): gọi trực tiếp, không
#   reflection → R8 tự tối ưu được.
# Nếu CI báo "Missing class" khi bật R8: thêm -dontwarn cho đúng class đó kèm
# lý do, KHÔNG thêm -dontwarn tràn lan để "cho qua".
