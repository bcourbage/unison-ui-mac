# Engine prototype: session options via a command-line parser extension: evidence report

**Status:** Feasibility evidence for [`docs/cli-session-requests-design.md`](cli-session-requests-design.md).
**Prototype:** [`docs/spikes/cli-session-parser-prototype.ml`](spikes/cli-session-parser-prototype.ml).
**Patch under review:** [`docs/spikes/cli-session-parser.patch`](spikes/cli-session-parser.patch).
**Reproduce:** [`docs/spikes/run-cli-session-parser-prototype.sh`](spikes/run-cli-session-parser-prototype.sh).
**Companion:** the `Prefs.loadStrings` adapter half is in
[`docs/cli-session-prefs-prototype-report.md`](cli-session-prefs-prototype-report.md).

## Verdict

This half evaluates a **small, backward-compatible extension of the engine's own
command-line parser** that accepts an explicit per-session argument vector and
**raises instead of exiting**. The result:

- The variant is **behaviorally identical to upstream** for the options tested.
  It reuses the same parser, so it inherits every option's arity, list
  accumulation, and command-line precedence. On the same option words it produces
  the same preference state as `Prefs.parseCmdLine`.
- It **applies `-path`**, the feature's central option, exactly as the baseline
  does. `-path` is `Prefs.typ = CUSTOM`; the `loadStrings` translator could not
  infer its arity and refused it. The parser knows it.
- It **preserves whitespace** the command line preserves. `loadStrings` trimmed
  it.
- **Repeated `-path A -path B` accumulates `[A; B]`**, matching the baseline's
  list behavior rather than replacing.
- **Invalid input raises `Util.Fatal`** and does not exit; the next session is
  demonstrably clean.

So the parser variant carries exactly the cases the `loadStrings`-only adapter
could not. Its cost is different, not zero: it is a **vendored engine source
patch** to carry across upstream bumps, and it still needs the **same lifecycle
call site** the adapter needed (after profile load, before connect). Both facts
are detailed below.

## The change

