#!/bin/zsh
# Build Revive.app from the SwiftPM package (no Xcode project needed).
#   ./build.sh              build only (build/Revive.app; NOT registered with
#                           the system, so it won't duplicate "Open With")
#   ./build.sh --install    build + install to /Applications + register
#   ./build.sh --install --refresh-shell   ...and restart Dock/Finder to
#                           refresh a stubborn icon cache
set -e
cd "$(dirname "$0")"

swift build -c release

APP="build/Revive.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Revive "$APP/Contents/MacOS/Revive"
cp Support/Info.plist "$APP/Contents/Info.plist"
echo "APPL????" > "$APP/Contents/PkgInfo"

# app icon (regenerate if the source script changed)
if [ ! -f Support/icon/Revive.icns ] || [ Support/make_icon.py -nt Support/icon/Revive.icns ]; then
  python3 Support/make_icon.py >/dev/null 2>&1 || echo "  (icon generation skipped — needs Pillow)"
fi
[ -f Support/icon/Revive.icns ] && cp Support/icon/Revive.icns "$APP/Contents/Resources/Revive.icns"

# bundle the Great Vibes brand font (OFL) — ATSApplicationFontsPath="Fonts"
# auto-registers it at launch, so the wordmark renders on any Mac
mkdir -p "$APP/Contents/Resources/Fonts"
cp Support/fonts/GreatVibes-Regular.ttf "$APP/Contents/Resources/Fonts/"
cp Support/fonts/OFL.txt "$APP/Contents/Resources/Fonts/"

# ad-hoc signature so TCC (photo-library permission) works locally
codesign --force --sign - "$APP"

echo
echo "✅ 建置完成: $(pwd)/$APP"

if [[ "$*" == *--install* ]]; then
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  pkill -x Revive 2>/dev/null || true
  rm -rf /Applications/Revive.app
  cp -R "$APP" /Applications/Revive.app
  codesign --force --sign - /Applications/Revive.app
  # register ONLY the /Applications copy; unregister the build copy so
  # "Open With" never shows duplicates
  "$LSREG" -u "$(pwd)/$APP" 2>/dev/null || true
  "$LSREG" -f /Applications/Revive.app
  /System/Library/CoreServices/pbs -flush 2>/dev/null || true
  echo "✅ 已安裝: /Applications/Revive.app"
  if [[ "$*" == *--refresh-shell* ]]; then
    killall Dock 2>/dev/null || true
    killall Finder 2>/dev/null || true
    echo "   (已重啟 Dock/Finder 刷新圖示)"
  fi
else
  echo "   安裝到應用程式: ./build.sh --install"
fi
