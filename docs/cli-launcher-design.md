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
`execv`s it with argv passed through unchanged. Resolution:

1. **Inside a bundle.** `_NSGetExecutablePath`, then `realpath`. When the
   result ends in `/Contents/MacOS/cltool`, the enclosing bundle is the only
   candidate. Its `Info.plist` is read with `CFBundle`: `CFBundleIdentifier`
   must equal `net.courbage.unison-ui-mac`, and the file named by
   `CFBundleExecutable` must exist and be executable. A foreign identifier,
   a missing `Info.plist`, or a missing executable is bundle damage: the tool
   says which on stderr and exits 1. It never falls through to Launch
   Services from inside a bundle, because "the executable next to me is
   missing" is not a reason to run some other copy. This is the path taken
   through a symlink (the cask, and the manual install).
2. **Outside a bundle.** The tool was copied out. `LSCopyApplicationURLsFor
   BundleIdentifier` is asked for our identifier; exactly one registered
   application is required, and it is verified the same way as in step 1.
   Zero or several matches print the candidates to stderr and exit 1. Picking
   one of several would silently run a Debug build next to the installed
   release.

What the two steps prove: step 1 proves the tool is running the app whose
bundle it is physically part of, and that the bundle declares our identity.
Step 2 proves only that Launch Services knows exactly one app with our
identity. Neither proves the app is the *intended* install when a user keeps
two copies; step 1 makes the symlink decide that, deterministically.

`exec` matters: the launcher process is replaced, so stdin, stdout, stderr,
the exit status, and the ssh pipe belong to the app with no intermediary.

No Carbon. `LSFindApplicationForInfo`, `FSRef` and `FSRefMakePath` used by
upstream's tool are deprecated.

### 2. The command-line branch in `main.swift`

Runs before `NSApplication.shared`, before Sparkle, before the menu.

**Mode selection** is a pure function of argv and three environment facts,
kept in a testable policy type (`CommandLineInvocationPolicy`):

- *session*: `CGSessionCopyCurrentDictionary()` is non-nil. This is Quartz
  session membership, nothing more. False under ssh, cron and launchd
  daemons; true for a LaunchAgent in a logged-in session.
- *tty*: `isatty(STDIN_FILENO)`. A person in Terminal has one; launchd, cron
  and ssh commands do not. Together with *session* this separates a person
  from automation without guessing intent from one probe.
- *test host*: XCTest or `UNISON_UI_SMOKE`. Checked first.

Before classification, host-injected flags (`-NS…` and `-Apple…` with their
value, `-psn_…`) are removed on **every** path. Option names follow `Uarg`'s
grammar: leading dashes are not significant and `-name=value` is one token,
so `-ui=text` and `--server` are recognized. The remaining "user arguments"
drive the table, rows evaluated in order:

| Row | Condition | Mode |
|---|---|---|
| 1 | test host | GUI, argv[0] only. The test host must reach `applicationDidFinishLaunching`, where `UNISON` is redirected, before the runtime starts. |
| 2 | no user arguments, session | GUI, argv[0] only (Finder, `open`, Xcode). |
| 3 | no user arguments, no session | command-line, `-ui text`: upstream prints usage and exits. AppKit is never attempted without a session. |
| 4 | an engine option present (`server`, `socket`, `ui`, `version`, `doc`, `help`), and `-ui graphic` with no session | command-line, `graphic` rewritten to `text`, notice on stderr. The GTK build's behavior. |
| 5 | an engine option present, otherwise | command-line, user arguments passed through. Precedence among mixed options is upstream's (`Main.init` checks `-version` before `-server`). |
| 6 | no engine option, and (no session **or** no tty) | command-line, `-ui text` prepended: automation such as `unison -batch p` from launchd or cron, in or out of a GUI session. |
| 7 | no engine option, session and tty | unsupported: exit 1 with a message naming the arguments, the picker, and `-ui text`. Covers `unison myprofile`, two roots, and unknown options typed in Terminal. |

**In command-line mode** the full user argv is handed to `caml_startup` and
`unisonNonGuiStartup` is invoked on the OCaml thread. It exits the process
for `-server`, `-socket`, `-version`, `-doc`, `-help` and `-ui text`, and
upstream's parser reports unknown or malformed options with usage and exit 2.
If it returns, the caller asked for `-ui graphic` with a session, and
execution continues into the normal GUI path with the runtime already
started. The existing `unison_bridge_startup` guard makes the later startup
call a no-op. This is the one command-line path that reaches Sparkle and the
menu; the headless roles never do.

