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
2. **Outside a bundle.** The tool's real path is known and does not have the
   bundle layout, so it was copied out. `LSCopyApplicationURLsFor
   BundleIdentifier` is asked for our identifier; exactly one registered
   application is required, and it is verified the same way as in step 1.
   Zero or several matches print the candidates to stderr and exit 1. Picking
   one of several would silently run a Debug build next to the installed
   release.
3. **Location unknown.** If the tool cannot determine its own real path
   (`_NSGetExecutablePath` or `realpath` fails, for instance while the bundle
   is being replaced or removed underneath it), it stops with exit 1. Unknown
   is not "known to be copied out", and Launch Services is never consulted
   from this state.

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

**The engine's parser is the classifier.** Only `Uarg` knows which tokens
are options and which are values (`-label -server` is a label) and which
`-ui` wins (the last one given), so no token-level policy can say what a
shell invocation means. The app therefore never interprets Unison options.
It decides one thing itself, *graphical launch or shell launch*, and for a
shell launch hands the engine the caller's tokens unchanged with a single
default in front, `-ui text`, then lets upstream's `unisonNonGuiStartup`
interpret the result exactly as `Main.init` does:

- `-server`, `-socket`, `-version`, `-doc`, `-help`: handled before `-ui` is
  looked at; the process exits. `-server -ui graphic` is a server.
- Effective `-ui text`, which is the default unless the caller's own later
  `-ui graphic` wins (scanCmdLine keeps the last value): the text interface
  runs on the caller's arguments and exits. `unison p`, `unison -batch p`,
  `-label -server -batch p` and `-ui graphic -ui text -batch p` are all text
  runs. Unknown or malformed options get upstream's usage and exit 2;
  `--server` is one of those.
- Effective `-ui graphic`: the callback returns. With a graphical session the
  graphical launch continues with the runtime already up; without one the
  invocation is refused with a message naming `-ui text`.

Consequence, stated plainly: `unison p` typed in Terminal runs the text
interface, which is what the `unison` command does everywhere. There is no
"refuse a bare profile" rule and no tty probe; nothing is ever dropped,
edited or reordered.

**Graphical launch or shell launch** is decided by `CommandLineInvocationPolicy.launchKind`
from three facts, in order:

- *test host* (XCTest or `UNISON_UI_SMOKE`): graphical. Both must reach
  `applicationDidFinishLaunching`, where `UNISON` is redirected, before the
  runtime starts.
- *launcher marker*: `cltool` sets `UNISON_UI_MAC_LAUNCHER=1` in the
  environment of the process it execs; `main.swift` reads and removes it so
  nothing the app spawns inherits it. Present means shell. It identifies the
  launch path, not a security boundary.
- otherwise: shell if there is no window-server session (nothing graphical
  can run), or if any argument other than host-injected flags is present
  (a direct invocation of the bundle executable with arguments, so
  `servercmd` pointing at the executable keeps working); graphical if only
  host-injected flags remain (Finder, `open`, Xcode). Host-injected flags
  (`-NS…`/`-Apple…` with a following non-option value, `-psn_…`) are only
  ignored for this decision, never removed from argv.

**Shell launch.** `[argv0, "-ui", "text"] + caller's tokens` is handed to
`caml_startup` and `unisonNonGuiStartup` is invoked on the OCaml thread
(`unison_bridge_cli_startup`). It exits the process for every role but the
graphical one. If it returns, the effective interface is graphical:
`main.swift` checks for a window-server session, refuses with exit 1 without
one, and otherwise continues into the normal graphical path with the runtime
already started. The existing `unison_bridge_startup` guard makes the later
startup call a no-op. This is the one shell path that reaches Sparkle and the
menu; the headless roles never do.

A bare `unison` over ssh therefore runs the text interface with no
arguments, which like upstream's `unison` uses the `default` profile if one
exists and prints usage otherwise. AppKit is never attempted without a
session.

