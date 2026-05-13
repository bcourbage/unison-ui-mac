# unison-ui-mac — TODO

What's left to do, kept brief. Completed items live in the collapsible
section at the bottom so this list stays scannable.

## To Do

- [ ] **Public help target** — the `<appname> Help` menu item now points
      at `MANUAL.md` on `main`. That URL 404s for non-collaborators
      while the repo is private. Pick one: flip the repo public,
      enable the wiki and copy `MANUAL.md` content there, or ship an
      Apple Help bundle inside the `.app`. Blocks the Report-an-Issue
      item below.

- [ ] **Help menu → Report an Issue** — wires
      `https://github.com/bcourbage/unison-ui-mac/issues/new` with a
      pre-filled body templated from app version + OS version. Needs
      the repo to be **public** for non-collaborators to file issues,
      plus a `.github/ISSUE_TEMPLATE/bug_report.md` for structure. As a
      fallback for users without GitHub accounts, consider an iCloud
      "Hide My Email" alias wired via `mailto:` in the About panel.

- [ ] **App signing** — currently ad-hoc (`codesign --force --sign -`).
      On macOS Tahoe 26, ad-hoc-signed apps trigger a one-time
      Gatekeeper prompt the first time they're launched, and re-prompt
      after every rebuild if launched via Finder. Four options:
    1. **Stay ad-hoc** — fine for personal use; live with the prompt.
       Current state.
    2. **Free Apple ID developer cert** — weekly rotation, stops the
       local prompt but the app still isn't notarized so other Macs
       refuse it.
    3. **Apple Developer Program ($99/yr) + notarization** — required
       for any distribution outside the App Store. Set
       `CODE_SIGN_STYLE = Manual` + `CODE_SIGN_IDENTITY = "Developer
       ID Application: …"` in `project.yml`, then `xcrun notarytool
       submit … --wait --staple` as a Makefile target.
    4. **Mac App Store** — not viable; we embed GPLv3 code and the
       App Store license terms aren't GPL-compatible.
      Any signed-for-distribution build also needs Hardened Runtime
      (default for new Xcode projects) + an entitlements file for
      outgoing SSH network access + a current `LSMinimumSystemVersion`.

- [ ] **Warning/error UX completeness** — modal sheets are wired, but
      `displayStatus` messages containing "FAILED" / "error" / "could
      not" still appear only in the row table or the Unified Log.
      Worth surfacing as toasts or banners in the reconcile window so
      transient errors don't get buried.

- [ ] **TUI vs GUI `setupRoots` parity** *(memory aid, not a feature)*
      — if the GUI ever behaves differently from `unison <profile>` on
      the same `.prf`, the first place to look is `Prefs.parseCmdLine`
      vs `Prefs.loadTheFile` ordering inside `do_unisonInit0/1` on the
      OCaml side.

---

<details>
<summary>

## Completed

</summary>

*Historical log of finished work, preserved for context. 40+ items
landed across the bring-up and follow-on sessions.*

### Bring-up workflow

- [x] **Rescan button** in reconcile toolbar — re-runs `init2` against
      the current profile via `unison_bridge_init2()`, replaces `items`
      in place, indeterminate progress bar during the scan.
- [x] **Return to profile picker** — `File → Open Profile` (now `Show
      Profiles`) closes any open reconcile window and re-shows the
      picker; closing the reconcile window also returns to picker via
      `NSWindowDelegate.windowWillClose`.
- [x] **Real mid-sync abort** — Stop button now triggers a true abort
      via a local-fork patch to `src/uimacbridge.ml` registering
      `Callback.register "abortAll" unisonAbortAll`. New
      `unison_bridge_abort_sync()` dispatches `Abort.all` on an OCaml
      worker; the in-flight sync raises `Util.Transient "Aborted by
      user request"` at its next checkpoint. Swift's `cancelSync()`
      sends the abort signal and updates the summary to "Aborting
      sync…" — keeps the window open so the user can inspect FAILED
      rows after the unwind. `windowShouldClose` mid-sync prompt grew
      a third option "Abort & Close" alongside "Keep Syncing" /
      "Close (let it run)". Patch reproducibility via
      `patches/0001-uimacbridge-register-abortAll.patch` +
      `make apply-patches` (auto-runs before `make blob`,
      idempotent). Stays local — never proposed back to
      bcpierce00/unison per the project's LLM-usage posture.

