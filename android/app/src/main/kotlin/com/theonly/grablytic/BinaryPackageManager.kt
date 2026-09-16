package com.theonly.grablytic

import android.content.Context
import android.util.Log
import java.io.File

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
 * install prompt (REQUEST_INSTALL_PACKAGES), which Grablytic refuses to
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

    /** Probe version for diagnostics. Never throws. */
    fun status(paths: Map<String, NativeBinPaths>, extraLdDirs: List<String> = emptyList()): List<NativeBinStatus> =
        paths.map { (name, bin) ->
            try {
                // Single-dash form, matching yt-dlp's own probe style
                // (`-bsfs`). Both forms work on real FFmpeg builds
                // (verified: `ffmpeg --version` exits 0); single-dash is
                // kept for consistency, not necessity.
                val versionArg = if (name.startsWith("ffmpeg") || name.startsWith("ffprobe")) "-version" else "--version"
                val proc = ProcessBuilder(bin.executable, versionArg)
                    .redirectErrorStream(true)
                    .apply {
                        // The bundled .so files have no RUNPATH; without this
                        // the probe fails even though the binary is healthy.
                        val ldParts = listOfNotNull(
                            bin.ldLibDir,
                            *extraLdDirs.toTypedArray(),
                        ).filter { it.isNotBlank() }.distinct()
                        if (ldParts.isNotEmpty()) {
                            environment()["LD_LIBRARY_PATH"] = ldParts.joinToString(":")
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

    private data class Stamp(val length: Long, val mtime: Long, val crc32: Long)

    private fun readStamp(file: File): Stamp? {
        if (!file.isFile) return null
        return try {
            val lines = file.readLines()
            if (lines.isEmpty() || lines[0].trim() != "v3-atomic") return null
            val map = lines.drop(1).associate {
                val parts = it.split("=", limit = 2)
                parts[0].trim() to parts.getOrNull(1)?.trim()
            }
            val len = map["length"]?.toLongOrNull() ?: return null
            val mtime = map["mtime"]?.toLongOrNull() ?: return null
            val crc = map["crc32"]?.toLongOrNull() ?: return null
            Stamp(len, mtime, crc)
        } catch (_: Exception) {
            null
        }
    }

    private fun writeStamp(file: File, stamp: Stamp) {
        try {
            file.writeText("v3-atomic\nlength=${stamp.length}\nmtime=${stamp.mtime}\ncrc32=${stamp.crc32}\n")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to write stamp: ${e.message}")
        }
    }

    private fun computeCrc32(file: File): Long {
        val crc = java.util.zip.CRC32()
        val buf = ByteArray(65536)
        file.inputStream().use { input ->
            var n: Int
            while (input.read(buf).also { n = it } != -1) {
                crc.update(buf, 0, n)
            }
        }
        return crc.value
    }

    private fun safeDeleteEntry(file: File) {
        try {
            val stat = android.system.Os.lstat(file.absolutePath)
            if (android.system.OsConstants.S_ISDIR(stat.st_mode)) {
                file.deleteRecursively()
            } else {
                android.system.Os.unlink(file.absolutePath)
            }
        } catch (e: android.system.ErrnoException) {
            if (e.errno != android.system.OsConstants.ENOENT) {
                file.delete()
            }
        } catch (_: Exception) {
            file.delete()
        }
    }

    private fun recoverIncompleteSwap(packagesDir: File, name: String) {
        val target = File(packagesDir, name)
        val tmp = File(packagesDir, "$name.tmp")
        val backup = File(packagesDir, "$name.bak")

        if (!target.exists()) {
            if (tmp.exists() && File(tmp, ".zipsize").isFile) {
                Log.w(TAG, "Recovering swap: promoting intact $tmp to $target")
                if (!tmp.renameTo(target)) {
                    Log.e(TAG, "Failed to promote $tmp to $target")
                }
            } else if (backup.exists()) {
                Log.w(TAG, "Recovering swap: rolling back $backup to $target")
                if (!backup.renameTo(target)) {
                    Log.e(TAG, "Failed to rollback $backup to $target")
                }
            }
        }
        deleteQuietly(tmp)
        deleteQuietly(backup)
    }

    private fun extractTree(zipSo: File, target: File) {
        if (!zipSo.isFile) return // packages without a support tree (none today)
        val packagesDir = target.parentFile
            ?: throw IllegalStateException("no parent for ${target.absolutePath}")

        recoverIncompleteSwap(packagesDir, target.name)

        val marker = File(target, ".zipsize")
        val currentStamp = readStamp(marker)

        val zipLength = zipSo.length()
        val zipMtime = zipSo.lastModified()

        // Two-tier cache check: fast path checks size + mtime
        if (target.isDirectory && currentStamp != null) {
            if (currentStamp.length == zipLength && currentStamp.mtime == zipMtime) {
                return
            }
            // If mtime/length differ, check authoritative CRC32
            val actualCrc = computeCrc32(zipSo)
            if (currentStamp.length == zipLength && currentStamp.crc32 == actualCrc) {
                // Update mtime in stamp so subsequent launches hit fast path
                writeStamp(marker, Stamp(zipLength, zipMtime, actualCrc))
                return
            }
        }

        // Three-way atomic swap: extract into tmp, swap target -> backup, tmp -> target, delete backup.
        val tmp = File(packagesDir, "${target.name}.tmp")
        val backup = File(packagesDir, "${target.name}.bak")
        deleteQuietly(tmp)
        deleteQuietly(backup)
        tmp.mkdirs()

        val crc = try {
            extractZipTo(zipSo, tmp)
        } catch (e: Exception) {
            deleteQuietly(tmp)
            throw e
        }

        val newStamp = Stamp(zipLength, zipMtime, crc)
        writeStamp(File(tmp, ".zipsize"), newStamp)

        if (target.exists()) {
            if (!target.renameTo(backup)) {
                deleteQuietly(tmp)
                Log.w(TAG, "${target.name}: rename to backup failed; aborting swap")
                return
            }
        }

        if (!tmp.renameTo(target)) {
            Log.e(TAG, "${target.name}: atomic swap failed; rolling back from backup")
            if (backup.exists() && !backup.renameTo(target)) {
                Log.e(TAG, "${target.name}: rollback from backup also failed!")
            }
            deleteQuietly(tmp)
            return
        }

        deleteQuietly(backup)

        // .so deps need read access; keep everything executable-safe.
        target.walkTopDown().forEach { it.setExecutable(true, false) }
        Log.i(TAG, "extracted ${zipSo.name} -> ${target.absolutePath} (CRC32: $crc)")
    }

    private fun extractZipTo(zipSo: File, target: File): Long {
        val crc = java.util.zip.CRC32()
        val buf = ByteArray(65536)

        org.apache.commons.compress.archivers.zip.ZipFile(zipSo).use { zip ->
            val entries = zip.entries
            while (entries.hasMoreElements()) {
                val entry = entries.nextElement()
                val out = File(target, entry.name)

                // Zip-slip entry location guard
                check(out.canonicalPath.startsWith(target.canonicalPath + File.separator)) {
                    "Unsafe zip entry: ${entry.name}"
                }

                if (entry.isDirectory) {
                    safeDeleteEntry(out)
                    out.mkdirs()
                } else if (entry.isUnixSymlink) {
                    out.parentFile?.mkdirs()
                    val linkTarget = zip.getInputStream(entry).use { it.bufferedReader().readText().trim() }
                    check(linkTarget.isNotEmpty()) { "Empty symlink target in ${entry.name}" }
                    check(!linkTarget.startsWith("/")) {
                        "Absolute symlink target forbidden: ${entry.name} -> $linkTarget"
                    }
                    val resolvedTarget = File(out.parentFile, linkTarget).canonicalPath
                    check(resolvedTarget.startsWith(target.canonicalPath + File.separator)) {
                        "Symlink target escapes package directory: ${entry.name} -> $linkTarget"
                    }
                    safeDeleteEntry(out)
                    android.system.Os.symlink(linkTarget, out.absolutePath)
                } else {
                    out.parentFile?.mkdirs()
                    safeDeleteEntry(out)
                    zip.getInputStream(entry).use { input ->
                        out.outputStream().use { output ->
                            var n: Int
                            while (input.read(buf).also { n = it } != -1) {
                                output.write(buf, 0, n)
                            }
                        }
                    }
                }
            }
        }

        zipSo.inputStream().use { input ->
            var n: Int
            while (input.read(buf).also { n = it } != -1) {
                crc.update(buf, 0, n)
            }
        }
        return crc.value
    }

    private fun deleteQuietly(file: File) {
        try {
            if (file.exists()) file.deleteRecursively()
        } catch (_: Exception) {
        }
    }
}
