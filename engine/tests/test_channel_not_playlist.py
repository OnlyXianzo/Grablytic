"""A CHANNEL is not a playlist.

`detect_playlist` used to match `channel/`, `/c/`, `/@` and `user/`, so
a channel URL was routed through the playlist picker and the engine
expanded a busy channel into every video it has ever posted.
"""

import pytest


def _pl():
    import grablytic_engine.playlist as pl_mod

    return pl_mod


@pytest.mark.unit
@pytest.mark.parametrize(
    "url",
    [
        "https://youtube.com/channel/UCxyz",
        "https://youtube.com/c/ChannelName",
        "https://youtube.com/@ChannelName",
        "https://youtube.com/user/username",
        "https://www.youtube.com/@handle/videos",
    ],
)
def test_channel_urls_are_detected(url):
    assert _pl().detect_channel(url) is True


@pytest.mark.unit
@pytest.mark.parametrize(
    "url",
    [
        "https://youtube.com/channel/UCxyz",
        "https://youtube.com/c/ChannelName",
        "https://youtube.com/@ChannelName",
        "https://youtube.com/user/username",
    ],
)
def test_channel_urls_are_not_playlists(url):
    assert _pl().detect_playlist(url) is False


@pytest.mark.unit
@pytest.mark.parametrize(
    "url",
    [
        "https://youtube.com/watch?v=abc&list=PLxyz",
        "https://youtube.com/playlist?list=PLxyz",
        "https://example.com/sets/abc",
    ],
)
def test_real_playlists_are_still_playlists(url):
    assert _pl().detect_playlist(url) is True
    assert _pl().detect_channel(url) is False


@pytest.mark.unit
def test_watch_urls_are_neither():
    assert _pl().detect_playlist("https://youtube.com/watch?v=x") is False
    assert _pl().detect_channel("https://youtube.com/watch?v=x") is False


@pytest.mark.unit
def test_non_string_urls_are_safe():
    assert _pl().detect_playlist(None) is False
    assert _pl().detect_channel(None) is False
    assert _pl().detect_playlist(123) is False


@pytest.mark.unit
def test_a_channel_downloads_one_video_by_default():
    """The engine must not expand a channel unless asked to."""
    from grablytic_engine.opts_builder import build_ydl_opts

    opts = build_ydl_opts(url="https://youtube.com/@ChannelName")
    assert opts.get("noplaylist") is True


@pytest.mark.unit
def test_expand_channel_opts_in_to_the_expansion():
    from grablytic_engine.opts_builder import build_ydl_opts

    opts = build_ydl_opts(
        config={"expand_channel": True},
        url="https://youtube.com/@ChannelName",
    )
    assert opts.get("noplaylist") is None


@pytest.mark.unit
def test_a_real_playlist_is_not_narrowed():
    from grablytic_engine.opts_builder import build_ydl_opts

    opts = build_ydl_opts(url="https://youtube.com/playlist?list=PLxyz")
    assert opts.get("noplaylist") is None


@pytest.mark.unit
def test_a_truncated_playlist_is_reported(monkeypatch):
    """A cut list must say so — a silent cut looks like the whole list."""
    import grablytic_engine.playlist as pl_mod

    class _FakeYDL:
        def __init__(self, opts):
            """The fake downloader needs no stored options."""

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        @staticmethod
        def extract_info(url, download=False):
            return {
                "title": "Big list",
                "entries": [
                    {"title": f"v{i}", "url": f"https://x.test/{i}"}
                    for i in range(pl_mod._MAX_PLAYLIST_ENTRIES + 25)
                ],
            }

    monkeypatch.setattr(pl_mod, "YoutubeDL", _FakeYDL)
    monkeypatch.setattr(pl_mod, "is_safe_media_url", lambda u: True, raising=False)
    import grablytic_engine.url_guard as ug

    monkeypatch.setattr(ug, "is_safe_media_url", lambda u: True)

    res = pl_mod.get_playlist_info("https://youtube.com/playlist?list=PLx")
    assert res.get("success") is True
    assert res.get("truncated") is True
    assert res.get("max_entries") == pl_mod._MAX_PLAYLIST_ENTRIES
    assert res.get("count") == pl_mod._MAX_PLAYLIST_ENTRIES


@pytest.mark.unit
def test_a_short_playlist_is_not_marked_truncated(monkeypatch):
    import grablytic_engine.playlist as pl_mod

    class _FakeYDL:
        def __init__(self, opts):
            """The fake downloader needs no stored options."""

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        @staticmethod
        def extract_info(url, download=False):
            return {
                "title": "Small",
                "entries": [{"title": "a", "url": "https://x.test/a"}],
            }

    monkeypatch.setattr(pl_mod, "YoutubeDL", _FakeYDL)
    import grablytic_engine.url_guard as ug

    monkeypatch.setattr(ug, "is_safe_media_url", lambda u: True)

    res = pl_mod.get_playlist_info("https://youtube.com/playlist?list=PLx")
    assert res.get("success") is True
    assert res.get("truncated") is False
