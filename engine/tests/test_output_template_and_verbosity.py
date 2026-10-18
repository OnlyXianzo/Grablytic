"""Output templates, verbosity and error classification.

- The default template had no per-item unique field, and yt-dlp
  REPLACES an existing video file, so two uploads with the same title
  silently overwrote each other.
- The engine forced `verbose = True`, so yt-dlp's verbose output
  flooded the log on every download and the user's setting was ignored.
- Private / removed videos fell through to ERROR_UNKNOWN.
"""

import pytest


def _ob():
    import grablytic_engine.opts_builder as ob
    return ob


def _cfg():
    import grablytic_engine.config as cfg_mod
    return cfg_mod


def _dl():
    import grablytic_engine.downloader as dl_mod
    return dl_mod


# ─────────────────────────────────────────────────────── collision safety

@pytest.mark.unit
def test_the_default_template_is_collision_safe():
    assert _cfg().DEFAULT_CFG["output_tmpl"] == \
        "%(uploader)s - %(title)s [%(id)s].%(ext)s"


@pytest.mark.unit
@pytest.mark.parametrize("tmpl", [
    "%(uploader)s - %(title)s [%(id)s].%(ext)s",
    "%(id)s.%(ext)s",
    "%(playlist_index)s - %(title)s.%(ext)s",
    "%(autonumber)s - %(title)s.%(ext)s",
])
def test_collision_safe_templates_are_recognised(tmpl):
    assert _ob()._outtmpl_is_collision_safe(tmpl) is True


@pytest.mark.unit
@pytest.mark.parametrize("tmpl", [
    "%(uploader)s - %(title)s.%(ext)s",
    "%(title)s.%(ext)s",
    "video.%(ext)s",
    "",
    None,
])
def test_collision_unsafe_templates_are_recognised(tmpl):
    assert _ob()._outtmpl_is_collision_safe(tmpl) is False


@pytest.mark.unit
def test_the_engine_warns_about_a_collision_unsafe_template():
    """A template without a unique field must be flagged, not silently used."""
    ob = _ob()
    ob._collision_warned = False
    ob._warn_collision_unsafe_tmpl("%(title)s.%(ext)s")
    assert ob._collision_warned is True


@pytest.mark.unit
def test_the_default_template_needs_no_warning():
    ob = _ob()
    assert ob._outtmpl_is_collision_safe(_cfg().DEFAULT_CFG["output_tmpl"])


# ───────────────────────────────────────────────────────────────── verbosity

@pytest.mark.unit
def test_verbose_is_off_unless_the_config_asks_for_it():
    ob = _ob()
    opts = ob.build_ydl_opts(config={"verbose": False})
    assert not opts.get("verbose")


@pytest.mark.unit
def test_verbose_follows_the_config():
    ob = _ob()
    opts = ob.build_ydl_opts(config={"verbose": True})
    assert opts.get("verbose") is True


@pytest.mark.unit
def test_the_engine_does_not_force_verbose():
    """The downloader used to set `opts["verbose"] = True` unconditionally."""
    dl = _dl()
    opts = {"verbose": True}
    dl._apply_verbosity(opts, {"verbose": False})
    assert "verbose" not in opts
    dl._apply_verbosity(opts, {"verbose": True})
    assert opts["verbose"] is True


# ───────────────────────────────────────────────────── error classification

@pytest.mark.unit
@pytest.mark.parametrize("message,expected", [
    ("Private video. Sign in if you've been granted access", "ERROR_PRIVATE"),
    ("This video is private. Sign in if you've been granted access",
     "ERROR_PRIVATE"),
    ("This video has been removed by the uploader", "ERROR_UNAVAILABLE"),
    ("This video is no longer available because the YouTube account "
     "associated with it has been terminated", "ERROR_UNAVAILABLE"),
])
def test_yt_dlp_phrasings_are_classified(message, expected):
    from grablytic_engine.errors import classify_error
    assert classify_error(Exception(message)).error_type == expected


# ─────────────────────────────────────────────────────── the logger tail

@pytest.mark.unit
def test_the_logger_tail_is_lock_protected_and_readable():
    dl = _dl()
    logger = dl.YDLogger()
    logger.error("boom")
    assert logger.last_error() == "boom"
    assert hasattr(logger, "_lock")


@pytest.mark.unit
def test_last_error_is_none_when_nothing_failed():
    dl = _dl()
    assert dl.YDLogger().last_error() is None
