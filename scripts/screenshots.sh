#!/usr/bin/env bash
# Makes the README screenshots, docs/sharing.png and docs/add-device.png, on a fresh iPhone 17 Pro
# simulator with the newest iOS runtime installed. Builds a Debug app (the demo scenarios are Debug
# only), takes the `sharing` and `noDevices` scenarios at 9:41 with full bars, and deletes the
# simulator afterwards. Run it after a change to the main screen.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
work=$(mktemp -d)
sim=
cleanup() {
    [[ -n $sim ]] && { xcrun simctl shutdown "$sim" 2>/dev/null; xcrun simctl delete "$sim"; }
    rm -rf "$work"
}
trap cleanup EXIT

xcodegen generate --quiet
xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$work/dd" build -quiet
app=$work/dd/Build/Products/Debug-iphonesimulator/Tether.app
bundle=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Info.plist")

# With no runtime named, simctl picks the newest one that supports the device.
sim=$(xcrun simctl create "Tether screenshots" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)
xcrun simctl boot "$sim"
xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl status_bar "$sim" override --time 9:41 --batteryState discharging --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi
xcrun simctl ui "$sim" appearance light
xcrun simctl install "$sim" "$app"

shot() { # shot <scenario> <docs file>
    xcrun simctl launch --terminate-running-process "$sim" "$bundle" -TetherDemo "$1" >/dev/null
    sleep 3 # the list settles and the speeds animate in
    xcrun simctl io "$sim" screenshot "$work/$1.png" >/dev/null 2>&1
    # The README shows them 260 points wide, so 645 pixels stays sharp and keeps the files small.
    sips --resampleWidth 645 "$work/$1.png" --out "docs/$2" >/dev/null
    echo "docs/$2"
}
shot sharing sharing.png
shot noDevices add-device.png
