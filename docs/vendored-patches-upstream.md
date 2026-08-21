# Vendored Unison patches — upstream-contribution reference

Details of every local patch applied to the vendored Unison engine, with an
explicit **additive-only** verdict per patch (does it only *add* lines, or does
it also modify/remove existing upstream lines?). Additive-only patches are the
lowest-risk to land upstream; patches that change existing lines need closer
review.

## Baseline

| Field | Value |
| --- | --- |
| Upstream | `bcpierce00/unison` **v2.54.0**, commit `91421d0617b0fb543c0eee51bcb4d4791d8b0631` (`v2.54.0-19-g91421d0`, `origin/master`) |
| Toolchain | OCaml 5.5.0 (pinned) |
| Apply mechanism | `scripts/apply-unison-patches.sh` (idempotent, per-patch dry-run detection); series in `patches/` |
| Already upstreamed | `0001-uimacbridge-register-abortAll` — **merged** as [PR #1198](https://github.com/bcpierce00/unison/pull/1198) (commit `2429c6c`), retired from this series. Precedent that the series-based flow works. |

## Summary

| Patch | Files (added / removed) | Additive only? | Scope | Upstream candidate |
| --- | --- | --- | --- | --- |
| 0002 closeConnection | `uimacbridge.ml` (+51 / −0) | **Yes** | macUI bridge | Low (macUI-only) |
| 0003 close-and-drain | `remote.ml` (+36/−0), `remote.mli` (+17/−0), `test.ml` (+96/−0), `uicommon.ml` (+4/−13) | **No** | general engine | **High** |
| 0004 transport-child reaper | `remote.ml` (+41/−0), `remote.mli` (+11/−0), `uimacbridge.ml` (+10/−0) | **Yes** | general hooks + macUI policy | Medium (hooks half) |
| 0005 sync-completion snapshot | `uimacbridge.ml` (+11/−2) | **No** | macUI bridge | Low (macUI perf) |

Two of the four are strictly additive (0002, 0004). The two non-additive ones
each change a small, well-scoped piece of existing code (see below).

---

## 0002 — `uimacbridge-register-closeConnection`

- **Additive only: YES** — `src/uimacbridge.ml` +51 / −0. Pure new callback
  registration; touches no existing lines.
- **What:** registers a `closeConnection` OCaml callback so the macUI bridge can
  cleanly tear down an established remote connection when the user leaves a
  profile (closes the connection's channels, unregisters it, drains). Issue #6.
- **Upstream relevance:** the bridge file is macUI-only, so this matters upstream
  only if the native macUI is to gain connection teardown. Depends on 0003's
  engine primitive.
- **Upstream-readiness (generalization in progress):** the exception-handler
  diagnostic emits a fork-neutral `closeConnection: <error>`; the downstream
  `unison-mac:` prefix is dropped. Any remaining downstream-specific elements are
  to be reviewed before 0002 is offered upstream. Tracked in `TODO.md`.

## 0003 — `remote-close-and-drain`

- **Additive only: NO.** Three files are purely additive — `src/remote.ml`
  (+36/−0), `src/remote.mli` (+17/−0), `src/test.ml` (+96/−0) — but
  **`src/uicommon.ml` is +4 / −13**: it *replaces* the existing inline
  post-close drain loop (the `loop_yield` + `for … Transport.maxThreads () …
  Lwt_unix.run` block) with a single call to the newly-added
  `Remote.drainDroppedConnectionThreads ~rounds:(Transport.maxThreads ())`.
  So the net change is a **refactor-extract**: existing behavior moved into a
  named, reusable `remote.ml` function, plus the new drain semantics.
- **What:** adds `Remote.drainDroppedConnectionThreads` and drives it from the
  close paths so a closed connection's dormant Lwt receiver thread cannot resume
  inside the *next* connection's `Lwt_unix.run` (issue #8).
- **Ships a test:** `src/test.ml` gains a no-network connection-lifecycle test
  (an ssh-replacement shell wrapper; Unix-only) — exactly the evidence upstream
  review expects.
- **Upstream relevance: HIGH.** Genuine engine-correctness fix in shared,
  non-GUI code, with a self-test. The strongest standalone contribution. Note
  for the PR: the `uicommon.ml` hunk is a behavioral change to a shared code
  path, so call it out explicitly rather than burying it under "additive".

## 0004 — `remote-transport-child-reaper`

- **Additive only: YES** — `src/remote.ml` (+41/−0), `src/remote.mli` (+11/−0),
  `src/uimacbridge.ml` (+10/−0). All hunks add lines; no existing line changed.
- **What:** adds overridable `Remote.register/retireTransportChild` hooks
  (**default no-ops**, so CLI/GTK behavior is unchanged); the macUI bridge sets
  them to track the exact transport (ssh) child PID at spawn and, at teardown,
  SIGKILL + remove it under a mutex before reaping. Design: `docs/ssh-reaper-design.md`.
- **Upstream relevance:** cleanly separable. The **hook mechanism in
  `remote.ml`/`.mli` is general and additive with no-op defaults** — plausibly
  upstreamable on its own. The PID-tracking *policy* lives in the macUI bridge
  and is macUI-specific.

## 0005 — `uimacbridge-sync-completion-snapshot`

- **Additive only: NO** — `src/uimacbridge.ml` +11 / −2. It **changes the
  signature of an existing `external`**: `syncComplete : unit -> unit` becomes
  `syncComplete : stateItem array -> unit`, and updates the one call site
  (`syncComplete ()` → `syncComplete !theState`). The other +lines are an
  explanatory comment.
- **What:** `syncComplete` now carries the final post-sync `stateItem array` so
  the bridge marshals ONE bulk completion snapshot (each row's final progress +
  details) in a single call, instead of the UI making O(n) per-row
  `unisonRiToDetails` round-trips at completion (Finding #10). Reuses
  already-registered accessors; no new OCaml allocation.
- **Upstream relevance: LOW.** A macUI-bridge performance change, and it alters
  a bridge external's ABI — only relevant if upstream evolves the native macUI.

---

## Contribution decomposition

Group by generality, which is the natural PR split:

1. **General engine (realistic upstream PRs):**
   - **0003 close-and-drain** — highest value; already has a `test.ml` test.
     Flag the `uicommon.ml` behavioral hunk explicitly.
   - **0004's `remote.ml`/`.mli` hook half** — additive, no-op defaults; could
     be proposed independently of the macUI wiring.
2. **macUI-bridge only (lower value, harder to land):** 0002, 0005, and 0004's
   `uimacbridge.ml` wiring — relevant only if upstream evolves the
   largely-unmaintained native macUI.

## Caveats before investing

- **Authorship / contribution policy.** This repo is LLM-assisted and upstream
  has been wary of LLM-authored contributions. These patches are small,
  mechanical `Callback`/hook registrations (the vendor README characterizes them
  as not carrying significant authorship) and 0001 already landed — but confirm
  upstream's current stance and present human-reviewed, minimal diffs.
- **Licensing:** non-issue. Everything is GPLv3-or-later, same as upstream;
  derivative-artifact provenance is documented in `vendor/README.md` §6.

## Supporting material for reviewers

- `docs/ssh-reaper-design.md` — 0004.
- Issue #8 — 0003 rationale.
- `docs/scan-interruption-design.md` — engine connection-lifecycle reasoning.
- `vendor/README.md` — provenance, toolchain, and the full patch-set description.
