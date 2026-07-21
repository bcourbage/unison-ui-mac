# Manual test plan — connection lifecycle (issue #6 steps 1–3; issue #24)

Covers the behaviors the headless autotest harness can't drive. Some cases now
have recorded evidence (see **Evidence provenance** at the bottom, which
separates *live*, *automated*, and *pending* results); the interactive cases
still need a hands-on pass with a human entering the SSH password. Nothing here
gates a merge on its own — treat it as the live-validation record.

Estimated time for a full hands-on pass: ~20–30 min.

Placeholders used below (substitute your own): `<repo>` = the unison-ui-mac
working copy; `<remote-host>` = the SSH host for the key/non-interactive
profile; `<pw-host>` = the SSH host for the password/interactive profile;
`~/.ssh/<key>` = your SSH private key; `<server-unison>` = the remote `unison`
binary path (e.g. a Homebrew path). Never record a real password anywhere.

---

## 0. Prerequisites

### Build & run

Debug build (has the `UNISON_AUTOTEST_*` hooks; step-2b/issue-24 logic is
identical in both configs):

```sh
cd <repo>
make build
open .build/derived/Build/Products/Debug/unison-ui-mac.app
```

Release build (what actually ships — use this for the production-bound checks):

```sh
cd <repo>
make build CONFIG=Release
open .build/derived/Build/Products/Release/unison-ui-mac.app
```

Only the `UNISON_AUTOTEST_*` hooks are Debug-only; the connection lifecycle and
the issue-24 scan-stall detector are present and identical in both.

### Two SSH profiles

You need **both** auth styles, because the whole point of 2b is that the
close policy differs by auth cost:

1. **Key/agent profile (non-interactive)** — e.g. a profile to `<remote-host>`
   with `sshargs = -i ~/.ssh/<key>` and `servercmd = <server-unison>`.
   Connecting shows **no** password sheet.
2. **Password profile (interactive)** — a profile whose SSH connection
   **prompts for a password**. Easiest ways to get one:
   - Point at a host/account that has no key installed, or
   - Temporarily force password fallback (e.g. `sshargs = -i /nonexistent`), or
   - Any remote where you normally type a password.
   The test only needs the connect to pop the password sheet once.

### A local-only profile

A plain folder-to-folder profile (both roots local paths) for the sanity case.

### Test data

For each remote profile, use two scratch dirs with a difference to sync, e.g.:

```sh
# local side
rm -rf /tmp/u2b-local && mkdir -p /tmp/u2b-local && date > /tmp/u2b-local/a.txt
# remote side (adjust host)
ssh <remote-host> 'rm -rf /tmp/u2b-remote && mkdir -p /tmp/u2b-remote && date > /tmp/u2b-remote/b.txt'
```

Point the profile's roots at these (`ssh://<remote-host>//tmp/u2b-remote`).

### Observation tools (keep both open in a second Terminal)

**A. Live app log** (shows the connection-lifecycle lines):

```sh
/usr/bin/log stream --level debug \
  --predicate 'subsystem == "net.courbage.unison-ui-mac"' --style compact
```

Watch for these lines:
- `init1 complete (needs_prompt=…)`
- `connection: no more prompts …` (non-interactive) **or** `connection prompt: …` (interactive)
- `sync complete — closing non-interactive connection` **or** `sync complete — holding interactive-auth connection until leave`
- `closeConnection (<reason>) -> status 0`
- `rescan: connection was closed — reopening …` **or** `rescan: re-running init2 …`

**B. SSH children** (should appear on connect, vanish on close). Re-run after each step:

```sh
pgrep -af ssh | grep -i <remote-host>          # adjust host
```

---

## Test cases

Fill in PASS/FAIL in the table at the bottom.

### TC1 — Non-interactive: connection closes on sync-end *(re-confirm)*

1. Open the **key** profile.
2. Watch it scan, then click **Go** (sync). Wait for "Synchronization complete".
3. **Expect (log):** `sync complete — closing non-interactive connection` then `closeConnection (sync complete, non-interactive) -> status 0`.
4. **Expect (ssh):** `pgrep` shows the ssh child **gone** right after the sync finishes (while the results window is still open).
5. **Expect (files):** the difference propagated both ways.

