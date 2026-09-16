#!/usr/bin/env bash
# End-to-end check of ipa-install-on-mac, judged by effect: builds the probe
# app (test/probe.m), installs it into a scratch directory, launches it, and
# reads what the probe itself logged -- the idiom and screen UIKit handed it,
# the device model sysctl reports, the keychain, where a run-time GL lookup
# lands, and every touch it received. Only lines logged after each launch's
# own marker count, so nothing an earlier launch wrote can pass a check.
#
# Three installs and a --configure, 23 checks:
#
#   default     shipped idiom, the binary's own SDK kept, sandboxed, the
#               embedded framework loads, dlsym(RTLD_DEFAULT, "gl...") answers
#               OpenGL ES, and a keychain item survives a relaunch (the shim)
#   mac idiom   --mac-idiom runs the app in the Mac idiom, and a --dylib
#               source (test/extra.c) is built, linked and loads
#   playtools   --resolution 1080p forces a 1920x1080 screen, the device model
#               reads iPad13,8, --map K=0.25,0.75 turns a K key press into a
#               touch at exactly that fraction of the window, and a keychain
#               item survives a relaunch (PlayChain)
#   configure   --configure --resolution 1600x900 takes effect on relaunch
#
# The key press goes through System Events, so the terminal needs
# Accessibility; without it that one check is skipped, loudly. What is left
# behind: the probe's sandbox container, which containermanagerd owns, and
# one copy of the probe in ~/.Trash per install that replaced another (the
# installer trashes the previous copy, and these three share a directory).
#
# Usage: test/e2e.sh
#        env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin test/e2e.sh
#          -- the same run with the tools a stock macOS has: /bin/bash 3.2
#             through the #! line, and /usr/bin/python3 3.9

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
# check WHAT COMMAND...: the command decides, and every check reads the same.
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

# ── What the installed app says about itself ────────────────────────────────
# grep without -q on the reading side of a pipe: -q exits at the first match
# and SIGPIPEs the producer, which pipefail then counts as a failed check.
entitlements() { codesign -d --entitlements - "$APP" 2>/dev/null; }
has_entitlement()  { entitlements | grep -F "$1" >/dev/null; }
# An app with no entitlements at all lacks everything, which would make a
# negative check pass for the wrong reason: there must be some to look at.
# Captured first rather than piped twice -- `grep -q` would exit at the first
# line and SIGPIPE codesign, which pipefail then counts as a failed check.
lacks_entitlement() {
  local ents
  ents=$(entitlements)
  [ -n "$ents" ] && ! printf '%s\n' "$ents" | grep -F "$1" >/dev/null
}
links() { otool -L "$APP/Probe" 2>/dev/null | grep -F "$1" >/dev/null; }
stamped_sdk() { otool -l "$APP/Probe" | grep -A4 LC_BUILD_VERSION | grep -F "sdk $1" >/dev/null; }
reported() { grep -F "$1" "$W/out" >/dev/null; }   # a line of the installer's summary

quit_probe() {
  pkill -f "$APP/Probe" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$APP/Probe" >/dev/null || return 0
    sleep 0.3
  done
}
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
  # LaunchServices can refuse an open moments after quit_probe killed the
  # previous instance ("_LSOpenURLsWithCompletionHandler() failed with error
  # -600", on 6 of 9 runs of the unchanged suite, 2026-09-16), so a refused
  # open is retried rather than counted as a launch that did not happen.
  local tries=0
  until open "$APP" 2>"$W/open.err"; do
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] || { cat "$W/open.err"; return 1; }
    [ "$tries" -gt 1 ] || echo "  note: LaunchServices refused the open ($(tr -d '\n' < "$W/open.err")); retrying"
    sleep 0.5
  done
  for _ in $(seq 1 40); do logged ' launch ' && return 0; sleep 0.25; done
  return 1
}
# Install the probe into the scratch directory; its summary goes to $W/out,
# which the checks below read. An install that fails ends the run: every
# check after it would be measuring the previous install.
install_probe() {
  "$CLI" "$W/probe.ipa" --dest "$W/apps" "$@" >"$W/out" 2>"$W/err" \
    || { bad "install $*: $(cat "$W/err")"; exit 1; }
}

