// Grablytic native binary packages (Android).
//
// Why this exists: on targetSdk > 28 Android refuses to execute binaries the
// app downloads itself at runtime (SDK28 exec restriction). The only files the
// OS will run are ones shipped inside an APK's jniLibs — either ours or a
// helper app's. Helper apps would force the user through a system install
// prompt (REQUEST_INSTALL_PACKAGES), so Grablytic bundles instead: zero
// extra permissions, zero prompts, works offline on first run.
//
// Binaries:
// - ffmpeg (v7.0.1): from io.github.junkfood02.youtubedl-android:ffmpeg:0.17.2
//   (Maven Central, verified self-contained closure with ZERO missing DT_NEEDED
//   libraries, used by YTDLnis and Seal in production).
// - nodejs (v25.3.0) & deno (v2.7.7): from deniscerri/ytdlnis-packages (Bionic cross-compiles).
//
// Versions are pinned here. Bump + rebuild the APK to ship newer binaries.
// Skip with: flutter build apk --dart-define=... -PskipNativePackages

val nativePackageVersions = mapOf(
    "deno" to "2.7.7",
    "nodejs" to "25.3.0",
)
// Release variant selector: which JS runtime(s) to bundle for the PO-Token/SABR
// challenge path. `both` (default) reproduces the pre-variant universal APK;
// `deno` / `node` produce the single-runtime release variants (Task 2).
// Build with e.g.: flutter build apk --release -PtargetAbi=arm64-v8a -PjsRuntime=node
// Unknown values fail the build loudly (fail closed — never ship a runtimeless APK).
val jsRuntimeProp = (project.findProperty("jsRuntime") as String?)?.trim()?.lowercase()
val jsRuntime = if (jsRuntimeProp.isNullOrBlank()) "both" else jsRuntimeProp
check(jsRuntime in setOf("deno", "node", "both")) {
    "Unknown -PjsRuntime=$jsRuntimeProp (expected deno|node|both)"
}
// NOTE: the map keys are "deno"/"nodejs" while the property values are
// "deno"/"node" — normalized explicitly so a typo can't silently empty the set.
val activePackageVersions = nativePackageVersions.filterKeys { pkg ->
    jsRuntime == "both" || (jsRuntime == "deno" && pkg == "deno") ||
        (jsRuntime == "node" && pkg == "nodejs")
}
check(activePackageVersions.isNotEmpty()) {
    "jsRuntime=$jsRuntime selected zero JS packages — refusing to build"
}
// Must stay in sync with abiFilters in build.gradle.kts.
val targetAbiProp = project.findProperty("targetAbi") as String?
val nativePackageAbis = if (!targetAbiProp.isNullOrBlank()) {
    listOf(targetAbiProp)
} else {
    listOf("arm64-v8a", "armeabi-v7a", "x86_64")
}
val nativePackagesRepo = "deniscerri/ytdlnis-packages"

val ffmpegAarUrl = "https://repo1.maven.org/maven2/io/github/junkfood02/youtubedl-android/ffmpeg/0.17.2/ffmpeg-0.17.2.aar"
val ffmpegAarDigest = "e12402803f7a61802fded6bd021422688cb7a03e924068a1aec983dae88ea3c1"
val ffmpegVersion = "0.17.2"

