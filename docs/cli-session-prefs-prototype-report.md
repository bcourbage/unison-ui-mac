# Engine prototype: session-scoped CLI options: evidence report

**Status:** Feasibility evidence for [`docs/cli-session-requests-design.md`](cli-session-requests-design.md).
**Prototype:** [`docs/spikes/cli-session-prefs-prototype.ml`](spikes/cli-session-prefs-prototype.ml).
**Reproduce:** [`docs/spikes/run-cli-session-prefs-prototype.sh`](spikes/run-cli-session-prefs-prototype.sh).

## Verdict

This half of the comparison evaluates an **app-owned adapter over
`Prefs.loadStrings`**. The honest result:

- The adapter **applies** scalar, boolean, `BOOLDEF`, string, string-list, and
  aliased profile-settable options; resets cleanly between sessions; and rejects
  invalid and `cli_only` options with catchable errors, matching the engine's own
  command-line parser for those options.
- A generic **CLI-args translator** built on it **cannot handle `-path`**: `path`
  is a `CUSTOM`-typed pref, so the translator cannot infer its arity from the
  public API and refuses it. (This is a limit of the *translator*, not of
  `loadStrings`, which applies a path value fine; see the repeated-list case.)
- `loadStrings` **trims whitespace** the command line preserves.
- The production insertion point needs a **source edit**: overrides must be
  applied between profile load and connection, and today's `do_unisonInit1` has
  no hook there.

So a `loadStrings`-only adapter is **not sufficient** for the feature's own
options, and the command-line-parser variant is the candidate to weigh next.

## Approach and why

