# Install Unison UI for macOS

**Requirements:** macOS 15 (Sequoia) or later, Apple Silicon. Free and open source
under the GPLv3.

## Homebrew (recommended)

```
brew install --cask bcourbage/tap/unison-ui-mac
```

This installs the latest signed, notarized build. The app keeps itself up to date
through Sparkle, so you do not need to re-run Homebrew to update.

## Signed .app download

Download the latest `unison-ui-mac-<version>.app.zip` from the
[GitHub Releases page](https://github.com/bcourbage/unison-ui-mac/releases/latest),
unzip it, and move `unison-ui-mac.app` to your Applications folder. Release builds
are Developer ID-signed and notarized by Apple, so they open without a Gatekeeper
prompt.

## Build from source

The full build instructions live in
[INSTALL.md](https://github.com/bcourbage/unison-ui-mac/blob/main/INSTALL.md).
In short: install Xcode, `xcodegen`, and OCaml 5.5.0 built for the macOS 15
deployment target, then run `make build` (or `make install`). A prebuilt OCaml
engine is vendored, so an everyday build compiles Swift and links in a few seconds
rather than compiling Unison from source.

## Updating

Once installed, the app checks for updates through Sparkle over a cryptographically
signed feed. You can also check any time from **App menu ▸ Check for Updates**.

## Uninstalling

- Homebrew: `brew uninstall --cask unison-ui-mac`
- Manual: move `unison-ui-mac.app` to the Trash. To also remove saved settings:
  `defaults delete net.courbage.unison-ui-mac`.
