# unison-ui-mac — TODO

A snapshot of what's left to do, with priority tiers. Personal-use project;
not for upstream contribution (per unison's CONTRIBUTING.md).

## P0 — Workflow gaps blocking real use

These three together close the basic loop: open profile → reconcile → sync →
go back / refresh / open another profile.

- [ ] **Rescan button** in reconcile toolbar — re-runs `init2` against the
      current profile to refresh the state-item list. Should reuse the
      existing reconcile window, replace `items`, reload the table.
- [ ] **Return to profile picker** — menu item / toolbar action / closing
      the reconcile window all need to bring the picker back without
      requiring quit + relaunch. The `File → Open Profile` menu item is
      already a no-op stub; wire it up.
- [ ] **Cancel a running sync** — no way to interrupt a transfer in
      progress. OCaml's `Abort` module is the right entry point
      (`Abort.all`); needs a C bridge function and a toolbar Stop button
      that's only enabled while `isSyncing == true`.

## P1 — Quality of life

- [ ] **Color-coded reconcile rows** — the original app color-codes rows by
      action so the user can scan the change-set at a glance (e.g. green = →,
      blue = ←, yellow/red = conflict, gray = skip). Apply via row/cell
      background or text color in `tableView(_:viewFor:row:)`.
- [ ] **Details footer in the reconcile window** — selected row's full
      details (path, both sides' size/mtime, conflict reason). Calls
      `unisonRiToDetails`. The legacy app puts this in a bottom strip; we
      can do the same.
- [ ] **Window-close guard during sync** — closing the reconcile window
      mid-sync should confirm or cancel cleanly, not leak the OCaml worker.
- [ ] **Highlight FAILED rows** in the table (e.g. red status text or a
      symbol in the Progress column). OCaml reports failures via
      `unisonRiToProgress` returning `"FAILED"`.
- [ ] **Per-row progress for slow transfers** — current OCaml throttling
      (>1% change) collapses small files to a single `100%` event. For
      network sync we'll see intermediate ticks; verify the column updates
      live and consider a tiny per-row progress bar.
- [ ] **Disable direction-override toolbar items when nothing is selected**
      (NSToolbarItem `validate(_:)` hook). Currently they beep.
- [ ] **Tooltip on truncated paths** — the Path column uses byTruncatingMiddle;
      a tooltip with the full path would help.
- [ ] **Status messages with newlines** — currently we take only the first
      line in the picker status label. Worth surfacing the full text via
      tooltip or a "Show details" disclosure, especially for SSH error
      output during connect.

## P2 — Features from the legacy app

- [ ] **Ignore actions** — right-click on a row → Ignore Path / Ext / Name
      (calls `unisonIgnorePath`/`unisonIgnoreExt`/`unisonIgnoreName`, then
      `unisonUpdateForIgnore` to re-filter the current state-item list).
- [ ] **Diff viewer** — Diff button / context-menu action that calls
      `runShowDiffs` for the selected row and displays the result. The OCaml
      side calls back into `displayDiff(left, right)` (currently abort stub).
      Needs a diff-viewer window.
- [ ] **Force older / newer direction** — `unisonRiForceOlder` /
      `unisonRiForceNewer` aren't wired. Worth surfacing as toolbar items or
      Edit-menu actions.
- [ ] **Details pane** — selected-row inspector showing
      `unisonRiToDetails` (full path, modification time, etc.). Could be a
      bottom drawer or right-side pane in the reconcile window.
- [ ] **New Profile editor** — `File → New Profile…` currently just beeps.
      A minimal editor: name, two roots (with file pickers), `path =`
      filters, ignore patterns, save to `~/Library/Application Support/Unison/<name>.prf`.
- [ ] **Hide Merge toolbar item if `merge` pref isn't set** — the action only
      works with a configured merge tool; right now it succeeds in the UI
      but fails at sync time.
- [ ] **Help menu → Unison Online Help** — open
      `https://github.com/bcpierce00/unison/wiki` in the browser. The legacy
      app pointed at the old UPenn URL (now 404); use the current wiki.
- [ ] **Mirror the legacy app's full menu structure** (App-specific items
      only — leave macOS defaults alone). The legacy [MainMenu.xib](unison/src/uimac/English.lproj/MainMenu.xib)
      includes at least:
    - **File**: New profile…, Open profile…, Save profile, Synchronize all,
      Install command-line tool, Quit
    - **Edit**: Cut/Copy/Paste/Select All (done), plus
      **Ignore Path / Ignore Extension / Ignore Name** (per-row from
      selection), Select Conflicts, Revert to Unison's Recommendation
    - **Action**: Propagate Left to Right / Right to Left / Older to Newer /
      Newer to Older, Skip ("Leave Alone"), Merge, Diff, Go (Synchronize)
    - **Help**: Unison Online Help, About
- [ ] **About panel content** — populate `NSApplication.orderFrontStandardAboutPanel`
      with our version, "Based on Unison <version>" credit line, and a
      Credits.rtf with the license summary.

## P3 — Hardening / hygiene

- [ ] **Gate dev hooks behind a Debug build flag** — `UNISON_AUTOTEST_*`
      env vars and the TraceLog file at `/tmp/unison-ui-mac.log` are dev-only.
      Either remove them in Release or feature-gate so they're inert.
- [ ] **Replace TraceLog with `os.Logger`** — once we're past the bring-up
      phase, file-based dev logging should go.
- [ ] **Reconcile window during fatal/cancel** — `abortAllInFlight()` only
      resets the picker. If a fatal fires *during sync* (after reconcile),
      the reconcile window stays in a stale state.
- [ ] **Clean shutdown of OCaml workers** — currently we just exit; no
      `caml_remove_generational_global_root` for `g_preconn` / `g_ri_roots` on
      app quit. Mostly cosmetic since the process is dying.
- [ ] **Build dependency tracking** — `make xcodeproj` only regenerates when
      `project.yml` changes; new Swift files require manual `xcodegen
      generate`. Either depend on `Sources/**/*` or document the workflow.
- [ ] **Remove test artifacts** — `~/Library/Application Support/Unison/test-tiny.prf`
      and `/tmp/unison-test-{a,b}` left from bring-up testing.
- [ ] **Codesigning** — currently ad-hoc. Apple Developer ID would let us
      stop seeing the "downloaded from internet" warning on every fresh
      build, but it's a paid-membership step. Personal use can stay ad-hoc.
- [ ] **Full test suite** — currently no automated tests at all. Target
      coverage:
    - **Bridge unit tests** (XCTest): each `unison_bridge_*` entry point
      against a known minimal OCaml state. Spin up the runtime, exercise
      get_version / unison_directory / init1 against a test profile, verify
      results.
    - **State-item marshaling**: build fake `stateItem` arrays in OCaml-test
      callbacks, check Swift `[StateItem]` matches field-by-field.
    - **UI tests** (XCUITest): launch → pick profile → reconcile shows →
      Go → completes. Use the `UNISON_AUTOTEST_*` env-var hooks. Run against
      a /tmp test profile so no network or user state is involved.
    - **Concurrency/stress**: the existing `1000-calls-in-7ms` benchmark
      should be promoted to a perf test, plus a re-entrance test (callback
      that re-enters the bridge).
    - **Memory leaks**: scripted runs under `leaks(1)` after sync.

## Carried-over reminders (memory notes)

- [ ] **Warning/error UX completeness** — the modal sheets are wired, but
      `displayStatus` messages containing "FAILED" / "error" / "could not"
      still appear only in the table or log. Worth surfacing as toasts or
      banners. (See `unison_ui_mac_warning_error_ux` memory note.)
- [ ] **TUI vs GUI `setupRoots` parity** — Unison TUI works against the same
      profiles; if the GUI ever behaves differently for the same profile, the
      first place to look is `Prefs.parseCmdLine` vs `Prefs.loadTheFile`
      ordering in `do_unisonInit0/1`.

## Architecture remarks (not work items)

These aren't todos but should inform future work:

- The bridge's **handoff pattern** (request/response via mutex+condvar on a
  dedicated OCaml worker) is now used by both directions: Swift→OCaml
  synchronous calls and OCaml→Swift modal callbacks. The same shape would
  fit any future blocking OCaml→Swift call.
