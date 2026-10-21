"""File names must fit the filesystem, in BYTES, after template expansion.

Field logs (Android, yt-dlp 2026.08.19):

    OSError: [Errno 36] File name too long:
    '/storage/emulated/0/Download/Grablytic/Video/Muskan K - 6.8K views ·
     220 reactions ｜ Your SEO to-do list ... .f1647430460256725v.mp4.part'

521 bytes in one path component, where NAME_MAX is 255 bytes. The cause
is not just a long caption: `trim_file_name` counts *characters* and
splits the name on its last two dots, so a dot anywhere in the title
(defeating the trim) plus emoji/full-width glyphs (3-4 bytes each)
produced a name the kernel could not create. It then auto-retried three
times and surfaced as ERROR_UNKNOWN.
"""

import pytest

from grablytic_engine import filename_guard as fg

# The exact title from the device log that failed with Errno 36.
_FIELD_TITLE = (
    "6.8K views · 220 reactions ｜ Your SEO to-do list, sorted by how often 👇 "
    "Every day Check your rankings Reply to Google reviews Check new leads "
    "Check your site is up Once a week Publish a blog post Check Search Console "
    "Add internal links Post on your Google profile Once a month Run a site "
    "audit Refresh old content Build 2–3 backlinks Check if ChatGPT recommends "
    "you Save this for your next planning day 📌 #seo #seotips #digitalmarketing "
    "#smallbusiness #aiseo"
)
_FIELD_URL_DIR = "Video/"


def _byte_len(text: str) -> int:
    return len(text.encode("utf-8"))


# ─────────────────────────────────────────────── byte-aware primitives


@pytest.mark.unit
def test_short_names_are_untouched():
    assert fg.bound_component("Muskan K - Short clip.mp4") == "Muskan K - Short clip.mp4"


@pytest.mark.unit
def test_empty_and_non_string_input_is_passed_through():
    assert fg.bound_component("") == ""
    assert fg.bound_component(None) is None
    assert fg.bound_filename("") == ""


@pytest.mark.unit
def test_budget_is_defined_below_the_filesystem_limit():
    # 255 is NAME_MAX; yt-dlp still appends .f<format_id> / .part.
    assert fg.NAME_MAX_BYTES == 255
    assert fg.MAX_COMPONENT_BYTES < fg.NAME_MAX_BYTES
    assert fg.MAX_COMPONENT_BYTES == fg.NAME_MAX_BYTES - fg.SUFFIX_RESERVE_BYTES


@pytest.mark.unit
def test_ascii_name_is_cut_to_the_byte_budget():
    out = fg.bound_component("a" * 400 + ".mp4")
    assert _byte_len(out) <= fg.MAX_COMPONENT_BYTES
    assert out.endswith(".mp4")


@pytest.mark.unit
def test_emoji_name_is_cut_and_never_splits_a_character():
    out = fg.bound_component("🎬" * 200 + ".mp4")
    assert _byte_len(out) <= fg.MAX_COMPONENT_BYTES
    assert out.endswith(".mp4")
    # A half-cut code point would not survive a round trip.
    assert out.encode("utf-8").decode("utf-8") == out
    assert "�" not in out


@pytest.mark.unit
def test_fullwidth_title_from_the_field_log_is_bounded():
    out = fg.bound_component(f"Muskan K - {_FIELD_TITLE}.mp4")
    assert _byte_len(out) <= fg.MAX_COMPONENT_BYTES
    assert out.endswith(".mp4")
    assert out.startswith("Muskan K - 6.8K views")


@pytest.mark.unit
def test_trailing_id_marker_survives_truncation():
    """The default template ends with " [%(id)s]" — cutting it would
    collapse different long-titled items onto one file name."""
    name = f"{'x' * 400} [f1647430460256725v].mp4"
    out = fg.bound_component(name)
    assert _byte_len(out) <= fg.MAX_COMPONENT_BYTES
    assert out.endswith(" [f1647430460256725v].mp4")


