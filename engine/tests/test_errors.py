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


class TestClassifyPrecision:
    """T3-14 engine half: precise classification (no substring false
    positives, no congestion→VPN misdirection) + sanitized messages."""

    def test_drm_filename_not_drm(self):
        err = classify_error(Exception("ERROR: file 'mydrmvideo.mkv' not found"))
        assert err.error_type != "ERROR_DRM"

    def test_drm_word_still_detected(self):
        err = classify_error(Exception("This video is DRM protected"))
        assert err.error_type == "ERROR_DRM"
        assert err.recoverable is False

    def test_timeout_is_network_not_ssl(self):
        err = classify_error(Exception("Connection timed out after 30 seconds"))
        assert err.error_type == "ERROR_NETWORK"
        assert err.suggests_vpn is False

    def test_dns_is_network_not_ssl(self):
        err = classify_error(Exception("Name or service not known"))
        assert err.error_type == "ERROR_NETWORK"
        assert err.suggests_vpn is False

    def test_genuine_ssl_stays_ssl(self):
        err = classify_error(Exception("certificate verify failed: self signed"))
        assert err.error_type == "ERROR_SSL_BLOCKED"
        assert err.suggests_vpn is True

    def test_proxy_creds_scrubbed_from_message(self):
        err = classify_error(Exception("Failed: http://user:s3cret@proxy:8080/"))
        assert "s3cret" not in err.message
        assert err.message

    def test_giant_message_capped(self):
        err = classify_error(Exception("x" * 5000))
        assert len(err.message) <= 520
