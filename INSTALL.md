# Installing Unison-UI-Mac

This page walks through getting Unison-UI-Mac built and running on your Mac.
There is no signed release binary — you build from source, then run an
installer script that ad-hoc-signs the bundle, copies it to `/Applications`,
and clears the macOS quarantine attribute so Gatekeeper lets it launch.

> Already familiar with macOS dev tooling? The 60-second version is at the
> bottom under [TL;DR](#tldr).

## System requirements

### To run the app

- **macOS 15 (Sequoia) or later.** The app's deployment target is `15.0`;
  it will refuse to launch on earlier releases.
- **Apple Silicon Mac.** The build produces a host-architecture binary
  (arm64 on Apple Silicon, x86_64 on Intel) — both are supported, but you
  must build on the same architecture you intend to run on. There is no
  universal binary today.
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
  Tested against OCaml 5.4.1; any 5.x release should work.
- **A local clone of upstream Unison** at `../unison/` relative to this
  repo (i.e. as a sibling directory):
  ```sh
  cd ..
  git clone https://github.com/bcpierce00/unison.git
  cd unison-ui-mac
  ```
  If you keep upstream Unison somewhere else, set `UNISON_SRC` in the
  environment to point at the `src/` directory inside it.
- **~2 GB free disk** for the upstream OCaml build artifacts.
- **Time**: the first build takes 5–10 minutes because it compiles
  Unison's entire OCaml core into `unison-blob.o`. Subsequent builds
  only recompile changed Swift/C and finish in a few seconds.

## Install (recommended path)

```sh
# 1. Get build prerequisites (one time)
xcode-select --install
brew install ocaml xcodegen

# 2. Clone upstream Unison and this repo as siblings
cd ~/somewhere
git clone https://github.com/bcpierce00/unison.git
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
git clone https://github.com/bcpierce00/unison.git ../unison
make install
```

## Troubleshooting

- **"can't be opened because Apple cannot check it for malicious
  software"** — quarantine attribute is still on the bundle. Re-run
  `./install.sh` or `sudo xattr -dr com.apple.quarantine
  /Applications/unison-ui-mac.app`.
- **App launches then immediately quits** — check Console.app under
  subsystem `net.courbage.unison-ui-mac` for the crash reason. Most
  common cause is an OCaml architecture mismatch (e.g. ran the
  installer after `brew install`ing OCaml under Rosetta).
- **`make build` fails with "cannot find unison-blob.o"** — the
  upstream Unison checkout at `../unison/` is missing or `make macui`
  failed there. Try `cd ../unison && make macui` directly to see the
  underlying error.
- **`make build` fails with "xcodegen: command not found"** — Homebrew
  is installed but `brew install xcodegen` hasn't run, or your shell
  hasn't picked up Homebrew's PATH yet (`eval "$(/opt/homebrew/bin/brew
  shellenv)"`).