**After init0 on the graphical continuation** (`unison -ui graphic …` with a
session), upstream's `unisonInit0` has extracted any profile or roots from
argv. Two roots have no representation in the picker: stderr message, exit 1.
A profile is preselected in the picker. Opening it directly is a follow-up.
Silently opening the picker and dropping the argument is the one behavior
this design forbids. Precedence with row 4: without a session, `-ui graphic
p` runs `p` in the text interface; the graphical continuation, and its
positional rules, apply only when a window can be shown.

**stdout is the wire.** In command-line mode nothing may write to stdout
before OCaml does. `TraceLog` writes to the unified log, not to stdout, and
is acceptable. Any diagnostic added to this path goes to stderr.

### 3. Bridge support

One new C entry point, `unison_bridge_cli_startup(argc, argv)`, which starts
the runtime with the given argv (reusing `unison_bridge_startup`), dispatches
`unisonNonGuiStartup` through the existing worker via the exception-returning
callback (`caml_callback_exn`, as every other bridge wrapper does), and
returns a status. Three outcomes, all defined:

- OCaml called `exit`: the process ends from the worker while the main
  thread is parked in `run_on_ocaml_thread`. Correct on this path; there is
  no AppKit to serve.
- OCaml returned normally: `UNISON_BRIDGE_OK`; the caller continues into the
  graphical launch.
- OCaml raised: the exception is printed to stderr with
  `caml_format_exception`, the function returns `UNISON_BRIDGE_ERR_EXN`, and
  the caller exits 1. An exception can never be mistaken for the graphical
  continuation, and never strands the worker, because it is caught at the
  callback boundary rather than escaping `req->fn`.

Two small accessors come with it. `_ocaml_init0` already receives
`unisonInit0`'s `string option` result (the command-line profile); it now
copies it out, exposed as `unison_bridge_command_line_profile()`.
`unison_bridge_command_line_roots_set()` wraps the already-registered
`areRootsSet`. No change to the vendored blob.

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
  ```

  Brew then owns the symlink at `#{HOMEBREW_PREFIX}/bin/unison` and removes
  it on uninstall. There is no cask-level way to declare a conflict with a
  formula: Homebrew's `ConflictsWith` DSL accepts only `cask:`
  (`Library/Homebrew/cask/dsl/conflicts_with.rb`, `VALID_KEYS = [:cask]`).
  What happens instead when the formula is linked: the `binary` artifact
  finds `bin/unison` occupied, the installer raises "It seems there is
  already a Binary at …", and its rescue path uninstalls the artifacts it
  had placed (`cask/installer.rb`), so the app is not left half-installed.
  The user then chooses: `brew unlink unison` and retry, or install the app
  from the zip and keep the formula's CLI. Both paths are documented; the
  second is the supported way to have the formula's text CLI and this GUI on
  one machine.

  Downgrading through brew to a cask version that predates the `binary`
  stanza removes the link (artifacts follow the installed definition). A
  manual link is not managed and dangles after such a downgrade; Settings
  reports it.

### 5. Detection, Settings panel, first-launch prompt

A `CommandLineToolStatus` value computed from the filesystem every time it is
needed, never cached across launches. A Finder-launched process does not have
the user's shell PATH, and the design itself establishes that Terminal and
incoming ssh see different PATHs, so the status is computed for **two named
contexts** and both are shown:

- *Terminal*: the PATH of the user's login shell, obtained by running
  `$SHELL -l -c 'printf %s "$PATH"'`.
- *Incoming ssh*: the PATH `path_helper` builds from `/etc/paths` and
  `/etc/paths.d`, which is what a non-interactive remote command sees on a
  stock macOS.

For each context the first PATH entry holding a `unison` **entry** (a file or
a symlink, dangling included; `which` skips dangling links and must not be
used here) is classified:

| Classification | Evidence |
|---|---|
| `thisApp` | Resolves to a file whose real path ends in `/Contents/MacOS/cltool` inside a bundle whose `Info.plist` identifier is ours |
| `homebrewManaged` | `thisApp`, the link lives under `$(brew --prefix)/bin`, **and** the Caskroom holds an install receipt for `unison-ui-mac`. Location alone is not ownership. |
| `brewFormula` | Resolves into the Homebrew Cellar |
| `upstreamApp` | Resolves into a bundle with identifier `edu.upenn.cis.Unison` |
| `danglingLauncherPath` | Broken link whose target path ends in `/unison-ui-mac.app/Contents/MacOS/cltool`. This is a pathname, not proof of ownership; it identifies what the link *was for*, which is all Repair needs to know (below). |
| `danglingOther` | Broken link pointing anywhere else |
| `other` | Anything else, path shown |
| `none` | No entry in that context |

