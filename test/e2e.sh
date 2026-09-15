#!/usr/bin/env bash
# End-to-end check of ipa-install-on-mac, judged by effect: builds the probe
# app (test/probe.m), installs it into a scratch directory, launches it, and
# reads what the probe itself logged -- the idiom and screen UIKit handed it,
# the device model sysctl reports, the keychain, where a run-time GL lookup
# lands, and every touch it received. Only lines logged after each launch's
# own marker count, so nothing an earlier launch wrote can pass a check.
#
#   default     shipped idiom, the binary's own SDK kept, sandboxed, the
#               embedded framework loads, dlsym(RTLD_DEFAULT, "gl...") answers
#               OpenGL ES, and a keychain item survives a relaunch (the shim)
#   mac idiom   --mac-idiom runs the app in the Mac idiom
#   playtools   --resolution 1080p forces a 1920x1080 screen, the device model
#               reads iPad13,8, --map K=0.25,0.75 turns a K key press into a
#               touch at exactly that fraction of the window, and a keychain
#               item survives a relaunch (PlayChain)
#   configure   --configure --resolution 1600x900 takes effect on relaunch
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
PASS=0; FAIL=0; SKIP=0; MARK=""

ok()   { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP  $*"; SKIP=$((SKIP + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
quit_probe() { pkill -f "$APP/Probe" 2>/dev/null; for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$APP/Probe" >/dev/null || return 0; sleep 0.3; done; }
cleanup() {
  quit_probe
  rm -rf "$W"
  rm -f "$PC/App Settings/$BID.plist" "$PC/PlayChain/$BID.db" "$PC/PlayChain/$BID.db-journal"
  rm -rf "$PC/Keymapping/$BID"
}
trap cleanup EXIT

# This launch's lines: everything after its marker.
since() { awk -v m="$MARK" 'f; $0 == m { f = 1 }' "$LOG" 2>/dev/null; }
logged() { since | grep -E "$1" >/dev/null; }
launch() {
  quit_probe
  MARK="--- e2e $(date +%s).$RANDOM"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  echo "$MARK" >> "$LOG" || { echo "cannot write the probe's log ($LOG)"; exit 2; }
  open "$APP"
  for _ in $(seq 1 40); do logged ' launch ' && return 0; sleep 0.25; done
  return 1
}
install() { "$CLI" "$W/probe.ipa" --dest "$W/apps" "$@" >"$W/out" 2>"$W/err" || { bad "install $*: $(cat "$W/err")"; exit 1; }; }

echo "Building the probe ..."
"$HERE/make-probe-ipa.sh" "$W/probe.ipa" >/dev/null || { echo "could not build the probe (needs Xcode's iOS SDK)"; exit 2; }
unzip -q -o "$W/probe.ipa" 'Payload/Probe.app/Probe' -d "$W/x"
SDK=$(otool -l "$W/x/Payload/Probe.app/Probe" | awk '/LC_BUILD_VERSION/ { c = 1 } c && $1 == "sdk" && !d { print $2; d = 1 }')

echo "default install"
install --reset
check "the binary keeps its own SDK ($SDK)" sh -c "otool -l '$APP/Probe' | grep -A4 LC_BUILD_VERSION | grep -q 'sdk $SDK'"
check "sandboxed" sh -c "codesign -d --entitlements - '$APP' 2>/dev/null | grep -q app-sandbox"
check "OpenGL ES redirect linked (the probe links OpenGL ES)" grep -q 'opengl es:' "$W/out"
if launch; then
  check "shipped idiom (iPad, 1)" logged ' launch idiom=1 '
  check "embedded framework loaded" logged 'probekit ok'
  check "GL lookup answers OpenGL ES, not desktop libGL" logged 'gl lookup=OpenGLES '
  check "keychain item stored (shim)" logged 'keychain miss=.* add=0 '
else
  bad "the probe did not launch"
fi
if launch; then
  check "keychain item read back after relaunch (shim)" logged 'keychain read=v-'
else
  bad "the probe did not relaunch"
fi

echo "--mac-idiom install"
install --mac-idiom
if launch; then check "Mac idiom (5)" logged ' launch idiom=5 '; else bad "the probe did not launch"; fi

echo "--playtools install"
rm -f "$PC/PlayChain/$BID.db"
install --resolution 1080p --aspect 16:9 --map K=0.25,0.75
check "PlayTools linked" sh -c "otool -L '$APP/Probe' | grep -q 'PlayTools.framework/PlayTools'"
check "AKInterface in the app's PlugIns" test -d "$APP/PlugIns/AKInterface.bundle"
check "summary reports the keymap" grep -q 'K@0.25,0.75' "$W/out"
check "sandbox rules name this app only" sh -c "codesign -d --entitlements - '$APP' 2>/dev/null | grep -q 'PlayChain/$BID.db' && ! codesign -d --entitlements - '$APP' 2>/dev/null | grep -q 'subpath \"$PC\")'"
if launch; then
  check "screen forced to 1920x1080" logged 'screen=1920x1080 '
  check "device model spoofed" logged 'hw.machine=iPad13,8'
  check "keychain item stored (PlayChain)" logged 'keychain miss=.* add=0 '
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
if launch; then
  check "keychain item read back after relaunch (PlayChain)" logged 'keychain read=v-'
else
  bad "the probe did not relaunch"
fi

echo "--configure"
"$CLI" --configure "$BID" --resolution 1600x900 >/dev/null 2>"$W/err" || bad "configure: $(cat "$W/err")"
if launch; then
  check "relaunch reads the new size (1600x900)" logged 'screen=1600x900 '
else
  bad "the probe did not launch"
fi

echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
