#!/bin/bash
# Verify the actual packaged app without importing media into Photos.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "BLOCKED: packaged app verification requires macOS." >&2
  exit 78
fi
[[ $# -eq 1 ]] || { echo "Usage: bash ci-verify-app.sh <build-output-directory>" >&2; exit 64; }
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd -P)"
BUILD_OUT="$(cd "$1" && pwd -P)"
EVIDENCE="$PROJECT_ROOT/build/ci-evidence"
mkdir -p "$EVIDENCE"
touch "$EVIDENCE/SmokeStarted"
PLIST="$EVIDENCE/CIVerification.plist"
plutil -create xml1 "$PLIST"
plutil -insert status -string FAILED "$PLIST"
plutil -insert sourceCommit -string "${GITHUB_SHA:-LOCAL_UNRECORDED}" "$PLIST"
plutil -insert applePhotosLivePlaybackVerified -bool false "$PLIST"
plutil -insert notarized -bool false "$PLIST"
APP_PID=""
DEBUG_PID=""

finish() {
  local result=$?
  trap - EXIT
  for process in "$APP_PID" "$DEBUG_PID"; do
    if [[ -n "$process" ]] && kill -0 "$process" 2>/dev/null; then
      kill -TERM "$process" 2>/dev/null || true
      # Avoid leaving a GUI process behind if a smoke check fails.
      sleep 1
      kill -KILL "$process" 2>/dev/null || true
      wait "$process" 2>/dev/null || true
    fi
  done
  local reports="${HOME}/Library/Logs/DiagnosticReports"
  for report in "$reports"/Revive*.ips "$reports"/Revive*.crash; do
    if [[ -f "$report" && "$report" -nt "$EVIDENCE/SmokeStarted" ]]; then
      mkdir -p "$EVIDENCE/CrashReports"
      cp "$report" "$EVIDENCE/CrashReports/" || true
    fi
  done
  plutil -insert exitCode -integer "$result" "$PLIST" || true
  plutil -convert json -o "$EVIDENCE/CIVerification.json" "$PLIST" || true
  exit "$result"
}
trap finish EXIT

[[ "$(plutil -extract status raw "$BUILD_OUT/BuildReceipt.json")" == BUILT_TESTED_NOT_DEVICE_ACCEPTED ]]
[[ "$(plutil -extract nativeTests raw "$BUILD_OUT/BuildReceipt.json")" == PASS ]]
shasum -a 256 -c "$BUILD_OUT/SHA256SUMS.txt" | tee "$EVIDENCE/ArchiveHashVerification.txt"
ARCHIVE_ROOT="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/revive-smoke.XXXXXX")"
ditto -x -k "$BUILD_OUT/Revive-Enhanced-macOS.zip" "$ARCHIVE_ROOT"
APP="$ARCHIVE_ROOT/Revive.app"
BIN="$APP/Contents/MacOS/Revive"
[[ -x "$BIN" ]]
codesign --verify --strict --verbose=2 "$APP" 2> "$EVIDENCE/PackagedSignatureVerification.txt"
codesign -d --verbose=4 "$APP" 2> "$EVIDENCE/PackagedSignatureDetails.txt"
ARCHITECTURES="$(lipo -archs "$BIN")"
[[ "$ARCHITECTURES" == *arm64* && "$ARCHITECTURES" == *x86_64* ]]
printf '%s\n' "$ARCHITECTURES" > "$EVIDENCE/PackagedArchitectures.txt"
plutil -insert packagedArchive -string PASS "$PLIST"

# Start the release executable extracted from the downloadable archive. No file
# argument is supplied, so this only opens its normal empty app window.
"$BIN" > "$EVIDENCE/ReleaseStartup.log" 2>&1 &
APP_PID=$!
for ((second = 0; second < 12; second++)); do
  sleep 1
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    startup_status=0
    wait "$APP_PID" || startup_status=$?
    APP_PID=""
    printf 'Release exited before the 12-second observation ended (exit %s).\n' "$startup_status" >&2
    exit 1
  fi