The patch touches four clean files (the full diff is
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
  keeps its exact former behavior by catching `ParseError` and doing the old
  print-and-exit (the removed lines reappear verbatim inside the new `parse`, so
  the change is a refactor plus two additions). A new `parseArgv args speclist
  anonfun` parses an explicit vector, raises `Uarg.Bad` on error, and saves and
  restores `Uarg.current` so a session parse does not disturb the shared
  `Sys.argv` position.
- `Prefs`: `parseCmdLineArgs usage args` is the session-request counterpart of
  `parseCmdLine`. It drives `Uarg.parseArgv` through the same `argspecs`, and
  funnels both `IllegalValue` and `Uarg.Bad` into a single catchable
  `Util.Fatal`.

`Uarg.parse` and `Prefs.parseCmdLine` are unchanged in behavior, so the existing
text UI and server entry points are unaffected. The addition is purely additive
API surface plus an internal refactor.

## Reproducing it

One committed script does everything: it applies the patch to a pristine tree,
builds the engine objects on the repository's own OCaml path
(`unison/src/Makefile.OCaml`, the same path `make vendor-blob` uses; no
`opam`/`dune`), links the prototype, runs every asserted case, and restores only
the four patched files with `git checkout` (leaving any unrelated local
modifications in the tree untouched). It exits non-zero if any assertion fails.

```sh
UNISON_SRC=/path/to/unison/src docs/spikes/run-cli-session-parser-prototype.sh
```

The baseline in every case is upstream's own parser on the process's fixed
`Sys.argv` (`Prefs.parseCmdLine`); the variant is `Prefs.parseCmdLineArgs` fed
the same option words as an explicit vector. Because `parseCmdLine` reads a fixed
argv, each argv is exercised in its own process, selected by `EXPECT`.

## Result (verbatim run)

```
##### match (bool, alias-opposite-default, int, BOOLDEF) + B..F #####
  baseline(parseCmdLine): batch=true confirmBigDeletes=false maxerrors=5 fastcheck=default
  variant(parseCmdLineArgs): batch=true confirmBigDeletes=false maxerrors=5 fastcheck=default
  PASS  boolean matches upstream baseline              true
  PASS  alias set OPPOSITE its default (proves effect) false
  PASS  scalar (maxerrors) matches upstream baseline   5
  PASS  BOOLDEF (fastcheck=default) matches upstream baseline default
B. Reset isolation (A -> reload A -> B), each session independent:
  PASS  A scoped to Documents                          Documents
  PASS  reload A with no overrides drops the scope
  PASS  B clean, no leak from A                        Preset
C. Later request with different overrides uses only its own:
  PASS  second request carries only its own -path      Projects
D. Failure isolation (partial apply then reset):
  PASS  next session clean after partial-apply failure Preset
E. Lifecycle insertion point (parser applies after loadTheFile, before connect):
  PASS  servercmd applied at the pre-connection point  /session/unison
F. Full-CLI surface note (a real difference from the loadStrings adapter):
  PASS  parser variant ACCEPTS cli_only options (loadStrings rejected them) (-dumparchives)

##### path-custom (the headline) #####
  baseline(parseCmdLine -path): [Documents]
  variant(parseCmdLineArgs -path): [Documents]
  PASS  variant applies -path (CUSTOM), unlike the loadStrings translator Documents
  PASS  variant matches upstream baseline for -path    Documents

##### repeated-list #####
  baseline(parseCmdLine -path A -path B): [A; B]
  variant(parseCmdLineArgs -path A -path B): [A; B]
  PASS  repeated list accumulates [A; B]               A,B
  PASS  variant matches upstream baseline for repeated -path A,B

##### whitespace #####
  baseline(parseCmdLine '-path   ws  '): [  ws  ]
  variant(parseCmdLineArgs '-path   ws  '): [  ws  ]
  PASS  variant preserves whitespace, matches upstream baseline [  ws  ]

##### invalid #####
  PASS  invalid argument raises Util.Fatal, no exit    (-maxerrors notanint)
  PASS  next session clean after a raised failure      []
```

## The two approaches side by side

| Requirement (from the design's Verification) | `loadStrings` adapter | Parser variant |
|---|---|---|
| Scalar, boolean, alias, `BOOLDEF` match upstream | Yes | Yes |
| `-path` (`CUSTOM`) applied and matching upstream | **No** (translator cannot infer arity) | **Yes** |
| Repeated-list accumulation and precedence | Yes (values known) | Yes |
| Whitespace preserved as the CLI does | **No** (trims) | **Yes** |
| Invalid input recovers without exit | Yes (`Util.Fatal`) | Yes (`Util.Fatal`) |
| `cli_only` / process-role options | Rejected by the adapter | **Accepted** by the parser; routed at the app layer |
| Lifecycle call site (after load, before connect) | Upstream source edit | Same upstream source edit |
| Engine parser source patch | No | **Yes** (this diff) |
| Blob rebuild | Yes | Yes |

The single behavioral gap between the two approaches is the middle rows:
`-path`/`CUSTOM` and whitespace, which the design names as required and which
only the parser variant satisfies.

## What this does and does not prove

**Proven by the run:**

- Parser parity with upstream for scalar, boolean, alias, `BOOLDEF`, `-path`,
  repeated `-path`, and whitespace.
- Raising on invalid input with no process exit, and a clean next session.
- Session independence: A scoped, reload A drops the scope, B clean; a later
  request uses only its own overrides.
- The parser can be invoked at the pre-connection point (`servercmd` set after
  `loadTheFile`).

**Not proven, and still required by the design:**

- **The lifecycle call site is an upstream source edit.** Section E sets a
  preference at the correct point; it does not wire `do_unisonInit1` to call the
  parser there. Today that function runs `reset -> loadTheFile -> (parse on
  first load only) -> checkThatPreferredRootIsValid -> openConnectionStart` with
  no hook between load and connect. Adding the per-session apply there is an edit
  to `uimacbridge.ml`. This edit is needed by **either** engine approach; it is
  not specific to the parser patch.
- **Failure isolation is shown only for the next load.** Section D proves the
  following session resets clean; it does not by itself prevent a scan or
  connection on the failed session. The design requires that a partially applied
  option set begins neither connection nor scanning, which is an app
  control-flow guarantee around this parser call, not a property of the parser.
- **The parser accepts the whole command-line surface**, including process-role
  options (`-server`, `-ui`, `-doc`, and `cli_only` options such as
  `-dumparchives`). The design routes those at the app layer before a session
  apply; the engine parser does not gate them. This is a difference from the
  adapter, which rejected `cli_only`, and it moves that gating into app code.
- **No connection, socket, or running-instance behavior** is exercised. This is
  a bounded engine prototype only.
- **Concurrency (#2) remains an app-level guarantee.** Holding session A active
  while a request B arrives, with no preference-touching validation of B while A
  runs, is not attempted here; it belongs with the implementation.

## Recommendation and next step

For the feature's own options, the parser variant is the faithful path: it
reproduces upstream parsing exactly, including the `-path`/`CUSTOM` and
whitespace cases the adapter cannot, and it recovers from bad input by raising.
Its cost is a vendored engine patch (this diff) carried across upstream bumps,
plus the lifecycle call site both approaches share and the app-level routing of
process-role options.

The patch is small, additive, and leaves the existing `Uarg.parse` and
`Prefs.parseCmdLine` behavior unchanged. The remaining work before this becomes a
feature, not an experiment, is the `do_unisonInit1` lifecycle wiring, the
app-level failure-isolation and concurrency guarantees, and the running-instance
and caller-result handling in the design. The adoption decision belongs to review
of this diff and evidence; this experiment does not itself commit to shipping a
vendored patch.
