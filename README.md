# ipa-install-on-mac

Installs a **decrypted** iOS `.ipa` as a native Mac app — thinned to arm64,
re-signed, and running at the Mac's own resolution with logins that survive
a relaunch — without PlayCover.

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
`codesign`), so this script does exactly that, plus two things a full app
(as opposed to a game, PlayCover's usual case) actually needs: correct
Mac-scaled rendering and a keychain that survives a relaunch. See
["How it works"](#how-it-works) below.

**What it is not**: a jailbreak tool, a FairPlay remover, or a
compatibility shim for finicky apps. It refuses App-Store-encrypted `.ipa`s
outright (see "Requirements"), and it does not attempt anything PlayCover's
own *PlayTools* layer does for games — see
["What PlayCover still does that this does not"](#what-playcover-still-does-that-this-does-not).

## Requirements

- **Apple silicon** (arm64) Mac, macOS 14 or later.
- **Xcode or the Xcode Command Line Tools** (`xcode-select --install`):
  `lipo`, `otool`, `vtool`, `install_name_tool`, `codesign`, and `clang` with
  the macOS SDK (for the keychain shim). `unzip`, `plutil`, `xattr`, `file`
  and `python3` are already on every Mac.
- A **decrypted** `.ipa`. App Store downloads are FairPlay-encrypted
  (`cryptid 1` in `LC_ENCRYPTION_INFO`); this tool refuses them before
  touching anything. Decrypting one needs a jailbroken device or an
  already-decrypted source — nothing here does that part.

## Usage

```
ipa-install-on-mac <file.ipa> [options]
```

| Flag | Effect |
|---|---|
| `--dest DIR` | install into `DIR` instead of `/Applications` |
| `--open` | launch the app afterwards and confirm the process appeared |
| `--force` | replace a same-named bundle even if its bundle id differs |
| `--keep` | keep the temporary work directory for inspection |
| `--scaled` | keep the iPad idiom (77%-scaled rendering) instead of the Mac idiom |
| `--no-keychain` | skip the keychain shim; logins will not survive a relaunch |
| `--reset` | wipe the app's sandbox container (preferences, caches, the shim's store) before installing |

## How it works

1. **Unpack** the `.ipa` (a zip) and find its one `Payload/*.app`.
2. **Refuse FairPlay-encrypted binaries** before changing anything — every
   Mach-O in the bundle is checked for `LC_ENCRYPTION_INFO`'s `cryptid`, and
   a nonzero value stops the run immediately, before anything is modified.
3. **Thin every Mach-O to arm64** (`lipo -thin`) — frameworks, dylibs and
   extensions too, not just the main executable, because dyld refuses to
   load an iOS-platform image at all inside a Catalyst process.
4. **Rewrite the platform** of every Mach-O to Mac Catalyst
   (`vtool -set-build-version maccatalyst 11.0 14.0 -replace`) — PlayCover's
   exact target values, which is what lets LaunchServices treat the bundle
   as a Catalyst app in the first place.
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
   inside-out, then the app itself with a small sandbox entitlement set —
   see "`codesign --deep` re-signs nothing" below for why both the order
   and the per-file signing matter.
8. **Move the bundle into `/Applications`** (or `--dest`). A same-named
   bundle with a *different* bundle id is left alone unless `--force` is
   given; otherwise the previous copy is moved to `~/.Trash` first.

Two more steps exist because a real *app* (rather than a game, PlayCover's
usual target) needs them:

- **Rendering** (`--scaled` to opt out): UIKit decides the interface idiom
  from `UIDeviceFamily` in `Info.plist` at launch time. Appending `6` (Mac)
  to that array — Xcode's own "Optimize Interface for Mac" — makes the
  process run in `UIUserInterfaceIdiom.mac`: native, 1:1 with the Mac's own
  points and controls, instead of the iPad layout scaled to 77%. Measured:
  the reported idiom value itself changes (`1` -> `5`) from this one plist
  edit, and a full-size display renders edge to edge instead of
  letterboxed.
- **Keychain** (`--no-keychain` to opt out): see the next section.

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
- **A failing pipeline under `set -e -o pipefail` can die with no message.**
  `grep -q` on the producing side of a pipe, or `xargs`/`awk` exiting early
  on odd input, both SIGPIPE the upstream command — on a real, multi-
  thousand-file bundle this killed earlier versions of the script silently.
  Every such pipeline here captures full output first and filters
  afterwards, and an `ERR` trap names the failing line if anything else
  still slips through.

## The keychain shim's security trade-off

`lib/ipa-keychain.c` (around 300 lines of C, no dependencies) is linked into
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
shipped: no login survives a relaunch).

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

## What PlayCover still does that this does not

PlayCover's remaining value on top of a plain install is its *PlayTools*
layer, aimed at games rather than ordinary apps:

- Keyboard-and-mouse-to-touch input mapping.
- Device spoofing and jailbreak-detection bypass tuned for specific titles.
- A maintained community catalogue of per-app compatibility settings.

If one of those is actually the point (a touch-only game you want to play
with a keyboard), install PlayCover itself instead, from its **release**
channel — not a nightly build, which ships as a versioned CI artifact with
no stable "latest" URL to automate against.

## Install

```
git clone <this repo> ipa-install-on-mac
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
shim's stored keychain items gone.

## License

MIT — see [LICENSE](LICENSE).
