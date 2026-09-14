"""Unit tests for scheduler poll helpers."""

from grablytic_engine.scheduler_check import (
    diff_new_entries,
    flat_entries_to_ids,
    flat_entry_video_id,
    parse_youtube_rss,
)


def test_flat_entry_video_id_invalid_inputs():
    assert flat_entry_video_id(None) is None
    assert flat_entry_video_id("not-a-dict") is None
    assert flat_entry_video_id({}) is None
    assert flat_entry_video_id({"title": "Valid", "url": ""}) is None


def test_flat_entry_video_id_skips_unavailable():
    assert flat_entry_video_id({"title": "[Deleted video]", "url": "dQw4w9WgXcQ"}) is None
    assert flat_entry_video_id({"title": "[Private video]", "url": "dQw4w9WgXcQ"}) is None
    assert flat_entry_video_id({"title": None, "url": "dQw4w9WgXcQ"}) is None
    assert flat_entry_video_id({"title": "Secret", "availability": "private", "url": "dQw4w9WgXcQ"}) is None


def test_flat_entry_video_id_valid_formats():
    vid = "dQw4w9WgXcQ"
    # Bare 11-char ID
    assert flat_entry_video_id({"title": "Never Gonna Give You Up", "url": vid}) == vid
    # Watch URL
    assert flat_entry_video_id({"title": "Song", "url": f"https://www.youtube.com/watch?v={vid}"}) == vid
    # youtu.be URL
    assert flat_entry_video_id({"title": "Song", "url": f"https://youtu.be/{vid}"}) == vid
    # webpage_url fallback
    assert flat_entry_video_id({"title": "Song", "webpage_url": f"https://www.youtube.com/watch?v={vid}"}) == vid


def test_flat_entry_video_id_rejects_non_youtube():
    assert flat_entry_video_id({"title": "Other", "url": "https://vimeo.com/123456"}) is None
    assert flat_entry_video_id({"title": "Other", "url": "not a url or id"}) is None


def test_flat_entries_to_ids():
    entries = [
        {"title": "[Deleted video]", "url": "del12345678"},
        {"title": "Video 1", "url": "vid11111111"},
        {"title": "Video 2", "url": "https://www.youtube.com/watch?v=vid22222222"},
        {"title": "Video 1 duplicate", "url": "vid11111111"},
        {"title": "Bad", "url": "short"},
    ]
    res = flat_entries_to_ids(entries)
    assert len(res) == 2
    assert res[0] == {
        "id": "vid11111111",
        "url": "https://www.youtube.com/watch?v=vid11111111",
        "title": "Video 1",
    }
    assert res[1] == {
        "id": "vid22222222",
        "url": "https://www.youtube.com/watch?v=vid22222222",
        "title": "Video 2",
    }


def test_parse_youtube_rss_malformed():
    assert parse_youtube_rss("") == []
    assert parse_youtube_rss("   ") == []
    assert parse_youtube_rss(None) == []
    assert parse_youtube_rss("<not>valid<xml") == []
    assert parse_youtube_rss("<feed><title>No entries</title></feed>") == []


def test_parse_youtube_rss_valid_atom():
    sample_xml = """<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">
  <title>Test Channel</title>
  <entry>
    <id>yt:video:dQw4w9WgXcQ</id>
    <yt:videoId>dQw4w9WgXcQ</yt:videoId>
    <title>Never Gonna Give You Up</title>
    <link rel="alternate" href="https://www.youtube.com/watch?v=dQw4w9WgXcQ"/>
    <published>2009-10-25T06:57:33+00:00</published>
  </entry>
  <entry>
    <id>yt:video:9bZkp7q19f0</id>
    <yt:videoId>9bZkp7q19f0</yt:videoId>
    <title>Gangnam Style</title>
    <link rel="alternate" href="https://www.youtube.com/watch?v=9bZkp7q19f0"/>
    <published>2012-07-15T07:46:32+00:00</published>
  </entry>
</feed>"""
    entries = parse_youtube_rss(sample_xml)
    assert len(entries) == 2
    assert entries[0]["id"] == "dQw4w9WgXcQ"
    assert entries[0]["title"] == "Never Gonna Give You Up"
    assert entries[0]["url"] == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    assert entries[0]["published"] == "2009-10-25T06:57:33+00:00"

    assert entries[1]["id"] == "9bZkp7q19f0"
    assert entries[1]["title"] == "Gangnam Style"


def test_diff_new_entries():
    entries = [
        {"id": "vid1", "title": "One"},
        {"id": "vid2", "title": "Two"},
        {"id": "vid3", "title": "Three"},
        {"id": "vid1", "title": "One Dup"},
    ]
    seen = {"vid1"}
    diff = diff_new_entries(entries, seen)
    assert len(diff) == 2
    assert diff[0]["id"] == "vid2"
    assert diff[1]["id"] == "vid3"
