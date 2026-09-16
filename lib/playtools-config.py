#!/usr/bin/env python3
"""Write PlayTools' per-app settings and keymap for ipa-install-on-mac.

PlayTools (built by playtools-build.sh, embedded by ipa-install-on-mac
--playtools) reads two things at every launch, from paths it hardcodes as
/Users/<login>/Library/Containers/io.playcover.PlayCover/ -- upstream reverted
a portable home lookup on 2026-09-12, so this writes exactly there:

  App Settings/<bundle id>.plist   resolution, device model, keychain, input
  Keymapping/<bundle id>/          default.plist (the keymap) + .config.plist

Both are decoded all-or-nothing by Swift Codable: ONE missing or mistyped key
and that reader silently falls back to its own built-in defaults for EVERY
key (and PlayTools' defaults are not PlayCover's: noKMOnInput off,
playChain off, 1080p). So the settings file is always written whole -- the
existing file's values, the defaults for anything missing, then the options
given -- with the superset of the keys PlayTools (PlaySettings.swift) and
PlayCover (AppSettings.swift) decode, so PlayCover.app, if installed, reads
the same file. Same rule for keymaps: every field of every element.

Coordinates in a keymap are fractions of the app's window (0..1, from the top
left); an element's size is a percentage of the window's longer side, as in
PlayTools' own editor (Cmd+K in the running app), whose defaults are used.

Usage: playtools-config.py --bundle-id BID [options]    write, then summarise
       playtools-config.py --check [options]            validate options only
Run with --help for the options.
"""
import argparse
import math
import os
import plistlib
import pwd
import re
import subprocess
import sys
import tempfile
import urllib.parse

# ── Settings ────────────────────────────────────────────────────────────────
# PlayCover's writer defaults, except discordActivity (off: PlayTools would
# otherwise talk to a local Discord client) and notch (PlayTools' own default;
# it only letterboxes an Auto resolution on a notched display).
DEFAULTS = {
    "bundleIdentifier": "",
    "keymapping": True,
    "sensitivity": 50.0,
    "disableTimeout": False,
    "displayRotation": 0,
    "iosDeviceModel": "iPad13,8",
    "windowWidth": 1920,
    "windowHeight": 1080,
    "customScaler": 2.0,
    "resolution": 1,
    "aspectRatio": 1,
    "notch": False,
    "bypass": False,
    "discordActivity": {"enable": False, "applicationID": "", "details": "", "state": "", "image": ""},
    "version": "3.0.0",
    "playChain": True,
    "playChainDebugging": False,
    "inverseScreenValues": False,
    "metalHUD": False,
    "windowFixMethod": 0,
    "injectIntrospection": False,
    "rootWorkDir": True,
    "noKMOnInput": True,
    "enableScrollWheel": True,
    "hideTitleBar": False,
    "floatingWindow": False,
    "checkMicPermissionSync": False,
    "limitMotionUpdateFrequency": False,
    "disableBuiltinMouse": False,
    "resizableAspectRatioType": 0,
    "resizableAspectRatioWidth": 0,
    "resizableAspectRatioHeight": 0,
    "blockSleepSpamming": False,
    "ignoreUnityKeyboardInitializationError": False,
}
# Owned by other options, or not settings at all.
NOT_SETTABLE = {"bundleIdentifier", "discordActivity", "version", "resolution", "aspectRatio", "playChain"}

# The resolution enum PlaySettings decodes, in PlayCover's labels. CUSTOM
# carries its size in windowWidth/windowHeight; the fixed heights get their
# width from the aspect ratio; RESIZABLE takes its aspect from another key.
RES_APP_DEFAULT, RES_AUTO, RES_1080P, RES_1440P, RES_4K, RES_CUSTOM, RES_RESIZABLE = range(7)
RES_NAMES = {RES_APP_DEFAULT: "app default", RES_AUTO: "auto", RES_1080P: "1080p",
             RES_1440P: "1440p", RES_4K: "4k", RES_CUSTOM: "custom", RES_RESIZABLE: "resizable"}
RES_HEIGHT = {RES_1080P: 1080, RES_1440P: 1440, RES_4K: 2160}
RES_BY_NAME = {"app": RES_APP_DEFAULT, "app-default": RES_APP_DEFAULT, "auto": RES_AUTO,
               "1080p": RES_1080P, "1440p": RES_1440P, "4k": RES_4K, "2160p": RES_4K,
               "resizable": RES_RESIZABLE}
