from grablytic_engine.config import DEFAULT_CFG


def test_default_config_has_required_keys():
    assert "format_code" in DEFAULT_CFG
    assert "audio_only" in DEFAULT_CFG
    assert "container" in DEFAULT_CFG
    assert "quality_ceiling" in DEFAULT_CFG
    assert "retries" in DEFAULT_CFG
    assert "output_tmpl" in DEFAULT_CFG


def test_default_config_values():
    assert DEFAULT_CFG["quality_ceiling"] == "4k"
    assert DEFAULT_CFG["audio_only"] is False
    assert DEFAULT_CFG["retries"] == 10
    assert DEFAULT_CFG["fragment_retries"] == 10
    assert DEFAULT_CFG["output_tmpl"] == "%(uploader)s - %(title)s.%(ext)s"


def test_default_config_explicit_overrides_are_none():
    assert DEFAULT_CFG["explicit_format_id"] is None
    assert DEFAULT_CFG["explicit_audio_format_id"] is None
