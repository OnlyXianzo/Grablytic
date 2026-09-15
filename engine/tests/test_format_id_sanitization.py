"""T0-3 exploit-proof tests: explicit format IDs must not inject selector syntax.

`explicit_format_id` / `explicit_audio_format_id` arrive via IPC config
(Format Picker forwards yt-dlp-supplied IDs, but the config channel itself
is untrusted). They must be single concrete format IDs — never a full
`-f` selector expression. See GRABLYTIC_TEARDOWN.md §4 + HQ tracking (T0-3).
"""

import pytest

from grablytic_engine.format_selector import build_format_string, is_safe_format_id
from grablytic_engine.opts_builder import build_ydl_opts


# ── validator unit tests ──────────────────────────────────────────────

@pytest.mark.parametrize("good", [
    "137", "140", "22", "hls_aac_160k", "sb0", "247-dashy",
    "251-webm", "bestaudio.1", "A1_B2.c-3",
])
def test_safe_ids_accepted(good):
    assert is_safe_format_id(good) is True


@pytest.mark.parametrize("bad", [
    # selector operators (README FORMAT SELECTION + YoutubeDL ALLOWED_OPS)
    "22/47", "137+140", "22,47", "(22)", "bestvideo+bestaudio/best",
    "bv*[height<=1080]+ba/b", "22[height<=720]", "all", "mergeall",
    "ALL", "MergeAll",
    # shell metachars / whitespace (never in a concrete ID)
    "22; rm -rf", "22 && 47", "22|47", "$(47)", "`47`", "22 47",
    "22\n47", "22\t47",
    # empty / overlong / non-string
    "", "x" * 65, None, 123, 137, ["137"], {"id": "137"},
])
def test_unsafe_ids_rejected(bad):
    assert is_safe_format_id(bad) is False


# ── format_selector: malicious IDs fall through to the safe ladder ────

def test_selector_ignores_operator_injection():
    out = build_format_string({"explicit_format_id": "22/47"})
    assert "22/47" not in out
    assert out.endswith("/bestaudio/best")  # safe ladder fallback


def test_selector_rejects_all_mergeall_amplification():
    for evil in ("all", "mergeall", "ALL"):
        out = build_format_string({"explicit_format_id": evil})
        assert out != evil
        assert "all" not in out.lower().replace("bestaudio/best", "")


def test_selector_valid_pair_unchanged():
    out = build_format_string(
        {"explicit_format_id": "137", "explicit_audio_format_id": "140"})
    assert out == "137+140/137/best"


def test_selector_valid_vid_plus_evil_aid_uses_vid_only():
    out = build_format_string(
        {"explicit_format_id": "137", "explicit_audio_format_id": "140/141"})
    assert "140/141" not in out
    assert out == "137/best"


# ── opts_builder: malicious IDs never reach yt-dlp `format` ───────────

def test_opts_rejects_format_expression_injection():
    for evil in ("bestvideo+bestaudio/best", "22/47", "all", "bv*+ba/best",
                 "22[height<=0]", "(22)", "22,47"):
        opts = build_ydl_opts(config={"explicit_format_id": evil})
        assert evil not in opts["format"], evil
        # fail closed to a safe ladder, never the attacker's expression
        assert opts["format"].endswith("/bestaudio/best"), opts["format"]


def test_opts_rejects_audio_id_injection():
    opts = build_ydl_opts(config={"explicit_audio_format_id": "140/141"})
    assert "140/141" not in opts["format"]


def test_opts_valid_ids_still_work():
    opts = build_ydl_opts(
        config={"explicit_format_id": "137", "explicit_audio_format_id": "140"})
    assert opts["format"] == "137+140"
    opts2 = build_ydl_opts(config={"explicit_audio_format_id": "140"})
    assert opts2["format"] == "140"


def test_opts_evil_audio_id_does_not_force_audio_mode():
    # "all" must not flip the download into audio-extract mode either.
    opts = build_ydl_opts(config={"explicit_audio_format_id": "all"})
    assert "140/141" not in opts.get("format", "")
    assert opts["format"] != "all"
    pps = opts.get("postprocessors", [])
    assert not any(pp.get("key") == "FFmpegExtractAudio" for pp in pps)