ASPECTS = {"4:3": (0, 4, 3), "16:9": (1, 16, 9), "16:10": (2, 16, 10)}
ASPECT_BY_CODE = {code: (name, width, height) for name, (code, width, height) in ASPECTS.items()}
DEFAULT_ASPECT = ASPECTS["16:9"][0]           # what a file holding anything else reads as
RESIZABLE_ASPECT = {"free": 0, "4:3": 2, "16:9": 3, "16:10": 4}
RESIZABLE_ASPECT_BY_CODE = {code: name for name, code in RESIZABLE_ASPECT.items()}

# ── Keys ────────────────────────────────────────────────────────────────────
# USB HID usage (== GCKeyCode raw value) -> the name PlayTools dispatches on.
# PlayTools binds by NAME at runtime, translating each macOS key event to one
# through KeyCodeNames.swift; a keymap whose keyName disagrees with its
# keyCode follows the name. This is that table, limited to keys its macOS
# keycode mapping can actually deliver.
KEYS = {
    **{4 + i: chr(ord("A") + i) for i in range(26)},
    **{30 + i: str(i + 1) for i in range(9)}, 39: "0",
    40: "Enter", 41: "Esc", 42: "Del", 43: "Tab", 44: "Spc", 45: "-", 46: "=", 47: "[", 48: "]",
    49: "\\", 51: ";", 52: "'", 53: "`", 54: ",", 55: ".", 56: "/", 57: "Caps",
    **{58 + i: f"F{i + 1}" for i in range(12)},
    79: "Right", 80: "Left", 81: "Down", 82: "Up",
    83: "NumLock", 84: "Keypad /", 85: "Keypad *", 86: "Keypad -", 87: "Keypad +", 88: "Keypad Enter",
    **{89 + i: f"Keypad {i + 1}" for i in range(9)}, 98: "Keypad 0", 99: "Keypad .", 103: "Keypad =",
    104: "F13", 105: "F14", 107: "F16", 108: "F17", 109: "F18", 110: "F19", 111: "F20",
    224: "LCtrl", 225: "Lshft", 226: "LOpt", 227: "LCmd", 228: "RCtrl", 229: "Rshft", 230: "ROpt", 231: "RCmd",
    -1: "LMB", -2: "RMB", -3: "MMB",
}
ALIASES = {
    "space": 44, "return": 40, "escape": 41, "backspace": 42, "delete": 42, "capslock": 57,
    "shift": 225, "lshift": 225, "rshift": 229, "ctrl": 224, "control": 224, "rcontrol": 228,
    "alt": 226, "opt": 226, "option": 226, "lalt": 226, "ralt": 230, "roption": 230,
    "cmd": 227, "command": 227, "rcommand": 231,
    "minus": 45, "equal": 46, "equals": 46, "lbracket": 47, "rbracket": 48, "backslash": 49,
    "semicolon": 51, "quote": 52, "apostrophe": 52, "grave": 53, "backtick": 53,
    "comma": 54, "period": 55, "dot": 55, "slash": 56,
    "leftclick": -1, "rightclick": -2, "middleclick": -3,
    **{f"kp{i}": 89 + i - 1 for i in range(1, 10)}, "kp0": 98,
}
LOOKUP = {name.lower(): code for code, name in KEYS.items()}
LOOKUP.update(ALIASES)

# Element sizes PlayTools' editor gives a new element (EditorController.swift).
SIZE_BUTTON, SIZE_DRAG, SIZE_JOYSTICK, SIZE_MOUSE = 5.0, 15.0, 20.0, 25.0


class UsageError(Exception):
    pass


# ── The options, as keymap elements ─────────────────────────────────────────
def key_code(name):
    code = LOOKUP.get(name.strip().lower())
    if code is None:
        raise UsageError(f"unknown key {name!r}; use a letter, digit, F1-F20, Space, Enter, Esc, Tab, "
                         "Shift, Ctrl, Alt, Cmd, Up/Down/Left/Right, LMB/RMB/MMB, or a symbol such as , . / ;")
    return code


