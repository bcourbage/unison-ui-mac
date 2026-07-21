# Manual test plan — connection lifecycle (issue #6, steps 1–3)

Covers the behaviors the headless autotest harness can't drive. The
**non-interactive close-on-sync-end + ssh-child reap** path is already
verified live (see PR #7); everything below still needs a hands-on pass
before merge.

Estimated time: ~20–30 min.

---

## 0. Prerequisites

### Build & run the Debug build (has the autotest hooks; not required here but consistent)

```sh
cd ~/Documents/Sources/unison-ui-mac
make build
open .build/derived/Build/Products/Debug/unison-ui-mac.app
```

Or test the release build you'll actually ship — both contain the step-2b
logic; only the `UNISON_AUTOTEST_*` hooks are Debug-only.

### Two SSH profiles

You need **both** auth styles, because the whole point of 2b is that the
close policy differs by auth cost:

1. **Key/agent profile (non-interactive)** — e.g. a profile to Demeter with
   `sshargs = -i /Users/bcourbage/.ssh/Demeter` and
   `servercmd = /opt/homebrew/bin/unison`. Connecting shows **no** password
   sheet.
2. **Password profile (interactive)** — a profile whose SSH connection
   **prompts for a password**. Easiest ways to get one:
   - Point at a host/account that has no key installed, or
   - Temporarily rename your key so the agent can't offer it (e.g.
     `sshargs = -i /nonexistent` forcing password fallback), or
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
ssh demeter 'rm -rf /tmp/u2b-remote && mkdir -p /tmp/u2b-remote && date > /tmp/u2b-remote/b.txt'
```

Point the profile's roots at these (`ssh://demeter//tmp/u2b-remote`).

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
pgrep -af ssh | grep -i demeter          # adjust host
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

**PASS =** no errors, no spurious ssh processes.

### TC8 — No ssh-child pile-up across opens (leak regression)

1. From the picker, open the **key** profile, sync, return to Profiles.
2. Repeat 3–4 times with different profiles (or the same one).
3. After each return to the picker, check `pgrep -af ssh | grep -i <host>`.

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

A transport that wedges mid-sync (connection died) can't be unblocked in-process — this test is about the *hint*, not a rescue.

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
then, so the scan needs its own bound.

> **Terminology correction (2026-07-20).** An earlier draft of TC11 called the
> unattended public-key case a "wedge". That was wrong. Re-examination showed:
> a public-key/`BatchMode` profile that can't authenticate surfaces a
> **credential sheet** (`connection_prompt` returns a prompt); the app then
> correctly **waits for input** — the toolbar is disabled because a **modal
> sheet** is open, and the connect watchdog is (correctly) disarmed so it can't
> time out the user's typing. That is a legitimate credential-sheet wait, **not**
> a wedge. The confirmed original defect is the **no-sheet, post-credential-
> submission** hang, which occurs in `init2` on a dead/wedged transport.

**TC11a — deterministic post-auth init2 wedge (controlled proxy).** Because the
auth-failure path parks at a credential sheet, the reliable *unattended* proxy
for the real wedge is a **key profile** (authenticates via key, no prompt) whose
transport freezes mid-scan:

1. Open the **key** profile; it authenticates (no sheet) and enters the scan.
2. On the remote, freeze the server mid-scan: `kill -STOP $(pgrep -f "server __new-rpc-mode")`.
3. **Expect (UI):** within the scan-stall bound (**120 s** in production; the
   detector resets on every scan-status message, so a healthy scan is never
   killed) the window shows *"Couldn't reach the remote (no scan progress for
   N seconds)… quit Unison and reopen"* and the app enters **restart-required**.
4. **Expect:** **no credential sheet**; the toolbar `Stop` **is** enabled during
   the wedge (no modal sheet), and clicking it returns to the picker.
5. **Recovery:** Quit (clean) + reopen connects fresh and scans; on the remote,
   `kill -CONT` / `kill -9` the frozen server afterward.
6. **Same-process-after-Stop:** if you hit Stop (→ picker) and immediately open
   another profile, it shows "Waiting for the previous operation to finish…"
   and then, when the detector fires, transitions to restart-required — the
   abandoned scan's detector is **retained** (abandonment is not idleness), so a
   replacement profile never waits forever.

**TC11b — interactive auth failure (live).** A real password profile with a
wrong/failing password. Enter the wrong password.
1. **Expect:** the credential sheet is re-presented (or an auth-failure error);
   this is a legitimate credential wait, not a wedge. Cancelling returns to the
   picker.
2. If a run somehow gets *past* auth and then wedges in the scan, the init2
   scan-stall detector bounds it exactly as TC11a. **Identify which phase TC11b
   occupies** and confirm it has a bounded terminal path.

**PASS =** a post-auth transport wedge reaches restart-required within the scan
timeout (never an indefinite "Opening…"/"Looking for changes…"); `Stop` is
enabled and effective in the no-sheet wedge; a waiting replacement profile is
carried to restart-required rather than stranded; and quit+reopen recovers
cleanly. A credential-sheet wait is expected behavior, not a failure.

> **Fix (issue #24, in a draft PR — not yet merged).** A Swift-only,
> operation-bound init2/scan stall detector (`ScanStallTimer`): armed for remote
> scans via `pendingScan.didSet`, reset on scan-status delivery, and on expiry it
> fails the exact scan op with quiescence UNPROVEN → coordinator restart-required.
> Bound to the retained `pendingScan` op token, so it survives UI abandonment.
> No C/OCaml/blob change. `Stop`-during-connect reliability is a separate
> follow-up (the control is unreliable behind a modal sheet, and
> `connection_cancel` cannot interrupt a wedged op on the serial queue).

---

## Known limitations (do NOT file as bugs — tracked in issue #6)

- **Recovering a wedged sync requires quit + reopen.** A sync on a connection
  that died (sleep / network drop / frozen remote) can't be unblocked
  in-process — proven infeasible (a `select()` blocked on a dead connection
  can't be woken from another thread by closing the fd or killing ssh). The
  stall hint (TC10) detects it after 45 s and points the user to quit +
  reopen, which is clean now. SSH keepalive prevention is deferred.
- **Password re-prompt after sleep:** a held connection dies on sleep, so a
  later reopen re-prompts. Keychain/ControlMaster caching is a separate
  future item.

---

## Results

| Case | Behavior | PASS / FAIL | Notes |
|---|---|---|---|
| TC1 | non-interactive close on sync-end | | |
| TC2 | non-interactive Rescan reopens silently | | |
| TC3 | interactive held through sync-end | | |
| TC4 | interactive Rescan no re-prompt | | |
| TC5 | interactive closes on leave | | |
| TC6a | Keep Syncing | | |
| TC6b | Abort & Close | | |
| TC6c | Close (let it run) | | |
| TC7 | local-only sanity | | |
| TC8 | no ssh pile-up | | |
| TC9a | gate: pick during background sync | | |
| TC9b | gate: pick during scan | | |
| TC10 | wedged-sync stall hint | PASS | orange hint at 45s, responsive, clean quit+reopen |
| TC11a | post-auth init2 wedge (frozen-remote proxy) | PASS (with fix) | scan-stall detector fires at 120s → restart-required; Stop enabled+effective; same-process-after-Stop carries replacement to restart-required; clean reopen. (Earlier "auth-failure wedge" reclassified: that is a benign credential-sheet wait.) |
| TC11b | interactive auth failure | pending live (needs password entry) | expected: credential-sheet wait, not a wedge; confirm phase + bounded terminal path |
