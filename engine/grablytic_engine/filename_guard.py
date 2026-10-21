"""Keep generated download names inside what the filesystem can create.

The kernel rejects a *path component* longer than ``NAME_MAX`` with
``[Errno 36] File name too long``. On ext4, FUSE-backed Android storage
(``/storage/emulated/0``) and our desktop targets that limit is 255
**bytes**, not characters — an emoji or a full-width glyph costs 3-4
bytes. A perfectly ordinary social-media caption therefore produced a
508-character / 521-byte name in the field and the download died.

yt-dlp's own ``trim_file_name`` cannot be used for this: it counts
characters (``no_ext[:trim_file_name]``) and it splits the name on the
last two dots, so a dot anywhere in the title defeats it entirely — see
yt-dlp issues #2314, #5526, #6974, #12035 and #12386, and
``docs/output_templates.md``.

This module supplies a deterministic, byte-aware bound that is applied
to the name yt-dlp is about to write, for every output template. yt-dlp
reuses the same ``_prepare_filename`` result for the temp file, so
bounding it once covers the download, the ``.part`` file and the
postprocessed result.
"""

from __future__ import annotations

import re

# POSIX NAME_MAX (ext4, FUSE, APFS, NTFS): 255 bytes per component.
NAME_MAX_BYTES = 255

# yt-dlp appends to the prepared name before opening the file:
#   .f<format_id>.<ext>   per requested format when merging
#   .part                 partial download
#   .temp.<ext>           postprocessor scratch file
# Format ids are short in practice but unbounded, so reserve generously.
SUFFIX_RESERVE_BYTES = 55

# Budget for one component of the prepared template output.
MAX_COMPONENT_BYTES = NAME_MAX_BYTES - SUFFIX_RESERVE_BYTES  # 200

# Keep at least this much room for the human-readable head before we
# give up preserving a trailing "[id]" marker.
_MIN_HEAD_BYTES = 16

# A trailing " [abc123]" / "[abc]" marker (yt-dlp's own default template
# is "%(title)s [%(id)s].%(ext)s"). Cutting it off would collapse
# different long-titled items onto one file name.
_UNIQUE_TAIL_RE = re.compile(r"^(?P<head>.*?)(?P<tail> ?\[[^\[\]]{1,64}\])\s*$")

# Extensions longer than this are almost certainly part of the title,
# not a real extension; treating them as an extension would let the head
# shrink to nothing.
_MAX_EXT_BYTES = 16

_EMPTY_FALLBACK = "media"


def _byte_len(text: str) -> int:
    return len(text.encode("utf-8", "ignore"))


def _truncate_bytes(text: str, max_bytes: int) -> str:
    """Cut ``text`` to at most ``max_bytes`` UTF-8 bytes.

    A multi-byte character sliced in half is dropped by the ``ignore``
    decoder, so the result is always valid UTF-8 and never exceeds the
    budget.
    """
    if max_bytes <= 0:
        return ""
    raw = text.encode("utf-8", "ignore")
    if len(raw) <= max_bytes:
        return text
    return raw[:max_bytes].decode("utf-8", "ignore")


def _split_extension(name: str) -> tuple[str, str]:
    """Split off a plausible trailing extension, keeping the dot."""
    head, dot, ext = name.rpartition(".")
    if not head or not dot or not ext:
        return name, ""
    if "/" in ext or _byte_len(ext) > _MAX_EXT_BYTES:
        return name, ""
    return head, dot + ext


def bound_component(name: str, max_bytes: int = MAX_COMPONENT_BYTES) -> str:
    """Return ``name`` bounded to ``max_bytes`` UTF-8 bytes."""
    if not isinstance(name, str) or not name:
        return name
    if _byte_len(name) <= max_bytes:
        return name

    stem, suffix = _split_extension(name)
    budget = max_bytes - _byte_len(suffix)
    if budget <= 0:
        # Pathological "extension": bound the whole thing.
        return _truncate_bytes(name, max_bytes) or _EMPTY_FALLBACK

    tail = ""
    head = stem
    match = _UNIQUE_TAIL_RE.match(stem)
    if match:
        tail = match.group("tail")
        head = match.group("head")
        if _byte_len(tail) > budget - _MIN_HEAD_BYTES:
            tail, head = "", stem

    head_out = _truncate_bytes(head, budget - _byte_len(tail)).rstrip(" .")
    if head_out:
        return head_out + tail + suffix

    # Nothing readable survived the head cut: keep whatever fits so the
    # file still gets a valid name instead of an empty one.
    fallback = _truncate_bytes(stem, budget).strip(" .")
    return (fallback or _EMPTY_FALLBACK) + suffix


def bound_filename(path: str, max_bytes: int = MAX_COMPONENT_BYTES) -> str:
    """Bound every component of a relative output path.

    ``NAME_MAX`` applies per component, not to the whole path, so a
    template such as ``%(playlist)s/%(title)s.%(ext)s`` is bounded
    component by component.
    """
    if not isinstance(path, str) or not path:
        return path
    # yt-dlp builds templates with a backslash on Windows, so splitting on
    # "/" alone treated "Show/Episode 1.mp4" (written with a backslash) as one
    # component: the pair shared a single NAME_MAX and the episode lost its
    # tail while the show kept all of it. Separators come out as "/" because
    # the value is fed back into an output template.
    parts = re.split(r"[/\\]", path)
    return "/".join(bound_component(part, max_bytes) for part in parts)
