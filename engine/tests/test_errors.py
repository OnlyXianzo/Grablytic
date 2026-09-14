from grablytic_engine.errors import GrablyticError, classify_error


class TestGrablyticError:
    def test_holds_fields(self):
        err = GrablyticError("ERROR_TEST", "something went wrong", recoverable=True)
        assert err.error_type == "ERROR_TEST"
        assert err.message == "something went wrong"
        assert err.recoverable is True

    def test_to_dict(self):
        err = GrablyticError("ERROR_TEST", "msg", True)
        d = err.to_dict()
        assert d == {
            "error_type": "ERROR_TEST",
            "error_message": "msg",
            "recoverable": True,
            "suggests_vpn": False,
        }

    def test_suggests_vpn(self):
        err = GrablyticError("ERROR_GEO_BLOCKED", "msg", True)
        assert err.suggests_vpn is True
        assert err.to_dict()["suggests_vpn"] is True



class TestClassifyError:
    def test_geo_blocked(self):
        exc = Exception("This video is not available in your country")
        err = classify_error(exc)
        assert err.error_type == "ERROR_GEO_BLOCKED"
        assert err.recoverable is True

    def test_age_restricted(self):
        exc = Exception("Sign in to confirm your age")
        err = classify_error(exc)
        assert err.error_type == "ERROR_AGE_RESTRICTED"
        assert err.recoverable is True

    def test_bot_check_maps_to_forbidden_for_cookie_guidance(self):
        exc = Exception(
            "ERROR: [youtube] RhxEmvngWBY: Sign in to confirm you're not "
            "a bot. Use --cookies-from-browser or --cookies")
        err = classify_error(exc)
        assert err.error_type == "ERROR_FORBIDDEN"
        assert err.recoverable is True

    def test_private_video(self):
        exc = Exception("this video is private")
        err = classify_error(exc)
        assert err.error_type == "ERROR_PRIVATE"
        assert err.recoverable is True

    def test_video_unavailable(self):
        exc = Exception("Video unavailable")
        err = classify_error(exc)
        assert err.error_type == "ERROR_UNAVAILABLE"
        assert err.recoverable is False

    def test_rate_limited(self):
        exc = Exception("HTTP Error 429")
        err = classify_error(exc)
        assert err.error_type == "ERROR_RATE_LIMITED"
        assert err.recoverable is True

    def test_forbidden(self):
        exc = Exception("HTTP Error 403")
        err = classify_error(exc)
        assert err.error_type == "ERROR_FORBIDDEN"
        assert err.recoverable is True

    def test_no_formats(self):
        exc = Exception("no video formats found")
        err = classify_error(exc)
        assert err.error_type == "ERROR_FORMAT_UNAVAILABLE"
        assert err.recoverable is True

    def test_drm(self):
        exc = Exception("DRM")
        err = classify_error(exc)
        assert err.error_type == "ERROR_DRM"
        assert err.recoverable is False

    def test_unknown_error(self):
        exc = Exception("some random error")
        err = classify_error(exc)
        assert err.error_type == "ERROR_UNKNOWN"
        assert err.recoverable is True

    def test_honors_stderr(self):
        exc = Exception("transient glitch")
        err = classify_error(exc, stderr="quota exceeded")
        assert err.error_type == "ERROR_QUOTA_EXCEEDED"
        assert err.recoverable is False

    def test_case_insensitive_matching(self):
        exc = Exception("HTTP ERROR 429")
        err = classify_error(exc)
        assert err.error_type == "ERROR_RATE_LIMITED"

    def test_file_sharing_violation(self):
        exc = Exception("file sharing violation")
        err = classify_error(exc)
        assert err.error_type == "ERROR_FILE_LOCKED"
