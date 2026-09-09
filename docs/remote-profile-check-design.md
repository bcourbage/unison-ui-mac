# Guided remote-profile check

## Goal

A profile with an `ssh://` root works only if the remote side runs a Unison the
user intends: the right executable, reachable over ssh without interaction,
protocol-compatible with the app's engine. Today the app checks one thing after
the fact (the version-mismatch probe on open) and the manual explains the rest
("Repair and migration"). This feature turns that explanation into a guided
check the user runs from the profile editor: it reports, with wording that
claims only what was observed, what was verified and what was not, and when a
change would help it shows the exact edit and applies it only after approval.

## Non-goals

- Rewriting a profile automatically. Every edit is previewed and approved.
- Running a synchronization. The check observes whether a command line run
  over ssh emits a Unison version line and what that line says; only a real
  sync exercises the server protocol, and the check says so.
- Changing anything on the remote machine.
- Diagnosing PATH on the remote. The check never asks what PATH an ssh command
  receives; it works with absolute paths, which make PATH irrelevant.

## Upstream semantics the check must reproduce (verified in v2.54.0 source)

Read in `bcpierce00/unison` at the vendored commit (`91421d0`, v2.54.0-19).
The check must match these rules or say where it does not.

### Profile file grammar (`src/ubase/prefs.ml`, `readAFile` / `parseLines` / `processLines`)

- A UTF-8 BOM at the start of a file is skipped; a trailing CR is removed.
- Directive detection uses the **untrimmed** line: `Util.startswith theLine
  "include "` (and `source `, `include? `, `source? `). A line with leading
  whitespace before `include` is **not** a directive; it then falls to the
  `key = value` rule and, having no `=`, is fatal ("Garbled line (no '=')").
  The trimmed line is used only to skip empty lines and `#` comments.
- `include f`: read profile `f` with `.prf` appended, fail if missing.
  `source f`: read file `f` literally, fail if missing. `include? f` and
  `source? f`: same, but a missing file is silently skipped. The directive
  line is split into words at spaces; anything but exactly two words is
  "Garbled 'include' directive". Included lines are spliced **in place**.
- Every other line must contain `=`; the text before the first `=` is the
  option name and the text after it the value, both trimmed.
- Unknown option names are **fatal**; command-line-only options (`ui`,
  `server`, `socket`, `version`, `doc`, …) in a profile are **fatal**. The
  check stops at the first such error and reports it in upstream's words
  ("Profile … (file …), line N: `x' is not a valid option"); a profile Unison
  cannot load has no effective settings to report.
- Scalar options (`Prefs.createString`, e.g. `servercmd`, `sshcmd`,
  `sshargs`; `Prefs.createBool`, e.g. `addversionno`) are **set** on each
  occurrence: the **last assignment in spliced order wins**, including
  assignments inside includes. List options (`createStringList`, e.g. `root`,
  `path`, `ignore`) **accumulate** in order.
- File lookup for `include` uses `profilePathname`: the exact name if such a
  file exists in the Unison directory, otherwise the name with `.prf`
  appended. The app's `ProfileRootResolver` already implements this rule.

### Remote command assembly (`src/remote.ml`, `buildShellConnection`, lines 1811 ff.)

The client builds, as separate `execv` arguments after splitting each piece at
spaces with `Util.splitIntoWords` (space is the only separator; a backslash
escapes the next character and is consumed; a trailing lone backslash is
dropped; empty words are dropped):

```
<sshcmd or "ssh">  [-l <user>]  [-p <port>]  <host>  -e none  <sshargs…>  <servercmd or "unison">[-<majorversion>]  -server  __new-rpc-mode
```

- `user` and `port` come from the root (`src/clroot.ml`: `user@` matched by
  `[-_a-zA-Z0-9.%@]+@`, `:port` after the host).
- `servercmd` empty means the bare name `unison`, resolved by the **remote**
  PATH. `addversionno = true` appends `-<major>` (currently `-2.54`) to that
  name before ` -server`.
