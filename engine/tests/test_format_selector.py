from grablytic_engine.format_selector import build_format_string


class TestBuildFormatString:
    def test_audio_only_opus(self):
        cfg = {"audio_only": True, "audio_format": "opus"}
        result = build_format_string(cfg)
        assert result == "bestaudio[ext=webm]/bestaudio"

    def test_audio_only_m4a(self):
        cfg = {"audio_only": True, "audio_format": "m4a"}
        result = build_format_string(cfg)
        assert result == "bestaudio[ext=m4a]/bestaudio"

    def test_audio_only_flac(self):
        cfg = {"audio_only": True, "audio_format": "flac"}
        result = build_format_string(cfg)
        assert "flac" in result

    def test_audio_only_mp3(self):
        cfg = {"audio_only": True, "audio_format": "mp3"}
        result = build_format_string(cfg)
        assert result == "bestaudio[ext=mp3]/bestaudio"

    def test_video_4k(self):
        cfg = {"audio_only": False, "quality_ceiling": "4k"}
        result = build_format_string(cfg)
        assert "height<=2160" in result

    def test_video_1080p(self):
        cfg = {"audio_only": False, "quality_ceiling": "1080p"}
        result = build_format_string(cfg)
        assert "height<=1080" in result

    def test_video_720p(self):
        cfg = {"audio_only": False, "quality_ceiling": "720p"}
        result = build_format_string(cfg)
        assert "height<=720" in result

    def test_video_best(self):
        cfg = {"audio_only": False, "quality_ceiling": "best"}
        result = build_format_string(cfg)
        assert result == "bestvideo+bestaudio/best"

    def test_explicit_video_format(self):
        cfg = {"explicit_format_id": "137"}
        result = build_format_string(cfg)
        assert result == "137/best"

    def test_explicit_video_and_audio_format(self):
        cfg = {"explicit_format_id": "137", "explicit_audio_format_id": "140"}
        result = build_format_string(cfg)
        assert result == "137+140/137/best"

    def test_explicit_overrides_audio_only(self):
        cfg = {
            "audio_only": True,
            "audio_format": "opus",
            "explicit_format_id": "137",
            "explicit_audio_format_id": "140",
        }
        result = build_format_string(cfg)
        assert result == "137+140/137/best"

    def test_format_code_override_wins_over_ladder(self):
        cfg = {"audio_only": False, "quality_ceiling": "720p",
               "format_code": "bestvideo[height<=1080]+bestaudio/best"}
        assert build_format_string(cfg) == \
            "bestvideo[height<=1080]+bestaudio/best"

    def test_format_code_none_falls_back_to_ladder(self):
        cfg = {"audio_only": False, "quality_ceiling": "720p",
               "format_code": None}
        assert "height<=720" in build_format_string(cfg)

    def test_explicit_id_beats_format_code(self):
        cfg = {"explicit_format_id": "137",
               "format_code": "bestvideo+bestaudio/best"}
        assert build_format_string(cfg) == "137/best"

    def test_explicit_audio_only_format_without_video(self):
        cfg = {"explicit_format_id": None, "explicit_audio_format_id": "140"}
        result = build_format_string(cfg)
        assert result == "140/bestaudio/best"

    def test_video_ladder_has_audio_fallback(self):
        cfg = {"audio_only": False, "quality_ceiling": "1080p"}
        result = build_format_string(cfg)
        assert result.endswith("/bestaudio/best")


class TestGetFormatsPlaylist:
    def test_generator_entries_in_formats(self, monkeypatch):
        from grablytic_engine.formats import get_formats
        import grablytic_engine.formats as fmt_mod

        def gen():
            yield {
                "formats": [
                    {"format_id": "137", "vcodec": "avc1", "acodec": "none", "height": 1080},
                    {"format_id": "140", "vcodec": "none", "acodec": "mp4a", "abr": 128},
                ]
            }

        class MockYDL:
            def __init__(self, opts):
                pass
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def extract_info(self, url, download=False):
                return {
                    "_type": "playlist",
                    "entries": gen(),
                }

        monkeypatch.setattr(fmt_mod, "YoutubeDL", MockYDL)

        res = get_formats("https://youtube.com/playlist?list=test")
        assert res["success"] is True
        assert len(res["formats"]) == 2
        assert res["recommended_video_format_id"] == "137"
        assert res["recommended_audio_format_id"] == "140"
