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

    def test_video_480p(self):
        cfg = {"audio_only": False, "quality_ceiling": "480p"}
        result = build_format_string(cfg)
        assert "height<=480" in result

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

    def test_video_ladder_tail_is_combined_best_never_audio_only(self):
        # Portrait reels (720x1280/1080x1920) miss every height<=1080 rung;
        # the old /bestaudio/best tail then matched the always-present
        # dash-audio and saved silent .m4a. A video intent must never
        # resolve to audio-only: end on combined /best (visible error if
        # truly nothing matches beats a wrong file).
        for ceiling in ("480p", "720p", "1080p", "4k"):
            cfg = {"audio_only": False, "quality_ceiling": ceiling}
            result = build_format_string(cfg)
            assert result.endswith("/best"), result
            assert not result.endswith("/bestaudio/best"), result

    def test_video_ladder_has_portrait_width_branch(self):
        # Orientation-neutral cap: same H must match landscape by height
        # and portrait by width (maintainer pattern yt-dlp#4117), with the
        # branches split by aspect_ratio so a 540x960 variant never wins
        # over 1080x1920 under a 1080p ceiling.
        cfg = {"audio_only": False, "quality_ceiling": "1080p"}
        result = build_format_string(cfg)
        assert "bestvideo*[height<=1080][aspect_ratio>=1]" in result
        assert "bestvideo*[width<=1080][aspect_ratio<1]+bestaudio" in result
        assert "best[width<=1080]" in result
        cfg = {"audio_only": False, "quality_ceiling": "720p"}
        result = build_format_string(cfg)
        assert "bestvideo*[width<=720][aspect_ratio<1]+bestaudio" in result


class TestPortraitLadderSelection:
    """End-to-end pin for the 2026-09-30 field bug, through yt-dlp's real
    ``build_format_selector`` (no network — synthetic IG-style listings).

    Replicates ``YoutubeDL._select_formats``: worst→best sort plus the
    ``has_merged_format`` / ``incomplete_formats`` ctx keys, and fills
    ``aspect_ratio`` exactly like ``YoutubeDL`` does at processing time
    (``round(width / height, 2)``).
    """

    OLD_1080P = (
        "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]"
        "/bestvideo[height<=1080]+bestaudio"
        "/best[height<=1080]/bestaudio/best"
    )

    @staticmethod
    def _v(fid, w, h, tbr):
        d = {"format_id": fid, "url": f"http://x/{fid}", "ext": "mp4",
             "width": w, "height": h, "vcodec": "avc1.640028",
             "acodec": "none", "tbr": tbr, "protocol": "https",
             "aspect_ratio": round(w / h, 2)}
        return d

    @staticmethod
    def _a():
        return {"format_id": "dash-a", "url": "http://x/a.m4a", "ext": "m4a",
                "vcodec": "none", "acodec": "mp4a.40.2", "abr": 128,
                "tbr": 128, "protocol": "https", "aspect_ratio": None}

    def _select(self, formats, spec):
        from yt_dlp import YoutubeDL

        ydl = YoutubeDL({"quiet": True, "no_warnings": True})
        fs = [dict(f) for f in formats]
        fs.sort(key=lambda f: (f.get("height") or 0, f.get("tbr") or 0))
        ctx = {
            "formats": fs,
            "has_merged_format": any(
                "none" not in (f.get("acodec"), f.get("vcodec")) for f in fs),
            "incomplete_formats": (
                all(f.get("vcodec") == "none" for f in fs)
                or all(f.get("acodec") == "none" for f in fs)),
        }
        return list(ydl.build_format_selector(spec)(ctx))

    def test_old_ladder_goes_audio_only_on_portrait_hi_only(self):
        # Red pin for the field report: 720x1280 + 1080x1920 only.
        formats = [self._v("dash-1080v", 1080, 1920, 8000),
                   self._v("dash-720v", 720, 1280, 4500), self._a()]
        picked = self._select(formats, self.OLD_1080P)
        assert picked, "old ladder should resolve (to audio)"
        assert all(f["vcodec"] == "none" for f in picked)

    def test_new_ladder_merges_full_portrait_video(self):
        formats = [self._v("dash-1080v", 1080, 1920, 8000),
                   self._v("dash-720v", 720, 1280, 4500), self._a()]
        spec = build_format_string(
            {"audio_only": False, "quality_ceiling": "1080p"})
        picked = self._select(formats, spec)
        # A merge resolves to one dict with a joined id ("a+b").
        ids = "+".join(f["format_id"] for f in picked)
        assert "dash-1080v" in ids, ids
        assert "dash-a" in ids, ids

    def test_new_ladder_prefers_portrait_best_over_low_variant(self):
        # A 540x960 variant must not win over 1080x1920 at 1080p.
        formats = [self._v("dash-1080v", 1080, 1920, 8000),
                   self._v("dash-720v", 720, 1280, 4500),
                   self._v("dash-540v", 540, 960, 2000), self._a()]
        spec = build_format_string(
            {"audio_only": False, "quality_ceiling": "1080p"})
        picked = self._select(formats, spec)
        ids = "+".join(f["format_id"] for f in picked)
        assert "dash-1080v" in ids, ids
        assert "dash-540v" not in ids, ids

    def test_new_ladder_landscape_unchanged(self):
        formats = [self._v("hd-1080v", 1920, 1080, 6000),
                   self._v("hd-540v", 960, 540, 1500), self._a()]
        spec = build_format_string(
            {"audio_only": False, "quality_ceiling": "1080p"})
        picked = self._select(formats, spec)
        ids = "+".join(f["format_id"] for f in picked)
        assert "hd-1080v" in ids, ids

    def test_new_ladder_never_resolves_audio_only(self):
        # Whatever misses, a video intent must not come back audio-only.
        listings = [
            [self._v("dash-1080v", 1080, 1920, 8000),
             self._v("dash-720v", 720, 1280, 4500), self._a()],
            [self._v("l4k", 3840, 2160, 20000), self._a()],
        ]
        for ceiling in ("480p", "720p", "1080p", "4k"):
            spec = build_format_string(
                {"audio_only": False, "quality_ceiling": ceiling})
            for formats in listings:
                picked = self._select(formats, spec)
                assert not picked or any(
                    f["vcodec"] != "none" for f in picked), (ceiling, spec)


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