- **Per-row OCaml roots** (`g_ri_roots`) re-registered on each init2 are the
  key to making per-row actions cheap. Don't reach for indices-into-OCaml-arrays
  patterns — values can move under GC; the global-root pointer auto-updates.
- **`@MainActor` on the UI controllers** (AppDelegate, ProfileWindowController,
  ReconcileWindowController) carries through Swift 6 strict concurrency. Any
  new UI class should adopt it.

---

## Recommendation: do the P0 items, then the colored UI + details footer

You hit the missing Rescan + return-to-picker yourself just by using the app —
that's the strongest signal there is. The three P0 items together turn the
app from "one-shot" into something with a real workflow loop:

1. **Return to picker** is small (~10 min): wire `AppDelegate.openProfile(_:)`
   to call `showProfilePicker()`, close the reconcile window or just bring
   the picker forward. Also re-run on reconcile-window close.
2. **Rescan** is moderate (~30 min): a "Rescan" toolbar item on the reconcile
   window that calls `unison_bridge_init2()` and reuses the existing window
   to display the new state-item list. The bridge already supports this — we
   just need to re-install the `init2Complete` handler before calling.
3. **Cancel sync** is the meatiest (~1 hr): exposing `Abort.all` (or
   equivalent) over the bridge, adding a "Stop" toolbar item that's only
   visible while syncing, plus a wait/clean-up path on the Swift side.

After P0, the two newly-added P1 items (color coding + details footer) are
high-leverage UI wins — they're what make the reconcile window actually
*usable* for scanning a hundred-file changeset. Both are pure Swift; no
bridge work needed.

The full menu mirror, ignore actions, and diff viewer (P2) take the app from
"works for me" to "drop-in replacement for the legacy app." The test suite
is the right hardening step before any of that, but realistically can come
after the must-have features land.
