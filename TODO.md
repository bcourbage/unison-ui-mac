# unison-ui-mac — TODO

A snapshot of what's left to do, with priority tiers. Personal-use project;
not for upstream contribution (per unison's CONTRIBUTING.md).

Each section below is collapsible. P0 (the bring-up workflow basics)
defaults closed since it's fully done; the active work tiers default
open so the file stays scannable on GitHub's web view.

<details>
<summary>

## P0 — Workflow gaps blocking real use

</summary>

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

</details>

<details open>
<summary>

## P1 — Quality of life

</summary>

- [x] **Color-coded reconcile rows** — done at the cell level: the Action
      column cell carries a tinted "badge" (green `#97BB68` → remote, blue
      `#5A96DE` ← local, orange conflict, purple merge) with a bolder
      enlarged arrow glyph. Folder rows in the outline view stay uncolored.
      *(See follow-up: folder aggregate tints.)*
- [x] **Folder aggregate (Action column)** — folder rows show the
      aggregate direction in the Action column (uniform → matching
      direction badge, all-skipped → gray ⊖, mixed → empty). The folder
      *icon* in the Path column stays the native Finder blue so folders
      keep reading as folders. Aggregates recompute on `applyDirection`
      and propagate up to every ancestor folder.
- [x] **Details footer in the reconcile window** — `NSTextView` strip at
      the bottom of the window; updates on selection via
      `unisonRiToDetails`. Folders show "/path/\n N items in this folder".
- [x] **Window-close guard during sync** — `NSWindowDelegate.windowShouldClose`
      shows an NSAlert with "Keep Syncing" / "Close Window". Text is
      explicit that closing doesn't actually abort OCaml (we don't have
      mid-sync abort support — see real-cancel TODO).
- [x] **Highlight FAILED rows** — Progress column renders bold systemRed
      when the text matches "FAIL" (covers "FAILED", "Failed", etc.).
- [x] **Per-row progress for slow transfers** — Progress column is now
      a custom-drawn bar + overlaid percent text (`ProgressCellView`).
      Bar fill comes from `ProgressDescriptor.parse(_:)` — a pure
      function with 12 test cases that pin every Unison progress
      shape: empty/whitespace → idle; `"  N%"` → bar fill N/100;
      `"done"` → bar at 1.0 with "done" label; `"FAILED"` (any case,
      any substring) → bold red text, no bar; unknown labels like
      `"start"` or `"queued"` → text only.
- [x] **Disable direction-override toolbar items when nothing is selected**
      — `outlineViewSelectionDidChange` walks the toolbar's segmented
      direction group and toggles isEnabled on each subitem based on
      whether any leaf rows are reachable from the selection.
- [x] **Tooltip on truncated paths** — Path-column cells set
      `toolTip = node.pathFromRoot` whenever the full path differs
      from the displayed leaf name. `ReconcileNode.pathFromRoot`
      handles leaves (returns the stored `fullPath`) and folders
      (walks ancestors) uniformly, replacing the earlier private
      `folderFullPath` helper.
- [x] **Status messages with newlines** — multi-line `displayStatus`
      output (typically SSH connect failures dumping multi-line stderr)
      now surfaces both as a `toolTip` on the summary label *and* via
      a "Details…" inline button that opens an NSAlert with a
      scrolling text view (selectable, copyable). The decision rule
      lives in `ReconcileWindowController.splitStatus(_:)` — a pure
      function (`nonisolated static`) with 8 test cases covering
      empty / single-line / multi-line / whitespace-only / blank-lines-
      between-content. `setSummary(_:)` is the single chokepoint for
      non-status summary text and clears the disclosure state.
- [x] **Finder-style path column** — folder icon (`folder.fill` in
      systemBlue) + folder name in system body font + labelColor. Files
      get a neutral `doc` icon so names align vertically with folder
      names. Both reads like Finder's list view.
- [x] **Status icons in First + Second columns** — `StatusIconCellView`
      maps the per-side change keyword to an SF Symbol with tooltip:
      Created → plus.circle.fill green, Modified → circle blue (hollow),
      PropsChanged → circle.dashed blue, Deleted → minus.circle.fill red,
      "" → tiny gray dot.
