package com.theonly.grablytic

import java.net.URI
import java.net.URISyntaxException

/**
 * The one place that decides whether tier 1 of the observed-sources poll may
 * open a socket, and to where (SEC-002).
 *
 * Tier 1 fetches a YouTube Atom feed directly from Kotlin, in the host process,
 * so none of the engine's `url_guard` runs on it. The old code accepted any
 * configured string containing `/feeds/videos.xml` and passed it to `URL(...)`,
 * which meant a source URL of `http://127.0.0.1:8080/feeds/videos.xml` — or the
 * user's router, or a metadata endpoint — was fetched from a background worker
 * that retries on every poll.
 *
 * The policy parses instead of pattern-matching, because a whole-URL regex has
 * to re-solve userinfo, port, percent-encoding and case folding, and Android's
 * own guidance is that regex is the wrong tool for host validation. What comes
 * back is a URL **built here** from validated parts, never the caller's string,
 * so nothing parsed-but-unchecked can reach the socket.
 */
internal object YouTubeFeedUrl {
    /** The only host tier 1 talks to; `youtube.com` is rewritten to this. */
    const val FEED_HOST = "www.youtube.com"

    /** Matches the whole path. `/feeds/videos.xml/` and `/feeds/videos.xml.x` do not. */
    private const val FEED_PATH = "/feeds/videos.xml"

    /**
     * Long enough for any real channel or playlist URL, short enough that a
     * pathological string cannot make `URI` or the regexes work hard.
     */
    private const val MAX_SOURCE_LENGTH = 2048

    /**
     * Exact host names, not suffixes. `endsWith("youtube.com")` would accept
     * `evil-youtube.com` and `youtube.com.evil.example`; set membership does not.
     */
    private val ALLOWED_HOSTS = setOf(FEED_HOST, "youtube.com")

    private val CHANNEL_IN_PATH = Regex("""channel/(UC[A-Za-z0-9_-]{22})""")
    private val CHANNEL_IN_QUERY = Regex("""[?&](?:channel_id|channel)=(UC[A-Za-z0-9_-]{22})""")

    /**
     * A feed query is exactly one accepted parameter with a URL-safe value: no
     * `&` (so no smuggled parameters), no `%` (so no encoding tricks), no
     * fragment. `channel_id` is checked against the UC form by the caller.
     */
    private val FEED_PARAM = Regex("""^(channel_id|playlist_id|user)=([A-Za-z0-9._~-]{1,128})$""")

    private val CHANNEL_ID_VALUE = Regex("""^UC[A-Za-z0-9_-]{22}$""")

    /**
     * Returns the `https://www.youtube.com/feeds/videos.xml…` URL to fetch, or
     * `null` when [sourceUrl] is not a YouTube channel or feed.
     *
     * A channel id may come from anywhere in the string — the URL is
     * constructed here from the captured 24 characters, so the source of the
     * match cannot influence the destination.
     */
    fun feedUrlFor(sourceUrl: String): String? {
        val trimmed = sourceUrl.trim()
        if (trimmed.isEmpty() || trimmed.length > MAX_SOURCE_LENGTH) return null

        val channelId = (CHANNEL_IN_PATH.find(trimmed) ?: CHANNEL_IN_QUERY.find(trimmed))
            ?.groupValues?.get(1)
        if (channelId != null) {
            return "https://$FEED_HOST$FEED_PATH?channel_id=$channelId"
        }
        return explicitFeedUrl(trimmed)
    }

    /** A URL the user pasted as a feed rather than as a channel. */
    private fun explicitFeedUrl(raw: String): String? {
        val uri = try {
            URI(raw)
        } catch (_: URISyntaxException) {
            return null
        }

        // Scheme first: without it, `file:`, `content:` and `javascript:` all
        // reach the next checks looking like relative paths.
        if (uri.scheme?.lowercase() != "https") return null
        // `https://youtube.com@127.0.0.1/…` puts the real host after the `@`.
        if (uri.rawUserInfo != null) return null
        if (uri.rawFragment != null) return null
        val port = uri.port
        if (port != -1 && port != 443) return null

        // getHost() returns null for authorities it considers illegal, which is
        // a rejection, not an invitation to fall back to the raw string.
        val host = uri.host?.lowercase() ?: return null
        if (host !in ALLOWED_HOSTS) return null
        if (uri.rawPath != FEED_PATH) return null

        val queryMatch = FEED_PARAM.matchEntire(uri.rawQuery ?: return null) ?: return null
        val name = queryMatch.groupValues[1]
        val value = queryMatch.groupValues[2]
        if (name == "channel_id" && !CHANNEL_ID_VALUE.matches(value)) return null

        // Rebuilt from the validated parts, so the apex host becomes `www` (the
        // canonical feed host) and no redirect is needed for the normal path.
        return "https://$FEED_HOST$FEED_PATH?$name=$value"
    }
}