done
plutil -insert releaseStartup -string ALIVE_FOR_12_SECONDS "$PLIST"
kill -TERM "$APP_PID"
for ((second = 0; second < 5; second++)); do
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$APP_PID" 2>/dev/null; then
  echo "Release did not terminate after the bounded smoke check." >&2
  exit 1
fi
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

# Use the existing DEBUG-only offscreen UI harness with the tracked synthetic
# fixture. This is a rendering check, separate from the release startup check.
cd "$PROJECT_ROOT"
swift build -c debug 2>&1 | tee "$EVIDENCE/DebugUIBuild.log"
DEBUG_BIN="$(swift build -c debug --show-bin-path)/Revive"
SNAPSHOT="$EVIDENCE/NativeUISmoke.png"
REVIVE_LANG=zh-Hans "$DEBUG_BIN" --ui-smoke \
  "$PROJECT_ROOT/Tests/ReviveTests/Fixtures/TEST_synthetic_six_seconds.mp4" \
  "$SNAPSHOT" > "$EVIDENCE/NativeUISmoke.log" 2>&1 &
DEBUG_PID=$!
for ((second = 0; second < 75; second++)); do
  kill -0 "$DEBUG_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$DEBUG_PID" 2>/dev/null; then
  echo "Native UI rendering and actual preview exceeded 75 seconds." >&2
  exit 1
fi
wait "$DEBUG_PID"
DEBUG_PID=""
grep -q 'UI smoke OK' "$EVIDENCE/NativeUISmoke.log"
grep -q 'actual JPG/MOV preview verified' "$EVIDENCE/NativeUISmoke.log"
[[ -s "$SNAPSHOT" ]]
sips -g pixelWidth -g pixelHeight "$SNAPSHOT" > "$EVIDENCE/NativeUISnapshotDimensions.txt"
plutil -insert debugNativeUIRendering -string PNG_RENDERED "$PLIST"

# The image fixture is retained by the real still-motion acceptance test. Run
# the actual model preview/GIF path and capture its existing image controls.
shopt -s nullglob
image_fixtures=("$EVIDENCE"/StillMotion-Core-debug-*/TEST_still_source.png)
[[ ${#image_fixtures[@]} -eq 1 ]] || { echo 'Expected one retained still-motion fixture.' >&2; exit 1; }
IMAGE_SNAPSHOT="$EVIDENCE/NativeImageUISmoke.png"
REVIVE_LANG=zh-Hans REVIVE_UI_SMOKE_GIF=1 "$DEBUG_BIN" --ui-smoke \
  "${image_fixtures[0]}" "$IMAGE_SNAPSHOT" > "$EVIDENCE/NativeImageUISmoke.log" 2>&1 &
DEBUG_PID=$!
for ((second = 0; second < 90; second++)); do
  kill -0 "$DEBUG_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$DEBUG_PID" 2>/dev/null; then
  echo 'Native image preview and real GIF export exceeded 90 seconds.' >&2
  exit 1
fi
wait "$DEBUG_PID"
DEBUG_PID=""
grep -q 'image motion + GIF verified' "$EVIDENCE/NativeImageUISmoke.log"
grep -q 'UI smoke OK' "$EVIDENCE/NativeImageUISmoke.log"
[[ -s "$IMAGE_SNAPSHOT" ]]
sips -g pixelWidth -g pixelHeight "$IMAGE_SNAPSHOT" > "$EVIDENCE/NativeImageUISnapshotDimensions.txt"
plutil -insert debugImageMotionAndGIF -string VERIFIED "$PLIST"
plutil -replace status -string PACKAGED_STARTUP_AND_UI_SMOKE_PASSED "$PLIST"
printf '%s\n' 'Packaged release startup and DEBUG native UI rendering passed. Photos LIVE playback is unverified.'