- `Uarg.parse` (the engine's command-line parser) reads a fixed `Sys.argv`
  (`system_generic.ml`: `argv () = Sys.argv`) and calls `exit` on bad input.
  Driving it on a per-session argument vector would need a patch (args-taking,
  raising). It does know each option's arity from its `Uarg` spec.
- `Prefs.loadStrings : string list -> unit` applies profile-file-syntax lines and
  raises `Util.Fatal` (catchable), no `exit`, but takes `key = value` lines, not
  CLI args, so it needs a translator that can only see `Prefs.typ` (value type),
  not arity.

The prototype uses `loadStrings` as the adapter and compares it, on the same argv,
against `Prefs.parseCmdLine` (the engine's own parser) as the baseline.

## Reproducing it

One committed script does everything (build the engine objects on the repository's
own OCaml path, link the prototype, run every asserted case, restore the tree),
and exits non-zero if any assertion fails:

```sh
UNISON_SRC=/path/to/unison/src docs/spikes/run-cli-session-prefs-prototype.sh
```

No `opam`/`dune`; no engine source is edited (`make clean` restores the tree).

## Result (verbatim run)

```
##### match (bool, alias-opposite-default, int, BOOLDEF) #####
  baseline(parseCmdLine): path=[] batch=true confirmBigDeletes=false maxerrors=5 fastcheck=default
  adapter lines: [batch = true | confirmbigdeletes = false | maxerrors = 5 | fastcheck = default]
  PASS  boolean matches CLI baseline               true
  PASS  alias set OPPOSITE its default (proves effect) false
  PASS  scalar (maxerrors) matches CLI baseline    5
  PASS  BOOLDEF (fastcheck=default) matches CLI baseline default
B. Reset isolation:
  PASS  A scoped to Documents                      Documents
  PASS  B clean, no leak                           Preset
C. Invalid override raises, no exit:
  PASS  invalid raised Util.Fatal
D. cli_only rejected:
  PASS  dumparchives (cli_only) rejected
E. Failure isolation (reset-before-next only):
  PASS  next session clean after partial-apply failure Preset
F. Preference assignment at the pre-connection point (NOT a production integration):
  PASS  servercmd set after loadTheFile            /session/unison
=== PASS (0 failure(s)) ===

##### repeated-list #####
  baseline(parseCmdLine): path=[A; B] ...
  adapter(loadStrings path=A; path=B): path=[A; B]
  PASS  repeated list accumulates, matches CLI baseline A,B
=== PASS (0 failure(s)) ===

##### path-custom #####
  baseline(parseCmdLine): path=[Documents] ...
  PASS  -path is CUSTOM: generic TRANSLATOR refuses (loadStrings itself CAN apply a path value; see repeated-list)
  PASS  CLI baseline still applied -path           Documents
=== PASS (0 failure(s)) ===

##### whitespace #####
  baseline(parseCmdLine): path=[  ws  ] ...
  adapter(loadStrings 'path =   ws  '): path=[ws]
  PASS  CLI keeps whitespace, loadStrings trims (DIFFER) CLI=  ws   vs adapter=ws
=== PASS (0 failure(s)) ===
```

## Findings, mapped to the review

**Lifecycle and "no source patch" (P1).** Section F is a preference assignment plus
source inspection, **not** a demonstrated production lifecycle: it sets a
connection-affecting pref (`servercmd`) at the point overrides must land (after
`loadTheFile`), and inspects `do_unisonInit1`, which today runs
`reset -> loadTheFile -> (parse on first) -> checkThatPreferredRootIsValid ->
openConnectionStart` with no hook between load and connect. That shows the
*current* function has no suitable hook; it does not prove every app-owned
replacement entry would need a source edit, though such a replacement would
duplicate that lifecycle. Applying overrides in the existing function is an
**upstream source edit** (not a *parser* patch); "no parser patch" and "no source
patch" are different claims, and this needs the latter.

**CLI translation vs the engine's own parser (P2).** Baseline is `Prefs.parseCmdLine`.
- **Bool, alias, int, and `BOOLDEF` match.** `BOOLDEF` (`createBoolWithDefault`,
  e.g. `-fastcheck default`) takes a value; the translator splits it from bare
  `BOOL` and emits `fastcheck = default`, matching the baseline.
- **The alias is set opposite its default** (`-confirmbigdeletes=false` where the
  default is `true`), so the check would fail if the alias did nothing.
- **Repeated list demonstrated:** `-path A -path B` yields `[A; B]` from the CLI,
  and `loadStrings ["path = A"; "path = B"]` yields the same, so list accumulation
  matches. (Constructed directly because the generic translator refuses `-path`.)
- **`-path` refused by the translator** (`Prefs.typ = CUSTOM`); the engine's own
  parser applied it in the baseline.
- **Whitespace differs:** the CLI keeps `  ws  `; `loadStrings` trims to `ws`
  (`prefs.ml`: `Util.trimWhitespace`).

**Assertions and reproducibility (P2).** Every case asserts and the run exits
non-zero on any surprise (an accepted invalid value, or an unexpected raise). The
full build/link/run and fixtures are the committed script above. The
failure-isolation case (E) is scoped to what it proves: the next session resets
clean, not that a scan or connection is prevented on the failed session (an
app-level control-flow guarantee).

## What is supported vs not

- **Supported:** profile-settable scalar, boolean, `BOOLDEF`, string, string-list,
  and aliased options, with reset isolation and catchable rejection of invalid and
  `cli_only` options.
- **Not, via a generic `loadStrings` translator:** `CUSTOM`-typed options,
  including **`-path`** (the feature's central option), and any value with
  significant leading/trailing whitespace.

## Productionization is more than one callback

- Exposing `loadStrings` needs a bridge callback (`uimacbridge.ml`).
- Applying overrides at the right lifecycle point needs a **source edit** to
  `do_unisonInit1`, or a new entry that splits load from connect (which duplicates
  the lifecycle).
- Handling `-path`/`CUSTOM` needs per-option arity hardcoded in the app, or an
  engine change to expose arity, or reuse of the command-line parser.
- Concurrency (#2) remains an app-level guarantee, proven with session A held
  active; not attempted here.

## Recommendation and next step

A `loadStrings`-only adapter cannot faithfully carry `-path` or preserve
whitespace, and the lifecycle needs a source edit regardless. The next experiment,
now authorized (as an experiment, not a commitment to ship a vendor patch), is a
**small, backward-compatible command-line-parser extension** that accepts
per-session arguments and **raises instead of exiting**, plus the required
lifecycle integration, measured against this same upstream baseline on exactly
`-path`, whitespace, and the insertion point. The two approaches will be compared
on behavior and maintenance cost, with the actual diff and evidence put up for
review before any adoption decision.
