# ipa-install-on-mac

Installs a **decrypted** iOS `.ipa` as a native Mac app: every binary in it is
thinned to arm64 and converted to Mac Catalyst, re-signed, sandboxed, and put
in `/Applications`, with logins that survive a relaunch. For games,
`--playtools` adds PlayCover's in-app layer -- keyboard and mouse to touch
mapping, resolution and aspect control, device model spoofing -- from the
command line, without PlayCover.app.

## Legal

Use this only with an app you are entitled to run -- one you own or hold a
license for. Obtaining or decrypting an `.ipa` is out of scope and
unsupported here: this project starts from an `.ipa` you have already
decrypted yourself and does not explain, link to, or provide any way to do
that step. Decrypting an App Store binary may breach Apple's terms of service
and, depending on where you are, local law; evaluating that risk is on you,
not something this tool settles for you.

It is not a jailbreak tool, a FairPlay remover, or a compatibility shim for
finicky apps.

## Requirements

- An **Apple silicon** (arm64) Mac, macOS 14 or later.
- **Xcode or the Xcode Command Line Tools** (`xcode-select --install`), for
  `lipo`, `otool`, `vtool`, `install_name_tool`, `codesign`, and `clang` with
  the macOS SDK. `unzip`, `plutil`, `xattr`, `file` and `python3` are already
  on every Mac.
- For `--playtools` only: **full Xcode** with the iOS SDK (`xcodebuild`, not
  just the Command Line Tools) and `git`. The first `--playtools` install
  builds PlayTools from source (about a minute, network needed); later ones
  reuse `~/Library/Caches/ipa-install-on-mac`.
- An `.ipa` you have decrypted yourself. App Store downloads are
  FairPlay-encrypted (`cryptid 1` in `LC_ENCRYPTION_INFO`) and this tool
  refuses them before changing anything.

## Install

```
git clone https://github.com/ayush5harma/ipa-install-on-mac
cd ipa-install-on-mac
./install.sh
```

This symlinks `bin/ipa-install-on-mac` into `~/.local/bin` (`--bin-dir DIR`
or the `BIN_DIR` environment variable to put it elsewhere). A symlink rather
than a copy on purpose: the script resolves its own real location at run time
to find `lib/` beside it, so a `git pull` in the checkout updates the
installed command with nothing further to do.

`./install.sh --uninstall` removes the symlink again.

## Installing an app

```
ipa-install-on-mac Game.ipa
ipa-install-on-mac Game.ipa --dest ~/Applications --open
```

It prints what it did: the bundle id, how the app will render, which keychain
it got, and where it went. The app is an ordinary Mac app afterwards --
launch it from Spotlight or the Finder, drag it to the Trash to remove it.

