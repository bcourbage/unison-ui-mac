# Engine prototype: session options via a command-line parser extension: evidence report

**Status:** Feasibility evidence for [`docs/cli-session-requests-design.md`](cli-session-requests-design.md).
**Patch under review:** [`docs/spikes/cli-session-parser.patch`](spikes/cli-session-parser.patch).
**Reference prototype (unpatched parser):** [`docs/spikes/cli-session-parser-reference.ml`](spikes/cli-session-parser-reference.ml).
**Variant prototype (patched parser):** [`docs/spikes/cli-session-parser-variant.ml`](spikes/cli-session-parser-variant.ml).
**Reproduce:** [`docs/spikes/run-cli-session-parser-prototype.sh`](spikes/run-cli-session-parser-prototype.sh).
**Companion:** the `Prefs.loadStrings` adapter half is in
[`docs/cli-session-prefs-prototype-report.md`](cli-session-prefs-prototype-report.md).

## Verdict

This half evaluates a **small, backward-compatible extension of the engine's own
command-line parser** that accepts an explicit per-session argument vector and
**raises instead of exiting**. Measured against an **independent, unpatched
upstream reference**:

- On the same option words, the variant's `Prefs.parseCmdLineArgs` produces the
  **same preference state** as unmodified upstream `Prefs.parseCmdLine`, across
  scalar, boolean, alias, `BOOLDEF`, `-path` (`CUSTOM`), repeated `-path`,
  whitespace, and CLI-plus-profile precedence.
- The refactor to the shared parsing loop leaves the historical parser's
  observable behavior unchanged: on unknown, missing, malformed, and `-help`
  input, the refactored `parse` produces the **same exit status, stdout, and
  stderr** as the unpatched `parse`.
- On invalid input the variant **raises `Util.Fatal`** rather than exiting; the
  option preceding the failure is shown to have taken effect, and the next
  session is clean.

So the parser variant carries exactly the cases the `loadStrings`-only adapter
could not (`-path`/`CUSTOM` and whitespace), and does so with upstream-faithful
parsing. Its cost is different, not zero: it is a **vendored engine source
patch** to carry across upstream bumps, and it still needs the **same lifecycle
call site** the adapter needed (after profile load, before connect). Both facts
are detailed below.

## The change

The patch touches four files (the full diff is
[`docs/spikes/cli-session-parser.patch`](spikes/cli-session-parser.patch)):

```
 src/ubase/prefs.ml  | 28 ++++++
 src/ubase/prefs.mli |  9 +++
 src/ubase/uarg.ml   | 82 ++++++++++++++------------
 src/ubase/uarg.mli  | 11 +++
 4 files changed, 109 insertions(+), 21 deletions(-)
```

- `Uarg`: the parsing loop is factored out of `parse` into a shared `parseCore`
  that **raises `ParseError`** rather than printing usage and exiting. `parse`
  keeps its former behavior by catching `ParseError` and doing the old
  print-and-exit. A new `parseArgv args speclist anonfun` parses an explicit
  vector, raises `Uarg.Bad` on error, and saves and restores `Uarg.current` so a
  session parse does not disturb the shared `Sys.argv` position.
- `Prefs`: `parseCmdLineArgs usage args` is the session-request counterpart of
  `parseCmdLine`. It drives `Uarg.parseArgv` through the same `argspecs`, and
  funnels both `IllegalValue` and `Uarg.Bad` into a single catchable
  `Util.Fatal`.

`Uarg.parse` and `Prefs.parseCmdLine` are additive-only at the API level and,
by the measurement in section 2 below, unchanged in observable behavior. The
existing text UI and server entry points are unaffected.

## Reproducing it, and how the comparison avoids self-confirmation

An earlier version of this spike compared `parseCmdLine` against
`parseCmdLineArgs` **inside a single patched binary**. That only shows two paths
through the same patched `parseCore` agree; a shared regression would pass both.
This version builds an **independent unpatched reference** and compares across
binaries.

One committed script does everything, with no effect on the caller's working
tree:

```sh
UNISON_SRC=/path/to/unison/src docs/spikes/run-cli-session-parser-prototype.sh
```