- `servercmd`, `sshcmd`, `sshargs` and `addversionno` are single, global
  settings. Upstream also refuses the configurations that would need more
  than one: `src/globals.ml` line 58 raises "Wrong number of roots" unless
  exactly two roots are given, and `src/uicommon.ml` lines 1105–1113 count
  every non-local root, `ConnectByShell` (`ssh://` and other shell
  transports) **and** `ConnectBySocket` (`socket://`), and raise "cannot
  synchronize more than one remote root" when that count exceeds one. A
  profile therefore has at most one remote root of any transport, and the
  check stops with upstream's message before any ssh session when either rule
  is violated.

### What the remote shell then sees (OpenSSH behavior)

ssh concatenates every argument after the destination into **one command
string joined by single spaces** and hands it to the remote user's login
shell. Consequences the design must respect:

- Upstream's tokenizer consumes a single backslash, so `My\ Dir/unison` in
  the profile reaches the remote shell as `My Dir/unison -server …` and the
  shell runs `My`. One backslash cannot protect a space through both stages.
- Other encodings can survive both stages under some remote shells, for
  example a doubled backslash or quote characters, which the tokenizer passes
  through in pieces and ssh's single-space join reassembles for the remote
  shell to re-parse. Whether that works depends on the remote login shell,
  and runs of more than one space are lost either way (the tokenizer drops
  empty words). Any shell metacharacter in `servercmd` or `sshargs` is
  interpreted by the remote shell.
- The check does not attempt to reason about those encodings. It
  **verifies the exact remote command string** Unison would send (tokens
  rejoined with single spaces, plus ` -version` in place of
  ` -server __new-rpc-mode`), so whatever the user wrote is what gets tested,
  and it **proposes only paths made of safe characters**
  (`A–Z a–z 0–9 . _ / + -`). A selected executable whose path contains
  whitespace or any other character is not proposed; the check says why and
  suggests a symlink with a plain path on the remote (for example
  `/usr/local/bin/unison`).

### What the app does today, and the divergence to fix

`VersionCheck.buildConfig` runs `ssh -o BatchMode=yes -o ConnectTimeout=5
-o StrictHostKeyChecking=yes <sshargs…> [-p port] -- user@host servercmd
-version`. Differences from upstream: `tokenizeSSHArgs` splits at spaces
**and tabs** with **no** escape handling, unlike `splitIntoWords`; `user@host`
replaces `-l user`; the three `-o` options are added; `-e none` is omitted.
The user-form and `-e none` do not change what the remote runs. The three
options do change what a failure means: `BatchMode=yes` refuses any
interactive authentication that an ordinary sync could satisfy through the
app's credential prompts, `StrictHostKeyChecking=yes` refuses an unknown host
that a sync could accept after a prompt, and `ConnectTimeout` cuts a slow
connection short. A probe failure caused by any of them says that the
connection needed interaction or time the probe does not allow, not that the
sync cannot connect; the wording rules below keep that distinction. The
tokenizer difference is a bug: the check and the probe must share one
`PrefsTokenizer` with upstream's semantics, unit-tested against
`splitIntoWords` cases.

## Design

### Entry point

The check lives in the Profile Editor, Roots section, Remote Connection
group, as a **Check Remote Command…** button beside the **Remote unison**
field. It is enabled when a root is `ssh://`; Step 1 (effective settings and
root rules) runs before any session, and a profile that fails Step 1 shows
that failure under the field and opens no session. The check runs against the
profile as the form currently has it: the form's Remote unison, SSH command,
SSH args and roots, composed with the effective settings from the profile's
includes on disk. No save is required before checking; the user saves after
seeing the result. The profile picker's context menu (**Run**, **Check Remote
Command…**) offers the same command, which opens the profile in the Profile
Editor at that section and starts the check; the picker itself stays a pure
list, so no other management command joins the menu.

