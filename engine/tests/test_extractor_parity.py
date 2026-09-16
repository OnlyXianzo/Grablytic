

class TestExtractorParity:
    def test_get_formats_configures_js_runtime(self, monkeypatch, tmp_path):
        import grablytic_engine.formats as formats_mod

        fake_node = tmp_path / "node"
        fake_node.write_text("#!/bin/sh\nexit 0\n")
        fake_node.chmod(0o755)

        monkeypatch.setattr(formats_mod, "get_paths", lambda: {"nodejs_path": str(fake_node)})

        captured_opts = {}

        class MockYDL:
            def __init__(self, opts):
                captured_opts.update(opts)
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def extract_info(self, url, download=False):
                return {"title": "Test Video", "formats": []}

        monkeypatch.setattr(formats_mod, "YoutubeDL", MockYDL)

        res = formats_mod.get_formats("https://example.com/watch?v=123")
        assert res["success"] is True
        assert "js_runtimes" in captured_opts
        assert "node" in captured_opts["js_runtimes"]
        assert captured_opts.get("remote_components") == ["ejs:github"]

    def test_get_playlist_info_configures_js_runtime(self, monkeypatch, tmp_path):
        import grablytic_engine.playlist as pl_mod

        fake_node = tmp_path / "node"
        fake_node.write_text("#!/bin/sh\nexit 0\n")
        fake_node.chmod(0o755)

        monkeypatch.setattr(pl_mod, "get_paths", lambda: {"nodejs_path": str(fake_node)})

        captured_opts = {}

        class MockYDL:
            def __init__(self, opts):
                captured_opts.update(opts)
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def extract_info(self, url, download=False):
                return {"title": "Test Playlist", "entries": []}

        monkeypatch.setattr(pl_mod, "YoutubeDL", MockYDL)

        res = pl_mod.get_playlist_info("https://example.com/playlist?list=123")
        assert res["success"] is True
        assert "js_runtimes" in captured_opts
        assert "node" in captured_opts["js_runtimes"]
        assert captured_opts.get("remote_components") == ["ejs:github"]

    def test_get_playlist_info_youtube_extractor_args_and_po_token(self, monkeypatch):
        import grablytic_engine.playlist as pl_mod

        monkeypatch.setattr(pl_mod, "get_paths", lambda: {"po_token": "custom-token-xyz"})

        captured_opts = {}

        class MockYDL:
            def __init__(self, opts):
                captured_opts.update(opts)
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def extract_info(self, url, download=False):
                return {"title": "YT Playlist", "entries": []}

        monkeypatch.setattr(pl_mod, "YoutubeDL", MockYDL)

        res = pl_mod.get_playlist_info("https://www.youtube.com/playlist?list=PL123")
        assert res["success"] is True
        assert "extractor_args" in captured_opts
        assert "youtube" in captured_opts["extractor_args"]
        yt_args = captured_opts["extractor_args"]["youtube"]
        assert yt_args.get("player_client") == ["default", "mweb"]
        assert yt_args.get("po_token") == ["custom-token-xyz"]

    def test_get_playlist_info_returns_thumbnail_url_fallback(self, monkeypatch):
        import grablytic_engine.playlist as pl_mod

        monkeypatch.setattr(pl_mod, "get_paths", lambda: {})

        # Case A: Top-level thumbnail present
        class MockYDLDirect:
            def __init__(self, opts): pass
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def extract_info(self, url, download=False):
                return {
                    "title": "PL 1",
                    "thumbnail": "https://img.example.com/pl.jpg",
                    "entries": [{"title": "Vid 1", "url": "https://example.com/v1"}],
                }

        monkeypatch.setattr(pl_mod, "YoutubeDL", MockYDLDirect)
        res_a = pl_mod.get_playlist_info("https://example.com/playlist?list=a")
        assert res_a["thumbnail_url"] == "https://img.example.com/pl.jpg"

        # Case B: Top-level thumbnail missing, fallback to entry thumbnail
        class MockYDLEntryFallback:
            def __init__(self, opts): pass
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def extract_info(self, url, download=False):
                return {
                    "title": "PL 2",
                    "entries": [
                        {"title": "[Deleted video]", "url": "https://example.com/del", "thumbnail": None},
                        {"title": "Vid 2", "url": "https://example.com/v2", "thumbnail": "https://img.example.com/v2.jpg"},
                    ],
                }

        monkeypatch.setattr(pl_mod, "YoutubeDL", MockYDLEntryFallback)
        res_b = pl_mod.get_playlist_info("https://example.com/playlist?list=b")
        assert res_b["thumbnail_url"] == "https://img.example.com/v2.jpg"

        # Case C: No thumbnails anywhere, fallback to YouTube hqdefault from 11-char ID
        class MockYDLIdFallback:
            def __init__(self, opts): pass
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def extract_info(self, url, download=False):
                return {
                    "title": "PL 3",
                    "entries": [
                        {"title": "Vid 3", "url": "dQw4w9WgXcQ"},
                    ],
                }

        monkeypatch.setattr(pl_mod, "YoutubeDL", MockYDLIdFallback)
        res_c = pl_mod.get_playlist_info("https://example.com/playlist?list=c")
        assert res_c["thumbnail_url"] == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"

    def test_get_formats_playlist_generator_preserves_first_entry(self, monkeypatch):
        import grablytic_engine.formats as formats_mod

        monkeypatch.setattr(formats_mod, "get_paths", lambda: {})

        def sample_entries():
            yield {
                "title": "Entry 0",
                "formats": [
                    {"format_id": "18", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a", "height": 360}
                ],
                "thumbnail": "https://img.example.com/e0.jpg",
            }
            yield {
                "title": "Entry 1",
                "formats": [
                    {"format_id": "22", "ext": "mp4", "vcodec": "avc1", "acodec": "mp4a", "height": 720}
                ],
            }

        class MockYDLPlaylist:
            def __init__(self, opts): pass
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def extract_info(self, url, download=False):
                return {
                    "_type": "playlist",
                    "title": "Gen Playlist",
                    "entries": sample_entries(),
                }

        monkeypatch.setattr(formats_mod, "YoutubeDL", MockYDLPlaylist)

        res = formats_mod.get_formats("https://example.com/playlist?list=gen")
        assert res["success"] is True
        assert res["is_playlist"] is True
        assert len(res["formats"]) == 1
        assert res["formats"][0]["format_id"] == "18"
        # Should also pick up thumbnail from entry 0 if top level missing
        assert res["thumbnail_url"] == "https://img.example.com/e0.jpg"
