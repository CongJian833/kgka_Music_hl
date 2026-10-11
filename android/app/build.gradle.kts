import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // Flutter 3.32.8 的 Gradle 插件不会自动应用 KGP，需显式启用以编译 Kotlin 源码。
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名信息从 android/key.properties 读取（该文件已被 .gitignore 忽略，不入库）。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

/** key.properties 是否已填好完整签名信息。 */
fun hasReleaseSigning(): Boolean = keystorePropertiesFile.exists() &&
    !keystoreProperties.getProperty("storeFile").isNullOrBlank() &&
    !keystoreProperties.getProperty("storePassword").isNullOrBlank() &&
    !keystoreProperties.getProperty("keyAlias").isNullOrBlank() &&
    !keystoreProperties.getProperty("keyPassword").isNullOrBlank()

android {
    namespace = "com.hoilai.mm.music"
    compileSdk = 36
    // Flutter 3.32.8 默认要求 NDK 26.3，显式使用本地已安装的 28.2 避免重复下载。
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning()) {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.hoilai.mm.music"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Flutter 3.32.8 官方默认 minSdk=21（Android 5.0），直接使用其值。
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
            // 安卓 5.1 设备多为 32 位系统，必须包含 armeabi-v7a。
            abiFilters.add("armeabi-v7a")
        }
    }

    buildTypes {
        release {
            // key.properties 填好后，命令行与 Android Studio 打包统一使用 release 正式签名；
            // 未配置完整信息时回退 debug 签名，保证开发期构建不被阻塞。
            if (hasReleaseSigning()) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                println("Warning: android/key.properties 未配置完整签名信息，release 构建将回退使用 debug 签名。")
                signingConfig = signingConfigs.getByName("debug")
            }
            ndk {
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
                abiFilters.add("armeabi-v7a")
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}


flutter {
    source = "../.."
}