- It pins the **documented vendored revision** the app ships (`91421d0`,
  `v2.54.0-19-g91421d0`, from `vendor/README.md`), not a newer upstream, and
  **fails** if the OCaml compiler is not the pinned `5.5.0` the vendored blob is
  ABI-locked to, rather than proceeding with a warning.
- It creates **two disposable `git worktree`s** at that revision, one pristine
  and one with the patch applied, builds each engine entirely inside its own
  worktree on the repository's own OCaml path (`unison/src/Makefile.OCaml`, the
  same path `make vendor-blob` uses; no `opam`/`dune`), and **removes both
  worktrees** at the end and on any error, reporting any cleanup failure rather
  than ignoring it.
- It builds **three binaries**: the reference from the pristine worktree (the
  unmodified upstream parser), the reference again from the patched worktree (the
  refactored `parse`), and the variant from the patched worktree (the new
  `parseCmdLineArgs`). Both reference binaries share the program name so
  upstream's error messages carry an identical program-name token.

Section 1 compares the patched variant against the **pristine** reference. Its
comparison is guarded: a case counts only if **both processes exit 0** and each
prints a **state record** (a `path=` line); the guard itself is unit-tested in
section 0 to prove it rejects a nonzero exit, an empty or record-less output, and
a mismatch, so two failing runs cannot pass as agreement. Section 2 compares the
two reference binaries (refactored vs unmodified `parse`): each case requires
**exit 2** and a **case-specific diagnostic**, and compares the **complete
stdout and stderr streams** as files (not through command substitution, which
would drop trailing newlines). Because `parseCmdLine` reads a fixed `Sys.argv`,
each argument vector is exercised in its own process.

## Result (verbatim run)

```
### 0. Guard self-test (prove the successful-parse check rejects false passes)
  PASS  self-test: reference process failed -> fail
  PASS  self-test: variant process failed -> fail
  PASS  self-test: exit 0 but empty output -> fail
  PASS  self-test: exit 0 but no state record -> fail
  PASS  self-test: state mismatch -> fail
  PASS  self-test: clean match passes -> pass

### 1. Successful parses: variant (patched parseCmdLineArgs) vs INDEPENDENT
###    unpatched reference (parseCmdLine). Requires exit 0 + a state record.
  PASS  scalar/bool/alias/BOOLDEF :: path=[] batch=true confirmBigDeletes=false maxerrors=5 fastcheck=default
  PASS  -path (CUSTOM) :: path=[Documents] batch=false confirmBigDeletes=true maxerrors=1 fastcheck=default
  PASS  repeated -path :: path=[A;B] batch=false confirmBigDeletes=true maxerrors=1 fastcheck=default
  PASS  whitespace preserved :: path=[  ws  ] batch=false confirmBigDeletes=true maxerrors=1 fastcheck=default
  PASS  profile paths only :: path=[ProfA;ProfB] batch=false confirmBigDeletes=true maxerrors=1 fastcheck=default
  PASS  CLI + profile precedence :: path=[ProfA;ProfB;CliX] batch=false confirmBigDeletes=true maxerrors=1 fastcheck=default

### 2. Historical parser fidelity: refactored parse (patched) vs unmodified
###    parse (pristine). Requires exit 2 + a case-specific diagnostic, and
###    compares the COMPLETE stdout and stderr streams (file compare).
  PASS  unknown option :: exit 2, diagnostic present, full streams identical
  PASS  missing argument :: exit 2, diagnostic present, full streams identical
  PASS  malformed value :: exit 2, diagnostic present, full streams identical
  PASS  help :: exit 2, diagnostic present, full streams identical

### 3. Variant raises (does not exit) on invalid input, recovery clean
  PASS  invalid argument raises Util.Fatal, no exit          (-maxerrors notanint)
  PASS  the option preceding the failure took effect         path=[Documents] at raise
  PASS  recovery: next session clean after failure           Preset

### 4. Session matrix (reload same overrides, later request, precedence, partial apply)
A. Reload with the SAME overrides preserves scope, no accumulation:
  PASS  first load scopes A to Documents                     Documents
  PASS  reload A with the same -path is still [Documents]    Documents
B. A later request uses only its own overrides:
  PASS  second request carries only its own -path            Projects
C. CLI-versus-profile precedence (profile has paths):
  PASS  profile-only load yields the profile's paths         ProfA;ProfB
  PASS  CLI -path accumulates onto profile paths (not replace) ProfA;ProfB;CliX
D. Partial application then recovery:
  PASS  partial-apply raised Util.Fatal
  PASS  the preceding -path took effect before the failure   path=[Documents]
  PASS  next session clean after partial-apply failure       Preset
```

