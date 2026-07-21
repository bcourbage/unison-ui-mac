# Contributing to unison-ui-mac

Thanks for the interest. Before opening anything, please read this in
full — the contribution model here is **deliberately unusual** because
of how this project relates to upstream Unison.

## About this project

`unison-ui-mac` is a native macOS GUI for the
[Unison File Synchronizer](https://github.com/bcpierce00/unison) by
Benjamin C. Pierce and contributors. It embeds Unison's compiled OCaml
core (`unison-blob.o`) and drives it through the bridge protocol
declared in `src/uimacbridge.ml`. Under the GPLv3 it's a modified
version of Unison; see [NOTICE.md](NOTICE.md) for the full attribution
and licensing trail.

This project was **written with substantial LLM assistance** and is
intentionally distinct from upstream Unison for that reason.

## Why this matters: upstream's LLM policy

The Unison project's [CONTRIBUTING.md](https://github.com/bcpierce00/unison/blob/master/CONTRIBUTING.md)
has an explicit policy under "LLM usage":

> LLMs essentially always use training input without copyright
> permission, and the unison maintainer considers the output from LLMs
> to be a derived work of the training data. Thus *LLM-generated code
> is simply not acceptable for submission to the project*.

This is not a position I argue with — it's the upstream maintainer's
call about their own codebase. So the rule for this repo is narrow and
specific: **the LLM-touched artifacts here — the `patches/` diffs and
the code in this fork — are local implementation and provenance
artifacts, and must not be submitted upstream directly**, because their
audit trail shows LLM involvement.

That is *not* a blanket claim that an idea can never reach upstream. If
a change genuinely belongs upstream, the maintainer may propose a
**separately developed, fully understood, human-authored** contribution
in accordance with upstream's own
[`CONTRIBUTING.md`](https://github.com/bcpierce00/unison/blob/master/CONTRIBUTING.md)
— developed clean against `bcpierce00/unison`, without consulting or
laundering this repo's LLM-touched diffs. What is off-limits is routing
this fork's LLM-touched code upstream by "cleaning it up" (the audit
trail still shows you saw the LLM output); an independent, human-authored
implementation is a separate thing and is upstream's normal path.

## What to file here

Issues, feature requests, and patches that are **specific to this
macOS GUI** are welcome:

- **Bug reports** about the Swift app, the C bridge, the build,
  installation friction, packaging. Include the embedded Unison
  version (visible in the About panel) and macOS version. The
  Unified Log subsystem `net.courbage.unison-ui-mac` (run
  `log show --predicate 'subsystem == "net.courbage.unison-ui-mac"'
  --last 1h`) captures most useful diagnostics.
- **Feature requests** for the GUI layer — toolbar, menus, profile
  editor, diff viewer, reconcile-window UX, etc. See
  [MANUAL.md](MANUAL.md) for what the GUI currently does and
  [TODO.md](TODO.md) for what's on the maintainer's radar.
- **Documentation fixes** — typos, broken links, mis-stated
  behavior in `MANUAL.md` / `README.md` / inline code comments.
  Don't worry about LLM-assisted tooling for prose edits; this
  isn't code.

## What does NOT belong here

These belong upstream, on `bcpierce00/unison`:

- **Anything that changes the OCaml core's behavior** — sync
  semantics, archive-format changes, RPC protocol changes,
  Unison's `Prefs` framework, OCaml-side I/O. We embed
  `unison-blob.o` verbatim; any change to that surface needs to
  happen in upstream's `src/` and ship in a future Unison release
  we then rebuild against.
- **Fixes to `src/uimacbridge.ml`** beyond the minimal local fork
  patches in `patches/`. The local patches exist only because they
  enable GUI features the upstream UI doesn't need (e.g., the
  `closeConnection` callback and the transport-child reaper hooks).
  Anything broader
  than that — fixing a bug in the existing `uimacbridge` callback
  set, adding a callback that would belong in upstream's
  long-term API — is upstream work, not ours.
- **Changes to the OCaml protocol semantics**. Our C bridge
  follows `uimacbridge.ml` as documented; if you find the protocol
  itself is wrong, that's an upstream issue.

In short: **the question to ask is "would this make sense in any
Unison front-end?" If yes, it's upstream. If it only makes sense for
the macOS app, it's here.**

## Pull requests

Code PRs are accepted with a few caveats:

1. **Your code WILL be touched by an LLM.** This project is built
   end-to-end with substantial LLM assistance — that's not a stage
   the maintainer can or wants to disable for incoming code. Review,
   refactoring, reformatting, test additions, comment expansion,
   commit-message tightening: all of it happens with an LLM in the
   loop. If you're not comfortable with your contribution becoming
   part of that workflow — for licensing, attribution, philosophical,
   or any other reason — **please do not submit a PR**. Open an issue
   describing the problem or proposed change instead; the maintainer
   can independently reproduce and implement, and no LLM-vs-your-code
   interaction occurs.
2. **No expectation of acceptance.** This is a personal-use project.
   The maintainer reviews on availability and may reject contributions
   that don't fit the project's direction without much explanation.
3. **CI hygiene**: `make test` must pass (696 tests at last count,
   ~1 s on M-series Macs). New behavior should add tests where the
   existing patterns (pure-function helpers + XCTest pinning) apply.
4. **GPLv3 inbound = outbound**: by submitting a PR you certify the
   code is your own work (or compatibly licensed) and you license it
   under GPLv3 to this project. Don't submit anything you can't
   license that way.

## Bug-report hygiene

If you file an issue, please include:

- App version (About panel) + embedded Unison version (same place).
- macOS version (`sw_vers`).
- Relevant log slice: `log show --predicate 'subsystem ==
  "net.courbage.unison-ui-mac"' --start <time>`.
- For sync-time bugs: the profile's `.prf` (with credentials
  redacted), the row(s) that misbehaved (path + direction + status
  fields), the result of `unison -showArchiveName <profile>` if the
  archive layer is suspected.
- For build-time bugs: `make print-config` output, `xcodebuild
  -version`, `ocaml --version`.

## Code of conduct

Be kind, assume good faith, don't litigate AI ethics in issue threads
(upstream's policy is documented; ours is downstream of theirs; if you
disagree with either, the productive forum is your own fork). This
project is one person's interactive tool — keep the bar pragmatic.

## Licensing

GPLv3. By contributing you agree to license your contribution under
the same terms. See [LICENSE](LICENSE).
