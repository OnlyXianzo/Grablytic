// TrueStream native binary packages (Android).
//
// Why this exists: on targetSdk > 28 Android refuses to execute binaries the
// app downloads itself at runtime (SDK28 exec restriction). The only files the
// OS will run are ones shipped inside an APK's jniLibs — either ours or a
// helper app's. Helper apps would force the user through a system install
// prompt (REQUEST_INSTALL_PACKAGES), so TrueStream bundles instead: zero
// extra permissions, zero prompts, works offline on first run.
//
// Binaries come from deniscerri/ytdlnis-packages (termux-packages
// cross-compiles for Bionic, maintained, versioned releases). This task runs
// before jniLib merging, downloads the per-ABI helper APKs, verifies each
// against the sha256 digest published by the GitHub Releases API, and extracts
// only lib/<abi>/lib*.so into src/main/jniLibs/<abi>/.
//
// Versions are pinned here. Bump + rebuild the APK to ship newer binaries
// (downloaded files could never be executed at runtime anyway, so there is
// deliberately no in-app binary updater on Android).
// Skip with: flutter build apk --dart-define=... -PskipNativePackages

val nativePackageVersions = mapOf(
    "ffmpeg" to "7.1.1",
    "deno" to "2.7.7",
)
// Must stay in sync with abiFilters in build.gradle.kts.
val nativePackageAbis = listOf("arm64-v8a", "x86_64")
val nativePackagesRepo = "deniscerri/ytdlnis-packages"

tasks.register("downloadNativePackages") {
    group = "truestream"
    description = "Fetch verified ffmpeg/deno jniLibs from ytdlnis-packages releases."
    onlyIf { !project.hasProperty("skipNativePackages") }
    doLast {
        val jniLibs = layout.projectDirectory.dir("src/main/jniLibs").asFile
        val slurper = groovy.json.JsonSlurper()
        val releases: List<Map<String, Any?>>
        try {
            @Suppress("UNCHECKED_CAST")
            val parsed = java.net.URL("https://api.github.com/repos/$nativePackagesRepo/releases")
                .openStream().use { slurper.parse(it) } as List<Map<String, Any?>>
            releases = parsed
        } catch (e: Exception) {
            // Offline rebuild with warm jniLibs must not break the build.
            val warm = nativePackageVersions.keys.all { pkg ->
                nativePackageAbis.all { abi -> jniLibs.resolve(".$pkg-$abi.sha256").isFile }
            }
            if (warm) {
                logger.warn("native-packages: releases API unreachable (${e.message}); reusing cached jniLibs")
                return@doLast
            }
            throw GradleException("native-packages: releases API unreachable and no cached jniLibs: ${e.message}")
        }

        for ((pkg, version) in nativePackageVersions) {
            val tag = "$pkg-$version"
            val release = releases.firstOrNull { it["tag_name"] == tag }
                ?: throw GradleException("Native package release not found: $tag")
            @Suppress("UNCHECKED_CAST")
            val assets = release["assets"] as List<Map<String, Any?>>
            for (abi in nativePackageAbis) {
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
