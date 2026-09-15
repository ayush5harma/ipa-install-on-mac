#!/usr/bin/env bash
# Build PlayTools -- the in-app layer PlayCover injects into iOS apps
# (keyboard and mouse to touch mapping, resolution control, device model,
# an emulated keychain; github.com/PlayCover/PlayTools, AGPL-3.0) -- from
# source at a pinned commit, once per commit, into a per-user cache, and print
# the built framework's path on stdout. Progress goes to stderr.
#
# Nothing of PlayTools is vendored in this repo: this fetches upstream's own
# source at the pinned commit and builds it on this Mac with Xcode, the way
# PlayCover's CI does (Carthage, from PlayTools' master). Only the result's
# path is handed back; ipa-install-on-mac embeds it in the app being
# installed.
#
# Why these build settings (measured 2026-09-16, Xcode 27.0, PlayTools 003f460):
#   -destination generic/platform=iOS
#       PlayTools is an iOS framework; the installer converts it to Mac
#       Catalyst like every other binary in the app (the same vtool call
#       PlayCover's own build phase makes). Its AKInterface plugin target is a
#       native macOS bundle and builds as one inside it.
#   FASTLANE=1
#       the PlayTools target has a SwiftLint run-script phase that FAILS the
#       build when SwiftLint is not installed ("error: SwiftLint not
#       installed") and skips itself when FASTLANE is set, which is how
#       PlayCover's fastlane lanes build it.
#   playtools/Package.resolved + -onlyUsePackageVersionsFromResolvedFile
#       PlayTools commits no Package.resolved and tracks SwordRPC's main
#       branch; SwordRPC's 2026-06-18 API change (buttons became optional)
#       broke the build of PlayTools' v3.1.0 tag outright. The pinned file
#       holds the revisions this commit was built and tested with.
#   CODE_SIGNING_ALLOWED=NO
#       the installer ad-hoc signs every binary it ships.
#
# Needs full Xcode (xcodebuild with the iOS SDK) and git; the first build
# fetches PlayTools and its Swift packages from GitHub (about a minute on an
# M2 Pro), later installs reuse the cache and need no network.
#
# Usage: playtools-build.sh        prints <cache>/playtools-<rev>/PlayTools.framework
#        playtools-build.sh --rev  prints the pinned commit and exits
# Env:   IPA_INSTALL_CACHE         cache root (default ~/Library/Caches/ipa-install-on-mac)

set -Eeuo pipefail

REV=003f4603cf22346fce33131f6a2ee0b35effbef3
URL=https://github.com/PlayCover/PlayTools

die() { echo "playtools-build: $*" >&2; exit 2; }
[ "${1:-}" = "--rev" ] && { echo "$REV"; exit 0; }
[ $# -eq 0 ] || die "usage: playtools-build.sh [--rev]"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${IPA_INSTALL_CACHE:-$HOME/Library/Caches/ipa-install-on-mac}"
DIR="$ROOT/playtools-$REV"
OUT="$DIR/PlayTools.framework"

# A complete build, not just a directory: an interrupted one leaves both the
# marker missing and the framework half-copied.
built() { [ -f "$DIR/built" ] && [ -f "$OUT/PlayTools" ] && [ -d "$OUT/PlugIns/AKInterface.bundle" ]; }
if built; then echo "$OUT"; exit 0; fi

command -v git >/dev/null 2>&1 || die "missing git"
xcodebuild -version >/dev/null 2>&1 \
  || die "PlayTools builds with full Xcode, not only the Command Line Tools: install Xcode and select it (sudo xcode-select -s /Applications/Xcode.app)"
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 \
  || die "Xcode has no iOS SDK (xcodebuild -downloadPlatform iOS)"
[ -f "$HERE/playtools/Package.resolved" ] || die "missing $HERE/playtools/Package.resolved"

# One build at a time: a second install waits for the first one's build
# rather than racing it into the same directory.
mkdir -p "$ROOT"
LOCK="$DIR.lock"
waited=0
until mkdir "$LOCK" 2>/dev/null; do
  [ "$waited" -lt 900 ] || die "another build has held $LOCK for 15 minutes; remove it if none is running"
  [ "$waited" -eq 0 ] && echo "Waiting for another PlayTools build to finish ..." >&2
  sleep 1; waited=$((waited + 1))
done
trap 'rm -rf "$LOCK"' EXIT
# Again: the build this waited for is the one that was needed.
if built; then echo "$OUT"; exit 0; fi

echo "Building PlayTools ${REV:0:7} from source (first use on this Mac, about a minute; log: $DIR/build.log) ..." >&2
rm -rf "$DIR"
mkdir -p "$DIR"
git init -q "$DIR/src"
git -C "$DIR/src" fetch -q --depth 1 "$URL" "$REV" 2>"$DIR/fetch.err" \
  || die "could not fetch $URL at $REV: $(tr '\n' ' ' < "$DIR/fetch.err")"
git -C "$DIR/src" -c advice.detachedHead=false checkout -q FETCH_HEAD
[ "$(git -C "$DIR/src" rev-parse HEAD)" = "$REV" ] || die "fetched commit is not $REV"
SPM="$DIR/src/PlayTools.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$SPM"
cp "$HERE/playtools/Package.resolved" "$SPM/Package.resolved"

if ! xcodebuild -project "$DIR/src/PlayTools.xcodeproj" -scheme PlayTools -configuration Release \
     -destination 'generic/platform=iOS' -derivedDataPath "$DIR/dd" \
     -onlyUsePackageVersionsFromResolvedFile \
     CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY= FASTLANE=1 build > "$DIR/build.log" 2>&1; then
  grep -E ': error: |^error: ' "$DIR/build.log" | sort -u | head -5 >&2 || true
  die "xcodebuild failed; the full log is $DIR/build.log"
fi
PRODUCT="$DIR/dd/Build/Products/Release-iphoneos/PlayTools.framework"
[ -f "$PRODUCT/PlayTools" ] && [ -d "$PRODUCT/PlugIns/AKInterface.bundle" ] || die "the build finished but $PRODUCT is incomplete"
# Copied aside, then renamed: another install never sees a half-copied result.
cp -R "$PRODUCT" "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
# Derived data and the Swift package checkouts are only needed to build.
rm -rf "$DIR/dd"
printf '%s\n' "$REV" > "$DIR/built"
# An earlier pin's cache: every app installed from it carries its own copy.
find "$ROOT" -mindepth 1 -maxdepth 1 -type d -name 'playtools-*' ! -name "playtools-$REV" ! -name '*.lock' \
  -exec rm -rf {} + 2>/dev/null || true
echo "$OUT"
