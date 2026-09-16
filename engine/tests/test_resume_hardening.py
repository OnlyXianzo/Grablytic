import json
from grablytic_engine.resume import (
    scan_resume_candidates,
    report_resume_attempt,
)


class TestResumeHardening:
    def test_report_resume_attempt_accepts_output_dir(self, tmp_path, monkeypatch):
        from grablytic_engine import paths

        cache_dir = tmp_path / "cache"
        output_dir = tmp_path / "downloads"
        data_dir = tmp_path / "data"
        cache_dir.mkdir()
        output_dir.mkdir()
        data_dir.mkdir()

        monkeypatch.setattr(
            paths,
            "get_paths",
            lambda: {
                "cache_dir": str(cache_dir),
                "output_dir": str(output_dir),
                "data_dir": str(data_dir),
            },
        )

        part_file = output_dir / "video.mp4.part"
        part_file.write_bytes(b"12345")

        # Passing cache_dir when reporting attempt on a file in output_dir
        res = report_resume_attempt(str(cache_dir), str(part_file), success=False)
        assert res["success"] is True
        assert res["attempts"] == 1

        # Check that resume_attempts.json was stored in data_dir, not output_dir
        assert not (output_dir / "resume_attempts.json").exists()
        assert (data_dir / "resume_attempts.json").exists()

    def test_scan_finds_sibling_info_json_for_split_streams(self, tmp_path):
        target_dir = tmp_path / "downloads"
        target_dir.mkdir()

        # yt-dlp multi-stream format produces:
        # <title>.f137.mp4.part and <title>.info.json
        part_file = target_dir / "Awesome_Song.f137.mp4.part"
        part_file.write_bytes(b"data-chunks")

        info_file = target_dir / "Awesome_Song.info.json"
        info_file.write_text(
            json.dumps({
                "webpage_url": "https://www.youtube.com/watch?v=awesome123",
                "title": "Awesome Song",
            }),
            encoding="utf-8",
        )

        res = scan_resume_candidates(str(target_dir))
        assert res["success"] is True
        assert len(res["candidates"]) == 1
        cand = res["candidates"][0]
        assert cand["filename"] == "Awesome_Song.f137.mp4.part"
        assert cand["likely_url"] == "https://www.youtube.com/watch?v=awesome123"

    def test_scan_prefers_original_url_over_expiring_cdn_url(self, tmp_path):
        target_dir = tmp_path / "downloads"
        target_dir.mkdir()

        part_file = target_dir / "clip.mp4.part"
        part_file.write_bytes(b"video-bytes")

        info_file = target_dir / "clip.info.json"
        info_file.write_text(
            json.dumps({
                "url": "https://rr3---sn-4g5ednss.googlevideo.com/videoplayback?expire=123",
                "original_url": "https://youtu.be/short123",
            }),
            encoding="utf-8",
        )

        res = scan_resume_candidates(str(target_dir))
        assert res["success"] is True
        cand = res["candidates"][0]
        # Must prefer original_url instead of expiring cdn url
        assert cand["likely_url"] == "https://youtu.be/short123"
