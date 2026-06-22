# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The `MARKETING_VERSION` (visible in the About panel) tracks releases on this
list; the `CURRENT_PROJECT_VERSION` (CFBundleVersion) increases monotonically
across releases per Apple's bundle-version rules.

## [0.1.5] — 2026-06-21

### Added

- **Progress bar on collapsed folders during sync.** A collapsed folder
  row now shows an aggregate progress bar summarizing the transfer of its
  hidden contents, instead of a blank Progress cell. The fraction is
  byte-weighted (a large file dominates a small one), falling back to a
  done-count when the folder's items have no size (e.g. deletions). The
  bar appears/clears as you collapse/expand the folder.

### Fixed

- **The Profile Editor now honors "Reset window & toolbar layout."**
  Previously the editor reused a long-lived window object, so a reset
  cleared the saved frame in defaults but the next open still appeared at
  the old (possibly off-screen) position. The editor is now released on
  close, so it re-reads the saved frame — or centers when none exists.

### Internal

- Release builds + GitHub releases are now automated by a `v*`-tag
  workflow (`.github/workflows/release.yml`); the Homebrew cask continues
  to auto-bump from the tap.
- Integration tests now run against an isolated `$UNISON` temp directory,
  so the suite never reads or writes the user's real Unison archives.
- More controller logic extracted to pure, tested functions
  (`ProfileDocument.setConflict`, `SettingsModel.composeLogfile`); suite
  grew to 333 tests.

## [0.1.4] — 2026-06-21

### Added

- **Rewritten single-profile editor with a sidebar navigator.** The editor
  now organizes settings into sections in a left sidebar with a search box
  and per-section glyphs: General, Roots, Paths, Ignore, File Attributes,
  Options, Includes, and Advanced.

- **File Attributes section.** Dedicated controls for the metadata Unison
  preserves: modification times, permissions, resource forks, owner, group,
  and suppress-chmod (each Default / On / Off). Permissions offers Default,
  "ignore differences", or a custom octal / hex / decimal mask.

- **Options section.** Conflict handling (Prefer or Force a root, or
  newer / older), plus confirm-big-deletions, auto-accept-changes, and
  fast-update-check.

- **Includes.** Pull in another prefs file with an `include` directive, via
  a small row editor. Each include has a **Top / Bottom** position (Top: the
  profile wins single-value conflicts; Bottom: the included file wins) and an
  optional comment line. A banner notes when a profile includes others.
  Included names may contain spaces (written back-slash-escaped, e.g.
  `include File\ System\ Ignores.prf`), and the `.prf` extension is added
  for you on the saved line while the editor shows the bare profile name.

- **Comments in the freeform list fields.** Paths, Ignore patterns, and
  Exceptions (and the Includes rows) accept `#` comment lines, preserved in
  place across a load/save round-trip. Wrapped long lines are shown with a
  hanging indent so a wrap is visually distinct from a new entry.

- **Logging.** A `log` / `logfile` control in the editor's Options, plus a
  Settings **Logging** tab with three modes: all profiles share one file,
  all share one folder (one file each), or each profile sets its own
  location. Switching into a shared mode offers to update existing profiles
  (all-or-nothing, with a confirmation). The default location is Unison's
  own directory.

- **Open the .prf in your editor.** A pop-out button in the editor's
  top-right opens the raw profile file in your default app for that type.

- **Remote Connection fields** (`servercmd`, `sshcmd`, `sshargs`,
  `clientHostName`) in the Roots section, shown when a root is `ssh://` or
  `socket://`.

