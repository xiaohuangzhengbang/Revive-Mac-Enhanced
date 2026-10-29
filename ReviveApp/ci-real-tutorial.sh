#!/bin/bash
# Run only on ephemeral GitHub-hosted macOS runners. No Photos import, no user
# media, no production app modification. Actual native desktop recording only.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'BLOCKED: needs macOS' >&2; exit 78; }
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'Refusing CI screen-permission setup outside GitHub Actions.' >&2; exit 78; }
PROJECT="$(cd "$(dirname "$0")" && pwd -P)"
OUT="$PROJECT/build/real-tutorial"
mkdir -p "$OUT/originals/photo" "$OUT/originals/video" "$OUT/logs"
APP="$OUT/ReviveTutorial.app"
mkdir -p "$APP/Contents/MacOS"
cd "$PROJECT"

# Exact source provenance: the production sources must still be the tested
# release sources. CI-only files are excluded from this comparison.
APP_COMMIT=e67824ef4c087a98ba0cbb58a6800f2582260b1d
git diff --exit-code "$APP_COMMIT" -- Sources/Revive
export REVIVE_APP_SOURCE_COMMIT="$APP_COMMIT"
git rev-parse HEAD > "$OUT/logs/TutorialSourceCommit.txt"
git ls-tree -r "$APP_COMMIT" -- Sources/Revive > "$OUT/logs/ApplicationSourceTree.txt"
sw_vers > "$OUT/logs/MacOS.txt"
swift --version > "$OUT/logs/SwiftVersion.txt"

curl --fail --location --retry 2 --output "$OUT/originals/photo/red-fox-waubay-nwr-usfws.jpg" 'https://www.fws.gov/sites/default/files/2021-09/red-fox-waubay-nwr-usfws.jpg'
curl --fail --location --retry 2 --output "$OUT/originals/video/redw-WaterB-Roll_1280x720.mp4" 'https://www.nps.gov/nps-audiovideo/legacy/redw/E248DA0A-AEB5-7693-C969666B6A06E2DF/redw-WaterB-Roll_1280x720.mp4'
PHOTO="$OUT/originals/photo/red-fox-waubay-nwr-usfws.jpg"
VIDEO="$OUT/originals/video/redw-WaterB-Roll_1280x720.mp4"
[[ "$(shasum -a 256 "$PHOTO" | awk '{print $1}')" == 886190890b5438e906a8a603d1e998a7e130cb2937a8db0e4cf320f0f17f172c ]]
[[ "$(shasum -a 256 "$VIDEO" | awk '{print $1}')" == 0a47f3095c92da95e69382b2829462f6576844445f18b3acc8db6bf24dcd11f0 ]]
chmod a-w "$PHOTO" "$VIDEO"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.revive.ci.real-tutorial</string>
<key>CFBundleName</key><string>ReviveTutorial</string>
<key>CFBundleExecutable</key><string>ReviveTutorial</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST

