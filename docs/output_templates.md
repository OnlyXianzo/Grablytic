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

yt-dlp's `trim_file_name` is set to **160** characters (the extension
is excluded), so the expanded file name is at most 160 characters plus
the extension — comfortably under the 255-byte limit that Linux and
Android filesystems enforce. The kernel, not yt-dlp, is what rejects
an over-long name, so the trim is what prevents that failure.

Note that trimming can itself create a collision between two long
titles that share their first 160 characters. Including `%(id)s`
after the title keeps that safe in practice only if the id falls
inside the trimmed prefix — the safest template puts `%(id)s` FIRST:

```
%(id)s - %(uploader)s - %(title)s.%(ext)s
```

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