- **"Show in the profile picker"** checkbox in the editor's General section
  (mirrors the Profile Editor's eye toggle).

- **Keyboard shortcuts for the reconcile direction controls:** `>` send to
  second, `<` send to first, `/` skip.

### Changed

- The Unison-directory path was removed from the Profile Picker window (it's
  still shown in the Profile Editor, where it's actionable).

- Settings and the profile editor are now mutually exclusive, so a logging
  change can't conflict with an open, unsaved edit. The **Settings** menu
  item is greyed out while a profile is open for editing; opening a profile
  while Settings is open surfaces a "Close Settings first" prompt.

- The Advanced box now refuses to save settings that have a dedicated
  section, or `include` directives, pointing you to the right place instead
  of silently dropping them.

### Fixed

- The profile editor window no longer grows wide to fit long help text.
- The selected sidebar row's label is now reliably readable (white on the
  active highlight) on open and while clicking.
- **Saving a profile with a conflict-handling preference no longer drops a
  nearby comment.** Re-applying `force` / `prefer` used to move the line to
  the end of the file; combined with a bottom `include`, that could delete
  the comment line sitting just above it (e.g. a commented-out `# path = …`).
  The preference is now rewritten in place.
- A profile's file-header comment is no longer absorbed as the first Top
  include's comment (the include block is fenced off with a blank line).

## [0.1.3] — 2026-06-19

### Added

- **Rescan ignoring archives (recovery).** A one-shot way to recover
  from a Unison "archive inconsistency" error without hand-editing the
  `.prf` or using the CLI. Available as **Action → Rescan Ignoring
  Archives…** and as a **Retry Ignoring Archives** button on the
  archive-inconsistency error itself (including the case where the
  missing/extra archive is on the *remote* host, which previously had
  no in-app recovery). Unison rebuilds its state by comparing the two
  replicas directly; your profile file is left unchanged.

- **Reveal profile folder in Finder.** A folder button on the Profile
  Editor's path line opens `~/Library/Application Support/Unison/` in
  Finder.

### Changed

- **Settings is now tab-based** (Saved State / Reconcile / Sync),
  replacing the single long scrolling page. The window resizes to each
  tab. Mirrors the macOS System Settings / Safari preferences layout.

## [0.1.2] — 2026-06-18

### Added

- **Quit button in the UI.** A Quit button now appears on the
  profile picker (bottom bar, separated from Run) and on the
  reconcile-window toolbar. Both route through the standard
  app-termination path, identical to `⌘Q` — so the OCaml bridge
  still shuts down cleanly on the way out.

- **Sync completion is now conspicuous.** When a sync finishes, the
  reconcile summary gains an inline result badge — a green ✓ on a
  clean sync, a red ⚠ when there were errors — with the summary text
  tinted and bolded to match. On top of that, two optional cues
  (both **on by default**, toggleable under **Settings → Sync
  Completion**): a Notification Center banner and a completion sound
  (a chime on success, the system error tone on failure). Note that
  macOS suppresses notification banners while screen sharing and can
  hold them via Scheduled Summary / Focus — the inline badge and
  sound are unaffected.

### Changed

- **CI runner-action versions bumped to `v5`** (`actions/checkout`,
  `actions/cache`, `actions/upload-artifact`) ahead of GitHub's
  Node 20→24 runner migration, which deprecates the `v4` line.

- **Homebrew is now the recommended install path.** Cask formula
  published at <https://github.com/bcourbage/homebrew-tap> pointing at
  the v0.1.1 release artifact. End-user install command:

  ```sh
  brew install --cask bcourbage/tap/unison-ui-mac
  ```

  Homebrew strips the macOS quarantine attribute automatically, so
  first launch is a clean double-click — no Gatekeeper prompt, no
  manual `xattr` invocation. `INSTALL.md` restructured to lead with
  this path; the manual zip-download path is now documented as the
  no-Homebrew fallback. `README.md`'s install blockquote leads with
  the brew one-liner. `INSTALL.md`'s TL;DR splits into end-user and
  developer branches.

- **Bug-report issue template tightened.** Added a visible
  `[!IMPORTANT]` callout at the top redirecting two common non-bug
  cases: usage questions ("how do I…") to `MANUAL.md` and the
  in-app Unison reference manual, and upstream Unison bugs (OCaml
  core, sync semantics, RPC protocol) to
  [`bcpierce00/unison`](https://github.com/bcpierce00/unison/issues).
  Aims to keep the issue tracker focused on actual bugs in this UI.

- **README and v0.1.1 GitHub Release notes** dropped decorative
  emojis in favor of plain bolded text and GitHub's native
  `[!IMPORTANT]` / `[!WARNING]` alert syntax (renders as colored
  callout boxes). Cosmetic; no information content changed.

## [0.1.1] — 2026-05-28

Maintenance release: tightens the SSH version-mismatch warning per
upstream feedback, fixes a version-string regression that surfaced
after v0.1.0, gets CI green on the GitHub-hosted Xcode toolchain.
No user-facing functionality changed.

### Fixed

- **SSH version-mismatch alert no longer fires on compatible
  version differences.** Unison 2.52.0 introduced the new wire
  protocol with feature negotiation; any pair of versions >= 2.52.0
  interoperates without intervention. The previous alert fired on any
  non-byte-equal mismatch — too strict, and a noisy first impression
  for users whose remote happened to be one minor version off.
  Current behavior: alert only when the two sides straddle the 2.52.0
  wire-protocol boundary (i.e., one side pre-2.52, the other
  >= 2.52). Same-side-of-boundary mismatches log to TraceLog but
  don't surface an NSAlert. Implementation: new
  `VersionCheck.classify(local:remote:)` classifier + 23 new tests
  pinning known-compatible and known-incompatible pairs.
- **About panel + Get Info now show the correct version** (`0.1.0` /
  `0.1.1`, not the stale `1.0`). Root cause: `xcodegen generate`
  regenerates `Resources/Info.plist` from `project.yml`'s
  `info.properties` block on every build, falling back to default
  `1.0` / `1` values for any version keys absent from that block.
  v0.1.0 shipped with the regenerated defaults. Fix: anchor the
  substitution variables in `project.yml`'s `info.properties` so
  they survive regen.
- **CI is now green** under the `macos-15` runner's Xcode 16.4
  (vs. our development Xcode 26). Two `@MainActor` annotations
  needed: `MainMenu` enum (touches `NSApp.helpMenu` /
  `.servicesMenu` / `.windowsMenu`) and `PathCellViewTests`
  (constructs NSView, reads main-actor properties). Both
  annotations are semantically correct, not workarounds.

### Documentation

- **README** now leads with a prominent bug-reports notice pointing
  at this repo's issues, not upstream Unison's. CONTRIBUTING.md
  already says this, but README is the surface most new users land
  on first.
- **README** gains six shields.io badges (CI, release, license,
  platform, arch, embedded Unison version).
- **MANUAL.md § Version-mismatch warning** updated to reflect the
  new 2.52-boundary classifier with the underlying wire-protocol
  rationale.
- **GitHub topics** applied to the repo (unison, file-sync,
  file-synchronization, macos, macos-app, swift, appkit, gui,
  ocaml, apple-silicon, gplv3, rsync-alternative) for organic
  discovery via GitHub's topic search.

### Tests

- 286 → 309 tests, all passing in <1s. New: 23 tests covering the
  `VersionCheck` classifier, `parseSemver`, `isPre252`, and the
  wire-protocol boundary at 2.52.0.

## [0.1.0] — 2026-05-27

Initial public release. Embeds Unison File Synchronizer **2.54.0** (upstream
commit `745dccd3ba31c5cf0b89b41f3487091b4871ad31`); see
[`vendor/README.md`](vendor/README.md) for provenance.

### Added

- **Profile picker** — list of `.prf` files from `~/Library/Application
  Support/Unison/` with double-click / Return / Cmd-Enter to launch.
  Hide-list and ordering controlled from the Profile Editor.
- **Reconcile window** — Unison's plan-then-apply workflow: scan
  (`init0`/`init1`/`init2`) → table of differences → per-row direction
  overrides → Go/Stop/Rescan. Real mid-sync abort via a local-fork
  patch to `src/uimacbridge.ml` registering `Callback.register
  "abortAll"`.
- **Per-row progress bar** — `NSProgressIndicator`-backed cell tracking
  Unison's progress strings (`"N%"`, `"FAILED"`, `"done"`, etc.) with a
  pure-function `ProgressDescriptor.parse` for testability.
- **Per-row failure attribution** — synthesized `FAILED: <reason>` cells
  from post-sync `unison_bridge_ri_get_details` so errors surface in
  the row that produced them, not just in a global banner.
- **Details footer** — `NSTextView` strip showing the selected row's
  status / progress / synopsis on selection change.
- **3 layout modes × 3 expand policies** — Settings → Reconcile display
  exposes `flat` / `nestedCollapsed` (default) / `nestedFull` plus
  `smart` / `all` / `rootOnly`. Mirrors upstream's "Switch table
  nesting" 3-segment control and `expandConflictedParent` preference.
- **Color-coded direction badges** — green `#97BB68` (→ second), blue
  `#5A96DE` (← first), orange conflict, purple merge. Folder rows
  show the aggregate direction when uniform.
- **Profile Editor window** — list / edit / delete / reorder / hide
  `.prf` files. Drag-to-reorder, ⌘R refresh.
- **Settings window** — preference UI for picker, reconcile display,
  diagnostics, and the "reset all settings" escape hatch.
- **About panel** — version + embedded Unison version (from the
  bridge) + GPLv3 attribution via `NSAttributedString`.
- **Help → Report an Issue** — opens GitHub's new-issue form with an
  Environment block pre-filled (app version, embedded Unison
  version, macOS version, architecture). A
  `.github/ISSUE_TEMPLATE/bug_report.md` provides the same structure
  for users who hit New Issue via the GitHub UI directly.
- **Auto-expand failed branches post-sync** — when a sync finishes
  with one or more ⚠ FAILED rows, the ancestor chain of each failed
  row is force-expanded in the outline view, even when the
  configured Expand Policy is `Smart` or `Top level only`. Additive
  (user's setting isn't mutated) and reverts on the next rescan.
- **Help → Unison File Synchronizer Manual** — opens a hevea-rendered
  HTML copy of upstream's `doc/unison-manual.tex`, bundled with the
  .app and usable offline.
- **Help → Unison-UI-Mac Help** (⌘?) — opens this repo's MANUAL.md.
- **Diff viewer** — Action → Diff opens the unified-diff text in a
  scrollable window for the selected row.
- **Selection helpers** — Action → Select Conflicts / Revert to
  Unison's Recommendation (pure logic in `RowSelectionRules`).
- **Window-close guard during sync** — three-button alert (Keep
  Syncing / Abort & Close / Close-let-it-run) protects mid-flight
  syncs.
- **SSH credential flow** — `openConnectionPrompt` / `…Reply` / `…End`
  callback loop matches upstream's protocol; supports password +
  passphrase + key-passphrase prompts.
- **Unified Log integration** — subsystem
  `net.courbage.unison-ui-mac`, viewable in Console.app and `log
  show`. Categories: `lifecycle`, `bridge`, `ssh`, `ui`.
- **Vendored OCaml blob** — `vendor/unison-blob-2.54.0-arm64.o`
  committed so everyday `make build` skips the 5–10 min OCaml compile.
  See `vendor/README.md` for provenance + GPLv3 §6 source-availability
  statement.
- **Vendored manual** — `vendor/unison-manual-2.54.0.html` regenerated
  via `make vendor-manual` (hevea), shipped inside the .app.
- **Keyboard shortcuts** — ⌘⏎ Go, ⌘. Stop, ⌘⇧R Rescan, ⌘⇧E Profile
  Editor, ⌘⇧P Show Profile Picker, ⌘? Help, ⌘, Settings.

### Documentation

- `README.md`, `INSTALL.md`, `MANUAL.md`, `NOTICE.md`, `CONTRIBUTING.md`,
  `TODO.md`, `vendor/README.md` cover end-to-end install, daily use,
  attribution, contribution policy, and outstanding work.

### Known limitations

- Apple Silicon (arm64) only. Intel users would need an x86_64 vendored
  blob — drop one next to the arm64 file and the Makefile's
  `ARCH := $(shell uname -m)` selector picks it up automatically.
- macOS 15 (Sequoia) minimum deployment target.
- Ad-hoc code-signed only — distributed .app builds will be blocked
  by macOS 15's Gatekeeper on first open. The right-click → Open
  trick that worked in older macOS releases no longer applies. Strip
  the quarantine attribute with
  `xattr -dr com.apple.quarantine /Applications/unison-ui-mac.app`,
  or use System Settings → Privacy & Security → Open Anyway. See
  [INSTALL.md § First launch & Gatekeeper](INSTALL.md#first-launch--gatekeeper).
- No auto-update mechanism yet. Watch this repo's Releases for new
  versions.

[Unreleased]: https://github.com/bcourbage/unison-ui-mac/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/bcourbage/unison-ui-mac/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/bcourbage/unison-ui-mac/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/bcourbage/unison-ui-mac/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/bcourbage/unison-ui-mac/releases/tag/v0.1.0