- [x] **"Reset archives" recovery action per profile** — both paths
      done. The *reactive* path (when Unison hits "inconsistent state"
      mid-reconcile) parses the fatal text via `ArchiveRecovery.swift`
      and offers a one-click "Delete N Orphan Archive(s) and Retry"
      button. The *proactive* path lives in the Profile Editor manager
      as a `Reset Archives…` button: compute the archive hash via
      `ArchiveHash.swift` (pure-Swift replication of upstream's MD5
      logic, no OCaml round-trip needed), find matching ar*/fp*/lk*/
      tm*/sc* files in the Unison directory, and move them to Trash
      via `ArchiveCleanup.swift`. The confirm dialog shows the hash
      and canonical roots so the user can cross-check against
      `unison -showArchiveName <profile>` if they're paranoid.
      **Rename integration discovery**: archive files are keyed off
      `(thisRoot, rootsName, archiveFormat)` — `rootsName` comes from
      the parsed `root = …` lines, not the .prf filename. So
      renaming a profile (with no root changes) does NOT orphan
      archives. The earlier "renaming will orphan archive files"
      warning sheet was based on a misreading of upstream and has
      been removed. Documented in `ArchiveHash.swift`'s top comment
      so future contributors don't re-introduce the warning.
      **Limitations** (documented in code): doesn't apply `rootalias`
      substitutions; doesn't resolve symlinks in local paths; pins
      `archiveFormat = 23` (upstream's current value — bump if a
      future Unison release changes this).
- [x] **Hide / delete profile** — done via the Profile Editor manager.
      Hide chose **option 1** from the prior design notes: stored in
      `UserDefaults` under `net.courbage.unison-ui-mac` (key
      `profiles.hidden`), CLI is unaffected, picker filters via
      `ProfilePreferences.apply(to:includeHidden:false)`. Reorder uses
      a sibling key `profiles.order`.
- [x] **Reconcile toolbar layout** — done. Direction overrides live in
      an `NSToolbarItemGroup` segmented control with palette-tinted SF
      Symbols (green/blue/orange/purple for each direction). Reading
      order: Profiles · Rescan · `[First | Second | Skip | Merge]` ·
      flex · Go · Stop. Wider spacers between clusters. Toolbar
      identifier is `ReconcileToolbar.v4` (bumped from v3 when the
      Local/Remote → First/Second terminology change renamed the
      `dir.toLocal` / `dir.toRemote` subitems to `dir.toFirst` /
      `dir.toSecond`).
- [x] **Colorful toolbar / table icons** — done via option 2 (SF Symbol
      palette tints):
      - Toolbar: direction buttons palette-tinted (green/blue/orange/purple),
        Go button green, Stop button red, all via
        `NSImage.SymbolConfiguration(paletteColors: …)`.
      - Status cells (`StatusIconCellView`): green plus.circle.fill /
        blue circle / blue circle.dashed / red minus.circle.fill /
        small gray dot for the per-side change state.
      - Direction cells: badge-tinted background (matching toolbar palette)
        with a bold arrow glyph; folder rows show aggregate badges.
      - Path cells: blue folder.fill / neutral doc icon Finder-style.
      The legacy `.tif`/`.png` route is still on the table if the SF
      Symbol style ever feels insufficient, but the current state is
      cohesive enough that there's no pressing need.
