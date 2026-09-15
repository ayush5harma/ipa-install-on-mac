#!/usr/bin/env bash
# Build test/probe.m into an .ipa packed the way a store download is: a
# prior signature, an embedded provisioning profile, iTunesMetadata.plist at
# the archive root, and one embedded framework so the installer's nested
# signing is exercised as well as the main binary's. Needs Xcode's iOS SDK.
#
# Usage: test/make-probe-ipa.sh [OUT.ipa]    (default: $TMPDIR/ipa-probe.ipa)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${TMPDIR:-/tmp}/ipa-probe.ipa}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
SDK=$(xcrun --sdk iphoneos --show-sdk-path) || { echo "no iOS SDK: install Xcode" >&2; exit 2; }
SDKVER=$(xcrun --sdk iphoneos --show-sdk-version)
TARGET=arm64-apple-ios15.0

W=$(mktemp -d "${TMPDIR:-/tmp}/ipa-probe.XXXXXX")
trap 'rm -rf "$W"' EXIT
APP="$W/Payload/Probe.app"
mkdir -p "$APP/Frameworks/ProbeKit.framework"

# The framework: one function the app calls at launch, so a framework the
# installer failed to convert or sign stops the app at dyld, visibly.
printf 'const char *probekit_hello(void) { return "probekit ok"; }\n' > "$W/probekit.c"
xcrun clang -target "$TARGET" -isysroot "$SDK" -dynamiclib \
  -install_name @rpath/ProbeKit.framework/ProbeKit \
  -o "$APP/Frameworks/ProbeKit.framework/ProbeKit" "$W/probekit.c"
plutil -create xml1 "$APP/Frameworks/ProbeKit.framework/Info.plist"
for kv in CFBundleIdentifier=local.ipa-install-on-mac.probekit CFBundleExecutable=ProbeKit \
          CFBundlePackageType=FMWK CFBundleShortVersionString=1.0 CFBundleVersion=1 MinimumOSVersion=15.0; do
  plutil -insert "${kv%%=*}" -string "${kv#*=}" "$APP/Frameworks/ProbeKit.framework/Info.plist"
done

xcrun clang -target "$TARGET" -isysroot "$SDK" -fobjc-arc -fmodules \
  -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
  -framework UIKit -framework Foundation -framework Security -framework OpenGLES \
  -Wl,-rpath,@executable_path/Frameworks \
  "$APP/Frameworks/ProbeKit.framework/ProbeKit" \
  -o "$APP/Probe" "$HERE/probe.m"

P="$APP/Info.plist"
plutil -create xml1 "$P"
for kv in CFBundleIdentifier=local.ipa-install-on-mac.probe CFBundleExecutable=Probe \
          CFBundleName=Probe "CFBundleDisplayName=IPA Probe" CFBundlePackageType=APPL \
          CFBundleShortVersionString=1.0 CFBundleVersion=1 MinimumOSVersion=15.0 \
          DTPlatformName=iphoneos "DTSDKName=iphoneos$SDKVER"; do
  plutil -insert "${kv%%=*}" -string "${kv#*=}" "$P"
done
plutil -insert CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$P"
plutil -insert UIDeviceFamily -json '[1,2]' "$P"
plutil -insert UILaunchScreen -json '{}' "$P"
# Scene lifecycle, which an app linked against the iOS 27 SDK must adopt.
plutil -insert UIApplicationSceneManifest -json '{"UIApplicationSupportsMultipleScenes":false}' "$P"
plutil -insert UIRequiresFullScreen -bool true "$P"
# Landscape, like the games keymapping is for.
plutil -insert UISupportedInterfaceOrientations -json \
  '["UIInterfaceOrientationLandscapeLeft","UIInterfaceOrientationLandscapeRight"]' "$P"

# What a store copy carries and the installer must cope with.
printf 'not a real profile\n' > "$APP/embedded.mobileprovision"
codesign --force --sign - "$APP/Frameworks/ProbeKit.framework" >/dev/null 2>&1
codesign --force --sign - "$APP" >/dev/null 2>&1
plutil -create xml1 "$W/iTunesMetadata.plist"
plutil -insert itemName -string "IPA Probe" "$W/iTunesMetadata.plist"

rm -f "$OUT"
(cd "$W" && zip -qry "$OUT" Payload iTunesMetadata.plist)
echo "$OUT"
