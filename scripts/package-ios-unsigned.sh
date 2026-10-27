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
xcrun lipo "$app/$executable" -verify_arch arm64
extension="$app/PlugIns/ShareExtension.appex"
test -d "$extension" || { echo 'Share Extension is missing from the physical-device build.' >&2; exit 1; }
extension_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$extension/Info.plist")
xcrun lipo "$extension/$extension_executable" -verify_arch arm64

mkdir -p "$root/artifacts/tmp" "$root/artifacts/releases"
stage=$(mktemp -d "$root/artifacts/tmp/ios-unsigned.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
mkdir "$stage/Payload"
ditto "$app" "$stage/Payload/Runner.app"
# Unsigned apps have no code-signature entitlements to extract. Include the
# resolved templates for manual signing; a provisioned signature must still
# authorize the same group on both the host and extension.
group=$(/usr/libexec/PlistBuddy -c 'Print :GLOBALSEND_APP_GROUP_ID' "$app/Info.plist")
cp "$root/client/ios/Runner/Runner.entitlements" "$stage/Payload/Runner.app/GlobalSend.entitlements"
cp "$root/client/ios/ShareExtension/ShareExtension.entitlements" "$stage/Payload/Runner.app/PlugIns/ShareExtension.appex/GlobalSend.entitlements"
for entitlements in "$stage/Payload/Runner.app/GlobalSend.entitlements" "$stage/Payload/Runner.app/PlugIns/ShareExtension.appex/GlobalSend.entitlements"; do
  /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $group" "$entitlements"
done
ipa="$root/artifacts/releases/GlobalSend-iPad-unsigned.ipa"
(cd "$stage" && ditto -c -k --keepParent Payload "$ipa")
unzip -t "$ipa"
echo "Unsigned IPA: $ipa"