### Reconcile window: visuals + interaction

- [x] **Color-coded reconcile rows** — Action column carries a tinted
      badge (green `#97BB68` → second, blue `#5A96DE` ← first, orange
      conflict, purple merge) with a bolder enlarged arrow glyph.
- [x] **Folder aggregate (Action column)** — folder rows show the
      aggregate direction (uniform → matching badge, all-skipped → gray
      ⊖, mixed → empty). Aggregates recompute on `applyDirection` and
      propagate to every ancestor folder.
- [x] **Details footer** — `NSTextView` strip at the bottom; updates
      on selection via `unisonRiToDetails`. Folders show
      "/path/\n N items in this folder".
- [x] **Window-close guard during sync** — `windowShouldClose` prompt
      with three options (Keep Syncing / Abort & Close / Close-let-it-
      run) once real abort landed.
- [x] **Highlight FAILED rows** — Progress column renders bold systemRed
      when text matches "FAIL". Later subsumed by `ProgressCellView`.
- [x] **Per-row progress bar** — custom-drawn `ProgressCellView` +
      overlaid percent text. Bar fill from `ProgressDescriptor.parse`
      (pure, 12 tests): empty → idle; `"N%"` → bar fill N/100;
      `"done"` → bar at 1.0; `"FAILED"` (any case) → bold red text, no
      bar; unknown labels → text only.
- [x] **Disable direction-override toolbar items when nothing's
      selected** — `outlineViewSelectionDidChange` walks the toolbar's
      segmented direction group and toggles `isEnabled` on each
      subitem.
- [x] **Tooltip on truncated paths** — Path-column cells set
      `toolTip = node.pathFromRoot` whenever the full path differs
      from the displayed leaf name. `ReconcileNode.pathFromRoot`
      handles leaves (stored `fullPath`) and folders (walks ancestors)
      uniformly.
- [x] **Status messages with newlines** — multi-line `displayStatus`
      output surfaces both as a `toolTip` on the summary label AND
      via a "Details…" inline button (NSAlert + scrolling text view).
      Decision rule in `splitStatus(_:)`. `setSummary(_:)` is the
      single chokepoint that clears disclosure state on non-status
      writes.
- [x] **Finder-style path column** — folder icon (`folder.fill`
      systemBlue) + folder name in body font + labelColor. Files get a
      neutral `doc` icon so names align vertically with folder names.
- [x] **Status icons in First + Second columns** — `StatusIconCellView`
      maps each per-side change keyword to an SF Symbol with tooltip:
      Created → plus.circle.fill green, Modified → circle blue
      (hollow), PropsChanged → circle.dashed blue, Deleted →
      minus.circle.fill red, "" → tiny gray dot.
- [x] **Reconcile toolbar layout** — `NSToolbarItemGroup` segmented
      control with palette-tinted SF Symbols. Reading order:
      Profiles · Rescan · `[First | Second | Skip | Merge]` · flex ·
      Go · Stop. Toolbar identifier currently
      `ReconcileToolbar.v5` (bumped through v3 → v4 → v5 as subitem
      sets changed: terminology rename, Merge-conditional inclusion).
- [x] **Colorful toolbar / table icons** — done via SF Symbol palette
      tints: toolbar buttons (green/blue/orange/purple), status cells
      (green/blue/red), direction-cell badges, blue folder.fill paths.
- [x] **Reconcile window during fatal/cancel** — `abortAllInFlight()`
      branches by phase: reconcile-phase (`!isSyncing`) closes the
      window so the picker comes back; sync-phase (`isSyncing`) keeps
      the window open and resets the sync UI in place
      (`resetSyncUIAfterAbort(reason:)`). User can inspect FAILED
      rows before closing manually. Retry path passes
      `forceClose: true` to override.
