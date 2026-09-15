"""Pytest test configuration and global fixtures for grablytic_engine tests."""

import pytest
import grablytic_engine.downloader as dl_mod


@pytest.fixture(autouse=True)
def _auto_reset_downloader_shutdown():
    """Ensure every test starts and ends with a clean shutdown state."""
    if hasattr(dl_mod, "reset_shutdown_for_tests"):
        dl_mod.reset_shutdown_for_tests()
    yield
    if hasattr(dl_mod, "reset_shutdown_for_tests"):
        dl_mod.reset_shutdown_for_tests()
    if hasattr(dl_mod, "stop_cleanup_thread"):
        dl_mod.stop_cleanup_thread()