**After init0 on the graphical continuation** (`unison -ui graphic …` with a
session), upstream's `unisonInit0` has extracted any profile or roots from
argv and already verified that a named profile's file exists (`name` or
`name.prf`). Roots: the engine is asked through `areRootsSet`, which answers
yes, no, or *undetermined* (callback missing or raised); yes and undetermined
both stop with a stderr message and exit 1, because undetermined is not
"no". A profile: upstream's `profilePathname s` opens the file named exactly
`s` if it exists and `s.prf` otherwise, and the picker hands the engine its
row name (the `.prf` file's name without the extension), which the engine
resolves by the same rule. So the given string is turned into a picker name
only when both resolve to the same file (`CommandLineProfileHandoff`): with
`p` and `p.prf` both present, `p.prf` given would become picker `p`, which
opens the extensionless `p`; that case stops with a message naming both
files. The resulting name is then checked against the list the picker will
actually show, with the user's hide preferences applied; only then is it
preselected. A profile the picker does not list (hidden) stops with a message
saying so, because the picker falls back to another row for a name it cannot
find, which would select the wrong profile silently. Opening the profile
directly is a follow-up.

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
contexts**, both shown, and both labelled as what they are: reconstructions
of a PATH, not measurements taken inside those execution contexts.

- *Login shell*: the PATH a non-interactive login shell builds, obtained by
  running `$SHELL -l -c 'printf %s "$PATH"'`. This reads `/etc/zprofile` and
  `~/.zprofile` but not `~/.zshrc`, so a PATH change made only in `.zshrc`
  is not seen. The label says "as a login shell sees it".
- *Remote command*: sshd's default PATH, `/usr/bin:/bin:/usr/sbin:/sbin`.
  An ssh command runs `$SHELL -c`, which reads neither `/etc/zprofile` (so
  `path_helper` and `/etc/paths` never apply) nor `~/.zshrc`; only
  `~/.zshenv` or `/etc/zshenv` could add to it, and the panel notes when one
  exists rather than evaluating it. Measured on a macOS 26 host: `ssh host
  'echo $PATH'` prints exactly the default. Neither `/usr/local/bin` nor a
  Homebrew prefix is on it, whatever created the link, so `servercmd` is the
  answer for every remote peer of a Mac, not a fallback. (An earlier revision
  of this document claimed `/etc/paths` applied and put `/usr/local/bin` on
  this PATH; the measurement contradicted it.)

For each context two things are found: the first PATH entry holding a
`unison` **entry** of any kind (a file or a symlink, dangling included), and
the first entry that **executes** (what `command -v` would pick, which skips
dangling links). When they differ, both are shown, because a dangling link
ahead of a working command means Repair would change which command runs.
The first entry is classified:

| Classification | Evidence |
|---|---|
| `thisInstallation` | Resolves to `cltool` inside the bundle this process is running from (path equality with `Bundle.main.bundlePath` after resolving symlinks) |
| `otherCopyOfThisApp` | Resolves to `cltool` inside a different bundle whose `Info.plist` identifier is ours (a Debug build, a second copy). Same product, not this installation. |
| `homebrewManaged` | `thisInstallation` or `otherCopyOfThisApp`, the link lives under `$(brew --prefix)/bin`, **and** the Caskroom holds an install receipt for `unison-ui-mac`. Location alone is not ownership. |
| `brewFormula` | Resolves into the Homebrew Cellar |
| `upstreamApp` | Resolves into a bundle with identifier `edu.upenn.cis.Unison` |
| `danglingLauncherPath` | Broken link whose target path ends in `/unison-ui-mac.app/Contents/MacOS/cltool`. A pathname, not proof of ownership; it identifies what the link *was for*. |
| `danglingOther` | Broken link pointing anywhere else |
| `other` | Anything else, path shown |
| `none` | No entry in that context |

**Settings, Command Line Tool section.** Shows both contexts, the
classification and the resolved path in words. Actions are offered from the
login-shell result and are gated by what the evidence proves:

- `none` in both contexts: **Install** creates `/usr/local/bin/unison` as a
  symlink to this installation's tool. One administrator prompt. If either
  context already shows an entry, Install is withheld and the entry shown.
- `danglingLauncherPath`: **Repair** replaces the broken link with one to
  this installation. The confirmation shows the old target path and, when a
  later PATH entry currently executes, names that command and says Repair
  will take precedence over it. Nothing that resolves is ever replaced.
- `thisInstallation` (not `homebrewManaged`): **Remove** deletes the link.
- `otherCopyOfThisApp`: read-only, with the other bundle's path. A second
  copy must not remove the installed release's link.
- `homebrewManaged`: read-only, "Managed by Homebrew".
- Every other state: read-only, with the path shown.

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
> Adds a `unison` command in /usr/local/bin that runs this app's copy of
> Unison, so `unison -ui graphic` opens this app and `unison -server` from a
> remote machine uses it, wherever /usr/local/bin comes first on the PATH.
> Requires an administrator password.
> [ ] Do not ask again
> **Install**   Not Now

## Scenario matrix

| Scenario | Result | Notes |
|---|---|---|
| Brew formula only | Unchanged. Text UI; `-ui graphic` ignored. | Not this app's concern. |
| Brew formula linked, then this cask | Cask install fails at the `binary` artifact ("already a Binary at …"); brew rolls back the app it had placed. | User chooses `brew unlink unison`, or the zip. |
| Brew formula plus this app from the zip | Both work. `unison` is the formula's CLI; the app runs from the picker. Install is offered only if nothing owns the name, so it is not offered here. | The supported way to keep the formula's CLI. |
| This app via cask | `unison -ui graphic` opens the app; `unison -ui text` runs in the terminal; `brew uninstall --cask` removes both. | The incoming-ssh PATH is sshd's default and lacks the brew prefix on every architecture; peers set `servercmd = <prefix>/bin/unison`. |
| This app via zip | Nothing on PATH until Install. | First-launch prompt or Settings. Link lands in `/usr/local/bin`, which is on a login shell's PATH but not on the incoming-ssh PATH, so peers set `servercmd = /usr/local/bin/unison`. Settings shows reconstructed PATHs for two contexts and says so; a `.zshrc` or `.zshenv` change can still pick another `unison`, and the prompt's copy promises only what the link does, not what every shell will resolve. |
| Fresh install, first run over ssh | Gatekeeper's first-launch assessment of a quarantined app needs a GUI session; over ssh the exec may be refused. Homebrew quarantines cask downloads too (`cask/download.rb`). | Manual: launch the app once from Finder before relying on ssh, whatever the install method. |
| Sparkle update | Link stays valid; bundled tool updates too. | The headless roles exit before Sparkle initializes; the `-ui graphic` continuation reaches Sparkle like any graphical launch. |
| Bare `unison` over ssh, with a `default.prf` present | The text interface runs the default profile, as upstream's `unison` would. | Upstream semantics, stated as such. Not "prints usage". |
| Script started from Terminal, `unison -batch p`, stdin inherited | Text UI. | No tty probe exists; the default applies. |
| Dangling launcher link ahead of a working formula on PATH | Settings shows both the first entry and the executing one; Repair's confirmation says which command it displaces. | PR C. |
| Second copy of the app (Debug build) opens Settings | The installed release's link classifies as `otherCopyOfThisApp`; Remove is not offered. | PR C. |
| Sparkle replaces the bundle while a `-server` process runs | The running process keeps its mapped binary; new invocations resolve the new bundle. The old bundle is moved aside, so a link stays valid. | Same as any in-place app update with a running helper. |
| Brew `upgrade --greedy` after Sparkle | Can downgrade to the tap's version. A downgrade to a pre-launcher cask version removes brew's link; a manual link dangles. | Release checklist already bumps the cask with each release; Settings reports the dangling case. |
| Mac that is both GUI user and ssh target | One binary serves both. | File access over ssh follows sshd's Full Disk Access grant, unchanged. |
| `unison -batch p` from cron, ssh, a daemon, or a LaunchAgent in a GUI session | Text UI: the `-ui text` default applies. | Upstream's Mac app opens a GUI here and fails headless. |
| Person in Terminal: `unison p` or two roots | Text UI, exactly as the `unison` command behaves everywhere. | No refusal rule; nothing to drop. |
| Person in Terminal: `unison -bogus` | Upstream's unknown-option usage, exit 2. | The engine reports it, not the app. |
| `unison -label -server -batch p` | Text sync with the label "-server". | Only the parser knows `-server` is a value; the app never decides. |
| `unison -ui graphic -ui text -batch p` | Text sync. | Last `-ui` wins in upstream's scanner. |
| `unison -server -ui graphic` | Server. | `Main.init` handles `-server` before `-ui`. |
| `-ui=text` | Recognized as an engine option. | `Uarg` splits at `=`. |
| `--server`, `--ui text` | Upstream's unknown-option usage, exit 2: it registers single-dash names and matches exactly. | The manual says so. |
| XCTest or smoke host, any arguments | GUI path, argv[0] only. | `UNISON` redirection in `applicationDidFinishLaunching` precedes the runtime start, as today. |
| Xcode scheme runs `-ui graphic` with `-NSDocumentRevisionsDebugMode YES` | Command-line mode; the host flag reaches the engine intact and upstream's parser reports it with usage, exit 2. | Nothing is removed from argv, because the policy cannot know option-value boundaries. |
| `unison -ui text -label -NSFoo p` | Passed through intact; `-NSFoo` is the label's value and Unison treats it as such. | Same reason. |
| Two copies of the app installed | Through a link, the link's bundle wins after identity verification. A copied-out tool fails closed on two Launch Services matches. | |
| Damaged bundle (executable missing, or foreign `Info.plist`) | Launcher exits 1 naming the damage; never runs another copy. | |
| App moved after linking | `danglingLauncherPath`, Repair offered with the old path shown. | Cask installs are immune. |
| App deleted, link left behind | `danglingLauncherPath` on reinstall, otherwise "command not found". | Manual uninstall doc removes the link. |
| Upstream `Unison.app` also present | Both coexist. Its launcher looks up its own bundle id. | Only the filename `unison` is contested; Settings shows who owns it in each context. |
| `addversionno` on a peer | Peer invokes `unison-2.54`. | Manual note: second link under that name. |

## Acceptance criteria

Each gate is named for what it proves. None of them proves notarization or
Gatekeeper acceptance of the shipped bundle. The release pipeline signs with
a Developer ID and notarizes, but its macOS 15 smoke runs the *unsigned*
build artifact before that step, so **no automated gate exercises a
quarantined, notarized download**; that check is manual, in the release
checklist (install the published zip on a clean Mac, launch from Finder,
then run `unison -version` through the link). `sign-app.sh` and its
structural test do not stand in for it.

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
- Unit tests for the launch-kind decision (marker, test host, no session,
  direct invocation with arguments, Finder/Xcode/XCTest host flags, a host
  flag followed by an option) and for the engine argv (`-ui text` prepended,
  everything else byte-identical, including `-label -server -batch p` and a
  caller's own later `-ui graphic`). These prove what is handed over; what
  the engine does with it is upstream's behavior and is exercised against the
  real bundle by the smoke and the live checks below, never asserted by name
  in a unit test.
- Live, against the built bundle through the launcher: `-label -server
  -batch p` performs a text sync (the label is "-server"); `-ui graphic -ui
  text -batch p` performs a text sync (last `-ui` wins); `-server -ui
  graphic` runs the server role (exits on EOF, no window); `-batch p` under a
  real pseudo-terminal performs a text sync (no refusal); `-NSDocument
  RevisionsDebugMode YES -ui graphic` and `--server` get upstream's
  unknown-option usage, exit 2; `-ui graphic p` opens the GUI.
- **`scripts/smoke-cli.sh` against the built bundle** (`make smoke-cli`
  locally; the release pipeline runs it on the macOS 15 runner against the
  exact release bytes, where XCTest and `UNISON_UI_SMOKE` deliberately take
  the graphical branch and prove nothing about this path). Through a PATH
  symlink with `UNISON` in a throwaway directory: `-version` prints exactly
  one version line on stdout with empty stderr and exit 0; **the stdin/stdout
  transport oracle**: the app in text mode as client and the same bundle as
  server, reached through an ssh stand-in that execs the launcher with the
  exact remote command upstream sends (`unison -server __new-rpc-mode`),
  syncs a 200 KB file and a nested file byte-identical with exit 0; `-bogus`
  headless reaches the engine's parser (exit 2); `-server </dev/null` exits
  on its own within 30 s. The last is a liveness check only: upstream sends
  the header first but flushes asynchronously, so 0 bytes on immediate EOF is
  consistent with a working server and proves nothing about the handshake.
  The transport oracle is what proves the handshake.
- Also measured live on the development host, independent 2.54.0 client
  (the brew formula): the same stdin/stdout transport, and `-socket` mode
  over TCP, both sync byte-identical. Recorded in the PR body.
- `unison -help` prints usage, exit 2 (upstream's code). `unison -ui text
  NoSuchProfile` fails with usage. `unison NoSuchProfile` in Terminal is
  refused. `unison -ui graphic NoSuchProfile` fails with upstream's
  "Profile … does not exist" (proves the full argv reached OCaml). `unison -ui
  graphic` brings the GUI up; `unison -ui graphic <profile>` preselects it in
  the picker; a hidden profile is refused with a message.
- Not provable on the development host and recorded as such: the no-session
  rows (a window-server session always exists there), and an incoming ssh
  `-server` from another machine. The transport oracle covers the protocol
  half of the ssh case; the PATH half is documented.
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
