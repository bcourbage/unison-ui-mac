# Engine prototype: session-scoped CLI options: evidence report

**Status:** Feasibility evidence for [`docs/cli-session-requests-design.md`](cli-session-requests-design.md).
**Prototype:** [`docs/spikes/cli-session-prefs-prototype.ml`](spikes/cli-session-prefs-prototype.ml).

## Verdict

The engine boundary works through an **app-owned adapter over existing OCaml
preference APIs** (`Prefs.resetToDefaults` / `loadTheFile` / `loadStrings`), with
**no patch to the engine's own command-line parser**. Every requirement the
review set for the boundary is demonstrated by a running program, not asserted.

The adapter has one real limitation (`cli_only` options, below), which is
aligned with the design rather than a blocker.

## Approach and why

The design's preferred order is: investigate an app-owned adapter over existing
APIs first, before any upstream source patch.

- `Uarg.parse` (the engine's command-line parser) reads a fixed `Sys.argv`
  (`system_generic.ml`: `argv () = Sys.argv`) and calls `exit 2`/`exit 37` on bad
  input. Reusing it on a per-session argument vector would need an upstream patch
  (an args-taking, raising variant), and it terminates the process on invalid
  input, which we must avoid.
- `Prefs.loadStrings : string list -> unit` applies profile-file-syntax lines
  (`["path = Documents"]`). It uses the same value parsers and the same pref
  registry as a profile load, it accumulates list options exactly as the command
  line does, and it **raises `Util.Fatal` (catchable) on bad input rather than
  exiting**. It needs no engine-source patch.

The prototype uses `loadStrings` as the adapter. A session load is:
`resetToDefaults()` → set `profileName` → `loadTheFile()` → `loadStrings overrides`.

## How it was built (reproducible)

Built entirely on the repository's existing OCaml path, no `opam`/`dune`:

1. `make vendor-blob`'s toolchain: `cd unison/src && make Makefile.cfg && make -f Makefile.OCaml tui` compiles every engine object with the pinned `ocamlopt`.
2. The prototype is linked with the exact native link line the `unison` binary uses, with `main.cmx`/`linktext.cmx` (the text-UI entry) replaced by `prototype.cmx`. No engine source is modified; the unison tree is restored with `make clean` afterward.

## Result (verbatim run)

Profiles: `A.prf` configures no `path`; `B.prf` configures `path = Preset`.

```
=== session-scoped option adapter (Prefs.loadStrings), no engine-source patch ===

1. Session A with -path Documents (A configures no path):
  OK             A + path=Documents               path=[Documents]  batch=false confirmBigDeletes=true

2. Reload A with the same overrides (in-place / reconnect):
  OK             A reload + path=Documents        path=[Documents]  batch=false confirmBigDeletes=true

3. Session B, no overrides -- A must not leak (B configures path=Preset):
  OK             B (no overrides)                 path=[Preset]  batch=false confirmBigDeletes=true

4. Session B + -path Other -- list ACCUMULATES onto the profile path:
  OK             B + path=Other                   path=[Preset; Other]  batch=false confirmBigDeletes=true

5. Scalar + boolean + alias overrides (maxerrors, batch, confirmbigdeletes):
  OK             A +maxerrors +batch +alias=false path=[]  batch=true confirmBigDeletes=false

6. Invalid value must RAISE (catchable), never exit the process:
  RAISED(caught) A + batch=notabool               batch expects a boolean value, but notabool is not a boolean
  ...process is still running after invalid input.

7. A command-line-only option is rejected by the adapter:
  RAISED(caught) A +dumparchives (cli_only)       "dumparchives" is a command line-only option; it must not be present in a profile.

8. Failure isolation: partial apply then failure; the NEXT session is clean:
  RAISED(caught) A + path=Documents + bad         batch expects a boolean value, but notabool is not a boolean
  next session B (no overrides) must NOT inherit path=Documents:
  OK             B after failure                  path=[Preset]  batch=false confirmBigDeletes=true

9. -path stays root-relative (never rewritten against cwd=.../unison/src):
  OK             A + path=Documents (check literal) path=[Documents]  batch=false confirmBigDeletes=true

=== done ===
```

## Findings mapped to the review's constraints

- **Load A → reload A → load B (isolation).** Scenarios 1-3: A scoped to
  `[Documents]`, an identical reload stays `[Documents]`, and B with no overrides
  is `[Preset]`, so A's override does not leak, because each load begins with
  `resetToDefaults()`.
- **Parser parity, including list accumulation and precedence (#4).** Scenario 4:
  `-path Other` on B yields `[Preset; Other]`; the list **accumulates onto the
  profile's configured path**, it does not replace it. This matches the engine's
  own `path` parser (`Safelist.append`), so command-line and adapter parity holds.
  Scenario 5: a scalar (`maxerrors`), a boolean (`batch`), and an **alias**
  (`confirmbigdeletes`, which changed `confirmBigDeletes` from its default `true`
  to `false`) all applied.
- **Invalid input rejected without terminating (#1).** Scenario 6: a bad boolean
  raises a catchable `Util.Fatal`; the process keeps running.
- **Path semantics are root-relative (#4, corrected).** Scenario 9: `-path Documents`
  is stored as the literal replica path `Documents`, not resolved against the
  process cwd, and the app never changes its own cwd.
- **Failure isolation beyond synchronization (#3).** Scenario 8: an override set
  that applies `path=Documents` and then fails on a bad boolean leaves the pref
  registry partially set, but the **next** session (B) is clean (`[Preset]`, not
  `[Preset; Documents]`). The clean state comes from `resetToDefaults()` at the
  start of every load, so a failed load never carries into the next request. The
  app must catch the failure and not begin connection or scanning on the partial
  state; catching the exception is not by itself the proof; the clean next
  session is.

## Supported options and the one limitation

- **Supported (profile-settable prefs):** the whole space of options that can
  appear in a profile: `path`, `batch`, `ignore`, `follow`, `force`, scalars,
  booleans, string lists, and their aliases. These are exactly the overrides a
  graphical session would carry.
- **Rejected: `cli_only` options (scenario 7).** A pref marked `cli_only`
  (`-server`, `-socket`, `-ui`, `-version`, `-doc`, `-help`, `-dumparchives`,
  `-testserver`, and similar) raises "command line-only option; it must not be
  present in a profile." This is an **alignment**, not a gap: those are the
  process-level roles the design already handles separately (Entry points), plus a
  few developer/UI flags that are not graphical-session overrides. If a user
  passes a `cli_only` option to a graphical session request, the adapter refuses
  it cleanly, which is the correct outcome.

Net: the adapter reproduces the command-line option semantics for the options a
session actually carries, **without duplicating them in Swift** (the engine's own
parsers and registry do the work) and **without an engine-source patch**.

## Required productionization (not in this prototype)

- **One bridge callback.** `Prefs.loadStrings` is not currently a Swift/C bridge
  capability. Production needs a small callback in the bridge surface
  (`uimacbridge.ml`) that a session load calls after `loadTheFile`, plus its C/Swift
  declaration. That is an app-owned adapter in the bridge, **not** a patch to the
  engine parser.
- **Blob rebuild, not a source patch.** Adding that callback rebuilds the vendored
  blob via the existing `unison/src/Makefile.OCaml` path. It changes no engine
  parsing logic. This is the distinction the review asked to keep explicit:
  avoiding an upstream source patch is achieved; avoiding a blob rebuild is not,
  and does not need to be.
- **Concurrency (#2) is an app-level guarantee.** The prototype proves each load is
  a discrete reset-then-apply; it does not exercise a background operation. The
  "a queued request only stores its args, and neither application nor
  preference-touching validation runs until the prior operation and cleanup
  finish" rule is enforced by the app's engine-idle sequencing and must be proven
  at the app level with session A held active.

## Recommendation

Proceed with the **app-owned `loadStrings` adapter**. It clears every engine-boundary
requirement with no engine-source patch, its only limitation (`cli_only` options)
matches the design, and the remaining work is a single bridge callback plus the
existing blob rebuild. An upstream parser patch is not required and would add
maintenance without a benefit this evidence supports.