A second entry point is a failed connection: when a sync cannot connect to an
ssh root, the restart notice offers **Check Remote Command…** as a third
button, and the reconcile window's summary keeps to a short headline ("Could
not connect to the remote. Unison must be restarted to continue.") whose
**Details** popover holds the full reason, the next step, and the same button.
Both are worded as a diagnostic ("You can check the remote command for this
profile first") without claiming the remote command caused the failure. The offer appears only when the failure happened while connecting
(the coordinator records that the restart was entered from its opening phase)
and the profile's effective roots include an `ssh://` root; a scan or sync
failure, a local-only profile, or a `socket://` root (which runs no ssh
command) makes no offer. It opens the exact profile that failed; if an editor
for it is already open, that window is brought forward and the check runs
against the form as it stands, so unsaved edits survive. An editor open on a
different profile is brought forward and named instead of being replaced.
The check runs its own ssh subprocess, so it works while the engine is in its
restart-required state.

### Step 1: effective settings

Resolve the profile the way Unison will read it, with the grammar above,
recording for every line its file and line number; stop at the first error
Unison would report, and report it in Unison's words. Compute effective
values for `root` (list), `servercmd`, `sshcmd`, `sshargs`, `addversionno`,
with the location of the winning assignment and of every assignment it
overrides. Apply upstream's root rules before anything else: not exactly two
roots stops with "Wrong number of roots"; more than one non-local root,
counting `ssh://` and `socket://` together as upstream does, stops with
"cannot synchronize more than one remote root". If the single remote root is
`socket://`, or there is no remote root, the check does not apply and says
so (it verifies ssh transports only). Parse the one `ssh://` root into user,
host, port and path with the `clroot` rules. Derive the **effective remote
command**: the exact string Unison would send, per the assembly above.

Reuse: `ProfileRootResolver`'s include lookup (`fileInUnisonDir`, exact name
then `.prf`) and its file reader. New: `EffectiveProfile` (values with
provenance; it walks lines itself, because it must keep file and line for
every assignment and report errors in the order `parseLines` finds them,
which `ProfileDocument`'s editing model does not record), `PrefsTokenizer`
(matching `splitIntoWords`, also used by `ProfileDocument` and the version
probe), `UnisonPreferenceCatalog` (the engine's preference table: names,
kinds, command-line-only and pseudo flags, aliases; checked against the built
engine's `-help` in CI), `RemoteCommand` (the assembled string and the `ssh`
argument vector).

### Step 2: discovery (first ssh session)

One non-interactive session to the remote host runs a single POSIX `sh`
command that prints, between unique markers:

- `uname -s`;
- for the effective remote executable, for each well-known candidate
  (`/opt/homebrew/bin/unison`, `/usr/local/bin/unison`,
  `/Applications/unison-ui-mac.app/Contents/SharedSupport/bin/unison`,
  `/Applications/unison-ui-mac.app/Contents/MacOS/cltool`,
  `/Applications/Unison.app/Contents/MacOS/cltool`, `/usr/bin/unison`), and for
  a `unison` in any directory of the non-interactive shell's `PATH` — the same
  environment Unison's own remote `unison` resolves in — that the fixed list
  missed, each reported once: the path, `readlink` of it when it is a symlink
  (the **stored** target, which may be relative or itself a link; reported as
  such), and the first line of `<path> -version`;
- `command -v unison`, labelled as what the discovery script's `sh`
  resolves; the remote login shell (aliases, functions) and Unison's own ssh
  command may each resolve differently.

The session ends there. Nothing is written.

### Step 3: the current command first, then alternatives (no ssh)

After discovery the check verifies the command the profile runs today (Step 4
for the effective command as it is) without asking, in its own ssh session.
That verification runs whether or not discovery enumerated the alternatives, so
one discovered command that hangs on `-version` cannot withhold the current
command's answer; when discovery did not complete, the alternatives are simply
unavailable and the status says so. That result decides what the user sees:

- it started and reported a version this Mac can connect to: the status
  reads **No change needed.**, and a secondary **Choose Another Command…**
  button appears when discovery found other installations;
- it reported a version across the 2.52 boundary: the status says so, and
  the same button lists the alternatives with their reported versions, so
  the ones that pass the version check can be told apart;
- it did not start or did not report a version: the failure sentences are
  shown, and the button offers what discovery found.

When the profile sets no `servercmd`, the remote PATH decides what runs, and
the menu opens by itself once the current command has its answer, so a user
with nothing configured picks without another click; a configured command
gets its answer and the button. Most users get an answer without making a
choice. The menu behind the button
lists **Keep current setting** ("Currently configured for this profile", or
"No command is set for this profile; the remote PATH decides which unison
runs" when Remote unison is empty),
then one row per other installation found, titled by what choosing it means
rather than by a maintenance policy the check cannot see: **Use this
installation directly** ("Uses the program at this location", adding "even if
the link is redirected" when a link to it is also listed) or **Use the command
link** ("Uses whichever installation this link points to; now `<target>`").
Each row shows its full path beneath the title and ends with its reported
version, "cannot connect to this Mac's `<local>`" across the boundary, or "No
version reported". Paths the remote resolves to one executable are grouped
under **Two paths to the same installation**: equivalent today, different
once a link changes. Nothing infers who maintains an installation from its
path, and the check never recommends a change; keeping a verified current
setting is the normal outcome. Choosing a row runs Step 4 for that path and,
on success, fills the Remote unison field with the proposed value under the
composition rules below; applying a proposal moves the check's baseline to the
applied configuration, so a further choice or Save is compared against it rather
than the pre-proposal form. Keep current setting restores the field and Advanced
to what they were when the check started. A help button beside Check Remote
Command… says, in four sentences, when to change the command and what the
check does and does not prove.

Composition rules for a proposed setting, applied before anything is verified:

- The proposed `servercmd` is the selected absolute path, safe characters
  only (else no proposal; the menu entry says why).
- `addversionno`: if the effective value is `true`, Unison will append
  `-<major>`. If the selected path ends with that suffix, the proposal writes
  `servercmd` **without** the suffix and leaves `addversionno` alone; if it
  does not, the proposal also sets `addversionno = false`, shown as a second
  change in the status line. A selection is never double-suffixed, and the
  setting that Unison will run is always the one that was verified.

### Step 4: verification (second ssh session)

The proposed profile is composed in memory, its effective remote command
re-derived exactly as in step 1, and that command string (with ` -version`)
is run on the remote host through the same `ssh` argument vector Unison would
use, plus the non-interactive options. The remote command is prefixed with
`printf '<unique start marker>'; ` so that the marker's presence in stdout
shows that the remote shell ran the `printf`; it says nothing about whether
the executable that follows started. The marker is stripped before the
version line is parsed. The check's `ssh` argument vector is
specified as: `<sshcmd> -o BatchMode=yes -o ConnectTimeout=<t>
-o StrictHostKeyChecking=yes [-l user] [-p port] <host> -e none <sshargs…>
<remote command string>`, that is upstream's order with the three options
inserted first. Outcomes are classified from exit status and stderr with the
probe's existing rules (host key, authentication refused, timeout, connection
refused, remote command not found, version parsed). An edit is offered only
after this step succeeds.

Each check is bound to a **configuration token**: a hash over the form's
roots, Remote unison, SSH command, SSH args and `addversionno` as effective
values; the editor session identifier; and, for every path that took part in
resolution, present or absent, its existence and, when present, identity and
content hash. The paths are the top-level file; for each include directive
both lookup candidates (the exact name and the `.prf` form), the one used and
the one absent; and for each optional directive the absent target. An optional
include that appears, or an exact-name candidate that appears and takes
precedence over an unchanged `.prf`, therefore changes the token. The token is
taken when the check starts. A completion is accepted only after a fresh
Step 1 resolution, run at completion time from the current form values and
the includes on disk, reproduces that token; otherwise the completion is
discarded and logged, no field or result changes, and the status line reads
"Not checked since the last change." Any edit to a field that participates
in the token clears the displayed result the same way.

### Step 5: result wording

Every sentence names an observation. Templates, with what each may and may
not say:

- Connection: "ssh connected to `host` as `user` without prompting." Not
  "with key authentication": batch mode proves only that no prompt was needed.
- Executable: "`<path>` on `host` is a symlink whose stored target is
  `<target>`." / "…is a regular file." Not "resolves to": the check reports
  one stored target, which may be relative or a further link; when the remote
  has `readlink -f` or `realpath`, the fully resolved path is shown as a
  second, separately labelled line.
- Version: "`<remote command>` printed `unison version 2.54.0 (ocaml 5.5.0)`."
- PATH: "This profile does not set `servercmd`, so the remote machine's PATH
  decides which `unison` runs; the check cannot see that PATH."
- Protocol boundary: "2.54.0 (this Mac) and 2.53.5 (`host`) are on the same
  side of the 2.52 boundary." / "…on opposite sides and cannot connect."
- Failures report observations and infer nothing beyond them. The
  observations are: whether the start marker was received, the exit status,
  the first stderr line, whether the deadline expired, and what stdout
  contained after the marker. Each is stated separately; none is turned into
  a claim about an execution stage. Wording:
  - marker not received: "No start marker was received before ssh exited
    (status N, `<first stderr line>`)." or "…before the `<t>`-second deadline."
    followed by "Execution status is unknown." A synchronization may still
    connect if it can answer a prompt; this check cannot. Nothing about the
    executable is claimed either way.
  - marker received, deadline expired: "The remote shell emitted the start
    marker; the `<t>`-second deadline expired. Output received so far:
    `<stdout>`. Whether the executable started is not established."
  - marker received, nonzero exit: "The remote shell emitted the start
    marker; the command line then exited with status N; stderr:
    `<first line>`." For status 127 one sentence is added from step 2's
    record, stated historically: "During discovery no file was found at
    `<path>`." or "During discovery a file was found at `<path>`; status 127
    with this stderr can also mean a dependency of that file is missing." The
    executable's startup is not established by the marker alone, and nothing
    is claimed from the status alone.
  - marker received, exit 0, output not a Unison version line: "The remote
    shell emitted the start marker; the command line printed `<first line>`,
    which is not a Unison version line." What ran remains unverified.
- Closing, by outcome. After a parsed version whose comparison with this
  Mac's version (`VersionCheck.classify`) is not across the 2.52 boundary:
  for the current setting, "No change needed."; for a
  selected candidate, "The command you selected started over ssh and reported
  its version."; both followed by "Only a synchronization confirms the server
  protocol; run the profile to test that." After a parsed version across the
  boundary, the result is "The command started over ssh and reported version
  `<remote>`. `<remote>` (`host`) and `<local>` (this Mac) are on opposite
  sides of the 2.52 boundary and cannot connect." with no proposal applied.
  After any other failure, the failure sentences with "This check did not
  verify the remote command. What it observed is above."
- When the current command did not pass and discovery found other
  installations, the status ends with "Choose Another Command lists the N
  installations found on `host`." For status 127 on a bare command name, the
  failure adds what discovery's `sh` saw: "During discovery, command -v unison
  printed nothing inside sh either." or what it printed, noting that the login
  shell resolved differently.
- Where the sentences appear: the result headline and one status line sit
  directly under the Remote unison field. The observation sentences
  (connection, program found, version, PATH) are grouped under three plain
  labels in a **Details…** popover with **Copy Report**; on a failure the
  popover opens by itself. Details exist only when there is more than the
  status line says; a result whose only extra sentence is the closing shows
  no Details button. Details… and Choose Another Command… sit on their own
  row under the status, and no row may widen the window. No result sentence names which implementation the
  remote runs beyond what the version line printed; the check does not prefer
  this app.

### Step 6: the profile change

The check changes nothing on disk. Selecting a verified, compatible candidate
sets the Remote unison field (and the `addversionno` control when composition
requires) in the open editor; the change is applied by the editor's ordinary
Save under the field semantics of "The Remote unison field" below, and written
by `ProfileSaveTransaction` to the top-level profile only. Included files are
never edited.

Shared-profile disclosure. Before a Save that changes any remote scalar
(`servercmd`, `sshcmd`, `sshargs`, `addversionno`, `clientHostName`), the
editor resolves every other profile in the Unison directory with
`EffectiveProfile` (reads only) and classifies each as a consumer (it includes
the file being saved, directly or transitively), a non-consumer, or could not
be resolved. The scan completes before the decision. Disclosure is shown when
at least one profile is a consumer or could not be resolved:

> These profiles include this file and may be affected: `<name>` (`<host>`),
> `<name>` (`<host>`).
> Could not be resolved: `<name>`.
> [Save Anyway] [Cancel]

Either line is omitted when empty. Hosts come from each consumer's own
effective roots. A save changing no remote scalar shows no disclosure. Cancel
leaves the file untouched. The disclosure is consent, not refusal: the user is
editing a file they own, and the effect on other profiles does not depend on
whether the value was typed or selected from the check's menu.

At Save the app runs a fresh Step 1 resolution, re-derives the effective
remote command from what it is about to write composed with the includes on
disk at that moment, and compares the result with the token of the displayed
check result. A difference sets the status line to "The remote command changed
since it was checked." and Save proceeds; the old result is cleared.

### Cancellation and timeouts

Both ssh sessions reuse the probe executor's contract: a wall-clock deadline
(default 10 s, ConnectTimeout 5 s), cancellation from the UI at any time,
SIGTERM then SIGKILL of the exact child PID with reaping. Blocking work runs
on a GCD queue behind a continuation, never on Swift's cooperative pool.
Include expansion is bounded (depth 16, files 64).

### Concurrent profile edits

The editor's existing rules apply. A check result is attached to the
configuration token that produced it; any edit to a participating field, or a
resolution that no longer reproduces the token, clears the result and sets the
status line to "Not checked since the last change." An in-flight check whose
token no longer matches at completion is discarded. Save behaves as today for
a file changed on disk since it was opened.

### The Remote unison field

Applies to every scalar the form surfaces with a dedicated control (its
`surfacedScalarKeys`: the remote, attribute and option scalars), not only
`servercmd`.

Each surfaced scalar has an effective value and a provenance, computed by
`EffectiveProfile` at load:

- **Default**: no assignment in the top-level file or its includes. The
  control shows Unison's default and is not marked.
- **Local**: the winning assignment is in the top-level file. The control
  shows it unmarked.
- **Inherited**: the winning assignment is in an include. The control shows
  it with the note "From `<file>`, line `<n>`" and the value styled as
  inherited.

Save writes only controls whose value differs from the effective value shown
at load. An unchanged inherited value is never written to the top-level file;
unrelated saves do not materialize overrides. A changed value is written as a
top-level assignment placed so that it wins: an existing top-level line is
rewritten in place when no include after it sets the key, and moved to the
end of the file when one does; an absent line is appended at the end. When a
line is appended or moved to override an include, one comment line precedes
it: "# Overrides <include>: set here so this value takes effect". The comment
is recognized by its exact text and reused on later saves, so repeated saves
do not accumulate comments; comments already attached to a moved line move
with it. Settings the form does not surface are preserved byte for byte,
except changes the user makes through the form's Advanced editor, which are
written as that editor writes them today.

Clearing an inherited value ("use Unison's default") writes an explicit
top-level assignment that reproduces the default, because removing a top-level
line cannot override an include. The written value is Local provenance with
default behavior; the note under the control reads "Set here so Unison's
default applies instead of `<include>`". The assignment is defined per
preference from the upstream defaults at commit `91421d0`:

| Key | Upstream default | Default override written | Basis |
|---|---|---|---|
| `servercmd` | `""` | `servercmd =` | `remote.ml` substitutes `unison` when the value is empty |
| `sshcmd` | `"ssh"` | `sshcmd = ssh` | the value is used as given; empty would not restore `ssh` |
| `sshargs` | `""` | `sshargs =` | empty splits to no words |
| `clientHostName` | computed (local canonical host name) | none: clearing an inherited value is refused with "This app cannot express Unison's default for this setting as a local override. Remove it from `<include>` to use the default; that may affect other profiles that include it." | no literal reproduces a computed default |
| `times`, `owner`, `group`, `dontchmod`, `auto` | `false` | `<key> = false` | `createBool` defaults |
| `log`, `confirmbigdel` | `true` | `<key> = true` | `createBool` defaults |
| `perms` | `0o1777` (1023) | `perms = 1023` | `createInt` default; `int_of_string` accepts decimal |
| `fastcheck`, `rsrc` | `default` | `<key> = default` | `createBoolWithDefault` accepts `default` |
| `logfile` | `"unison.log"` | `logfile = unison.log` | `createString` literal default |
| `prefer`, `force` | `""` | `<key> =` | `recon.ml` `lookupPreferredRoot` uses a nonempty `force`, else a nonempty `prefer`, else none; an empty assignment disables that global preference |

Clearing a Local value with no include setting the key removes the line, as
today. Booleans have no cleared state: the control shows the effective value,
a changed value is written explicitly under the same placement rules, and
their tests exercise explicit changes, not a clear.

The combined conflict control (None / Prefer / Force) writes both keys
together, because upstream gives a nonempty `force` precedence over `prefer`:
selecting Prefer writes `prefer = <root>` and, when an effective `force` is
nonempty, `force =` to neutralize it; selecting Force writes `force = <root>`
and leaves `prefer` as it is (it cannot win); selecting None writes `force =`
and `prefer =` for whichever of the two is effective and nonempty, and removes
Local lines that no include re-sets. This concerns the two global preferences
only; `forcepartial` and `preferpartial` rules are not surfaced and are not
touched.

The duplicate-scalar refusal (SF5) is lifted for surfaced scalars under these
semantics: a duplicated scalar in the top-level file shows the effective
(last) value with the note "This file sets `<key>` more than once; saving a
change keeps the last value and removes the others." An unchanged duplicated
value is left as it is; a changed one is written at the last occurrence with
earlier duplicates removed, as `setValue` does today. The refusal remains for
any other reason the form cannot represent a file, and a Step 1 fatal error
(unknown option, garbled line) disables editing with Unison's message, as the
unreadable-file rule does today.

### macOS 15 compatibility

Foundation `Process`, `Pipe`, `FileManager` and `NSAlert` only; no new
frameworks, entitlements or sandbox changes. Swift 6 language mode as the rest
of the app. The deployment target is unchanged.

## Acceptance criteria (for the implementation PR)

- Tokenizer tests, one per branch of `splitIntoWords`: escape mid-word,
  escaped space kept inside a word, trailing lone backslash dropped, tab not
  a separator, runs of spaces produce no empty words.
- Grammar tests: BOM, CR, comment lines, leading whitespace before `include`
  is a garbled line (fatal), garbled include, all four directive forms with
  present and missing targets, cycle detection, last-assignment-wins across
  an include, list accumulation across an include, unknown option fatal with
  upstream's message, command-line-only option fatal.
- Remote-command tests: the assembled string for `servercmd` set/unset,
  `addversionno` true/false, quoted and escaped values, equals what upstream's
  tokenizer-and-join would produce; the `ssh` argument vector equals this
  document's specification for roots with and without user and port.
- Root-rule tests: a profile with one root, three roots, two `ssh://` roots,
  or one `ssh://` and one `socket://` root stops before any ssh session with
  upstream's exact message ("Wrong number of roots", "cannot synchronize more
  than one remote root"); a profile whose single remote root is `socket://`,
  or that has no remote root, reports that the check does not apply.
- Classification tests distinguish by observation only: marker not received
  with ssh's stderr (batch-mode authentication, host key, connection refused)
  or with the deadline expired, each worded "No start marker was received …
  Execution status is unknown."; marker received with the deadline expired;
  marker received with nonzero exit, including 127 with and without a
  discovery record of a file at the path, each adding only the historical
  "During discovery …" sentence; marker received with exit 0 and an
  unrecognized line. Assertions check that no output contains "could not
  start", "no executable", "the command began", or "a file exists".
- Composition tests: suffix stripping when `addversionno` is true and the
  selection ends in `-<major>`; `addversionno = false` added otherwise; unsafe
  characters produce no proposal.
- Classification tests for every ssh outcome, with recorded stderr fixtures.
- Process cleanup: the executor exposes the child PID; after cancel, `kill -0
  <pid>` fails and `waitpid` has reaped it. No pattern-based `pgrep`.
- Field tests: the Remote unison field shows the effective value when an
  include sets `servercmd` after the top-level line, with the note naming the
  include; saving a changed value appends or moves the top-level line to the
  end with the comment, and a reload shows the effective value equal to the
  saved one. Duplicates before, between and after includes show the effective
  value; unchanged, the file is byte-identical after save; changed, one line
  remains at the effective position with earlier duplicates removed. Every
  row of the default-override table round-trips (inherited value cleared, the
  listed assignment appended after the include with the comment, reload shows
  Local provenance with default behavior and the note); `clientHostName`
  clearing is refused with its note. Inherited-force-to-Prefer writes
  `prefer` and `force =`; inherited-conflict-to-None writes both empties;
  reload shows the selected behavior; `forcepartial`/`preferpartial` lines are
  untouched. Repeated saves of a moved line produce exactly one generated
  comment; a user comment directly above a moved line moves with it. Every
  surfaced scalar participates; unsurfaced keys are byte-identical across
  saves unless edited in the Advanced editor.
- Token tests: a check started for host A completes after the root is changed
  to host B: no field change, no result shown, one log line; the same for each
  participating field, for an optional include created after the check
  started, and for an exact-name file created beside a `.prf` after the check
  started.
- Compatibility: a remote printing `unison version 2.51.5` yields the
  boundary sentence as the result and no proposal; `2.53.7` yields the
  success closing.
- Disclosure tests: a file included by two profiles shows both with their
  hosts before a remote-scalar save; a single potential consumer that cannot
  be resolved triggers the disclosure with only the "Could not be resolved"
  line; a consumer whose own later assignment overrides the saved key is
  still listed; a save changing only a non-remote key shows no disclosure;
  Cancel leaves the file untouched.
- Entry points: the button is enabled only with an `ssh://` root and Step 1
  passing; a Step 1 failure shows under the field with no session; the
  reconcile offer opens the exact profile and preserves an open editor's
  unsaved state.
- Result placement: the success headline, the status line, and the Details
  popover contents for each classified outcome; the popover opens on failure;
  no output contains a sentence naming which implementation the remote runs.
- Live (Demeter): a profile without `servercmd` lists the real candidates with
  stored targets and versions; a profile with `servercmd = /opt/homebrew/bin/unison`
  reports no change to make; selecting a candidate fills the field and Save
  writes it after the includes; a cancelled check leaves its child PID gone.

## Open questions

- Whether the version-mismatch probe on open should reuse this check's
  results; not in the first implementation.