- [/] **Test suite** — 185 tests passing in ~0.6s via `make test`.
      Coverage so far and what's left:
    - [x] **Test target wiring** — `unison-ui-macTests` bundle.unit-test
          hosted by the app, runs via `xcodebuild test`. OCaml runtime
          shared via TEST_HOST (one init per process). `make test` green.
    - [x] **Pure-Swift unit tests** — StateItem composition (3),
          DirectionAction toolbar-identifier invariants (4), TraceLog
          ISO-8601 + concurrent-writes (2), StatusIconDescriptor mapping
          (6), DirectionVisual glyph/tint for both leaf and aggregate
          paths including the user-skip distinction (18),
          ArchiveRecovery parse + local-orphan classification (5),
          IgnoreAction label/tag invariants + DirectionAction-tag
          non-collision (6), ProfileDocument parse/serialize/round-trip
          including unknown-key preservation and trailing-newline
          normalization (14), ProfilePreferences apply (filter+sort),
          toggleHidden, forget, rename, drag-reorder index math, and
          UserDefaults persistence round-trip (27),
          ReconcileNode.pathFromRoot for leaves + folders + synthetic
          root (4), ReconcileWindowController.splitStatus single/multi-
          line detection (8), ProgressDescriptor.parse for every
          Unison progress shape including FAIL substring matching (12).
    - [x] **Bridge integration tests** (4) — `unison_bridge_get_version`
          returns a non-empty version string mentioning OCaml,
          `unison_bridge_unison_directory` returns an existing absolute
          dir, ri-set ops on out-of-range rows return NULL gracefully
          (don't crash), ignore-ops on out-of-range rows return false
          gracefully.
    - [x] **Concurrency/stress** (1) — `test_perf_getVersionRoundTrip`
          runs 1000 sync round-trips through the bridge as an XCTest
          perf measure (~10ms steady-state on M1 Max, regression gate
          at 10%).
    - [x] **ReconcileTree** (11) — empty/single/nested/sibling
          building; FolderAggregate uniform/mixed/all-skipped including
          the partial-skip "still needs attention" edge case.
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

</details>

<details open>
<summary>

## P2 — Features from the legacy app

</summary>

- [x] **Ignore actions** — right-click on a leaf row → Ignore Path /
      Extension / Name, also on the Edit menu. Bridge fns
      `unison_bridge_ignore_{path,ext,name}` add the pattern via
      `Uicommon.addIgnorePattern`, call `unisonUpdateForIgnore` to filter
      `theState` in place, then re-fire the init2-complete handler so the
      reconcile window replaces items via the same code path as a rescan.
      Disabled during sync and when the menu target isn't a leaf.
- [x] **Diff viewer** — done. New `DiffWindowController` shows the
      result of `unison_bridge_run_show_diffs` in a monospaced
      `NSTextView` with light per-line coloring for unified-diff
      format (`+` green / `-` red / `@@` blue / `+++`/`---` bold,
      no tint). One window per reconcile session, reused across
      Diff invocations. **Scope**: works for any row that passes
      Unison's `canDiff` predicate — that's "both sides are files
      with differing content." Excludes directories, symlinks,
      problem rows, and props-only-on-both-sides changes. Does
      NOT exclude binary files; those just produce uninformative
      output from `diff -u` ("Binary files differ"). C bridge exposes:
      - `unison_bridge_can_diff(row) → bool` (mirrors OCaml's
        `canDiff` predicate — only text files with content changes)
      - `unison_bridge_run_show_diffs(row)` (async; result arrives
        via the `displayDiff` callback, errors via `displayDiffErr`)
      - `unison_bridge_set_diff_handler` / `_set_diff_err_handler`
        register Swift trampolines. The old abort-stub
        `displayDiff` is now a real callback dispatch; the
        `displayDiffErr` stub is also wired with diff-window
        routing in addition to the existing status-log mirror.
      Menu wiring: `Action → Diff` plus a Diff item at the top of
      the row context menu (so right-click → Diff is the fast
      path). Menu validation calls `canDiff` so binary / props-only
      / non-file rows grey out.
- [x] **Force older / newer direction** — wired through new C bridge
      fns `unison_bridge_ri_force_older` / `_newer`, which use the
      existing `_ri_set_via` helper to invoke `unisonRiForceOlder` /
      `unisonRiForceNewer` then read back the resulting direction.
      Surfaced on the Edit menu (no toolbar entry — too rare to earn
      toolbar real estate). DirectionAction enum extended with
      `.forceOlder` / `.forceNewer` cases; menu order matches the
      legacy app's Action menu (direction → alternatives → mtime
      variants). **Visual override**: a row pinned to Force Older/Newer
      renders the user's *decision* (brown ↺ or teal ↻) instead of the
      mtime-resolved arrow — same pattern as the existing skip-vs-
      auto-conflict distinction. Implemented via a `RowOverride` enum
      (`.skip` / `.forceOlder` / `.forceNewer`), a
      `rowOverrides: [Int: RowOverride]` dict on the controller,
      extended `DirectionVisual.glyph/tint(for:override:)` signatures,
      and new `FolderAggregate` cases `.allForcedOlder` /
      `.allForcedNewer` so folder rows propagate the decision-over-
      direction rule. Tests: 13 new cases pinning glyph/tint distinctness
      and the override-hides-direction behavior at both leaf and folder
      level.
