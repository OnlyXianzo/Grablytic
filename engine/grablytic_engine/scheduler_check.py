"""Scheduler poll helpers.

Pure functions used by the background poll path: the Kotlin
``ObservedSourcesPollWorker`` checks YouTube sources via RSS (no Python),
and falls back to Chaquopy ``extract_flat`` (``get_playlist_info``) for
non-YouTube / unresolvable URLs. This module defines that fallback's
output contract: flat entries -> stable ``(video_id, url)`` pairs the
worker diffs against its seen-IDs ledger.

Unavailable entries (``[Deleted video]`` / ``[Private video]`` / missing
title / ``availability == "private"``) never yield IDs — they cannot be
downloaded, so recording them would poison the ledger. This mirrors the
``is_available`` rule in :mod:`grablytic_engine.playlist` without
importing any worker state.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from urllib.parse import parse_qs, urlparse

_VIDEO_ID_RE = re.compile(r"^[a-zA-Z0-9_-]{11}$")


def flat_entry_video_id(entry: dict) -> str | None:
    """Best-effort stable video ID for one flat-extraction entry.

    Returns ``None`` when the entry is unavailable or carries no usable
    identifier (caller must skip it, never ledger it).
    """
    if not isinstance(entry, dict):
        return None
    title = entry.get("title")
    if title is None or title in ("[Deleted video]", "[Private video]"):
        return None
    if entry.get("availability") == "private":
        return None
    raw = entry.get("url") or entry.get("webpage_url") or ""
    if not isinstance(raw, str) or not raw:
        return None
    raw = raw.strip()
    if _VIDEO_ID_RE.match(raw):
        return raw
    if raw.startswith("http"):
        try:
            parsed = urlparse(raw)
        except ValueError:
            return None
        host = (parsed.netloc or "").lower()
        if host.endswith("youtu.be"):
            candidate = parsed.path.strip("/").split("/")[0]
            if _VIDEO_ID_RE.match(candidate):
                return candidate
            return None
        vid = parse_qs(parsed.query).get("v", [None])[0]
        if vid is not None and _VIDEO_ID_RE.match(vid):
            return vid
        return None
    return None


def flat_entries_to_ids(entries: list) -> list[dict]:
    """Map flat entries to ledger-ready ``[{id, url, title}]``.

    Skips unavailable / ID-less entries, expands bare 11-char IDs to
    canonical watch URLs (same expansion as ``get_playlist_info``),
    dedupes by ID keeping first-seen order.
    """
    out: list[dict] = []
    seen: set[str] = set()
    for entry in entries or []:
        if not isinstance(entry, dict):
            continue
        vid = flat_entry_video_id(entry)
        if vid is None or vid in seen:
            continue
        seen.add(vid)
        raw = entry.get("url") or entry.get("webpage_url") or ""
        url = raw if isinstance(raw, str) and raw.startswith("http") else f"https://www.youtube.com/watch?v={vid}"
        out.append({"id": vid, "url": url, "title": entry.get("title")})
    return out


def parse_youtube_rss(xml_content: str) -> list[dict]:
    """Parse YouTube Atom RSS feed into ledger-ready ``[{id, url, title, published}]``.

    YouTube channel RSS feeds (https://www.youtube.com/feeds/videos.xml?channel_id=...)
    use the Atom namespace (http://www.w3.org/2005/Atom) and YouTube media namespace
    (http://www.youtube.com/xml/schemas/2015).

    Returns a list of entry dicts. Malformed XML or non-string inputs safely
    return an empty list without raising.
    """
    if not isinstance(xml_content, str) or not xml_content.strip():
        return []

    try:
        root = ET.fromstring(xml_content)
    except (ET.ParseError, ValueError):
        return []

    ns = {
        "atom": "http://www.w3.org/2005/Atom",
        "yt": "http://www.youtube.com/xml/schemas/2015",
    }

    entries = []
    entry_nodes = root.findall("atom:entry", ns)
    if not entry_nodes:
        entry_nodes = root.findall("entry")

    for node in entry_nodes:
        vid_elem = node.find("yt:videoId", ns)
        vid = vid_elem.text.strip() if vid_elem is not None and vid_elem.text else None

        if not vid or not _VIDEO_ID_RE.match(vid):
            id_elem = node.find("atom:id", ns)
            if id_elem is None:
                id_elem = node.find("id")
            if id_elem is not None and id_elem.text:
                id_text = id_elem.text.strip()
                candidate = id_text.split(":")[-1]
                if _VIDEO_ID_RE.match(candidate):
                    vid = candidate

        if not vid or not _VIDEO_ID_RE.match(vid):
            continue

        title_elem = node.find("atom:title", ns)
        if title_elem is None:
            title_elem = node.find("title")
        title = title_elem.text.strip() if title_elem is not None and title_elem.text else None

        published_elem = node.find("atom:published", ns)
        if published_elem is None:
            published_elem = node.find("published")
        published = published_elem.text.strip() if published_elem is not None and published_elem.text else None

        link_elem = node.find("atom:link", ns)
        if link_elem is None:
            link_elem = node.find("link")
        link_href = link_elem.attrib.get("href") if link_elem is not None else None
        url = link_href if isinstance(link_href, str) and link_href.startswith("http") else f"https://www.youtube.com/watch?v={vid}"

        entries.append({
            "id": vid,
            "url": url,
            "title": title,
            "published": published,
        })

    return entries


def diff_new_entries(entries: list[dict], seen_ids: set[str] | list[str]) -> list[dict]:
    """Filter entries down to those whose ID is not present in seen_ids.

    Maintains order and deduplicates IDs within the entries list.
    """
    seen_set = set(seen_ids) if seen_ids else set()
    new_entries: list[dict] = []
    batch_seen: set[str] = set()

    for entry in entries or []:
        if not isinstance(entry, dict):
            continue
        vid = entry.get("id")
        if not vid or vid in seen_set or vid in batch_seen:
            continue
        batch_seen.add(vid)
        new_entries.append(entry)

    return new_entries
