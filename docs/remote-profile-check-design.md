# Guided remote-profile check

## Goal

A profile with an `ssh://` root works only if the remote side runs a Unison the
user intends: the right executable, reachable over ssh without interaction,
protocol-compatible with the app's engine. Today the app checks one thing after
the fact (the version-mismatch probe on open) and the manual explains the rest
("Repair and migration"). This feature turns that explanation into a guided
check the user runs from the profile editor: it reports, with precise wording,
what was verified and what was not, and when a change would help it shows the
exact edit and applies it only after approval.

## Non-goals

- Rewriting a profile automatically. Every edit is previewed and approved.
- Running a synchronization. The check proves reachability and executable
  startup; only a real sync proves the server protocol, and the check says so.
- Changing anything on the remote machine.
- Diagnosing PATH on the remote. The check never asks what PATH an ssh command
  receives; it works with absolute paths, which make PATH irrelevant.

## Upstream semantics the check must reproduce (verified in v2.54.0 source)

Everything below was read in `bcpierce00/unison` at the vendored commit
(`91421d0`, v2.54.0-19). The check must match these rules or say where it
does not.

### Profile file grammar (`src/ubase/prefs.ml`, `readAFile` / `parseLines` / `processLines`)

- A UTF-8 BOM at the start of a file is skipped; a trailing CR is removed.
- Each line is trimmed. Empty lines and lines whose first non-blank character
  is `#` are ignored.
- `include f`: read profile `f` with `.prf` appended, fail if missing.
  `source f`: read file `f` literally, fail if missing. `include? f` and
  `source? f`: same, but a missing file is silently skipped. The directive line
  is split into words at spaces; anything but exactly two words is
  "Garbled 'include' directive". Included lines are spliced **in place**.
- Every other line must contain `=`; the text before the first `=` is the
  option name and the text after it the value, both trimmed. No `=` is
  "Garbled line (no '=')".
- Unknown option names are fatal. Command-line-only options (`ui`, `server`,
  `socket`, `version`, `doc`, …) in a profile are fatal.
- Scalar options (`Prefs.createString`, e.g. `servercmd`, `sshcmd`,
  `sshargs`) are **set** on each occurrence: the **last assignment in
  spliced order wins**, including assignments inside includes. List options
  (`createStringList`, e.g. `root`, `path`, `ignore`) **accumulate** in order.
- File lookup for `include` uses `profilePathname`: the exact name if such a
  file exists in the Unison directory, otherwise the name with `.prf`
  appended. The app's `ProfileRootResolver` already implements this rule for
  roots and is the reuse point.

### Remote command assembly (`src/remote.ml`, `buildShellConnection`, lines 1811 ff.)

The client runs, as separate `execv` arguments after splitting each piece at
spaces with `Util.splitIntoWords` (backslash escapes the next character; only
the space character separates; tabs do not):

```
<sshcmd or "ssh">  [-l <user>]  [-p <port>]  <host>  -e none  <sshargs…>  <servercmd or "unison">[-<majorversion>] -server __new-rpc-mode
```

- `user` and `port` come from the root (`src/clroot.ml`: `user@` matched by
  `[-_a-zA-Z0-9.%@]+@`, `:port` after the host).
- `servercmd` empty means the bare name `unison`, resolved by the **remote**
  PATH. `addversionno = true` appends `-2.54` to that name.
- `sshargs` and `servercmd` are split at unescaped spaces. A path containing a
  space must be written `My\ Dir/unison` in the profile; the check must warn
  when a value contains an unescaped space and must apply the same escaping
  when it proposes a path.
- Upstream passes the host bare and the user as `-l user`; it does not set
  `BatchMode`, `ConnectTimeout` or `StrictHostKeyChecking`.

### What the app does today, and the divergences to fix