**Settings, Command Line Tool section.** Shows both contexts, the
classification and the resolved path in words. Actions are offered from the
Terminal-context result and are gated by what the evidence proves:

- `none` in both contexts: **Install** creates `/usr/local/bin/unison` as a
  symlink to the bundled tool. One administrator prompt. If the incoming-ssh
  context already shows an entry, Install is withheld and the entry shown.
- `danglingLauncherPath`: **Repair** replaces the broken link, with the old
  target path shown in the confirmation. What this replaces is a link to
  nothing; the only thing lost is a pathname, and the dialog shows it.
  Nothing that resolves is ever replaced.
- `thisApp` (not `homebrewManaged`): **Remove** deletes the link.
- `homebrewManaged`: read-only, "Managed by Homebrew".
- Every other state: read-only, with the path shown. Never offers to remove
  or overwrite something that resolves to anything but this app.

**First-launch prompt.** Shown once per launch, after the picker appears,
only when all hold:

- Classification is `none` in both contexts, or `danglingLauncherPath`.
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
| Brew formula linked, then this cask | Cask install fails at the `binary` artifact ("already a Binary at …"); brew rolls back the app it had placed. | User chooses `brew unlink unison`, or the zip. |
| Brew formula plus this app from the zip | Both work. `unison` is the formula's CLI; the app runs from the picker. Install is offered only if nothing owns the name, so it is not offered here. | The supported way to keep the formula's CLI. |
| This app via cask | `unison -ui graphic` opens the app; `unison -ui text` runs in the terminal; `brew uninstall --cask` removes both. | Incoming ssh PATH lacks the brew prefix; peers set `servercmd`. On Intel, the prefix is `/usr/local`, so `bin/unison` is the same path a manual install would use, and the incoming-ssh PATH does include it. |
| This app via zip | Nothing on PATH until Install. | First-launch prompt or Settings. Link lands in `/usr/local/bin`, which is on the incoming-ssh PATH per `/etc/paths` on a stock macOS; Settings measures rather than assumes. |
| Fresh zip install, first run over ssh | Gatekeeper's first-launch assessment of a quarantined app needs a GUI session; over ssh the exec may be refused. | Manual: launch the app once from Finder before relying on ssh. Cask installs are not quarantined. |
| Sparkle update | Link stays valid; bundled tool updates too. | The headless roles exit before Sparkle initializes; the `-ui graphic` continuation reaches Sparkle like any graphical launch. |
| Sparkle replaces the bundle while a `-server` process runs | The running process keeps its mapped binary; new invocations resolve the new bundle. The old bundle is moved aside, so a link stays valid. | Same as any in-place app update with a running helper. |
| Brew `upgrade --greedy` after Sparkle | Can downgrade to the tap's version. A downgrade to a pre-launcher cask version removes brew's link; a manual link dangles. | Release checklist already bumps the cask with each release; Settings reports the dangling case. |
| Mac that is both GUI user and ssh target | One binary serves both. | File access over ssh follows sshd's Full Disk Access grant, unchanged. |
| Automation without a session (`unison -batch p` from cron, ssh, a daemon) | Text UI (row 6). | Upstream's Mac app fails here. |
| Automation in a GUI session (a LaunchAgent running `unison -batch p`) | Text UI (row 6, no tty). | Session membership alone would have misclassified this. |
| Person in Terminal: `unison p`, two roots, or `unison -bogus` | Refused with a message (row 7). | Upstream would report `-bogus` itself; here the person is told what the GUI cannot take and how to reach the text UI. |
| `=` and double-dash forms (`-ui=text`, `--server`) | Recognized as engine options. | `Uarg` splits at `=` and options are matched by name. |
| XCTest or smoke host, any arguments | GUI path, argv[0] only. | `UNISON` redirection in `applicationDidFinishLaunching` precedes the runtime start, as today. |
| Xcode scheme runs `-ui graphic` with `-NSDocumentRevisionsDebugMode YES` | Host flags stripped before the engine sees argv. | Stripping applies on every path. |
| Two copies of the app installed | Through a link, the link's bundle wins after identity verification. A copied-out tool fails closed on two Launch Services matches. | |
| Damaged bundle (executable missing, or foreign `Info.plist`) | Launcher exits 1 naming the damage; never runs another copy. | |
| App moved after linking | `danglingLauncherPath`, Repair offered with the old path shown. | Cask installs are immune. |
| App deleted, link left behind | `danglingLauncherPath` on reinstall, otherwise "command not found". | Manual uninstall doc removes the link. |
| Upstream `Unison.app` also present | Both coexist. Its launcher looks up its own bundle id. | Only the filename `unison` is contested; Settings shows who owns it in each context. |
| `addversionno` on a peer | Peer invokes `unison-2.54`. | Manual note: second link under that name. |

