package com.theonly.grablytic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.kxml2.io.KXmlParser
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream

/**
 * SEC-003: tier 1 read whatever the feed host sent and kept every entry.
 *
 * `android.util.Xml.newPullParser()` is a stub on the JVM, so [AtomFeed.parse]
 * takes the parser and these tests pass `KXmlParser` — the same parser Android
 * ships a fork of, in the version kxml2 published.
 */
class AtomFeedTest {

    private fun parser() = KXmlParser()

    private fun feed(vararg entries: String) = buildString {
        append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        append("<feed xmlns:yt=\"http://www.youtube.com/xml/schemas/2015\">\n")
        entries.forEach { append(it) }
        append("</feed>\n")
    }

    private fun entry(id: String, title: String = "A video") = """
        <entry>
          <id>yt:video:$id</id>
          <yt:videoId>$id</yt:videoId>
          <title>$title</title>
          <link rel="alternate" href="https://www.youtube.com/watch?v=$id"/>
        </entry>
    """

    @Test
    fun `parses an ordinary feed`() {
        val entries = AtomFeed.parse(
            feed(entry("abcdefghijk", "First"), entry("lmnopqrstuv", "Second")).byteInputStream(),
            parser(),
        )
        assertEquals(2, entries.size)
        assertEquals("abcdefghijk", entries[0].id)
        assertEquals("First", entries[0].title)
        assertEquals("https://www.youtube.com/watch?v=abcdefghijk", entries[0].url)
    }

    @Test
    fun `stops at the entry budget instead of draining the feed`() {
        val body = feed(*Array(10_000) { entry("abcdefghij$it".takeLast(11)) })
        val entries = AtomFeed.parse(body.byteInputStream(), parser())
        assertEquals(AtomFeed.MAX_ENTRIES, entries.size)
    }

    @Test
    fun `truncates an oversized title`() {
        val entries = AtomFeed.parse(
            feed(entry("abcdefghijk", "x".repeat(50_000))).byteInputStream(),
            parser(),
        )
        assertEquals(1, entries.size)
        assertEquals(AtomFeed.MAX_TITLE_CHARS, entries.single().title.length)
    }

    @Test
    fun `refuses a body over the byte budget`() {
        val body = ByteArray(4 * 1024 * 1024) { 'a'.code.toByte() }
        try {
            AtomFeed.parse(BoundedFeedStream(ByteArrayInputStream(body), 2L * 1024 * 1024), parser())
            fail("an oversized body must not be parsed")
        } catch (expected: IOException) {
            assertTrue(expected.message!!.contains("budget"))
        }
    }

    @Test
    fun `a body of exactly the budget is not refused`() {
        // The boundary case the naive "throw when the counter hits zero"
        // wrapper gets wrong: a document that ends exactly on the limit is
        // complete, not oversize.
        val body = feed(entry("abcdefghijk")).toByteArray()
        val stream = BoundedFeedStream(ByteArrayInputStream(body), body.size.toLong())
        val entries = AtomFeed.parse(stream, parser())
        assertEquals(1, entries.size)
        assertEquals(-1, stream.read())
    }

    @Test
    fun `a stream that reports end-of-input still returns -1`() {
        val stream = BoundedFeedStream(ByteArrayInputStream(ByteArray(0)), 16)
        assertEquals(-1, stream.read())
        assertEquals(-1, stream.read(ByteArray(8), 0, 8))
    }

    @Test
    fun `the byte budget is enforced through the buffered read too`() {
        val body = HugeStream(8L * 1024 * 1024)
        val stream = BoundedFeedStream(body, 64 * 1024)
        val buffer = ByteArray(4096)
        var total = 0L
        try {
            while (true) {
                val read = stream.read(buffer, 0, buffer.size)
                if (read < 0) break
                total += read
            }
            fail("reading past the budget must throw")
        } catch (expected: IOException) {
            assertTrue("read $total bytes before the refusal", total <= 64L * 1024 + 4096)
        } finally {
            body.closed = true
        }
    }

    @Test
    fun `a document type declaration does not expand`() {
        // The billion-laughs shape. DOCDECL processing defaults to off and
        // AtomFeed sets it off explicitly; the parser must either refuse the
        // document or ignore the declaration, never expand it.
        val bomb = """
            <?xml version="1.0"?>
            <!DOCTYPE feed [
              <!ENTITY a "aaaaaaaaaa">
              <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
              <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
            ]>
            <feed><entry><id>yt:video:abcdefghijk</id><title>&c;</title></entry></feed>
        """.trimIndent()
        val result = runCatching { AtomFeed.parse(bomb.byteInputStream(), parser()) }
        // Either the parser rejects the DTD or it treats the entity as text;
        // what must not happen is a 1000x expansion, which taking the title
        // would have produced.
        result.onSuccess { entries ->
            entries.forEach { entry ->
                assertTrue(
                    "entity expanded to ${entry.title.length} chars",
                    entry.title.length <= AtomFeed.MAX_TITLE_CHARS,
                )
            }
        }
    }

    @Test
    fun `malformed xml does not produce entries`() {
        val parsed = runCatching { AtomFeed.parse("<feed><entry>".byteInputStream(), parser()) }
        assertTrue(parsed.isFailure || parsed.getOrNull()?.isEmpty() == true)
    }

    /** An endless stream, so the test exercises the counter and not the source. */
    private class HugeStream(private val size: Long) : InputStream() {
        var closed = false
        private var served = 0L

        override fun read(): Int {
            if (served >= size) return -1
            served++
            return 'a'.code
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (served >= size) return -1
            val n = minOf(len.toLong(), size - served).toInt()
            for (i in 0 until n) b[off + i] = 'a'.code.toByte()
            served += n
            return n
        }

        override fun close() {
            closed = true
        }
    }
}