## The two approaches side by side

| Requirement (from the design's Verification) | `loadStrings` adapter | Parser variant |
|---|---|---|
| Scalar, boolean, alias, `BOOLDEF` match upstream | Yes | Yes |
| `-path` (`CUSTOM`) applied and matching upstream | **No** (translator cannot infer arity) | **Yes** |
| Repeated-list accumulation | Yes (values known) | Yes |
| CLI-versus-profile precedence (profile has paths) | Not shown | **Yes** (accumulates onto profile paths) |
| Whitespace preserved as the CLI does | **No** (trims) | **Yes** |
| Invalid input recovers without exit | Yes (`Util.Fatal`) | Yes (`Util.Fatal`) |
| `cli_only` / process-role options | Rejected by the adapter | **Accepted** by the parser; routed at the app layer |
| Lifecycle call site (after load, before connect) | Upstream source edit | Same upstream source edit |
| Engine parser source patch | No | **Yes** (this diff) |
| Blob rebuild | Yes | Yes |

The single behavioral gap between the two approaches is the middle rows:
`-path`/`CUSTOM`, precedence, and whitespace, which the design names as required
and which only the parser variant satisfies.

## What this does and does not prove

**Proven by the run:**

- Semantic parity with an **independent unpatched upstream** for scalar,
  boolean, alias, `BOOLDEF`, `-path`, repeated `-path`, whitespace, and
  CLI-plus-profile precedence.
- The refactor preserves the historical parser's exit status, stdout, and stderr
  on unknown, missing, malformed, and `-help` input.
- Raising on invalid input with no process exit; the option preceding the
  failure took effect (partial application is real), and the next session is
  clean.
- Session independence and lifetime: a first load scopes the session; reloading
  with the same overrides preserves the scope without accumulation; a later
  request uses only its own overrides.

**Not proven, and still required by the design:**

- **The lifecycle call site is an upstream source edit.** The prototype invokes
  the parser at the correct point (after `loadTheFile`), but does not wire
  `do_unisonInit1` to call it there. Today that function runs `reset ->
  loadTheFile -> (parse on first load only) -> checkThatPreferredRootIsValid ->
  openConnectionStart` with no hook between load and connect. Adding the
  per-session apply there is an edit to `uimacbridge.ml`, needed by **either**
  engine approach; it is not a parser patch.
- **Failure isolation is shown only for the next load.** The run proves the
  option before a failure took effect and that the following session resets
  clean; it does not by itself prevent a scan or connection on the failed
  session. The design requires that a partially applied option set begins
  neither connection nor scanning, which is an app control-flow guarantee around
  this parser call.
- **The parser accepts the whole command-line surface**, including process-role
  options (`-server`, `-ui`, `-doc`, and `cli_only` options such as
  `-dumparchives`). The design routes those at the app layer before a session
  apply; the engine parser does not gate them. This is a difference from the
  adapter, which rejected `cli_only`.
- **No connection, socket, or running-instance behavior** is exercised.
- **Concurrency (#2) remains an app-level guarantee.** Holding session A active
  while a request B arrives, with no preference-touching validation of B while A
  runs, belongs with the implementation.

## Recommendation and next step

For the feature's own options, the parser variant is the faithful path: it
reproduces unmodified upstream parsing, including the `-path`/`CUSTOM`,
precedence, and whitespace cases the adapter cannot, and it recovers from bad
input by raising. Its cost is a vendored engine patch (this diff) carried across
upstream bumps, plus the lifecycle call site both approaches share and the
app-level routing of process-role options.

The patch is small and additive, and the historical `Uarg.parse` and
`Prefs.parseCmdLine` behavior is measured as unchanged. The remaining work
before this becomes a feature, not an experiment, is the `do_unisonInit1`
lifecycle wiring, the app-level failure-isolation and concurrency guarantees, and
the running-instance and caller-result handling in the design. The adoption
decision belongs to review of this diff and evidence; this experiment does not
itself commit to shipping a vendored patch.