**PASS =** connection closed while the window is still open + ssh child reaped.

### TC2 — Non-interactive: Rescan silently reopens after the close

1. Continuing from TC1 (results window still open, connection already closed).
2. Click **Rescan**.
3. **Expect (log):** `rescan: connection was closed — reopening …`, then a fresh `init1 complete` / `no more prompts` / `init2 complete`.
4. **Expect (UI):** **no** password sheet appears; the scan completes normally.
5. **Expect (ssh):** an ssh child reappears during the rescan.

**PASS =** Rescan works with no prompt and repopulates the list.

### TC3 — Interactive: connection is HELD through sync-end

1. Open the **password** profile. Enter the password when the sheet appears.
2. **Expect (log):** `connection prompt: …` before the scan.
3. Sync (Go), wait for completion.
4. **Expect (log):** `sync complete — holding interactive-auth connection until leave` (NOT the "closing" line).
5. **Expect (ssh):** the ssh child **persists** after the sync completes (window still open).

**PASS =** connection is *not* closed on sync-end for a password profile.

### TC4 — Interactive: same-session Rescan does NOT re-prompt

1. Continuing from TC3 (connection held).
2. Click **Rescan**.
3. **Expect (log):** `rescan: re-running init2 …` (reuse path, NOT "reopening").
4. **Expect (UI):** **no** password sheet — the held connection is reused.

**PASS =** Rescan reuses the connection with no second password prompt.

### TC5 — Interactive: connection closes on leave

1. Continuing from TC4. Click **Profiles** (or close the window) to return to the picker.
2. **Expect (log):** `closeConnection (left profile) -> status 0`.
3. **Expect (ssh):** ssh child reaped after returning to the picker.

**PASS =** the held connection closes when you leave the profile.

### TC6 — Mid-sync window-close choices

Use a profile + data big enough that the sync runs for a few seconds (e.g.
a directory of several large files) so you can act mid-sync. Repeat the
sync before each sub-case.

**TC6a — Keep Syncing:** start a sync, click the window's close button
mid-sync, choose **Keep Syncing**.
- **Expect:** window stays open, sync continues, no close in the log.

**TC6b — Abort & Close:** start a sync, close mid-sync, choose **Abort & Close**.
- **Expect (log):** the abort, then once the worker unwinds,
  `background sync complete — closing deferred connection` and
  `closeConnection (background sync complete after leave) -> status 0`.
- **Expect (ssh):** ssh child reaped after the abort settles.

**TC6c — Close (let it run):** start a sync, close mid-sync, choose
**Close (let it run)**.
- **Expect:** window closes, sync keeps running in the background; when it
  finishes naturally you see `background sync complete — closing deferred
  connection` and `closeConnection … -> status 0`.
- **Expect (ssh):** ssh child persists until the background sync finishes,
  then is reaped.

**PASS =** each choice lands the connection correctly (none tears out a
running transport; both closing choices reap the child at the right time).

### TC7 — Local-only profile (sanity)

1. Open the **local-only** profile, sync, then leave.
2. **Expect (log):** `closeConnection (…) -> status 0` is harmless (status 0)
   and there is **no** error; no ssh child ever appears.
3. **Expect:** the scan-stall detector never arms (it is remote-only).

**PASS =** no errors, no spurious ssh processes.

### TC8 — No ssh-child pile-up across opens (leak regression)

1. From the picker, open the **key** profile, sync, return to Profiles.
2. Repeat 3–4 times with different profiles (or the same one).
3. After each return to the picker, check `pgrep -af ssh | grep -i <remote-host>`.

**PASS =** at most one ssh child at a time; **zero** while sitting on the
picker. (Pre-fix, these accumulated for the life of the app.)

### TC9 — Engine-idle gate: pick a profile while the engine is still busy (step 3)

This is the step-3 behavior. Two sub-cases.

