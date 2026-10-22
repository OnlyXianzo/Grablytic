package com.theonly.grablytic

import android.util.Log
import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserException
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream

/**
 * Parses the YouTube Atom feed tier 1 fetches (SEC-003).
 *
 * The old code handed the socket straight to the parser. `readTimeout` bounds
 * how long one read may block, not how much a feed may send, so a host that
 * dripped a byte every few seconds kept the worker alive indefinitely, and every
 * `<entry>` was retained until the process was killed. Bytes, entries and field
 * lengths are bounded here, and the call site cannot forget the byte bound
 * because [parseBounded] is the only entry point it uses.
 *
 * Parsing lives in its own object so it can be tested on the JVM:
 * `android.util.Xml.newPullParser()` is a stub outside an Android runtime, so
 * [parse] takes the parser and the tests pass a real `KXmlParser`.
 */
internal object AtomFeed {

    private const val TAG = "AtomFeed"

    /**
     * A 500-entry channel feed is about 1 MB; YouTube's carries 15 entries.
     * Anything past this is not a feed the app needs.
     */
    const val MAX_FEED_BYTES: Long = 2L * 1024 * 1024

    /** Retained entries. Truncating keeps the newest, which Atom lists first. */
    const val MAX_ENTRIES = 500

    /** Field caps. A title is one line; a media URL is a URL. */
    const val MAX_TITLE_CHARS = 500
    const val MAX_URL_CHARS = 2048

    /**
     * Reads at most [MAX_FEED_BYTES] from [stream], which is what the caller
     * should use. See [BoundedFeedStream] for why a cap has to be a stream.
     */
    fun parseBounded(stream: InputStream): List<SourceEntry> =
        parse(BoundedFeedStream(stream, MAX_FEED_BYTES), Xml.newPullParser())

    /**
     * Parses [stream] with [parser]. Exposed for tests; production goes through
     * [parseBounded] so the byte bound is not optional.
     */
    fun parse(stream: InputStream, parser: XmlPullParser): List<SourceEntry> {
        try {
            // A DTD is the one construct in an XML document that expands. The
            // default is already false — XMLPull: "Processing of DOCDECL is by
            // default set to false" — and setting it explicitly means a later
            // change to the parser or its factory cannot quietly turn entity
            // expansion on. A parser without the feature throws, which is not a
            // reason to fail the poll.
            parser.setFeature(XmlPullParser.FEATURE_PROCESS_DOCDECL, false)
        } catch (_: XmlPullParserException) {
            // Feature unsupported: the documented default already applies.
        } catch (_: UnsupportedOperationException) {
            // Same.
        }
        parser.setInput(stream, "UTF-8")

        val entries = mutableListOf<SourceEntry>()
        var eventType = parser.eventType
        var inEntry = false
        var currentId: String? = null
        var currentTitle: String? = null
        var currentUrl: String? = null

        while (eventType != XmlPullParser.END_DOCUMENT) {
            val tagName = parser.name
            when (eventType) {
                XmlPullParser.START_TAG -> {
                    if (tagName.equals("entry", ignoreCase = true)) {
                        inEntry = true
                        currentId = null
                        currentTitle = null
                        currentUrl = null
                    } else if (inEntry) {
                        when {
                            tagName.equals("videoId", ignoreCase = true) -> {
                                currentId = parser.nextText().trim().take(MAX_URL_CHARS)
                            }
                            tagName.equals("title", ignoreCase = true) && currentTitle == null -> {
                                currentTitle = parser.nextText().trim().take(MAX_TITLE_CHARS)
                            }
                            tagName.equals("link", ignoreCase = true) && currentUrl == null -> {
                                val href = parser.getAttributeValue(null, "href")
                                if (href != null && href.length <= MAX_URL_CHARS && href.startsWith("http")) {
                                    currentUrl = href
                                }
                            }
                            tagName.equals("id", ignoreCase = true) && currentId == null -> {
                                val idText = parser.nextText().trim()
                                val last = idText.substringAfterLast(":")
                                if (last.length == 11) {
                                    currentId = last
                                }
                            }
                        }
                    }
                }
                XmlPullParser.END_TAG -> {
                    if (tagName.equals("entry", ignoreCase = true)) {
                        if (currentId != null && currentId.length == 11) {
                            val finalUrl = currentUrl ?: "https://www.youtube.com/watch?v=$currentId"
                            entries.add(SourceEntry(currentId, finalUrl, currentTitle ?: currentId))
                        }
                        inEntry = false
                        if (entries.size >= MAX_ENTRIES) {
                            // Stop reading rather than drain a feed nobody asked
                            // for. The newest entries are the ones kept.
                            Log.w(TAG, "feed has more than $MAX_ENTRIES entries; truncating")
                            return entries
                        }
                    }
                }
            }
            eventType = parser.next()
        }
        return entries
    }
}

/**
 * An [InputStream] that fails once more than [limit] bytes have been read.
 *
 * Why a counting stream and not a header check: a hostile or broken feed sends
 * `Transfer-Encoding: chunked`, and `HttpURLConnection.contentLengthLong` is then
 * `-1`. Why throw rather than return EOF the way Guava's `ByteStreams.limit` and
 * Commons IO's `BoundedInputStream` do: a truncated Atom document is malformed
 * XML anyway, and an exception with a name is a better log line than a parse
 * error three frames away.
 *
 * At the boundary it reads one byte from the inner stream to tell "exactly at
 * the limit" from "over it", so a body of exactly [limit] bytes still parses.
 */
internal class BoundedFeedStream(
    inner: InputStream,
    private var remaining: Long,
) : FilterInputStream(inner) {

    private val limit: Long = remaining

    override fun read(): Int {
        if (remaining <= 0) return exhausted()
        val value = super.read()
        if (value >= 0) remaining--
        return value
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (remaining <= 0) return exhausted()
        val allowed = minOf(len.toLong(), remaining).toInt()
        val read = super.read(b, off, allowed)
        if (read > 0) remaining -= read
        return read
    }

    /** -1 when the body ended exactly on budget, otherwise the body is oversize. */
    private fun exhausted(): Int {
        if (super.read() < 0) return -1
        throw IOException("feed body exceeded the $limit-byte budget")
    }
}
