# ipa-install-on-mac

Installs a **decrypted** iOS `.ipa` as a native Mac app — thinned to arm64,
re-signed, with logins that survive a relaunch — without PlayCover. For
games, `--playtools` adds PlayCover's in-app layer from the command line:
keyboard and mouse to touch mapping, resolution and aspect control, device
model spoofing (see ["PlayTools"](#playtools---playtools)).

## What this is, and is not

This is PlayCover's core install mechanism, reimplemented directly on top of
Xcode's command-line tools, with no separate app or background helper of its
own. Reading PlayCover's source (`PlayCover/PlayCover`: `Installer.swift`,
`Macho.swift`, `Entitlements.swift`, `Shell.swift`) shows the install itself
is mechanical: unzip, thin every Mach-O in the bundle to arm64, rewrite each
one's platform load command to Mac Catalyst, repoint the Swift UIKit overlay
at the macOS copy, delete the embedded provisioning profile, sign everything
ad-hoc with a small sandbox entitlement set, and clear the quarantine flag.
It does **not** touch the platform keys in `Info.plist` and does **not**
wrap the bundle in anything — the bare iOS `.app` becomes the Mac app,
in place.

Every one of those steps has a direct Xcode CLI equivalent (`lipo -thin`,
`vtool -set-build-version maccatalyst`, `install_name_tool -change`,
`codesign`), so this script does exactly that, plus what a full app
actually needs to behave on a Mac: a keychain that survives a relaunch, the
binary's own SDK version kept, and OpenGL ES that does not fall through to
desktop OpenGL. See ["How it works"](#how-it-works) below.

**What it is not**: a jailbreak tool, a FairPlay remover, or a
compatibility shim for finicky apps. It refuses App-Store-encrypted `.ipa`s
outright (see "Requirements"). PlayCover's own *PlayTools* layer is
available behind `--playtools`, built from its upstream source; PlayCover.app
is never used or needed.

## Legal

Use this only with an app you are entitled to run — one you own or hold a
license for. Obtaining or decrypting an `.ipa` is out of scope and
unsupported here: this project starts from an `.ipa` you have already
decrypted yourself and does not explain, link to, or provide any way to do
that step. Decrypting an App Store binary may breach Apple's terms of
service and, depending on where you are, local law; evaluating that risk is
on you, not something this tool settles for you.

`--playtools` fetches [PlayTools](https://github.com/PlayCover/PlayTools)
(AGPL-3.0) from GitHub at a pinned commit and builds it on your Mac; nothing
of it is part of this repository, whose own code stays MIT.

## Requirements

- **Apple silicon** (arm64) Mac, macOS 14 or later.
- **Xcode or the Xcode Command Line Tools** (`xcode-select --install`):
  `lipo`, `otool`, `vtool`, `install_name_tool`, `codesign`, and `clang` with
  the macOS SDK (for the keychain shim). `unzip`, `plutil`, `xattr`, `file`
  and `python3` are already on every Mac.
- For `--playtools` only: **full Xcode** with the iOS SDK (`xcodebuild`, not
  just the Command Line Tools) and `git`; the first `--playtools` install
  builds PlayTools from source (about a minute, network needed), later ones
  reuse `~/Library/Caches/ipa-install-on-mac`.
- An `.ipa` you have decrypted yourself — nothing here does that part, and
  this project does not point at sources. App Store downloads are
  FairPlay-encrypted (`cryptid 1` in `LC_ENCRYPTION_INFO`); this tool
  refuses them before touching anything (see ["Legal"](#legal)).

## Usage

```
ipa-install-on-mac <file.ipa> [options]
ipa-install-on-mac --configure <App.app | bundle id> [PlayTools options] [--open]
```

| Flag | Effect |
|---|---|
| `--dest DIR` | install into `DIR` instead of `/Applications` |
| `--open` | launch the app afterwards and confirm the process appeared |
| `--force` | replace a same-named bundle even if its bundle id differs |
| `--keep` | keep the temporary work directory for inspection |
| `--mac-idiom` | render in the Mac idiom, 1:1 with the display, instead of the shipped iPad/iPhone layout (see "Rendering") |
| `--scaled` | the shipped idiom; the default since 2026-09-16, accepted so old invocations keep working |
| `--no-keychain` | no emulated keychain; logins will not survive a relaunch |
| `--reset` | wipe the app's sandbox container (preferences, caches, the emulated keychain) before installing |
| `--playtools` | embed PlayTools; implied by every option in the next table |
| `-h`, `--help` | print usage and exit 0 |

PlayTools options, at install time or later through `--configure`:

| Flag | Effect |
|---|---|
| `--resolution R` | `auto` (the display), `1080p`, `1440p`, `4k`, `WIDTHxHEIGHT`, `resizable`, `app-default` |
| `--aspect A` | `4:3`, `16:9`, `16:10` with 1080p/1440p/4k; also `free` with `resizable` |
| `--map KEY=X,Y[,S]` | pressing `KEY` taps the screen at `X,Y` |
| `--drag KEY=X,Y[,S]` | holding `KEY` puts a finger at `X,Y` and the mouse drags it |
| `--joystick KEYS=X,Y[,S]` | `wasd`, `arrows` or `UP/LEFT/DOWN/RIGHT` drive a stick centred at `X,Y` |
| `--mouse-look X,Y[,S]` | the mouse moves a finger within this area (camera control) |
| `--keymap FILE` | start the keymap from a PlayCover keymap (`.playmap` or keymap `.plist`) |
| `--set KEY=VALUE` | any other PlayTools setting, e.g. `iosDeviceModel=iPad13,8`, `hideTitleBar=true`, `customScaler=1.5`, `sensitivity=70`, `noKMOnInput=false` |

`X,Y` are fractions of the app's window (`0,0` top left, `1,1` bottom right);
`S` is a size in percent of the window's longer side (PlayTools' editor
defaults: 5 for a button, 15 draggable, 20 joystick, 25 mouse area). Keys:
letters, digits, `F1`-`F20`, `Space`, `Enter`, `Esc`, `Tab`, `Shift`, `Ctrl`,
`Alt`, `Cmd`, `Up`/`Down`/`Left`/`Right`, `LMB`/`RMB`/`MMB`, and symbols
(`, . / ; ' [ ] \ - =`, or their names: `comma`, `slash`, ...). Any keymap
option replaces the app's default keymap; without one, the existing keymap
(for instance one made in the app with Cmd+K) is left alone.

```
ipa-install-on-mac Game.ipa --resolution 1440p --aspect 16:9 \
  --joystick wasd=0.15,0.75 --map Space=0.85,0.8 --drag E=0.7,0.6 --mouse-look 0.6,0.4
ipa-install-on-mac --configure com.example.game --resolution 4k --set hideTitleBar=true
```

## How it works

1. **Unpack** the `.ipa` (a zip) and find its one `Payload/*.app`.
2. **Refuse FairPlay-encrypted binaries** before changing anything — every
   Mach-O in the bundle is checked for `LC_ENCRYPTION_INFO`'s `cryptid`, and
   a nonzero value stops the run immediately, before anything is installed.
3. **Thin every Mach-O to arm64** (`lipo -thin`) — frameworks, dylibs and
   extensions too, not just the main executable, because dyld refuses to
   load an iOS-platform image at all inside a Catalyst process.
4. **Rewrite the platform** of every Mach-O to Mac Catalyst
   (`vtool -set-build-version maccatalyst 11.0 <sdk> -replace`) — PlayCover's
   minimum, which is what lets LaunchServices treat the bundle as a Catalyst
   app in the first place, but each binary's **own** SDK version rather than
   PlayCover's fixed `14.0` (see "Measured traps").
5. **Repoint the Swift UIKit overlay**
   (`install_name_tool -change @rpath/libswiftUIKit.dylib
   /System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib`) —
   `/usr/lib/swift` has no UIKit overlay on macOS; Catalyst's copy lives
   under `/System/iOSSupport`. This is the only iOS-specific overlay that
   needs repointing.
6. **Delete `embedded.mobileprovision`** and bump `MinimumOSVersion` to
   `11.0` if it is higher — once the platform says Catalyst, LaunchServices
   reads that key as a *macOS* requirement, so an iOS 17 app would otherwise
   demand "macOS 17".
7. **Sign every Mach-O individually**, ad-hoc, then every nested bundle
   inside-out, then the app itself with a sandbox entitlement set — PlayCover's
   base set: `app-sandbox` plus network client and server, camera,
   microphone, Bluetooth, USB, contacts, calendars, location, and
   read-write access to Photos, Music and Movies. An entitlement only lets
   the app *ask*; macOS still shows its normal per-capability permission
   prompt (camera, contacts, location, ...) the first time the app actually
   uses one, the same as for any other Mac app. See "`codesign --deep`
   re-signs nothing" below for why both the order and the per-file signing
   matter.
8. **Move the bundle into `/Applications`** (or `--dest`). A same-named
   bundle with a *different* bundle id is left alone unless `--force` is
   given; otherwise the previous copy is moved to `~/.Trash` first.

More steps exist because a real *app* needs them:

- **Rendering**: the app keeps the idiom it shipped with, as PlayCover does
  — an iPad app runs in its iPad layout, which Catalyst scales to 77% on a
  Mac. `--mac-idiom` appends `6` (Mac) to `UIDeviceFamily` instead —
  Xcode's own "Optimize Interface for Mac" — so the process runs in
  `UIUserInterfaceIdiom.mac`, 1:1 with the Mac's points (measured: the
  reported idiom changes `1` -> `5` from that one plist edit). That suits an
  app that tolerates it (YouTube did) and breaks one that does not: in the
  Mac idiom UIKit draws its standard controls as native Mac controls, and
  apps skip every code path gated on `.pad`. Measured on Google Photos 7.92:
  Collections collapsed into rows of tiny push buttons, and every share
  sheet crashed (a popover presented with no source view, which the app
  only sets up for `.pad`). The Mac idiom was the default until 2026-09-16.
- **Keychain** (`--no-keychain` to opt out): see "The keychain shim".
- **OpenGL ES** (only for apps that link it): `lib/ipa-gles.c`, linked into
  the main executable, makes a run-time lookup of a GL function answer with
  OpenGL ES, as on iOS (see "Measured traps").

## Measured traps

- **`codesign --deep` re-signs nothing in a flat iOS bundle.** `--deep`
  finds nested code by walking `Contents/` — but an iOS app has no
  `Contents/` at all, so `codesign --force --sign - --deep` on the top-level
  bundle silently signs only the outer seal and leaves every framework,
  dylib and extension carrying the signature of bytes `vtool` had just
  rewritten underneath it. The kernel kills the process at dyld's very
  first page (`SIGKILL`, "CODESIGNING Invalid Page") the moment it tries to
  map one of them. The fix, and what PlayCover itself does: sign every
  Mach-O individually right after converting it, then seal nested bundles
  inside-out, then the app last — never `--deep` on an iOS-shaped bundle.
- **The -34018 keychain error, and why entitlements cannot fix it.** A Mac
  Catalyst app always uses the data-protection keychain (Apple TN3137),
  which requires an `application-identifier` and, for a shared group,
  `keychain-access-groups` — both of which normally come from a
  provisioning profile. An ad-hoc signature has neither, so every
  `SecItemAdd` answers `-34018` (`errSecMissingEntitlement`) and no login
  survives a relaunch. Adding `keychain-access-groups` to the entitlements
  does not help — it makes things *worse*: AMFI refuses to even spawn a
  process whose ad-hoc signature claims an entitlement that needs a profile
  to back it ("Launch failed", POSIX 163). There is no entitlements-only
  fix; the keychain itself has to be replaced. Hence the shim.
- **A sideloaded app's own "keychain fix" tweak can steal the calls the shim
  exists for.** Some tweaked/pre-modified `.ipa`s already carry a dylib that
  hooks `SecItemAdd`/`SecItemCopyMatching` (commonly named with
  `keychainfix` or `sideloadKeychainFix` somewhere in its path) to strip the
  access group for a different signing scheme entirely (AltStore/
  TrollStore-style). Under an *ad-hoc* signature that hook's own probe
  fails and it forwards every call straight to the real (missing-
  entitlement) keychain — silently defeating this tool's shim if left
  running. This tool neutralises any bundled dylib whose name matches
  `keychain.?fix|sideload.?keychain`, replacing its file with an empty
  dylib of the same install name (its load command is left in place
  deliberately — removing it would shift the two-level-namespace ordinal of
  every dylib after it), so dyld still finds it and it does nothing.
- **The rendering idiom is a single plist array value, easy to get wrong.**
  `UIDeviceFamily` has to be *appended to*, never replaced (an iPhone-only
  app should keep its `1`), and the idiom only changes at the next cold
  launch — an app already running under the iPad idiom needs a relaunch to
  pick up `6`.
- **PlayCover's fixed SDK version tells a modern app it was built for iOS
  14.** UIKit and SwiftUI change behaviour by the SDK an app was linked
  against ("linked on or after" checks), and a Catalyst build version
  counts in iOS versions. With `sdk 14.0` Google Photos 7.92 (built with the
  iOS 26.4 SDK) showed no photo grid, no Videos or Creations, and its
  Recently Added grid laid itself out at zero width forever — the main
  thread pinned in SwiftUI's layout, the app unresponsive. Stamped with its
  own 26.4, all of it renders. The flip side is faithful too: an app linked
  against the iOS 27 SDK that has not adopted the scene lifecycle now traps
  in `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`,
  exactly as it would on iOS 27.
- **OpenGL ES lookups land in desktop OpenGL.** A converted app's own GL
  calls are bound to `/System/iOSSupport/.../OpenGLES.framework`, a
  Metal-backed OpenGL ES that works (`glCreateShader` returns 1 with an
  `EAGLContext` current, 0 — harmlessly — without). But every Catalyst
  process also has desktop OpenGL loaded, first in the global search, so
  `dlsym(RTLD_DEFAULT, "glCreateShader")` returns desktop `libGL`'s, which
  dispatches through a CGL context EAGL never sets: Google Photos' editor
  (Google's Ink/Ion engine resolves GL at run time) died at the first call,
  `EXC_BAD_ACCESS` at `0x1298` in `libGL`. `lib/ipa-gles.c` interposes
  `dlsym` so `RTLD_DEFAULT` lookups of GL names answer OpenGL ES's symbol,
  NULL for desktop-only ones, and hands everything else to the real `dlsym`
  by tail call, so `RTLD_NEXT`/`RTLD_SELF` still resolve relative to their
  real caller. The editor opens and applies edits.
- **A real keychain returns accessibility and sync on every item.** The
  shim stored neither, so an item read back with its attributes lacked
  both; Google's SSO layer compares the accessibility and trapped in
  `CFEqual(NULL, ...)` on every launch after the first sign-in. The shim now
  keeps both and answers the keychain's defaults (`kSecAttrAccessibleWhenUnlocked`,
  not synchronizable) for items that never set them.
- **`file` output breaks awk in a UTF-8 locale.** `file` describes a data
  file from its own bytes, and macOS awk aborts on the first invalid UTF-8
  sequence ("towc: multibyte conversion failure"); the Mach-O scan runs in
  the C locale.
- **A failing pipeline under `set -e -o pipefail` can die with no message.**
  `grep -q` on the producing side of a pipe, or `xargs`/`awk` exiting early
  on odd input, both SIGPIPE the upstream command — on a real, multi-
  thousand-file bundle this killed earlier versions of the script silently.
  Every such pipeline here captures full output first and filters
  afterwards, and an `ERR` trap names the failing line if anything else
  still slips through.

## The keychain shim's security trade-off

`lib/ipa-keychain.c` (about 450 lines of C, no dependencies) is linked into
the app's main executable and interposes the four `SecItem*` entry points
for generic and internet passwords, storing them in a binary plist inside
the app's own sandbox container at
`Library/Application Support/ipa-keychain/items.plist`, mode `0600`. Every
other item class (keys, certificates, identities) passes straight through
to the real Security framework, unchanged.

This is **not** the real keychain's security model. Items rest on disk
behind ordinary file permissions and the app sandbox container — not behind
your login password, and not behind the Secure Enclave. Anyone who can read
`~/Library/Containers/<bundle id>/Data` can read the stored items in plain
text. This is the same trade-off PlayCover's own PlayChain makes; it is
what lets a sign-in survive at all under an ad-hoc signature, at the cost
of the hardware-backed protection a properly-provisioned app would have.
Pass `--no-keychain` to skip it entirely (the app then behaves exactly as
shipped: no login survives a relaunch). Under `--playtools` the keychain is
PlayTools' own PlayChain instead, with the same trade-off (see below).

Each stored item also gets a synthetic `kSecAttrAccessGroup` — a stable
10-character seed derived from the bundle id, shaped like a team identifier
— because some sign-in flows (Google's SSO layer among them) probe for one
before showing an account picker at all; a real keychain never answers that
probe with no group, so this shim always returns one too.

### Debug log

Set `IPA_KEYCHAIN_LOG=1` in the app's environment, or create an empty file
named `DEBUG` next to `items.plist` in the container, to get one line per
keychain call in `log.txt` beside it: operation, item class, account,
service, whether a secret was carried, how many items matched, and the
result — never the secret value itself. This is the first thing to check
when a sign-in still does not stick.

## PlayTools (`--playtools`)

[PlayTools](https://github.com/PlayCover/PlayTools) is the framework
PlayCover injects into every game: keyboard and mouse to touch mapping with
an in-app editor, resolution and aspect control, device model spoofing, and
PlayChain, its emulated keychain. `--playtools` (implied by any mapping or
resolution option) brings it in without PlayCover.app:

- **Built from source, once.** `lib/playtools-build.sh` fetches PlayTools at
  a pinned commit and builds it with `xcodebuild` (with `FASTLANE=1`, which
  skips its SwiftLint phase the way PlayCover's CI does, and the Swift
  package versions pinned in `lib/playtools/Package.resolved`, because
  PlayTools tracks a dependency's moving `main` branch) into
  `~/Library/Caches/ipa-install-on-mac`.
- **Embedded in the app.** PlayCover installs one shared copy in
  `~/Library/Frameworks` and links every game to it; here each app carries
  its own `Frameworks/PlayTools.framework` (converted to Catalyst like the
  rest), linked into the main executable, with its AppKit half,
  `AKInterface.bundle`, in the app's `PlugIns/` where PlayTools loads it
  from. A PlayCover.app on the same Mac is never touched.
- **Configured where PlayTools reads.** PlayTools hardcodes
  `/Users/<you>/Library/Containers/io.playcover.PlayCover/` for its settings
  (`App Settings/<bundle id>.plist`), keymaps (`Keymapping/<bundle id>/`)
  and PlayChain (`PlayChain/<bundle id>.db`); `lib/playtools-config.py`
  writes the first two, the app gets PlayCover's sandbox rule for that
  directory. Both files are decoded all-or-nothing (one missing key and
  PlayTools falls back to its own defaults for every key), so the settings
  file is always written whole, keeping earlier values; the keys are the
  superset PlayCover itself writes, so PlayCover.app reads the same file.
- **In the running app**: Cmd+K opens PlayTools' keymap editor (place,
  drag and bind buttons; it saves on close), Option switches the mapping on
  and off, and a focused text field types text rather than touches.
- **The keychain** is PlayChain, because PlayTools interposes the same
  `SecItem*` calls as this tool's shim and two interposers cannot share a
  process; `--no-keychain` turns PlayChain off.
- **The idiom** stays the shipped one, as with every install; `--mac-idiom`
  works under PlayTools too.

Measured (2026-09-16, macOS 27.0, Xcode 27.0, PlayTools `003f460`) with the
probe app in `test/`: `--resolution 1080p` gives the app a 1920x1080 screen
(2560x1440 display otherwise), the device model reads `iPad13,8`, a key set
with `--map K=0.25,0.75` arrives as a touch at exactly that fraction of the
window, K typed into a focused text field arrives as the letter, the editor
opens, draws the key where it was set and saves it back unchanged, and
`--configure --resolution 1440p` gives 2560x1440 on the next launch. Not
wired up: PlayTools' opt-in jailbreak-detection bypass (`USE_EXTRA_ANTIJB`),
Discord presence (written off), user plugins.

## Tests

`test/e2e.sh` builds the probe app (`test/probe.m`: logs its idiom, screen,
device model, touches, key presses and text input into its container),
installs it three ways and judges each by what the probe logged: a default
install (shipped idiom, own SDK kept, sandboxed), a `--playtools` install
(forced resolution, spoofed model, a mapped key becoming a touch) and a
`--configure` change taking effect on relaunch. The key press goes through
System Events, so the terminal needs Accessibility. It needs Xcode's iOS SDK
and, for the PlayTools part, the one-time PlayTools build.

## Install

```
git clone https://github.com/ayush5harma/ipa-install-on-mac
cd ipa-install-on-mac
./install.sh
```

This symlinks `bin/ipa-install-on-mac` into `~/.local/bin` (override the
directory with `--bin-dir DIR` or the `BIN_DIR` environment variable). It
is a symlink rather than a copy on purpose: the script resolves its own
real location through the link at run time to find `lib/ipa-keychain.c` and
`lib/ipa-inject-dylib.py` beside it — see `bin/ipa-install-on-mac`'s
`resolve_path` — so a `git pull` in the checkout updates the installed
command with nothing further to do, whether you run it from the clone
directly or through the symlink.

## Uninstall

```
./install.sh --uninstall
```

Removes the symlink from `~/.local/bin` (or `--bin-dir DIR`). This tool
never registers a LaunchAgent, a daemon, or any other background process —
there is nothing else to remove. An app it installed is not touched by
this; drag it from `/Applications` to the Trash like any other app. Its
sandbox container (`~/Library/Containers/<bundle id>`) is left behind the
same way any app's would be — remove it by hand if you also want the
shim's stored keychain items gone. For a `--playtools` app, its settings,
keymaps and PlayChain store are under
`~/Library/Containers/io.playcover.PlayCover/` (`App Settings`,
`Keymapping`, `PlayChain`, each by bundle id), and the PlayTools build cache
is `~/Library/Caches/ipa-install-on-mac`.

## License

MIT — see [LICENSE](LICENSE).