## Acceptance criteria

Each gate is named for what it proves. None of them proves notarization or
Gatekeeper acceptance of the shipped bundle; that remains the release
pipeline's job (Developer ID signing, notarization, and the macOS-15 launch
smoke on a quarantined download), which `sign-app.sh` and its structural test
do not replace.

### PR A: launcher and command-line branch

- `cltool` target exists in `project.yml` and embeds into `Contents/MacOS`.
  `make check-sign-app` proves `sign-app.sh` refuses a bundle without it and
  does not reject it as unexpected code. That is a structural check of the
  script, not a signing happy path.
- `verify-bundle-minos.sh` on the built bundle reports the launcher at
  exactly the deployment target (15.0).
- `make check-cltool` (cc only): through a symlink, argv[0] resolved and
  arguments intact, exit status passed through, stderr silent; direct
  invocation; copied out with no registered app, exit 1 and stdout empty;
  bundle with a foreign identifier, exit 1 naming both identifiers and no
  Launch Services fallback; genuine bundle with its executable missing, exit
  1 saying damaged and no fallback; bundle without `Info.plist`; a
  non-executable sibling. The two-copies case is not in this gate: it needs
  two registered Launch Services entries, which a fixture cannot arrange
  deterministically, so it is covered by the identity check plus the
  fail-closed count in code review.
- Unit tests for the mode-selection policy cover every row of the table,
  `=` and double-dash forms, mixed engine options passed through unreordered,
  `-ui graphic` with no session (both forms, profile kept), host flags on the
  command-line path, no arguments with no session, GUI-session automation
  without a tty, and a person in Terminal with a profile or an unknown option.
- Live, through a PATH symlink, `UNISON` pointed at a throwaway directory:
  `unison -version` prints exactly the engine's version line on stdout, empty
  stderr, exit 0. `unison -help` prints usage, exit 2 (upstream's code).
  `unison -server </dev/null` exits with 0 bytes on stdout and no GUI
  process. `unison -ui text -batch <local profile>` syncs two files.
  `unison -ui text NoSuchProfile` fails with usage. `unison NoSuchProfile`
  in Terminal is refused. `unison -ui graphic NoSuchProfile` fails with
  upstream's "Profile … does not exist" (proves the full argv reached OCaml).
  `unison -ui graphic` brings the GUI up; `unison -ui graphic <profile>`
  preselects it in the picker.
- **Server interoperability oracle.** `unison -socket <port>` from the
  launcher as the server, and an independent Unison 2.54 client (the brew
  formula) syncing `local ↔ socket://localhost:<port>/…` in batch mode: the
  client reports a completed sync, a 300 KB file compares identical, the
  server's stdout carries 0 bytes, and killing the server leaves no GUI
  process. This proves RPC negotiation and transfer through our engine as a
  peer without needing ssh to self.
- Not provable on the development host and recorded as such: the
  no-session rows (a window-server session always exists there), and an
  incoming ssh `-server` from another machine. The socket oracle covers the
  protocol half of the ssh case; the PATH half is documented.
- README and MANUAL: the "remote needs brew unison" requirement becomes "the
  remote needs a `unison` of 2.52 or later, which on a Mac with this app is
  the bundled command".

### PR B: cask

- `binary` stanza only. On a clean machine, `readlink $(which unison)`
  resolves to `…/unison-ui-mac.app/Contents/MacOS/cltool` (the resolved
  target, not just the PATH entry). With the formula linked,
  `brew install --cask` fails with "already a Binary" and
  `ls /Applications/unison-ui-mac.app` shows nothing left behind.

### PR C: detection, Settings, prompt

- Unit tests for the classifier, one per classification per context, using
  fixture directories that build the real layouts (bundle with `Info.plist`,
  Cellar path, dangling links), not string comparisons on invented paths.
- The two PATH contexts are computed from the shell and from `/etc/paths`
  on the test machine and shown separately.
- Install is offered only when both contexts report `none`; Repair only for
  `danglingLauncherPath` and shows the old target; Remove only when the link
  resolves into this bundle.
- Prompt suppression is honored across launches; "Not Now" re-prompts.
- Copy reviewed before the release that ships it.

## Open items

- Opening a command-line profile directly in GUI mode (today it is
  preselected in the picker), and a root pair. Needs picker bypass and a
  decision on what "profile not found" looks like in a GUI.

`unisonNonGuiStartup` silences the progress printer before the text
interface starts, but `uitext.ml` installs its own printer when
synchronization begins (`Uutil.setProgressPrinter showProgress`), so
terminal users do see transfer progress. Not an open item.
