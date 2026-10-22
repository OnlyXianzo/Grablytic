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
    namespace = "com.theonly.grablytic"
    // At least API 35: `Service.onTimeout(int startId, int fgsType)` —
    // the callback the system actually uses when a dataSync foreground
    // service runs out of its 6-hour budget — was added in API 35, and
    // DownloadService overrides it. Compiling against a lower API level
    // would make the override unresolvable.
    compileSdk = maxOf(flutter.compileSdkVersion, 35)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.theonly.grablytic"
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
            val releaseSigning = signingConfigs.findByName("release")
            if (releaseSigning == null) {
                // A release APK signed with the DEBUG key is a trap: it
                // cannot be upgraded in place over the shipped build, it
                // carries a key every developer has, and it looks
                // published. The old code fell back silently, so a
                // release built without a keystore produced a
                // debug-signed artifact with no warning.
                //
                // A local build that only asks for a debug variant is
                // unaffected; a task that actually PRODUCES a signed
                // release artifact fails loudly.
                //
                // Only the artifact-producing tasks count. A release
                // *variant* task that never signs anything (lintRelease,
                // compileReleaseKotlin, testReleaseUnitTest) must keep
                // working without a keystore — otherwise the CI lint
                // gate could never run, because CI has no keystore.
                val releaseArtifactTasks = setOf(
                    "assemblerelease",
                    "bundlerelease",
                    "packagerelease",
                    "signrelease",
                    "installrelease",
                    // The aggregate tasks build the release variant too.
                    // Without them `./gradlew assemble` (or `bundle`,
                    // or `build`) produced a DEBUG-SIGNED release
                    // artifact with no warning — the exact outcome this
                    // guard exists to prevent.
                    "assemble",
                    "bundle",
                    "build",
                )
                val buildingRelease = gradle.startParameter.taskNames.any { raw ->
                    val task = raw.substringAfterLast(':').lowercase()
                    task in releaseArtifactTasks
                }
                if (buildingRelease) {
                    throw org.gradle.api.GradleException(
                        "No release signing configuration. Provide " +
                            "android/key.properties (storeFile, storePassword, " +
                            "keyAlias, keyPassword) before building a release " +
                            "variant; a release must never be signed with the " +
                            "debug key.",
                    )
                }
                signingConfig = signingConfigs.getByName("debug")
            } else {
                signingConfig = releaseSigning
            }
        }
    }

    // JVM unit tests call android.util.Log through the parser's truncation
    // path (SEC-003). Without this, AGP's mockable android.jar throws
    // "Method w in android.util.Log not mocked" and the test fails for a
    // reason that has nothing to do with the code under test.
    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    lint {
        // Lint runs on release builds again (the AGP default) and its
        // errors fail the build. The old configuration disabled both
        // (`checkReleaseBuilds = false`, `abortOnError = false`), so a
        // release could ship with unchecked lint findings — including
        // the API-level mistakes that break a build on a newer Android
        // version.
        checkReleaseBuilds = true
        abortOnError = true
        // Informational findings stay informational; only errors gate.
        warningsAsErrors = false
    }
}

dependencies {
    // Symlink-aware zip extraction for the bundled support trees
    // (mirrors ytdlnis ZipUtils — java.util.zip cannot see Unix symlink
    // entries and extracts them as text files, breaking the linker).
    implementation("org.apache.commons:commons-compress:1.26.2")
    implementation("androidx.work:work-runtime-ktx:2.10.0")

    // SEC-002 / SEC-003: the feed-URL policy and the Atom parser are plain
    // Kotlin, so their tests run on the JVM (`./gradlew :app:testDebugUnitTest`)
    // instead of needing an emulator. JUnit 4 because that is what AGP's default
    // test runtime expects out of the box.
    testImplementation("junit:junit:4.13.2")
    // `android.util.Xml.newPullParser()` is a stub outside an Android runtime.
    // kxml2 is the parser Android ships a fork of, so the tests parse with the
    // same implementation family the device uses.
    testImplementation("net.sf.kxml:kxml2:2.3.0")
}

chaquopy {
    defaultConfig {
        version = "3.11"
        pip {
            // Pinned, like the desktop bootstrap. An unpinned install
            // makes the packaged engine depend on whatever PyPI serves
            // at build time, with no review of the change.
            // Keep in step with wheel_pin.PINNED_VERSION,
            // EngineContract.ytDlpVersion and engine/requirements.txt
            // (engine/tests/test_wheel_pin.py fails on drift).
            //
            // Chaquopy's pip DSL has no per-requirement hash option, so
            // the digest pin (#18) is enforced at runtime instead:
            // `bootstrap._install_yt_dlp_via_uv` downloads the wheel,
            // checks it against wheel_pin.PINNED_SHA256 and installs only
            // verified bytes. The APK copy comes from this Gradle
            // resolution at build time, from the hash-locked runner.
            install("yt-dlp==2026.8.19")
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