| Flag | Effect |
|---|---|
| `--dest DIR` | install into `DIR` instead of `/Applications` |
| `--open` | launch it afterwards and confirm the process stayed running |
| `--force` | replace a same-named bundle even if its bundle id differs |
| `--keep` | keep the temporary work directory for inspection |
| `--mac-idiom` | render in the Mac idiom, 1:1 with the display, instead of the shipped iPad/iPhone layout (read ["The Mac idiom breaks some apps"](#the-mac-idiom-breaks-some-apps) first) |
| `--scaled` | the shipped idiom; the default since 2026-09-16, still accepted so old invocations keep working |
| `--no-keychain` | no emulated keychain: logins will not survive a relaunch |
| `--reset` | wipe the app's sandbox container (preferences, caches, the emulated keychain) before installing |
| `--playtools` | embed PlayTools; implied by every mapping and resolution option |
| `--dylib FILE` | also link `FILE` into the app; repeatable (see below) |
| `-h`, `--help` | print usage on stdout and exit 0 |

## Games: keyboard, mouse and resolution

`--playtools` embeds [PlayTools](https://github.com/PlayCover/PlayTools), the
framework PlayCover injects into games, and writes its settings. Any of the
options below implies it.

```
ipa-install-on-mac Game.ipa --resolution 1440p --aspect 16:9 \
  --joystick wasd=0.15,0.75 --map Space=0.85,0.8 --drag E=0.7,0.6 --mouse-look 0.6,0.4
```

| Flag | Effect |
|---|---|
| `--resolution R` | `auto` (the display), `1080p`, `1440p`, `4k`, `WIDTHxHEIGHT`, `resizable`, `app-default` |
| `--aspect A` | `4:3`, `16:9`, `16:10` with 1080p/1440p/4k; also `free` with `resizable` |
| `--map KEY=X,Y[,S]` | pressing `KEY` taps the screen at `X,Y` |
| `--drag KEY=X,Y[,S]` | holding `KEY` puts a finger at `X,Y` and the mouse drags it |
| `--joystick KEYS=X,Y[,S]` | `wasd`, `arrows` or `UP/LEFT/DOWN/RIGHT` drive a stick centred at `X,Y` |
| `--mouse-look X,Y[,S]` | the mouse moves a finger within this area (camera control) |
| `--keymap FILE` | start from an existing PlayCover keymap (`.playmap` or keymap `.plist`) |
| `--set KEY=VALUE` | any other PlayTools setting, e.g. `iosDeviceModel=iPad13,8`, `hideTitleBar=true`, `customScaler=1.5`, `sensitivity=70`, `noKMOnInput=false` |

`X,Y` are fractions of the app's window (`0,0` top left, `1,1` bottom right);
`S` is a size in percent of the window's longer side, defaulting to what
PlayTools' own editor uses for a new element (5 for a button, 15 draggable,
20 joystick, 25 mouse area). Keys are letters, digits, `F1`-`F20`, `Space`,
`Enter`, `Esc`, `Tab`, `Shift`, `Ctrl`, `Alt`, `Cmd`,
`Up`/`Down`/`Left`/`Right`, `LMB`/`RMB`/`MMB`, and symbols (`, . / ; ' [ ] \
- =`, or their names: `comma`, `slash`, ...).

Any mapping option replaces the app's keymap; with none of them, the existing
keymap is left alone -- including one you made in the app, because **Cmd+K**
opens PlayTools' own editor in the running game (place, drag and bind
buttons; it saves on close). **Option** switches the mapping on and off, and
typing in a focused text field types text rather than firing the keymap.

## Changing the settings later

```
ipa-install-on-mac --configure com.example.game --resolution 4k --set hideTitleBar=true
ipa-install-on-mac --configure "/Applications/Game.app" --map Space=0.5,0.9 --open
```

`--configure` takes a bundle id or an installed app, applies any of the
PlayTools options above, prints the result, and changes nothing else. The app
reads both files at launch, so quit it and open it again (it says so if the
app is running).

## Linking in your own code

`--dylib FILE` links an extra library into the app, the same way this tool
links its own. A `.c` or `.m` source is built for Mac Catalyst against the
macOS SDK (Foundation and the Objective-C runtime are available); a prebuilt
`.dylib` is converted like every other binary in the bundle. It is repeatable,
and the library loads after the app's own, so it can `dlsym` what they export.

## How it works

This is PlayCover's install mechanism, done with Xcode's command-line tools
and nothing else -- no separate app, no background helper. Reading
PlayCover's source (`PlayCover/PlayCover`: `Installer.swift`, `Macho.swift`,
`Entitlements.swift`, `Shell.swift`) shows the install itself is mechanical,
and every step has a direct CLI equivalent:

1. **Unpack** the `.ipa` (a zip) and find its one `Payload/*.app`.
2. **Refuse FairPlay-encrypted binaries.** Every Mach-O in the bundle is
   checked for `LC_ENCRYPTION_INFO`'s `cryptid`; a nonzero value stops the run
   before anything is installed.
3. **Thin every Mach-O to arm64** (`lipo -thin`) -- frameworks, dylibs and
   extensions too, not just the main executable, because dyld refuses to load
   an iOS-platform image at all inside a Catalyst process.
4. **Rewrite the platform** of every Mach-O to Mac Catalyst
   (`vtool -set-build-version maccatalyst 11.0 <sdk> -replace`), keeping each
   binary's **own** SDK version (see ["Each binary keeps its own SDK
   version"](#each-binary-keeps-its-own-sdk-version)).
5. **Repoint the Swift UIKit overlay** at the system's copy
   (`install_name_tool -change @rpath/libswiftUIKit.dylib
   /System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib`): `/usr/lib/swift`
   has no UIKit overlay on macOS. It is the only iOS-specific overlay that
   needs this.
6. **Delete `embedded.mobileprovision`** and lower `MinimumOSVersion` to
   `11.0` if it is higher -- once the platform says Catalyst, LaunchServices
   reads that key as a *macOS* requirement, so an iOS 17 app would otherwise
   demand "macOS 17".
