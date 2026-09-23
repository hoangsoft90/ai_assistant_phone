plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.aiassistant.phone"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.aiassistant.phone"
        // minSdk 26 (Android 8.0) theo khuyến nghị của prompt P0.5: đủ để dùng foreground service
        // kiểu mới + Bluetooth permission model ổn định, và tránh phải xử lý nhánh quá cũ.
        // (Mặc định của Flutter là 24.)
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // P1C: chỉ build 1 ABI (máy test arm64-v8a) — whisper.cpp build cho mỗi ABI đều tốn
        // thời gian CI đáng kể. Thêm ABI khác khi cần phân phối rộng.
        //
        // K30 (đo trên máy thật 2026-09-22): khai báo này một mình KHÔNG đủ — plugin Flutter chạy
        // sau và ghi đè bằng `clear()` + `addAll(PLATFORM_ABI_LIST)` (armeabi-v7a + arm64-v8a +
        // x86_64), nên APK từng là 155MB với 3 bản mỗi thư viện native. Điều kiện để plugin chịu
        // đứng yên là property `disable-abi-filtering=true` trong android/gradle.properties.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // P7 mục 5: chính sách signing. **Cố ý debug-signed** cho đến khi user tạo keystore
            // riêng (đã chốt ở phiên P7: chưa signing — chỉ đo size + chạy R8 trên CI). KHÔNG
            // phân phối APK này: debug key nằm trên CI và có thể bị thay thế bất cứ lúc nào.
            // Khi signing thật: tạo keystore ngoài git + đọc password từ env/CI secret —
            // TUYỆT ĐỐI không commit mật khẩu keystore vào repo (rule 8 của AGENTS.md).
            signingConfig = signingConfigs.getByName("debug")

            // P7 mục 5: bật minify + shrink cho bản release. Lý do bật: model AI đã chiếm phần
            // lớn APK (Vosk 32MB + whisper ~chục MB), phần code Java/Kotlin của app và SDK
            // Flutter là phần duy nhất thu được. Keep rules ở proguard-rules.pro (JNA, org.vosk,
            // AsrNative) — đã kiểm bằng grep toàn repo: đúng 3 nhóm cần reflection/JNI.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        debug {
            // R8 chỉ chạy ở release; giữ bản debug không minify để stack trace dễ đọc khi test.
            isMinifyEnabled = false
        }
    }

    // P1C: build whisper.cpp (FetchContent pin commit trong cpp/CMakeLists.txt) + JNI wrapper.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    // P1D: vosk-android dùng JNA, và JNA tự giải nén `libjnidispatch.so` từ tài nguyên của AAR.
    // Từ AGP 8, native libs mặc định được đóng KHÔNG nén (useLegacyPackaging = false) → JNA rơi vào
    // nhánh tìm `com/sun/jna/<platform>/libjnidispatch.so` trong classpath và nổ UnsatisfiedLinkError
    // (đã có case thật: LottieFiles/dotlottie-android#98, 01/2026). Bật legacy packaging để lib được
    // giải nén ra thư mục của app lúc cài — đường tải cổ điển mà JNA chắc chắn đi qua được.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // P1B: WebRTC VAD (GMM, 158KB, chạy on-device, API 21+). Chọn bản nhẹ nhất đủ dùng theo
    // gợi ý của prompt_P1B — Silero/Yamnet cần ONNX/TFLite runtime nên nặng hơn nhiều.
    implementation("com.github.gkonovalov.android-vad:webrtc:2.0.10")

    // P1D: Vosk (ASR dự phòng) — dùng thẳng AAR chính chủ thay vì package Flutter.
    // Lý do (đã tra thực tế, xem .plan/P1D-result.md):
    //  - `vosk_flutter` 0.3.48 yêu cầu Dart `>=2.15.1 <3.0.0` → không cài được với Dart 3.
    //  - `vosk_flutter_2` (2023) là bản cũ, module Android chưa có `namespace` (AGP 8+ bắt buộc).
    //  - `vosk_flutter_service` (09/2026) hợp Flutter 3.47 nhưng kéo `permission_handler: ^13.0.0`
    //    → permission_handler_android 14.x đòi compileSdk 37 > AGP 9.1.0 max 36 (đúng lỗi làm
    //    CI run #1 fail). Dùng AAR trực tiếp thì không dính ràng buộc này.
    //  - AAR đã kiểm: minCompileSdk=1 (không có bẫy compileSdk), có libvosk.so cho arm64-v8a,
    //    POM kéo `net.java.dev.jna:jna:5.18.1`.
    // `@aar` cho jna là BẮT BUỘC: biến thể jar không kèm libjnidispatch.so cho Android.
    implementation("net.java.dev.jna:jna:5.18.1@aar")
    implementation("com.alphacephei:vosk-android:0.3.75@aar")
}
