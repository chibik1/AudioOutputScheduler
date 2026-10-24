#!/bin/zsh
# Builds "Audio Output Scheduler.app" into ./build.
#   ./build.sh            build only
#   ./build.sh --install  build and copy to /Applications (quits a running copy first)
set -e
cd "$(dirname "$0")"
ROOT="$PWD"
OUT="$ROOT/build"
WORK="$OUT/intermediates"
APP="$OUT/Audio Output Scheduler.app"
HELPER="$APP/Contents/Library/Helpers/AudioOutputSchedulerHelper.app"

rm -rf "$OUT"
mkdir -p "$WORK"

echo "==> Compiling app"
swiftc -O -parse-as-library Sources/Shared/Shared.swift Sources/App/App.swift -o "$WORK/AudioOutputScheduler"
echo "==> Compiling background helper"
swiftc -O Sources/Shared/Shared.swift Sources/Runner/main.swift -o "$WORK/AudioOutputSchedulerHelper"

echo "==> Rendering icon"
swiftc -O Tools/icon.swift -o "$WORK/icongen"
"$WORK/icongen" "$WORK/icon1024.png"
mkdir -p "$WORK/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon1024.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$WORK/icon1024.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$WORK/AppIcon.icns"

echo "==> Assembling bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources"
cp "$WORK/AudioOutputScheduler" "$APP/Contents/MacOS/"
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$WORK/AudioOutputSchedulerHelper" "$HELPER/Contents/MacOS/"
cp "$WORK/AppIcon.icns" "$HELPER/Contents/Resources/"
cp Resources/HelperInfo.plist "$HELPER/Contents/Info.plist"
codesign --force -s - "$HELPER"
codesign --force -s - "$APP"
rm -rf "$WORK"
echo "Built: $APP"

if [[ "$1" == "--install" ]]; then
  echo "==> Installing to /Applications"
  pkill -x AudioOutputScheduler 2>/dev/null || true
  pkill -x AudioOutputSchedule 2>/dev/null || true          # previous app name
  rm -rf "/Applications/Audio Output Scheduler.app" "/Applications/Audio Output Schedule.app"
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "/Applications/Audio Output Scheduler.app" \
       "/Applications/Audio Output Scheduler.app/Contents/Library/Helpers/AudioOutputSchedulerHelper.app"
  echo "Installed. Open it once so it can register its background job."
fi
