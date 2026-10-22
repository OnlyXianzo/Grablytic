package com.theonly.grablytic

import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * SEC-004: `intent/open_file` used to mint a FileProvider URI for any file it
 * was handed, and the provider is rooted at shared storage because the
 * download folder is a user choice. These tests pin the sink policy.
 *
 * Real temporary directories, not mocked paths: the whole point is that
 * canonicalisation (`..`, sibling prefixes, symlinks) is what the check rests
 * on, and that only shows up against a real filesystem.
 */
class DownloadPathGuardTest {

    private val created = mutableListOf<File>()

    private fun tempDir(prefix: String): File =
        Files.createTempDirectory("guard-$prefix").toFile().also { created += it }

    @After
    fun cleanUp() {
        created.asReversed().forEach { dir -> dir.deleteRecursively() }
    }

    @Test
    fun `a file in the download folder is openable`() {
        val root = tempDir("root")
        val file = File(root, "video.mp4").apply { writeText("x") }
        assertTrue(DownloadPathGuard.isOpenable(file, root.path))
    }

    @Test
    fun `a file in a nested download folder is openable`() {
        val root = tempDir("root")
        val nested = File(root, "Video").apply { mkdirs() }
        val file = File(nested, "video.mp4").apply { writeText("x") }
        assertTrue(DownloadPathGuard.isOpenable(file, root.path))
    }

    @Test
    fun `a sibling folder sharing the name prefix is refused`() {
        val parent = tempDir("parent")
        val root = File(parent, "Download").apply { mkdirs() }
        val sibling = File(parent, "Download-old").apply { mkdirs() }
        val file = File(sibling, "secret.mp4").apply { writeText("x") }
        assertFalse(DownloadPathGuard.isOpenable(file, root.path))
    }

    @Test
    fun `a dot dot escape is refused`() {
        val parent = tempDir("parent")
        val root = File(parent, "Download").apply { mkdirs() }
        File(parent, "outside.mp4").writeText("x")
        // The string looks like it is inside the root; canonicalisation is
        // what disproves it.
        val escaped = File("${root.path}/../outside.mp4")
        assertFalse(DownloadPathGuard.isOpenable(escaped, root.path))
    }

    @Test
    fun `an unrelated absolute path is refused`() {
        val root = tempDir("root")
        val elsewhere = tempDir("elsewhere")
        val file = File(elsewhere, "secret.jpg").apply { writeText("x") }
        assertFalse(DownloadPathGuard.isOpenable(file, root.path))
    }

    @Test
    fun `a symlink out of the download folder is refused`() {
        val root = tempDir("root")
        val elsewhere = tempDir("elsewhere")
        val target = File(elsewhere, "secret.mp4").apply { writeText("x") }
        val link = File(root, "innocent.mp4")
        try {
            Files.createSymbolicLink(link.toPath(), target.toPath())
        } catch (_: UnsupportedOperationException) {
            return // Platform without symlink support: nothing to assert.
        } catch (_: java.io.IOException) {
            return // Same, for filesystems that refuse the call.
        }
        assertFalse(DownloadPathGuard.isOpenable(link, root.path))
    }

    @Test
    fun `an unconfigured download folder fails closed`() {
        val root = tempDir("root")
        val file = File(root, "video.mp4").apply { writeText("x") }
        assertFalse(DownloadPathGuard.isOpenable(file, null))
        assertFalse(DownloadPathGuard.isOpenable(file, ""))
        assertFalse(DownloadPathGuard.isOpenable(file, "   "))
    }

    @Test
    fun `a trailing separator in the configured folder does not break containment`() {
        val root = tempDir("root")
        val file = File(root, "video.mp4").apply { writeText("x") }
        assertTrue(DownloadPathGuard.isContained(file, File("${root.path}/")))
    }
}
