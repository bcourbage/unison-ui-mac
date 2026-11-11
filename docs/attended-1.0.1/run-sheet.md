# 1.0.1 release candidate: attended run sheet (issue #197)

Fill the header first. A case that applies but was not exercised is not a Pass. Mark
each case **Pass**, **Fail**, or **N/A** with a stated justification; a Fail blocks
promotion (the RC is simply not approved). Evidence is a one-line observation, not a
screenshot of the whole screen.

| Field | Value |
| --- | --- |
| RC artifact | `unison-ui-mac-signed-1.0.1` from the `sign-rc` job of the v1.0.1 run |
| RC SHA-256 (zip `unison-ui-mac-1.0.1.app.zip`) | `0fbce41ad5c2d53d5baac5ad1c563b489dfdae4088c705c920f9fe22ddf6569f` (matches the `rc.sha256` and `rc-manifest.txt` inside the artifact; also record the sign-rc run-summary value here and confirm it is the same) |
| `MARKETING_VERSION (CURRENT_PROJECT_VERSION)` | 1.0.1 (29) |
| Source commit | `d3c5b4af1dc3db5c08c5a8d36a56ab55b5b68484` (tag `v1.0.1`); Release run 42754302708 |
| macOS (this Mac) / macOS 15 machine | |
| Tester / date | |

## 0. Before any case: the bytes under test

1. **Download in a way that quarantines.** Use the browser from the run's artifact page. Extract with a quarantine-preserving tool. (`gh run download` does not set the flag.)
2. **Verify the flag** before launching: `xattr -p com.apple.quarantine "<app>"` prints a value, exit 0. If not, the copy is not quarantined and the result is invalid.
3. **Checksum.** `shasum -a 256 <zip>` equals the sign-rc summary value, and equals the value recorded above.
4. **Inspect the signed bundle.**
   - `defaults read "<app>/Contents/Info" CFBundleShortVersionString CFBundleVersion` prints 1.0.1 and 29.
   - `defaults read "<app>/Contents/Info" LSMinimumSystemVersion` prints 15.0.
   - `codesign -dvvv --entitlements - "<app>"` shows Authority Developer ID Application, flags include `runtime`, Team `QJXKM5Q4WH`.
   - `xcrun stapler validate "<app>"` says the ticket is valid; `spctl -a -vvv -t exec "<app>"` says accepted, source Notarized Developer ID.
   - `strings "<app>/Contents/MacOS/unison-ui-mac" | grep -c UNISON_AUTOTEST` prints 0.
5. **Gatekeeper first open.** Move to /Applications, open once from Finder, accept nothing but the standard first-open dialog. Then `ln -s /Applications/unison-ui-mac.app/Contents/MacOS/cltool /tmp/unison; /tmp/unison -version` prints the engine version, exit 0.

| Step | Result | Evidence |
| --- | --- | --- |
| 1-3 quarantine, flag, checksum | Pass | Safari download of the artifact; `shasum -a 256` of `unison-ui-mac-1.0.1.app.zip` gave `0fbce41ad5c2d53d5baac5ad1c563b489dfdae4088c705c920f9fe22ddf6569f`, equal to the recorded value; the quarantine flag was present before launch. |
| 4 signed bundle inspection | Pass (inspected by Claude on an `ditto` extraction, not quarantined) | 1.0.1 (29); LSMinimumSystemVersion 15.0; arm64; both executables minos 15.0; Developer ID Application, Team QJXKM5Q4WH, flags `runtime`, secure timestamp; `codesign --verify --deep --strict` valid; `stapler validate` worked; `spctl` accepted, source Notarized Developer ID; 0 `UNISON_AUTOTEST` strings in `unison-ui-mac` and `cltool`; no debug dylib; bundled manual matches the committed one |
| 5 Gatekeeper first open and `-version` | Pass (Bruno, 2026-11-10), launched with `open` rather than from Finder | Quarantined Safari download, app in /Applications as `Unison-UI-Mac-1.0.1.app`. `xattr -p com.apple.quarantine` printed `0183;6af3bb81;Safari;004805B3-…`. The standard first-open dialog appeared ("…is an app downloaded from the Internet. Are you sure you want to open it?"; Safari download; Apple checked it for malicious software, none detected); Open was the only action taken, and the Profiles picker appeared (it listed his real profiles, none was run). The `cltool` link's `-version` printed `unison version 2.54.0 (ocaml 5.5.0)`, exit 0. |