@pytest.mark.unit
def test_dot_in_the_title_cannot_defeat_the_cut():
    """`trim_file_name` split on the last two dots, so this name escaped
    trimming entirely; the byte bound must not."""
    out = fg.bound_component(f"Muskan K - 6.8K views {_FIELD_TITLE}.mp4")
    assert _byte_len(out) <= fg.MAX_COMPONENT_BYTES


@pytest.mark.unit
def test_trailing_dots_and_spaces_are_stripped():
    out = fg.bound_component("b" * 199 + "...   .mp4")
    assert _byte_len(out) <= fg.MAX_COMPONENT_BYTES
    assert not out.split(".mp4")[0].endswith((" ", "."))


@pytest.mark.unit
def test_absurd_extension_falls_back_to_whole_name_bound():
    out = fg.bound_component("c" * 300 + "." + "d" * 40)
    assert _byte_len(out) <= fg.MAX_COMPONENT_BYTES


@pytest.mark.unit
def test_every_component_of_a_path_is_bounded():
    out = fg.bound_filename(f"{_FIELD_URL_DIR}{'e' * 400}/{'f' * 400}.mp4")
    parts = out.split("/")
    assert parts[0] == "Video"
    assert all(_byte_len(p) <= fg.MAX_COMPONENT_BYTES for p in parts)


# ───────────────────────────────── the yt-dlp boundary actually applies it


def _ydl(outtmpl: str, **params):
    from grablytic_engine.ytdlp_network import GuardedYoutubeDL

    opts = {
        "outtmpl": {"default": outtmpl},
        "paths": {"home": "/storage/emulated/0/Download/Grablytic"},
        "quiet": True,
        "logger": None,
    }
    opts.update(params)
    return GuardedYoutubeDL(opts)


@pytest.mark.unit
def test_prepare_filename_bounds_the_field_failure_end_to_end():
    """Reproduce the device failure: base name + yt-dlp's own suffixes.

    yt-dlp appends `.f<format_id>.<ext>` for each requested format and the
    downloader appends `.part`, so the bound must hold for THAT name.
    """
    info = {
        "id": "f1647430460256725v",
        "title": _FIELD_TITLE,
        "uploader": "Muskan K",
        "ext": "mp4",
        "format_id": "1647430460256725v",
    }
    ydl = _ydl("Video/%(uploader)s - %(title)s.%(ext)s")
    prepared = ydl._prepare_filename(info)
    assert prepared, "prepared filename must not be empty"
    # NAME_MAX is per component: "Video/" is a separate directory.
    assert _byte_len(prepared.rsplit("/", 1)[-1]) <= fg.MAX_COMPONENT_BYTES

    final = f"{prepared}.f{info['format_id']}.mp4.part"
    component = final.rsplit("/", 1)[-1]
    assert _byte_len(component) <= fg.NAME_MAX_BYTES, component

    # And the bug this replaces: unguarded, the same input blew the limit.
    raw = ydl.evaluate_outtmpl(
        {"default": "Video/%(uploader)s - %(title)s.%(ext)s"}["default"], info
    )
    assert _byte_len(raw.rsplit("/", 1)[-1]) > fg.NAME_MAX_BYTES


@pytest.mark.unit
def test_prepare_filename_keeps_the_default_template_unique():
    info = {"id": "abc123", "title": "x" * 500, "ext": "mp4", "format_id": "18"}
    ydl = _ydl("%(uploader)s - %(title)s [%(id)s].%(ext)s")
    prepared = ydl._prepare_filename({**info, "uploader": "Chan"})
    assert _byte_len(prepared.rsplit("/", 1)[-1]) <= fg.MAX_COMPONENT_BYTES
    assert prepared.endswith("[abc123].mp4")


@pytest.mark.unit
def test_prepare_filename_leaves_ordinary_names_alone():
    info = {"id": "abc123", "title": "A short clip", "uploader": "Chan", "ext": "mp4"}
    ydl = _ydl("%(uploader)s - %(title)s [%(id)s].%(ext)s")
    assert ydl._prepare_filename(info) == "Chan - A short clip [abc123].mp4"


