package com.theonly.grablytic

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * SEC-002: tier 1 fetches a feed from Kotlin without the engine's URL guard, so
 * [YouTubeFeedUrl] is the only thing standing between a configured source and
 * a socket. These cases are the audit's hostile vectors plus the accept paths
 * that must keep working.
 */
class YouTubeFeedUrlTest {

    private val uc = "UC1234567890123456789012"

    @Test
    fun `accepts a channel feed on the canonical host`() {
        assertEquals(
            "https://www.youtube.com/feeds/videos.xml?channel_id=$uc",
            YouTubeFeedUrl.feedUrlFor("https://www.youtube.com/feeds/videos.xml?channel_id=$uc"),
        )
    }

    @Test
    fun `rewrites the apex host to the canonical feed host`() {
        assertEquals(
            "https://www.youtube.com/feeds/videos.xml?channel_id=$uc",
            YouTubeFeedUrl.feedUrlFor("https://youtube.com/feeds/videos.xml?channel_id=$uc"),
        )
    }

    @Test
    fun `accepts a playlist feed`() {
        assertEquals(
            "https://www.youtube.com/feeds/videos.xml?playlist_id=PL1234567890abcdef",
            YouTubeFeedUrl.feedUrlFor(
                "https://www.youtube.com/feeds/videos.xml?playlist_id=PL1234567890abcdef",
            ),
        )
    }

    @Test
    fun `accepts a channel page and builds the feed for it`() {
        assertEquals(
            "https://www.youtube.com/feeds/videos.xml?channel_id=$uc",
            YouTubeFeedUrl.feedUrlFor("https://www.youtube.com/channel/$uc"),
        )
        // The id is captured and the URL is built here, so a hostile host in the
        // configured string still sends the request to youtube.com.
        assertEquals(
            "https://www.youtube.com/feeds/videos.xml?channel_id=$uc",
            YouTubeFeedUrl.feedUrlFor("https://evil.example/channel/$uc"),
        )
    }

    @Test
    fun `tolerates surrounding whitespace`() {
        assertEquals(
            "https://www.youtube.com/feeds/videos.xml?channel_id=$uc",
            YouTubeFeedUrl.feedUrlFor("  https://www.youtube.com/channel/$uc  "),
        )
    }

    @Test
    fun `rejects every hostile destination the audit filed`() {
        val hostile = listOf(
            "http://www.youtube.com/feeds/videos.xml", // cleartext
            "http://127.0.0.1:8080/feeds/videos.xml", // loopback
            "http://10.0.0.5/feeds/videos.xml", // LAN
            "https://evil.example/feeds/videos.xml", // off-domain
            "https://youtube.com.evil.example/feeds/videos.xml", // suffix confusion
            "file:///data/local/tmp/feeds/videos.xml", // scheme escape
            "content://com.example/feeds/videos.xml",
            "ftp://www.youtube.com/feeds/videos.xml",
            "https://www.youtube.com@evil.example/feeds/videos.xml", // userinfo
            "https://www.youtube.com/feeds/videos.xml/",
            "https://www.youtube.com/feeds/videos.xml?hl=en",
            "https://www.youtube.com/feeds/videos.xml?channel_id=../../etc/passwd",
            "",
            "   ",
        )
        for (url in hostile) {
            assertNull("expected rejection: $url", YouTubeFeedUrl.feedUrlFor(url))
        }
    }

    /**
     * A channel id is the one thing taken from the configured string, and the
     * URL is rebuilt from those 24 characters alone. Everything else the string
     * carried — cleartext, credentials, a port, extra parameters, a fragment,
     * another host — is dropped rather than rejected, because a channel id is
     * enough to build the canonical feed and the drop cannot be exploited.
     */
    @Test
    fun `a channel id collapses to the canonical feed and drops the rest`() {
        val canonical = "https://www.youtube.com/feeds/videos.xml?channel_id=$uc"
        val carriers = listOf(
            "http://www.youtube.com/feeds/videos.xml?channel_id=$uc",
            "https://user:pw@www.youtube.com/feeds/videos.xml?channel_id=$uc",
            "https://www.youtube.com:8443/feeds/videos.xml?channel_id=$uc",
            "https://www.youtube.com/feeds/videos.xml?channel_id=$uc&x=1",
            "https://www.youtube.com/feeds/videos.xml?channel_id=$uc#fragment",
        )
        for (url in carriers) {
            assertEquals(url, canonical, YouTubeFeedUrl.feedUrlFor(url))
        }
    }

    @Test
    fun `rejects a feed with no parameter and an unknown parameter`() {
        assertNull(YouTubeFeedUrl.feedUrlFor("https://www.youtube.com/feeds/videos.xml"))
        assertNull(
            YouTubeFeedUrl.feedUrlFor("https://www.youtube.com/feeds/videos.xml?hl=en"),
        )
    }

    @Test
    fun `rejects the percent-encoded authority that hides a second host`() {
        assertNull(
            YouTubeFeedUrl.feedUrlFor(
                "https://www.youtube.com%2f@evil.example/feeds/videos.xml",
            ),
        )
    }

    @Test
    fun `does not accept a very long string`() {
        assertNull(
            YouTubeFeedUrl.feedUrlFor(
                "https://www.youtube.com/feeds/videos.xml?channel_id=" + "A".repeat(4000),
            ),
        )
    }
}
