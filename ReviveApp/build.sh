#!/bin/bash
# Build and verify a new native app; never install over an existing application.
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "BLOCKED: a Mac with the macOS SDK and Swift 5.9+ is required." >&2
  exit 78
fi
MODE="universal"
if [[ $# -gt 0 ]]; then
  [[ $# -eq 1 && "$1" == "--native" ]] || {
    echo "Usage: bash build.sh [--native]. No installation or overwrite is performed." >&2
    exit 64
  }
  MODE="native"
fi
for tool in swift codesign lipo ditto plutil python3; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 78; }
done
ROOT="$(pwd -P)"
OUT="$ROOT/build/Enhanced-$(date +%Y%m%d-%H%M%S)-$(uuidgen)"
mkdir -p "$OUT"
RECEIPT="$OUT/BuildReceipt.json"
PLIST="$OUT/BuildReceipt.plist"
plutil -create xml1 "$PLIST"
plutil -insert status -string FAILED "$PLIST"
plutil -insert applePhotosLivePlaybackVerified -bool false "$PLIST"
plutil -insert buildMode -string "$MODE" "$PLIST"
plutil -insert sourcePath -string "$ROOT" "$PLIST"
finish_receipt() { plutil -convert json -o "$RECEIPT" "$PLIST"; }
trap finish_receipt EXIT

find Sources Tests Support -type f \( -name '*.swift' -o -name '*.plist' -o -name '*.mp4' -o -name '*.mov' \) -exec shasum -a 256 {} \; > "$OUT/source-sha256.txt"
shasum -a 256 build.sh ci-*.py ci-*.sh >> "$OUT/source-sha256.txt"
swift --version > "$OUT/SwiftVersion.txt"
python3 ci-natural-recovery.py
plutil -insert nativeNaturalStallRecovery -string VERIFIED "$PLIST"
python3 ci-recovery-counterfactual.py
plutil -insert recoveryCounterfactual -string EXPECTED_FAILURE_VERIFIED "$PLIST"
swift test 2>&1 | tee "$OUT/NativeTests.log"
plutil -insert nativeTests -string PASS "$PLIST"
plutil -insert debugNativeTests -string PASS "$PLIST"
# Exercise optimized native writer scheduling too; a Debug-only pass previously
# missed the intermittent readiness callback stall reproduced in Release.
swift test -c release 2>&1 | tee -a "$OUT/NativeTests.log"
plutil -insert releaseNativeTests -string PASS "$PLIST"
python3 ci-verify-writer-recovery.py
plutil -insert nativeStallRecovery -string VERIFIED "$PLIST"

ARCH_FLAGS=(--arch "$(uname -m)")
if [[ "$MODE" == "universal" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build -c release "${ARCH_FLAGS[@]}" 2>&1 | tee "$OUT/NativeBuild.log"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/Revive"
[[ -x "$BIN" ]] || { echo "No built executable: $BIN" >&2; exit 1; }
ARCHITECTURES="$(lipo -archs "$BIN")"
if [[ "$MODE" == "universal" ]]; then
  [[ "$ARCHITECTURES" == *arm64* && "$ARCHITECTURES" == *x86_64* ]] || {
    echo "Build is not universal: $ARCHITECTURES" >&2; exit 1;
  }
fi

APP="$OUT/Revive.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/Revive"
chmod 755 "$APP/Contents/MacOS/Revive"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Support/icon/Revive.icns "$APP/Contents/Resources/Revive.icns"
cp Support/fonts/GreatVibes-Regular.ttf Support/fonts/OFL.txt "$APP/Contents/Resources/Fonts/"
cp ../LICENSE "$APP/Contents/Resources/LICENSE.txt"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP" 2> "$OUT/SignatureVerification.txt"
plutil -lint "$APP/Contents/Info.plist"
plutil -insert architectures -string "$ARCHITECTURES" "$PLIST"
plutil -insert nativeBuild -string PASS "$PLIST"
plutil -insert signature -string AD_HOC_VERIFIED_NOT_NOTARIZED "$PLIST"
plutil -insert appPath -string "$APP" "$PLIST"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Revive-Enhanced-macOS.zip"
shasum -a 256 "$OUT/Revive-Enhanced-macOS.zip" > "$OUT/SHA256SUMS.txt"
plutil -replace status -string BUILT_TESTED_NOT_DEVICE_ACCEPTED "$PLIST"
echo "Built: $APP"
echo "Archive: $OUT/Revive-Enhanced-macOS.zip"
echo "No application was installed. Photos LIVE playback still requires device acceptance."