- [x] **Details pane** — done as a footer (`NSTextView` at the bottom of
      the reconcile window). Shows `unisonRiToDetails` on leaf selection,
      and "<folder>/\n N items" on folder selection.
- [x] **Profile Editor manager** — `Edit → Profile Editor…` (⌘⇧E)
      opens a multi-profile window with one row per .prf and per-row
      affordances: hamburger drag-handle (`line.3.horizontal`) for
      reorder, eye / eye.slash toggle for hide/show, profile name.
      Bottom-bar buttons: New…, **Duplicate…**, Edit…, Delete…, Done.
      Duplicate copies the .prf verbatim with a "<name> copy" suggestion
      and inserts next to its source in the custom order. **Rename is
      not a separate button** — the form's "Profile Name" field is
      editable, so an Edit + name-change + Save performs a rename
      (moves the .prf + .bak, rewrites the profile's slot in both
      `order` and `hidden` so prefs stay attached to the same logical
      profile). **Hide and reorder are UI-only**: they live in
      `ProfilePreferences` (a `UserDefaults` wrapper, keys
      `profiles.hidden` + `profiles.order`) and don't touch the .prf
      files — the CLI `unison <profile>` still sees every profile.
- [x] **Profile form (single-profile editor)** — opens from the
      manager's Edit / New buttons, or directly via `File → New
      Profile…`. Form fields: name, **First** and **Second** roots
      (matching the upstream manual's terminology — either can be a
      local path *or* an ssh/socket URL, each with a Browse button for
      local directories), `path =` list, **`ignore =` list**,
      **`ignorenot =` list (include overrides)**, and an "Advanced"
      raw-text catch-all that preserves every other key from the source
      .prf. Save writes atomically via `NSString.write` and creates a
      `<name>.prf.bak` backup first. *Beyond the legacy app*: the
      legacy editor was a single raw-text view; ours separates
      `ignore` from `ignorenot` and surfaces the structure of
      list-valued keys.
- [x] **Delete profile** — lives in the Profile Editor manager (no
      longer on the picker). Confirms via NSAlert and
      `NSFileManager.trashItem`s the `.prf` (plus any `.prf.bak`
      sidecar). Files move to the Trash so a misclick is recoverable
      from Finder. Unison's archive files (ar*, fp*) are intentionally
      left alone — that's the **proactive Reset archives** TODO above.
- [x] **Hide Merge toolbar item if `merge` pref isn't set** — done.
      AppDelegate reads the profile's .prf via `ProfileDocument.parse`
      and passes `mergeConfigured: Bool` to ReconcileWindowController.
      The toolbar's direction-group `makeDirectionGroup` omits the
      `.merge` subitem entirely when not configured; the Edit-menu
      Merge item is greyed via `validateMenuItem`. Toolbar identifier
      bumped `v4 → v5` because the subitem set is now profile-dependent.
      Doesn't follow `include` directives — a merge declared in an
      inherited profile would slip through, but that's rare and the
      worst case is the pre-existing "unhelpful Merge button" behavior.
- [x] **Help menu → Unison Online Help** — done, now split into two
      entries: "unison-ui-mac Help" (⌘?) → this app's README on GitHub,
      and "Unison File Synchronizer Help…" → upstream Unison wiki.
      `NSApp.helpMenu` wired so system Help-search hits it. **Note:**
      the unison-ui-mac repo is private; non-collaborators won't reach
      the README until the repo flips public or a wiki is set up. See
      P3 follow-up "Public help target".
- [x] **About panel** — customized via `orderFrontStandardAboutPanel(options:)`;
      shows the embedded Unison version (via `unison_bridge_get_version`)
      and the GPLv3 attribution.
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
- [x] **Mirror the legacy app's full menu structure** — done for
      every reconcile-window action. Final layout (App / Edit /
      Action / Window / Help; no File menu — see decision earlier):
    - **Edit**: Undo/Redo/Cut/Copy/Paste/Select All (standard) +
      Ignore Path/Extension/Name + `Profile Editor…` (⌘⇧E).
    - **Action**: ← First / → Second / Skip / Merge / Force Older /
      Force Newer (direction overrides, dispatch via
      `directionMenuAction:`) → separator → `Diff` (dispatch via
      `diffMenuAction:`) → separator → `Select Conflicts` and
      `Revert to Unison's Recommendation` (selection helpers,
      pure logic in `RowSelectionRules.swift`).
    - **Help**: `<appname> Help` + `Unison File Synchronizer Help`
      (no ellipsis on either — they open URLs immediately).
    Items we explicitly didn't mirror: `File → Save profile` /
    `Synchronize all` / `Install command-line tool` — Save isn't
    needed (the Profile Editor saves on demand), Synchronize all
    has no clear single-window semantics, and the CLI tool lives
    in `unison-blob.o` inside the .app bundle so there's nothing
    to install. The legacy `Quit` is wired automatically by AppKit
    via `NSApplication.terminate(_:)`.