7. **Sign**: every Mach-O individually, ad-hoc, then every nested bundle
   inside-out, then the app itself with a sandbox entitlement set (see
   ["`codesign --deep` re-signs nothing"](#codesign---deep-re-signs-nothing-in-a-flat-ios-bundle)
   for why the order matters), and clear the quarantine flag.
8. **Move the bundle** into `/Applications` (or `--dest`).

The bare iOS `.app` becomes the Mac app, in place: the platform keys in
`Info.plist` are not touched and the bundle is not wrapped in anything.

Three more things are added because a real *app* needs them:

- **Rendering.** The app keeps the idiom it shipped with, so an iPad app runs
  in its iPad layout, which Catalyst scales to 77% on a Mac. `--mac-idiom`
  appends `6` (Mac) to `UIDeviceFamily` instead -- Xcode's own "Optimize
  Interface for Mac" -- so the app runs 1:1 with the Mac's points.
- **A keychain that persists** (`--no-keychain` to opt out), because an ad-hoc
  signature cannot use the real one. See ["The emulated keychain"](#the-emulated-keychain).
- **OpenGL ES**, for apps that link it: run-time GL lookups are answered by
  OpenGL ES rather than desktop OpenGL (see ["OpenGL ES lookups would land in
  desktop OpenGL"](#opengl-es-lookups-would-land-in-desktop-opengl)).

The sandbox entitlements are PlayCover's base set: `app-sandbox` plus network
client and server, camera, microphone, Bluetooth, USB, contacts, calendars,
location, printing, and read-write access to Downloads, user-selected files,
Photos, Music and Movies. An entitlement only lets the app *ask*: macOS still
shows its normal permission prompt the first time the app actually uses one,
as it would for any other Mac app.

## Traps worth knowing

### An App Store download will not work

It is FairPlay-encrypted, and this tool refuses it rather than producing an
app that crashes at launch. Decrypting it is out of scope here; see
["Legal"](#legal).

### The Mac idiom breaks some apps

`--mac-idiom` makes UIKit run the app as a Mac app: it draws standard controls
as native Mac controls, and the app skips every code path it gates on
`.pad`. That suits an app which tolerates it (YouTube did) and breaks one
which does not. Measured on Google Photos 7.92 (2026-09-16): Collections
collapsed into rows of tiny push buttons, and every share sheet crashed -- a
popover presented with no source view, which the app only sets up for `.pad`.
The shipped idiom has been the default since then; `--scaled` names it
explicitly.

### Logins are stored on disk in the clear

The emulated keychain keeps items behind ordinary file permissions and a
sandbox container -- not behind your login password, and not in the Secure
Enclave. For this tool's shim that is the app's own container, so anyone who
can read `~/Library/Containers/<bundle id>/Data` can read them; for PlayTools'
PlayChain, under `--playtools`, it is
`~/Library/Containers/io.playcover.PlayCover/PlayChain/<bundle id>.db`, which
is why a PlayTools app needs a sandbox exception to reach it at all. Either
way it is the trade-off that makes a sign-in survive a relaunch under an
ad-hoc signature; `--no-keychain` opts out, and then no login persists.

### An app built for a newer iOS behaves as it would there

Each binary keeps the SDK version it was built against (raised to 14.0 if it
is older, or unreadable), so an app that has not adopted something its SDK
requires fails here exactly as it would on that iOS release. An app linked against the iOS 27 SDK that has not adopted the
scene lifecycle, for instance, traps in
`_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`. That is
faithful behaviour, not a bug in the conversion.

### A tweaked `.ipa` may carry its own "keychain fix"

Some pre-modified `.ipa`s ship a dylib that hooks `SecItemAdd` and
`SecItemCopyMatching` to strip the access group for a different signing
scheme (AltStore/TrollStore style). Under an ad-hoc signature that hook's own
probe fails and it forwards every call to the real keychain, which silently
defeats the keychain here. Any bundled dylib whose name matches
`keychain.?fix|sideload.?keychain` is replaced with an empty library of the
same name, and the install says which ones. Its load command is left in place
deliberately: removing it would shift the two-level-namespace ordinal of
every dylib after it.

### `--reset` needs the app closed

A running app would write its state straight back, so `--reset` refuses to
start while it is open. It clears the sandbox container (preferences, caches,
the emulated keychain store) and, for a PlayTools app, the PlayChain
database. Settings and keymaps are configuration, not state: they stay.

### Replacing an app that is not the same app

If `/Applications` already holds a bundle with the same name but a different
bundle id, the install stops rather than replacing it; `--force` (or
`--dest`) says what you meant. A copy that is replaced is moved to `~/.Trash`
first, and only removed outright if it cannot be moved there.

### PlayTools settings live in PlayCover's directory

PlayTools hardcodes `~/Library/Containers/io.playcover.PlayCover/` for its
settings, keymaps and PlayChain, so that is where they are written, whether
or not PlayCover.app is installed -- and PlayCover.app, if you do install it,
reads the same files. The app's sandbox exception names only its own files
there, not the whole directory, which also holds every other game's keychain.

## Uninstall

```
./install.sh --uninstall
```

removes the symlink from `~/.local/bin` (or `--bin-dir DIR`). This tool never
registers a LaunchAgent, a daemon, or any other background process, so there
is nothing else to remove.

An app it installed is not affected by that; drag it from `/Applications` to
the Trash like any other app. Its sandbox container
(`~/Library/Containers/<bundle id>`) is left behind the same way any app's
would be -- remove it by hand if you also want the stored keychain items
gone. For a `--playtools` app, the settings, keymaps and PlayChain store are
under `~/Library/Containers/io.playcover.PlayCover/` (`App Settings`,
`Keymapping`, `PlayChain`, each by bundle id), and the PlayTools build cache
is `~/Library/Caches/ipa-install-on-mac`.

## Tests

`test/e2e.sh` judges the installer by effect. It builds a probe app
(`test/probe.m`, which logs the idiom, screen, device model, touches, key
presses, keychain results and GL lookups it sees), installs it three ways,
launches it, and reads what the probe logged after that launch's own marker:
a default install, `--mac-idiom` with a `--dylib` source, a `--playtools`
install, and a `--configure` change taking effect on relaunch. 22 checks.

```
test/e2e.sh
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin test/e2e.sh
```

The second form runs the same suite with the tools a stock macOS has --
`/bin/bash` 3.2 through the `#!` line and `/usr/bin/python3` 3.9 -- which the
tool must keep working with. The mapped key press goes through System Events,
so the terminal needs Accessibility; without it that one check is skipped,
loudly. The suite needs Xcode's iOS SDK, and the one-time PlayTools build for
the `--playtools` part.

## Measured details

Everything below was measured rather than assumed; each is why the code does
something that looks odd.

### `codesign --deep` re-signs nothing in a flat iOS bundle

`--deep` finds nested code by walking `Contents/`, and an iOS app has no
`Contents/` at all, so `codesign --force --sign - --deep` on the top-level
bundle silently signs only the outer seal and leaves every framework, dylib
and extension carrying the signature of bytes `vtool` had just rewritten
underneath it. The kernel then kills the process at dyld's very first page
(`SIGKILL`, "CODESIGNING Invalid Page"). The fix, and what PlayCover itself
does: sign every Mach-O individually right after converting it, seal nested
bundles inside-out, and sign the app last.

### The -34018 keychain error, and why entitlements cannot fix it

A Mac Catalyst app always uses the data-protection keychain (Apple TN3137),
which requires an `application-identifier` and, for a shared group,
`keychain-access-groups` -- both of which normally come from a provisioning
profile. An ad-hoc signature has neither, so every `SecItemAdd` answers
`-34018` (`errSecMissingEntitlement`) and no login survives a relaunch.
Adding `keychain-access-groups` to the entitlements makes it worse: AMFI
refuses to even spawn a process whose ad-hoc signature claims an entitlement
that needs a profile behind it ("Launch failed", POSIX 163). There is no
entitlements-only fix, which is why the keychain itself is replaced.

### The emulated keychain

`lib/ipa-keychain.c` is linked into the app's main executable and interposes
the four `SecItem*` entry points for generic and internet passwords, storing
them in a binary plist inside the app's own sandbox container at
`Library/Application Support/ipa-keychain/items.plist`, mode `0600`. Every
other item class (keys, certificates, identities) passes straight through to
the real Security framework, unchanged. It is the same trade-off PlayCover's
PlayChain makes (see ["Logins are stored in the app's
container"](#logins-are-stored-in-the-apps-container-in-the-clear)), and
under `--playtools` PlayChain is used instead -- PlayTools interposes the
same four calls, and two interposers cannot share a process.

Each stored item also gets a synthetic `kSecAttrAccessGroup`: a stable
10-character seed derived from the bundle id, shaped like a team identifier.
Some sign-in flows (Google's SSO layer among them) probe for one before
showing an account picker at all, and a real keychain never answers that
probe with no group.

A real keychain also returns an accessibility class and a sync flag on every
item. The shim stored neither at first, and Google's SSO layer compared the
missing accessibility and trapped in `CFEqual(NULL, ...)` on every launch
after the first sign-in; it now keeps both and answers the keychain's
defaults (`kSecAttrAccessibleWhenUnlocked`, not synchronizable) for items
that never set them.

**Debug log.** Set `IPA_KEYCHAIN_LOG=1` in the app's environment, or create
an empty file named `DEBUG` next to `items.plist` in the container, to get
one line per keychain call in `log.txt` beside it: operation, item class,
account, service, whether a secret was carried, how many items matched, and
the result -- never the secret itself. This is the first thing to check when
a sign-in does not stick.

### Each binary keeps its own SDK version

PlayCover stamps a fixed `sdk 14.0` on everything. UIKit and SwiftUI change
behaviour by the SDK an app was linked against ("linked on or after" checks),
and a Catalyst build version counts in iOS versions, so that tells a modern
app it was built for iOS 14. Google Photos 7.92 (built with the iOS 26.4 SDK)
then showed no photo grid, no Videos or Creations, and its Recently Added
grid laid itself out at zero width forever, with the main thread pinned in
SwiftUI's layout. Stamped with its own 26.4, all of it renders.

### OpenGL ES lookups would land in desktop OpenGL

A converted app's own GL calls are bound to
`/System/iOSSupport/.../OpenGLES.framework`, a Metal-backed OpenGL ES that
works. But every Catalyst process also has desktop OpenGL loaded, first in
the global search order, so `dlsym(RTLD_DEFAULT, "glCreateShader")` returns
desktop `libGL`'s, which dispatches through a CGL context EAGL never sets:
Google Photos' editor (whose engine resolves GL at run time) died at the
first call, `EXC_BAD_ACCESS` in `libGL`. `lib/ipa-gles.c`, linked into apps
that use OpenGL ES, interposes `dlsym` so that `RTLD_DEFAULT` lookups of GL
names answer OpenGL ES's symbol, NULL for desktop-only ones, and everything
else reaches the real `dlsym` -- by tail call, so `RTLD_NEXT`/`RTLD_SELF`
still resolve relative to their real caller. The editor then opens and
applies edits.

### How PlayTools is built and embedded

- **Built from source, once.** `lib/playtools-build.sh` fetches PlayTools at
  a pinned commit and builds it with `xcodebuild` into
  `~/Library/Caches/ipa-install-on-mac`. `FASTLANE=1` skips its SwiftLint
  phase the way PlayCover's CI does, and the Swift package versions are
  pinned in `lib/playtools/Package.resolved` because PlayTools tracks a
  dependency's moving `main` branch.
- **Embedded per app.** PlayCover installs one shared copy in
  `~/Library/Frameworks` and links every game to it; here each app carries
  its own `Frameworks/PlayTools.framework`, converted to Catalyst like the
  rest, with its AppKit half `AKInterface.bundle` in the app's `PlugIns/`
  where PlayTools loads it from. A PlayCover.app on the same Mac is never
  touched.
- **Configured where PlayTools reads.** `lib/playtools-config.py` writes
  `App Settings/<bundle id>.plist` and `Keymapping/<bundle id>/` under
  `/Users/<you>/Library/Containers/io.playcover.PlayCover/`, the path
  PlayTools hardcodes. Both files are decoded all-or-nothing -- one missing
  key and PlayTools falls back to its own defaults for every key -- so the
  settings file is always written whole, keeping earlier values, with the
  superset of the keys PlayCover itself writes. The installer also creates
  the keymap directory and an empty PlayChain database, because PlayTools'
  own first connection creates the file and then fails the call, which would
  lose an app's first keychain write.
- **Sandboxed to its own files.** PlayCover grants every game read-write on
  that whole directory (which holds every other game's plaintext PlayChain),
  read on every Group Container and write on `.GlobalPreferences`. Here the
  rules name this app's own files only: its settings read-only, its keymap
  directory and its PlayChain database read-write. An `.ipa` is untrusted
  input.

Measured 2026-09-16 (macOS 27.0, Xcode 27.0, PlayTools `003f460`) with the
probe app in `test/`: `--resolution 1080p` gives the app a 1920x1080 screen
(2560x1440 display otherwise), the device model reads `iPad13,8`, a key set
with `--map K=0.25,0.75` arrives as a touch at exactly that fraction of the
window, K typed into a focused text field arrives as the letter, the editor
opens, draws the key where it was set and saves it back unchanged,
`--configure --resolution 1600x900` applies on the next launch, and a
keychain item written through PlayChain is read back after a relaunch. Not
wired up: PlayTools' opt-in jailbreak-detection bypass (`USE_EXTRA_ANTIJB`),
Discord presence, user plugins.

## License

MIT -- see [LICENSE](LICENSE). `--playtools` fetches
[PlayTools](https://github.com/PlayCover/PlayTools) (AGPL-3.0) from GitHub at
a pinned commit and builds it on your Mac; none of it is part of this
repository.
