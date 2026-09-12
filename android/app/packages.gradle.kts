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

// Build-time only: commons-compress powers the .deb/ar/xz/tar parsing in
// downloadNativeShims below (the APP keeps its own copy via build.gradle).
buildscript {
    dependencies {
        classpath("org.apache.commons:commons-compress:1.26.2")
    }
}

val nativePackageVersions = mapOf(
    "ffmpeg" to "7.1.1",
    "deno" to "2.7.7",
    // Primary Android JS runtime: Node links cleanly on Bionic while the
    // Deno bundle is missing shared libs (libsqlite3.so). Same pinned,
    // verified fetch as the rest.
    "nodejs" to "25.3.0",
)
// Must stay in sync with abiFilters in build.gradle.kts.
val nativePackageAbis = listOf("arm64-v8a", "x86_64")
val nativePackagesRepo = "deniscerri/ytdlnis-packages"

// ABI shims: shared libs missing from the ytdlnis trees, proven by
// on-device linker verdicts (libexpat.so.1 needed by libfontconfig;
// without it EVERY bundled binary fails to spawn). Source: Termux apt
// (Bionic API 24+, same floor as us; Expat is MIT-licensed). Pinned
// SHA-256, verified before extraction — same fail-closed policy as the
// packages above. No blobs in git; fetched at build time like the rest.
// Skip with -PskipNativePackages (same flag).
data class NativeShim(
    val soname: String,
    val debMember: String,
    val urls: Map<String, String>,
    val digests: Map<String, String>,
)

val nativeShims = listOf(
    NativeShim(
        soname = "libexpat.so.1",
        debMember = "data/data/com.termux/files/usr/lib/libexpat.so.1.12.4",
        urls = mapOf(
            "arm64-v8a" to "https://packages.termux.org/apt/termux-main/pool/main/libe/libexpat/libexpat_2.8.4_aarch64.deb",
            "x86_64" to "https://packages.termux.org/apt/termux-main/pool/main/libe/libexpat/libexpat_2.8.4_x86_64.deb",
        ),
        digests = mapOf(
            "arm64-v8a" to "71934cf00b404627702034bd1308cb58353dd851d9a2d3ecd9205b4ae6a67a27",
            "x86_64" to "0b1de1b009a09cb02d8ddc2311799b4c527fd6863765c0cc782f83143c1369ba",
        ),
    ),
)

tasks.register("downloadNativePackages") {
    group = "truestream"
    description = "Fetch verified ffmpeg/deno/nodejs jniLibs from ytdlnis-packages releases."
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

tasks.register("downloadNativeShims") {
    group = "truestream"
    description = "Fetch Termux ABI shims (libexpat) into jniLibs."
    onlyIf { !project.hasProperty("skipNativePackages") }
    doLast {
        val jniLibs = layout.projectDirectory.dir("src/main/jniLibs").asFile
        for (shim in nativeShims) {
            for (abi in nativePackageAbis) {
                val url = shim.urls[abi]
                    ?: throw GradleException("No ${shim.soname} URL for $abi")
                val digest = shim.digests[abi]
                    ?: throw GradleException("No ${shim.soname} digest for $abi")
                val marker = jniLibs.resolve(".shim-${shim.soname}-$abi.sha256")
                if (marker.exists() && marker.readText().trim() == digest) {
                    logger.lifecycle("native-shims: ${shim.soname}/$abi up to date")
                    continue
                }
                logger.lifecycle("native-shims: fetching ${shim.soname}/$abi ...")
                val deb = File.createTempFile("native-shim", ".deb")
                try {
                    java.net.URL(url).openStream().use { input ->
                        deb.outputStream().use { input.copyTo(it) }
                    }
                    val actual = sha256Hex(deb)
                    check(actual.equals(digest, ignoreCase = true)) {
                        "SHA-256 mismatch for ${shim.soname}/$abi: expected $digest, got $actual"
                    }
                    // .deb = ar(debian-binary, control.tar.*, data.tar.xz).
                    var dataName: String? = null
                    var dataBytes: ByteArray? = null
                    java.io.FileInputStream(deb).buffered().use { fis ->
                        org.apache.commons.compress.archivers.ar.ArArchiveInputStream(fis).use { ar ->
                            var entry = ar.nextEntry
                            while (entry != null) {
                                if (entry.name.startsWith("data.tar.")) {
                                    dataName = entry.name
                                    val out = java.io.ByteArrayOutputStream()
                                    val buf = ByteArray(65536)
                                    var total = 0
                                    while (true) {
                                        val n = ar.read(buf)
                                        if (n < 0) break
                                        total += n
                                        check(total <= 32 * 1024 * 1024) {
                                            "data archive too large: ${entry.name}"
                                        }
                                        out.write(buf, 0, n)
                                    }
                                    dataBytes = out.toByteArray()
                                    break
                                }
                                entry = ar.nextEntry
                            }
                        }
                    }
                    val rawName = dataName
                        ?: throw GradleException("No data.tar.* in ${shim.soname}/$abi")
                    val bytes = dataBytes
                        ?: throw GradleException("Empty data archive ${shim.soname}/$abi")
                    val tarStream: java.io.InputStream = if (rawName.endsWith(".xz")) {
                        org.apache.commons.compress.compressors.xz.XZCompressorInputStream(bytes.inputStream())
                    } else {
                        java.util.zip.GZIPInputStream(bytes.inputStream())
                    }
                    var found = false
                    tarStream.use { ts ->
                        org.apache.commons.compress.archivers.tar.TarArchiveInputStream(ts).use { tar ->
                            var e = tar.nextEntry
                            while (e != null) {
                                if (!e.isDirectory && e.name == shim.debMember) {
                                    val out = jniLibs.resolve("$abi/${shim.soname}")
                                    out.parentFile.mkdirs()
                                    out.outputStream().use { tar.copyTo(it) }
                                    out.setReadable(true, false)
                                    found = true
                                    break
                                }
                                e = tar.nextEntry
                            }
                        }
                    }
                    check(found) { "Member ${shim.debMember} missing in ${shim.soname}/$abi" }
                    marker.parentFile.mkdirs()
                    marker.writeText(digest)
                    logger.lifecycle("native-shims: ${shim.soname}/$abi ready")
                } finally {
                    deb.delete()
                }
            }
        }
    }
}
