"""T08: Tests for in-app preview stream selection in get_formats.

Ensures:
1. get_formats selects the best progressive (muxed) MP4 <= 480p from single extraction.
2. Original HTTP headers and cookies are preserved.
3. DASH/HLS segments and video > 480p are rejected.
4. If no eligible progressive stream exists, preview_stream is None.
"""

from grablytic_engine.formats import get_formats
import grablytic_engine.formats as fmt_mod


class TestPreviewStreamSelection:
    def test_selects_best_progressive_mp4_under_480p(self, monkeypatch):
        formats_data = [
            # 1080p video-only (DASH)
            {"format_id": "137", "vcodec": "avc1", "acodec": "none", "height": 1080, "ext": "mp4", "url": "https://cdn.example.com/1080p.mp4"},
            # 1080p muxed MP4 (>480p, should be skipped for preview)
            {"format_id": "22_1080", "vcodec": "avc1", "acodec": "mp4a", "height": 1080, "ext": "mp4", "url": "https://cdn.example.com/muxed1080.mp4"},
            # 720p muxed MP4 (>480p, should be skipped for preview)
            {"format_id": "22", "vcodec": "avc1", "acodec": "mp4a", "height": 720, "ext": "mp4", "url": "https://cdn.example.com/muxed720.mp4"},
            # 480p muxed MP4 (valid candidate, higher quality than 360p)
            {"format_id": "35", "vcodec": "avc1", "acodec": "mp4a", "height": 480, "ext": "mp4", "url": "https://cdn.example.com/muxed480.mp4", "http_headers": {"X-Candidate": "1"}},
            # 360p muxed MP4 (format 18, valid candidate)
            {"format_id": "18", "vcodec": "avc1", "acodec": "mp4a", "height": 360, "ext": "mp4", "url": "https://cdn.example.com/muxed360.mp4"},
            # Audio-only
            {"format_id": "140", "vcodec": "none", "acodec": "mp4a", "ext": "m4a", "url": "https://cdn.example.com/audio.m4a"},
        ]

        class MockYDL:
            def __init__(self, opts):
                pass
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def extract_info(self, url, download=False):
                return {
                    "id": "vid123",
                    "title": "Test Video",
                    "formats": formats_data,
                    "http_headers": {"User-Agent": "MockUA/1.0", "Referer": "https://example.com"},
                }

        monkeypatch.setattr(fmt_mod, "YoutubeDL", MockYDL)

        res = get_formats("https://example.com/watch?v=vid123")
        assert res["success"] is True
        preview = res["preview_stream"]
        assert preview is not None
        assert preview["format_id"] == "35"
        assert preview["height"] == 480
        assert preview["url"] == "https://cdn.example.com/muxed480.mp4"
        assert preview["headers"]["User-Agent"] == "MockUA/1.0"
        assert preview["headers"]["X-Candidate"] == "1"

    def test_ignores_dash_and_hls_protocols(self, monkeypatch):
        formats_data = [
            # 360p muxed but m3u8 protocol
            {"format_id": "hls-360", "vcodec": "avc1", "acodec": "mp4a", "height": 360, "ext": "mp4", "protocol": "m3u8_native", "url": "https://cdn.example.com/master.m3u8"},
            # 360p muxed but dash protocol
            {"format_id": "dash-360", "vcodec": "avc1", "acodec": "mp4a", "height": 360, "ext": "mp4", "protocol": "http_dash_segments", "url": "https://cdn.example.com/manifest.mpd"},
        ]

        class MockYDL:
            def __init__(self, opts):
                pass
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def extract_info(self, url, download=False):
                return {
                    "id": "vid_dash_only",
                    "title": "Dash Only",
                    "formats": formats_data,
                }

        monkeypatch.setattr(fmt_mod, "YoutubeDL", MockYDL)

        res = get_formats("https://example.com/watch?v=vid_dash_only")
        assert res["success"] is True
        assert res["preview_stream"] is None

    def test_audio_only_returns_none_preview(self, monkeypatch):
        formats_data = [
            {"format_id": "audio-opus", "vcodec": "none", "acodec": "opus", "ext": "webm", "url": "https://cdn.example.com/opus"},
            {"format_id": "audio-m4a", "vcodec": "none", "acodec": "mp4a", "ext": "m4a", "url": "https://cdn.example.com/m4a"},
        ]

        class MockYDL:
            def __init__(self, opts):
                pass
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def extract_info(self, url, download=False):
                return {
                    "id": "audio_track",
                    "title": "Audio Track",
                    "formats": formats_data,
                }

        monkeypatch.setattr(fmt_mod, "YoutubeDL", MockYDL)

        res = get_formats("https://example.com/track/123")
        assert res["success"] is True
        assert res["preview_stream"] is None