tasks.register("downloadNativePackages") {
    group = "grablytic"
    description = "Fetch verified ffmpeg/deno/nodejs jniLibs."
    onlyIf { !project.hasProperty("skipNativePackages") }
    doLast {
        val jniLibs = layout.projectDirectory.dir("src/main/jniLibs").asFile

        // Drop stale single-runtime leftovers when switching variants locally
        // (e.g. `both` → `-PjsRuntime=node`): each upstream package contributes
        // exactly lib<pkg>.so + lib<pkg>.zip.so per ABI (verified against the
        // deno-2.7.7 / nodejs-25.3.0 arm64 payloads 2026-09-13), so deleting the
        // known names is exact — ffmpeg is never touched. CI runners start clean
        // and never hit this path.
        val pkgSoName = mapOf("deno" to "deno", "nodejs" to "node")
        // Prune across every ABI this project ever builds, not just the active
        // -PtargetAbi: a universal build followed by a single-ABI variant build
        // must not leave the excluded runtime behind in another ABI folder.
        val allKnownAbis = listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        for ((pkg, _) in nativePackageVersions) {
            if (activePackageVersions.containsKey(pkg)) continue
            val so = pkgSoName.getValue(pkg)
            for (abi in allKnownAbis) {
                jniLibs.resolve("$abi/lib$so.so").delete()
                jniLibs.resolve("$abi/lib$so.zip.so").delete()
                jniLibs.resolve(".$pkg-$abi.sha256").delete()
            }
            logger.lifecycle("native-packages: pruned inactive package $pkg (jsRuntime=$jsRuntime)")
        }

        // 1. Fetch verified FFmpeg from youtubedl-android AAR (Maven Central).
        val ffmpegWarm = nativePackageAbis.all { abi -> jniLibs.resolve(".ffmpeg-$abi.sha256").isFile }
        val ffmpegNeedsFetch = nativePackageAbis.any { abi ->
            val marker = jniLibs.resolve(".ffmpeg-$abi.sha256")
            !marker.exists() || marker.readText().trim() != ffmpegAarDigest
        }
        if (ffmpegNeedsFetch) {
            logger.lifecycle("native-packages: fetching ffmpeg from youtubedl-android ($ffmpegVersion) ...")
            val aar = File.createTempFile("native-ffmpeg", ".aar")
            try {
                try {
                    java.net.URL(ffmpegAarUrl).openStream().use { input ->
                        aar.outputStream().use { input.copyTo(it) }
                    }
                } catch (e: Exception) {
                    if (ffmpegWarm) {
                        logger.warn("native-packages: ffmpeg AAR unreachable (${e.message}); reusing cached jniLibs")
                    } else {
                        throw GradleException("native-packages: ffmpeg AAR unreachable and no cached jniLibs: ${e.message}")
                    }
                }
                if (aar.length() > 0) {
                    val actual = sha256Hex(aar)
                    check(actual.equals(ffmpegAarDigest, ignoreCase = true)) {
                        "SHA-256 mismatch for ffmpeg AAR: expected $ffmpegAarDigest, got $actual"
                    }
                    java.util.zip.ZipFile(aar).use { zip ->
                        for (abi in nativePackageAbis) {
                            val prefix = "jni/$abi/"
                            val entries = zip.entries().asSequence()
                                .filter { it.name.startsWith(prefix) && it.name.endsWith(".so") }
                                .toList()
                            check(entries.isNotEmpty()) { "No $prefix*.so entries in ffmpeg AAR" }
                            var extracted = 0
                            for (entry in entries) {
                                val fileName = entry.name.removePrefix(prefix)
                                val out = jniLibs.resolve("$abi/$fileName")
                                out.parentFile.mkdirs()
                                zip.getInputStream(entry).use { input ->
                                    out.outputStream().use { input.copyTo(it) }
                                }
                                extracted++
                            }
                            val marker = jniLibs.resolve(".ffmpeg-$abi.sha256")
                            marker.parentFile.mkdirs()
                            marker.writeText(ffmpegAarDigest)
                            logger.lifecycle("native-packages: ffmpeg/$abi ready ($extracted files)")
                        }
                    }
                }
            } finally {
                aar.delete()
            }
        } else {
            logger.lifecycle("native-packages: ffmpeg up to date ($ffmpegVersion)")
        }

        // 2. Fetch verified Deno and/or NodeJS from ytdlnis-packages
        // (GitHub Releases). The active set follows -PjsRuntime
        // (deno|node|both, default both); ffmpeg above is always bundled.
        logger.lifecycle(
            "native-packages: jsRuntime=$jsRuntime " +
                "(bundling ${activePackageVersions.keys.sorted().joinToString(",")})"
        )
        val slurper = groovy.json.JsonSlurper()
        val releases: List<Map<String, Any?>>
        try {
            @Suppress("UNCHECKED_CAST")
            val parsed = java.net.URL("https://api.github.com/repos/$nativePackagesRepo/releases")
                .openStream().use { slurper.parse(it) } as List<Map<String, Any?>>
            releases = parsed
        } catch (e: Exception) {
            val warm = activePackageVersions.keys.all { pkg ->
                nativePackageAbis.all { abi ->
                    if (pkg == "deno" && abi == "armeabi-v7a") true
                    else jniLibs.resolve(".$pkg-$abi.sha256").isFile
                }
            }
            if (warm) {
                logger.warn("native-packages: releases API unreachable (${e.message}); reusing cached jniLibs")
                return@doLast
            }
            throw GradleException("native-packages: releases API unreachable and no cached jniLibs: ${e.message}")
        }

        for ((pkg, version) in activePackageVersions) {
            val tag = "$pkg-$version"
            val release = releases.firstOrNull { it["tag_name"] == tag }
                ?: throw GradleException("Native package release not found: $tag")
            @Suppress("UNCHECKED_CAST")
            val assets = release["assets"] as List<Map<String, Any?>>
            for (abi in nativePackageAbis) {
                if (pkg == "deno" && abi == "armeabi-v7a") {
                    logger.lifecycle("native-packages: skipping deno on $abi (64-bit only upstream, nodejs used as fallback)")
                    continue
                }
                val assetName = "app-$abi-release.apk"
                val asset = assets.firstOrNull { it["name"] == assetName }
                    ?: throw GradleException("Asset $assetName missing in $tag")
                val url = asset["browser_download_url"] as String
                val digest = (asset["digest"] as String).removePrefix("sha256:")
                val marker = jniLibs.resolve(".$pkg-$abi.sha256")
                if (marker.exists() && marker.readText().trim() == digest) {
                    logger.lifecycle("native-packages: $pkg/$abi up to date ($tag)")
                    continue
                }
                logger.lifecycle("native-packages: fetching $pkg/$abi ($tag) ...")
                val apk = File.createTempFile("native-$pkg-$abi", ".apk")
                try {
                    java.net.URL(url).openStream().use { input ->
                        apk.outputStream().use { input.copyTo(it) }
                    }
                    val actual = sha256Hex(apk)
                    check(actual.equals(digest, ignoreCase = true)) {
                        "SHA-256 mismatch for $assetName: expected $digest, got $actual"
                    }
                    var extracted = 0
                    java.util.zip.ZipFile(apk).use { zip ->
                        val entries = zip.entries().asSequence()
                            .filter { it.name.startsWith("lib/$abi/") && it.name.endsWith(".so") }
                            .toList()
                        check(entries.isNotEmpty()) {
                            "No lib/$abi/*.so entries in $assetName; upstream repackaged? Entries: " +
                                zip.entries().asSequence().map { it.name }.take(20).joinToString()
                        }
                        for (entry in entries) {
                            val out = jniLibs.resolve(entry.name.removePrefix("lib/"))
                            out.parentFile.mkdirs()
                            zip.getInputStream(entry).use { input ->
                                out.outputStream().use { input.copyTo(it) }
                            }
                            extracted++
                        }
                    }
                    check(extracted > 0) { "Extracted 0 files from $assetName" }
                    marker.parentFile.mkdirs()
                    marker.writeText(digest)
                    logger.lifecycle("native-packages: $pkg/$abi ready ($extracted files)")
                } finally {
                    apk.delete()
                }
            }
        }
    }
}

fun sha256Hex(file: java.io.File): String {
    val md = java.security.MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buf = ByteArray(8192)
        var n: Int
        while (input.read(buf).also { n = it } != -1) md.update(buf, 0, n)
    }
    return md.digest().joinToString("") { "%02x".format(it) }
}
