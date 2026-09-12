package com.theonly.truestream

import android.content.Context
import android.util.Log
import java.io.File
import java.util.zip.ZipFile

/**
 * Resolved paths for one bundled native binary.
 *
 * @param executable Absolute path of the executable inside our own
 *   nativeLibraryDir (e.g. .../lib/arm64/libffmpeg.so). It MUST be executed
 *   in place — copying it elsewhere and running the copy fails on
 *   targetSdk > 28.
 * @param ldLibDir Absolute path of the extracted `usr/lib` dependency tree,
 *   or null when the package ships none. Exported to the engine so child
 *   processes find their shared libraries (libffmpeg.so has no RUNPATH).
 */
data class NativeBinPaths(val executable: String, val ldLibDir: String?)

/** Health of one package after [BinaryPackageManager.init]. */
data class NativeBinStatus(
    val name: String,
    val ok: Boolean,
    val version: String?,
    val detail: String,
)

/**
 * Bundled native binaries (ffmpeg, deno) shipped in our own jniLibs.
 *
 * Design mirrors deniscerri/ytdlnis `PackageBase.initBundled`, minus the
 * helper-APK branch: helper APKs would force the user through a system
 * install prompt (REQUEST_INSTALL_PACKAGES), which TrueStream refuses to
 * require. Consequences, stated plainly:
 * - No new permissions. The manifest stays INTERNET + capped storage only.
 * - Binary updates ride app updates (downloaded files can't be executed on
 *   targetSdk > 28, so a silent in-app binary updater is impossible here).
 * - If a .so is missing (e.g. contributor build with -PskipNativePackages),
 *   the entry is absent and callers fall back to legacy bin/ paths.
 */
object BinaryPackageManager {
    private const val TAG = "BinaryPackages"

    private data class Spec(val name: String, val zipSo: String, val exeSo: String)

    private val SPECS = listOf(
        Spec("ffmpeg", "libffmpeg.zip.so", "libffmpeg.so"),
        Spec("deno", "libdeno.zip.so", "libdeno.so"),
        Spec("node", "libnode.zip.so", "libnode.so"),
    )

    /**
     * Extract support trees and resolve executables. Safe to call on every
     * `paths/set`: extraction is skipped unless the bundled zip changed size.
     * Call off the main thread (does file I/O + version probes).
     */
    fun init(context: Context): Map<String, NativeBinPaths> {
        val out = mutableMapOf<String, NativeBinPaths>()
        val libDir = File(context.applicationInfo.nativeLibraryDir)
        for (spec in SPECS) {
            try {
                val exe = File(libDir, spec.exeSo)
                if (!exe.isFile) {
                    Log.w(TAG, "${spec.name}: ${spec.exeSo} not in jniLibs (build without packages?)")
                    continue
                }
                val target = File(File(context.noBackupFilesDir, "packages"), spec.name)
                extractTree(File(libDir, spec.zipSo), target)
                val ldDir = File(target, "usr/lib").takeIf { it.isDirectory }
                out[spec.name] = NativeBinPaths(exe.absolutePath, ldDir?.absolutePath)
            } catch (e: Exception) {
                Log.w(TAG, "${spec.name}: init failed: ${e.message}")
            }
        }
        return out
    }

    /** Probe `--version` for diagnostics. Never throws. */
    fun status(paths: Map<String, NativeBinPaths>): List<NativeBinStatus> =
        paths.map { (name, bin) ->
            try {
                val proc = ProcessBuilder(bin.executable, "--version")
                    .redirectErrorStream(true)
                    .apply {
                        // The bundled .so files have no RUNPATH; without this
                        // the probe fails even though the binary is healthy.
                        if (bin.ldLibDir != null) {
                            environment()["LD_LIBRARY_PATH"] = bin.ldLibDir
                        }
                    }
                    .start()
                val firstLine = proc.inputStream.bufferedReader().readLine()?.take(120)
                val exited = proc.waitFor(8, java.util.concurrent.TimeUnit.SECONDS)
                if (exited && proc.exitValue() == 0 && firstLine != null) {
                    NativeBinStatus(name, true, firstLine, bin.executable)
                } else {
                    proc.destroyForcibly()
                    NativeBinStatus(name, false, null, "probe failed: $firstLine")
                }
            } catch (e: Exception) {
                NativeBinStatus(name, false, null, "probe error: ${e.message}")
            }
        }

    private fun extractTree(zipSo: File, target: File) {
        if (!zipSo.isFile) return // packages without a support tree (none today)
        val marker = File(target, ".zipsize")
        val size = zipSo.length().toString()
        if (target.isDirectory && marker.isFile && marker.readText().trim() == size) return

        deleteQuietly(target)
        target.mkdirs()
        ZipFile(zipSo).use { zip ->
            for (entry in zip.entries()) {
                val out = File(target, entry.name)
                // Zip-slip guard (entries come from our own APK, belt and braces).
                check(out.canonicalPath.startsWith(target.canonicalPath + File.separator)) {
                    "Unsafe zip entry: ${entry.name}"
                }
                if (entry.isDirectory) {
                    out.mkdirs()
                } else {
                    out.parentFile?.mkdirs()
                    zip.getInputStream(entry).use { input ->
                        out.outputStream().use { input.copyTo(it) }
                    }
                }
            }
        }
        // .so deps need read access; keep everything executable-safe.
        target.walkTopDown().forEach { it.setExecutable(true, false) }
        try {
            marker.writeText(size)
        } catch (_: Exception) {
        }
        Log.i(TAG, "extracted ${zipSo.name} -> ${target.absolutePath}")
    }

    private fun deleteQuietly(file: File) {
        try {
            if (file.exists()) file.deleteRecursively()
        } catch (_: Exception) {
        }
    }
}