- [x] **About panel content** — populated via
      `orderFrontStandardAboutPanel(options:)` with version, embedded
      Unison version (`unison_bridge_get_version`), and a GPLv3 credits
      paragraph as `NSAttributedString` (no Credits.rtf needed — the
      attributed-string path works the same way). Duplicates the
      "About panel" item above; both are this one feature.

</details>

<details open>
<summary>

## P3 — Hardening / hygiene

</summary>

- [ ] **Inline-rename profile from the Profile Editor table** — currently
      renaming requires opening Edit, changing the Profile Name field,
      and saving. NSTableView supports per-cell text editing (set
      `tableColumn.isEditable = true` + provide `tableView(_:setObjectValue:for:row:)`
      or use `NSTextField`-based cells with editing enabled and a delegate).
      Wire double-click on the name cell → in-place edit → on commit, run
      the same rename pipeline that `ProfileFormWindowController.saveAction`
      currently uses (move .prf, carry .bak, update `prefs.order` /
      `prefs.hidden`, fire the archive-orphan warning sheet from
      `confirmRenameWarning`). The form's rename path is the model;
      factor the file-system + prefs steps into a shared helper
      (`ProfileRename.swift`?) so both the inline edit and the form
      stay in sync.
- [ ] **Public help target** — the `<appname> Help` menu item now
      points at `MANUAL.md` on `main`. That URL 404s for
      non-collaborators while the repo is private. Pick one of:
    1. Flip the repo public (simplest; needs a CONTRIBUTING.md and a
       license file at the root first — see the LLM-disclosure TODO).
    2. Enable the wiki tab and copy MANUAL.md content there, link
       `<appname> Help` at `/wiki/Home`.
    3. Ship the help as an Apple Help bundle inside the .app — more work
       but doesn't depend on network or GitHub auth.
    Either of (1) or (2) also unblocks the P2 "Report an Issue" Help
    item that's still pending.
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

</details>

<details>
<summary>

## Carried-over reminders (memory notes)

</summary>

- [ ] **Warning/error UX completeness** — the modal sheets are wired, but
      `displayStatus` messages containing "FAILED" / "error" / "could not"
      still appear only in the table or log. Worth surfacing as toasts or
      banners. (See `unison_ui_mac_warning_error_ux` memory note.)
- [ ] **TUI vs GUI `setupRoots` parity** — Unison TUI works against the same
      profiles; if the GUI ever behaves differently for the same profile, the
      first place to look is `Prefs.parseCmdLine` vs `Prefs.loadTheFile`
      ordering in `do_unisonInit0/1`.

</details>

<details>
<summary>

## Architecture remarks (not work items)

</summary>

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

</details>

<details>
<summary>

## Recommendation: do the P0 items, then the colored UI + details footer

</summary>

*Historical note — most of this is now done; kept for the reasoning trail.*

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

</details>