## 1. Fixtures

`docs/attended-1.0.1/make-fixtures.sh [BASE]` builds everything below under one base directory with its own `UNISON` directory. Export `UNISON` in every Terminal and launch the RC from that environment. Pre-synchronize `work`, `other`, `shared-direct` and `shared-include` with the RC launcher (`-ui text -batch`) while replicas are equal, then introduce differences as each case says.

## 2. Existing cases on this exact RC

Work through `docs/manual-test-step2b.md` in its own order (non-interactive first, interactive-password last): TC1, TC2, TC6, TC7, TC8, TC9, TC10, TC11, TC14, TC15, then TC3, TC4, TC5, TC12, TC13. Add the two new cases for this release: **TC16** (recovery keeps the session's options) and **TC15j** (a request while an SSH prompt is open). Record each in that file's Results table when the run is accepted.

| Case | Result | Evidence |
| --- | --- | --- |
| TC1, TC2, TC6a-c, TC7, TC8 | | |
| TC9, TC10, TC11 | | |
| TC14 | | |
| TC15 a-i | | |
| TC16 a-d (new) | | |
| TC15j (new, interactive) | | |
| TC3, TC4, TC5 | | |
| TC12, TC13 | | |

## 3. Issue #197 items

Each item needs a person; inspecting the accessibility tree is not a substitute.

### 3.1 Accessibility
Real VoiceOver and Full Keyboard Access (System Settings, Keyboard, "Keyboard navigation"), then larger text and increased contrast. Walk: picker, profile form, reconcile tree (arrow keys, expand and collapse, row actions), toolbar, every sheet (sync decision, rescan confirmation, password sheet, fatal dialog), Settings. Fixtures: `work` (small tree), `flat-many`, `nested-many`.
Expect: every control is reachable and named, focus order is sensible, no control is mute or unreachable, the sheets can be answered from the keyboard, and text and contrast changes do not clip or hide a control.

| Area | Result | Evidence |
| --- | --- | --- |
| VoiceOver | Partial: picker, Profile Editor and reconcile tree pass; one finding (Bruno, 2026-11-10) | Picker: table and buttons, up and down the list, all read. Profile Editor: fields and buttons announced clearly, Cancel returned focus. Reconcile tree: passes. **Finding:** a sync ran and completed but VoiceOver did not speak the outcome. Source check: the status line is a plain label whose text changes silently; the app posts no accessibility announcement anywhere, and v1.0.0 has none either, so this is pre-existing and not a regression of the 1.0.1 changes. Decision (Bruno, 2026-11-10): ship 1.0.1 as is; tracked as #227. Rescan Ignoring Archives… (the Action menu item and its confirmation sheet): Pass (Bruno, 2026-11-10). Settings: Pass (Bruno, 2026-11-10). Toolbar: Pass (Bruno, 2026-11-10). Waived by Bruno, 2026-11-10: the remaining VoiceOver checks (the sync-decision sheet, the password sheet and the fatal dialog); no further VoiceOver testing for this candidate. |
| Full Keyboard Access | Pass (Bruno, 2026-11-10) | Reported by Bruno; surfaces covered not itemized. |
| Larger text | Waived (Bruno, 2026-11-10) | Not run for this candidate. |
| Increased contrast | Waived (Bruno, 2026-11-10) | Not run for this candidate. |

### 3.2 Window sizes and layouts
On this Mac and on a macOS 15 machine. At the picker's minimum size (360 by 260; now enforced and restored from a smaller saved frame, so also set a tiny saved frame in the defaults and relaunch) and at the reconcile window's minimum and a wide size. Layouts: flat (`flat-many`), nested-collapsed and nested-full (`nested-many`). Fixture sizes exceed the 221-file review fixture (600 and 480 conflicts).
Expect: no clipped controls at the minimum, a restored saved frame never below the minimum, lists scroll smoothly, selection and details stay usable.

| Check | Result | Evidence |
| --- | --- | --- |
| Picker minimum, and a too-small saved frame | | |
| Reconcile minimum / wide, this macOS | | |
| Reconcile minimum / wide, macOS 15 | | |
| flat-many (600) | | |
| nested-many collapsed / full (480) | | |

### 3.3 Sparkle dialogs against a test feed
Needs a local test appcast signed with a throwaway key per `docs/sparkle-updates.md` ("Key custody" for the throwaway-key procedure, `scripts/sparkle-appcast.sh` and `scripts/make-verifier-key.py`). Point a **copy** of the RC at it; never the production feed or key. Exercise: permission prompt, update available, no update available, and a failure (unreachable feed, then a feed with a bad signature).
Expect: each dialog appears with correct wording and Cancel and Install behave; a bad signature is refused with a failure dialog.

| Dialog | Result | Evidence |
| --- | --- | --- |
| Permission | | |
| Update available | | |
| No update | | |
| Failure (unreachable / bad signature) | | |

### 3.4 Command-line setup confirmation
Without altering a real shell configuration: use a throwaway macOS user, a VM, or a copy of the home with `HOME` pointed at a scratch directory so the setup block lands in a scratch `.zprofile`. Stock inputs: `scripts/fixtures/stock-zprofile-macos15.txt` and `-macos26.txt`.
Expect: Settings, Command Line shows the confirmation with the exact block; Cancel changes nothing; Confirm writes only the app-owned block; the status reads correctly after; removing it restores the file byte for byte.

| Check | Result | Evidence |
| --- | --- | --- |
| Confirmation text matches the block | | |
| Cancel writes nothing | | |
| Confirm writes only the app-owned block | | |
| Remove restores the file | | |

### 3.5 Transfer lifecycle
- **Sustained transfer:** `big-transfer`, Go, then Stop; repeat with each close decision (Keep Window Open, Stop Syncing and Close, Continue in Background). Expect: Stop leaves a consistent state, the engine is reusable, no orphan `ssh` or `unison` processes remain.
- **Partial failure:** `partial-fail`. After pre-sync, edit all three files in A, then `chflags uchg B/locked.txt`. Go. Expect: exactly the `locked` row fails, `ok-1` and `ok-2` transfer, and the failure is attributed to the right row. Undo with `chflags nouchg`.
- **Fatal recovery:** with `work` synced, delete one root's `ar<hash>` file in the `UNISON` directory and open it. Expect the "inconsistent state" dialog. Exercise Retry Ignoring Archives (the retry scan is scoped like the session) and, on a fresh copy, Delete 1 Orphan Archive and Retry. Known and tracked, not a defect of this run: #224 (an external repair made while the dialog is open can be undone by Delete) and #225 (retry after abandoning the session).
- **Interrupted archive transaction:** start Reset Archives or Clean Stale on a profile and interrupt (kill the app by PID) at the staging step; relaunch. Expect the recovery dialog, the profile blocked until recovery completes, and recovery restoring the archives.

| Check | Result | Evidence |
| --- | --- | --- |
| Stop and each close decision | | |
| Partial failure attributed to the right row | | |
| Fatal recovery, both buttons | | |
| Interrupted archive transaction recovered | | |

### 3.6 SSH credentials
Fixtures: `ssh-local` (Remote Login on; you type the password) and `check-fails`.
- Long server prompt: arrange a prompt much longer than the sheet (a `sshcmd` shim that prints a 400-character prompt and reads a line). Expect: the text wraps or scrolls and OK and Cancel stay reachable.
- Cancellation: cancel the sheet. Expect: the window closes, the picker returns, no ssh child remains.
- Failing Check Remote Command: `check-fails`, Profile Editor, Check Remote Command. Expect a clear failure diagnosis, no hang.
- New in 1.0.1: TC15j (a command-line request while the sheet is open is refused and leaves the sheet answerable).

| Check | Result | Evidence |
| --- | --- | --- |
| Long prompt | | |
| Cancel | | |
| Failing Check Remote Command | | |
| TC15j | | |

### 3.7 Dialog ordering
First-run engine warning pending (a profile with no archive), then background and foreground the app, then queue an open from the picker with ordinary interaction. Expect: the warning stays reachable; Close and ⌘Q work once it is answered. If a required warning becomes inaccessible and prevents closing or quitting, that is a release blocker.

| Check | Result | Evidence |
| --- | --- | --- |
| Warning reachable after background/foreground | | |
| Close and Cmd-Q work after answering | | |

### 3.8 Shared archive ownership (carried from 1.0.0)
`shared-direct` and `shared-include`, both synced. Delete one with the default choices: the survivor keeps its archives and its next run propagates a deletion instead of copying the file back (delete `doomed.txt` on one side first). `unresolved` and `symlinked`: the delete confirmation keeps the files.

| Check | Result | Evidence |
| --- | --- | --- |
| Survivor keeps its archives | | |
| `unresolved` / `symlinked` keep the files | | |


## Results of the Claude-run pass (RC `0fbce41a…`, macOS 27.2.1, Heracles)

Run on the extracted signed bytes (not a browser download) with disposable fixtures and a throwaway `UNISON` directory; no password was typed. "Remote" cases used a shim `sshcmd` that runs the RC's own `-server`, so the connection is non-interactive and the server child is the app's `unison-ui-mac -server`.

| Item | Result | Evidence |
| --- | --- | --- |
| Quarantine and Gatekeeper first open | Pass, with caveat | Quarantine set with `xattr -w` (not a browser download). `spctl` accepted (Notarized Developer ID); `open` launched under App Translocation with no first-open dialog; `unison -version` printed 2.54.0, exit 0. |
| TC1, TC2 | Pass | Server child 1 before Go and 0 right after sync-end with the window open; Rescan reconnected with no sheet and the child reappeared. |
| TC6a, 6b, 6c | Pass | Keep Window Open kept the sync running to completion; Stop Syncing & Close closed the window and reaped the child in about 5 s; Continue in Background closed the window and the 3.1 GB sync completed in the background (child 1 until then, then 0). |
| TC6d | Pass (run later, 2026-11-10) | A 2.6 GB sync: the close sheet (Keep Window Open, Continue in Background, Stop Syncing & Close) was raised 2 s in and left untouched; it dismissed itself when the sync completed, the window stayed with "Synchronization complete", and closing it afterwards raised no sheet and returned to the picker. |
| TC7, TC8 | Pass | Local sync: no child, no dialogs. Four opens of a remote profile: children 0 at the picker after each, never growing. |
| TC9a, TC9b | Pass | "Waiting for the previous operation to finish…" then the new profile opened, after a background sync and after leaving a scan. |
| TC10 | Pass | Advisory "No sync progress has been observed for 45 seconds." appeared between 45 and 48 s of a frozen server; app stayed responsive; thawing let the sync complete. |
| TC11 | Pass | Restart-required after about 125 s of a frozen scan with the "Unison needs to be restarted" sheet (Copy Details, Later, Quit Unison); Stop disabled; leaving by Profiles then opening another profile showed the waiting window, then restart-required. |
| TC14 steps 1 to 6 | Pass | Steps 1 to 5 as written; step 6 with the shim remote: scoped scan, scoped sync, reconnecting Rescan stayed scoped, picker reopen unscoped. |
| TC15a to c, d, e, f, g, h, i | Pass | Idle open, options delivered, local takeover Started, remote takeover accepted-and-waiting, editor refusal (names the profile), restart-required refusal, all three sync-decision choices plus timeout (120 s), menu Quit with the sheet up, background-sync accept, second request refused, app killed during an awaited decision gave the unconfirmed-outcome message. TC15h, run later (2026-11-10): the second request was refused as already handling another (above); leaving the waiting window through Action, Show Profile Picker cancelled the waiting request (`other` never opened), and a profile chosen afterwards opened as an ordinary open (it waited for the engine, then scanned). The picker "A command-line request is already waiting to open." alert could not be driven by hand: the waiting window closes the picker while a request is queued, so no picker selection is possible; that path is covered by the unit tests only. Not individually run: the other three Quit routes of TC15f. |
| TC15j (new) | Pass | Request refused (exit 1, "waiting for an SSH prompt"); the credential sheet, window and child stayed; Cancel returned to the picker with no child; a later request was accepted. |
| TC16a, b, d | Pass | Recovery stayed scoped to `Documents` and showed the archive-ignored conflict, with and without `-ignorearchives=false` in the session; profile file byte-identical; a stale confirmation did nothing (the replacement stayed). |
| TC16c | Corrected | Profile file is unchanged and a later ordinary open is unscoped with no override. The wording in the test plan ("the archive in effect, one-sided change not a conflict") is wrong: the recovery scan rebuilds the archive, so the later ordinary scan still shows the conflict. The test plan needs that sentence fixed. |
| #197 window sizes and layouts | Partial | Reconcile window minimum enforced at 960 by 466, wide limited by the screen; picker minimum 360 by 292 (content 360 by 260) enforced. flat-many: 600 rows; nested-many: flat 480, collapsed with all branches 496, top level only 16, nested full with all branches 560. The too-small saved picker frame: Pass (Bruno, 2026-11-10; an undersized saved frame was restored at the minimum or larger). Window layouts on macOS 15: Not run (Bruno, 2026-11-10). The macOS 15 launch of the exact release build is covered by the pipeline's `smoke-macos15` job, which passed; layouts and window sizes on macOS 15 were not checked by hand. |
| #197 transfer lifecycle | Pass, with notes | Stop and each close decision (TC6). Partial failure: exactly one row (`locked.txt`) failed with the other two transferred. Fatal recovery: the dialog offered Retry Ignoring Archives, Delete 1 Orphan Archive and Retry, OK; Delete-and-retry removed the orphan and restarted with the normal first-sync warning. Interrupted transaction: a crafted pre-commit staging record with its locks (not a live kill) produced the recovery dialog, blocked the profile in the picker and from the command line, and Recover Now restored all archive files, cleared the locks and the staging directory, and the profile then opened normally. |
| #197 shared archive ownership | Pass | Deleting one of two same-root profiles kept the 3 archive files and named the other profile; the survivor's next run propagated the deletion instead of copying the file back; with `symlinked` and `unresolved` profiles present, the delete confirmation kept the files and said why. |
| #197 dialog ordering | Pass | First-sync warning pending, app backgrounded and foregrounded: warning still reachable; answering it, Close returned to the picker and Quit worked. The picker was not clickable while the warning was up, so queueing an open from the picker was not possible. |
| #197 SSH credentials | Partial | Failing connection showed "Couldn't connect…" with the ssh error. Guided Check Remote Command from the restart sheet failed with "No start marker was received before ssh exited (status 1, no stderr)." and no hang. Cancel of the credential sheet cleaned up. Not run: a long server prompt (the shim could not produce a credential prompt). |
| #197 command-line setup | Pass (Claude, 2026-11-10, with Bruno's go-ahead, on the real `~/.zprofile` after a checksummed backup) | Cancel wrote nothing. Use This Copy… then confirm rewrote only the managed block's PATH line (line 16 of 18; all other lines byte-identical; `~/.zshrc` untouched) and the status read "This app selected by the check". Unticking "Keep unison in Terminal pointing at this app" changed nothing in the file and surfaced Remove Terminal Setup…; its confirmation ("Removes this app's block from …/.zprofile") deleted exactly the four block lines and left every other byte as it was. Afterwards the original file was restored from the backup (SHA-256 `7d74d2c5b0f2beb4…` and 618 bytes, as before) and the `commandLine.keepInTerminal` preference was set back to on. For a few minutes the PATH block pointed at the scratch copy of the RC. |
| #197 accessibility (VoiceOver, Full Keyboard Access, larger text, increased contrast) | Not run | Needs changing system accessibility settings, which I do not do. |
| #197 Sparkle dialogs | Not run (Bruno, 2026-11-10): local test build unavailable | Needs a test feed with a throwaway key and a re-pointed copy of the app. The real update path from 0.10.1 was exercised for 1.0.0; the permission, update-available, no-update and failure dialogs have not been run on this candidate. The post-publication canary (installed 1.0.0 updating from the live feed) still applies after promotion. Assessment (Claude, 2026-11-10): not worth a purpose-built test build for this release. The 1.0.1 diff touches no Sparkle code; the dialogs are Sparkle's own; a test build (different feed URL, throwaway EdDSA key, signed feed) would not be the candidate's bytes. The item stays open in #197 for 1.1. |
| TC3, TC4, TC5, TC12, TC13 | Not run | Interactive password cases. |

| Interactive password cases on the VM (`vmuser@192.168.2.199`, password typed by Bruno) | Pass (2026-11-10) | TC13: the host-key question used a plain field (the fingerprint matched the one already in Bruno's known_hosts) and the password prompt a masked field. TC3: after the sync the ssh child persisted with the window open. TC4: Rescan reused the same ssh child with no second sheet. TC5: leaving to the picker reaped the child within a second. TC12: a wrong password re-prompted once, the correct one then authenticated; Cancel closed the window and returned to the picker with no child left. TC15j on the VM profile was not redone (it passed against a local password sshd; its answer-then-opens half passed on the VM). Note: a second copy of the app was started by a CLI request when the single-instance listener was held elsewhere; not a product defect. |

| Remote-root gate (new in this candidate, added after the combined review) | Pass (Claude, 2026-11-10) | With a crafted blocking staging record: the picker refused the profile with a local plus an ssh root, offering recovery with "This profile has a remote root, so the archives it uses cannot be identified from its roots…", while an unrelated local profile opened normally. The command-line path is covered by unit tests only. |

Observation, not a defect of this candidate: with the app in restart-required, choosing a profile in the picker is silently ignored (no window, no message).


## 4a. Waivers and decision (2026-11-10)

Bruno waived the remaining open items and directed publication: larger text, increased contrast, the remaining VoiceOver sheets, the long server prompt, the other three Quit routes in TC15f, and (Not run) the macOS 15 layouts and the Sparkle dialogs. Accepted artifact: `unison-ui-mac-1.0.1.app.zip`, SHA-256 `0fbce41ad5c2d53d5baac5ad1c563b489dfdae4088c705c920f9fe22ddf6569f`, commit `d3c5b4af1dc3db5c08c5a8d36a56ab55b5b68484`, Release run 42754302708. Known and tracked at acceptance: #227 (VoiceOver does not announce the sync outcome), #224, #225, #217, #218; the TC16c test-plan wording needs a docs fix.

## 4. Decision

All results above are Pass or justified N/A, no Fail is outstanding, and the SHA-256 recorded here equals the one the `publish` run prints it is shipping.

| Accepted artifact | SHA-256 | Accepted by / date |
| --- | --- | --- |
| | | |

## 5. Post-publication canaries (2026-11-10)

| Canary | Result | Evidence |
| --- | --- | --- |
| Published artifact | Pass | The v1.0.1 release zip's SHA-256 equals the accepted candidate's (`0fbce41a…`); both feeds (client and Pages) are byte-identical and list 1.0.1 (29). |
| Real Sparkle update (installed 1.0.0 to 1.0.1) | Pass (Bruno) | The update dialog appeared: "Unison-UI-Mac 1.0.1 is now available, you have 1.0.0", with the 1.0.1 release notes and Install Update, Remind Me Later and Skip This Version. |
| Homebrew cask | Pass | Tap PR #27 merged (`1b97ab4`); `brew info --cask bcourbage/tap/unison-ui` shows 1.0.1 (Bruno's run). The tap's scheduled bump workflow is broken (untrusted tap) and needs a separate fix. |