- [x] **Forced-direction visual override** — a row pinned to Force
      Older/Newer renders the user's *decision* (brown ↺ or teal ↻)
      instead of the mtime-resolved arrow, mirroring the existing
      skip-vs-auto-conflict distinction. Implemented via `RowOverride`
      enum + `rowOverrides: [Int: RowOverride]` dict +
      `DirectionVisual.glyph/tint(for:override:)` + new
      `FolderAggregate` cases (`.allForcedOlder` / `.allForcedNewer`).

### Per-row actions

- [x] **Ignore actions** — right-click on a leaf → Ignore Path /
      Extension / Name, also on the Edit menu. Bridge fns add the
      pattern via `Uicommon.addIgnorePattern`, call
      `unisonUpdateForIgnore` to filter `theState` in place, re-fire
      the init2-complete handler. **Patterns persist to the .prf
      immediately** via `Prefs.add`.
- [x] **Diff viewer** — `DiffWindowController` shows the result of
      `unison_bridge_run_show_diffs` in a monospaced `NSTextView`
      with light per-line coloring for unified diff (`+` green, `-`
      red, `@@` blue, `+++/---` bold no tint). Reused across Diff
      invocations. Scope: any row that passes Unison's `canDiff` —
      excludes directories, symlinks, problem rows, and
      props-only-on-both-sides changes. Includes binary files
      (uninformative output, but the diff runs). Strict single-leaf
      target via `RowSelectionRules.diffTarget` so folder selections
      don't fall back to "first leaf under folder."
- [x] **Force older / newer direction** — `unison_bridge_ri_force_older`
      / `_newer` use the existing `_ri_set_via` helper. Surfaced only
      on the Action menu (no toolbar entry). DirectionAction enum
      extended with `.forceOlder` / `.forceNewer`.
- [x] **Hide Merge when `merge` pref isn't set** — AppDelegate parses
      the .prf via `ProfileDocument.parse`, passes `mergeConfigured:
      Bool` to `ReconcileWindowController`. Toolbar's direction-group
      `makeDirectionGroup` omits the `.merge` subitem when not
      configured; menu Merge item is greyed via `validateMenuItem`.
- [x] **Select Conflicts** + **Revert to Recommendation** —
      Action-menu items. `RowSelectionRules.unresolvedConflictRows`
      returns indices of `<-?->` rows with no user override pinned;
      `clearOverrides(...)` drops overrides on requested rows. Both
      pure-function, fully tested.

### Profile management

- [x] **Profile picker** — pure list + Run button (was "Open"; renamed
      to match the CLI verb). Reads
      `ProfilePreferences.apply(to:includeHidden:false)` so hidden
      profiles disappear from the picker.
- [x] **Profile Editor manager** (`Edit → Profile Editor…`, ⌘⇧E) —
      multi-profile window with one row per `.prf` and per-row
      affordances: hamburger drag-handle for reorder, eye/eye.slash
      toggle for hide/show, profile name. Bottom-bar buttons:
      New… / Duplicate… / Edit… / Delete… / Reset Archives… / Done.
      Rename is **not** a separate button — the form's Profile Name
      field is editable.
