#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$root/client/build/ios/iphoneos/Runner.app"
platform=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$app/Info.plist")
if [[ "$platform" != 'iPhoneOS' ]]; then
  echo 'Expected a physical-device iPhoneOS build.' >&2
  exit 1
fi
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")
xcrun lipo -verify_arch arm64 "$app/$executable"

mkdir -p "$root/artifacts/tmp" "$root/artifacts/releases"
stage=$(mktemp -d "$root/artifacts/tmp/ios-unsigned.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
mkdir "$stage/Payload"
ditto "$app" "$stage/Payload/Runner.app"
ipa="$root/artifacts/releases/GlobalSend-iPad-unsigned.ipa"
(cd "$stage" && ditto -c -k --keepParent Payload "$ipa")
unzip -t "$ipa"
echo "Unsigned IPA: $ipa"
