# Revive CLI

Convert an MP4/MOV into an Apple Live Photo pair (a JPEG/HEIC still + a MOV) without re-encoding the video.

The video bitstream is stream-copied into the output `.MOV` — byte-for-byte identical to the source (verifiable with `ffmpeg -f framemd5`). The still is extracted at full source resolution.

## Requirements

- Python 3.9+
- **ffmpeg** — `brew install ffmpeg` (macOS) / `sudo apt install ffmpeg` (Linux)
- **exiftool** — `brew install exiftool` / `sudo apt install libimage-exiftool-perl`
- macOS only, for the native backend (recommended): `python3 -m pip install pyobjc`
- optional: `pip install Pillow` — bumps the extracted JPEG from quality ~93 (ffmpeg's ceiling) to quality 97 with 4:4:4 chroma

The tool detects your OS and picks the backend automatically:

| Platform | Video metadata | Image metadata | still-image-time track |
|---|---|---|---|
| macOS (`apple` backend) | AVFoundation passthrough | exiftool (in-place) | ✅ written |
| any (`exiftool` backend) | exiftool (in-place) | exiftool (in-place) | ⚠️ not written* |

\* Pairs generally still import as Live Photos without it (identifiers are what iOS matches on), but the `apple` backend is the fully compliant path.

## Usage

```bash
# whole video (warns if > 3s)
python3 revive_cli.py clip.mp4

# trim: 3 seconds starting at 0:04, custom output folder and name
python3 revive_cli.py clip.mp4 --start 4.0 --duration 3.0 -o out/ --name IMG_0042

# choose the key still frame (relative to the trimmed clip; default = midpoint)
python3 revive_cli.py clip.mp4 --duration 3 --frame-time 1.2

# HEIC still instead of JPEG (macOS)
python3 revive_cli.py clip.mp4 --heic

# verify an existing pair
python3 revive_cli.py --verify out/IMG_0042.JPG out/IMG_0042.MOV
```

Every conversion ends with a verification checklist that reads the metadata back from both files and confirms the identifiers match:

```
Verification checklist:
  ✅ image has MakerNotes:ContentIdentifier
  ✅ video has Keys:ContentIdentifier (com.apple.quicktime.content.identifier)
  ✅ identifiers match
  ✅ video has still-image-time metadata track
  ✅ file basenames match
```

## Where quality is preserved (and where it isn't)

- **Remux/trim**: always `ffmpeg -c copy` (stream copy). The compressed bitstream is moved into the `.MOV` container untouched. Verify yourself:

  ```bash
  ffmpeg -i source.mp4 -map 0:v -c copy -f h264 - | md5
  ffmpeg -i IMG_0042.MOV -map 0:v -c copy -f h264 - | md5   # identical
  ```

- **Metadata stamping**: the macOS backend rewrites the container in AVFoundation *passthrough* mode (no decode/encode); exiftool edits metadata blocks in place. Neither touches media data.
- **Still frame**: decoded once from the (bit-identical) video at full resolution, saved at JPEG quality 97 (Pillow) / `-q:v 1` (ffmpeg fallback), or HEIC at max quality via `sips`.
- **Re-encoding happens in exactly two cases**, each printed as a warning, always at visually lossless `libx264 -crf 12`:
  1. the source codec can't exist in a QuickTime container (e.g. VP9/AV1);
  2. you pass `--exact` (see below).

### Lossless trimming cuts at keyframes

Stream copy can only cut where the video has a keyframe. Phone/screen recordings often have keyframes several seconds apart, so `--start 4 --duration 3` may produce a clip that starts earlier / runs longer than requested (the tool tells you when this happens). If you need a frame-accurate cut, add `--exact` — one re-encode at `libx264 -crf 12`, which is visually indistinguishable from the source.

## Importing the pair into an iPad photo library

The golden rule: **both files must arrive in Photos together, as files, with their metadata intact.**

### AirDrop from a Mac (most reliable)

1. In Finder, select **both** `IMG_XXXX.JPG` and `IMG_XXXX.MOV` (⌘-click).
2. Right-click → Share → AirDrop → your iPad.
3. iPadOS saves them into Photos as a single Live Photo automatically.

If AirDrop shows two separate "Save" prompts, accept both; Photos merges them on import.

### iCloud Photos upload

1. On any browser, go to iCloud.com → Photos.
2. Click Upload and select **both files in one upload operation**.
3. iCloud pairs them server-side; the Live Photo appears on every synced device.

Alternatively on a Mac with iCloud Photos enabled: open the Photos app, then File → Import… and select both files together.

### Known pitfalls

- **The Files app usually breaks the pair.** Saving the two files to Files and tapping them imports only the still image (or only a video). Don't route through Files.
- **Messaging apps strip metadata.** WhatsApp/Telegram/etc. recompress and discard the ContentIdentifier. Email attachments sometimes survive, but AirDrop/iCloud are the reliable paths.
- **Import both at once.** Importing the JPG today and the MOV tomorrow gives you a photo and a video, not a Live Photo.
- **Matching basenames matter.** `IMG_0042.JPG` + `IMG_0042.MOV` — the tool enforces this; don't rename just one afterwards.
- **Verify before transferring** if in doubt: `python3 revive_cli.py --verify a.JPG a.MOV` tells you exactly which metadata field is missing.

## Technical notes

A Live Photo isn't one file — it's a pair linked by a shared asset identifier (UUID):

| File | Role | Linking metadata |
|---|---|---|
| `IMG_XXXX.JPG` / `.HEIC` | still image | Apple MakerNotes `ContentIdentifier` |
| `IMG_XXXX.MOV` | short video | `com.apple.quicktime.content.identifier`, plus a `still-image-time` metadata track marking the key-photo frame |

When both files carry the same UUID and are imported together, Photos merges them into one Live Photo. The `still-image-time` track marks which frame is the key photo; converters that omit it still usually pair, but the key frame isn't preserved.

## Project structure

```
cli/
├── revive_cli.py      # CLI + ffmpeg pipeline + exiftool backend + verification
├── apple_metadata.py  # macOS-native writer (AVFoundation passthrough + CoreGraphics)
└── README.md
```

`convert()` takes a `Job` dataclass — batch mode later is just building a list of `Job`s and looping.

## TODO

- After a conversion on macOS, reveal both output files in Finder (`open -R`),
  mirroring the GUI app's `activateFileViewerSelecting`. Seeing that it's a
  *pair* makes it less likely someone AirDrops only one of the two files. The
  files are already correct — this is purely a delivery-experience improvement.

> Built with AI assistance.

（繁體中文：[README.zh-Hant.md](README.zh-Hant.md)）
