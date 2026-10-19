"""The engine <-> host IPC contract.

The desktop (Dart) and Android (Kotlin) hosts speak a line-delimited
JSON protocol to this engine. Nothing pinned its shape: a host and an
engine from different builds could disagree about a field name, a
method name or an error code, and the mismatch surfaced as a silent
null or a KeyError in the middle of a download.

The contract is VERSIONED. Every request may carry `contract_version`;
the engine refuses a mismatched MAJOR version with
ERROR_CONTRACT_MISMATCH instead of guessing. A MINOR bump stays
compatible: a new optional field, a new error code.

`lib/core/engine/engine_contract.dart` mirrors these constants — keep
the two in step.
"""

CONTRACT_MAJOR = 1
CONTRACT_MINOR = 0
# What a host sends in `contract_version`.
CONTRACT_VERSION = CONTRACT_MAJOR
CONTRACT_VERSION_STRING = f"{CONTRACT_MAJOR}.{CONTRACT_MINOR}"

# The methods the engine answers. The dispatch registry in __main__.py
# must contain exactly these.
METHODS = (
    "engine/bootstrap",
    "engine/contract",
    "download/start",
    "download/cancel",
    "download/queue_status",
    "download/set_concurrency",
    "download/clear_archive",
    "formats/get",
    "playlist/info",
    "search/query",
    "resume/scan",
    "resume/report",
    "engine/update_check",
    "engine/set_update_channel",
)

# Error codes a host may receive.
ERROR_CONTRACT_MISMATCH = "ERROR_CONTRACT_MISMATCH"
ERROR_INVALID_PARAM = "ERROR_INVALID_PARAM"
ERROR_UNKNOWN_METHOD = "ERROR_UNKNOWN_METHOD"


def parse_version(raw):
    """Parse a `contract_version` into (major, minor), or None.

    Accepts an int (the major alone) or a "major.minor" string.
    """
    if isinstance(raw, bool):
        return None
    if isinstance(raw, int):
        return raw, 0
    if isinstance(raw, str):
        parts = raw.strip().split(".")
        try:
            major = int(parts[0])
            minor = int(parts[1]) if len(parts) > 1 else 0
        except (ValueError, IndexError):
            return None
        return major, minor
    return None


def contract_info() -> dict:
    """Describe the contract this engine speaks."""
    return {
        "success": True,
        "contract_version": CONTRACT_VERSION,
        "contract_major": CONTRACT_MAJOR,
        "contract_minor": CONTRACT_MINOR,
        "contract_version_string": CONTRACT_VERSION_STRING,
        "methods": list(METHODS),
    }
