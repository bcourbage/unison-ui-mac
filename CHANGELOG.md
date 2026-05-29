# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The `MARKETING_VERSION` (visible in the About panel) tracks releases on this
list; the `CURRENT_PROJECT_VERSION` (CFBundleVersion) increases monotonically
across releases per Apple's bundle-version rules.

## [Unreleased]

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

[Unreleased]: https://github.com/bcourbage/unison-ui-mac/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/bcourbage/unison-ui-mac/releases/tag/v0.1.0
