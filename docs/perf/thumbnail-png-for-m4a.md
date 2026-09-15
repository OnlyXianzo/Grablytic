# Thumbnail PNG for m4a (field-failure fix)

## Symptom (from exported logs)
`Audio/Saregama … - Aaj Ki Raat … .m4a` failed at EmbedThumbnail:
`[ipod] Could not find tag for codec mjpeg` → `Conversion failed!` →
download marked failed although audio bytes were complete.

## Root cause
Default cover art is JPG (mjpeg). The mp4/ipod muxer has no mjpeg tag, so
ffmpeg cannot mux a JPG thumbnail into `.m4a`. The existing PNG toggle
(Settings → Lossless thumbnails) already avoids this, but defaults leave
every m4a audio download broken out of the box.

## Fix
`opts_builder.py`: when the resolved audio codec is `m4a` and the cover
format is JPG, force PNG (one INFO line logged). Video containers and other
audio codecs keep the user's toggle choice; an explicit PNG choice is
untouched. MP3 (ID3) embeds mjpeg fine — no override there.

## Evidence
- New: 4 `test_opts_builder.py` tests (m4a+jpg→png, m4a+png→png,
  mp3+jpg→jpg, video+jpg→jpg).
- Existing Dart toggle chain (`pngThumbnails` → `thumbnail_format`) already
  covered by `download_config_test.dart` — 6 passed, confirms no toggle
  regression.
- `pytest engine/tests/`: 458 passed. `flutter analyze`: clean.

## Verify on device
Download any audio (m4a default) with the PNG toggle OFF: expect
`.m4a` with embedded art + a `Using PNG cover art for m4a output` log line,
no EmbedThumbnail error.
