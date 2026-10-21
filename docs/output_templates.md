# Output Templates

The output template decides the file name (and optionally the
subdirectory) of every download. It is a yt-dlp output template: a
string with `%(field)s` placeholders that yt-dlp expands from the
media metadata.

Default:

```
%(uploader)s - %(title)s [%(id)s].%(ext)s
```

## The two rules that matter

### 1. Include a field that is unique per item

yt-dlp **overwrites** an existing video file by default (`overwrites`
defaults to `None`, which means "overwrite only non-video files" — a
video file is replaced). So a template built only from fields that can
repeat silently DESTROYS the earlier download:

| Template | Result |
|---|---|
| `%(title)s.%(ext)s` | Two videos with the same title → the second replaces the first |
| `%(uploader)s - %(title)s.%(ext)s` | Same uploader + same title → same collision |
| `%(uploader)s - %(title)s [%(id)s].%(ext)s` | Unique per video ✅ |

The engine logs a warning when a template has no unique field
(`%(id)s`, `%(autonumber)s`, `%(playlist_index)s`,
`%(playlist_autonumber)s`, `%(video_autonumber)s`).

`%(id)s` is yt-dlp's own convention — its default template is
`%(title)s [%(id)s].%(ext)s`. It is stable for the same video (a
re-download keeps the name) and unique across videos.

### 2. Stay inside the output directory

A template must be a RELATIVE path. The engine rejects:

| Rejected | Why |
|---|---|
| `/abs/path` | Escapes the output directory |
| `~/path` | Escapes the output directory |
| `C:\path` | Escapes the output directory |
| `..` segments | Escapes the output directory |
| A NUL byte | Truncates the path |
| Templates longer than 256 chars | Path abuse |

A rejected template falls back to the default. A template with `/` in
it (for example `%(playlist)s/%(title)s.%(ext)s`) is fine: yt-dlp
creates the subdirectory inside the output directory.

## Length

A filesystem limits a **single path component** to `NAME_MAX` — 255
bytes on ext4, on Android's FUSE-backed `/storage/emulated/0`, and on
macOS/Windows. Bytes, not characters: an emoji costs 4 and a full-width
`｜` costs 3, so a 100-character emoji title can already be over the
limit. The kernel, not yt-dlp, rejects the name.

yt-dlp's `trim_file_name` does **not** solve this. It counts characters
rather than bytes, and it splits the name on its last two dots, so a
title containing a dot escapes trimming completely (upstream yt-dlp
issues #2314, #5526, #6974, #12035, #12386). The engine therefore leaves
`trim_file_name` unset and bounds the expanded name itself, in
`engine/grablytic_engine/filename_guard.py`, applied by
`GuardedYoutubeDL._prepare_filename`:

| Rule | Value |
|---|---|
| Hard limit per path component | 255 bytes (`NAME_MAX_BYTES`) |
| Reserved for yt-dlp's suffixes (`.f<format_id>`, `.part`, `.temp.<ext>`) | 55 bytes |
| Budget for the prepared name | 200 bytes per component (`MAX_COMPONENT_BYTES`) |

The extension is kept, a trailing `[id]`-style marker is kept, and only a
head is cut — multi-byte characters are never split. This applies to
every template (including user templates and subdirectory templates),
so no output template can make a download fail with `[Errno 36] File
name too long`. If the bound is ever hit, keeping the unique field at
the END of the template (`... [%(id)s]`) is what preserves uniqueness
after truncation; the safest template still puts `%(id)s` FIRST:

```
%(id)s - %(uploader)s - %(title)s.%(ext)s
```

A name the kernel still rejects (an even smaller limit, a deep path)
surfaces as `ERROR_FILENAME_TOO_LONG` — a non-recoverable error that is
not auto-retried.

## Fields that leak

`%(url)s` expands to the full media URL, which for a signed YouTube
link contains the signature parameters. yt-dlp sanitizes the
characters that are illegal in a file name (`/`, `:`, `*`, `?` become
full-width equivalents), so it cannot escape the output directory, but
the URL — and its signature — ends up in the file name, and therefore
in the file listing and in any backup of the output directory. Use
`%(id)s` instead.

## Safe and unsafe field summary

| Field | Safe? | Note |
|---|---|---|
| `%(id)s` | ✅ | Unique per item — the recommended disambiguator |
| `%(title)s` | ⚠️ | Not unique; can repeat |
| `%(uploader)s` | ⚠️ | Not unique |
| `%(upload_date)s` | ⚠️ | Not unique on its own |
| `%(playlist)s` | ⚠️ | Creates a subdirectory |
| `%(ext)s` | ✅ | The extension |
| `%(autonumber)s` | ✅ | Unique within one run only |
| `%(url)s` | ❌ | Leaks the signed URL into the file name |
| `%(webpage_url)s` | ❌ | Same |