**TC9a — pick while a background sync is running:**
1. Open a **key** profile with enough data that the sync runs a few seconds.
2. Start the sync, close the window mid-sync, choose **Close (let it run)** → you're back at the picker with the sync still running in the background.
3. Immediately pick **another** profile.
4. **Expect (UI):** the new profile's window opens showing **"Waiting for the previous operation to finish…"** (its normal connecting spinner), and does **not** connect yet.
5. **Expect (log):** `engine busy — queueing open of '…'`, then when the background sync finishes: `background sync complete …`, `closeConnection … -> status 0`, `engine idle …`, `engine idle — running queued profile open`, then the new profile's `init1 complete` / scan.
6. **Expect:** the new profile then scans normally; the first profile's connection was closed (not clobbered).

**TC9b — pick while a scan is running:**
1. Open a profile whose scan takes a few seconds (large tree).
2. While it's still scanning, click **Stop** (or close the window) to return to the picker.
3. Immediately pick another profile.
4. **Expect:** same as above — the new open waits for the abandoned scan to finish, then starts. No crash, no double-drive.

**PASS =** the second open waits for the engine to go idle, then opens cleanly; the first profile's connection is closed, not leaked or clobbered.

### TC10 — Wedged-sync stall hint (steps 4–5)

A transport that wedges mid-*sync* (connection died) can't be unblocked in-process — this test is about the *hint*, not a rescue. (This is the **transfer** phase; the scan phase is covered separately by TC11.)

1. Open a **remote** profile with enough data to transfer for a while (a few hundred MB+).
2. Start the sync. While it's transferring, kill the connection in a way that hangs rather than cleanly errors — e.g. on the remote host, `kill -STOP $(pgrep -f "server __new-rpc-mode")` to freeze the remote server (or pull the network / sleep the remote).
3. Wait ~45 seconds with no progress.
4. **Expect (UI):** the summary turns into an orange warning: *"Sync appears stuck: no progress for 45 seconds. The remote connection was likely lost. Quit Unison and reopen the profile to recover…"* The window stays responsive (you can still click around, quit).
5. **Expect (log):** `sync stalled — no progress for 45s; surfacing quit+reopen hint`.
6. **Recovery:** Quit Unison (should quit cleanly, no hang) and reopen the profile — it should connect fresh and work.
7. **No false positive:** a healthy but slow sync that keeps making progress must NOT trip the hint (progress resets the 45 s timer).

**PASS =** the hint appears only on a genuine stall, the app stays responsive, and quit+reopen recovers cleanly. (On the remote, `kill -CONT` / `kill -9` the frozen server afterward.)

---

### TC11 — Post-authentication transport wedge during scan (issue #24)

A remote connection whose transport dies or freezes **after authentication**
must not leave the app hung with no recovery. The wedge lands in **`init2`**
(the scan / update-detection phase): `connection_end` does not do a blocking
server round-trip (it returns `status 0` regardless of server state), so the
first round-trip that can hang is the scan. The connect watchdog is disarmed by
then, so the scan needs its own bound — which is what the issue-24 detector adds.

> **Terminology correction (2026-07-20).** An earlier draft of TC11 called the
> unattended public-key case a "wedge" and described a deterministic
> `BatchMode` auth failure. That was wrong. Re-examination showed: a
> public-key profile that can't authenticate surfaces a **credential sheet**
> (`connection_prompt` returns a prompt); the app then correctly **waits for
> input** — the toolbar is disabled because a **modal sheet** is open (its
> **Cancel** button is still an in-app exit), and the connect watchdog is
> disarmed so it can't time out the user's typing. That is a legitimate
> credential-sheet wait, **not** a wedge. The confirmed defect is the
> **no-sheet, post-credential-submission** hang, which occurs in `init2` on a
> dead/wedged transport.

> **Proxy caveat.** TC11a below freezes a healthy server mid-scan to produce a
> *controlled proxy* for a post-auth transport wedge. It reliably reproduces
> the **init2 no-progress** condition and exercises the detector, but it is
> **not proof of identical root cause** with the original field incident (an
> inconsistently reproduced, misconfigured-auth report). Treat TC11a as
> "the detector correctly bounds a post-auth init2 stall", not as "the original
> incident is reproduced".

