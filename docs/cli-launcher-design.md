# Command-line launcher: `unison` on PATH resolves to this app

## Goal

`unison -ui graphic` typed in Terminal opens this app. The same `unison`
command, invoked by a remote peer over ssh as `unison -server`, serves the
sync headlessly with the embedded engine. One binary, both roles, with no
dependency on upstream's `Unison.app` or on a Homebrew formula.

## Non-goals

- Replacing upstream's text UI for scripting. `unison -ui text` works through
  the embedded engine, but the profile picker stays the GUI's entry point.
- Managing other products' installations. The app never writes, moves, or
  removes a `unison` link that points anywhere but at this app.
- A persisted preference for "what `unison` points to". That fact lives on
  disk and in PATH order, so the app reports it and acts on it, but does not
  store a belief about it.

## How upstream selects a UI (facts the design rests on)

The `-ui` preference does no runtime lookup. `Main.Body` in `src/main.ml` is a
functor over one UI module chosen at link time: `linktext.ml` produces the
text-only `unison`, `linkgtk3.ml` produces `unison-gui`. In a text-only binary
`-ui graphic` is accepted and ignored.

The macOS app is the reverse arrangement. `uimac/main.m` scans argv for
`-doc`, `-help`, `-version`, `-server`, `-socket`, `-ui` and, if any is
present, calls the OCaml `unisonNonGuiStartup` **before** `NSApplicationMain`.
That runs `Main.init`: `-server` and `-socket` serve and exit; `-ui text` runs
the text UI and exits; `-version` and `-doc` print and exit. Only `-ui graphic`
or a bare profile name returns, and then the Cocoa UI starts.

The `unison` command upstream puts on PATH is `uimac/cltool.c`: it looks the
app up by bundle identifier through Launch Services and `execv`s
`Contents/MacOS/Unison` with argv untouched. It parses nothing. Upstream's
build compiles it into the bundle but installs nothing on PATH; the GUI offers
an opt-in first-launch prompt that copies it to `/usr/local/bin/unison` with
admin rights, and Homebrew's `unison-app` cask symlinked it into the brew
prefix. That cask was disabled on 2026-09-01 for failing Gatekeeper.

## Current state of this app

- `main.swift` goes straight to `NSApplication`. No argv scan.
- `AppDelegate` boots the OCaml runtime with **argv[0] only**, because
  macOS and XCTest inject flags (`-NSTreatUnknownArgumentsAsOpen`, …) that
  Unison's preference parser rejects with a usage error.
- The vendored blob links `uimacbridge.cmo`, so `unisonNonGuiStartup` is
  registered and callable. Nothing calls it.
- Consequence: `unison-ui-mac -server` would open the GUI and drop the flag.
  The README and MANUAL therefore require brew unison on every ssh peer.

## Design

Five components, shipped in three pull requests. Each component has
acceptance criteria below.

### 1. `cltool`: the launcher inside the bundle

A C command-line tool built as its own Xcode target and embedded at
`unison-ui-mac.app/Contents/MacOS/cltool`. It resolves the app executable and
`execv`s it with argv passed through unchanged. Resolution order:

1. **Self-relative.** `_NSGetExecutablePath`, then `realpath`, then replace
   the trailing `/cltool` with `/unison-ui-mac`. This is the path taken when
   the tool is reached through a symlink (the cask, and the manual install).
   It is deterministic and needs no Launch Services.
2. **Bundle-identifier fallback.** `LSCopyApplicationURLsForBundleIdentifier`
   for `net.courbage.unison-ui-mac`. Used only when step 1 finds no
   executable, which happens if someone copied the tool out of the bundle.
   Exactly one match is required. Zero or several matches print the
   candidates to stderr and exit 1. Picking one of several would silently
   run a Debug build next to the installed release.

`exec` matters: the launcher process is replaced, so stdin, stdout, stderr,
the exit status, and the ssh pipe belong to the app with no intermediary.

No Carbon. `LSFindApplicationForInfo`, `FSRef` and `FSRefMakePath` used by
upstream's tool are deprecated.

### 2. The command-line branch in `main.swift`

Runs before `NSApplication.shared`, before Sparkle, before the menu.

**Mode selection** is a pure function of argv and one environment probe,
kept in a testable policy type:

| Condition | Mode |
|---|---|
| Any of `-server`, `-socket`, `-ui`, `-version`, `-doc`, `-help` present | command-line |
| Otherwise, at least one argument present **and** no window-server session | command-line, with `-ui text` prepended |
| Otherwise | GUI, argv reduced to argv[0] as today |

"No window-server session" means `CGSessionCopyCurrentDictionary()` returns
nil. That is the ssh, cron and launchd case. The second row exists for
automation callers running `unison -batch myprofile` without `-ui text`;
upstream's Mac app opens a GUI there and fails.

**In command-line mode** the full argv is handed to `caml_startup` and
`unisonNonGuiStartup` is invoked on the OCaml thread. It exits the process
for `-server`, `-socket`, `-version`, `-doc`, `-help` and `-ui text`. If it
returns, the caller asked for `-ui graphic` (or gave a bare profile with a
GUI session available), and execution continues into the normal GUI path with
the runtime already started. The existing `unison_bridge_startup` guard makes
the later startup call a no-op.

`-ui graphic` with no window-server session cannot be honored. Mirror the GTK
build: warn on stderr and start the text UI instead.

**Positional arguments in GUI mode** (`unison -ui graphic myprofile`, or two
roots) are not supported in this iteration. Exit 1 with a message that names
the profile picker. Silently opening the picker and dropping the argument is
the one behavior this design forbids. Honoring a command-line profile is a
follow-up.

**stdout is the wire.** In command-line mode nothing may write to stdout
before OCaml does. `TraceLog` writes to the unified log, not to stdout, and
is acceptable. Any diagnostic added to this path goes to stderr.

### 3. Bridge support

One new C entry point, `unison_bridge_cli_startup(argc, argv)`, which starts
the runtime with the given argv (reusing `unison_bridge_startup`), dispatches
`unisonNonGuiStartup` through the existing worker, and returns only if OCaml
returned. The main thread blocks meanwhile. That is correct: in command-line
mode there is no AppKit to serve, and `exit` from the OCaml worker ends the
process normally.

### 4. Signing and packaging

- `scripts/sign-app.sh` whitelists `Contents/MacOS/cltool` and signs it
  inside-out before the main executable, same identity, hardened runtime.
  Notarization rejects an unsigned embedded Mach-O.
- The tool ships inside the bundle, so Sparkle updates it with the app. A
  symlink on PATH stays valid across updates because the bundle path does not
  change.
- Cask, in `bcourbage/tap`:

  ```ruby
  binary "#{appdir}/unison-ui-mac.app/Contents/MacOS/cltool", target: "unison"
  conflicts_with formula: "unison"
  ```

  Brew then owns the symlink at `/opt/homebrew/bin/unison`, removes it on
  uninstall, and refuses to install alongside the formula with a clear
  message instead of a half-install.

### 5. Detection, Settings panel, first-launch prompt

A `CommandLineToolStatus` value computed from the filesystem every time it is
needed, never cached across launches. It resolves `unison` on PATH and
classifies the result:

| Classification | Meaning |
|---|---|
| `thisApp` | Resolves to `cltool` inside this app's bundle |
| `homebrewManaged` | `thisApp`, and the link lives under the brew prefix |
| `brewFormula` | Resolves into the Homebrew Cellar |
| `upstreamApp` | Resolves into a bundle with identifier `edu.upenn.cis.Unison` |
| `danglingToThisApp` | Broken link whose target path is this app's former location |
| `danglingOther` | Broken link pointing elsewhere |
| `other` | Anything else |
| `none` | Nothing on PATH |

**Settings, Command Line Tool section.** Shows the classification and the
resolved path in words. Actions by state:

- `none`: **Install** creates `/usr/local/bin/unison` as a symlink to the
  bundled tool. One administrator prompt.
- `danglingToThisApp`: **Repair** replaces the link.
- `thisApp` (not brew): **Remove** deletes the link.
- `homebrewManaged`: read-only, "Managed by Homebrew".
- Every other state: read-only, with the path shown. Never offers to remove
  or overwrite something this app does not own.

**First-launch prompt.** Shown once per launch, after the picker appears,
only when all hold:

- Classification is `none` or `danglingToThisApp`.
- The user has not checked "Do not ask again". That is a stored preference
  about prompting, which the app controls, not about the disk.