`VersionCheck.buildConfig` runs `ssh -o BatchMode=yes -o ConnectTimeout=5
-o StrictHostKeyChecking=yes <sshargs…> [-p port] -- user@host servercmd
-version`. Differences from upstream: (a) `tokenizeSSHArgs` splits at spaces
**and tabs** with **no** escape handling, so `\ ` in `sshargs` is treated
differently from Unison; (b) `user@host` instead of `-l user`; (c) the extra
`-o` options; (d) no `-e none`. (b) and (c) are deliberate and harmless for a
probe; (d) is irrelevant to a non-interactive command. (a) is a bug shared
with this design: the check and the probe must use one tokenizer with
upstream's semantics (space-only, backslash escape, trailing lone backslash
ignored), unit-tested against `splitIntoWords` cases.

## Design

### Entry point

A **Check Remote…** button in the Profile Form's Remote Connection group
(shown only when a root is `ssh://`), and the same command in the profile
picker's context menu. It operates on the **saved** profile file; if the form
has unsaved changes, the check says so and offers to save first.

### Step 1: effective settings

Resolve the profile the way Unison will read it:

- Expand `include`/`source`/`include?`/`source?` recursively with the grammar
  above, recording for every line its file and line number. Detect cycles
  (fatal, reported with the chain) and missing required files (fatal,
  reported like upstream's "Included from …, line N").
- Compute effective values: `root` (list, expect exactly two), `servercmd`,
  `sshcmd`, `sshargs`, `addversionno`, plus the location (file, line) of the
  **winning** assignment for each scalar and of every earlier assignment it
  overrides. Report unknown option names as upstream would, without stopping
  the check.
- Parse each `ssh://` root into user, host, port, path with the `clroot`
  rules. Two remote roots are supported (each checked); zero means the check
  does not apply.

Reuse: `ProfileDocument` for line parsing, `ProfileRootResolver`'s include
lookup. New: an `EffectiveProfile` type carrying values with provenance, and a
`PrefsTokenizer` matching `splitIntoWords`.

### Step 2: the intended remote executable

The check distinguishes what the profile **will run** from what the user
**intends**:

- If `servercmd` is set, the candidate is that value (with `-<major>` appended
  when `addversionno` is true). If it contains an unescaped space, stop with a
  precise message; propose the escaped form as an edit.
- If `servercmd` is empty, the profile relies on the remote PATH. The check
  says so and, over the same ssh session as step 3, asks the remote for
  candidates without depending on PATH itself:
  `for p in /opt/homebrew/bin/unison /usr/local/bin/unison
  /Applications/unison-ui-mac.app/Contents/MacOS/cltool /usr/bin/unison; do
  [ -e "$p" ] && printf '%s\n' "$p"; done; command -v unison`. The user then
  selects the intended one from a list that shows, per candidate, what it
  resolves to (`readlink`) and what `-version` prints.
- The selected executable becomes the proposed `servercmd`, absolute, escaped.
  The check never selects on the user's behalf; with one candidate it still
  shows it and asks.

### Step 3: ssh verification

Run, with the shared tokenizer and upstream's argument order plus the probe's
non-interactive options: `sshcmd -o BatchMode=yes -o ConnectTimeout=<t>
-o StrictHostKeyChecking=yes [-l user] [-p port] <sshargs…> host` and a single
remote command that prints, separated by unique markers: `uname -s`,
`readlink <candidate>` (or the literal path when not a link), and
`<candidate> -version`. One session, one round trip, no shell state assumed
beyond POSIX `sh`.

Outcomes are classified from exit status and stderr as the version probe
already does (host key, authentication, timeout, connection refused, remote
command not found, version parsed), and each is worded as a fact about what
happened.

### Step 4: result wording

Every sentence names what was checked and its outcome; nothing is inferred.
Templates:

- "Connected to `host` as `user` with key authentication." / "Could not
  connect: ssh reported `<first stderr line>`." / "The host key is not in
  `known_hosts`; connect once from Terminal to accept it, then check again."
- "`/opt/homebrew/bin/unison` on `host` resolves to
  `/Applications/unison-ui-mac.app/Contents/MacOS/cltool` and reports
  `unison version 2.54.0 (ocaml 5.5.0)`." The classification of that target
  (this app, Homebrew formula, upstream Unison.app, other) reuses
  `CommandLineToolStatus`'s rules applied to the remote path text and is
  labelled "by path" since the remote bundle is not inspected.
- "This profile does not set `servercmd`, so the remote machine's PATH
  decides which `unison` runs; that PATH is not something this check can see."
- "Versions 2.54.0 (this Mac) and 2.53.5 (`host`) are on the same side of the
  2.52 protocol boundary." / "…are on opposite sides and cannot connect."
- Always, last: "This check confirms the executable starts over ssh. Only a
  synchronization confirms the server protocol; run the profile to test that."

### Step 5: previewed, approved edits

Edits are offered only when the check found something to change and the
target is verified (step 3 succeeded for it). Each edit is shown as a diff of
the exact file it touches, with the line it adds or replaces, before an
**Apply** button. Rules that preserve working configurations:

- Setting `servercmd`: if the winning assignment is in the top-level profile,
  replace that line in place. If it is in an included file, do **not** edit
  the include (it may serve other profiles; the check names them by scanning
  the Unison directory for profiles that include it); instead append
  `servercmd = <path>` to the top-level profile **after the last include
  directive**, with a comment naming the include it overrides, and show that
  this is an override by position. If the top-level file ends inside a
  construct the editor does not manage (pass-through directives after the
  point of insertion), refuse and explain.
- Escaping `servercmd`/`sshargs` spaces: replace the value with the escaped
  form, in place, same provenance rules.
- Nothing else is ever edited. No line is removed; replaced lines are kept as
  a `#`-prefixed copy directly above the new line so the previous value is
  visible in the file.
- Writes go through `ProfileSaveTransaction` (atomic temp-file-and-rename in
  the profile directory).

### Cancellation and timeouts

The ssh step reuses the probe executor's contract: a wall-clock deadline
(default 10 s, ConnectTimeout 5 s), cancellation from the UI at any time,
SIGTERM then SIGKILL with reaping so no ssh child outlives the check. Blocking
work runs on a GCD queue behind a continuation, never on Swift's cooperative
pool (the lesson recorded in `CommandLineToolStatus.currentStatusAsync`).
Include expansion is bounded (depth 16, files 64) so a pathological profile
cannot hang the check.

### Concurrent profile edits

The check snapshots the top-level file and every included file (path, size,
mtime, content hash) when it starts. Before applying an edit it re-reads and
compares; any difference, including a Profile Form save or an external editor,
refuses the edit with "the profile changed since the check ran; run it again".
The Profile Form is told a check is in progress so it disables Save for that
profile until the check finishes or is cancelled. Two checks on the same
profile cannot run at once.

### macOS 15 compatibility

Foundation `Process`, `Pipe`, `FileManager` and `NSAlert` only; no new
frameworks, entitlements or sandbox changes. Swift 6 language mode as the rest
of the app. Nothing here raises the deployment target.

## Acceptance criteria (for the implementation PR)

- Tokenizer tests: one case per branch of `splitIntoWords` (escape mid-word,
  trailing lone backslash, tabs not separating, multiple spaces).
- Grammar tests: BOM, CR, comment lines, garbled include, garbled line, all
  four directive forms with present and missing targets, cycle detection,
  last-assignment-wins across an include, list accumulation across an
  include, unknown option reported with file and line.
- Assembly test: the argument vector the check runs equals upstream's
  assembly with the three probe options inserted before `-l`, for roots with
  and without user and port, and with escaped spaces in `sshargs`.
- Classification tests for every ssh outcome, using the recorded stderr
  fixtures the version probe already has.
- Edit tests: replace-in-place, override-after-last-include with comment,
  refusal when the winning assignment is in an include shared by another
  profile unless approved, refusal on a concurrent change, escaping proposal.
- Live: against Demeter, a profile with `servercmd` unset selects among the
  real candidates; a profile with `servercmd = /opt/homebrew/bin/unison`
  reports its resolution and version; the proposed edit's diff matches the
  file after Apply; a cancelled check leaves no ssh process (`pgrep -f
  "ssh .*demeter"`).

## Open questions

- Whether to offer Check Remote from the reconcile window after a connect
  failure (probably yes, later).
- How much of the version-mismatch probe on open should be replaced by this
  check's results cache; not in the first implementation.