**TC11a — deterministic post-auth init2 wedge (controlled proxy).** Because the
auth-failure path parks at a credential sheet, the reliable *unattended* proxy
for a post-auth wedge is a **key profile** (authenticates via key, no prompt)
whose transport freezes mid-scan:

1. Open the **key** profile; it authenticates (no sheet) and enters the scan.
2. On the remote, freeze the server mid-scan: `kill -STOP $(pgrep -f "server __new-rpc-mode")`.
3. **Expect (UI):** within the scan-stall bound (**120 s** in production; the
   detector resets on every scan-status message, so a healthy scan is never
   killed) the window shows *"Couldn't reach the remote (no scan progress for
   N seconds)… quit Unison and reopen"* and the app enters **restart-required**.
4. **Expect:** **no credential sheet**; because no modal sheet is up, the
   toolbar `Stop` is enabled during the wedge.
5. **`Stop` semantics (important):** clicking `Stop` performs **visible-session
   abandonment** — it returns you to the picker. It does **not** unwind the
   in-flight `init2` operation (the wedged round-trip on the serial queue is not
   interruptible in-process). The scan-stall detector is deliberately
   **retained** across this abandonment, so it still fires for the abandoned op
   and drives it to **restart-required**. `Stop` is therefore *not* an engine
   terminal action; the detector is what terminates the operation.
6. **Recovery:** Quit (clean) + reopen connects fresh and scans; on the remote,
   `kill -CONT` / `kill -9` the frozen server afterward.
7. **Same-process-after-Stop:** if you hit `Stop` (→ picker) and immediately open
   another profile, it shows "Waiting for the previous operation to finish…"
   and then, when the retained detector fires, transitions to restart-required —
   because the abandoned op's detector is retained (abandonment is not
   idleness), a replacement profile is carried to restart-required rather than
   stranded waiting forever.

**TC11b — interactive auth failure (live).** A real password profile with a
wrong/failing password. Enter the wrong password.
1. **Record which happens:** the credential sheet is re-presented, an
   auth-failure error is surfaced, or the connect proceeds into scan. Any of the
   first two is a legitimate credential wait/error, **not** a wedge.
2. **Confirm** `Cancel` on the sheet returns cleanly to the picker.
3. If a run somehow gets *past* auth and then wedges in the scan, the init2
   scan-stall detector bounds it exactly as TC11a. **Identify which phase TC11b
   occupies** and confirm it has a bounded terminal path. Never conflate a modal
   credential wait with a transport wedge.

**PASS =** a post-auth transport wedge reaches restart-required within the scan
timeout (never an indefinite "Opening…"/"Looking for changes…"); in the
no-sheet wedge `Stop` returns to the picker (visible-session abandonment) while
the retained detector carries the op to restart-required; a waiting replacement
profile is carried to restart-required rather than stranded; and quit+reopen
recovers cleanly. A credential-sheet wait is expected behavior, not a failure.

