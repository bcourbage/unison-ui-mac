# Engine prototype: session-scoped CLI options: evidence report

**Status:** Feasibility evidence for [`docs/cli-session-requests-design.md`](cli-session-requests-design.md).
**Prototype:** [`docs/spikes/cli-session-prefs-prototype.ml`](spikes/cli-session-prefs-prototype.ml).

## Verdict (revised)

An earlier draft concluded "the adapter works; only one callback remains." That
was premature. This iteration tests an actual CLI-to-preference translation
against the engine's own parser and demonstrates the lifecycle, and the honest
result is narrower:

- The `Prefs.loadStrings` adapter **does** apply scalar, boolean, string, and
  aliased profile-settable options, resets cleanly between sessions, and rejects
  invalid and `cli_only` options with catchable errors, matching the engine's own
  command-line parser for those options.
- But it **does not generically translate `-path`** (or any `CUSTOM`-typed pref),
  and it **trims whitespace** that the command line preserves. `-path` is the
  central option of this feature.
- And the production insertion point **requires an upstream source edit**, not
  only a bridge callback: `-path`-style overrides must be applied between profile
  load and connection, and there is no hook there today.

So a `loadStrings`-translation adapter is **not sufficient on its own**, and a
small command-line-parser variant is **not ruled out**. The investigation should
continue rather than commit to either mechanism.

## Approach and why

