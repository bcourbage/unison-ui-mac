# unison-ui-mac — TODO

A snapshot of what's left to do, with priority tiers. Personal-use project;
not for upstream contribution (per unison's CONTRIBUTING.md).

## P0 — Workflow gaps blocking real use

These three together close the basic loop: open profile → reconcile → sync →
go back / refresh / open another profile.

- [x] **Rescan button** in reconcile toolbar — re-runs `init2` against the
      current profile via `unison_bridge_init2()`, replaces `items` in
      place, indeterminate progress bar during the scan.
- [x] **Return to profile picker** — `File → Open Profile` closes any open
      reconcile window and re-shows the picker; closing the reconcile
      window also returns to picker via `NSWindowDelegate.windowWillClose`.
- [x] **Cancel a running sync** *(partial — matches legacy semantics)* —
      Stop toolbar item is wired to close the reconcile window, which
      returns to the picker. The OCaml worker continues running in the
      background until it finishes naturally. **True mid-sync abort** would
      need upstream to register `Abort.all` via `Callback.register` in
      `uimacbridge.ml` (currently absent), or we'd have to patch upstream
      ourselves. The legacy app's "Cancel" toolbar item has the same
      limitation — it just calls `@selector(chooseProfiles)`, not a real
      abort. Tracked under P3 if we ever want a real stop-the-transfer.

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
- [/] **"Reset archives" recovery action per profile** *(partial)* — the
      *reactive* path is done: when Unison hits the "inconsistent state"
      fatal during reconcile, the modal now offers a one-click
      "Delete N Orphan Archive(s) and Retry" button (see
      `ArchiveRecovery.swift`). What's still missing is the *proactive*
      path: a profile-context menu item in the picker that wipes ar/fp/lk
      *before* any error, with a clear warning. Implementation hint: would
      need a bridge call to resolve the local+remote archive basenames
      from the profile's roots so we can delete only the relevant files
      instead of guessing from a fatal message after the fact.
- [ ] **Hide / delete profile from the picker** — destructive on disk
      (delete) or app-only (hide). Both belong in a right-click context
      menu on profile rows, with a confirmation sheet for delete.
      Implementation question for "hide" is *where to store the state* so
      the CLI `unison <profile>` keeps working — three reasonable options:
    1. **Store in `NSUserDefaults`** under `net.courbage.unison-ui-mac`.
       The list of hidden basenames lives in the app's prefs. CLI users
       see all profiles; only this app filters. Cleanest if "hide" is
       conceptually a per-app view setting.
    2. **Marker comment in the .prf file** like `# unison-ui-mac:hidden`.
       Unison ignores comments, so CLI is unaffected. Single source of
       truth (the file itself), but the file must be writable and the
       comment can be lost on profile edits.
    3. **Sidecar file** like `~/Library/Application Support/Unison/.uimac-hidden`
       listing hidden basenames. Like (1) but stored next to the
       profiles, shareable across versions of the app.
    Recommend **option 1** unless we ever want multiple installs of the
    app to share the same hidden set — then option 3.
- [ ] **Reconcile toolbar layout** — current order/grouping isn't great.
      Concretely: the four direction buttons (Local / Remote / Skip /
      Merge) should be visually distinct from workflow actions (Rescan /
      Go / Stop) and the navigation item (Profiles). Likely fixes:
    - Use NSToolbarItemGroup to bundle the four directions as a single
      segmented control.
    - Use a clearer left-to-right reading: navigation → context (Rescan)
      → per-row actions (direction group) → flexible space → primary
      action (Go) → escape hatch (Stop).
    - Consistent SF Symbol weights/styles within each group.
    - Likely pairs with the P1 "Colorful toolbar / table icons" item —
      the icon overhaul will resurface this layout decision anyway.
- [ ] **Colorful toolbar / table icons** — the legacy app's toolbar icons
      ([uimac/toolbar/*.tif](https://github.com/bcpierce00/unison/tree/master/src/uimac/toolbar))
      and table-row status icons
      ([uimac/tableicons/*.png](https://github.com/bcpierce00/unison/tree/master/src/uimac/tableicons))
      are tinted/colored and read at a glance; our current SF Symbol set is
      monochrome and feels flat. Two routes:
    1. **Re-use upstream**: the .tif/.png files are GPLv3 (same as us) and
       compatible — copy into `Resources/` and reference by name. Lowest
       effort; matches legacy look exactly.
    2. **Regenerate**: SF Symbols hierarchical/multicolor variants
       (`arrow.right` with `.palette` config), or hand-drawn replacements
       in Pixelmator/Sketch. More work; modernizes the look.
    Pair this with row-color coding (already in P1) so the visual language
    is consistent.
- [/] **Test suite** — harness landed; ~13 tests passing in ~0.5s via
      `make test`. Coverage so far and what's left:
    - [x] **Test target wiring** — `unison-ui-macTests` bundle.unit-test
          hosted by the app, runs via `xcodebuild test`. OCaml runtime
          shared via TEST_HOST (one init per process). `make test` green.
    - [x] **Pure-Swift unit tests** — StateItem (`with(direction:)`,
          `with(progress:bytesTransferred:)` composition), DirectionAction
          (toolbar-identifier uniqueness/stability, workflow IDs don't
          collide with direction IDs, labels/symbols non-empty),
          TraceLog (write produces ISO-8601-prefixed line, concurrent
          writes don't tear).
    - [x] **Bridge integration tests** — `unison_bridge_get_version`
          returns a non-empty version string mentioning OCaml,
          `unison_bridge_unison_directory` returns an existing absolute
          dir, ri-set ops on out-of-range rows return NULL gracefully
          (don't crash).
    - [x] **Concurrency/stress** — `test_perf_getVersionRoundTrip` runs
          1000 sync round-trips through the bridge as an XCTest perf
          measure (~10ms steady-state on M1 Max, regression gate at 10%).
    - [ ] **State-item marshaling** — need to drive `unisonInit2Complete`
          with a known reconcile state (e.g., the /tmp/unison-test-{a,b}
          fixture) and verify the resulting `[StateItem]` field-by-field.
          Tricky because OCaml init can only happen once; tests would
          need to coordinate on a shared init1+init2 setup.
    - [ ] **UI tests** (XCUITest) — launch → pick profile → reconcile
          shows → Go → completes. Use the `UNISON_AUTOTEST_*` env hooks
          we already have. Separate test target since UI tests run out-
          of-process.
    - [ ] **Modal warn/fatal sheet paths** — scripted scenarios for
          warn-proceed, warn-cancel, and fatal-dismiss. Each must verify
          `abortInFlight()` actually fires and the picker is usable
          afterward.
    - [ ] **Memory leaks** — `leaks(1)` after sync, scripted run.
    - [ ] **Re-entrance** — handler that fires from OCaml→C→Swift then
          re-enters the bridge from the handler. Tests the 3-worker
          design from the bring-up.

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
- [ ] **Help menu → Report an Issue** — opens
      `https://github.com/bcourbage/unison-ui-mac/issues/new` (or a
      pre-filled URL with the body templated with app version + OS version,
      via query params: `?title=...&body=...&labels=bug`). GitHub Issues is
      the email relay — neither side exposes their address. Two
      prerequisites and a fallback:
    1. The repo must be **public** for non-collaborators to file issues.
       Currently private; flip when ready to accept external bug reports.
    2. Consider creating an **issue template**
       (`.github/ISSUE_TEMPLATE/bug_report.md`) so reports come in
       structured with version / steps to reproduce / log excerpt.
    3. **Fallback for users without GitHub accounts**: an iCloud
       "Hide My Email" alias (e.g. `unison-ui-mac@hidemy.email`) wired to
       a `mailto:` link, listed in the About panel. Apple forwards mail
       without revealing your real address; revocable if abused.
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
- [ ] **Real mid-sync abort** — the current Stop button matches the legacy
      app's behavior (close window, OCaml keeps running). Truly aborting an
      in-flight transfer would require patching `src/uimacbridge.ml`
      upstream to add `Callback.register "abortAll" Abort.all`, then a new
      `unison_bridge_abort_sync()` C entry that calls it. Patching upstream
      is the only way; from our `unison-blob.o` we can only invoke what
      upstream registered.
- [ ] **Add `CONTRIBUTING.md`** — restate upstream Unison's stance that
      LLM-generated code is not welcome in their repository (see
      [unison/CONTRIBUTING.md](https://github.com/bcpierce00/unison/blob/master/CONTRIBUTING.md),
      "LLM usage" section). Disclose that *this* project was built with
      substantial LLM assistance, which is why it intentionally lives
      downstream and should never be proposed upstream. Pointers to where
      we *do* welcome PRs (if any) and what we don't (anything that would
      need to be merged into Unison).
- [ ] **App signing** — currently ad-hoc (`codesign --force --sign -` via
      the default Xcode build settings). On macOS Tahoe 26, ad-hoc-signed
      apps trigger a one-time Gatekeeper prompt the first time they're
      launched, and re-prompt after every rebuild if you launch via Finder.
      Options, increasing in effort/cost:
    1. **Stay ad-hoc** — fine for personal use; live with the one-time
       prompt. Current state.
    2. **Sign with a free Apple ID developer certificate** — open Xcode →
       Settings → Accounts, add your Apple ID, pick "Sign in with Apple
       Developer" → free 7-day-rotating certificate. Stops the prompt for
       local use but the cert needs renewing weekly and the app still
       isn't notarized so other Macs would refuse it.
    3. **Apple Developer Program ($99/year) + notarization** — get a
       Developer ID Application certificate, set `CODE_SIGN_STYLE = Manual`
       + `CODE_SIGN_IDENTITY = "Developer ID Application: ..."` in
       project.yml, then `xcrun notarytool submit ... --wait --staple` as
       a Makefile target. Required for any distribution outside the App
       Store. Probably overkill for personal use.
    4. **Mac App Store** — not viable; we embed GPLv3 code and the App
       Store license terms aren't GPL-compatible.
      Additional bits any signed-for-distribution build needs:
    - `Hardened Runtime` enabled (already a default for new Xcode projects
      but worth verifying after we touch entitlements).
    - An entitlements file granting at minimum: outgoing network (SSH),
      and File Access exceptions for the directories the user syncs.
    - `LSMinimumSystemVersion` in Info.plist (already set to 15.0;
      ratchet up if we start using post-15 APIs).

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

After P0, **land the test suite before the P2 features.** The pattern of
the last few iterations — bugs found by hand, fixed, re-broken by the next
change — argues for tests to be in place when we start touching the bigger
P2 surface area (ignore actions, diff viewer, new-profile editor).

The other high-leverage P1 items are color coding + details footer + colored
icons — they're what make the reconcile window actually *usable* for scanning
a hundred-file changeset. All three are pure Swift; no bridge work needed,
so they can sneak in between test-harness work and P2 features.

Order I'd suggest:
1. P0 — return to picker, rescan, cancel sync
2. P1 — test suite (XCTest + XCUITest + stress + leaks)
3. P1 — color coding + details footer + colored icons (visual polish)
4. P1 — reset-archives recovery action (safety net for the failure mode
   we've seen most often)
5. P2 — ignore actions, diff viewer, force older/newer, full menu mirror,
   new-profile editor
