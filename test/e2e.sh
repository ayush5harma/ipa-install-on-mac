#!/usr/bin/env bash
# End-to-end check of ipa-install-on-mac, judged by effect: builds the probe
# app (test/probe.m), installs it into a scratch directory, launches it, and
# reads what the probe itself logged -- the idiom and screen UIKit handed it,
# the device model sysctl reports, and every touch it received.
#
#   default     shipped idiom, the binary's own SDK kept, sandboxed, the
#               embedded framework loads
#   playtools   --resolution 1080p forces a 1920x1080 screen, the device model
#               reads iPad13,8, and --map K=0.25,0.75 turns a K key press into
#               a touch at exactly that fraction of the window
#   configure   --configure --resolution 1440p takes effect on the next launch
#
# The key press goes through System Events, so the terminal needs
# Accessibility; without it that one check is skipped, loudly. Leaves nothing
# behind but the probe's sandbox container, which containermanagerd owns.
#
# Usage: test/e2e.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../bin/ipa-install-on-mac"
BID=local.ipa-install-on-mac.probe
LOG="$HOME/Library/Containers/$BID/Data/Documents/probe.log"
PC="/Users/$(id -un)/Library/Containers/io.playcover.PlayCover"
# Physical path: TMPDIR is /var/folders/..., the process runs from
# /private/var/folders/..., and pkill/pgrep match the latter.
W=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ipa-e2e.XXXXXX")" && pwd -P)
APP="$W/apps/IPA Probe.app"
PASS=0; FAIL=0; SKIP=0

ok()   { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP  $*"; SKIP=$((SKIP + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
quit_probe() { pkill -f "$APP/Probe" 2>/dev/null; for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$APP/Probe" >/dev/null || return 0; sleep 0.3; done; }
cleanup() {
  quit_probe
  rm -rf "$W"
  rm -f "$PC/App Settings/$BID.plist" "$PC/PlayChain/$BID.db"
  rm -rf "$PC/Keymapping/$BID"
}
trap cleanup EXIT

launch() {  # launch, wait for the probe's launch line
  : > "$LOG" 2>/dev/null || true
  open "$APP"
  for _ in $(seq 1 40); do grep -q ' launch ' "$LOG" 2>/dev/null && return 0; sleep 0.25; done
  return 1
}
logged() { grep -E "$1" "$LOG" >/dev/null 2>&1; }

echo "Building the probe ..."
"$HERE/make-probe-ipa.sh" "$W/probe.ipa" >/dev/null || { echo "could not build the probe (needs Xcode's iOS SDK)"; exit 2; }
unzip -q -o "$W/probe.ipa" 'Payload/Probe.app/Probe' -d "$W/x"
SDK=$(otool -l "$W/x/Payload/Probe.app/Probe" | awk '/LC_BUILD_VERSION/ { c = 1 } c && $1 == "sdk" && !d { print $2; d = 1 }')

echo "default install"
"$CLI" "$W/probe.ipa" --dest "$W/apps" >/dev/null 2>"$W/err" || { bad "install: $(cat "$W/err")"; exit 1; }
check "the binary keeps its own SDK ($SDK)" sh -c "otool -l '$APP/Probe' | grep -A4 LC_BUILD_VERSION | grep -q 'sdk $SDK'"
check "sandboxed" sh -c "codesign -d --entitlements - '$APP' 2>/dev/null | grep -q app-sandbox"
if launch; then
  check "shipped idiom (iPad, 1)" logged ' launch idiom=1 '
  check "embedded framework loaded" logged 'probekit ok'
else
  bad "the probe did not launch"
fi
quit_probe

echo "--playtools install"
"$CLI" "$W/probe.ipa" --dest "$W/apps" --resolution 1080p --aspect 16:9 --map K=0.25,0.75 >"$W/out" 2>"$W/err" \
  || { bad "install: $(cat "$W/err")"; exit 1; }
check "PlayTools linked" sh -c "otool -L '$APP/Probe' | grep -q 'PlayTools.framework/PlayTools'"
check "AKInterface in the app's PlugIns" test -d "$APP/PlugIns/AKInterface.bundle"
check "summary reports the keymap" grep -q 'K@0.25,0.75' "$W/out"
if launch; then
  check "screen forced to 1920x1080" logged 'screen=1920x1080 '
  check "device model spoofed" logged 'hw.machine=iPad13,8'
  pid=$(pgrep -f "$APP/Probe" | head -1)
  if osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1; then
    sleep 1
    # Twice: the first press after the window activates reaches the probe as
    # "touch ended" only (its began is lost; measured in the first spike too),
    # every press after that as began + ended.
    for _ in 1 2; do
      osascript -e 'tell application "System Events" to key code 40' >/dev/null 2>&1   # K
      sleep 1
    done
    check "K becomes a touch at 0.25,0.75" logged 'touch began .* nx=0\.250 ny=0\.750'
  else
    skip "key press (the terminal needs Accessibility for System Events)"
  fi
else
  bad "the probe did not launch"
fi
quit_probe

echo "--configure"
"$CLI" --configure "$BID" --resolution 1440p >/dev/null 2>"$W/err" || bad "configure: $(cat "$W/err")"
if launch; then
  check "relaunch reads 1440p (2560x1440)" logged 'screen=2560x1440 '
else
  bad "the probe did not launch"
fi

echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
