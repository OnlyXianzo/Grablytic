import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.chaquo.python")
}

fun loadKeystoreProperties(): Properties? {
    val propsFile = rootProject.file("key.properties")
    if (!propsFile.exists()) return null
    val props = Properties()
    props.load(FileInputStream(propsFile))
    return props
}

android {
    namespace = "com.theonly.truestream"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.theonly.truestream"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24 // Chaquopy requires minSdk >= 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters.clear()
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
        python {
            version = "3.11"
            buildPython("/usr/bin/python3")
            pip("yt-dlp", "curl_cffi")
        }
    }

    signingConfigs {
        val keystoreProps = loadKeystoreProperties()
        if (keystoreProps != null) {
            create("release") {
                keyAlias = keystoreProps["keyAlias"] as String
                keyPassword = keystoreProps["keyPassword"] as String
                storeFile = file(keystoreProps["storeFile"] as String)
                storePassword = keystoreProps["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

chaquopy {
    sourceSets {
        getByName("main") {
            srcDir("../../engine")
        }
    }
}

flutter {
    source = "../.."
}
