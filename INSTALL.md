# Installing Unison-UI-Mac

This page walks through getting Unison-UI-Mac running on your Mac.
Three paths, in increasing order of effort:

1. **[Homebrew (recommended)](#quickest-install-homebrew)**: one
   command, and the app keeps itself up to date after that. The
   recommended path for anyone who already has Homebrew installed.
2. **[Prebuilt `.app` from the Releases page](#quick-install-prebuilt-release)**:
   the manual zip-download path. Use this if you don't use Homebrew or
   want explicit control over which version is installed.
3. **[Build from source](#install-from-source)**: required for
   development, or if you'd rather build the binary yourself.

> Already familiar with macOS dev tooling? The 60-second version is at the
> bottom under [TL;DR](#tldr).

## Quickest install: Homebrew

The recommended path for end users:

```sh
brew install --cask bcourbage/tap/unison-ui-mac
open /Applications/unison-ui-mac.app
```

That's it. Launch the app once, and updates after that come through the app
itself.

To uninstall:

```sh
brew uninstall --cask unison-ui-mac           # remove the app
brew uninstall --cask --zap unison-ui-mac     # also remove user defaults
```

The cask formula lives at
<https://github.com/bcourbage/homebrew-tap/blob/main/Casks/unison-ui-mac.rb>.
It pins macOS 15+ and Apple Silicon, so brew refuses to install on
incompatible hosts rather than producing a bundle that won't launch.

## System requirements

### To run the app

- **macOS 15 (Sequoia) or later** on an **Apple Silicon Mac**. The
  app's deployment target is `15.0` and ships as an arm64-only binary.
  Intel Macs are not supported.
- **~60 MB of disk.** The bundle is around 50 MB (the embedded OCaml
  core is the bulk of it).
- **No admin rights** beyond what `/Applications` itself requires: the
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
- **Build tools**: `xcodegen` (via Homebrew) plus **OCaml 5.5.0**.
  ```sh
  brew install xcodegen
  # OCaml 5.5.0 specifically: the vendored blob's runtime ABI is locked to
  # it, so the app must link against 5.5.0 (`libasmrun`, `libthreadsnat`, …).
  # The reproducible way is an opam switch:
  opam switch create 5.5.0    # then: eval $(opam env)
  ```
  A plain `brew install ocaml` works **only** while Homebrew's current
  formula is exactly 5.5.0; `make` runs `check-ocaml-version` and fails fast
  otherwise. OCaml is needed for the runtime libraries we link, *not* to
  compile Unison itself.

That's it. **No upstream Unison clone required**: a prebuilt
`unison-blob.o` lives in `vendor/` (see
[vendor/README.md](vendor/README.md) for provenance). The build
compiles Swift + C, links against the vendored blob + the OCaml 5.5.0
runtime from your selected toolchain (the preferred, reproducible one is
the opam 5.5.0 switch above; a Homebrew `ocaml` also works only while it
is exactly 5.5.0), and finishes in a few seconds rather than the 5–10 min
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

## Quick install: prebuilt release

Use this path if you don't have Homebrew, or want to install a specific
version other than the latest. Otherwise the
[Homebrew path above](#quickest-install-homebrew) is shorter.

1. Open <https://github.com/bcourbage/unison-ui-mac/releases> and
   download the `unison-ui-mac-<version>.app.zip` attached to the release
   you want.
2. Unzip it and drag the app (its file name is `unison-ui-mac.app`, shown in
   Finder as **Unison-UI-Mac**) to `/Applications`.
3. Double-click to launch. Updates after that come through the app itself.

If no release is available for the version you want, or you'd rather
build the binary yourself, see
[Build from source](#install-from-source) below.

## Install from source

```sh
# 1. Get build prerequisites (one time)
xcode-select --install
brew install xcodegen        # + OCaml 5.5.0 (e.g. opam switch create 5.5.0), ABI-locked, enforced by check-ocaml-version

# 2. Clone this repo
cd ~/somewhere
git clone https://github.com/bcourbage/unison-ui-mac.git
cd unison-ui-mac

# 3. Build + install in one shot
make install
```

That's it. `make install` builds the Release configuration (forced
internally; `make build` on its own defaults to Debug for dev
iteration) and hands off to `install.sh`, which signs the app, copies it
to `/Applications`, and opens it. After this you'll find
**Unison-UI-Mac** in `/Applications` and in Launchpad. Re-run
`make install` after pulling updates to refresh the installed copy.

If you'd rather run the two halves separately, build Release explicitly:

```sh
make build CONFIG=Release   # Release build into .build/derived/...
./install.sh                # sign + copy to /Applications + launch
```

## What the installer script does

`install.sh` is a thin wrapper around a handful of commands you could run
yourself. Specifically:

1. **Finds the built bundle.** Looks for the Release build first, then
   Debug, under `.build/derived/Build/Products/`. (`make install`
   produces Release; if you're calling `install.sh` directly, build
   Release explicitly with `make build CONFIG=Release` first.) Errors
   out with a clear message if neither exists.
2. **Signs it** via `scripts/sign-app.sh`, inside-out. When a Developer ID
   Application certificate is in your keychain, it signs with that identity
   and a hardened runtime; otherwise it falls back to an ad-hoc signature for
   local use (`ADHOC=1` forces the fallback).
3. **Copies the bundle into `/Applications`.** Uses `sudo` automatically
   if your user can't write there.
4. **Clears the quarantine attribute** (`xattr -dr com.apple.quarantine`).
   This matters only for a locally built or ad-hoc-signed bundle that macOS
   flagged after a copy from another origin; the official Homebrew and Releases
   builds are Developer ID-signed and notarized, so they never need it.
5. **Opens the app** so you can verify it launches.

You can pass `--no-launch` to skip the final `open` step, or
`--dest <path>` to install somewhere other than `/Applications` (for
example `~/Applications`).

## Manual install (without the script)

If you'd rather see every step:

```sh
# Build Release explicitly (CONFIG=Debug is the make default):
make build CONFIG=Release
APP=.build/derived/Build/Products/Release/unison-ui-mac.app

scripts/sign-app.sh "$APP"          # Developer ID if one is in the keychain;
                                    # pass "-" as a second argument for ad-hoc
sudo cp -R "$APP" /Applications/
open /Applications/unison-ui-mac.app
```

## Pinning a specific version

Homebrew casks don't pin versions side by side: `brew upgrade` always
moves you to the latest published release, and there's no
`unison-ui-mac@0.1` track. If you want to **stay on a specific version**
(e.g. keep `0.1.x` and skip a future `0.2.0`), install that version from
source by its git tag and take it out of Homebrew's hands:

```sh
# 1. If you installed via Homebrew, stop it from managing the app
brew uninstall --cask unison-ui-mac

# 2. Build and install the exact version you want
git clone https://github.com/bcourbage/unison-ui-mac.git
cd unison-ui-mac
git tag                    # list available versions
git checkout <version-tag> # e.g. the version you want to stay on
make install               # Release build → /Applications (see "Install from source")
```

Nothing will change the app after this until you choose to. To move to
a different version later, `git checkout <other-tag>` then `make install`
again. To rejoin the auto-updating Homebrew track, reinstall the cask:
`brew install --cask bcourbage/tap/unison-ui-mac`.

Prerequisites are the same one-time tools as [Install from
source](#install-from-source) (`xcode-select --install`,
`brew install xcodegen` plus OCaml 5.5.0; see above).

## Uninstall

```sh
sudo rm -rf /Applications/unison-ui-mac.app
defaults delete net.courbage.unison-ui-mac 2>/dev/null || true
```

The second line removes the app's user defaults (hidden/reordered
profiles, version-mismatch suppressions). Your `~/Library/Application
Support/Unison/` profile and archive directory is left untouched;
delete it manually if you want a fully clean slate, but be aware that
Unison's CLI also uses it.

## TL;DR

**End users:**

```sh
brew install --cask bcourbage/tap/unison-ui-mac
```

**Developers (build from source):**

```sh
xcode-select --install
brew install xcodegen        # + OCaml 5.5.0 (e.g. opam switch create 5.5.0), ABI-locked, enforced by check-ocaml-version
make install
```

## Troubleshooting

- **`brew install --cask bcourbage/tap/unison-ui-mac` errors with
  "Cask 'unison-ui-mac' is unavailable"**: the tap isn't registered
  yet. Run `brew tap bcourbage/tap` once, then re-run install. The
  fully-qualified form (`bcourbage/tap/unison-ui-mac`) usually
  auto-taps, but some Homebrew configurations need the explicit
  `brew tap` first.
- **`brew install --cask` errors with "depends_on macos"**: your
  Mac is older than macOS 15 (Sequoia) or running on Intel. The
  app is arm64-only and targets macOS 15+; the cask refuses to
  install on older OSes / Intel CPUs rather than producing a
  bundle that won't launch.
- **App launches then immediately quits**: check Console.app under
  subsystem `net.courbage.unison-ui-mac` for the crash reason. Most
  common cause is an OCaml install that doesn't match the host
  architecture (e.g. `brew install`ing OCaml under Rosetta on Apple
  Silicon, the runtime libs end up x86_64 and won't link with the
  arm64 vendored blob).
- **`make build` fails with "xcodegen: command not found"**: Homebrew
  is installed but `brew install xcodegen` hasn't run, or your shell
  hasn't picked up Homebrew's PATH yet (`eval "$(/opt/homebrew/bin/brew
  shellenv)"`).
