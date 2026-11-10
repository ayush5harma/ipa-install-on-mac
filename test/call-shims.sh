#!/usr/bin/env bash
# The two call shims, without an app or a camera:
#
#   callkit  lib/ipa-callkit.m built as the installer builds it and linked
#            into test/callkit-probe.m, whose classes have the shapes of
#            WhatsApp's call manager: every CallKit check answers no-CallKit
#            (instance, class, and many-argument methods), while a same-named
#            method that is not a BOOL and an unrelated BOOL keep their own
#            answers
#   camera   lib/ipa-camera.m's wrapper on stand-in devices
#            (test/camera-probe.m): a 10 fps request on a fixed 30 fps format
#            becomes 30 (WhatsApp's video call on a Mac webcam, 2026-11-11),
#            supported rates and the reset pass untouched, a subclass setter
#            that calls super runs each original once, and at load all six
#            real AVFoundation setters are wrapped on the build Mac
#
# Usage: test/call-shims.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W=$(mktemp -d "${TMPDIR:-/tmp}/ipa-call-shims.XXXXXX")
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0

ok()  { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

SDK=$(xcrun --sdk macosx --show-sdk-path) || { echo "no macOS SDK (xcode-select --install)"; exit 2; }
build() {
  xcrun clang -target arm64-apple-ios14.0-macabi -isysroot "$SDK" -O2 -Wall -fobjc-arc "$@" 2>"$W/clang.err" \
    || { echo "build failed:"; cat "$W/clang.err"; exit 2; }
}
# The flags bin/ipa-install-on-mac builds each library with.
build -dynamiclib -framework Foundation -install_name @rpath/libipacallkit.dylib \
  -o "$W/libipacallkit.dylib" "$HERE/../lib/ipa-callkit.m"
build -framework Foundation -L"$W" -lipacallkit -Wl,-rpath,"$W" -o "$W/callkit-probe" "$HERE/callkit-probe.m"
build -framework Foundation -framework AVFoundation -framework CoreMedia -o "$W/camera-probe" "$HERE/camera-probe.m"

run() { "$W/$1" >"$W/$1.out" 2>"$W/$1.err"; local s=$?; sed 's/^/        /' "$W/$1.out"; return $s; }
# NAME=value, the whole line after the =
got() { sed -n "s/^$2=//p" "$W/$1.out"; }

echo "callkit"
check "the probe ran" run callkit-probe
check "-isCallKitSupported answers NO" test "$(got callkit-probe supported)" = 0
check "+isCallKitSupported answers NO" test "$(got callkit-probe class_supported)" = 0
check "-isCallKitDisabled answers YES" test "$(got callkit-probe disabled)" = 1
check "callDataManagerRequestShouldUseCallKitForCall: answers NO" test "$(got callkit-probe request)" = 0
check "the 7-argument per-call check answers NO" test "$(got callkit-probe per_call)" = 0
check "an unrelated BOOL keeps its answer" test "$(got callkit-probe unrelated)" = 1
check "a same-named non-BOOL method is left alone" test "$(got callkit-probe non_bool)" = untouched
check "it says what it changed (5 methods)" grep -q 'ipacallkit: 5 CallKit checks' "$W/callkit-probe.err"

echo "camera"
check "the probe ran" run camera-probe
check "10 fps on a 30-30 format becomes 30, each setter once" test "$(got camera-probe fixed_10)" = "30 calls=1/1"
check "30 fps on a 30-30 format passes" test "$(got camera-probe fixed_30)" = "30 calls=1/1"
check "kCMTimeInvalid (reset) passes" test "$(got camera-probe fixed_reset)" = "invalid calls=1/1"
check "10 fps on a 5-30 format passes" test "$(got camera-probe wide_10)" = "10 calls=1/1"
check "60 fps on a 5-30 format becomes 30" test "$(got camera-probe wide_60)" = "30 calls=1/1"
check "50 fps between a 15 and a 60 range becomes 60" test "$(got camera-probe two_50)" = "60 calls=1/1"
check "it says what it changed" grep -q 'ipacamera: setActiveVideoMaxFrameDuration: on probe 30-30: 10.00 fps' "$W/camera-probe.err"
check "on this Mac it wrapped all 6 real AVFoundation setters" grep -q 'ipacamera: wrapped 6 frame-duration setters' "$W/camera-probe.err"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