def point(spec, default_size, what):
    """'X,Y[,SIZE]' -> transform dict; X and Y fractions of the window."""
    parts = spec.split(",")
    if len(parts) not in (2, 3):
        raise UsageError(f"{what}: expected X,Y or X,Y,SIZE, got {spec!r}")
    try:
        x, y = float(parts[0]), float(parts[1])
        size = float(parts[2]) if len(parts) == 3 else default_size
    except ValueError:
        raise UsageError(f"{what}: X, Y and SIZE must be numbers, got {spec!r}") from None
    if not (0.0 <= x <= 1.0 and 0.0 <= y <= 1.0):
        raise UsageError(f"{what}: X and Y are fractions of the window, 0..1 (0,0 is the top left), got {spec!r}")
    if not 0.0 < size <= 100.0:
        raise UsageError(f"{what}: SIZE is a percentage of the window's longer side, 0..100, got {spec!r}")
    return {"size": size, "xCoord": x, "yCoord": y}


def split_binding(spec, what):
    """'KEY=X,Y[,S]' -> (KEY, 'X,Y[,S]'). The LAST '=' splits, so '=' itself can be a key."""
    key, sep, where = spec.rpartition("=")
    if not sep or not key or not where:
        raise UsageError(f"{what}: expected KEY=X,Y[,SIZE], got {spec!r}")
    return key, where


def button(spec, size, what):
    key, where = split_binding(spec, what)
    code = key_code(key)
    return {"keyCode": code, "keyName": KEYS[code], "transform": point(where, size, what)}


def joystick(spec):
    keys, where = split_binding(spec, "--joystick")
    k = keys.strip().lower()
    if k == "wasd":
        names = ["W", "A", "S", "D"]
    elif k == "arrows":
        names = ["Up", "Left", "Down", "Right"]
    else:
        names = keys.split("/")
        if len(names) != 4:
            raise UsageError(f"--joystick: KEYS is wasd, arrows, or UP/LEFT/DOWN/RIGHT, got {keys!r}")
    up, left, down, right = (key_code(n) for n in names)
    # "Keyboard" is what the editor names a keyboard-driven stick; a name with
    # a "u" in it (Mouse, Thumbstick) would make PlayTools treat it as analog.
    return {"upKeyCode": up, "rightKeyCode": right, "downKeyCode": down, "leftKeyCode": left,
            "keyName": "Keyboard", "transform": point(where, SIZE_JOYSTICK, "--joystick"), "mode": 0}


def mouse_area(spec):
    return {"keyName": "Mouse", "transform": point(spec, SIZE_MOUSE, "--mouse-look")}


def keymap_elements(args):
    """Every keymap option, as PlayTools' four lists of elements."""
    return {
        "buttonModels": [button(s, SIZE_BUTTON, "--map") for s in args.maps],
        "draggableButtonModels": [button(s, SIZE_DRAG, "--drag") for s in args.drags],
        "joystickModel": [joystick(s) for s in args.sticks],
        "mouseAreaModel": [mouse_area(s) for s in args.mice],
    }


# ── The options, as settings ────────────────────────────────────────────────
def coerce(key, raw):
    want = type(DEFAULTS[key])
    if want is bool:
        v = raw.strip().lower()
        if v in ("1", "true", "yes", "on"):
            return True
        if v in ("0", "false", "no", "off"):
            return False
        raise UsageError(f"--set {key}: expected true or false, got {raw!r}")
    try:
        value = want(raw)
    except ValueError:
        raise UsageError(f"--set {key}: expected {want.__name__}, got {raw!r}") from None
    # A plist integer is 64-bit and Swift decodes these as Int/Double: an
    # out-of-range or non-finite value would make PlayTools drop the file.
    if want is float and not math.isfinite(value):
        raise UsageError(f"--set {key}: expected a finite number, got {raw!r}")
    if want is int and not -2**63 <= value < 2**63:
        raise UsageError(f"--set {key}: out of range, got {raw!r}")
    return value


def parse_set(spec):
    key, sep, raw = spec.partition("=")
    if not sep:
        raise UsageError(f"--set: expected KEY=VALUE, got {spec!r}")
    if key not in DEFAULTS:
        raise UsageError(f"--set: unknown setting {key!r}; known: {', '.join(sorted(set(DEFAULTS) - NOT_SETTABLE))}")
    if key in NOT_SETTABLE:
        raise UsageError(f"--set: {key} is set through its own option (--resolution, --aspect, --no-keychain), not --set")
    return key, coerce(key, raw)


