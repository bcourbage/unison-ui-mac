# unison-ui-mac: TODO

## To Do

- [ ] **Verify a Sparkle auto-update end to end on the 0.5.1 release.** 0.5.0 was
      the first Sparkle build, so there was no prior client to update *from*. On
      0.5.1, confirm an installed 0.5.0 finds, downloads, verifies, and installs
      0.5.1 through the app. This is also the first real exercise of the appcast
      seed-authentication and build-monotonicity paths in `release.yml` against a
      published feed (0.5.0 took the first-release 404 path). While here, remove
      the now-reversed "App signing / notarization: not pursuing" entry from the
      Completed → won't-do section (0.5.0 shipped exactly that).

- [ ] **Scan interruption: residual (post-release umbrella, tracked in #53).**
      Two independent, fail-closed tracks remain after the qualified direct-SSH
      Stop Scan shipped (PR #51):
      - **Track A, CPU-bound local-replica walk:** a scan hashing locally is not
        blocked on the transport, so no transport kill unwinds it. Needs
        scan-specific cooperative cancellation (safe points in `update.ml` +
        exception-safe unwinding) or per-session process isolation, must **not**
        reuse the propagation-global `Abort` flag (`Abort` is consulted by
        propagation, never by `update.ml`).
      - **Track B, non-direct transports** (ControlMaster / ProxyCommand /
        custom `sshcmd`): a transport-ownership problem (killing a shared
        ControlMaster or a proxy with descendant processes is unsafe), stays
        fail-closed until proven.
      Both fall back safely today (Return to Profiles → abandon while the
      coordinator retains engine ownership; the 120 s watchdog bounds a wedged op
      to restart-required). No dependency on #41 (closed infeasible) or #55 (no
      implementation). Analysis in #53 and `docs/scan-interruption-design.md`.

- [ ] **SSH keepalive investigation** (`ServerAliveInterval` /
      `ServerAliveCountMax`), as *mitigation* for wedged connections:
      have ssh actively probe and disconnect a dead peer (~45s) instead
      of a silent indefinite wedge. NOT a rescue of an already-blocked
      transport; its effect on the blocked bridge is unproven (the
      kill-ssh experiment suggests ssh's own exit may not wake Unison's
      `select()`), so any adoption must be *validated against a
      reproduced wedge*, not assumed. Add via `sshargs`/ssh_config.
- [ ] **Secure credential caching (optional):** Keychain and/or SSH
      `ControlMaster` so password-auth profiles don't re-prompt on
      reconnect-after-sleep (a held connection dies on sleep). Separate
      future enhancement; no security shortcuts.

- [ ] **Generalize vendored patch 0002 (`closeConnection`) for upstream-readiness.**
      Strip downstream-specific elements so the patch can stand as a fork-neutral
      contribution offered on its own, independent of the macUI wiring. Author
      the OCaml changes by hand: upstream is wary of LLM-authored diffs (see
      `docs/vendored-patches-upstream.md` "Caveats before investing"). Per-patch
      state and upstream verdicts live in `docs/vendored-patches-upstream.md`
      §0002.


---

<details>
<summary>

## Completed

</summary>

*Historical log of finished work, preserved for context. 40+ items
landed across the bring-up and follow-on sessions.*

### Resolved as won't-do

- [x] **App signing / notarization for distribution:** not pursuing.
      For personal use this is already settled: the ad-hoc signature
      (`codesign --sign -`) plus `install.sh`'s `xattr -dr
      com.apple.quarantine` means launches from `/Applications` don't
      trip Gatekeeper. Distributing notarized builds to other Macs
      (Developer ID cert + `notarytool` + Hardened Runtime +
      entitlements) is out of scope and not of interest. The Mac App
      Store route stays off the table anyway (GPLv3 vs. App Store terms).


### Bring-up workflow

- [x] **Rescan button** in reconcile toolbar: re-runs `init2` against
      the current profile via `unison_bridge_init2()`, replaces `items`
      in place, indeterminate progress bar during the scan.
- [x] **Return to profile picker:** `File → Open Profile` (now `Show
      Profiles`) closes any open reconcile window and re-shows the
      picker; closing the reconcile window also returns to picker via
      `NSWindowDelegate.windowWillClose`.
- [x] **Real mid-sync abort:** Stop button now triggers a true abort
      via a local-fork patch to `src/uimacbridge.ml` registering
      `Callback.register "abortAll" unisonAbortAll`. New
      `unison_bridge_abort_sync()` dispatches `Abort.all` on an OCaml
      worker; the in-flight sync raises `Util.Transient "Aborted by
      user request"` at its next checkpoint. Swift's `cancelSync()`
      sends the abort signal and updates the summary to "Aborting
      sync…" and keeps the window open so the user can inspect FAILED
      rows after the unwind. `windowShouldClose` mid-sync prompt grew
      a third option "Abort & Close" alongside "Keep Syncing" /
      "Close (let it run)". The `abortAll` callback was human-rewritten
      from scratch and **proposed upstream (PR #1198), where it was
      merged** (commit `2429c6c`), so it is now present at the pinned
      base and the local `patches/0001-…` was **retired** (it added
      nothing to the blob). The current local vendor patch set is
      `0002` (closeConnection), `0003` (close-and-drain), `0004`
      (transport-child reaper), and `0005` (sync-completion snapshot);
      they stay local for now, though a future maintainer-authored
      change could still be proposed upstream on its own merits (as
      `abortAll` was).

### Reconcile window: visuals + interaction

- [x] **Reconcile layout + expand policy settings:** two pickers in
      Settings → Reconcile display, mirroring upstream Unison's
      "Switch table nesting" three-segment control plus a
      smart-expand option. **Layout**: `Flat list` / `Nested
      (collapsed)` *(default)* / `Nested (full)`. **Expand on
      open**: `Smart` *(default)* / `All branches` / `Top level only`.
      Stored under `reconcile.layoutMode` and `reconcile.expandPolicy`
      in UserDefaults. The collapse algorithm (merge any folder
      with exactly one child into the child by concatenating names)
      matches upstream's `ReconItem.collapseParentsWithSingleChildren`;
      the smart-expand walk matches upstream's
      `expandConflictedParent` (expand only branches with
      conflicts the user hasn't already resolved via override).
      Both settings re-read on every reconcile populate, so a change
      in Settings takes effect on the next rescan or profile open;
      already-displayed rows aren't re-laid out live.
- [x] **Auto-expand failed branches after a sync with failures:**
      `ReconcileTree.nodesToRevealFailedRows(_:)` walks the tree and
      returns the ancestor chain of every row whose progress ended
      `FAILED` (including the synthesized FAILED rows from
      `attributeRowFailuresFromDetails`). `syncDidComplete` invokes
      this after the failure count is known and expands every
      returned folder. Additive: leaves the user's configured
      `ExpandPolicy` untouched, and the next rescan rebuilds the
      tree, so the widening is one-shot per sync result. 8 new
      XCTest cases cover the new pure surface.

- [x] **Color-coded reconcile rows:** Action column carries a tinted
      badge (green `#97BB68` → second, blue `#5A96DE` ← first, orange
      conflict, purple merge) with a bolder enlarged arrow glyph.
- [x] **Folder aggregate (Action column):** folder rows show the
      aggregate direction (uniform → matching badge, all-skipped → gray
      ⊖, mixed → empty). Aggregates recompute on `applyDirection` and
      propagate to every ancestor folder.
- [x] **Details footer:** `NSTextView` strip at the bottom; updates
      on selection via `unisonRiToDetails`. Folders show
      "/path/\n N items in this folder".
- [x] **Window-close guard during sync:** `windowShouldClose` prompt
      with three options (Keep Syncing / Abort & Close / Close-let-it-
      run) once real abort landed.
- [x] **Highlight FAILED rows:** Progress column renders bold systemRed
      when text matches "FAIL". Later subsumed by `ProgressCellView`.
- [x] **Per-row progress bar:** custom-drawn `ProgressCellView` +
      overlaid percent text. Bar fill from `ProgressDescriptor.parse`
      (pure, 12 tests): empty → idle; `"N%"` → bar fill N/100;
      `"done"` → bar at 1.0; `"FAILED"` (any case) → bold red text, no
      bar; unknown labels → text only.
- [x] **Disable direction-override toolbar items when nothing's
      selected:** `outlineViewSelectionDidChange` walks the toolbar's
      segmented direction group and toggles `isEnabled` on each
      subitem.
- [x] **Tooltip on truncated paths:** Path-column cells set
      `toolTip = node.pathFromRoot` whenever the full path differs
      from the displayed leaf name. `ReconcileNode.pathFromRoot`
      handles leaves (stored `fullPath`) and folders (walks ancestors)
      uniformly.
- [x] **Status messages with newlines:** multi-line `displayStatus`
      output surfaces both as a `toolTip` on the summary label AND
      via a "Details…" inline button (NSAlert + scrolling text view).
      Decision rule in `splitStatus(_:)`. `setSummary(_:)` is the
      single chokepoint that clears disclosure state on non-status
      writes.
- [x] **Finder-style path column:** folder icon (`folder.fill`
      systemBlue) + folder name in body font + labelColor. Files get a
      neutral `doc` icon so names align vertically with folder names.
- [x] **Status icons in First + Second columns:** `StatusIconCellView`
      maps each per-side change keyword to an SF Symbol with tooltip:
      Created → plus.circle.fill green, Modified → circle blue
      (hollow), PropsChanged → circle.dashed blue, Deleted →
      minus.circle.fill red, "" → tiny gray dot.
- [x] **Reconcile toolbar layout:** `NSToolbarItemGroup` segmented
      control with palette-tinted SF Symbols. Reading order:
      Profiles · Rescan · `[First | Second | Skip | Merge]` · flex ·
      Go · Stop. Toolbar identifier currently
      `ReconcileToolbar.v5` (bumped through v3 → v4 → v5 as subitem
      sets changed: terminology rename, Merge-conditional inclusion).
- [x] **Colorful toolbar / table icons:** done via SF Symbol palette
      tints: toolbar buttons (green/blue/orange/purple), status cells
      (green/blue/red), direction-cell badges, blue folder.fill paths.
- [x] **Reconcile window during fatal/cancel:** `abortAllInFlight()`
      branches by phase: reconcile-phase (`!isSyncing`) closes the
      window so the picker comes back; sync-phase (`isSyncing`) keeps
      the window open and resets the sync UI in place
      (`resetSyncUIAfterAbort(reason:)`). User can inspect FAILED
      rows before closing manually. Retry path passes
      `forceClose: true` to override.
- [x] **Forced-direction visual override:** a row pinned to Force
      Older/Newer renders the user's *decision* (brown ↺ or teal ↻)
      instead of the mtime-resolved arrow, mirroring the existing
      skip-vs-auto-conflict distinction. Implemented via `RowOverride`
      enum + `rowOverrides: [Int: RowOverride]` dict +
      `DirectionVisual.glyph/tint(for:override:)` + new
      `FolderAggregate` cases (`.allForcedOlder` / `.allForcedNewer`).
- [x] **Warning/error UX completeness:** multi-line `displayStatus`
      messages already had a Details disclosure; this pass adds a
      persistent red banner (`⚠ N issue(s) — View…`) for any status
      line containing error-looking keywords (FAIL / error / could
      not / permission denied / no such file / connection refused /
      host unreachable / host key verification / Operation timed out
      / Util.Fatal). Classifier is a pure `nonisolated static`
      `errorLines(in:)` with 11 tests. Banner persists until rescan
      or until the user clicks Clear in the disclosure sheet, so
      transient errors emitted at 3% scan don't get steamrolled by
      the next status message at 4%.
      **Subsequently removed** (commit `b5b75c6`): once per-row
      failure attribution landed (the ⚠ + tooltip Progress-column
      marker, fed by `attributeRowFailuresFromDetails` reading each
      row's OCaml-side details at sync-complete), the banner had
      no information left to surface: its content was either
      duplicative of the summary's count prefix or false-positive
      noise (paths containing "Error" / status messages containing
      "failure"). Diagnostic stream still goes to TraceLog →
      Console.app under subsystem `net.courbage.unison-ui-mac`.

### Per-row actions

- [x] **Ignore actions:** right-click on a leaf → Ignore Path /
      Extension / Name, also on the Edit menu. Bridge fns add the
      pattern via `Uicommon.addIgnorePattern`, call
      `unisonUpdateForIgnore` to filter `theState` in place, re-fire
      the init2-complete handler. **Patterns persist to the .prf
      immediately** via `Prefs.add`.
- [x] **Diff viewer:** `DiffWindowController` shows the result of
      `unison_bridge_run_show_diffs` in a monospaced `NSTextView`
      with light per-line coloring for unified diff (`+` green, `-`
      red, `@@` blue, `+++/---` bold no tint). Reused across Diff
      invocations. Scope: any row that passes Unison's `canDiff`:
      excludes directories, symlinks, problem rows, and
      props-only-on-both-sides changes. Includes binary files
      (uninformative output, but the diff runs). Strict single-leaf
      target via `RowSelectionRules.diffTarget` so folder selections
      don't fall back to "first leaf under folder."
- [x] **Force older / newer direction:** `unison_bridge_ri_force_older`
      / `_newer` use the existing `_ri_set_via` helper. Surfaced only
      on the Action menu (no toolbar entry). DirectionAction enum
      extended with `.forceOlder` / `.forceNewer`.
- [x] **Hide Merge when `merge` pref isn't set:** AppDelegate parses
      the .prf via `ProfileDocument.parse`, passes `mergeConfigured:
      Bool` to `ReconcileWindowController`. Toolbar's direction-group
      `makeDirectionGroup` omits the `.merge` subitem when not
      configured; menu Merge item is greyed via `validateMenuItem`.
- [x] **Select Conflicts** + **Revert to Recommendation**:
      Action-menu items. `RowSelectionRules.unresolvedConflictRows`
      returns indices of `<-?->` rows with no user override pinned.
      **Revert is a REAL engine revert (Finding #2, 2026-07-20):** each
      selected modified leaf is reset in OCaml via `unison_bridge_ri_revert`
      (upstream `unisonRiRevert` → `diff.direction <- diff.default_direction`,
      the exact inverse of all six actions, incl. restoring an original
      Conflict that Skip overwrote), then the Swift row (direction +
      `changedFromDefault`) and its visual override are resynced. `changedFromDefault`
      is now first-class on the state item (emitted per scan/Ignore, updated by
      every action) so Revert enablement covers plain First/Second/Merge
      (not just rows in `rowOverrides`) and a Force whose result equals the
      default stays revertible to clear its badge. DIRTY failure → restart-required.
      Verified by engine round-trip tests (six actions→revert, skip-over-conflict,
      force incl. equal-to-default, merge, invalid no-op, exn at each stage,
      multi-row, emit/reindex) + the `isRevertible` predicate tests.

### Profile management

- [x] **Profile picker:** pure list + Run button (was "Open"; renamed
      to match the CLI verb). Reads
      `ProfilePreferences.apply(to:includeHidden:false)` so hidden
      profiles disappear from the picker.
- [x] **Profile Editor manager** (`Edit → Profile Editor…`, ⌘⇧E):
      multi-profile window with one row per `.prf` and per-row
      affordances: hamburger drag-handle for reorder, eye/eye.slash
      toggle for hide/show, profile name. Bottom-bar buttons:
      New… / Duplicate… / Edit… / Delete… / Reset Archives… / Done.
      Rename is **not** a separate button; the form's Profile Name
      field is editable.
- [x] **Profile form** (single-profile editor): name + First/Second
      roots (terminology from upstream manual; either side can be
      local or remote, Browse for each) + `path =` list + `ignore` +
      `ignorenot` + Advanced raw-text catch-all that preserves every
      other key. Atomic save with `.bak` sidecar. Beyond the legacy
      app: separate `ignore` / `ignorenot` fields surfacing
      list-valued keys (vs. legacy's raw-text view).
- [x] **Hide / delete profile:** both done in the Profile Editor.
      Hide stored in `UserDefaults` under `profiles.hidden`; reorder
      under `profiles.order`. Both UI-only; CLI sees every profile.
      Delete moves the `.prf` + `.bak` to Trash via
      `NSFileManager.trashItem`.
- [x] **"Reset archives" recovery:** both reactive and proactive
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
      Renaming a profile does NOT orphan archives; earlier
      "rename will orphan" warning sheet was wrong and is gone.
- [x] **SSH version-mismatch check:** `VersionCheck.run(...)` spawns
      a one-shot `ssh -o BatchMode=yes host servercmd -version` in
      the background when a profile with an `ssh://` root opens. On
      mismatch, surfaces an NSAlert with `showsSuppressionButton`
      ("Don't remind me again for this host until either version
      changes"). Suppression stored as
      `"<host>|<local>|<remote>"` tokens in `UserDefaults`;
      re-prompts automatically on either-side upgrade. Silent on
      probe failure (no double-prompt with password auth).

### Menus + Help

- [x] **Menu structure:** App / Edit / Action / Window / Help (no
      File menu, non-document app, like Calculator / System
      Settings). Edit: standard text ops + Ignore items + Profile
      Editor. Action: direction overrides + Diff + Select Conflicts /
      Revert. Window: Close (⌘W) + Minimize + Zoom. Help: `<appname>
      Help` (⌘?) + `Unison File Synchronizer Manual` (bundled HTML).
- [x] **About panel:** version + embedded Unison version (via
      `unison_bridge_get_version`) + GPLv3 attribution paragraph via
      `NSAttributedString` (no Credits.rtf needed).
- [x] **Help menu split:** two entries: app help vs. upstream Unison
      help. No ellipsis on either (HIG: immediate-action items don't
      get one).
- [x] **Help menu → Report an Issue**: opens
      `https://github.com/bcourbage/unison-ui-mac/issues/new` with
      `?body=` pre-filled (app version, embedded Unison version,
      macOS version, architecture). GitHub's URL API can't combine
      `?template=` with `?body=`, so the menu path drives the body
      and `.github/ISSUE_TEMPLATE/bug_report.md` provides structure
      for users who hit New Issue directly via the GitHub UI.
      `AppDelegate.makeIssueReportBody()` is internal so future
      tests can pin its shape against the template.
- [x] **Public help target:** both Help menu links resolve for
      everyone now that the repo went public at v0.1.0 (2026-05-28).
      `<appname> Help` (⌘?) opens MANUAL.md on the v0.1.0 commit;
      `Unison File Synchronizer Manual` opens the bundled hevea-
      rendered HTML offline. Originally tracked as a blocker on
      Report-an-Issue (the new-issue form needs a public repo to
      accept submissions from non-collaborators), resolved by the
      same repo-flip.

### Terminology + correctness pass

- [x] **First / Second replica terminology:** per upstream's
      `unison-manual.tex §Roots`, the two endpoints are "first" and
      "second"; either can be local or remote. Reconcile column
      headers, direction buttons, summary text, `DirectionAction`
      enum cases (`.toFirst` / `.toSecond`), profile form labels are
      all consistent. Toolbar identifier `v3 → v4` to reset
      autosaved layouts.
- [x] **Delete confirm dialog:** fixed "two Cancel buttons" bug.
      `NSAlert.addButton` assigns Return to the FIRST button;
      destructive confirms should add Cancel first (Return = "back
      out"). Same pattern applied to all destructive prompts.
- [x] **TUI vs GUI `setupRoots` parity audit:** concrete finding:
      GUI's `do_unisonInit1` in `uimacbridge.ml` runs
      `Prefs.parseCmdLine` only on `firstTime`, while upstream's
      `Uicommon.initPrefs` re-parses unconditionally (the "JV (6/09):
      always reparse the command line" comment in that file).
      Practical impact: zero; we launch OCaml with `argv =
      [program_name]`, so there are no command-line args to lose
      anyway. But if we ever start accepting CLI overrides at app
      launch (e.g., `open --args …`), the GUI would apply them only
      on the first profile open and silently drop them on subsequent
      profile switches. Documented in `MANUAL.md`'s "Profile won't
      sync but CLI works" troubleshooting section so the
      divergence is findable if a related bug ever surfaces.

### Build + ops

- [x] **Release-build automation:** `.github/workflows/release.yml`
      triggers on a `v*` tag push: it checks out the tag, mirrors
      `ci.yml`'s OCaml/xcodegen setup, asserts the tag matches
      `project.yml`'s `MARKETING_VERSION`, runs `make test`, builds
      `make build CONFIG=Release`, verifies the ad-hoc signature, packages
      with `ditto -c -k --keepParent`, pulls notes from the matching
      CHANGELOG section, and `gh release create`s (or re-uploads the asset
      if the release already exists). A `workflow_dispatch` `dry_run` mode
      (default on) builds + uploads the zip as an artifact without touching
      any Release, so the pipeline is testable without disturbing a
      published asset's bytes (and thus the cask sha256). The Homebrew
      cask is intentionally NOT bumped here; the tap's `bump-cask.yml`
      detects the new release via `brew livecheck` daily and opens the PR.

- [x] **Isolate test archives from the real Unison dir:** when the
      unit-test bundle is hosted by the app, `AppDelegate`
      `applicationDidFinishLaunching` now detects XCTest (via the
      `XCTestConfigurationFilePath` env var) and `setenv`s `UNISON` to a
      throwaway temp dir (`$TMPDIR/unison-ui-mac-test-unisondir`) *before*
      `unison_bridge_startup()`, the point at which the OCaml runtime
      reads `$UNISON`. So `BridgeTests`' `init1`/`init2` now read fixture
      profiles from, and write `ar*`/`fp*` archives into, the temp dir
      instead of `~/Library/Application Support/Unison/`. Verified: real
      dir archive count unchanged across a run, archives land in the temp
      dir, zero fixture profiles leak into the real dir.

- [x] **Gate dev hooks behind a Debug build flag:**
      `UNISON_AUTOTEST_*` env-var handling + `runRiOpsAutotest` /
      `maybeRunAutotestHooks` helpers are wrapped in `#if DEBUG`.
      The entire autotest path compiles out of Release builds;
      verified with `strings` (zero AUTOTEST references in Release
      binary).
- [x] **Clean shutdown of OCaml workers:** `unison_bridge_shutdown()`
      releases the bridge's generational global roots (`g_preconn` +
      `g_ri_roots`) by dispatching `release_preconn` +
      `clear_ri_roots` on the OCaml worker thread. AppDelegate calls
      it from `applicationWillTerminate(_:)`. Idempotent +
      safe-before-startup.
- [x] **Build dependency tracking:** `make xcodeproj` regenerates
      automatically on file add/remove/rename. Mechanism: the source
      directories themselves are listed as prereqs of
      `.build/sources.manifest` (POSIX advances directory mtime on
      add/remove but NOT on content edits); the manifest's `cmp -s`
      check avoids spurious regens on no-op directory touches.
- [x] **Local fork patches infrastructure:** `patches/` directory +
      `make apply-patches` (via `scripts/apply-unison-patches.sh`) with
      complete-state detection: per patch it `git apply --check`s
      forward (→ apply), else reverse (→ already applied), else fails
      loudly on a partial/incompatible tree. Requires the documented
      set. Survives a fresh upstream `git clone`. Current patches:
      `0002` (closeConnection), `0003` (close-and-drain), `0004`
      (transport-child reaper), and `0005` (sync-completion snapshot);
      `0001` (abortAll) retired after it merged upstream (PR #1198).
- [x] **Replace TraceLog with `os.Logger`:** `TraceLog.shared.write`
      forwards to `os.Logger` under subsystem
      `net.courbage.unison-ui-mac`, category `general`. The
      `/tmp/unison-ui-mac.log` text file is gone. New structured
      `Log.*` namespace with per-category loggers (lifecycle, bridge,
      reconcile, ocaml-status, version-check) for filterable live
      streams via `log stream --predicate ...`.
- [x] **Remove bring-up test artifacts:** `test-tiny.prf` trashed;
      `/tmp/unison-test-{a,b}` were already gone. Integration tests
      now build their own per-test fixtures under
      `/tmp/unison-ui-mac-itest/<uuid>/` via `IntegrationFixture`.
- [x] **Bundle the Unison reference manual:**
      `make vendor-manual` runs hevea (upstream's TeX→HTML
      toolchain) against `doc/unison-manual.tex` and writes
      `vendor/unison-manual-2.54.0.html`. XcodeGen copies it into
      Resources at build time. `AppDelegate.openUnisonProjectHelp(_:)`
      opens the bundled HTML via NSWorkspace using a glob-style
      filename lookup (`unison-manual-*.html`) so a Unison version
      bump doesn't silently fall through to the wiki fallback. Pairs
      with `make vendor-blob`; both refresh in lock-step.
- [x] **GPLv3 §5 bundle hygiene:** `LICENSE` and `NOTICE.md` are
      now copied into the .app's `Contents/Resources/` at build
      time via `project.yml`. A standalone-zipped .app carries its
      own license + attribution; doesn't depend on the source tree
      being alongside.
- [x] **GitHub Actions CI:** `.github/workflows/ci.yml` runs
      `make build` + `make test` on `macos-15` triggered by push to
      main, PRs, and manual workflow_dispatch. Caches the Homebrew
      OCaml install (~3 min savings per run after first hit).
      Uploads xcresult bundle on failure with 7-day retention.
- [x] **First CI run verified green** (commit `87f69c0`, run
      `26548904263`). Actual sticky point was **not** what the
      original TODO predicted (OCaml drift, xcodegen install), it
      was **Xcode-toolchain skew**: local builds on Xcode 26, but
      `macos-15` runner ships Xcode 16.4. Older Xcode is stricter
      about Swift 6 actor isolation on AppKit APIs that newer Xcode
      lets pass implicitly. Two `@MainActor` annotations needed:
      `MainMenu` enum (touches `NSApp.helpMenu` / `.servicesMenu` /
      `.windowsMenu`) and `PathCellViewTests` (constructs NSView
      and reads `textField` / `imageView` / `toolTip`). Both are
      semantically correct, not workarounds. Side discovery during
      the same fix: xcodegen **regenerates** `Resources/Info.plist`
      on every build, overwriting any keys not listed in
      `project.yml`'s `info.properties`, which had silently
      reverted the version-substitution fix and was the actual root
      cause of the original "Get Info shows 1.0 not 0.1.0" report.
      Now anchored in `project.yml`. Lesson for future deployment-
      target or Swift-version bumps: run them through CI before
      assuming "local passes → CI passes."
- [x] **Repo discoverability: GitHub topics + README badges**
      (commits `add-topics`, `066d6fe`). Twelve topic tags applied
      via `gh repo edit --add-topic …` (unison, file-sync,
      file-synchronization, macos, macos-app, swift, appkit, gui,
      ocaml, apple-silicon, gplv3, rsync-alternative); six
      shields.io badges added at the top of the README (CI,
      release, license, platform, arch, embedded Unison version).
      Improves organic discovery via GitHub topic search.
- [x] **v0.1.0: first public release (2026-05-28)**, repo flipped
      public; tag `v0.1.0` annotated at commit `5195c78`; GitHub
      Release published at
      <https://github.com/bcourbage/unison-ui-mac/releases/tag/v0.1.0>
      with `unison-ui-mac-0.1.0.app.zip` (2.1 MB, ad-hoc signed,
      SHA-256 `fabb595a838ca07ade3f415e3abe7899319163e1ade7e57a3255ac91e6056c30`).
      Archive built with `ditto -c -k --sequesterRsrc --keepParent`
      (canonical macOS archiver that preserves the code signature
      and resource forks; standard `zip` can occasionally strip the
      signature).
- [x] **v0.1.1: maintenance release (2026-05-28)**, tag `v0.1.1`
      at commit `5e8a003`, GitHub Release at
      <https://github.com/bcourbage/unison-ui-mac/releases/tag/v0.1.1>
      with `unison-ui-mac-0.1.1.app.zip` (SHA-256
      `d2b6e3b98e30bcd2b7159afe77aa927974d426e45cbd0714fea59c227c68c7ef`).
      Three targeted fixes:
      (a) `VersionCheck` now classifies via a 2.52-wire-protocol-
      boundary predicate (was firing on any non-byte-equal pair,
      which over-warned on compatible new-protocol versions);
      (b) `MainMenu` + `PathCellViewTests` annotated `@MainActor`
      so CI passes under Xcode 16.4's strict Swift 6 concurrency
      (we develop on Xcode 26); (c) `Info.plist` version
      substitution variables anchored in `project.yml`'s
      `info.properties` block so xcodegen's plist regeneration
      doesn't revert them (root cause of the v0.1.0 About-panel
      "1.0" bug). 309 tests, all green. Release notes lead with
      a GitHub `[!IMPORTANT]` callout pointing bug reports at
      this repo, not upstream. Same line in README.
- [x] **Homebrew tap: discoverability unlock**, `bcourbage/
      homebrew-tap` published with `Casks/unison-ui-mac.rb`
      pointing at the v0.1.1 release. Public install path is
      `brew install --cask bcourbage/tap/unison-ui-mac`, verified
      end-to-end (`brew uninstall --cask unison-ui-mac && brew
      install --cask bcourbage/tap/unison-ui-mac && open
      /Applications/unison-ui-mac.app`). INSTALL.md restructured
      to lead with the brew command; manual zip-download path
      demoted to the no-Homebrew fallback. README's install
      blockquote updated to match. Maintainer-only runbook for
      bumping the tap on future releases lives at
      `HOMEBREW_TAP.md` (gitignored, kept on disk only).

### Test suite

- [x] **997 tests, ~1s** via `make test`, plus ad-hoc `make leaks`
      for `leaks(1)`-based release checks. Coverage (illustrative,
      counts are at-last-tally and grow with each pure-logic
      extraction):
      - Pure-Swift units across StateItem, DirectionAction,
        StatusIconDescriptor, DirectionVisual (incl. forced-decision
        variants), ArchiveRecovery, IgnoreAction, ProfileDocument
        parse/serialize, ProfilePreferences
        apply/forget/rename/reorder/persist, ReconcileNode.pathFromRoot,
        `splitStatus`, `ProgressDescriptor.parse`, RowSelectionRules /
        diff target, DiffWindowController unified-diff line classifier,
        ArchiveHash canonicalization + MD5, VersionCheck URL/version
        parsing + suppression, SettingsModel reset semantics +
        suppression-token round-trip, ReconcileSummary count + bytes
        + prefix logic, ArchiveCleanup file find + trash semantics,
        PathCellView tooltip rule.
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
        exercises the 3-worker pool design.
      - **Deferred** with rationale: XCUITest (covered indirectly by
        the marshaling test; visual layer easier to smoke-test by
        hand) and modal warn/fatal sheet paths (NSAlert.runModal
        isn't dependency-injectable without significant
        restructuring; dismiss-handler behavior is covered
        indirectly by abortAllInFlight semantics tests).

### Documentation

- [x] **README** rewritten for the current feature set; links to
      MANUAL.md.
- [x] **MANUAL.md:** feature-by-feature user guide, ~600 lines.
      Concept primer, picker / editor / form / reconcile walkthroughs,
      diff-viewer scope notes, menu reference, troubleshooting
      (archive inconsistency, SSH errors, version-mismatch warning,
      Stop button semantics, Unison-update story).
- [x] **CONTRIBUTING.md:** restates the no-upstream-LLM stance,
      sets expectations for downstream contributions.

</details>

---

<details>
<summary>

## Architecture notes

</summary>

*Not work items: context for future contributors.*

- The bridge's **handoff pattern** (request/response via mutex+condvar
  on a dedicated OCaml worker) is used in both directions:
  Swift→OCaml synchronous calls AND OCaml→Swift modal callbacks. The
  same shape fits any future blocking OCaml→Swift call.
- **Per-row OCaml roots** (`g_ri_roots`) re-registered on each init2
  are the key to making per-row actions cheap. Don't reach for
  indices-into-OCaml-arrays patterns: values can move under GC; the
  global-root pointer auto-updates.
- **`@MainActor` on the UI controllers** (AppDelegate, the three
  Profile*WindowControllers, ReconcileWindowController) carries
  through Swift 6 strict concurrency. Any new UI class should adopt
  it.
- **The fork relationship with upstream Unison**: `unison-blob.o` is
  built from a local checkout of `bcpierce00/unison`, with our
  `patches/` applied first, currently `0002` (closeConnection),
  `0003` (close-and-drain), `0004` (transport-child reaper), and
  `0005` (sync-completion snapshot). These stay local for now;
  upstreaming any individual maintainer-authored patch remains
  possible on its own merits (as `abortAll`/`0001` was, merged via
  PR #1198 and then retired here). `make apply-patches` uses
  complete-state `git apply --check` detection and runs
  automatically before `make blob`.
- **Already-wedged sync cannot be interrupted in-process** under the
  current single-process bridge/Lwt architecture: a transport blocked
  in `select()` on a dead/frozen connection is not woken by closing the
  fd or killing ssh from another thread (validated against a reproduced
  wedge). The supported behavior is the 45s stall indication followed by
  quit + reopen (clean since #5 + #7); PR #9 additionally guarantees the
  registered SSH transport child receives `SIGKILL` during quit. In-place
  cancellation would require a different architecture (process isolation
  of the engine, or engine-level interruptibility) and should only be
  revisited in that context; see the scan-phase true-cancellation task
  in the open items above for the related, separately-feasible mid-scan
  teardown.

</details>
