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

        // Chaquopy HARD-requires ndk.abiFilters (build fails without it).
        // Release variants (Task 2): the JS-runtime dimension lives in
        // packages.gradle.kts as `-PjsRuntime=deno|node|both` (default `both`),
        // combined with this `-PtargetAbi` selector. Shipped matrix:
        // arm64-v8a+Deno, arm64-v8a+Node.js, universal(both). Deliberately NOT
        // Gradle splits{} / product flavors: splits{} conflicts with this
        // Chaquopy-mandated abiFilters block (hard build error), and flavor-level
        // abiFilters are silently ignored by the Flutter Gradle plugin ≥3.35.
        // The -P property matrix produces the same artifacts without either risk.
        // If targetAbi is passed (-PtargetAbi=arm64-v8a), build for that specific ABI.
        // Otherwise, bundle arm64-v8a, armeabi-v7a, and x86_64 for a universal APK.
        val targetAbi = project.findProperty("targetAbi") as String?
        ndk {
            abiFilters.clear()
            if (!targetAbi.isNullOrBlank()) {
                abiFilters += targetAbi
            } else {
                abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
            }
        }
    }

    // Native-package .so files are executables + zips, not linked libraries:
    // keep legacy extraction so they land as real files in nativeLibraryDir.
    packagingOptions {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += listOf("**/*.zip.so")
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

    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
}

dependencies {
    // Symlink-aware zip extraction for the bundled support trees
    // (mirrors ytdlnis ZipUtils — java.util.zip cannot see Unix symlink
    // entries and extracts them as text files, breaking the linker).
    implementation("org.apache.commons:commons-compress:1.26.2")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
}

chaquopy {
    defaultConfig {
        version = "3.11"
        pip {
            install("yt-dlp")
            // python-quickjs requires native Android wheel not yet available via Chaquopy pip.
            // QuickJS on Android will be bridged via Kotlin JNI in a future milestone.
        }
    }
    sourceSets {
        getByName("main") {
            srcDir("../../engine")
        }
    }
}

flutter {
    source = "../.."
}

// Prebuilt Android binaries (ffmpeg/deno) bundled into our own jniLibs —
// no helper APKs, no install prompts, no extra permissions. See file.
apply(from = "packages.gradle.kts")

// Guarantee the download tasks run before native libs are merged.
tasks.matching { it.name.startsWith("merge") && it.name.contains("JniLibFolders") }
    .configureEach { dependsOn("downloadNativePackages") }

// AGP/Kotlin script analysis bug causes lintVitalAnalyzeRelease to crash on KaModule.
tasks.matching { it.name.startsWith("lintVital") }.configureEach {
    enabled = false
}