- `Uarg.parse` (the engine's command-line parser) reads a fixed `Sys.argv`
  (`system_generic.ml`: `argv () = Sys.argv`) and calls `exit` on bad input.
  Driving it on a per-session argument vector would need a patch (args-taking,
  raising). It does, however, know each option's arity from its `Uarg` spec.
- `Prefs.loadStrings : string list -> unit` applies profile-file-syntax lines and
  raises `Util.Fatal` (catchable) on bad input, no `exit`. But it takes
  profile-file lines (`path = X`), not CLI args, so it needs a translator, and
  the translator can only see `Prefs.typ` (the value type), not the arity.

The prototype uses `loadStrings` as the adapter and compares it, on the same
argv, against `Prefs.parseCmdLine` (the engine's own parser) as the baseline.

## Reproducing it

Toolchain is the repository's own (`ocamlopt`), no `opam`/`dune`.

```sh
# 1. Build the engine objects (same path make vendor-blob uses):
cd unison/src && make Makefile.cfg && make -f Makefile.OCaml tui
# 2. Compile the prototype (copied from docs/spikes/cli-session-prefs-prototype.ml):
inc="-I lwt -I ubase -I system -I system/generic -I lwt/generic -I +unix -I +str"
ocamlopt -g $inc -c prototype2.ml
# 3. Link with the unison binary's exact native objects, main.cmx/linktext.cmx
#    replaced by prototype2.cmx (see the -o unison line in the tui build log).
ocamlopt -g $inc -o prototype2 <those .cmx, ending prototype2.cmx> <the .o C stubs>
# 4. Fixtures + run (three modes; the CLI parser reads a fixed argv, so one per run):
U=$(mktemp -d); printf '# A: no path\n' > "$U/A.prf"; printf 'path = Preset\n' > "$U/B.prf"
EXPECT=match      UNISON="$U" ./prototype2 -batch -confirmbigdeletes -maxerrors 5
EXPECT=path-custom UNISON="$U" ./prototype2 -path Documents
EXPECT=whitespace  UNISON="$U" ./prototype2 -path '  ws  '
# The unison tree is restored afterward with `make clean`; no engine source is edited.
```

The prototype **asserts** each expectation and **exits non-zero** on any surprise.

## Result (verbatim run)

```
=== prototype2 EXPECT=match argv=[-batch -confirmbigdeletes -maxerrors 5] ===
  baseline(parseCmdLine): path=[] batch=true confirmBigDeletes=true maxerrors=5
  adapter lines: [batch = true | confirmbigdeletes = true | maxerrors = 5]
  PASS  boolean matches CLI baseline             true
  PASS  alias matches CLI baseline               true
  PASS  scalar (maxerrors) matches CLI baseline  5
B. Reset isolation:
  PASS  A scoped to Documents                    Documents
  PASS  B clean, no leak                         Preset
C. Invalid override raises, no exit:
  PASS  invalid raised Util.Fatal
  PASS  process alive
D. cli_only rejected:
  PASS  dumparchives (cli_only) rejected
E. Failure isolation (reset-before-next, NOT connect/scan prevention):
  PASS  next session clean after partial-apply failure Preset
F. Lifecycle point (override in effect before connect):
  PASS  servercmd applied after loadTheFile      /session/unison
=== PASS (0 failure(s)) ===

=== prototype2 EXPECT=path-custom argv=[-path Documents] ===
  baseline(parseCmdLine): path=[Documents] batch=false confirmBigDeletes=true maxerrors=1
  PASS  -path is CUSTOM: generic translate refuses (engine's own parser handled it in the baseline above)
  PASS  CLI baseline still applied -path         Documents
=== PASS (0 failure(s)) ===

=== prototype2 EXPECT=whitespace argv=[-path   ws  ] ===
  baseline(parseCmdLine): path=[  ws  ] batch=false confirmBigDeletes=true maxerrors=1
  adapter(loadStrings 'path =   ws  '): path=[ws]
  PASS  CLI keeps whitespace, loadStrings trims (DIFFER) CLI=  ws   vs adapter=ws
=== PASS (0 failure(s)) ===
```

## Findings, mapped to the review

**1. Lifecycle and "no source patch" (P1).** Section F applies a connection-affecting
override (`servercmd`) at the point it must land: after `loadTheFile`, before a
connection. Production `do_unisonInit1` runs `reset -> loadTheFile -> (parse on
first) -> checkThatPreferredRootIsValid -> openConnectionStart` with **no hook**
between load and connect. Applying overrides there is an **upstream source edit**
to that engine function (`uimacbridge.ml`). It is not a *parser* patch, but the
"no source patch" claim was wrong; those are different claims, and this one needs
a lifecycle edit.

**2. CLI translation vs an independent baseline (P2).** The baseline is
`Prefs.parseCmdLine` (the engine's own parser) on the same argv.
- **Matches for bool, alias, and int** (`-batch`, `-confirmbigdeletes`,
  `-maxerrors 5`), with `maxerrors` read back from a preference dump.
- **`-path` cannot be translated generically.** `Prefs.typ "path"` is `CUSTOM`
  (path uses a custom parser, not `createStringList`), so the translator cannot
  learn its arity from the public API and refuses rather than guess. The engine's
  own parser handles `-path` in the baseline. A `loadStrings` adapter would have
  to hardcode `-path` (and every other `CUSTOM` option's) arity, which is the
  duplication of CLI semantics the design set out to avoid, or the engine must
  expose per-option arity.
- **Whitespace differs.** The command line preserves `  ws  `; the profile parser
  `loadStrings` uses trims to `ws` (`prefs.ml`: `Util.trimWhitespace`). Values
  with significant whitespace cannot be round-tripped through `key = value`.
- Bare booleans are handled by querying `Prefs.typ` and emitting `name = true`;
  repeated list arguments accumulate. Both are shown for translatable options.

**3. Assertions, reproducibility, and scoped claims (P2).** The prototype now
asserts and exits non-zero (an accepted invalid value, or an unexpected raise,
fails the run). The build/link/run commands and fixtures are above. The
failure-isolation case (E) is scoped: it proves the **next** session resets
clean, **not** that a scan or connection is prevented on the failed session,
which is an app control-flow guarantee shown elsewhere.

## What is supported vs not

- **Supported:** profile-settable scalar, boolean, string, string-list, and
  aliased options, applied with reset isolation and catchable rejection of invalid
  and `cli_only` options. That is the majority of options a session would carry.
- **Not, via a generic `loadStrings` translator:** `CUSTOM`-typed options,
  including **`-path`** (the feature's central option); and any value with
  significant leading/trailing whitespace.

## Productionization is more than one callback

- Exposing `loadStrings` needs a bridge callback (`uimacbridge.ml`).
- Applying overrides at the right lifecycle point needs a **source edit** to
  `do_unisonInit1` (or a new bridge entry that splits load from connect).
- Handling `-path` and other `CUSTOM` options needs either per-option arity
  hardcoded in the app, or an engine change to expose arity, or reuse of the
  command-line parser (an args-taking, raising variant), which is a parser patch.
- Concurrency (#2) remains an app-level guarantee, proven with session A held
  active; it is not attempted here.

## Recommendation

Continue the adapter investigation; **do not** declare a command-line-parser patch
unnecessary. The `-path`/`CUSTOM` gap and the whitespace trim mean a
`loadStrings`-only adapter cannot faithfully carry the feature's own options
without duplicating semantics, and the lifecycle needs a source edit regardless.
The next comparison worth running is a bounded args-taking, raising variant of the
engine's command-line parser against the same baseline, to weigh it against the
adapter on exactly `-path`, whitespace, and the lifecycle insertion.