@pytest.mark.unit
def test_thumbnail_and_sidecar_names_are_bounded_too():
    info = {"id": "abc123", "title": "🎬" * 200, "ext": "mp4"}
    ydl = _ydl("%(title)s.%(ext)s")
    thumb = ydl.prepare_filename(info, "thumbnail")
    assert thumb
    assert _byte_len(thumb.rsplit("/", 1)[-1]) <= fg.NAME_MAX_BYTES


# ──────────────────────────────────────────────── downloads no longer retry


@pytest.mark.unit
def test_filename_too_long_is_classified_non_recoverable():
    from grablytic_engine.errors import classify_error

    exc = OSError(
        36,
        "File name too long: '/storage/emulated/0/Download/Grablytic/Video/"
        + "Muskan K - 6.8K views · 220 reactions ｜ " * 12
        + ".f1.mp4.part'",
    )
    err = classify_error(exc)
    assert err.error_type == "ERROR_FILENAME_TOO_LONG"
    assert err.recoverable is False
    assert err.suggests_vpn is False


@pytest.mark.unit
def test_windows_spelling_is_classified_too():
    from grablytic_engine.errors import classify_error

    err = classify_error(Exception("ERROR: Filename too long"))
    assert err.error_type == "ERROR_FILENAME_TOO_LONG"


@pytest.mark.unit
def test_filename_too_long_never_auto_retries():
    from grablytic_engine import downloader
    from grablytic_engine.errors import GrablyticError

    err = GrablyticError("ERROR_FILENAME_TOO_LONG", "File name too long", False)
    assert downloader._is_transient_retryable(err) is False
    assert "ERROR_FILENAME_TOO_LONG" in downloader._NO_RETRY_PERMANENT


@pytest.mark.unit
def test_trim_file_name_is_not_used():
    """yt-dlp's trim is character-based and breaks on dotted titles."""
    from grablytic_engine.opts_builder import build_ydl_opts

    opts = build_ydl_opts()
    assert "trim_file_name" not in opts


# ─────────────────────────────────────────── the kernel agrees with us


@pytest.mark.unit
def test_guarded_name_is_actually_creatable_while_the_old_one_is_not(tmp_path):
    """Prove the bound against a real filesystem, not just a length sum.

    The pre-fix name from the device log is 521 bytes in one component;
    ``open()`` on ext4/FUSE answers ENAMETOOLONG. The guarded name must
    be creatable, including yt-dlp's ``.f<format_id>.<ext>.part`` temp
    suffix.
    """
    import os

    info = {
        "id": "f1647430460256725v",
        "title": _FIELD_TITLE,
        "uploader": "Muskan K",
        "ext": "mp4",
        "format_id": "1647430460256725v",
    }

    old_name = f"Muskan K - {_FIELD_TITLE}.f1647430460256725v.mp4.part"
    if os.name == "posix":
        with pytest.raises(OSError) as excinfo:
            (tmp_path / old_name).write_bytes(b"x")
        assert excinfo.value.errno in (36, 63)  # Linux / macOS ENAMETOOLONG

    ydl = _ydl("Video/%(uploader)s - %(title)s.%(ext)s")
    prepared = ydl._prepare_filename(info).rsplit("/", 1)[-1]
    final = tmp_path / f"{prepared}.f{info['format_id']}.mp4.part"
    final.write_bytes(b"x")
    assert final.exists()


@pytest.mark.unit
def test_backslash_separators_are_bounded_per_component():
    """#102: a Windows template must not share one NAME_MAX between folders."""
    out = fg.bound_filename(f"{'d' * 300}\\{'f' * 300}.mp4")
    assert "/" in out, "separators are normalised for the output template"
    assert "\\" not in out
    parts = out.split("/")
    assert len(parts) == 2
    assert all(_byte_len(part) <= fg.MAX_COMPONENT_BYTES for part in parts)
    assert parts[1].endswith(".mp4")