def parse_resolution(spec):
    s = spec.strip().lower()
    if s in RES_BY_NAME:
        return RES_BY_NAME[s], None
    m = re.fullmatch(r"(\d{3,5})x(\d{3,5})", s)
    if m:
        return RES_CUSTOM, (int(m.group(1)), int(m.group(2)))
    raise UsageError(f"--resolution: expected auto, 1080p, 1440p, 4k, WIDTHxHEIGHT, resizable or app-default; got {spec!r}")


def apply_resolution(s, res, aspect, display):
    if res is not None:
        code, custom = res
        s["resolution"] = code
        if code == RES_CUSTOM:
            s["windowWidth"], s["windowHeight"] = custom
        elif code in (RES_APP_DEFAULT, RES_RESIZABLE):
            s["windowWidth"], s["windowHeight"] = 1920, 1080
        elif code == RES_AUTO:
            s["windowWidth"], s["windowHeight"] = display()
    if aspect is not None:
        a = aspect.strip().lower()
        if s["resolution"] == RES_RESIZABLE:
            if a not in RESIZABLE_ASPECT:
                raise UsageError(f"--aspect: with a resizable window, expected free, 4:3, 16:9 or 16:10; got {aspect!r}")
            s["resizableAspectRatioType"] = RESIZABLE_ASPECT[a]
        elif s["resolution"] in RES_HEIGHT:
            if a not in ASPECTS:
                raise UsageError(f"--aspect: expected 4:3, 16:9 or 16:10; got {aspect!r}")
            s["aspectRatio"] = ASPECTS[a][0]
        else:
            raise UsageError(f"--aspect applies to 1080p, 1440p, 4k or resizable, not {RES_NAMES[s['resolution']]}")
    if s["resolution"] in RES_HEIGHT:
        # PlayCover's formula (AppSettingsView.getWidthFromAspectRatio), integer division included
        _, wr, hr = ASPECT_BY_CODE.get(s["aspectRatio"], ASPECT_BY_CODE[DEFAULT_ASPECT])
        h = RES_HEIGHT[s["resolution"]]
        s["windowWidth"], s["windowHeight"] = (h // hr) * wr, h


def main_display_points():
    """The main display's size in points, as PlayCover's Auto uses (NSScreen.main.frame)."""
    try:
        out = subprocess.run(
            ["osascript", "-l", "JavaScript", "-e",
             'ObjC.import("AppKit"); var f = $.NSScreen.mainScreen.frame; f.size.width + "x" + f.size.height'],
            capture_output=True, text=True, timeout=10).stdout.strip()
        w, h = out.split("x")
        return int(float(w)), int(float(h))
    except (OSError, ValueError, subprocess.SubprocessError):
        print("playtools-config: warning: could not read the display size; Auto uses 1920x1080", file=sys.stderr)
        return 1920, 1080


def display_size(args):
    """What --resolution auto measures: this display, or the --display given."""
    if args.display:
        size = tuple(int(v) for v in args.display.split("x"))
        return lambda: size
    return main_display_points


# ── Files ───────────────────────────────────────────────────────────────────
def default_root():
    return f"/Users/{pwd.getpwuid(os.getuid()).pw_name}/Library/Containers/io.playcover.PlayCover"


def write_plist(path, obj):
    """Atomic: a running app reading the file never sees half of it."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "wb") as f:
            plistlib.dump(obj, f, fmt=plistlib.FMT_XML)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def load_plist(path):
    try:
        with open(path, "rb") as f:
            return plistlib.load(f)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None


def merged_settings(existing, bid):
    """Every known key present and of the decoder's type; unknown keys kept."""
    out = dict(existing) if isinstance(existing, dict) else {}
    for key, default in DEFAULTS.items():
        have = out.get(key)
        want = type(default)
        if want is float and isinstance(have, int) and not isinstance(have, bool):
            out[key] = float(have)
        elif want is dict:
            d = dict(default)
            if isinstance(have, dict):
                d.update({k: v for k, v in have.items() if k in default and isinstance(v, type(default[k]))})
            out[key] = d
        elif not isinstance(have, want) or (want is int and isinstance(have, bool)):
            out[key] = default
    out["bundleIdentifier"] = bid
    return out


def settings_path(root, bid):
    return os.path.join(root, "App Settings", f"{bid}.plist")


def write_settings(root, args, res, sets):
    """The settings file, whole: what it held, then the defaults, then these
    options. Written before the keymap, and before the installer moves the
    bundle, so an option this refuses stops the run with nothing changed."""
    path = settings_path(root, args.bundle_id)
    s = merged_settings(load_plist(path), args.bundle_id)
    apply_resolution(s, res, args.aspect, display_size(args))
    for key, value in sets:
        s[key] = value
    if args.keychain:
        s["playChain"] = args.keychain == "playchain"
    write_plist(path, s)
    return s


# ── Keymaps ─────────────────────────────────────────────────────────────────
def empty_keymap(bid, version="2.0.0"):
    return {"buttonModels": [], "draggableButtonModels": [], "joystickModel": [], "mouseAreaModel": [],
            "bundleIdentifier": bid, "version": version}


def transform_of(e):
    t = e["transform"]
    return {"size": float(t["size"]), "xCoord": float(t["xCoord"]), "yCoord": float(t["yCoord"])}


def keymap_from_file(path, bid):
    """A PlayCover keymap, re-emitted with every field PlayTools decodes."""
    km = load_plist(path)
    if not isinstance(km, dict):
        raise UsageError(f"--keymap: {path} is not a keymap property list")
    version = str(km.get("version", "2.0.0"))
    if not version.startswith("2.0."):
        raise UsageError(f"--keymap: {path} is keymap format {version}; PlayTools reads only 2.0.x")
    out = empty_keymap(bid, version)
    try:
        for group in ("buttonModels", "draggableButtonModels"):
            for b in km.get(group, []):
                code = int(b["keyCode"])
                name = b.get("keyName") or KEYS.get(code, "Btn")
                out[group].append({"keyCode": code, "keyName": name, "transform": transform_of(b)})
        for j in km.get("joystickModel", []):
            e = {k: int(j[k]) for k in ("upKeyCode", "rightKeyCode", "downKeyCode", "leftKeyCode")}
            e.update(keyName=j.get("keyName") or "Keyboard", transform=transform_of(j))
            if "mode" in j:
                e["mode"] = int(j["mode"])
                if e["mode"] not in (0, 1):   # JoystickMode: FIXED, FLOATING
                    raise ValueError(f"joystick mode {e['mode']}")
            out["joystickModel"].append(e)
        for m in km.get("mouseAreaModel", []):
            out["mouseAreaModel"].append({"keyName": m.get("keyName") or "Mouse", "transform": transform_of(m)})
    except (KeyError, TypeError, ValueError) as e:
        raise UsageError(f"--keymap: {path} has an element PlayTools could not decode ({e!r})") from None
    return out


def file_url(path):
    return "file://" + urllib.parse.quote(path)


def keymap_path(root, bid):
    return os.path.join(root, "Keymapping", bid, "default.plist")


def write_keymap(root, bid, km):
    base = os.path.join(root, "Keymapping", bid)
    default = os.path.join(base, "default.plist")
    write_plist(default, km)
    # .config.plist's URLs are Swift URLs, which PropertyListEncoder writes as
    # {relative: "file://..."} dicts; a bare string fails to decode and
    # PlayTools resets the config. The default keymap first, then any others
    # the in-app editor made, so the editor's "next keymap" still finds them.
    others = sorted(f for f in os.listdir(base) if f.endswith(".plist") and f not in ("default.plist", ".config.plist"))
    order = [default] + [os.path.join(base, f) for f in others]
    write_plist(os.path.join(base, ".config.plist"),
                {"defaultKm": {"relative": file_url(default)},
                 "keymapOrder": [{"relative": file_url(p)} for p in order]})
    return default


def write_or_read_keymap(root, args, elements):
    """Any keymap option replaces the app's keymap; with none, the existing one
    (the in-app editor's, say) is left alone and only read back to describe."""
    if args.keymap or any(elements.values()):
        km = keymap_from_file(args.keymap, args.bundle_id) if args.keymap else empty_keymap(args.bundle_id)
        for group, items in elements.items():
            km[group].extend(items)
        write_keymap(root, args.bundle_id, km)
        return km
    path = keymap_path(root, args.bundle_id)
    if not os.path.isfile(path):
        return None
    try:
        return keymap_from_file(path, args.bundle_id)
    except UsageError as e:
        print(f"playtools-config: warning: the existing keymap is not readable: {e}", file=sys.stderr)
        return None


# ── Summary ─────────────────────────────────────────────────────────────────
def at(element):
    """An element's position, as the summary prints it."""
    t = element["transform"]
    return f"{t['xCoord']:g},{t['yCoord']:g}"


def describe(s, km):
    res = s["resolution"]
    if res == RES_RESIZABLE:
        aspect = RESIZABLE_ASPECT_BY_CODE.get(s["resizableAspectRatioType"], "custom")
        size = f"resizable window, aspect {aspect}"
    elif res == RES_APP_DEFAULT:
        size = "app default (the app's own window)"
    else:
        label = RES_NAMES[res]
        if res in RES_HEIGHT:
            label += " " + ASPECT_BY_CODE.get(s["aspectRatio"], ASPECT_BY_CODE[DEFAULT_ASPECT])[0]
        size = f"{label} -> {s['windowWidth']}x{s['windowHeight']}"
    lines = [f"resolution {size}, scaler {s['customScaler']:g}, device {s['iosDeviceModel']}",
             f"keyboard mapping {'on' if s['keymapping'] else 'off'} (Cmd+K edits in the app, Option toggles), "
             f"text fields type {'text' if s['noKMOnInput'] else 'through the keymap'}, "
             f"keychain {'PlayChain' if s['playChain'] else 'real (logins will not persist)'}"]
    if km is None:
        lines.append("keymap: none yet (PlayTools starts an empty one; Cmd+K in the app to add keys)")
    else:
        parts = [f"{b['keyName']}@{at(b)}" for b in km["buttonModels"]]
        parts += [f"drag {b['keyName']}@{at(b)}" for b in km["draggableButtonModels"]]
        for j in km["joystickModel"]:
            names = "/".join(KEYS.get(j[k], "?") for k in ("upKeyCode", "leftKeyCode", "downKeyCode", "rightKeyCode"))
            parts.append(f"joystick {names}@{at(j)}")
        parts += [f"mouse-look@{at(m)}" for m in km["mouseAreaModel"]]
        lines.append("keymap: " + (", ".join(parts) if parts else "empty"))
    return lines


# ── Run ─────────────────────────────────────────────────────────────────────
def check_options(args, res):
    """--check: everything that can be decided without the app's own settings,
    so ipa-install-on-mac can refuse a bad option before minutes of work."""
    if args.keymap:
        keymap_from_file(args.keymap, "check")
    if args.aspect is None:
        return
    if res is not None:
        # the combination is decidable here; without --resolution it
        # depends on the app's saved settings, checked at write time
        apply_resolution(dict(DEFAULTS), res, args.aspect, lambda: (1920, 1080))
    elif args.aspect.strip().lower() not in set(ASPECTS) | set(RESIZABLE_ASPECT):
        raise UsageError(f"--aspect: expected 4:3, 16:9, 16:10 or free; got {args.aspect!r}")


def main(argv):
    p = argparse.ArgumentParser(prog="playtools-config.py", description=__doc__.split("\n\n")[0])
    p.add_argument("--bundle-id")
    p.add_argument("--root", default=None, help="the io.playcover.PlayCover directory (default: where PlayTools reads)")
    p.add_argument("--check", action="store_true", help="validate the options, write nothing")
    p.add_argument("--resolution")
    p.add_argument("--aspect")
    p.add_argument("--set", action="append", default=[], dest="sets")
    p.add_argument("--keychain", choices=["playchain", "off"])
    p.add_argument("--map", action="append", default=[], dest="maps")
    p.add_argument("--drag", action="append", default=[], dest="drags")
    p.add_argument("--joystick", action="append", default=[], dest="sticks")
    p.add_argument("--mouse-look", action="append", default=[], dest="mice")
    p.add_argument("--keymap")
    p.add_argument("--display", help="WIDTHxHEIGHT in points for --resolution auto (default: the main display)")
    a = p.parse_args(argv)

    try:
        res = parse_resolution(a.resolution) if a.resolution else None
        sets = [parse_set(s) for s in a.sets]
        elements = keymap_elements(a)
        if a.keymap and not os.path.isfile(a.keymap):
            raise UsageError(f"--keymap: no such file: {a.keymap}")
        if a.display and not re.fullmatch(r"\d+x\d+", a.display):
            raise UsageError(f"--display: expected WIDTHxHEIGHT, got {a.display!r}")
        if a.check:
            check_options(a, res)
            return 0
        if not a.bundle_id:
            raise UsageError("--bundle-id is required")

        root = a.root or default_root()
        settings = write_settings(root, a, res, sets)
        km = write_or_read_keymap(root, a, elements)
        for line in describe(settings, km):
            print(line)
        return 0
    except UsageError as e:
        print(f"ipa-install-on-mac: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
