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
    private const val MAX_ZIP_PATH_CHARS = 4096
    private const val MAX_SYMLINK_TARGET_BYTES = 4096
    private const val ZIP_STAMP_FILE = ".zipsize"

    private data class Spec(val name: String, val zipSo: String, val exeSo: String)

    private val SPECS = listOf(
        Spec("ffmpeg", "libffmpeg.zip.so", "libffmpeg.so"),
        Spec("deno", "libdeno.zip.so", "libdeno.so"),
        Spec("node", "libnode.zip.so", "libnode.so"),
    )

    /**
     * Extract support trees and resolve executables. Safe to call on every
     * `paths/set`: a cache hit requires archive and extracted-tree SHA-256
     * verification; a mismatch triggers a fresh atomic extraction. Call off
     * the main thread (does file I/O + version probes).
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

    private data class Stamp(
        val length: Long,
        val mtime: Long,
        val archiveSha256: String,
        val treeSha256: String,
    )

    private enum class ZipEntryKind { DIRECTORY, FILE, SYMLINK }
    private data class ValidatedZipEntry(
        val entry: org.apache.commons.compress.archivers.zip.ZipArchiveEntry,
        val output: File,
        val kind: ZipEntryKind,
    )

    private fun readStamp(file: File): Stamp? {
        return try {
            val stat = android.system.Os.lstat(file.absolutePath)
            if (!android.system.OsConstants.S_ISREG(stat.st_mode) || stat.st_size > 1024L) return null
            val lines = file.readLines()
            if (lines.isEmpty() || lines[0].trim() != "v5-sha256-tree-atomic") return null
            val map = lines.drop(1).associate {
                val parts = it.split("=", limit = 2)
                parts[0].trim() to parts.getOrNull(1)?.trim()
            }
            val len = map["length"]?.toLongOrNull() ?: return null
            val mtime = map["mtime"]?.toLongOrNull() ?: return null
            val archiveHash = map["archive_sha256"]?.lowercase() ?: return null
            val treeHash = map["tree_sha256"]?.lowercase() ?: return null
            val hashPattern = Regex("[0-9a-f]{64}")
            if (!archiveHash.matches(hashPattern) || !treeHash.matches(hashPattern)) return null
            Stamp(len, mtime, archiveHash, treeHash)
        } catch (_: Exception) {
            null
        }
    }

    private fun writeStamp(file: File, stamp: Stamp) {
        try {
            val existing = android.system.Os.lstat(file.absolutePath)
            check(android.system.OsConstants.S_ISREG(existing.st_mode)) {
                "Package stamp is not a regular file: ${file.absolutePath}"
            }
        } catch (e: android.system.ErrnoException) {
            if (e.errno != android.system.OsConstants.ENOENT) throw e
        }
        file.writeText(
            "v5-sha256-tree-atomic\nlength=${stamp.length}\nmtime=${stamp.mtime}" +
                "\narchive_sha256=${stamp.archiveSha256}\ntree_sha256=${stamp.treeSha256}\n",
        )
    }

    private fun computeSha256(file: File): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(65536)
        file.inputStream().use { input ->
            var n: Int
            while (input.read(buf).also { n = it } != -1) digest.update(buf, 0, n)
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    /** Hash the extracted tree without following symlinks; omit the root stamp. */
    private fun computeTreeSha256(root: File): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val rootPath = root.canonicalFile.path
        val rootPrefix = root.absolutePath.trimEnd(File.separatorChar) + File.separator
        fun field(value: String) {
            val bytes = value.toByteArray(Charsets.UTF_8)
            digest.update(java.nio.ByteBuffer.allocate(4).putInt(bytes.size).array())
            digest.update(bytes)
        }
        fun visit(directory: File) {
            val children = directory.listFiles()
                ?: throw IllegalStateException("Cannot list package directory: ${directory.absolutePath}")
            for (entry in children.sortedBy { it.name }) {
                if (directory.canonicalFile.path == rootPath && entry.name == ZIP_STAMP_FILE) continue
                val stat = android.system.Os.lstat(entry.absolutePath)
                val absolutePath = entry.absolutePath
                check(absolutePath.startsWith(rootPrefix)) {
                    "Package tree entry escaped root: $absolutePath"
                }
                val relative = absolutePath.removePrefix(rootPrefix)
                check(relative.isNotBlank()) { "Package tree entry escaped root: $absolutePath" }
                val executableMask = android.system.OsConstants.S_IXUSR or
                    android.system.OsConstants.S_IXGRP or android.system.OsConstants.S_IXOTH
                val executable = (stat.st_mode and executableMask) != 0
                field(relative)
                when {
                    android.system.OsConstants.S_ISDIR(stat.st_mode) -> {
                        field("directory")
                        field(if (executable) "x" else "-")
                        visit(entry)
                    }
                    android.system.OsConstants.S_ISLNK(stat.st_mode) -> {
                        field("symlink")
                        field("")
                        field(android.system.Os.readlink(entry.absolutePath))
                    }
                    android.system.OsConstants.S_ISREG(stat.st_mode) -> {
                        field("file")
                        field(if (executable) "x" else "-")
                        field(stat.st_size.toString())
                        entry.inputStream().use { input ->
                            val buffer = ByteArray(65536)
                            var total = 0L
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                digest.update(buffer, 0, count)
                                total += count
                            }
                            check(total == stat.st_size) { "Package file changed while hashing: $absolutePath" }
                        }
                    }
                    else -> throw IllegalStateException("Unsupported package entry type: $absolutePath")
                }
            }
        }
        val rootStat = android.system.Os.lstat(root.absolutePath)
        check(android.system.OsConstants.S_ISDIR(rootStat.st_mode)) {
            "Package root is not a real directory: ${root.absolutePath}"
        }
        visit(root)
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun deleteEntryNoFollow(file: File) {
        val stat = try {
            android.system.Os.lstat(file.absolutePath)
        } catch (e: android.system.ErrnoException) {
            if (e.errno == android.system.OsConstants.ENOENT) return
            throw e
        }
        if (android.system.OsConstants.S_ISDIR(stat.st_mode)) {
            val children = file.listFiles()
                ?: throw IllegalStateException("Cannot list directory for cleanup: ${file.absolutePath}")
            children.forEach { deleteEntryNoFollow(it) }
            android.system.Os.rmdir(file.absolutePath)
        } else {
            android.system.Os.remove(file.absolutePath)
        }
    }

    private fun safeDeleteEntry(file: File) = deleteEntryNoFollow(file)

    private fun markExecutableNoFollow(root: File) {
        val mask = android.system.OsConstants.S_IXUSR or android.system.OsConstants.S_IXGRP or
            android.system.OsConstants.S_IXOTH
        fun mark(file: File, mode: Int) {
            if ((mode and mask) == 0 && !file.setExecutable(true, false)) {
                throw IllegalStateException("Cannot mark package entry executable: ${file.absolutePath}")
            }
        }
        fun visit(directory: File) {
            val dirStat = android.system.Os.lstat(directory.absolutePath)
            check(android.system.OsConstants.S_ISDIR(dirStat.st_mode)) {
                "Package directory is not a real directory: ${directory.absolutePath}"
            }
            mark(directory, dirStat.st_mode)
            val children = directory.listFiles()
                ?: throw IllegalStateException("Cannot list package directory: ${directory.absolutePath}")
            for (child in children.sortedBy { it.name }) {
                val stat = android.system.Os.lstat(child.absolutePath)
                when {
                    android.system.OsConstants.S_ISDIR(stat.st_mode) -> visit(child)
                    android.system.OsConstants.S_ISREG(stat.st_mode) -> mark(child, stat.st_mode)
                    android.system.OsConstants.S_ISLNK(stat.st_mode) -> Unit
                    else -> throw IllegalStateException("Unsupported package entry type: ${child.absolutePath}")
                }
            }
        }
        visit(root)
    }

    private fun recoverIncompleteSwap(packagesDir: File, name: String) {
        val target = File(packagesDir, name)
        val tmp = File(packagesDir, "$name.tmp")
        val backup = File(packagesDir, "$name.bak")

        if (!target.exists()) {
            if (tmp.exists() && File(tmp, ZIP_STAMP_FILE).isFile) {
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

        val marker = File(target, ZIP_STAMP_FILE)
        val currentStamp = readStamp(marker)

        val zipLength = zipSo.length()
        val zipMtime = zipSo.lastModified()

        // Metadata is only a quick reject hint, never the integrity proof.
        if (target.isDirectory && currentStamp != null) {
            val actualArchiveSha256 = computeSha256(zipSo)
            val actualTreeSha256 = computeTreeSha256(target)
            if (currentStamp.length == zipLength &&
                currentStamp.archiveSha256 == actualArchiveSha256 &&
                currentStamp.treeSha256 == actualTreeSha256
            ) {
                if (currentStamp.mtime != zipMtime) writeStamp(marker, currentStamp.copy(mtime = zipMtime))
                return
            }
        }

        // Three-way atomic swap: extract into tmp, swap target -> backup, tmp -> target, delete backup.
        if (!packagesDir.isDirectory && !packagesDir.mkdirs()) {
            throw IllegalStateException("Cannot create package directory: ${packagesDir.absolutePath}")
        }
        val tmp = File(packagesDir, "${target.name}.tmp")
        val backup = File(packagesDir, "${target.name}.bak")
        deleteEntryNoFollow(tmp)
        deleteEntryNoFollow(backup)
        check(tmp.mkdir()) { "Cannot create clean staging directory: ${tmp.absolutePath}" }
        check(android.system.OsConstants.S_ISDIR(android.system.Os.lstat(tmp.absolutePath).st_mode)) {
            "Staging path is not a real directory: ${tmp.absolutePath}"
        }

        val archiveSha256 = try {
            extractZipTo(zipSo, tmp)
        } catch (e: Exception) {
            deleteQuietly(tmp)
            throw e
        }

        markExecutableNoFollow(tmp)
        val treeSha256 = computeTreeSha256(tmp)
        val newStamp = Stamp(zipLength, zipMtime, archiveSha256, treeSha256)
        writeStamp(File(tmp, ZIP_STAMP_FILE), newStamp)

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

        Log.i(
            TAG,
            "extracted ${zipSo.name} -> ${target.absolutePath} " +
                "(archive SHA-256: $archiveSha256, tree SHA-256: $treeSha256)",
        )
    }

    private fun validateZipEntries(
        entries: List<org.apache.commons.compress.archivers.zip.ZipArchiveEntry>,
        target: File,
    ): List<ValidatedZipEntry> {
        val rootPath = target.canonicalFile.path
        val byPath = linkedMapOf<String, ValidatedZipEntry>()
        val validated = ArrayList<ValidatedZipEntry>(entries.size)
        for (entry in entries) {
            val raw = entry.name
            check(raw.length <= MAX_ZIP_PATH_CHARS) { "Zip entry path is too long" }
            check(raw.isNotBlank() && '\u0000' !in raw && '\\' !in raw && ':' !in raw) {
                "Invalid zip entry path: $raw"
            }
            check(!raw.startsWith("/") && !raw.matches(Regex("^[A-Za-z]:.*"))) {
                "Absolute zip entry path forbidden: $raw"
            }
            val pathName = if (entry.isDirectory) raw.removeSuffix("/") else raw
            check(pathName.isNotBlank()) { "Zip entry may not name package root" }
            val segments = pathName.split('/')
            check(segments.none { it.isEmpty() || it == "." || it == ".." }) {
                "Unsafe zip entry path: $raw"
            }
            check(segments.first() != ZIP_STAMP_FILE) { "Reserved package metadata path: $raw" }
            val output = File(target, pathName).canonicalFile
            check(output.path.startsWith(rootPath + File.separator) && output.path != rootPath) {
                "Zip entry escapes package directory: $raw"
            }
            val kind = when {
                entry.isUnixSymlink -> ZipEntryKind.SYMLINK
                entry.isDirectory -> ZipEntryKind.DIRECTORY
                else -> ZipEntryKind.FILE
            }
            val record = ValidatedZipEntry(entry, output, kind)
            check(byPath.put(output.path, record) == null) { "Duplicate or colliding zip entry path: $raw" }
            validated.add(record)
        }
        for (record in validated) {
            var parent = record.output.parentFile?.canonicalFile
            while (parent != null && parent.path != rootPath) {
                check(parent.path.startsWith(rootPath + File.separator)) {
                    "Zip entry parent escapes package directory: ${record.entry.name}"
                }
                val ancestor = byPath[parent.path]
                if (ancestor != null) {
                    check(ancestor.kind == ZipEntryKind.DIRECTORY) {
                        "Non-directory zip entry is an ancestor of ${record.entry.name}: ${ancestor.entry.name}"
                    }
                }
                parent = parent.parentFile
            }
        }
        return validated
    }

    private fun extractZipTo(zipSo: File, target: File): String {
        val buf = ByteArray(65536)
        org.apache.commons.compress.archivers.zip.ZipFile(zipSo).use { zip ->
            val archiveEntries = mutableListOf<org.apache.commons.compress.archivers.zip.ZipArchiveEntry>()
            val iterator = zip.entries
            while (iterator.hasMoreElements()) archiveEntries.add(iterator.nextElement())
            val validated = validateZipEntries(archiveEntries, target)
            for (record in validated) {
                val entry = record.entry
                val out = record.output
                when (record.kind) {
                    ZipEntryKind.DIRECTORY -> check(out.isDirectory || out.mkdirs()) {
                        "Could not create directory for zip entry: ${entry.name}"
                    }
                    ZipEntryKind.SYMLINK -> {
                        out.parentFile?.mkdirs()
                        val linkBytes = java.io.ByteArrayOutputStream().use { sink ->
                            zip.getInputStream(entry).use { input ->
                                val targetBuffer = ByteArray(512)
                                var total = 0
                                while (true) {
                                    val count = input.read(targetBuffer)
                                    if (count < 0) break
                                    total += count
                                    check(total <= MAX_SYMLINK_TARGET_BYTES) {
                                        "Symlink target is too long in ${entry.name}"
                                    }
                                    sink.write(targetBuffer, 0, count)
                                }
                            }
                            sink.toByteArray()
                        }
                        val linkTarget = String(linkBytes, Charsets.UTF_8).trim()
                        check(linkTarget.isNotEmpty()) { "Empty symlink target in ${entry.name}" }
                        check(
                            !linkTarget.startsWith("/") && '\\' !in linkTarget &&
                                '\u0000' !in linkTarget && ':' !in linkTarget,
                        ) { "Absolute or invalid symlink target forbidden: ${entry.name} -> $linkTarget" }
                        val resolvedTarget = File(out.parentFile, linkTarget).canonicalPath
                        check(resolvedTarget.startsWith(target.canonicalPath + File.separator)) {
                            "Symlink target escapes package directory: ${entry.name} -> $linkTarget"
                        }
                        safeDeleteEntry(out)
                        android.system.Os.symlink(linkTarget, out.absolutePath)
                    }
                    ZipEntryKind.FILE -> {
                        out.parentFile?.mkdirs()
                        safeDeleteEntry(out)
                        zip.getInputStream(entry).use { input ->
                            out.outputStream().use { output ->
                                var n: Int
                                while (input.read(buf).also { n = it } != -1) output.write(buf, 0, n)
                            }
                        }
                    }
                }
            }
        }
        return computeSha256(zipSo)
    }

    private fun deleteQuietly(file: File) {
        try {
            deleteEntryNoFollow(file)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to remove ${file.absolutePath}: ${e.message}")
        }
    }
}
