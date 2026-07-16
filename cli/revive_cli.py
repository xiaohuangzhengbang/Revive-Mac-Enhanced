#!/usr/bin/env python3
"""revive-cli — turn any MP4/MOV into an Apple Live Photo pair with ZERO quality loss.

A Live Photo is two files sharing one asset identifier (UUID):

  IMG_XXXX.JPG  — still image, UUID in Apple MakerNotes "ContentIdentifier"
  IMG_XXXX.MOV  — video, UUID in "com.apple.quicktime.content.identifier",
                  plus a "com.apple.quicktime.still-image-time" metadata track
                  marking the key-photo frame

The video is never re-encoded: trimming/remuxing uses ffmpeg stream copy, and
metadata is written either natively (macOS AVFoundation passthrough — compressed
bitstream copied byte-for-byte) or with exiftool (in-place metadata edit).
Re-encoding happens only when the source codec cannot live in a QuickTime
container at all, and then at visually lossless settings (libx264 -crf 12).

Usage:
  python3 revive_cli.py clip.mp4
  python3 revive_cli.py clip.mp4 --start 4.0 --duration 3.0 -o out/
  python3 revive_cli.py clip.mp4 --frame-time 1.2 --name IMG_0042
  python3 revive_cli.py --verify out/IMG_0042.JPG out/IMG_0042.MOV
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import json
import os
import platform
import random
import shutil
import subprocess
import sys
import tempfile
import uuid as uuid_mod
from pathlib import Path

LIVE_PHOTO_TYPICAL_MAX_S = 3.05

# Codecs that can be stream-copied straight into a QuickTime .mov that iOS accepts
QT_COPYABLE_VIDEO = {"h264", "hevc", "mjpeg", "prores"}
QT_COPYABLE_AUDIO = {"aac", "alac", "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be"}

# 2x2 white JPEG carrying a genuine Apple MakerNotes block (ContentIdentifier =
# all zeros). exiftool cannot CREATE Apple MakerNotes from scratch, but it can
# copy this block into any JPEG and then edit the identifier inside it.
DONOR_MAKERNOTE_JPEG_B64 = (
    "/9j/4AAQSkZJRgABAQAASABIAAD/4QCeRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAABJJ8AAcAAABFAAAAUKABAAMAAAABAAEAAKACAAQAAAABAAAAAqADAAQAAAABAAAAAgAAAABBcHBsZSBpT1MAAAFNTQABABEAAgAAACUAAAAgAAAAADAwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMAAA/8AAEQgAAgACAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgMDBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A/fyiiigD/9k="
)

IS_MACOS = platform.system() == "Darwin"

_apple = None  # lazily imported apple_metadata module


def apple_backend_available() -> bool:
    global _apple
    if _apple is not None:
        return True
    if not IS_MACOS:
        return False
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import apple_metadata  # noqa: PLC0415
        _apple = apple_metadata
        return True
    except ImportError:
        return False


# --------------------------------------------------------------------------
# External tools
# --------------------------------------------------------------------------

EXTRA_TOOL_DIRS = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]


def find_tool(name: str) -> str | None:
    path = shutil.which(name)
    if path:
        return path
    for d in EXTRA_TOOL_DIRS:
        candidate = Path(d) / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def install_hint(tool: str) -> str:
    system = platform.system()
    if system == "Darwin":
        return f"Install it with:  brew install {tool}"
    if system == "Linux":
        pkg = {"ffmpeg": "ffmpeg", "exiftool": "libimage-exiftool-perl"}.get(tool, tool)
        return f"Install it with:  sudo apt install {pkg}   (or your distro's equivalent)"
    return (
        f"Download it from https://ffmpeg.org/download.html"
        if tool == "ffmpeg"
        else "Download it from https://exiftool.org (rename exiftool(-k).exe to exiftool.exe and put it on PATH)"
    )


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        raise RuntimeError(
            f"Command failed ({result.returncode}): {' '.join(cmd)}\n{result.stderr.strip()}"
        )
    return result


# --------------------------------------------------------------------------
# ffprobe / ffmpeg
# --------------------------------------------------------------------------

def ffprobe_info(ffprobe: str, path: Path) -> dict:
    result = run([
        ffprobe, "-v", "error", "-print_format", "json",
        "-show_format", "-show_streams", str(path),
    ])
    return json.loads(result.stdout)


def stream_of(info: dict, kind: str) -> dict | None:
    return next((s for s in info.get("streams", []) if s.get("codec_type") == kind), None)


def duration_of(info: dict) -> float:
    fmt = info.get("format", {})
    if fmt.get("duration"):
        return float(fmt["duration"])
    video = stream_of(info, "video")
    if video and video.get("duration"):
        return float(video["duration"])
    raise RuntimeError("Could not determine input duration")


@dataclasses.dataclass
class MovResult:
    path: Path
    video_copied: bool
    audio_copied: bool | None  # None = no audio stream
    duration: float


def prepare_mov(
    ffmpeg: str,
    ffprobe: str,
    input_path: Path,
    out_path: Path,
    start: float | None,
    duration: float | None,
    exact: bool = False,
) -> MovResult:
    """Trim/remux the input into a .mov, stream-copying whenever possible."""
    info = ffprobe_info(ffprobe, input_path)
    video = stream_of(info, "video")
    audio = stream_of(info, "audio")
    if video is None:
        raise RuntimeError(f"No video stream found in {input_path}")

    vcodec = video.get("codec_name", "")
    acodec = audio.get("codec_name", "") if audio else None

    copy_video = vcodec in QT_COPYABLE_VIDEO and not exact
    if exact:
        print("  ! --exact: re-encoding video (libx264 -crf 12, visually lossless) "
              "for frame-accurate trimming")
    copy_audio = acodec in QT_COPYABLE_AUDIO if audio else None

    cmd = [ffmpeg, "-y", "-v", "error"]
    if start:
        cmd += ["-ss", f"{start:.6f}"]
    cmd += ["-i", str(input_path)]
    if duration:
        cmd += ["-t", f"{duration:.6f}"]
    cmd += ["-map", "0:v:0"]
    if audio:
        cmd += ["-map", "0:a:0"]

    if copy_video:
        cmd += ["-c:v", "copy"]
    else:
        if not exact:
            print(f"  ! video codec '{vcodec}' cannot be stream-copied into QuickTime;")
            print("    re-encoding ONCE at visually lossless settings (libx264 -crf 12)")
        cmd += ["-c:v", "libx264", "-crf", "12", "-preset", "slow", "-pix_fmt", "yuv420p"]
    if audio:
        if copy_audio:
            cmd += ["-c:a", "copy"]
        else:
            print(f"  ! audio codec '{acodec}' not QuickTime-compatible; re-encoding audio to AAC 256k")
            cmd += ["-c:a", "aac", "-b:a", "256k"]

    if start and copy_video:
        # stream-copy trims snap to the nearest keyframe at/before --start
        cmd += ["-avoid_negative_ts", "make_zero"]

    cmd += ["-f", "mov", str(out_path)]
    run(cmd)

    out_info = ffprobe_info(ffprobe, out_path)
    return MovResult(
        path=out_path,
        video_copied=copy_video,
        audio_copied=copy_audio,
        duration=duration_of(out_info),
    )


def extract_still(
    ffmpeg: str, mov_path: Path, frame_time: float, out_path: Path, heic: bool
) -> Path:
    """Grab the key frame from the (stream-copied) MOV at full source resolution."""
    if heic:
        # lossless PNG first, then convert with sips (macOS) at max quality
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
            png_path = Path(tmp.name)
        try:
            run([ffmpeg, "-y", "-v", "error", "-ss", f"{frame_time:.6f}",
                 "-i", str(mov_path), "-frames:v", "1", "-update", "1", str(png_path)])
            run(["sips", "-s", "format", "heic", "-s", "formatOptions", "best",
                 str(png_path), "--out", str(out_path)])
        finally:
            png_path.unlink(missing_ok=True)
    else:
        try:
            from PIL import Image  # noqa: PLC0415
        except ImportError:
            Image = None
        if Image is not None:
            # lossless PNG first, then Pillow at quality 97 with 4:4:4 chroma
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
                png_path = Path(tmp.name)
            try:
                run([ffmpeg, "-y", "-v", "error", "-ss", f"{frame_time:.6f}",
                     "-i", str(mov_path), "-frames:v", "1", "-update", "1", str(png_path)])
                Image.open(png_path).convert("RGB").save(
                    out_path, "JPEG", quality=97, subsampling=0, optimize=True
                )
            finally:
                png_path.unlink(missing_ok=True)
        else:
            # mjpeg qscale 1 is ffmpeg's maximum JPEG quality (≈ libjpeg 93-95);
            # `pip install Pillow` bumps this to quality 97
            run([ffmpeg, "-y", "-v", "error", "-ss", f"{frame_time:.6f}",
                 "-i", str(mov_path), "-frames:v", "1", "-q:v", "1", "-update", "1",
                 str(out_path)])
    if not out_path.is_file() or out_path.stat().st_size == 0:
        raise RuntimeError(f"Failed to extract still frame at {frame_time:.3f}s")
    return out_path


# --------------------------------------------------------------------------
# Metadata backends
# --------------------------------------------------------------------------

def stamp_image(image: Path, asset_id: str, exiftool: str | None) -> None:
    """Write the asset id into the image's Apple MakerNotes ContentIdentifier.

    Preferred path is exiftool: it edits metadata in place and never touches the
    compressed image data. exiftool cannot CREATE an Apple MakerNotes block from
    scratch, so we first transplant a donor block from an embedded 2x2 JPEG,
    then edit the identifier inside it (works for JPEG and HEIC).

    Fallback is CoreGraphics (macOS), which re-encodes the image — pinned to
    max quality, but exiftool is strictly better."""
    if exiftool:
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
            tmp.write(base64.b64decode(DONOR_MAKERNOTE_JPEG_B64))
            donor = Path(tmp.name)
        try:
            run([exiftool, "-overwrite_original", "-tagsFromFile", str(donor),
                 "-MakerNotes", str(image)])
            run([exiftool, "-overwrite_original",
                 f"-MakerNotes:ContentIdentifier={asset_id}", str(image)])
        finally:
            donor.unlink(missing_ok=True)
    elif apple_backend_available():
        print("  ! exiftool not found — stamping the still via CoreGraphics, which "
              "re-encodes it once at max quality.\n"
              "    " + install_hint("exiftool") + "  to keep the still bit-exact.")
        _apple.write_image_asset_id(str(image), asset_id)
    else:
        raise RuntimeError("No way to write image metadata. " + install_hint("exiftool"))


def stamp_video_apple(mov: Path, asset_id: str, still_time: float) -> None:
    """macOS-native AVFoundation passthrough rewrite: bitstreams copied
    byte-for-byte, adds content identifier AND the still-image-time track."""
    tmp_out = mov.with_name(f".{mov.stem}.stamped.mov")
    tmp_out.unlink(missing_ok=True)
    try:
        _apple.write_video_asset_id_and_still_time(str(mov), str(tmp_out), asset_id, still_time)
        os.replace(tmp_out, mov)
    finally:
        tmp_out.unlink(missing_ok=True)


def stamp_video_exiftool(exiftool: str, mov: Path, asset_id: str) -> None:
    """Cross-platform: writes the content identifier in place. NOTE: cannot add
    the still-image-time metadata track (that requires container-level muxing —
    only the apple backend does it)."""
    run([exiftool, "-overwrite_original",
         f"-Keys:ContentIdentifier={asset_id}", str(mov)])


# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------

@dataclasses.dataclass
class Check:
    label: str
    ok: bool | None  # None = could not determine
    detail: str


def exiftool_json(exiftool: str, path: Path, extra: list[str] | None = None) -> dict:
    result = run([exiftool, "-j", "-G1", *(extra or []), str(path)])
    return json.loads(result.stdout)[0]


def verify_pair(
    image: Path, mov: Path, exiftool: str | None, expect_still_time: bool = True
) -> list[Check]:
    checks: list[Check] = []

    image_id = video_id = None
    still_time_present: bool | None = None

    if exiftool:
        img_meta = exiftool_json(exiftool, image)
        image_id = next(
            (v for k, v in img_meta.items() if k.endswith(":ContentIdentifier")), None
        )
        mov_meta = exiftool_json(exiftool, mov, extra=["-ee"])
        video_id = next(
            (v for k, v in mov_meta.items()
             if k.endswith(":ContentIdentifier") and k.startswith("Keys")), None
        )
        still_time_present = any(k.endswith(":StillImageTime") for k in mov_meta)
    elif apple_backend_available():
        image_id = _apple.read_image_asset_id(str(image))
        video_id = _apple.read_video_asset_id(str(mov))
        still_time_present = _apple.video_has_still_image_time_track(str(mov))
    else:
        checks.append(Check(
            "metadata reader available", None,
            "neither exiftool nor pyobjc found — cannot verify. " + install_hint("exiftool"),
        ))
        return checks

    checks.append(Check(
        "image has MakerNotes:ContentIdentifier",
        bool(image_id), image_id or "MISSING — iOS will treat the image as a plain photo",
    ))
    checks.append(Check(
        "video has Keys:ContentIdentifier (com.apple.quicktime.content.identifier)",
        bool(video_id), video_id or "MISSING — iOS cannot link the video to the still",
    ))
    checks.append(Check(
        "identifiers match",
        bool(image_id) and image_id == video_id,
        "match" if image_id and image_id == video_id
        else f"image={image_id!r} video={video_id!r}",
    ))
    label_sit = "video has still-image-time metadata track (com.apple.quicktime.still-image-time)"
    if still_time_present is None:
        checks.append(Check(label_sit, None, "could not inspect timed metadata on this platform"))
    elif still_time_present:
        checks.append(Check(label_sit, True, "present"))
    elif expect_still_time:
        checks.append(Check(
            label_sit, False,
            "MISSING — the apple backend should have written this track; the file was "
            "not stamped correctly",
        ))
    else:
        checks.append(Check(
            label_sit, None,
            "not written (known limitation of the exiftool backend — pairs generally "
            "still import fine; on macOS run `python3 -m pip install pyobjc` to enable "
            "the native backend, which writes this track)",
        ))
    checks.append(Check(
        "file basenames match",
        image.stem == mov.stem,
        f"{image.name} / {mov.name}",
    ))
    return checks


def print_checklist(checks: list[Check]) -> bool:
    all_ok = True
    print("\nVerification checklist:")
    for c in checks:
        mark = "✅" if c.ok else ("⚠️ " if c.ok is None else "❌")
        if c.ok is False:
            all_ok = False
        print(f"  {mark} {c.label}")
        print(f"      {c.detail}")
    return all_ok


# --------------------------------------------------------------------------
# Conversion pipeline
# --------------------------------------------------------------------------

@dataclasses.dataclass
class Job:
    """One conversion. Batch mode later = build a list of Jobs and loop."""
    input_path: Path
    output_dir: Path
    name: str | None = None
    start: float | None = None
    duration: float | None = None
    frame_time: float | None = None  # relative to the trimmed clip
    exact: bool = False  # frame-accurate trim (re-encodes at crf 12)
    heic: bool = False
    backend: str = "auto"  # auto | apple | exiftool
    verify: bool = True


def pick_backend(requested: str, exiftool: str | None) -> str:
    if requested == "apple":
        if not IS_MACOS:
            raise RuntimeError("--backend apple only works on macOS")
        if not apple_backend_available():
            raise RuntimeError(
                "pyobjc is not installed. Install the native backend with:\n"
                "  python3 -m pip install pyobjc\n"
                "(pulls in the AVFoundation/Quartz bindings this tool uses)"
            )
        return "apple"
    if requested == "exiftool":
        if not exiftool:
            raise RuntimeError("exiftool not found. " + install_hint("exiftool"))
        return "exiftool"
    # auto: on macOS prefer the native backend (it's the only one that can
    # write the still-image-time track); otherwise exiftool
    if IS_MACOS and apple_backend_available():
        return "apple"
    if exiftool:
        if IS_MACOS:
            print("  note: using exiftool backend. For 100% Live-Photo compliance "
                  "(still-image-time track), install the native backend:\n"
                  "        python3 -m pip install pyobjc")
        return "exiftool"
    if IS_MACOS:
        raise RuntimeError(
            "No metadata backend available. Install one of:\n"
            "  python3 -m pip install pyobjc     (native macOS backend, recommended)\n"
            "  brew install exiftool               (cross-platform backend)"
        )
    raise RuntimeError("exiftool not found. " + install_hint("exiftool"))


def unique_name(output_dir: Path, requested: str | None, ext: str) -> str:
    if requested:
        return requested
    for _ in range(100):
        name = f"IMG_{random.randint(0, 9999):04d}"
        if not (output_dir / f"{name}{ext}").exists() and not (output_dir / f"{name}.MOV").exists():
            return name
    raise RuntimeError("Could not find a free IMG_XXXX name in the output directory")


def convert(job: Job, ffmpeg: str, ffprobe: str, exiftool: str | None) -> tuple[Path, Path]:
    backend = pick_backend(job.backend, exiftool)
    if job.heic and not IS_MACOS:
        raise RuntimeError("--heic requires macOS (HEIC encoding uses the system's "
                           "`sips` tool); use the default JPEG output instead")

    info = ffprobe_info(ffprobe, job.input_path)
    src_duration = duration_of(info)
    start = job.start or 0.0
    if start >= src_duration:
        raise RuntimeError(f"--start {start:.2f}s is beyond the video's end ({src_duration:.2f}s)")
    clip_duration = min(job.duration or (src_duration - start), src_duration - start)
    if clip_duration > LIVE_PHOTO_TYPICAL_MAX_S:
        print(f"  ⚠️  clip is {clip_duration:.1f}s — Live Photos are typically ≤3s. "
              "iOS will accept it, but consider --duration 3")

    job.output_dir.mkdir(parents=True, exist_ok=True)
    img_ext = ".HEIC" if job.heic else ".JPG"
    name = unique_name(job.output_dir, job.name, img_ext)
    image_path = job.output_dir / f"{name}{img_ext}"
    mov_path = job.output_dir / f"{name}.MOV"

    print(f"  input    : {job.input_path}  ({src_duration:.2f}s)")
    if job.start or job.duration:
        print(f"  trim     : start={start:.2f}s duration={clip_duration:.2f}s"
              + (" (stream copy — cut snaps to nearest keyframe)" if job.start else ""))

    mov = prepare_mov(ffmpeg, ffprobe, job.input_path, mov_path, job.start, job.duration,
                      exact=job.exact)
    print(f"  video    : {mov_path.name}  ({mov.duration:.2f}s, "
          + ("stream-copied, zero quality loss" if mov.video_copied else "re-encoded @ crf 12")
          + ")")
    if mov.video_copied and (job.start or job.duration) and mov.duration > clip_duration + 0.25:
        print(f"  ⚠️  clip came out {mov.duration:.2f}s instead of {clip_duration:.2f}s: "
              "lossless trims cut at keyframes, and this video's keyframes are sparse.\n"
              "      Re-run with --exact for a frame-accurate cut (one visually lossless "
              "re-encode at crf 12).")

    frame_time = job.frame_time if job.frame_time is not None else mov.duration / 2
    if not 0 <= frame_time <= mov.duration:
        raise RuntimeError(f"--frame-time {frame_time:.2f}s is outside the clip (0–{mov.duration:.2f}s)")
    extract_still(ffmpeg, mov_path, frame_time, image_path, job.heic)
    print(f"  still    : {image_path.name}  (frame @ {frame_time:.2f}s, full source resolution)")

    asset_id = str(uuid_mod.uuid4()).upper()
    stamp_image(image_path, asset_id, exiftool)
    if backend == "apple":
        stamp_video_apple(mov_path, asset_id, frame_time)
    else:
        stamp_video_exiftool(exiftool, mov_path, asset_id)
    print(f"  asset id : {asset_id}  (backend: {backend}"
          + (", image via exiftool" if exiftool else "") + ")")

    if job.verify:
        checks = verify_pair(image_path, mov_path, exiftool,
                             expect_still_time=(backend == "apple"))
        if not print_checklist(checks):
            raise RuntimeError(
                "Verification FAILED — see the ❌ items above for exactly which "
                "metadata field is missing."
            )

    return image_path, mov_path


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="revive-cli",
        description="Convert a video into an Apple Live Photo pair (JPG/HEIC + MOV) "
                    "with zero quality loss.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("input", nargs="?", type=Path, help="input video (MP4/MOV/…)")
    parser.add_argument("--start", type=float, default=None, metavar="SECONDS",
                        help="trim: start time in the source video")
    parser.add_argument("--duration", type=float, default=None, metavar="SECONDS",
                        help="trim: clip length (Live Photos are typically ≤3s)")
    parser.add_argument("--frame-time", type=float, default=None, metavar="SECONDS",
                        help="key still frame time, relative to the trimmed clip "
                             "(default: clip midpoint)")
    parser.add_argument("--exact", action="store_true",
                        help="frame-accurate trimming: re-encode the video once at "
                             "visually lossless settings (libx264 -crf 12) instead of "
                             "stream copy, which can only cut at keyframes")
    parser.add_argument("-o", "--output-dir", type=Path, default=Path("live_photos"),
                        help="output folder")
    parser.add_argument("--name", default=None, metavar="IMG_XXXX",
                        help="output basename (default: random IMG_XXXX)")
    parser.add_argument("--heic", action="store_true",
                        help="write the still as HEIC instead of JPEG (macOS only)")
    parser.add_argument("--backend", choices=["auto", "apple", "exiftool"], default="auto",
                        help="metadata writer: apple = native macOS AVFoundation "
                             "(most reliable, writes still-image-time track); "
                             "exiftool = cross-platform")
    parser.add_argument("--no-verify", action="store_true",
                        help="skip the automatic post-conversion verification")
    parser.add_argument("--verify", nargs=2, metavar=("IMAGE", "VIDEO"), default=None,
                        help="verify an existing pair (no conversion) and print the checklist")
    args = parser.parse_args(argv)

    exiftool = find_tool("exiftool")

    if args.verify:
        image, video = Path(args.verify[0]), Path(args.verify[1])
        for p in (image, video):
            if not p.is_file():
                print(f"error: {p} does not exist", file=sys.stderr)
                return 2
        ok = print_checklist(verify_pair(image, video, exiftool, expect_still_time=False))
        print("\nResult: " + ("pair is a valid Live Photo ✅" if ok else "pair is NOT valid ❌"))
        return 0 if ok else 1

    if not args.input:
        parser.error("input video required (or use --verify IMAGE VIDEO)")
    if not args.input.is_file():
        print(f"error: input not found: {args.input}", file=sys.stderr)
        return 2

    ffmpeg = find_tool("ffmpeg")
    ffprobe = find_tool("ffprobe")
    if not ffmpeg or not ffprobe:
        print("error: ffmpeg/ffprobe not found. " + install_hint("ffmpeg"), file=sys.stderr)
        return 2

    print(f"revive-cli — {platform.system()} detected")
    try:
        job = Job(
            input_path=args.input,
            output_dir=args.output_dir,
            name=args.name,
            start=args.start,
            duration=args.duration,
            frame_time=args.frame_time,
            exact=args.exact,
            heic=args.heic,
            backend=args.backend,
            verify=not args.no_verify,
        )
        image_path, mov_path = convert(job, ffmpeg, ffprobe, exiftool)
    except RuntimeError as exc:
        print(f"\nerror: {exc}", file=sys.stderr)
        return 1

    print(f"\nDone. Live Photo pair written to {job.output_dir}/:")
    print(f"  {image_path.name} + {mov_path.name}")
    print("Import BOTH files together (AirDrop both to the iPad, or add both to "
          "iCloud Photos). See README for pitfalls.")
    # TODO: 在 macOS 上轉完自動用 Finder 選中這兩個檔案（open -R），
    # 比照 GUI 版 activateFileViewerSelecting 的引導,降低使用者
    # 只拿到其中一個的機會。exiftool/ffmpeg 已確保檔案本身正確,
    # 這純粹是交付體驗的改進。
    return 0


if __name__ == "__main__":
    sys.exit(main())
