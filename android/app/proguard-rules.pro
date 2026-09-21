# P1D — Vosk (vosk-android) dùng JNA để gọi libvosk.so.
#
# JNA map interface Java ↔ native bằng reflection (Structure/Interface), nên nếu bật minify mà
# không giữ lại các class này thì app sẽ crash ngay ở lần gọi native đầu tiên (UnsatisfiedLinkError
# / ClassNotFoundException) — lỗi CHỈ lộ ở bản release, không lộ ở debug.
#
# Hiện `isMinifyEnabled` chưa bật nên file này chưa có tác dụng; giữ sẵn để bản release sau không
# vấp lại. Nguồn: hướng dẫn chính thức của vosk_flutter_service (cùng dùng vosk-android):
# https://pub.dev/packages/vosk_flutter_service
-keep class com.sun.jna.* { *; }
-keepclassmembers class * extends com.sun.jna.* { public *; }
