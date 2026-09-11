from truestream_engine.playlist import detect_playlist


class TestDetectPlaylist:
    def test_youtube_playlist_list_param(self):
        assert detect_playlist("https://youtube.com/watch?v=abc&list=PLxyz") is True

    def test_youtube_playlist_path(self):
        assert detect_playlist("https://youtube.com/playlist?list=PLxyz") is True

    def test_youtube_channel(self):
        assert detect_playlist("https://youtube.com/channel/UCxyz") is True

    def test_youtube_custom_url(self):
        assert detect_playlist("https://youtube.com/c/ChannelName") is True

    def test_youtube_handle(self):
        assert detect_playlist("https://youtube.com/@ChannelName") is True

    def test_youtube_user(self):
        assert detect_playlist("https://youtube.com/user/username") is True

    def test_single_video_not_playlist(self):
        assert detect_playlist("https://youtube.com/watch?v=dQw4w9WgXcQ") is False

    def test_shortened_url_not_playlist(self):
        assert detect_playlist("https://youtu.be/dQw4w9WgXcQ") is False

    def test_twitter_url_not_playlist(self):
        assert detect_playlist("https://twitter.com/username/status/123") is False

    def test_generic_url_not_playlist(self):
        assert detect_playlist("https://example.com/video.mp4") is False

    def test_sets_url(self):
        assert detect_playlist("https://example.com/sets/abc") is True


class TestGetPlaylistInfo:
    def test_generator_entries_and_none_filtering(self, monkeypatch):
        from truestream_engine.playlist import get_playlist_info
        import truestream_engine.playlist as pl_mod

        def sample_generator():
            yield {"title": "Song 1", "url": "dQw4w9WgXcQ", "duration": 180}
            yield None  # Deleted/blocked video yielded by yt-dlp
            yield "not-a-dict"  # Malformed item
            yield {"title": "[Deleted video]", "url": "https://example.com/v2"}
            yield {"title": "Song 3", "webpage_url": "https://youtube.com/watch?v=123"}

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
                    "title": "My Test Playlist",
                    "entries": sample_generator(),
                }

        monkeypatch.setattr(pl_mod, "YoutubeDL", MockYDL)

        res = get_playlist_info("https://youtube.com/playlist?list=test")
        assert res["success"] is True
        assert res["title"] == "My Test Playlist"
        assert res["count"] == 3  # The 3 valid dict entries
        # Test that raw video ID was expanded
        assert res["entries"][0]["url"] == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        assert res["entries"][0]["title"] == "Song 1"
        # Test deleted video
        assert res["entries"][1]["title"] == "[Deleted video]"
        # Test webpage_url
        assert res["entries"][2]["url"] == "https://youtube.com/watch?v=123"
