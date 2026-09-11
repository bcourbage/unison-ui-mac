# Manual test plan — connection lifecycle (issue #6 steps 1–3; issue #24)

Covers the behaviors the headless autotest harness can't drive. Some cases have
recorded evidence (see **Evidence provenance** at the bottom, which tags each
result *automated*, *live*, or *not yet run*). Interactive cases require a
hands-on pass with a human entering the SSH password. Treat this as the
live-validation record; nothing here gates a merge on its own.

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

## Supplementary Debug automation (development aid, not RC acceptance)

This section is for exercising some of these behaviors quickly on a **Debug**
build during development. It is **not** release acceptance. The release checklist
requires every applicable case to be run against the **signed RC**, and the hooks
below are `#if DEBUG` only, so they do not exist in that artifact at all. Signed-RC
acceptance therefore needs a person, or suitable UI automation, driving the actual
signed build. A case you cannot automate is still not **Not Applicable**; it needs
a hands-on or UI-automation pass against the RC.

**Coverage is partial even on Debug.** The hooks only select a profile, cycle the
first row's directions, and start a sync. They do **not** exercise TC6's
window-close choices, TC9's picking a second profile while the engine is busy, or
TC14's full launch / refuse / relaunch sequence; those need real interaction on any
build. Treat what follows as a fast smoke aid for the flows it does reach, not a
substitute for running each case as written.

**Drive with the app's own autotest hooks, in preference to scripted UI
automation.** A Debug build exposes three environment hooks (compiled out of
Release). Launch the inner
binary directly so it inherits the environment; `open(1)` does not pass
environment variables and only refocuses an already-running instance, so kill
any running copy first (`pkill -x unison-ui-mac`).

```sh
make build   # Debug; the hooks are #if DEBUG only
bin=.build/derived/Build/Products/Debug/unison-ui-mac.app/Contents/MacOS/unison-ui-mac
UNISON_AUTOTEST_PROFILE=<name> "$bin" &
```

- `UNISON_AUTOTEST_PROFILE=<name>` selects that profile and starts its
  connection and scan at launch, with no picker click.
- `UNISON_AUTOTEST_RI_OPS` cycles the first row through its direction overrides.
- `UNISON_AUTOTEST_SYNC` starts the sync automatically once the scan reconciles.

**Observe with screenshots, not the log.** Under `os_log` the lifecycle lines
render their interpolated values as `<private>`, and lifting that redaction
needs a sudo `log config` profile, so the `log stream` command in the
Observation tools section is for a hands-on operator and is otherwise unreliable
for content. For an unattended run the window is the observable:
`screencapture -x -o f.png`, then read the PNG. The status line, toolbar control
titles, and the restart-required dialog text are all legible that way.

**Wedge the transport yourself for the stall cases (TC10, TC11).** A key profile
authenticates with no prompt, so the freeze is a plain shell command over the
same key. Run the `kill -STOP` and the `kill -CONT` / `kill -9` cleanup exactly
as those cases document, and freeze the remote unison *server* (not sshd) so the
socket stays alive at the SSH layer and the app sees a genuine post-auth wedge.

**`pgrep` gotcha.** The working-directory path contains `unison-ui-mac`, so a
local `pgrep -af unison` matches your own shell. Use `pgrep -x unison-ui-mac`
(exact process name) or a bracket pattern (`pgrep -f '[u]nison-ui-mac'`) for a
true count of the app or its ssh children.

### The interactive-password cases stay human-run

TC3, TC4, TC5, TC12, and TC13 (the run-last group) need a person typing a real
password and must not be driven unattended, for two reasons:

1. **Credential rule.** They require the correct real password typed into the
   sheet, which an automated pass does not supply.
