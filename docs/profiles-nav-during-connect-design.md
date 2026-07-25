# Design Proposal: Profiles / picker navigation during connect (issue #38)

Status: draft for review. 0.3.1 UX; no vendored-blob change expected.

Related: #35 (fatal-ssh-as-prompt, done), #51 (scan-interruption teardown machinery, merged). See `docs/scan-interruption-design.md` for the coordinator/teardown vocabulary.

## 1. Purpose

Make **Action ▸ Show Profile Picker** (and the toolbar "Return to Profiles") reliably available throughout the connect phase (`.opening`), so a user can bail to the picker during a slow or interactive connect — matching the app's stated intent that navigation is always available except during `.syncing`. Keep the expected sheet-modality behavior while a credential sheet is actually up.

## 2. Baseline / evidence

- Reproducible: `Action ▸ Show Profile Picker` read `enabled=false` in **12/12 samples across 2 runs** during `.opening`, **before any credential sheet appeared** (`sheet=no` throughout). Observed on Debug at `main`-derived `a1f9762`, profile `Sync-LiveTest-VM-Pw`. The whole toolbar row shows greyed during "Opening…".
- It is *also* inert once the credential sheet is up — that part is expected sheet modality and is **not** the bug.

## 3. Root cause: a validation/responder-timing artifact, not a gate

Every explicit enablement site already says navigation is always available except `.syncing`:

- `ReconcileActionGate` (`.profiles`, `.quit`): "Navigation is always available — never blocked."
- `ReconcileWindowController.canPerformToolbarAction` → `profilesIdentifier`: `return true`.
- `ReconcileWindowController.validateMenuItem` → `showProfilePickerMenuAction`: `true` unless `.syncing`.
- `AppDelegate.validateMenuItem`: does not gate it.

So nothing *intends* it disabled during `.opening`. The likely cause is that during `.opening` the reconcile window's **responder / first-responder wiring** (or menu/toolbar validation timing) does not yet route `showProfilePickerMenuAction:` to an enabled responder — a validation target that isn't established yet, not an explicit gate. The fix is therefore about **when the reconcile window becomes the validation target during connect**, not about the enablement predicates (which are already correct).

## 4. The teardown concern (why "just enable it" is a scope trap)

Enabling the control is necessary but not sufficient: navigating away during `.opening` must **reap the in-flight connect cleanly**, or it reintroduces the lingering-child problem (#53). The good news is the reaping path already exists:

- The connect phase leaves through `leaveSession` → `engine.abandon()`; for `.opening` the coordinator's `leaveRouting` returns `.leaveImmediately` (it is not `.scanning`), i.e. the honest immediate leave — **not** the #51 SIGKILL-interruption path.
- The half-open preconnection is torn down via `connection_cancel` (the #35 `failConnectFatal` machinery reaps the tracked ssh child; child-exit is proven via `unison_bridge_transport_child_terminated()` / sysctl `SZOMB`), and presentation waits for the cancel to be **acknowledged** (engine quiescent) before returning to the picker; a cancel that can't prove quiescence routes to `.restartRequired`.

So the safe fix routes a nav-during-`.opening` through the **existing connect-cancel reap + quiescence gate**, reusing #35's teardown — no new interruption mechanism, no blob change.

## 5. Proposed approach

1. **Establish the validation target during `.opening`.** Ensure the reconcile window is the first responder / validation target as soon as it appears (during "Opening…"), so `validateMenuItem` / `canPerformToolbarAction` — which already return enabled — are actually consulted. Concretely: audit when the reconcile window is made key/main and when its responder chain is wired relative to the `.opening` transition; wire it at window creation, not at first render/scan.
2. **Route the leave through the existing connect-cancel reap.** `showProfilePicker` / Return-to-Profiles during `.opening` → `leaveSession` → `.leaveImmediately` → `connection_cancel` reap → present picker only on acknowledged quiescence (else `.restartRequired`). No new code path; confirm the abandon-during-`.opening` reaping is exercised.
3. **Preserve sheet modality.** While a credential sheet is actually up, keep today's behavior (the sheet owns input; its **Cancel** is the in-sheet exit). The change targets only the **pre-sheet** `.opening` window.

## 6. Alternatives considered

- **(A) Explicit always-enabled routing** — force-enable the item during `.opening` by overriding validation. Rejected as papering over the responder-timing root cause; risks enabling it in a state where the action isn't wired.
- **(B) Fix the validation target timing (recommended).** Addresses the actual cause; the enablement predicates are already correct, so once the window is the validation target the control lights up on its own.

## 7. Test matrix

- **Enablement:** `Show Profile Picker` reads `enabled=true` throughout `.opening`, pre-sheet, across repeated samples (invert the 12/12-disabled evidence).
- **Clean teardown:** trigger Show Profile Picker mid-`.opening` (slow VM peer) → returns to picker; the tracked ssh child is reaped (no orphan); no `.restartRequired` on the happy path; a non-quiescent cancel routes to `.restartRequired` (not a silent leak).
- **Sheet modality preserved:** with the credential sheet up, the item behaves as today; the sheet's **Cancel** still exits credential entry.
- **Enables #35 GUI repro:** a replacement profile can now be requested while connecting, making the queued-replacement-around-connect-fatal path (#35) GUI-reproducible.
- **No `.syncing` regression:** navigation remains blocked during `.syncing` (unchanged).

## 8. Invariants

- Navigation is available in every phase **except** `.syncing`, now including `.opening` pre-sheet.
- A leave never leaks the connect child: it goes through `connection_cancel` reap + the quiescence gate (`.restartRequired` on unprovable quiescence).
- No vendored-blob change; no new interruption mechanism (this is connect-phase abandon, not scan interruption).
- Credential-sheet modality unchanged.

## 9. Open questions

- Is the responder/validation target established at window creation or only at first reconcile render? (Determines the one-line-vs-small-refactor size of step 1 — confirm in `ReconcileWindowController`'s window setup.)
- Does the toolbar item need the same responder fix as the menu item, or does it validate through a different path (`canPerformToolbarAction`)? Verify both light up.
- Should the greyed *whole-row* toolbar appearance during "Opening…" be revisited, or only the Profiles/picker control? Scope to the picker control; leave sync-relevant controls (Go/Diff) disabled during connect.

## 10. Recommendation

Ship in 0.3.1 as a scoped UX fix: **(B)** fix the validation-target timing so the already-correct enablement predicates take effect during `.opening`, and route the leave through the existing #35 connect-cancel reap + quiescence gate. No blob change, no new mechanism. Do not expand #35 / PR #37 for this; it is a separate, small responder-timing fix plus a teardown-path confirmation.