echo "Building the probe ..."
"$HERE/make-probe-ipa.sh" "$W/probe.ipa" >/dev/null || { echo "could not build the probe (needs Xcode's iOS SDK)"; exit 2; }
unzip -q -o "$W/probe.ipa" 'Payload/Probe.app/Probe' -d "$W/x"
SDK=$(otool -l "$W/x/Payload/Probe.app/Probe" | awk '/LC_BUILD_VERSION/ { c = 1 } c && $1 == "sdk" && !d { print $2; d = 1 }')

echo "default install"
install_probe --reset
check "the binary keeps its own SDK ($SDK)" stamped_sdk "$SDK"
check "sandboxed" has_entitlement app-sandbox
check "OpenGL ES redirect linked (the probe links OpenGL ES)" reported 'opengl es:'
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

echo "--mac-idiom and --dylib install"
install_probe --mac-idiom --dylib "$HERE/extra.c"
check "summary names the extra library" reported 'libextra.dylib (--dylib)'
if launch; then
  check "Mac idiom (5)" logged ' launch idiom=5 '
  check "the --dylib source was built, linked and loaded" logged 'extra dylib loaded'
else
  bad "the probe did not launch"
fi

echo "--playtools install"
rm -f "$PC/PlayChain/$BID.db"      # so the keychain check sees a first write
install_probe --resolution 1080p --aspect 16:9 --map K=0.25,0.75
check "PlayTools linked" links 'PlayTools.framework/PlayTools'
check "AKInterface in the app's PlugIns" test -d "$APP/PlugIns/AKInterface.bundle"
check "summary reports the keymap" reported 'K@0.25,0.75'
# This app's own PlayChain database, and not a subpath of the directory that
# holds every other PlayTools app's.
check "sandbox rules name this app only" has_entitlement "PlayChain/$BID.db"
check "sandbox rules do not open the whole directory" lacks_entitlement "subpath \"$PC\")"
if launch; then
  check "screen forced to 1920x1080" logged 'screen=1920x1080 '
  check "device model spoofed" logged 'hw.machine=iPad13,8'
  check "keychain item stored (PlayChain)" logged 'keychain miss=.* add=0 '
  pid=$(pgrep -f "$APP/Probe" | head -1)
  frontmost=0
  for _ in 1 2 3; do
    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1 \
      && { frontmost=1; break; }
    sleep 0.5
  done
  if [ "$frontmost" -eq 1 ]; then
    sleep 1
    # The first press after the window activates reaches the probe as "touch
    # ended" only (its began is lost; measured in the first spike too), and
    # how long activation takes varies (two fixed presses missed on 3 of 9
    # runs, 2026-09-16): press until the touch is logged, at most five times.
    for _ in 1 2 3 4 5; do
      osascript -e 'tell application "System Events" to key code 40' >/dev/null 2>&1   # K
      sleep 1
      logged 'touch began .* nx=0\.250 ny=0\.750' && break
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
# --open on a bundle LaunchServices refuses to launch: the settings are
# written and the refusal is reported, but it is not a failure of the
# configure. Inside a function `open ... && echo` is subject to set -e where
# the same line at top level was not (measured 2026-09-16: rc 1 and "failed
# at line 255" although the settings had been written), so this holds the
# extracted configure_installed_app to the old exit status.
quit_probe
mv "$APP/Probe" "$APP/Probe.aside"
"$CLI" --configure "$BID" --resolution 1600x900 --open >/dev/null 2>"$W/err"; rc=$?
mv "$APP/Probe.aside" "$APP/Probe"
check "--configure --open exits 0 when the app cannot be launched" test "$rc" -eq 0

echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
