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

A **Check Remote…** button in the Profile Form's Remote Connection group
(shown only when a root is `ssh://`), and the same command in the profile
picker's context menu. It operates on the **saved** profile file; if the form
has unsaved changes, the check says so and offers to save first.

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

Reuse: `ProfileDocument` for line parsing and `ProfileRootResolver`'s include
lookup. New: `EffectiveProfile` (values with provenance), `PrefsTokenizer`
(matching `splitIntoWords`), `RemoteCommand` (the assembled string and the
`ssh` argument vector).

### Step 2: discovery (first ssh session)

One non-interactive session to the remote host runs a single POSIX `sh`
command that prints, between unique markers:

- `uname -s`;
- for the effective remote executable and for each well-known candidate
  (`/opt/homebrew/bin/unison`, `/usr/local/bin/unison`,
  `/Applications/unison-ui-mac.app/Contents/MacOS/cltool`, `/usr/bin/unison`)
  that exists: the path, `readlink` of it when it is a symlink (the **stored**
  target, which may be relative or itself a link; reported as such), and the
  first line of `<path> -version`;
- `command -v unison`, labelled as what that remote login shell resolves,
  which may differ from what Unison's own ssh command resolves.

The session ends there. Nothing is written.

### Step 3: selection (no ssh)

The user is shown the effective command as Unison would send it and the
discovered candidates with their stored link target and version line, then
selects the intended executable or keeps the current setting. The check never
selects on the user's behalf; with one candidate it still asks.

Composition rules for a proposed setting, applied before anything is verified:

- The proposed `servercmd` is the selected absolute path, safe characters
  only (else no proposal, see above).
- `addversionno`: if the effective value is `true`, Unison will append
  `-<major>`. If the selected path ends with that suffix, the proposal writes
  `servercmd` **without** the suffix and leaves `addversionno` alone; if it
  does not, the proposal also sets `addversionno = false`, as a second
  previewed line under the same provenance rules. A selection is never
  double-suffixed, and the setting that Unison will run is always the one that
  was verified.

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
  Identity by path text only: "That path is inside a `unison-ui-mac.app`
  bundle." / "…is in Homebrew's Cellar." / "…is upstream `Unison.app`'s
  launcher." Labelled "by path"; the remote bundle is not inspected.
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
    marker; no further output arrived within `<t>` seconds. Output so far:
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
- Closing, by outcome: after a parsed version, "The command started over ssh
  and reported its version. Only a synchronization confirms the server
  protocol; run the profile to test that." After any failure, "This check did
  not verify the remote command. What it observed is above."

### Step 6: previewed, approved edits

Offered only after step 4 succeeded. Each edit is a diff of the exact file it
touches, shown before an **Apply** button.

- Before any edit, the check resolves every other profile in the Unison
  directory and finds those that include, directly or through further
  includes, **the file it is about to edit**. The profile being checked can
  itself be an include of another profile. If any other profile consumes the
  target file, the edit is **refused**: the check names those profiles and
  the remote host each of them uses, and leaves the change to the user. The
  edit proceeds only when the target file is consumed by the checked profile
  alone. Two rules make that scan fail closed: a profile that cannot be read
  or resolved (unreadable file, garbled line, missing required include,
  cycle) is **not** a proven non-consumer and is listed as "could not be
  resolved", which refuses the edit like a consumer would; and the scan's
  result is part of the pre-Apply snapshot, so a consumer that appears or
  changes between the check and Apply invalidates the edit.
- `servercmd` (and `addversionno` when composition requires it): if the
  winning assignment is in the top-level profile, replace that line in
  place. If it is in an included file, do **not** edit the include; append
  the override to the top-level profile **after the last directive line**,
  with a comment naming the include it overrides. If a pass-through directive
  follows the insertion point, refuse and explain.
- No line is ever removed; a replaced line is kept as a `#`-prefixed copy
  directly above the new line.
- Nothing else is edited. Writes go through `ProfileSaveTransaction`.

### Cancellation and timeouts

Both ssh sessions reuse the probe executor's contract: a wall-clock deadline
(default 10 s, ConnectTimeout 5 s), cancellation from the UI at any time,
SIGTERM then SIGKILL of the exact child PID with reaping. Blocking work runs
on a GCD queue behind a continuation, never on Swift's cooperative pool.
Include expansion is bounded (depth 16, files 64).

### Concurrent profile edits

When the check starts it snapshots every path that took part in resolution,
**present or absent**: the top-level file; for each directive both lookup
candidates (exact name and `.prf` form), the one used and the one absent;
for optional directives the absent target. Each snapshot records existence,
size, mtime and content hash where present. The snapshot also holds the
consumer scan's result: every profile in the Unison directory with its
content hash and its resolution outcome (consumer, non-consumer, could not be
resolved). Before Apply the check re-reads every snapshotted path, re-runs
the consumer scan, and compares; any difference, including a file that has
appeared or a profile whose consumer status changed, refuses the edit: "the
profile, its includes, or the profiles that share them changed since the
check ran; run it again". The Profile Form disables Save for that profile
while a check runs; one check per profile at a time.

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
- Consumer tests: an edit is refused, naming the consuming profiles and
  their remote hosts, when the target file is included directly or
  transitively by another profile; it proceeds when the checked profile is
  the only consumer; a profile that cannot be read or resolved is listed as
  "could not be resolved" and refuses the edit; a consumer that appears, or
  a profile whose consumer status changes, between the check and Apply
  invalidates the edit.
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
- Edit tests: replace in place; override after the last directive with the
  include's other users named; refusal when a pass-through directive follows;
  refusal on any snapshot difference including a newly present optional
  include; replaced lines kept commented.
- Process cleanup: the executor exposes the child PID; after cancel, `kill -0
  <pid>` fails and `waitpid` has reaped it. No pattern-based `pgrep`.
- Live (Demeter): a profile without `servercmd` lists the real candidates with
  stored targets and versions; a profile with `servercmd = /opt/homebrew/bin/unison`
  verifies; a proposal's diff equals the file after Apply; a cancelled check
  leaves its child PID gone.

## Open questions

- Offering Check Remote from the reconcile window after a connect failure.
- Whether the version-mismatch probe on open should reuse this check's
  results; not in the first implementation.
