# Installing Unison-UI-Mac

This page walks through getting Unison-UI-Mac running on your Mac. Two
paths:

1. **Prebuilt `.app` from the [Releases page](https://github.com/bcourbage/unison-ui-mac/releases)** —
   easiest if a release has been cut for the version you want. The
   binary is ad-hoc-signed (not Apple-notarized), so you'll need to
   handle a one-time Gatekeeper prompt; see
   [First launch & Gatekeeper](#first-launch--gatekeeper) below.
2. **Build from source** — required for development, or if no release
   is available, or if you'd rather verify the binary yourself. See
   [Install from source](#install-from-source) below.

> Already familiar with macOS dev tooling? The 60-second version is at the
> bottom under [TL;DR](#tldr).

## System requirements

### To run the app

- **macOS 15 (Sequoia) or later** on an **Apple Silicon Mac**. The
  app's deployment target is `15.0` and ships as an arm64-only binary.
  Intel Macs are not supported.
- **~60 MB of disk.** The bundle is around 50 MB (the embedded OCaml
  core is the bulk of it).
- **No admin rights** beyond what `/Applications` itself requires — the
  installer uses `sudo` only if `/Applications` isn't writable as your
  user, which is the macOS default.

### To build from source

- **macOS 15+** (same as runtime).
- **Xcode 26+**, installed from the App Store, opened at least once so
  it accepts its license. Older Xcode versions may work; not tested.
- **Xcode Command Line Tools**:
  ```sh
  xcode-select --install
  ```
- **Homebrew**: <https://brew.sh>
- **Build tools via Homebrew**:
  ```sh
  brew install ocaml xcodegen
  ```
  Tested against OCaml 5.4.1; any 5.x release should work. OCaml is
  needed for the runtime libraries we link (`libasmrun`, `libthreadsnat`,
  etc.) — *not* to compile Unison itself.

That's it. **No upstream Unison clone required** — a prebuilt
`unison-blob.o` lives in `vendor/` (see
[vendor/README.md](vendor/README.md) for provenance). The build
compiles Swift + C, links against the vendored blob + the OCaml runtime
from Homebrew, and finishes in a few seconds rather than the 5–10 min
that a from-source upstream build would take. Maintainer-only target
`make vendor-blob` rebuilds the vendored blob when upstream Unison
bumps version.

If you *do* want to build the OCaml core yourself (to verify the
vendored blob, to test a new upstream version, or to develop with
patched OCaml source), set `UNISON_SRC` to a local Unison checkout
and override `BLOB`:

```sh
git clone https://github.com/bcpierce00/unison.git ../unison
make build BLOB=$(pwd)/../unison/src/unison-blob.o
```

## Quick install — prebuilt release

The easiest path if a release has been cut for your needs:

1. Open <https://github.com/bcourbage/unison-ui-mac/releases> and
   download the `.app.zip` attached to the most recent release.
2. Unzip and drag `unison-ui-mac.app` to `/Applications`.
3. **Clear the quarantine attribute, then launch.** macOS 15
   (Sequoia) blocks downloaded unsigned apps on first launch with
   *"Apple could not verify ... is free of malware"* and offers
   only "Move to Trash" / "Done" — the old right-click → Open
   trick no longer applies. See
   [First launch & Gatekeeper](#first-launch--gatekeeper) for the
   two workarounds.

The fastest path is the one-line shell install — strips the
quarantine attribute up front so the first launch is a clean
double-click:

```sh
unzip ~/Downloads/unison-ui-mac-0.1.0.app.zip -d /Applications
xattr -dr com.apple.quarantine /Applications/unison-ui-mac.app
open /Applications/unison-ui-mac.app
```

If no release is available for the version you want, or you'd rather
build the binary yourself, see
[Build from source](#install-from-source) below.

## First launch & Gatekeeper

The released `.app` is **ad-hoc code-signed but not Apple-notarized**
(see [Why this isn't a notarized download](#why-this-isnt-a-notarized-download)).
On macOS 15 (Sequoia) the first launch from `/Applications` will be
blocked with:

> *"Apple could not verify 'Unison-UI-Mac.app' is free of malware
> that may harm your Mac or compromise your privacy."*

with only **Move to Trash** and **Done** buttons. (Earlier macOS
releases let you bypass this by right-clicking the app and picking
"Open"; Sequoia removed that escape hatch for downloaded apps.) Two
ways to unblock:

### Option 1 — command line (fastest)

```sh
xattr -dr com.apple.quarantine /Applications/unison-ui-mac.app
open /Applications/unison-ui-mac.app
```

This strips the `com.apple.quarantine` extended attribute macOS
adds to anything downloaded from the internet. Once the attribute
is gone, Gatekeeper stops checking the bundle and double-click
works normally from then on.

### Option 2 — System Settings (GUI)

1. Click **Done** on the blocking dialog (don't move it to Trash).
2. Open **System Settings → Privacy & Security**.
3. Scroll down to the Security section. You'll see:
   > *"Unison-UI-Mac.app" was blocked to protect your Mac.*
4. Click **Open Anyway**, authenticate with Touch ID or your
   password.
5. Try opening the app again — you'll get one more confirmation
   dialog, click **Open Anyway**.

After either path, the app launches normally and macOS adds it to
its approved list; future launches don't prompt.

## Install from source

```sh
# 1. Get build prerequisites (one time)
xcode-select --install
brew install ocaml xcodegen

# 2. Clone this repo
cd ~/somewhere
git clone https://github.com/bcourbage/unison-ui-mac.git
cd unison-ui-mac

# 3. Build + install in one shot
make install
```

That's it. `make install` builds the Release configuration (forced
internally — `make build` on its own defaults to Debug for dev
iteration) and hands off to `install.sh`, which signs, copies to
`/Applications`, clears the quarantine attribute, and opens the app.
After this you'll find **Unison-UI-Mac** in `/Applications` and in
Launchpad. Re-run `make install` after pulling updates to refresh the
installed copy.

If you'd rather run the two halves separately, build Release explicitly:

```sh
make build CONFIG=Release   # Release build into .build/derived/...
./install.sh                # sign + copy + de-quarantine + launch
```

## What the installer script does

`install.sh` is a thin wrapper around three commands that you could run
yourself; the script just makes them harder to typo. Specifically:

1. **Finds the built bundle.** Looks for the Release build first, then
   Debug, under `.build/derived/Build/Products/`. (`make install`
   produces Release; if you're calling `install.sh` directly, build
   Release explicitly with `make build CONFIG=Release` first.) Errors
   out with a clear message if neither exists.
2. **Ad-hoc code-signs it**, replacing the development signature with a
   fresh one tied to no particular identity:
   ```sh
   codesign --force --deep --sign - <bundle>
   ```
   This is the same kind of signature `xcodebuild` already applies in
   the build step, but doing it again after we move the bundle keeps
   the signature consistent with the bundle's new location and any
   incidental file changes (extended attributes, etc.).
3. **Copies the bundle into `/Applications`.** Uses `sudo` automatically
   if your user can't write there.
4. **Clears the quarantine attribute** that macOS adds to anything
   downloaded or copied from another origin:
   ```sh
   xattr -dr com.apple.quarantine /Applications/unison-ui-mac.app
   ```
   Without this, Gatekeeper refuses to open the app and shows the
   "cannot be opened because the developer cannot be verified" alert.
5. **Opens the app** so you can verify it launches.

You can pass `--no-launch` to skip the final `open` step, or
`--dest <path>` to install somewhere other than `/Applications` (for
example `~/Applications`).

## Why this isn't a notarized download

Apple-notarized distribution requires a paid Apple Developer account
($99/year) and an automated submission pipeline. This is a personal
project; that level of process isn't worth the cost or the time. The
ad-hoc signature path is the same one Apple's own documentation
describes for in-house and homebrew-installed apps, and it doesn't
weaken the app's security — it just means Gatekeeper has no third
party to vouch for the build, so you (the person who built it) are
implicitly vouching.

If a friend hands you a copy of this app without you building it
yourself, that's a separate trust decision. Don't run unsigned macOS
apps from untrusted sources.

## Manual install (without the script)

If you'd rather see every step:

```sh
# Build Release explicitly (CONFIG=Debug is the make default):
make build CONFIG=Release
APP=.build/derived/Build/Products/Release/unison-ui-mac.app

codesign --force --deep --sign - "$APP"
sudo cp -R "$APP" /Applications/
sudo xattr -dr com.apple.quarantine /Applications/unison-ui-mac.app
open /Applications/unison-ui-mac.app
```

## Uninstall

```sh
sudo rm -rf /Applications/unison-ui-mac.app
defaults delete net.courbage.unison-ui-mac 2>/dev/null || true
```

The second line removes the app's user defaults (hidden/reordered
profiles, version-mismatch suppressions). Your `~/Library/Application
Support/Unison/` profile and archive directory is left untouched —
delete it manually if you want a fully clean slate, but be aware that
Unison's CLI also uses it.

## TL;DR

```sh
xcode-select --install
brew install ocaml xcodegen
make install
```

## Troubleshooting

- **"can't be opened because Apple cannot check it for malicious
  software"** — quarantine attribute is still on the bundle. Re-run
  `./install.sh` or `sudo xattr -dr com.apple.quarantine
  /Applications/unison-ui-mac.app`.
- **App launches then immediately quits** — check Console.app under
  subsystem `net.courbage.unison-ui-mac` for the crash reason. Most
  common cause is an OCaml install that doesn't match the host
  architecture (e.g. `brew install`ing OCaml under Rosetta on Apple
  Silicon — the runtime libs end up x86_64 and won't link with the
  arm64 vendored blob).
- **`make build` fails with "xcodegen: command not found"** — Homebrew
  is installed but `brew install xcodegen` hasn't run, or your shell
  hasn't picked up Homebrew's PATH yet (`eval "$(/opt/homebrew/bin/brew
  shellenv)"`).
