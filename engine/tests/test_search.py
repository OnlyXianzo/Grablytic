import pytest
from grablytic_engine.search import _build_search_url, search
import grablytic_engine.search as search_mod


class TestBuildSearchUrl:
    def test_youtube_default(self):
        url = _build_search_url("never gonna give you up", "youtube", 20)
        assert url == "ytsearch20:never gonna give you up"

    def test_soundcloud(self):
        url = _build_search_url("chillhop essentials", "soundcloud", 10)
        assert url == "scsearch10:chillhop essentials"

    def test_empty_site_defaults_to_youtube(self):
        url = _build_search_url("jazz piano", "", 15)
        assert url == "ytsearch15:jazz piano"

    def test_trims_query_whitespace(self):
        url = _build_search_url("  ambient space  ", "youtube", 5)
        assert url == "ytsearch5:ambient space"


class TestSearch:
    def test_empty_query_returns_error(self):
        res = search("")
        assert res["success"] is False
        assert res["error_type"] == "ERROR_INVALID_PARAM"

    def test_whitespace_query_returns_error(self):
        res = search("   ")
        assert res["success"] is False
        assert res["error_type"] == "ERROR_INVALID_PARAM"

    def test_none_query_returns_error(self):
        res = search(None)
        assert res["success"] is False
        assert res["error_type"] == "ERROR_INVALID_PARAM"

    def test_successful_search_with_entry_normalization(self, monkeypatch):
        def sample_entries():
            yield {
                "title": "Never Gonna Give You Up",
                "url": "dQw4w9WgXcQ",
                "duration": 212,
                "thumbnails": [{"url": "https://img.youtube.com/small.jpg"}, {"url": "https://img.youtube.com/large.jpg"}],
                "uploader": "Rick Astley",
                "availability": "public",
            }
            yield None  # Filtered
            yield "not-a-dict"  # Filtered
            yield {
                "title": "[Deleted video]",
                "webpage_url": "https://youtube.com/watch?v=deleted",
                "uploader": None,
            }
            yield {
                "title": "Private Video",
                "url": "https://youtube.com/watch?v=private",
                "availability": "private",
            }

        class MockYDL:
            def __init__(self, opts):
                self.opts = opts
                assert opts.get("extract_flat") is True

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def extract_info(self, url, download=False):
                assert url == "ytsearch20:rick astley"
                return {
                    "_type": "playlist",
                    "title": "ytsearch20:rick astley",
                    "entries": sample_entries(),
                }

        monkeypatch.setattr(search_mod, "YoutubeDL", MockYDL)

        res = search("rick astley", site="youtube", limit=20)
        assert res["success"] is True
        assert res["query"] == "rick astley"
        assert res["site"] == "youtube"
        assert res["count"] == 3

        entry1 = res["entries"][0]
        assert entry1["index"] == 1
        assert entry1["title"] == "Never Gonna Give You Up"
        assert entry1["url"] == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        assert entry1["duration_seconds"] == 212
        assert entry1["thumbnail_url"] == "https://img.youtube.com/large.jpg"
        assert entry1["uploader"] == "Rick Astley"
        assert entry1["is_available"] is True

        entry2 = res["entries"][1]
        assert entry2["index"] == 2
        assert entry2["title"] == "[Deleted video]"
        assert entry2["url"] == "https://youtube.com/watch?v=deleted"

        entry3 = res["entries"][2]
        assert entry3["index"] == 3
        assert entry3["title"] == "Private Video"
        assert entry3["is_available"] is False

    def test_zero_results(self, monkeypatch):
        class MockYDL:
            def __init__(self, opts):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def extract_info(self, url, download=False):
                return {"_type": "playlist", "entries": []}

        monkeypatch.setattr(search_mod, "YoutubeDL", MockYDL)

        res = search("nonexistentquery123456789")
        assert res["success"] is True
        assert res["count"] == 0
        assert res["entries"] == []

    def test_none_data_returns_zero_results(self, monkeypatch):
        class MockYDL:
            def __init__(self, opts):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def extract_info(self, url, download=False):
                return None

        monkeypatch.setattr(search_mod, "YoutubeDL", MockYDL)

        res = search("test")
        assert res["success"] is True
        assert res["count"] == 0
        assert res["entries"] == []

    def test_bot_detection_classified_correctly(self, monkeypatch):
        class MockYDL:
            def __init__(self, opts):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def extract_info(self, url, download=False):
                raise Exception("Sign in to confirm you're not a bot")

        monkeypatch.setattr(search_mod, "YoutubeDL", MockYDL)

        res = search("blocked query")
        assert res["success"] is False
        assert res["error_type"] == "ERROR_FORBIDDEN"
        assert "bot" in res["error_message"].lower()

    def test_rate_limit_classified_correctly(self, monkeypatch):
        class MockYDL:
            def __init__(self, opts):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def extract_info(self, url, download=False):
                raise Exception("HTTP Error 429: Too Many Requests")

        monkeypatch.setattr(search_mod, "YoutubeDL", MockYDL)

        res = search("busy query")
        assert res["success"] is False
        assert res["error_type"] == "ERROR_RATE_LIMITED"

    def test_search_configures_js_runtime(self, tmp_path, monkeypatch):
        """Loop-4: search used a dead import name, silently running with no
        JS runtime (slower/missing formats). Must match the download path."""
        from grablytic_engine.paths import _paths
        deno_file = tmp_path / "deno"
        deno_file.touch()
        deno_file.chmod(0o755)
        monkeypatch.setitem(_paths, "deno_path", str(deno_file))

        seen = {}

        class MockYDL:
            def __init__(self, opts):
                seen.update(opts)

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def extract_info(self, url, download=False):
                return {"_type": "playlist", "entries": []}

        monkeypatch.setattr(search_mod, "YoutubeDL", MockYDL)
        res = search("some query")
        assert res["success"] is True
        assert "js_runtimes" in seen
        assert seen["js_runtimes"]["deno"]["path"] == str(deno_file)
        assert "ejs:github" in seen.get("remote_components", [])