2. **Timing, and unverified failure causes.** A drive loop that screenshots,
   locates the field, sends keystrokes, and clicks OK across separate tool calls
   is far slower than a person typing, and a slow entry can miss the remote's own
   authentication window and surface a "Couldn't connect... Connection closed"
   message. Do not assume that is the cause: the connect watchdog is disarmed
   before the password sheet is shown (`disarmConnectWatchdog()` in
   `AppDelegate`), so the message alone does not establish why a given timeout
   happened, and a genuine remote-auth timeout remains possible. Record any
   unexpected failure with its evidence and investigate it rather than dismissing
   it; do not widen a deadline without evidence of what it fixes. Hand these
   cases to the human operator, and do not co-drive the GUI while someone is
   using the Mac.

---

## Test cases

Fill in PASS/FAIL in the table at the bottom.

The cases are grouped by whether a person has to type a password. Run the
non-interactive cases first (TC1, TC2, TC6, TC7, TC8, TC9, TC10, TC11, TC14),
then the interactive-password cases last (TC3, TC4, TC5, TC12, TC13), which are
collected under **Interactive-password cases (run last)** at the end. Case
numbers are kept stable so the release checklist and cross-references still
resolve, which is why the interactive numbers appear out of sequence there.

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
2. **Expect (log):** the terminal sends the coordinator **directly to idle** —
   there is **no** connection to close, so **no** `closeConnection` line appears
   (a local-only session's `beginClose` goes straight to `finishToIdle`); no
   error; no ssh child ever appears.
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
2. While it's still scanning, click **Profiles** (or close the window) to return to the picker.
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

Uses a **key** profile (authenticates with no prompt) whose transport freezes mid-scan.

**Setup — make the scan last long enough to freeze it mid-way.** A fast scan finishes before you can run the freeze command. Extend it by forcing content hashing: set `fastcheck = false` in the profile (and/or `touch` the synced files so contents are rehashed), or point the profile at a large enough replica. Confirm the reconcile window sits in "Looking for changes" / "Waiting for changes from server" while you run step 2.

1. Open the **key** profile; it authenticates (no sheet) and enters the scan.
2. While the scan is running, freeze the server on the remote: `kill -STOP $(pgrep -f "server __new-rpc-mode")`.
3. **Expect:** within **120 s** the window shows *"Couldn't reach the remote (no scan progress for N seconds)… quit Unison and reopen"* and the app enters **restart-required**. No credential sheet.
4. During the frozen scan the leave control is **Profiles**; the **Stop** control is **disabled and neutral** (its title stays "Stop" and it does not move) — Stop is sync-only (issue #117). In v0.5.1 the in-place scan-interruption machinery has been **removed entirely** (#94): there is no policy gate or `.interruptingScan` state left, so **"Stop Scan"** never appears. (v0.4.0 shipped an in-place Stop Scan for qualified direct-SSH scans past remote-wait; it was withdrawn because forced-interruption engine reuse was never proven safe. See issue #53 / #94 and the CHANGELOG. Do not expect it here.)
5. Click **Profiles** → returns to the picker; the scan winds down in the background; it is **not** cancelled; the retained scan-stall detector still drives the abandoned op to **restart-required**.
6. **Recovery:** Quit + reopen connects fresh and scans. On the remote, `kill -CONT` / `kill -9` the frozen server afterward.
7. After returning to the picker via **Profiles**, immediately open another profile: it shows *"Waiting for the previous operation to finish…"*, then transitions to **restart-required** when the retained detector fires.

**PASS =** a post-auth transport wedge reaches restart-required within the scan timeout (never an indefinite "Opening…"/"Looking for changes…"); **Profiles** returns to the picker (without cancelling the scan) while the retained detector carries the op to restart-required; the **Stop** control stays disabled and "Stop Scan" is never offered; a waiting replacement profile is carried to restart-required rather than stranded; and quit+reopen recovers cleanly.

### TC14 — CLI option isolation across profile opens and rescans (issue #122)

Verifies, on the signed release candidate, that command-line option overrides
passed at launch stay bound to the launch's own profile and do not silently
reshape other profiles opened through the GUI. It exercises upstream's per-load
command-line reparse and the app's option-isolation gate end to end; the unit
tests cover only the Boolean gate. No synchronization is applied.

**Setup.** In one Terminal, create a uniquely-named throwaway directory so nothing
real is touched, and point the Unison directory and two local roots inside it:

```sh
TC14="$(mktemp -d)"
export UNISON="$TC14/config"
mkdir -p "$TC14/A/Documents" "$TC14/B"
printf 'x' > "$TC14/A/Documents/inside.txt"   # a change INSIDE Documents
printf 'x' > "$TC14/A/outside.txt"            # a change OUTSIDE it
```

Root **B** stays empty, so the only differences between the two roots are one
change inside `Documents` and one outside it. Create two local-only profiles,
`first` and `second`, **both** with roots `"$TC14/A"` and `"$TC14/B"` and **no**
`path`, `include`, or `ignore` preferences, so `-path` is the only thing that can
narrow the scan.

Before starting: **quit** any running copy of the app (a running instance would
serve the request instead, changing what is exercised), and make sure **Default
interface** is **Graphical** (a saved Text preference would send `first` to the
text interface). Run the RC's **in-bundle launcher explicitly** so the test
exercises the RC and not an installed release or the Homebrew formula; quote its
path, for example
`"/Volumes/…/unison-ui-mac.app/Contents/SharedSupport/bin/unison"`. If you test a
linked `unison`, first confirm with `readlink`/`-version` that it resolves into
the RC bundle. Record that path. Run **every** step from this same Terminal so the
disposable `UNISON` export stays in effect.

1. **Launched restriction applies.** Run `"<RC launcher>" first -path Documents`.
   **Expect:** `first` opens and scans, and the reconcile results list **only** the
   change inside `Documents` (`Documents/inside.txt`); the outside change
   (`outside.txt`) is absent.
2. **Other profile refused.** From the picker in that same instance, open
   `second`. **Expect:** it is refused with *"Reopen the app to open second"*; the
   picker stays and `second` does not open.
3. **Rescan keeps the restriction.** Back at the picker, reopen `first`, then
   invoke **Rescan**. **Expect:** its results are again limited to `Documents`
   (the launch override is preserved for the original profile and its rescans).
4. **Normal relaunch clears it.** Quit, then from the **same Terminal** (with
   `UNISON` still exported) run `"<RC launcher>"` with **no arguments**, and open
   `second`. Do not relaunch from Finder: a Finder launch would not inherit
   `UNISON` and could open your real configuration instead. **Expect:** `second`
   scans both roots in full, listing the outside change (`outside.txt`) as well as
   the one inside `Documents`; the earlier `-path` override is gone.

Record: the RC `MARKETING_VERSION (CURRENT_PROJECT_VERSION)`, the macOS version,
the exact launcher path, and pass/fail evidence for each step.

**PASS =** the launched `-path Documents` scan is limited to `Documents`; opening
a different profile is refused with the reopen message; a rescan of `first` stays
limited to `Documents`; and after a normal relaunch `second` scans its full root
without the override.

### Interactive-password cases (run last)

These cases need a person to type a real password (or answer a host-key
prompt), so they run after every non-interactive case. Their numbers are kept
stable for cross-references, so they are out of sequence here by design.

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

### TC12 — Interactive auth failure (live)

A real password profile with a wrong/failing password.

1. Enter the **wrong** password. **Expect:** the credential sheet is re-presented **once**, carrying the "Permission denied, please try again." message, and entering the correct password authenticates on that single entry (issue #63, fixed).
2. Confirm **Cancel** on the sheet returns cleanly to the picker.
3. If a run gets past auth and then wedges in the scan, confirm the init2 scan-stall detector bounds it to **restart-required** as in TC11.

**PASS =** a wrong password re-prompts exactly once (no phantom extra prompt), the correct password then authenticates, **Cancel** returns cleanly to the picker, and any post-auth scan wedge reaches restart-required. A credential-sheet wait is expected, not a failure.

### TC13 — Auth prompt field style: host-key plain, secrets masked (issue #35)

Verifies, in the live UI, that the credential sheet renders a **plain** field for
a non-secret host-key question and a **masked** field for secrets — the
`ConnectPromptClassifier` → `PasswordSheet.InputStyle` decision (unit-tested in
`ConnectPromptClassifierTests` / `PasswordSheetInputStyleTests`), confirmed
end-to-end. The response field is masked iff it is an `NSSecureTextField` (dots
instead of characters).

**Setup.** Use a profile to a host **not yet in `~/.ssh/known_hosts`** (or
temporarily remove its line) so the first connect asks the host-key question,
followed by a password profile (no key / `sshargs = -i /nonexistent`) so a
password prompt follows.

1. **Host-key question → plain field.** On first connect the sheet shows
   *"The authenticity of host '…' can't be established… Are you sure you want to
   continue connecting (yes/no/[fingerprint])?"*. **Expect:** the response field
   is **plain** (you can read what you type); type `yes` and it is accepted.
2. **Password / passphrase / OTP → masked field.** The next prompt is the
   password (or key passphrase, or an MFA/verification code). **Expect:** the
   response field is a **masked** secure field (dots). Entering the correct
   secret authenticates.
3. **Host-key line then a password prompt in one chunk → masked.** Harder to
   elicit live; if you can drive a peer that emits the host-key line immediately
   followed by `Password:` in the same read, **Expect:** the field is **masked**
   (the combined chunk classifies as a credential, not a host-key question — the
   fail-safe). If you cannot reproduce it live, the equality-based classifier
   cases `test_hostKeyQuestionThenPasswordPrompt_isCredential` and
   `test_hostKeyQuestionWithTrailingPasswordSameLine_isCredential` cover it.

**PASS =** the host-key yes/no question uses a plain field; every secret
(password/passphrase/OTP) uses a masked secure field; and a host-key line
followed by a password prompt is masked, never plain.

---

## Known limitations (do NOT file as bugs — tracked in issues #6 / #24)

- **Recovering a wedged sync/scan requires quit + reopen.** A connection that
  died (sleep / network drop / frozen remote) can't be unblocked in-process —
  proven infeasible (a `select()` blocked on a dead connection can't be woken
  from another thread by closing the fd or killing ssh). The sync-phase stall
  hint (TC10, 45 s) and the scan-phase detector (TC11, 120 s) both detect it and
  point the user to quit + reopen, which is clean now. SSH keepalive (#55) as a
  mitigation **will not be implemented** — the spike was transport-positive but
  app-inconclusive (see `docs/ssh-keepalive-spike-results.md`).
- **In-app exits do not unwind a genuinely wedged op.** No UI control unwinds a
  scan in-process. During scanning the only leave is **Profiles**
  (abandonment); **Stop** is disabled (sync-only, issue #117) and **sheet Cancel**
  cancels credential entry; recovery from a wedged scan is quit + reopen. The v0.4.0 in-place
  **Stop Scan** (kill the transport, then reuse the engine) was withdrawn because
  forced-interruption engine reuse was never proven safe; in v0.5.1 the machinery
  has been **removed entirely** (#94, merged) — there is no `ScanInterruptPolicy`
  gate or `.interruptingScan` state left. Genuine scan cancellation is declined
  (issue #53, not planned).
- **Password re-prompt after sleep:** a held connection dies on sleep, so a
  later reopen re-prompts. The app does not cache passwords; the recommended way
  to avoid re-prompts is SSH key authentication with the key held by `ssh-agent`
  / the macOS Keychain (`ssh-add --apple-use-keychain`), configured in the
  profile's `sshargs` / your `ssh_config`. See MANUAL.md "SSH authentication".

---

## Results

| Case | Behavior | PASS / FAIL | Notes |
|---|---|---|---|
| TC1 | non-interactive close on sync-end | PASS | live + automated regression |
| TC2 | non-interactive Rescan reopens silently | PASS | live (Release): initial ssh child reaped on sync-end; Rescan reconnects with NO credential sheet and scan completes; connection reused across a further rescan (same pid) then reaped again on the next sync-end. Child lifecycle correct. |
| TC3 | interactive held through sync-end | PASS | live (Release, user typed password, → .241 VM): connection authenticated; the ssh child **persisted** through the entire Go/sync and after "Synchronization complete" (3 items, 74 bytes) — held, NOT closed on sync-end (interactive-auth close policy). |
| TC4 | interactive Rescan no re-prompt | PASS | live: same-session Rescan reused the held connection (same ssh pid, **no** second credential sheet), scan completed ("Everything is up to date"). |
| TC5 | interactive closes on leave | PASS | live: clicking Profiles (leave) closed the connection and reaped the ssh child within ~1 s; returned to the picker. |
| TC6a | Keep Syncing | | |
| TC6b | Abort & Close | | |
| TC6c | Close (let it run) | | |
| TC7 | local-only sanity (detector never arms) | PASS | live + automated regression |
| TC8 | no ssh pile-up | PASS | live regression |
| TC9a | gate: pick during background sync | | |
| TC9b | gate: pick during scan | | |
| TC10 | wedged-sync stall hint | PASS | orange hint at 45s, responsive, clean quit+reopen |
| TC11 | post-auth scan wedge (frozen remote) | PASS (stall mechanics); UI re-confirm pending for #117 | scan-stall detector fires at the 120 s bound → restart-required; the leave-to-picker path (now **Profiles**) drives restart-required via the retained detector; a replacement profile opened right after is carried to restart-required; clean targeted quit, app-owned ssh child reaped, fresh reopen succeeds. Exercised against a frozen remote (`kill -STOP`). Under #117 re-confirm the toolbar delta: **Profiles** leaves, **Stop** stays disabled/neutral (was the relabelled "Return to Profiles"). |
| TC12 | interactive auth failure + cancel | PASS | live, user typed passwords → .241 VM. #63 fix validated 2026-07-26 (Debug build) across four sub-cases: correct-first-try (one sheet → auth → sync); wrong→correct (the retry sheet appears **once**, carrying the folded "Permission denied, please try again." message, and the correct password authenticates on that single entry — no phantom extra sheet); wrong→wrong→correct (one sheet per real attempt); Cancel-from-retry (clean return to the picker, ssh child reaped, verified 0 children). Earlier retry-recovery + cancellation runs were Release. |
| TC13 | auth prompt field style (host-key plain / secrets masked) | | REQUIRED on the signed RC: host-key yes/no → plain field, password/passphrase/OTP → masked secure field. Combined host-key+password chunk covered by unit tests. |

---

## Evidence provenance

Results above come from three evidence classes:

- **Automated (XCTest, runs in CI):** the coordinator state machine and
  `ScanStallTimer` behaviors — arm/reset/disarm, operation-bound firing,
  restart-required transition, late-completion suppression, retention across
  abandonment, and the healthy-scan control — all against an injected fake
  scheduler (no real timeouts).
- **Live — unattended (Release build, this pass):** TC1/TC7/TC8 regression;
  TC2 non-interactive close + silent reopen; TC10 sync-stall hint; TC11
  frozen-remote wedge at the production 120 s bound (detector fires →
  restart-required, clean quit, child reaped, fresh reopen). The healthy-scan
  control was a fast scan with a wide margin; a genuinely ~120 s-silent healthy
  scan was not constructed.
- **Live — interactive (Release build, → .241 VM; password typed by hand, never
  captured or stored):** TC3, TC4, TC5, and TC12 (retry-recovery and
  cancellation runs). **TC13** (auth field style) is interactive and **required
  on the signed v0.5.1 RC** — its host-key-plain and password-masked portions
  are reproducible live; the combined host-key+password chunk stays unit-tested.

Not yet re-run this pass: TC6a/b/c, TC9a/b, and TC13 (the last required on the
signed v0.5.1 RC — see the release checklist).