- GUI launch. Command-line mode exits before AppKit. The existing XCTest and
  `UNISON_UI_SMOKE` guards also suppress it.

"Not Now" without the checkbox asks again next launch, as upstream does.

Draft copy, subject to the usual review before release:

> **Install the unison command?**
> Adds a `unison` command in /usr/local/bin that opens this app. Terminal
> commands such as `unison -ui graphic` and ssh syncs from other machines then
> use this app. Requires an administrator password.
> [ ] Do not ask again
> **Install**   Not Now

## Scenario matrix

| Scenario | Result | Notes |
|---|---|---|
| Brew formula only | Unchanged. Text UI; `-ui graphic` ignored. | Not this app's concern. |
| Brew formula plus this cask | Install refused with a clear message. | `conflicts_with`. User picks one. |
| This app via cask | `unison -ui graphic` opens the app; `unison -ui text` runs in the terminal; `brew uninstall --cask` removes both. | Incoming ssh PATH lacks `/opt/homebrew/bin`; peers set `servercmd = /opt/homebrew/bin/unison`. |
| This app via zip | Nothing on PATH until Install. | First-launch prompt or Settings. Link lands in `/usr/local/bin`, which **is** on the incoming-ssh PATH per `/etc/paths`. |
| Sparkle update | Link stays valid; bundled tool updates too. | Command-line branch exits before Sparkle initializes. |
| Mac that is both GUI user and ssh target | One binary serves both. | File access over ssh follows sshd's Full Disk Access grant, unchanged. |
| Automation (`unison -batch p` from launchd) | Text UI via the headless row. | Upstream's Mac app fails here. |
| Two copies of the app installed | Self-relative resolution is deterministic; fallback fails closed on ambiguity. | |
| App moved after linking | `danglingToThisApp`, Repair offered. | Cask installs are immune. |
| App deleted, link left behind | `danglingToThisApp` on reinstall, otherwise "not found". | Manual uninstall doc removes the link. |
| Upstream `Unison.app` also present | Both coexist. Its launcher looks up its own bundle id. | Only the filename `unison` is contested; Settings shows who owns it. |
| Brew `upgrade --greedy` after Sparkle | Can downgrade to the tap's version. | Release checklist already bumps the cask with each release. |
| `addversionno` on a peer | Peer invokes `unison-2.54`. | Manual note: second link under that name. |

## Acceptance criteria

### PR A: launcher and command-line branch

- `cltool` target exists in `project.yml`, embeds into `Contents/MacOS`, and
  `scripts/sign-app.sh` signs it; `make check-sign-app` covers the whitelist.
- Shell test: through a symlink, `unison -version` prints exactly the
  embedded engine's version line to stdout and nothing else, exit 0.
- Shell test: `unison -server` fed a closed stdin exits without creating a
  window and without writing to stdout before the protocol.
- Shell test: with two bundles present and the tool copied out of both,
  invocation exits 1 and lists both candidates on stderr.
- Unit tests for the mode-selection policy cover every row of the mode table,
  including `-ui graphic` with no session and positional arguments in GUI
  mode.
- `unison -ui graphic` from Terminal opens the picker; `unison -ui text`
  runs a profile in the terminal; `ssh heracles /path/to/unison -version`
  from another host prints the version. Recorded in the PR body.
- README and MANUAL: the "remote needs brew unison" requirement becomes "the
  remote needs a `unison` of 2.52 or later, which on a Mac with this app is
  the bundled command".

### PR B: cask

- `binary` and `conflicts_with` stanzas. `brew install --cask` on a machine
  with the formula installed fails with brew's conflict message and installs
  nothing. On a clean machine `which unison` resolves into the bundle.

### PR C: detection, Settings, prompt

- Unit tests for the classifier, one per classification, using fixture paths.
- Install and Repair create the symlink through a single admin prompt; Remove
  only acts when the link resolves to this bundle.
- Prompt suppression is honored across launches; "Not Now" re-prompts.
- Copy reviewed before the release that ships it.

## Open items

- Honoring a command-line profile or root pair in GUI mode. Needs picker
  bypass and a decision on what "profile not found" looks like in a GUI.
- Whether `unisonNonGuiStartup`'s disabling of the progress printer should
  be reverted for `-ui text`, so terminal users see transfer progress. It is
  upstream's behavior; keep it unless it proves annoying.
