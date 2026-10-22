package com.theonly.grablytic

import java.io.File
import java.io.IOException

/**
 * Decides whether `intent/open_file` may hand a file to another app (SEC-004).
 *
 * The FileProvider is rooted at shared storage because the download folder is
 * a runtime choice (`FilePicker.getDirectoryPath()` in Settings), so the
 * provider itself cannot be the thing that says "only our downloads". That
 * check has to happen at the sink, and it has to be a canonical-path check:
 * `..` segments, a sibling folder sharing a name prefix (`Download-old` vs
 * `Download`) and a symlink planted in the download folder all produce a
 * path that *looks* contained as a string but is not.
 *
 * `File.canonicalFile` resolves `.`/`..` and every symlink, so one comparison
 * after canonicalisation covers all three. A path that cannot be canonicalised
 * (permission denied, bad mount) is refused — this gate fails closed.
 *
 * Pure `java.io`, deliberately: no `Context`, no provider, so it is a JVM unit
 * test rather than something only an emulator can exercise.
 */
object DownloadPathGuard {

    /** `file` canonicalised, or null when the filesystem refuses to resolve it. */
    fun canonicalOrNull(file: File): File? =
        try {
            file.canonicalFile
        } catch (_: IOException) {
            null
        } catch (_: SecurityException) {
            null
        }

    /** True when [file] is [root] or inside it, after both are canonicalised. */
    fun isContained(file: File, root: File): Boolean {
        val target = canonicalOrNull(file) ?: return false
        val base = canonicalOrNull(root) ?: return false
        if (target.path == base.path) return true
        // The separator matters: "/dl-evil/x" starts with "/dl" but is not in it.
        return target.path.startsWith(base.path + File.separator)
    }

    /**
     * The `intent/open_file` policy: a real file under the configured download
     * folder, and nothing else.
     *
     * A missing folder setting fails closed. That can only happen before
     * `paths/set` configured the engine, at which point no download exists and
     * therefore no legitimate path can be waiting to be opened.
     *
     * Deliberate consequence: if the user changes the download folder, media
     * downloaded to the *old* folder is no longer openable from history. The
     * file is still on disk and still reachable from a file manager; the app
     * shares what it currently manages, not everything it once wrote.
     */
    fun isOpenable(file: File, outputDir: String?): Boolean {
        if (outputDir.isNullOrBlank()) return false
        return isContained(file, File(outputDir))
    }
}