- [x] **Profile form** (single-profile editor) — name + First/Second
      roots (terminology from upstream manual; either side can be
      local or remote, Browse for each) + `path =` list + `ignore` +
      `ignorenot` + Advanced raw-text catch-all that preserves every
      other key. Atomic save with `.bak` sidecar. Beyond the legacy
      app: separate `ignore` / `ignorenot` fields surfacing
      list-valued keys (vs. legacy's raw-text view).
- [x] **Hide / delete profile** — both done in the Profile Editor.
      Hide stored in `UserDefaults` under `profiles.hidden`; reorder
      under `profiles.order`. Both UI-only; CLI sees every profile.
      Delete moves the `.prf` + `.bak` to Trash via
      `NSFileManager.trashItem`.
- [x] **"Reset archives" recovery** — both reactive and proactive
      paths. Reactive: when Unison hits "inconsistent state",
      `ArchiveRecovery.swift` parses the fatal text and offers a
      "Delete N Orphan Archive(s) and Retry" button. Proactive: a
      `Reset Archives…` button in the Profile Editor manager.
      `ArchiveHash.swift` replicates upstream's MD5 algorithm in pure
      Swift (no OCaml callback needed) to identify which files belong
      to the selected profile. `archiveFormat = 23` pinned; tests use
      `md5(1)`-verified reference digests so an upstream bump fails
      loudly. **Discovery**: archive files are keyed by
      `(thisRoot, rootsName, archiveFormat)`, NOT the .prf filename.
      Renaming a profile does NOT orphan archives — earlier
      "rename will orphan" warning sheet was wrong and is gone.
- [x] **SSH version-mismatch check** — `VersionCheck.run(...)` spawns
      a one-shot `ssh -o BatchMode=yes host servercmd -version` in
      the background when a profile with an `ssh://` root opens. On
      mismatch, surfaces an NSAlert with `showsSuppressionButton`
      ("Don't remind me again for this host until either version
      changes"). Suppression stored as
      `"<host>|<local>|<remote>"` tokens in `UserDefaults` —
      re-prompts automatically on either-side upgrade. Silent on
      probe failure (no double-prompt with password auth).

### Menus + Help

- [x] **Menu structure** — App / Edit / Action / Window / Help (no
      File menu — non-document app, like Calculator / System
      Settings). Edit: standard text ops + Ignore items + Profile
      Editor. Action: direction overrides + Diff + Select Conflicts /
      Revert. Window: Close (⌘W) + Minimize + Zoom. Help: `<appname>
      Help` (⌘?) + `Unison File Synchronizer Help`.
- [x] **About panel** — version + embedded Unison version (via
      `unison_bridge_get_version`) + GPLv3 attribution paragraph via
      `NSAttributedString` (no Credits.rtf needed).
- [x] **Help menu split** — two entries: app help vs. upstream Unison
      help. No ellipsis on either (HIG: immediate-action items don't
      get one).

### Terminology + correctness pass

- [x] **First / Second replica terminology** — per upstream's
      `unison-manual.tex §Roots`, the two endpoints are "first" and
      "second" — either can be local or remote. Reconcile column
      headers, direction buttons, summary text, `DirectionAction`
      enum cases (`.toFirst` / `.toSecond`), profile form labels —
      all consistent. Toolbar identifier `v3 → v4` to reset
      autosaved layouts.
- [x] **Delete confirm dialog** — fixed "two Cancel buttons" bug.
      `NSAlert.addButton` assigns Return to the FIRST button —
      destructive confirms should add Cancel first (Return = "back
      out"). Same pattern applied to all destructive prompts.

### Build + ops

- [x] **Gate dev hooks behind a Debug build flag** —
      `UNISON_AUTOTEST_*` env-var handling + `runRiOpsAutotest` /
      `maybeRunAutotestHooks` helpers are wrapped in `#if DEBUG`.
      The entire autotest path compiles out of Release builds;
      verified with `strings` (zero AUTOTEST references in Release
      binary).
- [x] **Clean shutdown of OCaml workers** — `unison_bridge_shutdown()`
      releases the bridge's generational global roots (`g_preconn` +
      `g_ri_roots`) by dispatching `release_preconn` +
      `clear_ri_roots` on the OCaml worker thread. AppDelegate calls
      it from `applicationWillTerminate(_:)`. Idempotent +
      safe-before-startup.
- [x] **Build dependency tracking** — `make xcodeproj` regenerates
      automatically on file add/remove/rename. Mechanism: the source
      directories themselves are listed as prereqs of
      `.build/sources.manifest` (POSIX advances directory mtime on
      add/remove but NOT on content edits); the manifest's `cmp -s`
      check avoids spurious regens on no-op directory touches.
- [x] **Local fork patches infrastructure** — `patches/` directory +
      `make apply-patches` that idempotently applies via grep
      detection. Survives a fresh upstream `git clone`. Currently
      one patch (`abortAll` callback registration).
- [x] **Replace TraceLog with `os.Logger`** — `TraceLog.shared.write`
      forwards to `os.Logger` under subsystem
      `net.courbage.unison-ui-mac`, category `general`. The
      `/tmp/unison-ui-mac.log` text file is gone. New structured
      `Log.*` namespace with per-category loggers (lifecycle, bridge,
      reconcile, ocaml-status, version-check) for filterable live
      streams via `log stream --predicate ...`.
- [x] **Remove bring-up test artifacts** — `test-tiny.prf` trashed;
      `/tmp/unison-test-{a,b}` were already gone. Integration tests
      now build their own per-test fixtures under
      `/tmp/unison-ui-mac-itest/<uuid>/` via `IntegrationFixture`.

### Test suite

- [x] **204 tests, ~0.6s** via `make test`, plus ad-hoc `make leaks`
      for `leaks(1)`-based release checks. Coverage:
      - Pure-Swift units across StateItem (3), DirectionAction (4),
        StatusIconDescriptor (6), DirectionVisual (18 incl.
        forced-decision variants), ArchiveRecovery (5), IgnoreAction
        (6), ProfileDocument parse/serialize (14),
        ProfilePreferences apply/forget/rename/reorder/persist (27),
        ReconcileNode.pathFromRoot (4), `splitStatus` (8),
        `ProgressDescriptor.parse` (12), RowSelectionRules / diff
        target (14), DiffWindowController unified-diff line
        classifier (8), ArchiveHash canonicalization + MD5 (12),
        VersionCheck URL/version parsing + suppression (18).
      - Bridge integration tests: `get_version`, `unison_directory`,
        graceful-failure of ri-set / ignore / canDiff / abort_sync
        when no state is loaded.
      - Concurrency/stress: perf measure for 1000 round-trips
        through the bridge.
      - ReconcileTree building + FolderAggregate including
        forced-decision aggregates (15).
      - State-item marshaling: `test_c_init2Marshaling_*` drives
        init1 + init2 against an ephemeral fixture, asserts the
        resulting `[StateItem]` count + direction strings + Created
        statuses + file-type lowercasing.
      - Re-entrance: status handler that re-enters the bridge via
        `unison_bridge_get_version()` from inside the callback body
        — exercises the 3-worker pool design.
      - **Deferred** with rationale: XCUITest (covered indirectly by
        the marshaling test; visual layer easier to smoke-test by
        hand) and modal warn/fatal sheet paths (NSAlert.runModal
        isn't dependency-injectable without significant
        restructuring; dismiss-handler behavior is covered
        indirectly by abortAllInFlight semantics tests).

### Documentation

- [x] **README** rewritten for the current feature set; links to
      MANUAL.md.
- [x] **MANUAL.md** — feature-by-feature user guide, ~600 lines.
      Concept primer, picker / editor / form / reconcile walkthroughs,
      diff-viewer scope notes, menu reference, troubleshooting
      (archive inconsistency, SSH errors, version-mismatch warning,
      Stop button semantics, Unison-update story).
- [x] **CONTRIBUTING.md** — restates the no-upstream-LLM stance,
      sets expectations for downstream contributions.

</details>

---

<details>
<summary>

## Architecture notes

</summary>

*Not work items — context for future contributors.*

- The bridge's **handoff pattern** (request/response via mutex+condvar
  on a dedicated OCaml worker) is used in both directions:
  Swift→OCaml synchronous calls AND OCaml→Swift modal callbacks. The
  same shape fits any future blocking OCaml→Swift call.
- **Per-row OCaml roots** (`g_ri_roots`) re-registered on each init2
  are the key to making per-row actions cheap. Don't reach for
  indices-into-OCaml-arrays patterns — values can move under GC; the
  global-root pointer auto-updates.
- **`@MainActor` on the UI controllers** (AppDelegate, the three
  Profile*WindowControllers, ReconcileWindowController) carries
  through Swift 6 strict concurrency. Any new UI class should adopt
  it.
- **The fork relationship with upstream Unison**: `unison-blob.o` is
  built from a local checkout of `bcpierce00/unison`, with our
  `patches/` applied first (currently just the `abortAll` callback
  registration). Patches stay local — never proposed back per the
  LLM-usage stance. `make apply-patches` is idempotent and runs
  automatically before `make blob`.

</details>
