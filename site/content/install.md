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

## The `unison` command

The app bundle includes a command-line launcher. Linked onto your PATH under the
name `unison`, it behaves like Unison's own command: `unison -ui graphic` opens the
app, `unison <profile>` runs Unison's text interface in the terminal on the app's
embedded engine, and `unison -server`, which another machine runs over ssh when it
syncs to this Mac, is served by the app's engine. A Mac with this app therefore
needs no separate Unison installation to be the far side of an SSH profile.

Homebrew installs create the `unison` link automatically — unless the `unison`
formula already owns that name, in which case Homebrew installs the app but keeps
the formula's command; the [manual]({{REPO}}/blob/main/MANUAL.md#the-unison-command)
covers running both. For a direct download, **Settings ▸ Command Line** can add the
app's bundled `unison` to your login-shell PATH with no administrator password: it
shows what `unison` currently resolves to, writes a marked block to your shell
startup file when it can do so safely, and otherwise shows what to add and names
the file to edit when it can identify one — when it cannot safely identify the file,
such as a redirected `ZDOTDIR` or an unsupported shell, it says so rather than point
at the wrong file. The app also offers this at first launch when nothing on your
PATH is named `unison`. Details, and the note for
machines that sync to this Mac over ssh, are in the
[manual]({{REPO}}/blob/main/MANUAL.md#the-unison-command).

## Updating

Once installed, the app checks for updates through Sparkle over a cryptographically
signed feed. Check any time from **App menu ▸ Check for Updates**.

## Uninstalling

- Homebrew: `brew uninstall --cask unison-ui`
- Manual: move `unison-ui-mac.app` to the Trash. To also remove saved settings, run
  `defaults delete net.courbage.unison-ui-mac`.