sources=()
for source in Sources/Revive/*.swift; do
  [[ "$source" == Sources/Revive/Main.swift ]] || sources+=("$source")
done
swiftc -D DEBUG -parse-as-library -target "$(uname -m)-apple-macosx15.0" \
  "${sources[@]}" ci-real-tutorial.swift \
  -o "$APP/Contents/MacOS/ReviveTutorial" 2>&1 | tee "$OUT/logs/Compile.log"
codesign --force --sign - --identifier com.revive.ci.real-tutorial "$APP" 2> "$OUT/logs/Signature.log"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx15.0" \
  ci-real-tutorial-ax.swift -o "$OUT/ReviveTutorialAX" 2>&1 | tee "$OUT/logs/AXHelperCompile.log"
codesign --force --sign - --identifier com.revive.ci.real-tutorial.ax "$OUT/ReviveTutorialAX" 2>> "$OUT/logs/Signature.log"

# The temporary runner belongs to this single CI job. Scope the permission to
# this signed CI-only app so an unattended recording does not wait on a TCC
# prompt. Never execute this on the user's computer. Schema is introspected
# rather than assuming a macOS-version-specific INSERT column layout.
sudo python3 - "$APP" "$OUT/ReviveTutorialAX" > "$OUT/logs/EphemeralRunnerScreenPermission.json" <<'PY'
import json, sqlite3, sys, time
path = '/Library/Application Support/com.apple.TCC/TCC.db'
db = sqlite3.connect(path)
columns = [r[1] for r in db.execute('pragma table_info(access)')]
values = {'service':'kTCCServiceScreenCapture', 'client':'com.revive.ci.real-tutorial',
          'client_type':0, 'auth_value':2, 'auth_reason':4, 'auth_version':1,
          'indirect_object_identifier_type':0, 'indirect_object_identifier':'UNUSED',
          'flags':0, 'last_modified':int(time.time()), 'pid':0, 'pid_version':0,
          'boot_uuid':'UNUSED', 'last_reminded':int(time.time())}
grants = [('kTCCServiceScreenCapture','com.revive.ci.real-tutorial',0),
          ('kTCCServiceAccessibility','com.revive.ci.real-tutorial',0),
          ('kTCCServiceAccessibility',sys.argv[2],1)]
for service,client,client_type in grants:
    values.update(service=service,client=client,client_type=client_type)
    keys = [k for k in columns if k in values]
    db.execute('insert or replace into access (' + ','.join(keys) + ') values (' + ','.join('?' for _ in keys) + ')', [values[k] for k in keys])
db.commit()
rows = db.execute("select service,client,auth_value from access where client in (?,?)", ('com.revive.ci.real-tutorial',sys.argv[2])).fetchall()
print(json.dumps({'scope':'ephemeral public GitHub-hosted runner only', 'permissions':rows}))
PY

"$APP/Contents/MacOS/ReviveTutorial" "$PHOTO" "$VIDEO" "$OUT/result" > "$OUT/logs/NativeTutorial.log" 2>&1 &
PID=$!
trap 'kill -TERM "$PID" 2>/dev/null || true' EXIT
for ((second=0; second<240; second++)); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
  echo 'Native tutorial exceeded 240 seconds. No recording success claimed.' >&2
  /usr/bin/sample "$PID" 3 -file "$OUT/logs/HardTimeoutProcessSample.txt" || true
  screencapture -x "$OUT/logs/FailureDesktop.png" || true
  cat "$OUT/logs/NativeTutorial.log"
  exit 1
fi
native_status=0
wait "$PID" || native_status=$?
cat "$OUT/logs/NativeTutorial.log"
if [[ $native_status -ne 0 ]]; then
  mkdir -p "$OUT/logs/CrashReports"
  for report in "$HOME"/Library/Logs/DiagnosticReports/ReviveTutorial*.ips "$HOME"/Library/Logs/DiagnosticReports/ReviveTutorial*.crash; do
    if [[ -f "$report" ]]; then cp -p "$report" "$OUT/logs/CrashReports/"; fi
  done
  echo "Native tutorial exited with status $native_status; inspect failure JSON and actual screen evidence." >&2
  exit "$native_status"
fi
trap - EXIT
grep -q 'REAL TUTORIAL PASSED' "$OUT/logs/NativeTutorial.log"
[[ -s "$OUT/result/RealTutorialReceipt.json" ]]
[[ "$(shasum -a 256 "$PHOTO" | awk '{print $1}')" == 886190890b5438e906a8a603d1e998a7e130cb2937a8db0e4cf320f0f17f172c ]]
[[ "$(shasum -a 256 "$VIDEO" | awk '{print $1}')" == 0a47f3095c92da95e69382b2829462f6576844445f18b3acc8db6bf24dcd11f0 ]]
python3 - "$OUT/result" <<'PY'
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
receipt = json.loads((root/'RealTutorialReceipt.json').read_text())
recording = os.environ.get('REVIVE_TUTORIAL_RECORDING') != '0'
assert receipt['recordingRequired'] is recording
assert receipt['continuousRecordingVerified'] is recording
if recording:
    assert receipt['status'] == 'REAL_MEDIA_NATIVE_UI_EXPORT_AND_SCREEN_RECORDING_VERIFIED'
    assert receipt['recordedDuration'] > 35
    assert (root/receipt['recordingFile']).stat().st_size > 0
else:
    assert receipt['status'] == 'REAL_MEDIA_NATIVE_UI_EXPORT_VERIFIED_NO_CONTINUOUS_RECORDING'
    assert receipt['recordedDuration'] == 0 and receipt['recordingFile'] == ''
assert len(receipt['cases']) == 2
for case in receipt['cases']:
    assert case['sourceUnchanged'] and case['allStrictChecksPassed']
    assert case['sourceSHA256Before'] == case['sourceSHA256After']
    folder = root/case['liveFolder']
    for name in ('IMG_LIVE.JPG','IMG_LIVE.MOV','检查报告.json'):
        assert (folder/name).is_file(), (case['kind'],name)
assert receipt['cases'][1]['trimStart'] == 15 and receipt['cases'][1]['trimEnd'] == 18
assert (root/receipt['cases'][0]['gifFile']).is_file()
print(json.dumps({'status':receipt['status'],'recordingRequired':recording,'seconds':receipt['recordedDuration'],'cases':len(receipt['cases'])}))
PY
