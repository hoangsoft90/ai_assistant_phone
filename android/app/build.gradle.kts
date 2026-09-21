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
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
}
