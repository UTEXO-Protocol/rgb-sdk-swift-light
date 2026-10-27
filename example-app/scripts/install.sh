#!/usr/bin/env bash
#
# Build the example app for the iOS Simulator and install it on a simulator.
#
#   install.sh            install on the booted simulator
#   install.sh <UDID>     install on that simulator (it must be booted)
#
# Boot one first, e.g. `xcrun simctl boot "iPhone 16"` or open Simulator.app.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
app_dir="$(cd "$here/.." && pwd)"
derived="${EXAMPLE_DERIVED_DATA:-$app_dir/../.build/example-app}"
device="${1:-booted}"

xcodebuild -quiet -project "$app_dir/UTEXOExample.xcodeproj" -scheme UTEXOExample \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived" build
xcrun simctl install "$device" "$derived/Build/Products/Debug-iphonesimulator/UTEXOExample.app"
echo "installed org.utexo.UTEXOExample on $device" >&2