> **Fix (issue #24, in a draft PR — not yet merged).** A Swift-only,
> operation-bound init2/scan stall detector (`ScanStallTimer`): armed for remote
> scans via `pendingScan.didSet`, reset on scan-status delivery, and on expiry it
> fails the exact scan op with quiescence UNPROVEN → coordinator restart-required.
> Bound to the retained `pendingScan` op token, so it survives UI abandonment.
> No C/OCaml/blob change. True in-process interruption of an already-wedged op
> is a separate follow-up (`connection_cancel` cannot interrupt a wedged op on
> the serial queue).

---

## Known limitations (do NOT file as bugs — tracked in issues #6 / #24)

- **Recovering a wedged sync/scan requires quit + reopen.** A connection that
  died (sleep / network drop / frozen remote) can't be unblocked in-process —
  proven infeasible (a `select()` blocked on a dead connection can't be woken
  from another thread by closing the fd or killing ssh). The sync-phase stall
  hint (TC10, 45 s) and the scan-phase detector (TC11, 120 s) both detect it and
  point the user to quit + reopen, which is clean now. SSH keepalive prevention
  is deferred.
- **`Stop` / sheet `Cancel` do not unwind a wedged engine op.** Both are
  in-app UI exits (abandonment / cancelling credential entry); neither
  interrupts an operation already blocked on a serial-queue round-trip. True
  in-place cancellation is the tracked follow-up.
- **Password re-prompt after sleep:** a held connection dies on sleep, so a
  later reopen re-prompts. Keychain/ControlMaster caching is a separate
  future item.

---

## Results

| Case | Behavior | PASS / FAIL | Notes |
|---|---|---|---|
| TC1 | non-interactive close on sync-end | PASS | live + automated regression |
| TC2 | non-interactive Rescan reopens silently | | |
| TC3 | interactive held through sync-end | pending live (needs password entry) | |
| TC4 | interactive Rescan no re-prompt | pending live (needs password entry) | |
| TC5 | interactive closes on leave | pending live (needs password entry) | |
| TC6a | Keep Syncing | | |
| TC6b | Abort & Close | | |
| TC6c | Close (let it run) | | |
| TC7 | local-only sanity (detector never arms) | PASS | live + automated regression |
| TC8 | no ssh pile-up | PASS | live regression |
| TC9a | gate: pick during background sync | | |
| TC9b | gate: pick during scan | | |
| TC10 | wedged-sync stall hint | PASS | orange hint at 45s, responsive, clean quit+reopen |
| TC11a | post-auth init2 wedge (frozen-remote proxy) | PASS (with fix) | detector arms + fires → restart-required; `Stop` = visible-session abandonment (returns to picker, does NOT unwind init2), retained detector drives restart-required; same-process-after-Stop carries replacement to restart-required; clean targeted quit; app-owned child reaped; fresh reopen succeeds. Controlled proxy, not proof of identical root cause with the original incident. (See Evidence provenance for whether the Release/120 s live confirmation is recorded.) |
| TC11b | interactive auth failure | partial live; wrong-password entry pending | Confirmed live: opening the password profile surfaces a **modal credential sheet** ("Permission denied (publickey)" → Password field, Cancel/OK) over an "Opening…" summary with the toolbar disabled *because the sheet is modal* — a credential-sheet wait, NOT a wedge. **Cancel** returns cleanly to the Profiles picker (no sheet, no ssh child leaked). Still pending (needs password entry): whether a WRONG password re-presents the sheet, surfaces an error, or proceeds into scan. |

---

## Evidence provenance

Results above come from three distinct sources — do not conflate them:

- **Automated (deterministic unit/integration tests, run in CI):** the
  coordinator state machine and `ScanStallTimer` behaviors — arm/reset/disarm,
  operation-bound firing, restart-required transition, late-completion
  suppression, retention across abandonment, healthy-scan control. These use an
  injected fake scheduler (no real timeouts) and run on every build.
- **Live (hands-on, recorded this pass):** TC1/TC7/TC8 regression; TC10 stall
  hint; TC11a frozen-remote proxy on the **Release** build at the production
  **120 s** bound (scan detector arms, restart-required at the bound, clean
  targeted quit, app-owned child reaped, fresh reopen succeeds); healthy-scan
  control (max inter-status silence observed ≈1 s against the 120 s bound → no
  false fire). Caveat: the healthy control was a fast scan with a large margin;
  a genuinely ~120 s-silent healthy scan was not constructed. TC11b non-password
  parts: the credential sheet appears (modal, toolbar disabled because the sheet
  is up — not a wedge) and its Cancel returns cleanly to the picker with no ssh
  child leaked.
- **Pending (require a human to type the SSH password — cannot run
  unattended):** the password-entry outcomes of TC3, TC4, TC5 (correct
  credentials: held connection, rescan reuse, close on leave) and TC11b (wrong
  credentials: re-present vs error vs proceed into scan).
