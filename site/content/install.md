# Install Unison UI for macOS

**Requirements:** macOS 15 (Sequoia) or later, Apple Silicon. Free and open source
under the GPLv3.

Two ways to install, whichever fits your setup. Both receive updates through
Sparkle. Whether the app checks automatically depends on the choice made at first
launch, and a manual check is always available from **App menu ▸ Check for
Updates**.

## Homebrew

<pre class="install" data-copyable><code>{{CASK}}</code></pre>

The app keeps itself up to date through Sparkle, so there is no need to re-run
Homebrew to update.

## Direct .app download

Download the latest `unison-ui-mac-<version>.app.zip` from the
[GitHub Releases page]({{REPO}}/releases/latest), unzip it, and move
`unison-ui-mac.app` to the Applications folder.

## Build from source

Full build instructions are in
[INSTALL.md]({{REPO}}/blob/main/INSTALL.md). In short: install Xcode, `xcodegen`,
and OCaml 5.5.0 built for the macOS 15 deployment target, then run `make build` (or
`make install`). A prebuilt OCaml engine is vendored, so an everyday build compiles
Swift and links in a few seconds rather than compiling Unison from source.

## Updating

Once installed, the app checks for updates through Sparkle over a cryptographically
signed feed. Check any time from **App menu ▸ Check for Updates**.

## Uninstalling

- Homebrew: `brew uninstall --cask unison-ui-mac`
- Manual: move `unison-ui-mac.app` to the Trash. To also remove saved settings, run
  `defaults delete net.courbage.unison-ui-mac`.
