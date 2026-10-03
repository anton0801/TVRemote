#!/bin/zsh
# Regenerates the Xcode project and builds for the iOS Simulator.
# Usage: Tools/build.sh [extra xcodebuild args]
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodegen generate --quiet
xcodebuild build \
  -project TVRemoteScreenMirroring.xcodeproj \
  -scheme TVRemoteScreenMirroring \
  -destination "platform=iOS Simulator,name=${SIMULATOR_NAME:-iPhone 16}" \
  -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO "$@"
