# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The `MARKETING_VERSION` (visible in the About panel) tracks releases on this
list; the `CURRENT_PROJECT_VERSION` (CFBundleVersion) increases monotonically
across releases per Apple's bundle-version rules.

## [Unreleased]

### Fixed
- **Settings → Command Line no longer presents a guessed PATH as the one an
  incoming ssh command receives.** The "Remote SSH command" line now reads
  "Not determined locally" and explains that SSH server configuration and the
  login shell's startup files decide that PATH, with the advice that avoids the
  question: an absolute `servercmd` in the peer's profile. Install and the
  first-launch offer are gated on the Terminal probe alone; the remote context
  can neither enable nor block them. The Terminal line is described as the
  result of a login-shell probe, which an interactive shell's `.zshrc` can
  differ from, and Install's copy says it creates `/usr/local/bin/unison`
  without promising which shells will find it. The manual, the design document
  and the 0.7.0 release notes are corrected in the same way; the manual records
  the one measurement made (Demeter, macOS 26.6.2: `/usr/bin:/bin:/usr/sbin:/sbin`)
  as that machine's observation, not as a rule.
- **The formula-linked Homebrew case was described as a refusal; it is a skipped
  link.** With the `unison` formula linked, Homebrew installs the cask and skips
  the app's `unison` link with a warning, leaving the command with the formula
  (`cask/artifact/symlinked.rb`, Homebrew 6.0.22; executed on Heracles). The
  refusal "already a Binary" applies to a non-formula occupant, as observed
  against the legacy `unison-app` cask's link. Manual, design document and the
  0.7.0 release notes now state the skip and the choice it leaves: keep the
  formula's command, or `brew unlink unison` then `brew reinstall --cask
  unison-ui-mac` to give the command to the app (verified on Heracles).

## [0.7.0] — 2026-09-06

A command-line release. (Build 23.) The app bundle now carries a `unison`
command, so one install serves both the graphical interface and Unison's
command-line roles, including acting as the far side of an SSH profile.
Existing profiles and settings continue to work without migration.

### Added
- **A `unison` command that opens this app.** The bundle now carries a
  command-line launcher at `Contents/MacOS/cltool`. Linked onto PATH under the
  name `unison`, it runs this app for `unison -ui graphic`, runs the embedded
  engine's text interface for `unison -ui text <profile>`, and serves
  `unison -server` headlessly when a remote peer invokes it over ssh. A Mac
  with this app installed therefore no longer needs a separate Unison install
  to act as an SSH peer. The command behaves like Unison's own: arguments
  reach the engine exactly as given, preceded by a `-ui text` default that a
  later `-ui graphic` overrides, so `unison <profile>` runs the text
  interface and only `-ui graphic` opens the app. `-ui graphic` without a
  graphical session is refused. A profile named alongside `-ui graphic` is
  preselected in the picker when the picker lists it, and refused with a
  reason otherwise; two roots on the command line are refused. The PATH link
  is created from Settings → Command Line, or by hand (see MANUAL, "The
  `unison` command"). (#124)
- **Settings → Command Line, and a first-launch offer to install the `unison`
  command.** The tab reads, from the filesystem each time, what `unison`
  resolves to on two PATHs (a login shell's, and the one macOS gives
  non-interactive commands) and names it: this app's command, another copy of
  this app, Homebrew-managed, the Homebrew formula, upstream Unison.app, a
  broken link, or something else. It offers exactly one action when the
  evidence supports it: Install when nothing owns the name, Repair for a broken
  link to a former copy of this app (naming any working command it would take
  precedence over), Remove for this installation's own link. Each needs an
  administrator password. After the picker appears, the app offers Install or
  Repair once per launch under the same conditions, with "Do not ask again".
  Both PATHs are labelled as reconstructions. (#125)

## [0.6.1] — 2026-08-29

A small user-interface and update-infrastructure release on top of 0.6.0.
(Build 22.) Existing profiles and settings continue to work without migration.

### Changed
- **Stop is a sync-only toolbar control, and the reconcile toolbar is spatially
  stable.** The Stop button keeps its "Stop" title and its position in every
  phase and is enabled (red) only during a synchronization, when it aborts that
  sync. It no longer relabels to "Return to Profiles" during a connect/scan, so
  the Go button no longer shifts between phases. Returning to the profile list
  during a scan is the Profiles control's job; leaving does not cancel the scan,
  which continues in the background (quit and relaunch if it does not finish).
  Rescan is now disabled while a scan or sync is already running. Enablement for
  Stop, Rescan, the toolbar, the menu, the keyboard, and the action-method
  boundaries is driven by one shared gate. (#117, #118)
- **Update checks route through `updates.courbage.net`.** Builds from 0.6.1
  onward check for updates through a privacy-scoped Cloudflare Worker that proxies
  the signed GitHub Pages appcast byte-for-byte (the EdDSA feed signature is
  intact and `SURequireSignedFeed` still fails closed). GitHub Pages remains the
  signed origin; a 0.6.0 install still discovers 0.6.1 through its existing feed.
  A bounded per-check telemetry row (the shared profile fields and coarse country,
  no IP, user agent, cookie, or user identifier) is recorded only when anonymous
  system-profile sharing is enabled, and nothing is recorded when it is disabled;
  see [what data the app sends](https://bcourbage.github.io/unison-ui-mac/faq/#what-data-does-the-app-send)
  in the FAQ. (#116)

### Fixed
- **The reconcile toolbar no longer shifts position between phases** — Go moving
  to where another control had been after a scan finished. (#117)

### Internal
- Synced the tracked generated `Resources/Info.plist` with `project.yml` so its
  `SUFeedURL` matches. (#119)

## [0.6.0] — 2026-08-24

A safety, correctness, and robustness release on top of 0.5.1. (Build 21.)
Existing profiles and settings continue to work without migration.

### Security / Safety
- **Archive maintenance is crash-safe and protects live and in-use archives.**
  Every destructive archive operation — Clean Stale Archives, Reset Archives,
  delete-with-archives, and archive-inconsistency recovery — runs through one
  transaction that acquires the same per-archive lock a live Unison uses (so a
  running sync, in this app or another process, blocks it), stages each file
  with an atomic same-filesystem move, and only then moves the removed set to
  the Trash as one unit. Before the removal is logically committed, any failure
  rolls back what it staged, and an incomplete rollback retains the quarantine
  and keeps the locks held rather than deleting. An interrupted operation leaves
  a durable recovery record and is detected on the next launch; if the archive
  family may be split, the affected profiles remain blocked (a surviving lock
  safely stops Unison). Recovery secures each archive before either restoring a
  pre-commit staging or finishing an already-committed removal — moving the
  quarantined copies to the Trash rather than restoring stale archives — and
  releases the locks only after you confirm no other Unison is running.
- **Clean Stale Archives only offers provably superseded copies.** An archive is
  removable only when it is attributed to a current profile that has a newer
  live archive replacing it. Orphans, "probably old" copies, anything involving
  a remote replica, and any archive whose roots can't be unambiguously read are
  now report-only: shown but not selectable, and never preselected. Profile roots
  are resolved through symlinks so a profile's own live archive is never mistaken
  for an orphan.
- The lock file (`lk…`) is never listed for deletion or trashed; it is
  synchronization state, held across the operation, not a payload.
- **`install.sh` installs atomically and only from a Release build.** The manual
  installer stages a validated copy of the app and then swaps it into place in a
  single atomic step, so a failed or interrupted install can never leave you with
  no working app. It clears the download quarantine and verifies the attribute is
  actually gone (rather than assuming success), and it accepts only a Release
  build. (Homebrew-cask installs are unaffected.)
- **Fixed a rare crash or corrupted results at the end of a sync.** The values in
  the end-of-sync completion snapshot could move under the OCaml garbage collector
  before the app read them; they are now GC-rooted, so the final per-row results
  are always read correctly.
- **"Rescan Ignoring Archives…" can no longer overlap in-flight engine work.** It
  runs only from a ready state, so it can't start while a connection, scan, or
  sync is already in progress and clobber it.
- **A profile the app can't read is handled fail-closed.** An unreadable or
  non-UTF-8 `.prf` is not loaded as an editable empty form, so a Save can't
  silently overwrite it with a blank profile.

### Fixed
- **Editing a profile preserves a symlinked `.prf` and the file's structure.**
  Saving a profile no longer replaces a symlinked profile (e.g. one linked from a
  dotfiles repository) with a regular file, and it round-trips comments, ordering,
  and escaping faithfully instead of rewriting them.
- **Diffing a file no longer freezes the reconcile window.** The window stays
  responsive while an external diff runs. A stalled diff is reported, and other
  engine actions stay disabled until it returns; if it never does, quit and
  reopen the app.
- **Ignore and Diff act on the item you mean.** From the menu bar they act on the
  current selection; from the right-click menu they act on the row you clicked
  (not a stale one). **Select Conflicts** now reveals conflicts hidden inside
  collapsed folders instead of silently skipping them.
- **No false version-mismatch warning from an SSH login banner.** The remote
  Unison-version check reads Unison's own `unison version` line, so a login banner
  that happens to contain a version number no longer triggers a spurious
  compatibility warning.
- **Archives with very long root paths are read correctly.** The archive-header
  parser no longer truncates on near-`PATH_MAX` roots, so such archives are still
  attributed to their profile in Clean Stale rather than hidden.

### Changed
- **Genuinely built for the macOS 15 minimum.** The app and its embedded Unison
  runtime are now compiled *for* the macOS 15 deployment target (not merely
  labelled as such), so the stated minimum is real and verified on macOS 15
  before any release is published.

### Documentation
- README opening rewritten for discoverability ("Unison UI for macOS", value
  proposition, requirements, install, features, screenshots).
- Provenance and maintainer docs refreshed: the vendored-patch reference now
  covers all five local patches, and the Sparkle EdDSA key-rotation limitation is
  documented (in-band rotation is not supported by the current single-feed
  pipeline; recovery is a manual reinstallation).

## [0.5.1] — 2026-08-22

A safety and documentation release on top of 0.5.0. (Build 20.) Existing profiles
and settings continue to work without migration.

### Changed
- **Leaving during a scan is now always "Return to Profiles".** While a scan is
  running, the toolbar's Stop control returns to the profile list but does **not**
  cancel the scan, which continues in the background until it finishes on its own.
  (Earlier builds could offer an in-place "Stop Scan" for some SSH scans.)

### Fixed
- **File-integrity safeguard for interrupted scans.** Removed a scan-interruption
  path that could reuse the embedded sync engine in an unverified state after a
  forced interruption. If a remote scan hangs, quit and relaunch (rather than
  Stop Scan followed by Rescan). Recovery from a wedged scan remains
  quit/relaunch; ordinary Sync Stop is unaffected.
- Corrected user-facing documentation (the in-app Manual and README) to describe
  the Return-to-Profiles behavior, the Settings tabs and menus, the SSH
  version-probe and compatibility boundary, and the update process accurately.

### Security
- **Credential prompts now default to masked entry.** The authentication sheet
  classifies each SSH prompt and shows a masked (secure) field for every
  secret — password, passphrase, or verification code — reserving the plain
  field for the exact host-key yes/no question only. A prompt that merely
  mentions "authenticity" or `yes/no`, or a host-key line followed by a password
  prompt, is now treated as a credential and masked (previously it could render
  in a plain, readable field).

## [0.5.0] — 2026-08-21

Adds in-app updates and moves to a Developer ID-signed, notarized build, on top
of 0.4.2. (Build 19.) Existing profiles and settings continue to work without
migration.

### Added
- **In-app updates.** The app checks for and installs updates itself through the
  Sparkle framework (App menu ▸ Check for Updates). On first launch it asks
  whether to check automatically.
- **Software Updates settings.** A new Updates tab in Settings changes whether the
  app checks for updates automatically and whether it includes an anonymous system
  profile, at any time after the first-launch prompt.
- **Donate menu item.** Help ▸ Donate opens the project's GitHub Sponsors page.

### Changed
- **Signed and notarized distribution.** The app is now distributed as a Developer
  ID-signed, notarized build, so it opens with a normal double-click. Updates after
  the first install come through the app itself.

## [0.4.2] — 2026-07-27

A feature release adding a native, appearance-aware app icon and clearer folder
size and sync-progress display, on top of 0.4.1. (Build 18.) Existing profiles
and settings continue to work without migration.

### Added
- **Native app icon with light, dark, and tinted variants.** The app now ships an
  Icon Composer icon that the system renders per appearance on macOS 26 and later
  (light, dark, or tinted to match the desktop), across Finder, the Dock, and the
  About panel. On macOS 15 and earlier the icon falls back to the light rendering.
- **Folder rows show the total size of their changes.** Each folder in the
  reconciliation list reports the combined size of the changed items beneath it,
  so the weight of a pending sync is visible without expanding every folder. A
  folder whose only changes are deletions or property updates stays blank.

### Changed
- **Folders show sync progress, including when expanded.** During a sync, a
  folder's progress bar advances with the aggregate progress of its contents.
  Expanded folders now show this bar alongside each child's own progress, not only
  collapsed ones. A directory that is itself a changed item and also contains
  changed items appears as an expandable folder whose own row stays selectable.

## [0.4.1] — 2026-07-26

A patch release fixing an interactive-authentication prompt annoyance on top of
0.4.0. (Build 17.) Existing profiles and settings continue to work without
migration.

### Fixed
- **Interactive SSH auth no longer shows a spurious extra password prompt.** On a
  password (interactive) profile, a wrong password made ssh's standalone
  "Permission denied, please try again." line surface as its own password sheet, so
  the correct password had to be entered twice. The app now recognizes that
  standalone notice and folds it into the message of the next real prompt: a wrong
  password re-prompts exactly once, and the correct password authenticates on that
  single entry. App-side only; no change to the vendored engine. (#63)

## [0.4.0] — 2026-07-26

Adds user-initiated scan interruption and a connect-time navigation fix on top of
0.3.0. (Build 16.) Existing profiles and settings continue to work without
migration.

### Added
- **Stop Scan.** An in-progress scan can now be interrupted from the Action menu /
  toolbar once it has reached the "waiting for changes from server" point, for a
  **qualified direct-SSH** connection. The interruption is coordinator-gated: it tears
  down the exact tracked SSH transport child and waits for the engine to reach a
  quiescent state. The reconciliation window then stays open in a **"Scan stopped"**
  state, and **Rescan** reuses that same clean session (stop-in-place). "Return to
  Profiles" is the separate fallback shown before the remote-wait point and for
  transports that cannot be stopped in place. (#24)

### Fixed
- **Profile navigation stays available while connecting.** "Show Profile Picker" and
  returning to Profiles are no longer intermittently disabled during the `.opening`
  (connect) phase; the command is owned by a stable target and validated through one
  routing decision, closing a first-menu-open greying race. (#38)

### Known limitations (tracked, not regressions)
- Stop-in-place applies to **qualified direct SSH after the remote-wait point** only.
  Non-direct transports (ControlMaster / ProxyCommand / ProxyJump / custom `sshcmd`)
  use "Return to Profiles" rather than stop-in-place. A **CPU-bound local walk is not
  covered by the 120 s remote-stall timer**; you can Return to Profiles while it winds
  down in the background, and a genuinely wedged engine may still require quitting.
  (Tracked in #53.)

## [0.3.0] — 2026-07-22

A large reliability, data-integrity, and correctness release rolling up the
post-0.2.2 engine-bridge hardening, the cumulative code-review remediation, and
the connection-lifecycle stall/fatal-error fixes. (Build 15 supersedes build 14
with a restart-message copy fix; build 14 superseded the held build 13 with the
connect/scan/sync stall fixes below.)

### Fixed
- **OCaml GC-rooting in `reloadTable`** — callback results are now rooted across
  allocation, closing an intermittent crash/memory-corruption risk during
  progress updates.
- **Bridge exception containment** — Swift↔OCaml entry points route through the
  `caml_callback*_exn` family with per-operation status; an OCaml raise can no
  longer strand a worker or abort the process.
- **"Revert to Unison's Recommendation" is a real engine inverse**
  (`unisonRiRevert`) instead of a Swift-only override delete.
- **Profile save preserves all directives** (`source`, `include?`, `source?`)
  and unknown/raw lines verbatim — a no-op save no longer disables config.
- **Failure-safe, retry-consistent profile save/rename** — temp-file-first with
  backup, rollback, and honest residue reporting.
- **`installExclusive` write-completion hardening** — a short `write()` is a
  failure, all bytes are verified, and `fchmod`/`fsync`/`close` failures are
  surfaced; an incomplete staging file is never installed.
- **External-edit-safe one-shot `ignorearchives` recovery** — restoration
  re-reads the current file and strips only the app-owned suffix, never
  clobbering an edit made during recovery; crash cleanup is anchored to the
  exact app-owned suffix.
- **Clean Stale Archives resolves `include`/`source` roots recursively** and
  marks uncertain attribution instead of risking a wrong delete.
- **Post-authentication scan-stall detector** (issue #24) — a remote transport
  that wedges during `init2`/scan is bounded (120 s, operation-bound) to a
  clear restart-required state instead of hanging in "Opening…".
- **Fatal SSH errors during connect are no longer shown as a password
  re-prompt** (issue #35) — a broken pipe / "connection closed" (e.g. after the
  ssh login-grace timeout) is recognized as terminal via the ssh child's state,
  not re-presented as another password sheet. Because no connection was
  established the app returns to the profile picker with a single dismissible
  error, instead of hanging in "Opening…" and demanding a restart. A cancel that
  cannot prove the engine is quiescent still routes to restart-required, now
  shown as a single modal even when a window is open.
- **Scan-stall detection is phase-aware** (issue #33) — a stall is treated as a
  wedged remote transport (fatal restart-required) only once the engine is
  actually waiting on the remote round-trip. A slow local-replica walk or a
  macOS TCC authorization prompt (e.g. a Photo Library under a synced local
  root) no longer false-positives as a lost connection; the detector keeps
  waiting without touching engine state.
- **Sync-stall notice is advisory, not a false alarm** (issue #34) — during a
  transfer, no-progress silence (common for many-small-file syncs) is reported
  as an informational "no progress observed; the transfer may still be running"
  notice that clears on resume, instead of claiming the connection was lost and
  telling the user to quit. It never changes engine state.
- **SSH version probe** — `StrictHostKeyChecking=yes` (never writes a host key),
  a real wall-clock deadline with terminate→kill→reap, and session-bound
  identity so a stale result cannot update a replacement profile.
- **Diff-request identity broker** — a slower earlier diff result can no longer
  overwrite a newer request.

### Changed
- **Honest "Update All" shared-logging propagation** — structured accounting
  with five distinct outcomes (nothing-needed / complete-success /
  partial-success / complete-failure / cannot-enumerate); a partial or total
  failure is never reported as success.
- **Bulk post-sync completion snapshot** replaces per-row blocking bridge calls
  at sync completion (large reconciliations no longer freeze); vendored blob
  updated accordingly.
- Connection teardown on leave, close-and-drain reconnect, and an SSH
  transport-child reaper (SIGKILL under a mutex; pid reserved until `waitpid`).
- Debug builds sign with a stable Apple Development identity (TCC grants survive
  rebuilds); CI matrix hardening.
- Bundled Unison manual regenerated from the vendored engine's commit
  (`91421d0`, hevea 2.38); the obsolete `mergebatch` preference is gone.
- Documentation/provenance accuracy pass (patch set `0002`–`0005`; upstream
  contribution policy wording; reaper/patch comments).

### Security / Privacy
- Crash-report copy no longer claims "no personal data"; it names what a macOS
  incident report can contain (account name, file paths, process arguments,
  system details) and keeps the Finder-review step. Log values are
  private-by-default (`%{private}@`).

### Deferred / known limitations
- **L3 vendored-engine build provenance** (clean disposable worktree at a pinned
  base commit + machine-generated manifest) is **not implemented** — provenance
  is currently manual/documentary.
- **Cross-process archive-mutation safety** is **deferred to a separate
  upcoming cycle**. (The connect-phase credential/fatal-error handling is
  addressed in this release; see issue #35 above.)
- **True in-process interruption of a wedged/in-flight scan** remains open — the
  scan-stall detector plus quit/reopen is the recovery; `Stop` and the
  credential sheet's `Cancel` are visible-session abandonment, not an engine
  unwind.
- **A real transport-liveness heartbeat** (superseding the advisory sync-stall
  notice of #34 and the status-string proxy of #33) is **deferred** — it needs a
  vendored-engine change. Until then the sync-stall notice stays advisory and
  the scan-stall fatal path keys on the engine's "waiting on server" status.
- **Returning to the profile picker is disabled during the connect phase**
  (post-release UX polish; the navigation is intended always-available). A slow
  or interactive connect must be exited via the credential sheet's Cancel, the
  connect watchdog, or quitting.
- The **vendored blob carries `LC_BUILD_VERSION minos 26.0`** (build-host
  metadata); this is cosmetic — the shipped executable is `minos 15.0` with no
  post-macOS-15 symbols. Optional provenance hygiene only.
- **Distribution is ad-hoc-signed and unnotarized** by design (installed via the
  Homebrew cask); first launch requires the usual Gatekeeper approval.
- Some AppKit window/menu wiring is verified by **code inspection** (its
  pure/presentation models are unit-tested). Issue #24's TC11a used a controlled
  frozen-remote proxy — reproducing the `init2` no-progress condition, not proof
  of an identical root cause with the original inconsistently-reproduced
  incident; the interactive lifecycle cases (TC3/TC4/TC5/TC11b) were verified
  live with a human-entered password.

## [0.2.2] — 2026-06-29

### Changed

- **Clean Stale Archives now decides what to pre-select by topology, not by
  age.** Only archives that are provably this Mac's own dead state are
  checked by default: a superseded copy of a profile that still exists, or a
  sync whose two roots are both this Mac. An archive that references another
  machine is left unchecked for review, because this Mac could be the remote
  side of a sync that machine runs, however infrequently. (Time-based
  guessing would wrongly drop an infrequent remote sync's live archive.)
  Anything with uncertain attribution is also left unchecked.

- Added a **Last modified** column to the Clean Stale window. It is shown for
  reference only and is never used to decide what is safe to remove.

## [0.2.1] — 2026-06-29

### Fixed

- **Reset Archives couldn't find a profile's archive after the Mac was
  renamed.** The archive hash was built from the Bonjour `.local` host name
  instead of POSIX `gethostname()` (what Unison itself uses), so it looked
  for a file that was never written. It now uses the same host name Unison
  does, and matches archives by reading their on-disk headers rather than by
  a recomputed hash (which can't be derived for an ssh remote offline).

- **Reset Archives missed half of a local-to-local profile's state.** Such a
  profile keeps two local archives (one per replica); Reset now clears every
  local archive for the profile instead of just one, and targets only the
  live generation the next sync will actually use.

- **Reset and Delete dialogs needed two Escape presses to cancel, and lost
  the selected profile afterward.** A single Escape now cancels reliably, and
  the previously selected profile stays selected.

### Added

- **Clean Stale Archives** (Settings, Maintenance tab): a resizable window
  listing archive files that no current profile uses, with a checkbox per
  row, a Select-all control, the owning profile name where it can be
  determined, each replica root in its own column, and file sizes. Move the
  checked archives to the Trash (recoverable) or export the list as CSV. Live
  archives are never shown.

- Each archive is integrity-checked (its filename must match a hash of its
  own header) before being matched or trashed, and attributions that can't be
  fully verified are flagged.

## [0.2.0] — 2026-06-27

### Fixed

- **Crash at launch on macOS 26 with notifications enabled.** The app could
  quit unexpectedly while reopening windows. A `@MainActor`-inferred
  completion closure passed to `UNUserNotificationCenter.requestAuthorization`
  was invoked off the main actor by the system; macOS 26's stricter Swift
  runtime traps on the executor-isolation check, crashing at launch even
  though the closure body was empty. Now uses the `async` API, which has no
  off-actor callback. (Reported in #4.)

- **"Cancel sync" at a warning quit the whole app.** Choosing Cancel on a
  Unison warning (e.g. the "no archive files were found" notice) made the
  engine call `exit()`, terminating the app instead of returning to the
  profile picker. Cancel now aborts the operation and returns to the picker.

- **Stopping a sync still reported "Synchronization complete."** Pressing Stop
  during propagation now ends in a distinct **"Synchronization stopped"**
  state (orange), so a user-initiated stop is acknowledged instead of looking
  like a normal, successful finish.

- **Version check failed for profiles that authenticate via `sshargs`.** The
  remote-version probe ignored the profile's `sshcmd`/`sshargs`, so a host
  reachable only via an `-i <key>` in `sshargs` failed `publickey` in the
  probe (while the real sync succeeded), and the wire-protocol mismatch
  warning never fired for it. The probe now honors `sshcmd`/`sshargs`.

- **Hardened the connect watchdog and cancel paths.** The connect-timeout
  watchdog now covers only the connect phase (not the scan, which can run
  long and silent on a large remote tree and would otherwise false-fire), and
  the timeout/Stop teardown no longer pokes the engine mid-scan (which could
  trip an `update.ml` assertion or an Lwt error).

### Added

- **Crash-report prompt.** If the app crashed on a previous launch, it offers
  once to send the macOS crash report — revealing it in Finder and opening a
  pre-filled GitHub issue.

- **Richer, shorter bug reports.** "Report an Issue" now includes the remote
  Unison version (probed for the active profile) and uses a leaner template;
  the log-capture instructions were corrected (they previously produced empty
  output by omitting `--info --debug`).

## [0.1.8] — 2026-06-22

### Fixed

- **App could hang (beachball, force-quit) on a bad SSH connection.** When
  a profile's SSH key, host, or `servercmd` was wrong, the connection ran
  synchronously on the main thread, freezing the whole UI until force-quit.
  The connect + scan (`init1`, the credential prompt loop, `init2`) now run
  off the main thread, guarded by a no-progress stall watchdog that
  recovers cleanly to the profile picker. **Stop** works during the
  connect/scan phase, and a slow-but-progressing large scan is no longer
  mistaken for a hang.

- **Profile Editor silently deleted boolean prefs written as `yes`/`no`.**
  A profile with e.g. `fastcheck = no` showed "Default" in the editor and,
  on save, dropped the line entirely. The Default/On/Off popups
  (`fastcheck`, `auto`, `confirmbigdel`, `rsrc`, `owner`, `group`,
  `dontchmod`, `times`) now understand Unison's full boolean vocabulary —
  `yes`/`no` and a bare key, not just `true`/`false`.

- **Blank / un-scrollable text views in release builds.** The Diff window
  rendered blank diffs, and the status-details panel clipped long SSH error
  dumps with no way to scroll. The canonical `NSTextView`-in-`NSScrollView`
  setup is now enforced through a single shared factory used by every
  scrollable text view, retiring this recurring release-only bug class.

- **Profile Editor: bottom `include` could jump above an added Advanced
  item.** Includes are now written last on save, so a bottom include stays
  below later-added keys.

### Added

- **Diff button on the reconcile toolbar.** Diff was previously buried in
  the Action menu; it now has a toolbar button between the Direction group
  and Go, enabled only when a single diff-able file is selected.

- **Profile Editor search matches more.** The sidebar search now matches a
  section's technical preference names (e.g. `fastcheck`, `sshargs`) and
  its field labels, not only the section title, and the detail pane follows
  the match.

## [0.1.7] — 2026-06-22

### Fixed

- **Crash when expanding or collapsing a folder mid-sync.** Toggling a
  folder's disclosure triangle while a sync was in progress crashed the
  app (`EXC_BAD_ACCESS`, stack overflow). The `outlineViewItemDidExpand` /
  `outlineViewItemDidCollapse` handlers repainted the toggled row's
  progress cell via `reloadItem(_:reloadChildren:)`, which synchronously
  re-posts the same expand/collapse notification — re-entering the handler
  and recursing until the stack was exhausted. Repaint now reloads the
  row's cells by index (`reloadData(forRowIndexes:columnIndexes:)`), which
  changes no expansion state and posts no notification, so it cannot
  re-enter. Reproduced on a live network sync and verified fixed.

## [0.1.6] — 2026-06-21

### Fixed

- **Details footer was blank in release builds.** Selecting a row showed
  no details (size / mtime / conflict info) in the bottom panel. The
  details `NSTextView` was created without the canonical
  frame + resizing + text-container setup; newer SDKs laid it out anyway,
  but the binary built by CI (older SDK) never painted the text — the
  content was present (reachable via accessibility) but invisible. First
  shipped in 0.1.5, which was the first CI-built release.

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
  or use System Settings → Privacy & Security → Open Anyway.
- No auto-update mechanism yet. Watch this repo's Releases for new
  versions.

[Unreleased]: https://github.com/bcourbage/unison-ui-mac/compare/v0.6.1...HEAD
[0.6.1]: https://github.com/bcourbage/unison-ui-mac/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/bcourbage/unison-ui-mac/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/bcourbage/unison-ui-mac/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/bcourbage/unison-ui-mac/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/bcourbage/unison-ui-mac/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/bcourbage/unison-ui-mac/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/bcourbage/unison-ui-mac/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/bcourbage/unison-ui-mac/compare/v0.2.2...v0.3.0
[0.1.3]: https://github.com/bcourbage/unison-ui-mac/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/bcourbage/unison-ui-mac/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/bcourbage/unison-ui-mac/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/bcourbage/unison-ui-mac/releases/tag/v0.1.0
