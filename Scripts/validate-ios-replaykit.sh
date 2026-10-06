#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "ERROR: $*" >&2; exit 1; }
pass() { echo "✓ $*"; }

APP_GROUP='group.com.tomaslin.Screen-Nibbles'
EXTENSION_ID='com.tomaslin.Screen-Nibbles.Broadcast'

plutil -lint \
  'Screen Nibbles/Info.plist' \
  'Screen Nibbles/ScreenNibbles.entitlements' \
  'Screen Nibbles Broadcast/Info.plist' \
  'Screen Nibbles Broadcast/Broadcast.entitlements' \
  'Screen Nibbles.xcodeproj/project.pbxproj' >/dev/null
pass 'Project, plists, and entitlements parse'

for file in \
  'Screen Nibbles/ScreenNibbles.entitlements' \
  'Screen Nibbles Broadcast/Broadcast.entitlements' \
  'Screen Nibbles Broadcast/SampleHandler.swift' \
  'Screen Nibbles/Utils/BroadcastRecordingInbox.swift'; do
  grep -q "$APP_GROUP" "$file" || fail "$file does not use $APP_GROUP"
done
pass 'App Group matches in app, extension, writer, and inbox'

grep -q 'com.apple.broadcast-services-upload' 'Screen Nibbles Broadcast/Info.plist' \
  || fail 'Broadcast Upload extension point is missing'
grep -q 'RPBroadcastProcessModeSampleBuffer' 'Screen Nibbles Broadcast/Info.plist' \
  || fail 'ReplayKit sample-buffer process mode is missing'
grep -q 'SampleHandler' 'Screen Nibbles Broadcast/Info.plist' \
  || fail 'SampleHandler principal class is missing'
pass 'ReplayKit Broadcast Upload extension plist is correct'

grep -q "$EXTENSION_ID" 'Screen Nibbles/Views/VideoCapture/ReplayKitRecordingView.swift' \
  || fail 'In-app ReplayKit picker does not target the embedded extension'
grep -q "$EXTENSION_ID" 'Screen Nibbles.xcodeproj/project.pbxproj' \
  || fail 'Broadcast extension target bundle identifier does not match the picker'
grep -q 'Embed Broadcast Extension' 'Screen Nibbles.xcodeproj/project.pbxproj' \
  || fail 'App target does not embed the broadcast extension'
pass 'Picker, extension identifier, and embed phase agree'

if find 'Screen Nibbles' 'Screen Nibbles Broadcast' -name '*.swift' -print0 \
  | xargs -0 grep -nE 'import ScreenCaptureKit|\bSCStream\b|\bRPScreenRecorder\b' >/dev/null 2>&1; then
  fail 'An alternate screen-capture path exists; capture must stay ReplayKit-only'
fi
pass 'ReplayKit is the only screen-capture implementation'

grep -q 'IPHONEOS_DEPLOYMENT_TARGET = 17.0;' 'Screen Nibbles.xcodeproj/project.pbxproj' \
  || fail 'Expected iOS 17.0 deployment target'
grep -q 'SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";' 'Screen Nibbles.xcodeproj/project.pbxproj' \
  || fail 'Project is not constrained to iOS/iOS Simulator'
pass 'iOS deployment settings are present'

if command -v xcodebuild >/dev/null 2>&1; then
  echo 'Building the full app + embedded ReplayKit extension for iOS Simulator…'
  xcodebuild \
    -project 'Screen Nibbles.xcodeproj' \
    -target 'Screen Nibbles' \
    -configuration Debug \
    -sdk iphonesimulator \
    CODE_SIGNING_ALLOWED=NO \
    build
  pass 'Xcode simulator build succeeded'
else
  echo 'NOTE: xcodebuild is unavailable here; run this script on a Mac with Xcode for the final SDK build.'
fi

cat <<'CHECKS'

Physical-iPhone ReplayKit check (required; Simulator cannot validate Control Center broadcasting):
  1. Install a signed Debug/Release build whose app and extension both include the App Group.
  2. In Screen Nibbles, tap Record Screen and invoke Apple's ReplayKit broadcast picker.
  3. Also verify Control Center -> touch and hold Screen Recording -> Screen Nibbles -> Start Broadcast.
  4. Scroll a long portrait page, stop from Apple's recording indicator, return to Screen Nibbles, and confirm automatic processing.
  5. Repeat with a landscape/horizontal swipe and with an interruption/orientation change.
  6. Force-close and relaunch after a completed broadcast; confirm finalized captures are still discovered and partial files are ignored.
CHECKS
